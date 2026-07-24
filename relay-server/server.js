const express = require('express');
const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { WebSocketServer } = require('ws');

const realApp = express();
// `app` is shadowed as a Router so every route below mounts under BASE_PATH
// without being touched individually (same trick used in git-forge/temutalk).
const app = express.Router();
const BASE_PATH = (process.env.BASE_PATH || '').replace(/\/$/, '');
const PORT = parseInt(process.env.PORT || '3002', 10);

const HEARTBEAT_TIMEOUT_MS = 20_000;
const SWEEP_INTERVAL_MS = 5_000;
const JOIN_TIMEOUT_MS = 10_000;
const MAX_NAME_LEN = 40;
const MAX_PAYLOAD_BYTES = 64 * 1024;
// Mirrors NetworkManager.MAX_LOBBY_PLAYERS in game/net/network_manager.gd --
// kept in sync by hand, same tradeoff already accepted for other client-
// mirrored constants in this file (level tile index ranges, below).
const MAX_LOBBY_PLAYERS = 8;
const RATE_LIMIT_WINDOW_MS = 60_000;
const RATE_LIMIT_MAX = 5;

// catalog.json currently holds published levels (type: 'level') only --
// players are flat auto-colored rectangles now, no client-curated cosmetic
// catalog. Deliberately not cached in memory: re-read fresh from disk on
// every request (cheap -- it's tiny).
const DATA_DIR = path.join(__dirname, 'data');
const CATALOG_JSON_PATH = path.join(DATA_DIR, 'catalog.json');
const CLIENT_ID_RE = /^[a-f0-9-]{8,64}$/i;

// Each level's actual layout is plain JSON, not a PNG -- see
// game/levels/level_data.gd on the client for the exact shape and why it's
// safe to trust directly (tile-index numbers + spawn coordinates only,
// never scenes/scripts). Dimension caps mirror LevelData's own -- kept in
// sync by hand.
const LEVEL_DATA_DIR = path.join(DATA_DIR, 'level_data');
const MAX_LEVELS_PER_CLIENT = 5;
const MAX_LEVEL_TILES = 6000;
const MIN_LEVEL_SPAWN_POINTS = 2;
const MAX_LEVEL_SPAWN_POINTS = 16;
// Mirrors LevelData's own MAX_PLATFORMS/MIN_PERIOD_SEC/MAX_PERIOD_SEC in
// game/levels/level_data.gd -- kept in sync by hand, same tradeoff already
// accepted for the tile caps above.
const MAX_LEVEL_PLATFORMS = 20;
const MIN_PLATFORM_PERIOD_SEC = 0.5;
const MAX_PLATFORM_PERIOD_SEC = 60.0;
// A full 6000-tile level's JSON is ~85-90KB -- this just needs to comfortably
// clear that with room to spare, while staying under the global
// express.json({limit: '256kb'}) body-parser cap below (a request over that
// limit never reaches this handler at all, so this can't usefully exceed it).
const MAX_LEVEL_UPLOAD_BYTES = 150 * 1024;

// Live-updatable *built-in* game art -- distinct from the player-drawn
// custom levels above (those are opt-in per-player content anyone can
// publish freely). These are the game's own default look (tile textures,
// menu badge icons, chrome), shared by every player -- so unlike level
// uploads, publishing here is gated by ASSET_PUBLISH_KEY (see verifyAssetKey
// below), not just rate limiting. See game/tools/art_tool.gd's Export Edits button (the one place
// that calls these) and game/net/game_asset_updater.gd on the client side
// (checks the manifest on launch, offers to download whatever changed).
const GAME_ASSETS_DIR = path.join(DATA_DIR, 'game_assets');
const GAME_ASSETS_MANIFEST_PATH = path.join(DATA_DIR, 'game_assets_manifest.json');
const ASSET_PUBLISH_KEY = process.env.ASSET_PUBLISH_KEY || '';
// SYNC: mirrors game/net/game_asset_categories.gd, the single GDScript-side
// source of truth both art_tool.gd and game_asset_updater.gd preload
// instead of hand-copying. This file can't share that literal source
// across languages, so this is the one remaining manual-sync copy -- keep
// both sides updated together.
const GAME_ASSET_CATEGORIES = ['icons', 'chrome'];
// The app's shared button/panel/slider box art.
const CHROME_KEYS = ['button', 'panel', 'slider_groove', 'slider_fill'];
// Categories that publish as one file per key (like a per-key subfolder)
// rather than a single shared atlas image (like icons/tiles) -- maps each
// to its key list so the publish/download routes below don't need one
// hand-written branch per category.
const MULTI_KEY_CATEGORIES = {
  chrome: CHROME_KEYS,
};
// A full-screen background (1152x648, far bigger than any icon/mode-button
// canvas) needs more headroom than those -- bumped along with the
// express.json limit below to match.
const MAX_ASSET_UPLOAD_BYTES = 2 * 1024 * 1024;

// Reads a PNG's declared width/height straight from its IHDR chunk (always
// the first chunk, always 8-byte signature + 4-byte length + 4-byte "IHDR"
// + data) rather than pulling in an image-decoding dependency -- this trusts
// the declared header, not actual decoded pixels, so a deliberately
// malformed file could lie about its own size. Godot's own PNG loader fails
// safely on a genuinely corrupt file either way; if stricter validation is
// ever needed, a pure-JS decoder like pngjs is the natural upgrade.
function pngDimensions(buf) {
  if (buf.length < 24) return null;
  if (buf[0] !== 0x89 || buf.toString('ascii', 1, 4) !== 'PNG') return null;
  if (buf.toString('ascii', 12, 16) !== 'IHDR') return null;
  return { width: buf.readUInt32BE(16), height: buf.readUInt32BE(20) };
}

fs.mkdirSync(LEVEL_DATA_DIR, { recursive: true });
const MATCHES_DIR = path.join(DATA_DIR, 'matches'); // one file per match, mirrors LEVEL_DATA_DIR's one-file-per-id pattern
fs.mkdirSync(MATCHES_DIR, { recursive: true });
for (const category of Object.keys(MULTI_KEY_CATEGORIES)) {
  fs.mkdirSync(path.join(GAME_ASSETS_DIR, category), { recursive: true });
}

function loadGameAssetsManifest() {
  try { return JSON.parse(fs.readFileSync(GAME_ASSETS_MANIFEST_PATH, 'utf-8')); }
  catch { return {}; }
}
let gameAssetsManifest = loadGameAssetsManifest(); // category -> { version, updatedAt }

function saveGameAssetsManifest() {
  fs.writeFileSync(GAME_ASSETS_MANIFEST_PATH, JSON.stringify(gameAssetsManifest));
}

// Constant-time against timing attacks (same approach as verifyPassword
// above), and fails closed: an unset key on the server rejects every
// publish rather than accepting an empty key from the caller.
function verifyAssetKey(candidateKey) {
  if (!ASSET_PUBLISH_KEY) return false;
  const a = Buffer.from(String(candidateKey || ''));
  const b = Buffer.from(ASSET_PUBLISH_KEY);
  if (a.length !== b.length) return false;
  return crypto.timingSafeEqual(a, b);
}

function readCatalog() {
  try { return JSON.parse(fs.readFileSync(CATALOG_JSON_PATH, 'utf-8')); }
  catch { return []; }
}

// ─── Ranked (ELO, ranks, matchmaking) ──────────────────────────────────────────
// Ranked matches are hosted by whichever player's client happened to open
// one (see game/net/network_manager.gd's is_ranked_server auto-lobby) --
// the same trust model casual play already uses, explicitly accepted for
// now rather than standing up dedicated always-on ranked infrastructure.
// That host can misreport *facts* (who placed where), but never mints
// rating points directly: this relay is the sole place ELO math happens and
// the sole writer of ranks.json, so a rigged host is bounded by the same
// formula everyone else is.
const RANKS_JSON_PATH = path.join(DATA_DIR, 'ranks.json');
const ELO_K = 28;
const STARTING_ELO = 1000;
const MAX_ELO = 9999;
const RANK_TIERS = [
  { name: 'Bronze', minElo: 0 },
  { name: 'Silver', minElo: 1100 },
  { name: 'Gold', minElo: 1300 },
  { name: 'Platinum', minElo: 1550 },
  { name: 'Diamond', minElo: 1850 },
  { name: 'Master', minElo: 2200 },
  { name: 'Grandmaster', minElo: 2800 },
  { name: 'Champion', minElo: 3600 },
  { name: 'Legend', minElo: 4800 },
  { name: 'Mythic', minElo: 6500 },
  { name: 'Immortal', minElo: 9000 },
  // Above MAX_ELO (see applyEloUpdates' clamp below) -- no normal match
  // result can ever push a player's elo past 9999, so this tier is
  // unreachable through real play. Exists only for a manually-set account.
  { name: 'Creator', minElo: 10000 },
];

function tierForElo(elo) {
  let tier = RANK_TIERS[0].name;
  for (const t of RANK_TIERS) {
    if (elo >= t.minElo) tier = t.name;
  }
  return tier;
}

function loadRanks() {
  try { return JSON.parse(fs.readFileSync(RANKS_JSON_PATH, 'utf-8')); }
  catch { return {}; }
}
// clientId -> playlistId -> { elo, wins, losses, matchesPlayed, lastPlayed }
// -- one ELO per {player, playlist} pair (1v1, 2v2, 1v1v1, 1v1v1v1 all rank
// separately, Rocket-League style), not one global number per player. "" is
// the legacy/undifferentiated free-for-all pool a ranked server launched
// without --playlist= falls back to (see network_manager.gd's playlist_id).
// Deliberately no migration from the old flat {clientId: {elo,...}} shape
// this replaces -- accepted clean break (active dev data, not a live
// service), see the plan this shipped from.
let ranks = loadRanks();

function saveRanks() {
  fs.writeFileSync(RANKS_JSON_PATH, JSON.stringify(ranks));
}

function getRankEntry(clientId, playlistId) {
  const playlist = String(playlistId || '');
  if (!ranks[clientId]) ranks[clientId] = {};
  if (!ranks[clientId][playlist]) ranks[clientId][playlist] = { elo: STARTING_ELO, wins: 0, losses: 0, matchesPlayed: 0, lastPlayed: 0 };
  return ranks[clientId][playlist];
}

// Standard FFA/multiplayer Elo extension: every pair (i, j) in the lobby is
// treated as an independent virtual 1v1 where whoever placed better is the
// "winner" of that pair, then each player's total delta is averaged over
// their N-1 opponents so total rating movement stays comparable regardless
// of how many people were in the round (an 8-player lobby shouldn't swing
// ratings 7x harder than a 2-player one).
function applyEloUpdates(results, playlistId) {
  // results: [{clientId, itTime, place}], already sorted/placed by the caller.
  // Team play reports the same `place` for both teammates (see
  // server_match.gd's _rank_by_team) -- two results sharing a `place` are
  // always teammates (FFA placement is always unique-per-player), so that
  // alone is enough to detect a team pairing with no separate team field
  // needed on the wire. Those pairs are skipped entirely rather than
  // compared as a "tie" -- comparing them would otherwise treat neither as
  // having "won" against the other and pull both down by an amount that
  // depends on their relative starting elo (not actually a tie at all,
  // just two players who were never opponents this match).
  const n = results.length;
  if (n < 2) return; // nothing to compare a lone result against
  const before = results.map(r => getRankEntry(r.clientId, playlistId).elo);
  const deltas = results.map(() => 0);
  const opponentCounts = results.map(() => 0);
  // Team mode never reaches place===n (team A/B in a 2v2 are place 1/2,
  // not 1/4) -- the actual "last place" is whatever the highest place
  // value in this result set is, which degrades to exactly n for FFA
  // (every place 1..n is unique there) and is the team count for team mode.
  const lastPlace = Math.max(...results.map(r => r.place));
  for (let i = 0; i < n; i++) {
    for (let j = 0; j < n; j++) {
      if (i === j || results[i].place === results[j].place) continue;
      const expected = 1 / (1 + Math.pow(10, (before[j] - before[i]) / 400));
      const actualScore = results[i].place < results[j].place ? 1 : 0; // lower place number = better = "won" this pair
      deltas[i] += (actualScore - expected);
      opponentCounts[i] += 1;
    }
  }
  for (let i = 0; i < n; i++) {
    const entry = getRankEntry(results[i].clientId, playlistId);
    if (opponentCounts[i] > 0) {
      entry.elo = Math.min(MAX_ELO, Math.round(entry.elo + ELO_K * (deltas[i] / opponentCounts[i])));
    }
    entry.matchesPlayed += 1;
    entry.lastPlayed = Date.now();
    if (results[i].place === 1) entry.wins += 1;
    else if (results[i].place === lastPlace) entry.losses += 1;
  }
  saveRanks();
}

// ─── Accounts (username + password login) ──────────────────────────────────────
// Deliberately a thin identity layer, not a replacement for clientId: every
// other system in this file (ranks, catalog createdBy, etc.) stays keyed by
// clientId exactly as before. An account just resolves to one stable
// "primaryClientId" -- logging into the same account from a second device
// means that device adopts the first device's clientId going forward, so both
// devices land on the same already-existing rows everywhere else. That's the
// entire migration story: there is nothing else to migrate.
const ACCOUNTS_JSON_PATH = path.join(DATA_DIR, 'accounts.json');
const SESSIONS_JSON_PATH = path.join(DATA_DIR, 'sessions.json');
const USERNAME_RE = /^[a-zA-Z0-9_]{3,20}$/;
const MIN_PASSWORD_LEN = 8;
const SESSION_TTL_MS = 30 * 24 * 60 * 60 * 1000; // 30 days -- persisted (not memory-only) so a relay restart doesn't log everyone out
const SCRYPT_KEYLEN = 64;

function loadAccounts() {
  try { return JSON.parse(fs.readFileSync(ACCOUNTS_JSON_PATH, 'utf-8')); }
  catch { return {}; }
}
let accounts = loadAccounts(); // accountId -> { username, usernameLower, salt, passwordHash, primaryClientId, createdAt }

function saveAccounts() {
  fs.writeFileSync(ACCOUNTS_JSON_PATH, JSON.stringify(accounts));
}

function loadSessions() {
  try { return JSON.parse(fs.readFileSync(SESSIONS_JSON_PATH, 'utf-8')); }
  catch { return {}; }
}
let sessions = loadSessions(); // token -> { accountId, expiresAt }

function saveSessions() {
  fs.writeFileSync(SESSIONS_JSON_PATH, JSON.stringify(sessions));
}

// Node's built-in scrypt (no extra npm dependency, same "use what's already
// there" preference as dev-panel.js's crypto.createHash key check) -- unlike
// that key check, a human-chosen password needs an actual slow, salted KDF
// rather than a bare hash, since passwords (unlike a random USB-key file) are
// low-entropy and brute-forceable without one.
function hashPassword(password, saltHex) {
  return crypto.scryptSync(password, saltHex, SCRYPT_KEYLEN).toString('hex');
}

function verifyPassword(password, saltHex, expectedHashHex) {
  const candidate = Buffer.from(hashPassword(password, saltHex), 'hex');
  const expected = Buffer.from(expectedHashHex, 'hex');
  if (candidate.length !== expected.length) return false;
  return crypto.timingSafeEqual(candidate, expected);
}

function findAccountByUsername(usernameLower) {
  for (const [accountId, account] of Object.entries(accounts)) {
    if (account.usernameLower === usernameLower) return [accountId, account];
  }
  return null;
}

function createSession(accountId) {
  const token = crypto.randomBytes(32).toString('hex');
  sessions[token] = { accountId, expiresAt: Date.now() + SESSION_TTL_MS };
  saveSessions();
  return token;
}

function getBearerToken(req) {
  const header = req.headers['authorization'] || '';
  const match = header.match(/^Bearer (.+)$/);
  return match ? match[1] : null;
}

// Sweep expired sessions the same way the server directory sweeps dead
// heartbeats below -- lazy cleanup, not correctness-critical (an expired
// token is already rejected on use via the expiresAt check in /api/auth/me).
setInterval(() => {
  const now = Date.now();
  let changed = false;
  for (const [token, s] of Object.entries(sessions)) {
    if (s.expiresAt < now) { delete sessions[token]; changed = true; }
  }
  if (changed) saveSessions();
}, SWEEP_INTERVAL_MS * 12); // every ~60s -- session expiry isn't time-sensitive like server heartbeats

// ─── Progression (XP, levels, achievements) ────────────────────────────────────
// Piggybacks entirely on the same trusted event ranked Elo already uses --
// POST /api/ranked/report-result -- rather than opening a second, separately-
// trusted report endpoint. No new client-reported data: XP/achievements are
// derived purely from the same {clientId, itTime, place} payload applyElo
// Updates() already validated, plus each player's own running progression
// row. Ranked-only for the same reason ranks themselves are (DESIGN_SPEC.md
// 4.2) -- casual matches report nothing today, so casual XP is out of scope.
const PROGRESSION_JSON_PATH = path.join(DATA_DIR, 'progression.json');
const XP_BASE = 20;
const XP_PLACEMENT_BONUS = 8;

function loadProgression() {
  try { return JSON.parse(fs.readFileSync(PROGRESSION_JSON_PATH, 'utf-8')); }
  catch { return {}; }
}
let progression = loadProgression(); // clientId -> { xp, achievements: [ids...] }

function saveProgression() {
  fs.writeFileSync(PROGRESSION_JSON_PATH, JSON.stringify(progression));
}

function getProgressionEntry(clientId) {
  if (!progression[clientId]) progression[clientId] = { xp: 0, achievements: [], username: null };
  return progression[clientId];
}

// level is always derived from xp, never stored redundantly -- there's
// nothing to keep in sync if the curve ever changes, just re-derive.
function levelForXp(xp) {
  return 1 + Math.floor(Math.sqrt(xp / 100));
}

// Each condition sees the player's own already-updated rank entry (post-
// applyEloUpdates) and this specific match's {itTime, place} for them, plus
// n (how many participants this round had, needed for "placed last").
const ACHIEVEMENTS = [
  { id: 'first_win', name: 'First Blood', condition: (rank, m) => rank.wins === 1 && m.place === 1 },
  { id: 'ten_wins', name: 'Perfect Ten', condition: (rank) => rank.wins === 10 },
  { id: 'fifty_wins', name: 'Half a Century', condition: (rank) => rank.wins === 50 },
  { id: 'untouchable', name: 'Untouchable', condition: (rank, m) => m.place === 1 && m.itTime === 0 },
  { id: 'veteran', name: 'Veteran', condition: (rank) => rank.matchesPlayed === 50 },
  { id: 'century', name: 'Century Club', condition: (rank) => rank.matchesPlayed === 100 },
  { id: 'marathon', name: 'Marathon Runner', condition: (rank) => rank.matchesPlayed === 200 },
  { id: 'silver', name: 'Silver League', condition: (rank) => rank.elo >= 1100 },
  { id: 'gold', name: 'Gold League', condition: (rank) => rank.elo >= 1300 },
  { id: 'platinum', name: 'Platinum League', condition: (rank) => rank.elo >= 1550 },
  { id: 'diamond', name: 'Diamond League', condition: (rank) => rank.elo >= 1850 },
  { id: 'master', name: 'Master League', condition: (rank) => rank.elo >= 2200 },
  { id: 'grandmaster', name: 'Grandmaster League', condition: (rank) => rank.elo >= 2800 },
  { id: 'champion', name: 'Champion League', condition: (rank) => rank.elo >= 3600 },
  { id: 'legend', name: 'Legend League', condition: (rank) => rank.elo >= 4800 },
  { id: 'mythic', name: 'Mythic League', condition: (rank) => rank.elo >= 6500 },
  { id: 'immortal', name: 'Immortal League', condition: (rank) => rank.elo >= 9000 },
  { id: 'creator', name: 'Creator League', condition: (rank) => rank.elo >= 10000 },
  { id: 'last_place', name: "Tag, You're It", condition: (rank, m) => m.place === m.n },
];

function achievementList(ids) {
  return ids.map(id => {
    const def = ACHIEVEMENTS.find(a => a.id === id);
    return { id, name: def ? def.name : id };
  });
}

// One file per match at data/matches/<id>.json (mirrors the existing one-
// file-per-id pattern already used for levels), plus a capped
// (last 20) list of match-id references on each participant's own
// progression row so a profile page can list "recent matches" without
// scanning the whole matches directory.
const MAX_RECENT_MATCHES = 20;
function recordMatchHistory(results, playlistId) {
  const id = 'match_' + crypto.randomBytes(8).toString('hex');
  const record = { id, timestamp: Date.now(), playlist: String(playlistId || ''), results };
  fs.writeFileSync(path.join(MATCHES_DIR, id + '.json'), JSON.stringify(record));
  for (const r of results) {
    const entry = getProgressionEntry(r.clientId);
    if (!entry.recentMatches) entry.recentMatches = [];
    entry.recentMatches.unshift(id);
    if (entry.recentMatches.length > MAX_RECENT_MATCHES) entry.recentMatches.length = MAX_RECENT_MATCHES;
  }
}

// Called right after applyEloUpdates(results) inside report-result -- reuses
// the exact same validated {clientId, itTime, place} entries, plus n
// (results.length) for achievements that depend on the whole round's size.
function applyProgressionUpdates(results, playlistId) {
  // Team mode never reaches place===results.length (see applyEloUpdates'
  // identical lastPlace note) -- both the placement XP bonus and the
  // last_place achievement condition below need the real highest place in
  // this result set, not the raw player count, or a team-mode loser's
  // bonus/achievement math silently breaks.
  const lastPlace = Math.max(...results.map(r => r.place));
  for (const r of results) {
    const entry = getProgressionEntry(r.clientId);
    if (r.username) entry.username = r.username;
    entry.xp += XP_BASE + Math.max(0, lastPlace - r.place) * XP_PLACEMENT_BONUS;
    const rank = getRankEntry(r.clientId, playlistId); // already updated by applyEloUpdates, called before this
    for (const ach of ACHIEVEMENTS) {
      if (entry.achievements.includes(ach.id)) continue;
      if (ach.condition(rank, { itTime: r.itTime, place: r.place, n: lastPlace })) {
        entry.achievements.push(ach.id);
      }
    }
  }
  saveProgression();
}


// ─── Friends ──────────────────────────────────────────────────────────────────
// A player's own clientId doubles as their friend code -- already a stable,
// shareable string (PlayerIdentity.client_id client-side), so there's nothing
// new to generate or manage. Adding a friend is instant and symmetric (no
// request/accept step) -- consistent with every other low-friction, no-
// review trust decision already made elsewhere in this file.
const FRIENDS_JSON_PATH = path.join(DATA_DIR, 'friends.json');
const MAX_FRIENDS_PER_CLIENT = 100;

function loadFriends() {
  try { return JSON.parse(fs.readFileSync(FRIENDS_JSON_PATH, 'utf-8')); }
  catch { return {}; }
}
let friends = loadFriends(); // clientId -> [friendClientId, ...]

function saveFriends() {
  fs.writeFileSync(FRIENDS_JSON_PATH, JSON.stringify(friends));
}

function addFriendPair(a, b) {
  if (!friends[a]) friends[a] = [];
  if (!friends[b]) friends[b] = [];
  if (!friends[a].includes(b)) friends[a].push(b);
  if (!friends[b].includes(a)) friends[b].push(a);
}

// ─── Party (live group queueing) ───────────────────────────────────────────
// A player-client's own persistent WebSocket to the relay (see the
// /relay/party/:clientId endpoint below) -- unlike every other connection in
// this file, this is one a plain player's client keeps open just for being
// in the online menus, not for hosting or joining a match. All state here is
// in-memory only and inherently ephemeral -- a relay restart just means
// everyone's party quietly resets, same as it already does for `servers`.
const parties = new Map();       // partyId -> { id, leaderId, members: Set<clientId>, pendingInvites: Set<clientId> }
const clientParty = new Map();   // clientId -> partyId
const playerSockets = new Map(); // clientId -> { ws, username }
const MAX_PARTY_SIZE = 16;

function partySnapshot(party) {
  return {
    id: party.id,
    leaderId: party.leaderId,
    members: [...party.members].map(id => ({
      clientId: id, username: (playerSockets.get(id) || {}).username || 'Player',
    })),
  };
}

function sendToPlayer(clientId, payload) {
  const entry = playerSockets.get(clientId);
  if (entry && entry.ws.readyState === entry.ws.OPEN) entry.ws.send(JSON.stringify(payload));
}

function broadcastPartyUpdate(party) {
  const snapshot = partySnapshot(party);
  for (const memberId of party.members) sendToPlayer(memberId, { type: 'party_updated', party: snapshot });
}

function sendPartyError(clientId, reason) {
  sendToPlayer(clientId, { type: 'party_error', reason });
}

// Any current member (not just the leader) can invite -- kicking and
// queue-start are leader-only (see below), but pulling in another friend is
// deliberately not gated, same low-friction trust level as everything else
// in this file.
function handlePartyInvite(fromId, targetId) {
  if (!CLIENT_ID_RE.test(targetId) || targetId === fromId) return;
  if (!(friends[fromId] || []).includes(targetId)) { sendPartyError(fromId, 'not_friend'); return; }
  if (!playerSockets.has(targetId)) { sendPartyError(fromId, 'offline'); return; }

  let partyId = clientParty.get(fromId);
  let party = partyId ? parties.get(partyId) : null;
  if (!party) {
    partyId = crypto.randomBytes(8).toString('hex');
    party = { id: partyId, leaderId: fromId, members: new Set([fromId]), pendingInvites: new Set() };
    parties.set(partyId, party);
    clientParty.set(fromId, partyId);
  }
  if (clientParty.get(targetId) === partyId) return; // already in this party
  if (party.members.size + party.pendingInvites.size >= MAX_PARTY_SIZE) { sendPartyError(fromId, 'party_full'); return; }

  party.pendingInvites.add(targetId);
  sendToPlayer(targetId, {
    type: 'party_invite_received', partyId,
    fromClientId: fromId, fromUsername: (playerSockets.get(fromId) || {}).username || 'Player',
  });
}

function handlePartyInviteAccept(clientId, partyId) {
  const party = parties.get(partyId);
  if (!party || !party.pendingInvites.has(clientId)) return;
  party.pendingInvites.delete(clientId);
  if (party.members.size >= MAX_PARTY_SIZE) { sendPartyError(clientId, 'party_full'); return; }
  // Only ever in one party at a time -- accepting a new invite implicitly
  // leaves whatever party this client was already in.
  handlePartyLeave(clientId);
  party.members.add(clientId);
  clientParty.set(clientId, partyId);
  broadcastPartyUpdate(party);
}

function handlePartyInviteDecline(clientId, partyId) {
  const party = parties.get(partyId);
  if (!party || !party.pendingInvites.has(clientId)) return;
  party.pendingInvites.delete(clientId);
  sendToPlayer(party.leaderId, {
    type: 'party_invite_declined',
    targetUsername: (playerSockets.get(clientId) || {}).username || 'Player',
  });
}

function handlePartyLeave(clientId) {
  const partyId = clientParty.get(clientId);
  if (!partyId) return;
  const party = parties.get(partyId);
  clientParty.delete(clientId);
  if (!party) return;
  party.members.delete(clientId);
  sendToPlayer(clientId, { type: 'party_updated', party: null });
  if (party.members.size === 0) {
    parties.delete(partyId);
    return;
  }
  if (party.leaderId === clientId) party.leaderId = [...party.members][0];
  broadcastPartyUpdate(party);
}

function handlePartyKick(fromId, targetId) {
  const partyId = clientParty.get(fromId);
  const party = partyId ? parties.get(partyId) : null;
  if (!party || party.leaderId !== fromId || targetId === fromId || !party.members.has(targetId)) return;
  party.members.delete(targetId);
  clientParty.delete(targetId);
  sendToPlayer(targetId, { type: 'party_kicked' });
  broadcastPartyUpdate(party);
}

// Pure forward -- the leader has already resolved/hosted the actual game
// server exactly like a solo player would (see PartyManager.queue_party on
// the client); this just tells every other member's client to connect+join
// the same place. No party state changes here, and a follower who isn't
// currently connected simply misses it -- party-synced queueing is a
// live-session feature, not an offline queue.
function handlePartyQueueStart(fromId, msg) {
  const partyId = clientParty.get(fromId);
  const party = partyId ? parties.get(partyId) : null;
  if (!party || party.leaderId !== fromId) return;
  const payload = {
    type: 'party_connect_now',
    serverAddress: String(msg.serverAddress || '').slice(0, 256),
    mode: String(msg.mode || '').slice(0, 16),
    playlist: String(msg.playlist || '').slice(0, 16),
  };
  for (const memberId of party.members) {
    if (memberId !== fromId) sendToPlayer(memberId, payload);
  }
}

const servers = new Map();       // serverId -> { id, name, maxPlayers, playerCount, createdAt, lastHeartbeat, controlSocket }
const pendingTokens = new Map(); // token -> { playerSocket, timer }
const rateLimitHits = new Map(); // ip -> [timestamps]

function withinRateLimit(ip) {
  const now = Date.now();
  const hits = (rateLimitHits.get(ip) || []).filter(t => now - t < RATE_LIMIT_WINDOW_MS);
  // Only record a hit for an attempt actually being let through -- recording
  // rejected attempts too meant a client that retries on failure (every
  // caller of this does: PartyManager.gd/RelayClient.gd's reconnect timers,
  // any client-side fetch retry) could never recover once over the limit,
  // since each rejected retry re-armed its own rejection for the next
  // RATE_LIMIT_WINDOW_MS -- a permanent lockout from one brief burst
  // (confirmed live: a handful of reconnects in a short window kept a real
  // client 502'd on /relay/party well past when the original burst aged out).
  if (hits.length >= RATE_LIMIT_MAX) {
    rateLimitHits.set(ip, hits);
    return false;
  }
  hits.push(now);
  rateLimitHits.set(ip, hits);
  return true;
}

// In production every request arrives via the portal's own loopback proxy
// (see webdev/portal/server.js's proxyTagWebSocket/tagRelayProxy), so
// req.socket.remoteAddress is always 127.0.0.1 -- every real player would
// otherwise share one rate-limit bucket. Cloudflare (including through a
// Tunnel) always sets cf-connecting-ip to the real visitor IP, and the
// portal forwards headers through unmodified, so trust it -- but only when
// the immediate hop is our own loopback proxy, never from an arbitrary
// direct connection (this port is bound on all interfaces, not just
// localhost), which would otherwise let anyone spoof the header to dodge
// or target another IP's rate limit.
function clientIpFor(req) {
  const direct = (req.socket.remoteAddress || '').toString();
  if (direct === '127.0.0.1' || direct === '::1' || direct === '::ffff:127.0.0.1') {
    const forwarded = req.headers['cf-connecting-ip'] || req.headers['x-forwarded-for'];
    if (forwarded) return String(forwarded).split(',')[0].trim();
  }
  return direct;
}

function sanitizeName(raw) {
  const trimmed = String(raw || '').trim();
  return (trimmed || 'Unnamed Server').slice(0, MAX_NAME_LEN);
}

// Drop any server whose host stopped heartbeating — this is the only cleanup
// mechanism for crashed/killed hosts (no unregister message will ever arrive).
setInterval(() => {
  const now = Date.now();
  for (const [id, s] of servers) {
    if (now - s.lastHeartbeat > HEARTBEAT_TIMEOUT_MS) servers.delete(id);
  }
}, SWEEP_INTERVAL_MS);

// ─── HTTP: directory + website panel ─────────────────────────────────────────
app.get('/api/servers', (req, res) => {
  res.json([...servers.values()].map(s => ({
    id: s.id, name: s.name, playerCount: s.playerCount, maxPlayers: s.maxPlayers, createdAt: s.createdAt, ranked: !!s.ranked,
    playlist: s.playlist || '',
  })));
});

// Polled by the website's live match viewer (relay-server/public/watch.html)
// -- a low-frequency (~1s), JSON-only echo of what the native client's own
// spectate view gets over the real per-tick WebSocket state push (see
// server_match.gd's _report_state_summary). {players: []} (not 404) when the
// server exists but no match is in progress right now, so the page can
// distinguish "not live yet" from "no such server."
app.get('/api/servers/:id/state', (req, res) => {
  if (!/^[a-f0-9]{16}$/.test(req.params.id)) return res.status(400).json({ error: 'bad server id' });
  const s = servers.get(req.params.id);
  if (!s) return res.status(404).json({ error: 'no such server' });
  res.json(s.matchState || { players: [], timeRemaining: 0, arenaWidth: 0, arenaHeight: 0, levelId: '', updatedAt: 0 });
});

// Small live-activity summary for the landing page (relay-server/public/
// index.html) -- everything here already lives in memory for other
// purposes (the server list, the party system), this just tallies it.
// partiesOnline only counts parties with 2+ members -- a lone leader who
// hasn't been joined by anyone yet isn't really "a party" from a visitor's
// perspective, same reasoning watch.html's own party-badge grouping uses.
app.get('/api/stats', (req, res) => {
  let playersOnline = 0;
  for (const s of servers.values()) playersOnline += s.playerCount;
  let partiesOnline = 0;
  for (const p of parties.values()) if (p.members.size >= 2) partiesOnline++;
  res.json({
    serversOnline: servers.size,
    playersOnline,
    partiesOnline,
    rankedPlayersTracked: Object.keys(progression).length,
  });
});

// Global JSON body parser -- every route from here on that reads req.body
// (levels, friends, auth, game-assets publish) depends on this being
// registered once, up front. 3mb headroom for full-screen background
// publishes (see "HTTP: game assets" below), the biggest body any route
// here ever receives.
app.use(express.json({ limit: '3mb' }));

// ─── HTTP: levels ─────────────────────────────────────────────────────────────
// Live-published, no review step -- same low-friction trust model used
// elsewhere in this file. A level's data is used by the dedicated server
// itself to build real match collision (see game/net/server_match.gd), not
// just rendered client-side -- but it's plain tile-index/coordinate JSON,
// so there's nothing here a level could ever do beyond "place solid tiles
// in weird places" no matter how it was crafted.
function isValidLevelData(data) {
  if (!data || typeof data !== 'object') return false;
  const { tiles, spawn_points: spawns, platforms } = data;
  if (!Array.isArray(tiles) || !Array.isArray(spawns)) return false;
  if (tiles.length > MAX_LEVEL_TILES) return false;
  if (spawns.length < MIN_LEVEL_SPAWN_POINTS || spawns.length > MAX_LEVEL_SPAWN_POINTS) return false;
  for (const t of tiles) {
    if (!Array.isArray(t) || t.length < 3) return false;
    if (typeof t[0] !== 'number' || typeof t[1] !== 'number' || typeof t[2] !== 'number') return false;
    // 11 atlas tiles: 3 base types x 3 art variants (indices 0-8, see
    // build_tileset.gd) plus 2 special behavior tiles appended after them,
    // Ice and Bouncy (indices 9-10, see tile_index()/EXTRA_TILE_NAMES in
    // art_tool.gd). This was previously capped at 8, silently rejecting any
    // publish that placed an Ice or Bouncy tile.
    if (t[2] < 0 || t[2] > 10) return false;
  }
  for (const s of spawns) {
    if (!Array.isArray(s) || s.length < 2) return false;
    if (typeof s[0] !== 'number' || typeof s[1] !== 'number') return false;
  }
  if (platforms !== undefined) {
    if (!Array.isArray(platforms) || platforms.length > MAX_LEVEL_PLATFORMS) return false;
    for (const p of platforms) {
      if (!p || typeof p !== 'object') return false;
      const { start, end, period_sec: period } = p;
      if (!Array.isArray(start) || start.length < 2 || typeof start[0] !== 'number' || typeof start[1] !== 'number') return false;
      if (!Array.isArray(end) || end.length < 2 || typeof end[0] !== 'number' || typeof end[1] !== 'number') return false;
      if (typeof period !== 'number' || period < MIN_PLATFORM_PERIOD_SEC || period > MAX_PLATFORM_PERIOD_SEC) return false;
    }
  }
  return true;
}

app.get('/api/levels/catalog', (req, res) => {
  res.json(readCatalog().filter(e => e.type === 'level'));
});

app.post('/api/levels/:clientId/upload', (req, res) => {
  if (!CLIENT_ID_RE.test(req.params.clientId)) return res.status(400).json({ error: 'bad client id' });
  if (!withinRateLimit(clientIpFor(req))) return res.status(429).json({ error: 'slow down' });

  const clientId = req.params.clientId;
  const existingCount = readCatalog().filter(e => e.createdBy === clientId && e.type === 'level').length;
  if (existingCount >= MAX_LEVELS_PER_CLIENT) {
    return res.status(400).json({ error: `max ${MAX_LEVELS_PER_CLIENT} published levels per client` });
  }

  const name = sanitizeName(req.body.name);
  const data = { tiles: req.body.tiles, spawn_points: req.body.spawn_points };
  // platforms is optional -- only include it at all if the client actually
  // sent one, so older/simpler level uploads keep publishing exactly the
  // same {tiles, spawn_points}-only JSON they always did.
  if (Array.isArray(req.body.platforms) && req.body.platforms.length > 0) {
    data.platforms = req.body.platforms;
  }
  if (!isValidLevelData(data)) return res.status(400).json({ error: 'invalid level data' });
  const json = JSON.stringify(data);
  if (Buffer.byteLength(json) > MAX_LEVEL_UPLOAD_BYTES) return res.status(400).json({ error: 'level too large' });

  const id = 'level_' + crypto.randomBytes(8).toString('hex');
  fs.writeFileSync(path.join(LEVEL_DATA_DIR, id + '.json'), json);
  const catalog = readCatalog();
  catalog.push({ id, name, type: 'level', createdBy: clientId, createdAt: Date.now() });
  fs.writeFileSync(CATALOG_JSON_PATH, JSON.stringify(catalog));
  res.json({ id });
});

app.get('/api/levels/data/:levelId', (req, res) => {
  const levelId = req.params.levelId;
  if (!/^level_[a-f0-9]{16}$/.test(levelId)) return res.status(400).end();
  const dataPath = path.join(LEVEL_DATA_DIR, levelId + '.json');
  if (!fs.existsSync(dataPath)) return res.status(404).end();
  res.set('Content-Type', 'application/json');
  res.set('Cache-Control', 'public, max-age=86400');
  fs.createReadStream(dataPath).pipe(res);
});

// ─── HTTP: game assets (built-in art, not player cosmetics) ───────────────────
// One version counter per category, bumped on every publish -- the client's
// GameAssetUpdater compares these against what it last downloaded (see
// game/net/game_asset_updater.gd) and only fetches a category that actually
// changed.
app.get('/api/game-assets/manifest', (req, res) => {
  res.json(gameAssetsManifest);
});

// Shared by every MULTI_KEY_CATEGORIES entry -- each publishes as a set of
// independent named images (one file per key) rather than a single shared
// atlas the way icons does. Returns an error string, or null on success.
function publishMultiKeyImages(category, keys, images) {
  if (!images || typeof images !== 'object') return 'images required';
  const decoded = {};
  for (const key of keys) {
    if (!images[key]) continue;
    let bytes;
    try { bytes = Buffer.from(String(images[key]), 'base64'); } catch { return `bad image data for ${key}`; }
    if (bytes.length === 0 || bytes.length > MAX_ASSET_UPLOAD_BYTES || !pngDimensions(bytes)) {
      return `image too large, empty, or not a PNG for ${key}`;
    }
    decoded[key] = bytes;
  }
  if (Object.keys(decoded).length === 0) return 'no valid images provided';
  for (const [key, bytes] of Object.entries(decoded)) {
    fs.writeFileSync(path.join(GAME_ASSETS_DIR, category, key + '.png'), bytes);
  }
  return null;
}

app.post('/api/game-assets/:category/publish', (req, res) => {
  const category = req.params.category;
  if (!GAME_ASSET_CATEGORIES.includes(category)) return res.status(404).json({ error: 'unknown category' });
  if (!verifyAssetKey(req.body.key)) return res.status(401).json({ error: 'bad or missing publish key' });
  if (!withinRateLimit(clientIpFor(req))) return res.status(429).json({ error: 'slow down' });

  if (MULTI_KEY_CATEGORIES[category]) {
    const err = publishMultiKeyImages(category, MULTI_KEY_CATEGORIES[category], req.body.images);
    if (err) return res.status(400).json({ error: err });
  } else {
    let bytes;
    try { bytes = Buffer.from(String(req.body.imageBase64 || ''), 'base64'); } catch { return res.status(400).json({ error: 'bad image data' }); }
    if (bytes.length === 0 || bytes.length > MAX_ASSET_UPLOAD_BYTES || !pngDimensions(bytes)) {
      return res.status(400).json({ error: 'image too large, empty, or not a PNG' });
    }
    fs.writeFileSync(path.join(GAME_ASSETS_DIR, category + '.png'), bytes);
  }

  const prevVersion = (gameAssetsManifest[category] && gameAssetsManifest[category].version) || 0;
  gameAssetsManifest[category] = { version: prevVersion + 1, updatedAt: Date.now() };
  saveGameAssetsManifest();
  res.json({ ok: true, version: gameAssetsManifest[category].version });
});

app.get('/api/game-assets/:category/download', (req, res) => {
  const category = req.params.category;
  if (!GAME_ASSET_CATEGORIES.includes(category) || MULTI_KEY_CATEGORIES[category]) return res.status(404).end();
  const imgPath = path.join(GAME_ASSETS_DIR, category + '.png');
  if (!fs.existsSync(imgPath)) return res.status(404).end();
  res.set('Content-Type', 'image/png');
  res.set('Cache-Control', 'no-cache'); // small file, checked rarely (once per launch), always want the latest
  fs.createReadStream(imgPath).pipe(res);
});

app.get('/api/game-assets/:category/:key/download', (req, res) => {
  const category = req.params.category;
  const key = req.params.key;
  const keys = MULTI_KEY_CATEGORIES[category];
  if (!keys || !keys.includes(key)) return res.status(404).end();
  const imgPath = path.join(GAME_ASSETS_DIR, category, key + '.png');
  if (!fs.existsSync(imgPath)) return res.status(404).end();
  res.set('Content-Type', 'image/png');
  res.set('Cache-Control', 'no-cache');
  fs.createReadStream(imgPath).pipe(res);
});

// ─── HTTP: ranked ─────────────────────────────────────────────────────────────
app.get('/api/ranked/:clientId', (req, res) => {
  if (!CLIENT_ID_RE.test(req.params.clientId)) return res.status(400).json({ error: 'bad client id' });
  const playlist = String(req.query.playlist || '');
  const entry = getRankEntry(req.params.clientId, playlist);
  saveRanks(); // getRankEntry may have just created a fresh entry -- persist it so a lookup alone doesn't silently lose a brand-new player's row on restart
  res.json({ elo: entry.elo, tier: tierForElo(entry.elo), wins: entry.wins, losses: entry.losses, matchesPlayed: entry.matchesPlayed, playlist });
});

// Mirrors game/net/server_match.gd's ROUND_DURATION_SEC -- a reported itTime
// can never legitimately exceed one full round, so anything outside this
// range is clamped rather than trusted outright (see report-result below).
const ROUND_DURATION_SEC = 180.0;

// A ranked match's host (any player's client, per the accepted trust model
// above) reports the round's outcome here once it ends. No auth beyond the
// existing rate limiter -- a malicious report can only ever move the
// clientIds it actually names, through the same public Elo formula everyone
// else goes through, so the worst case is a self-serving win/loss report,
// not an arbitrary rating mint. Clamping itTime to a plausible range closes
// the cheapest version of that: reporting an absurd time (negative, or far
// past the round length) to game the it_time-based ranking within one
// report. This doesn't address a fully malicious host lying about placement
// itself -- an accepted, known limitation of this hosted-authority model.
app.post('/api/ranked/report-result', (req, res) => {
  if (!withinRateLimit(clientIpFor(req))) return res.status(429).json({ error: 'slow down' });
  const results = req.body.results;
  if (!Array.isArray(results) || results.length === 0) return res.status(400).json({ error: 'results required' });
  const playlist = String(req.body.playlist || '');
  const clean = [];
  for (const r of results) {
    if (!r || !CLIENT_ID_RE.test(String(r.clientId || ''))) return res.status(400).json({ error: 'bad clientId in results' });
    const place = parseInt(r.place, 10);
    if (!Number.isFinite(place) || place < 1) return res.status(400).json({ error: 'bad place in results' });
    const itTime = Math.min(Math.max(Number(r.itTime) || 0, 0), ROUND_DURATION_SEC);
    clean.push({ clientId: String(r.clientId), itTime, place, username: r.username ? sanitizeName(r.username) : null });
  }
  applyEloUpdates(clean, playlist);
  applyProgressionUpdates(clean, playlist);
  recordMatchHistory(clean, playlist);
  saveProgression();
  res.json({ ok: true });
});

app.get('/api/progression/:clientId', (req, res) => {
  if (!CLIENT_ID_RE.test(req.params.clientId)) return res.status(400).json({ error: 'bad client id' });
  const entry = getProgressionEntry(req.params.clientId);
  saveProgression(); // mirrors GET /api/ranked/:clientId -- a lookup alone shouldn't lose a freshly-created zero-row on restart
  res.json({ xp: entry.xp, level: levelForXp(entry.xp), achievements: achievementList(entry.achievements) });
});

// ─── HTTP: auth (accounts) ────────────────────────────────────────────────────
// Optional -- playing with no account keeps working exactly as before this
// existed (see game/main/login_screen.gd's fallback-on-any-failure behavior).
// This is purely "make progress follow you across devices," not a gate on
// playing at all.
app.post('/api/auth/register', (req, res) => {
  if (!withinRateLimit(clientIpFor(req))) return res.status(429).json({ error: 'slow down' });
  const username = String(req.body.username || '').trim();
  const password = String(req.body.password || '');
  const clientId = String(req.body.clientId || '');
  if (!USERNAME_RE.test(username)) return res.status(400).json({ error: 'username must be 3-20 letters, numbers, or underscores' });
  if (password.length < MIN_PASSWORD_LEN) return res.status(400).json({ error: `password must be at least ${MIN_PASSWORD_LEN} characters` });
  if (!CLIENT_ID_RE.test(clientId)) return res.status(400).json({ error: 'bad client id' });
  const usernameLower = username.toLowerCase();
  if (findAccountByUsername(usernameLower)) return res.status(400).json({ error: 'username already taken' });

  const accountId = crypto.randomBytes(16).toString('hex');
  const salt = crypto.randomBytes(16).toString('hex');
  accounts[accountId] = {
    username, usernameLower, salt,
    passwordHash: hashPassword(password, salt),
    primaryClientId: clientId,
    createdAt: Date.now(),
  };
  saveAccounts();
  res.json({ token: createSession(accountId), primaryClientId: clientId });
});

app.post('/api/auth/login', (req, res) => {
  if (!withinRateLimit(clientIpFor(req))) return res.status(429).json({ error: 'slow down' });
  const usernameLower = String(req.body.username || '').trim().toLowerCase();
  const password = String(req.body.password || '');
  const found = findAccountByUsername(usernameLower);
  if (!found || !verifyPassword(password, found[1].salt, found[1].passwordHash)) {
    return res.status(401).json({ error: 'invalid username or password' });
  }
  const [accountId, account] = found;
  res.json({ token: createSession(accountId), primaryClientId: account.primaryClientId });
});

app.get('/api/auth/me', (req, res) => {
  const token = getBearerToken(req);
  const session = token ? sessions[token] : null;
  if (!session || session.expiresAt < Date.now()) return res.status(401).json({ error: 'not logged in' });
  const account = accounts[session.accountId];
  if (!account) return res.status(401).json({ error: 'account not found' });
  res.json({ username: account.username, primaryClientId: account.primaryClientId });
});

// ─── HTTP: friends ────────────────────────────────────────────────────────────
app.post('/api/friends/:clientId/add', (req, res) => {
  if (!CLIENT_ID_RE.test(req.params.clientId)) return res.status(400).json({ error: 'bad client id' });
  if (!withinRateLimit(clientIpFor(req))) return res.status(429).json({ error: 'slow down' });
  const clientId = req.params.clientId;
  const friendCode = String(req.body.friendCode || '');
  if (!CLIENT_ID_RE.test(friendCode)) return res.status(400).json({ error: 'bad friend code' });
  if (friendCode === clientId) return res.status(400).json({ error: "can't add yourself" });
  if ((friends[clientId] || []).length >= MAX_FRIENDS_PER_CLIENT) {
    return res.status(400).json({ error: `max ${MAX_FRIENDS_PER_CLIENT} friends` });
  }
  addFriendPair(clientId, friendCode);
  saveFriends();
  res.json({ ok: true });
});

// Cross-references each friend's clientId against every live server's own
// heartbeat-reported roster (servers Map, see the heartbeat handler below)
// to answer "is my friend online, and where" -- purely a live, in-memory
// lookup, nothing persisted beyond the friend list itself.
app.get('/api/friends/:clientId', (req, res) => {
  if (!CLIENT_ID_RE.test(req.params.clientId)) return res.status(400).json({ error: 'bad client id' });
  const list = friends[req.params.clientId] || [];
  const liveServers = [...servers.values()];
  const out = list.map(friendId => {
    const server = liveServers.find(s => (s.clientIds || []).includes(friendId));
    const progressionEntry = progression[friendId];
    return {
      clientId: friendId,
      username: (progressionEntry && progressionEntry.username) || null,
      online: !!server,
      serverId: server ? server.id : null,
      serverName: server ? server.name : null,
    };
  });
  res.json(out);
});

// ─── HTTP: leaderboard + profiles ──────────────────────────────────────────────
app.get('/api/leaderboard', (req, res) => {
  const limit = Math.min(100, Math.max(1, parseInt(req.query.limit, 10) || 50));
  const playlist = String(req.query.playlist || '');
  const rows = [];
  for (const [clientId, byPlaylist] of Object.entries(ranks)) {
    const r = byPlaylist[playlist];
    if (!r) continue; // never played this specific playlist -- not on its leaderboard
    rows.push({
      clientId,
      username: (progression[clientId] && progression[clientId].username) || null,
      elo: r.elo, tier: tierForElo(r.elo), wins: r.wins, losses: r.losses, matchesPlayed: r.matchesPlayed,
    });
  }
  rows.sort((a, b) => b.elo - a.elo);
  res.json(rows.slice(0, limit));
});

app.get('/api/profile/:clientId', (req, res) => {
  if (!CLIENT_ID_RE.test(req.params.clientId)) return res.status(400).json({ error: 'bad client id' });
  const clientId = req.params.clientId;
  const prog = getProgressionEntry(clientId);
  const recentMatches = (prog.recentMatches || []).map(matchId => {
    try { return JSON.parse(fs.readFileSync(path.join(MATCHES_DIR, matchId + '.json'), 'utf-8')); }
    catch { return null; }
  }).filter(Boolean);
  // Every playlist this player has a rank in (Rocket-League-style profile:
  // one rank per playlist shown side by side), not just a single number --
  // ranks[clientId] is {} for a player who's never played a ranked match.
  const byPlaylist = ranks[clientId] || {};
  const playlistRanks = {};
  for (const [playlistId, r] of Object.entries(byPlaylist)) {
    playlistRanks[playlistId] = { elo: r.elo, tier: tierForElo(r.elo), wins: r.wins, losses: r.losses, matchesPlayed: r.matchesPlayed };
  }
  res.json({
    clientId, username: prog.username,
    ranks: playlistRanks,
    xp: prog.xp, level: levelForXp(prog.xp), achievements: achievementList(prog.achievements),
    recentMatches,
  });
});

let _indexHtmlCache = null;
app.get('/', (req, res) => {
  if (!_indexHtmlCache) {
    const html = fs.readFileSync(path.join(__dirname, 'public', 'index.html'), 'utf-8');
    _indexHtmlCache = html.replace('</head>', `<script>window.__BASE_PATH__=${JSON.stringify(BASE_PATH)};</script></head>`);
  }
  // Without this, a plain res.send() carries only an auto-generated ETag
  // and no freshness info at all -- enough for some browsers to serve an
  // old cached copy of this exact page (with whatever __BASE_PATH__ value
  // happened to be injected at the time it was first cached) indefinitely
  // without ever re-checking the server, which is indistinguishable from
  // "the site is broken" to whoever's looking at a stale tab. This page is
  // tiny and re-fetching it on every visit costs nothing.
  res.set('Cache-Control', 'no-store');
  res.send(_indexHtmlCache);
});
app.use(express.static(path.join(__dirname, 'public'), { etag: false, lastModified: false, cacheControl: false, setHeaders: res => res.set('Cache-Control', 'no-store') }));

realApp.use(BASE_PATH || '/', app);

const server = http.createServer(realApp);
// perMessageDeflate: false -- the portal's http-proxy-middleware WS proxy
// doesn't correctly relay permessage-deflate-compressed frames (every
// connection through it fails immediately with "Invalid WebSocket frame:
// RSV1 must be clear", confirmed by bypassing it entirely and connecting
// directly, which works fine). Disabling compression negotiation here means
// the extension is never offered in the handshake, so neither side ever
// sets the RSV1 bit and the proxy has nothing to corrupt.
const wss = new WebSocketServer({ noServer: true, maxPayload: MAX_PAYLOAD_BYTES, perMessageDeflate: false });

// ─── WebSocket relay ──────────────────────────────────────────────────────────
// Three logical endpoints, dispatched by hand off the raw HTTP server's
// 'upgrade' event (mirrors the pattern in webdev/portal/server.js):
//   {BASE_PATH}/relay/host          - a hosting Tag-Server's control channel
//   {BASE_PATH}/relay/data/:token   - the host dials this per player, on request
//   {BASE_PATH}/relay/join/:serverId - a player's client dials this to connect
server.on('upgrade', (req, socket, head) => {
  const ip = clientIpFor(req);
  let pathname;
  try {
    pathname = new URL(req.url, 'http://relay').pathname;
  } catch {
    socket.destroy();
    return;
  }
  if (BASE_PATH) {
    if (!pathname.startsWith(BASE_PATH)) { socket.destroy(); return; }
    pathname = pathname.slice(BASE_PATH.length) || '/';
  }

  if (pathname === '/relay/host') {
    if (!withinRateLimit(ip)) { socket.destroy(); return; }
    wss.handleUpgrade(req, socket, head, ws => handleHostControl(ws));
    return;
  }
  const dataMatch = pathname.match(/^\/relay\/data\/([a-f0-9]{64})$/);
  if (dataMatch) {
    wss.handleUpgrade(req, socket, head, ws => handleHostData(ws, dataMatch[1]));
    return;
  }
  const joinMatch = pathname.match(/^\/relay\/join\/([a-f0-9]+)$/);
  if (joinMatch) {
    if (!withinRateLimit(ip)) { socket.destroy(); return; }
    wss.handleUpgrade(req, socket, head, ws => handlePlayerJoin(ws, joinMatch[1]));
    return;
  }
  // A player's own client, held open for as long as it's in the online
  // menus -- distinct from /relay/join above (that's the actual gameplay
  // tunnel to a specific server; this is party invite/roster/queue-together
  // traffic, unrelated to any one match). clientId lives in the URL, same
  // pattern as /relay/data/:token above, so there's no separate identify
  // round-trip needed before the relay knows who's on the other end.
  const partyMatch = pathname.match(/^\/relay\/party\/([a-f0-9-]{8,64})$/i);
  if (partyMatch) {
    if (!withinRateLimit(ip)) { socket.destroy(); return; }
    wss.handleUpgrade(req, socket, head, ws => handlePlayerParty(ws, partyMatch[1]));
    return;
  }
  // The website's live match viewer (watch.html) -- read-only, no rate
  // limit beyond the connection itself (a spectator can't affect anything,
  // same trust level as the native client's own spectate path).
  const watchMatch = pathname.match(/^\/watch\/([a-f0-9]{16})$/);
  if (watchMatch) {
    wss.handleUpgrade(req, socket, head, ws => handleBrowserWatch(ws, watchMatch[1]));
    return;
  }
  socket.destroy();
});

// serverId -> Set<WebSocket> -- browsers currently watching that server's
// live match state, pushed to immediately as each "match_state" message
// arrives on that server's own control channel (see handleHostControl)
// rather than making every open tab poll for it.
const watchers = new Map();

function handleBrowserWatch(ws, serverId) {
  if (!watchers.has(serverId)) watchers.set(serverId, new Set());
  watchers.get(serverId).add(ws);
  // Send whatever's already known immediately -- otherwise a browser that
  // connects between two server reports sits with a blank view for up to
  // MATCH_STATE_INTERVAL_SEC (relay_client.gd) before its first update.
  const s = servers.get(serverId);
  if (s && s.matchState) ws.send(JSON.stringify({ type: 'match_state', ...s.matchState }));
  ws.on('close', () => {
    const set = watchers.get(serverId);
    if (set) { set.delete(ws); if (set.size === 0) watchers.delete(serverId); }
  });
}

function broadcastMatchState(serverId, matchState) {
  const set = watchers.get(serverId);
  if (!set || set.size === 0) return;
  const payload = JSON.stringify({ type: 'match_state', ...matchState });
  for (const ws of set) {
    if (ws.readyState === ws.OPEN) ws.send(payload);
  }
}

function handleHostControl(ws) {
  let serverId = null;

  ws.on('message', raw => {
    let msg;
    try { msg = JSON.parse(raw.toString()); } catch { return; }

    if (msg.type === 'register') {
      if (serverId) return; // already registered on this socket -- ignore repeats
      serverId = crypto.randomBytes(8).toString('hex');
      servers.set(serverId, {
        id: serverId,
        name: sanitizeName(msg.name),
        maxPlayers: Math.max(1, Math.min(64, parseInt(msg.maxPlayers, 10) || 16)),
        playerCount: 0,
        ranked: !!msg.ranked,
        playlist: String(msg.playlist || ''),
        createdAt: Date.now(),
        lastHeartbeat: Date.now(),
        controlSocket: ws,
      });
      ws.send(JSON.stringify({ type: 'registered', serverId }));
    } else if (msg.type === 'heartbeat') {
      if (!serverId || !servers.has(serverId)) return;
      const s = servers.get(serverId);
      s.lastHeartbeat = Date.now();
      s.playerCount = Math.max(0, parseInt(msg.playerCount, 10) || 0);
      // Roster of who's currently connected here, so /api/friends/:clientId
      // can answer "is my friend online, and where" -- silently dropped
      // (not an error) if malformed, same tolerance-for-a-bad-field
      // approach as playerCount above, since a heartbeat's job is to keep
      // the server listed, not to hard-fail on one odd field.
      s.clientIds = Array.isArray(msg.clientIds) ? msg.clientIds.filter(id => CLIENT_ID_RE.test(String(id))).slice(0, 64) : [];
    } else if (msg.type === 'match_state') {
      // Live-ish snapshot for the website's match viewer (see relay-server/
      // public/watch.html) -- sent every ~1s by relay_client.gd while a
      // match is in progress, separate from the heartbeat above. Loosely
      // validated (this is trusted, already-registered infrastructure
      // traffic, not arbitrary client input) but still bounded/typed so a
      // malformed message can't wedge a bad value into what the website
      // reads back out.
      if (!serverId || !servers.has(serverId)) return;
      const s = servers.get(serverId);
      const players = Array.isArray(msg.players) ? msg.players.slice(0, MAX_LOBBY_PLAYERS).map(p => ({
        clientId: typeof p.clientId === 'string' ? p.clientId.slice(0, 64) : '',
        username: sanitizeName(p.username),
        x: typeof p.x === 'number' ? p.x : 0,
        y: typeof p.y === 'number' ? p.y : 0,
        isIt: !!p.isIt,
        colorId: typeof p.colorId === 'string' ? p.colorId.slice(0, 32) : 'red',
        facing: p.facing === -1 ? -1 : 1,
        // -1 = no team-mode playlist active for this match (see
        // server_match.gd's identical default) -- only ever 0/1 otherwise.
        team: (p.team === 0 || p.team === 1) ? p.team : -1,
        partyId: typeof p.partyId === 'string' ? p.partyId.slice(0, 64) : '',
      })) : [];
      s.matchState = {
        players,
        timeRemaining: typeof msg.timeRemaining === 'number' ? msg.timeRemaining : 0,
        arenaWidth: typeof msg.arenaWidth === 'number' ? msg.arenaWidth : 0,
        arenaHeight: typeof msg.arenaHeight === 'number' ? msg.arenaHeight : 0,
        arenaCenterX: typeof msg.arenaCenterX === 'number' ? msg.arenaCenterX : 0,
        arenaCenterY: typeof msg.arenaCenterY === 'number' ? msg.arenaCenterY : 0,
        levelId: typeof msg.levelId === 'string' ? msg.levelId.slice(0, 64) : '',
        updatedAt: Date.now(),
      };
      broadcastMatchState(serverId, s.matchState);
    } else if (msg.type === 'unregister') {
      if (serverId) servers.delete(serverId);
    }
  });

  ws.on('close', () => {
    // The control channel dying doesn't touch already-spliced player<->host
    // data sessions (those are independent sockets) — it just means new
    // joins can't be requested until either a reconnect re-registers, or the
    // heartbeat sweep above expires the stale listing.
    if (serverId && servers.has(serverId)) servers.get(serverId).controlSocket = null;
  });
}

function handlePlayerJoin(ws, serverId) {
  const s = servers.get(serverId);
  if (!s || !s.controlSocket || s.controlSocket.readyState !== s.controlSocket.OPEN) {
    ws.close(4404, 'server offline');
    return;
  }
  const token = crypto.randomBytes(32).toString('hex');
  const timer = setTimeout(() => {
    if (pendingTokens.delete(token)) ws.close(4408, 'host did not respond');
  }, JOIN_TIMEOUT_MS);
  pendingTokens.set(token, { playerSocket: ws, timer });
  ws.on('close', () => {
    const pending = pendingTokens.get(token);
    if (pending && pending.playerSocket === ws) {
      clearTimeout(pending.timer);
      pendingTokens.delete(token);
    }
  });
  s.controlSocket.send(JSON.stringify({ type: 'connect_request', token }));
}

function handlePlayerParty(ws, clientId) {
  playerSockets.set(clientId, { ws, username: 'Player' });
  // A client re-connecting (brief drop, page refresh-equivalent) picks its
  // current party state back up immediately rather than starting blank.
  const existingPartyId = clientParty.get(clientId);
  if (existingPartyId && parties.has(existingPartyId)) {
    sendToPlayer(clientId, { type: 'party_updated', party: partySnapshot(parties.get(existingPartyId)) });
  }

  ws.on('message', raw => {
    let msg;
    try { msg = JSON.parse(raw.toString()); } catch { return; }
    if (msg.type === 'player_identify') {
      const entry = playerSockets.get(clientId);
      if (entry) entry.username = sanitizeName(msg.username);
    } else if (msg.type === 'party_invite') {
      handlePartyInvite(clientId, String(msg.targetClientId || ''));
    } else if (msg.type === 'party_invite_accept') {
      handlePartyInviteAccept(clientId, String(msg.partyId || ''));
    } else if (msg.type === 'party_invite_decline') {
      handlePartyInviteDecline(clientId, String(msg.partyId || ''));
    } else if (msg.type === 'party_leave') {
      handlePartyLeave(clientId);
    } else if (msg.type === 'party_kick') {
      handlePartyKick(clientId, String(msg.targetClientId || ''));
    } else if (msg.type === 'party_queue_start') {
      handlePartyQueueStart(clientId, msg);
    }
  });

  ws.on('close', () => {
    const entry = playerSockets.get(clientId);
    if (entry && entry.ws === ws) {
      playerSockets.delete(clientId);
      handlePartyLeave(clientId);
    }
  });
}

function handleHostData(ws, token) {
  // Map.delete both enforces single-use and rejects a duplicate/stale token
  // in one step — a second socket presenting the same token finds nothing.
  const pending = pendingTokens.get(token);
  if (!pending) { ws.close(4410, 'invalid or expired token'); return; }
  pendingTokens.delete(token);
  clearTimeout(pending.timer);
  splice(pending.playerSocket, ws);
}

// Pure byte-forwarding in both directions — the relay has no idea it's
// carrying Godot multiplayer traffic, it just pipes frames.
function splice(a, b) {
  const pipe = (from, to) => {
    from.on('message', data => { if (to.readyState === to.OPEN) to.send(data); });
    from.on('close', () => { if (to.readyState === to.OPEN) to.close(); });
    from.on('error', () => { try { to.close(); } catch {} });
  };
  pipe(a, b);
  pipe(b, a);
}

server.listen(PORT, () => {
  console.log(`\n  Tag relay running at http://localhost:${PORT}${BASE_PATH}`);
});
