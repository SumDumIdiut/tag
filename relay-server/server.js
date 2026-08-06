const express = require('express');
const http = require('http');
const https = require('https');
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
// Cloudflare Realtime TURN key -- set on terraserver only (start_tag_relay()
// sources it from $HOME/.tag-secrets.env, never from anything git-tracked).
// Lets game clients get real STUN+TURN ICE servers without this process
// ever handing out the long-lived API token itself -- see /api/webrtc/turn-credentials.
const TURN_KEY_ID = process.env.TURN_KEY_ID || '';
const TURN_API_TOKEN = process.env.TURN_API_TOKEN || '';

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
// Two separate budgets, tracked independently per IP -- WS connection setup
// (hosting/joining a match, or the party channel that opens any time a
// player is just sitting in the online menus) happens automatically and
// often during completely normal play (browsing servers, joining, backing
// out, trying another), so it needs a much more generous budget than the
// handful of deliberate HTTP actions (registering, logging in, adding a
// friend, publishing an asset, reporting a ranked result). These used to
// share ONE 5-per-60s bucket -- confirmed live that normal navigation alone
// (which opens/reopens the party WS and a match join/host WS) could exhaust
// it before a player ever got to click "Add Friend" or finish creating an
// account, surfacing as an unexplained "slow down" on an unrelated action.
const RATE_LIMIT_ACTION_MAX = 20;
const RATE_LIMIT_CONNECT_MAX = 60;

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
// A level's own optional texture library (see the web level editor at
// public/level-editor.html's Textures panel) -- any number of uploaded
// images, each independently dragged onto the layout as however many
// placed copies the level actually wants (a "placement": which library
// texture, where, how big). Caps here bound the library itself; MAX_LEVEL_
// PLACEMENTS below bounds how many times those textures get placed.
const MAX_LEVEL_TEXTURES = 12;
const MAX_LEVEL_TEXTURE_BYTES = 512 * 1024;
const MAX_LEVEL_PLACEMENTS = 200;
const MAX_PLACEMENT_COORD = 2000; // generous grid-cell bound (the grid itself is 60x40) -- just an abuse guard
// A level's optional backdrop (fills the whole camera view behind
// everything, see LevelData.build_arena_from_data()) and its optional
// catalog thumbnail (shown in Local's map grid / the vote screen instead
// of a generic placeholder icon) -- each just one image, not a library
// like textures, so no separate MAX_COUNT needed.
const MAX_LEVEL_BACKGROUND_BYTES = 1024 * 1024;
const MAX_LEVEL_THUMBNAIL_BYTES = 256 * 1024;

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
const GAME_ASSET_CATEGORIES = ['icons', 'chrome', 'platform', 'playlist_thumbnails', 'backgrounds', 'button_art'];
// The app's shared button/panel/slider box art.
const CHROME_KEYS = ['button', 'panel', 'slider_groove', 'slider_fill'];
// The 3 tiles a MovingPlatform assembles itself from left-to-right (see
// game/levels/moving_platform.gd) -- always exactly 3 tiles, no auto-tiling.
const PLATFORM_KEYS = ['left', 'middle', 'right'];
// SYNC: mirrors game/net/game_asset_categories.gd's PLAYLIST_THUMBNAIL_KEYS
// (itself mirroring game/net/playlist_catalog.gd's PLAYLIST_ORDER).
const PLAYLIST_THUMBNAIL_KEYS = ['1v1', '2v2', '1v1v1', '1v1v1v1'];
// SYNC: mirrors game/net/game_asset_categories.gd's BACKGROUND_KEYS -- one
// per screen that calls UIStyle.add_background()/add_glow_background().
// casual_playlist_select/ranked_playlist_select deliberately reuse
// "casual_queue"/"ranked_queue" rather than getting their own keys.
const BACKGROUND_KEYS = [
  'main_menu', 'online_menu', 'local_menu', 'casual_queue', 'ranked_queue',
  'lobby_room', 'achievements_menu', 'friends_menu', 'login_screen',
  'match_intro', 'match_intro_ranked', 'match_results',
];
// SYNC: mirrors game/net/game_asset_categories.gd's BUTTON_ART_KEYS -- one
// optional per-button art override per individually-registered Button, keyed
// by the SAME "screen.shortkey" strings the ui-layout override system uses
// as layout_key (not a separate namespace). Deliberately excludes playlist
// cards -- those already have their own richer per-id art via
// PLAYLIST_THUMBNAIL_KEYS above.
const BUTTON_ART_KEYS = [
  'main_menu.online_button', 'main_menu.local_button',
  'main_menu.account_button', 'main_menu.achievements_button',
  'online_menu.casual_button', 'online_menu.ranked_button',
  'online_menu.private_button', 'online_menu.friends_button', 'online_menu.back_button',
  'local_menu.start_button', 'local_menu.back_button',
  'casual_playlist_select.back_button', 'ranked_playlist_select.back_button',
  'casual_queue.back_button', 'casual_queue.cancel_button',
  'ranked_queue.back_button', 'ranked_queue.cancel_button',
  'lobby_room.ready_button', 'lobby_room.start_button', 'lobby_room.leave_button',
  'achievements_menu.back_button',
  'friends_menu.copy_button', 'friends_menu.add_button', 'friends_menu.back_button',
  'login_screen.back_button', 'login_screen.login_button',
  'login_screen.register_button', 'login_screen.logout_button',
  'match_intro.skip_button',
  'match_results.continue_button',
  'pause_menu.resume_button', 'pause_menu.menu_button',
];
// Categories that publish as one file per key (like a per-key subfolder)
// rather than a single shared atlas image (like icons/tiles) -- maps each
// to its key list so the publish/download routes below don't need one
// hand-written branch per category.
const MULTI_KEY_CATEGORIES = {
  chrome: CHROME_KEYS,
  platform: PLATFORM_KEYS,
  playlist_thumbnails: PLAYLIST_THUMBNAIL_KEYS,
  backgrounds: BACKGROUND_KEYS,
  button_art: BUTTON_ART_KEYS,
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

// An account's primaryClientId can carry a manually-set `isCreator: true`
// (set directly in accounts.json, no signup-flow path to it) to pin its
// displayed tier to 'Creator' regardless of its actual elo -- unlike the
// old approach of just parking that one account's elo above MAX_ELO, this
// keeps its elo a normal, honestly-earned/reset number that sorts into its
// real position on the leaderboard, while the tier badge stays fixed.
function isCreatorClientId(clientId) {
  for (const account of Object.values(accounts)) {
    if (account.primaryClientId === clientId && account.isCreator) return true;
  }
  return false;
}

function tierFor(clientId, elo) {
  return isCreatorClientId(clientId) ? 'Creator' : tierForElo(elo);
}

// Prefer an account's real (login) username over progression[clientId]'s
// own username field wherever a clientId's display name is shown to other
// players (friends list, profile, leaderboard). progression's username is
// just whatever the client last self-reported over an unauthenticated
// channel (a match-result report, or the party socket's initial message,
// see applyProgressionUpdates()/handlePlayerParty() below) -- it predates
// the account system and never gets updated by logging into an account,
// so a player who signed up after already having played under some other
// name (or a shared/reused clientId, e.g. from local testing) would show
// that old name to friends forever, with no way to fix it client-side.
function accountUsernameFor(clientId) {
  for (const account of Object.values(accounts)) {
    if (account.primaryClientId === clientId) return account.username;
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
const FRIEND_REQUESTS_JSON_PATH = path.join(DATA_DIR, 'friend_requests.json');
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

function loadFriendRequests() {
  try { return JSON.parse(fs.readFileSync(FRIEND_REQUESTS_JSON_PATH, 'utf-8')); }
  catch { return {}; }
}
// targetClientId -> [requesterClientId, ...] -- pending incoming requests,
// keyed by the person who'd need to accept/decline them. Persisted (not
// just pushed live over the party socket) so a request sent while the
// target is offline is still there for them to see/act on next time they
// open the Friends screen, not lost the moment the tab they'd have popped
// up in was never open.
let friendRequests = loadFriendRequests();

function saveFriendRequests() {
  fs.writeFileSync(FRIEND_REQUESTS_JSON_PATH, JSON.stringify(friendRequests));
}

function friendRequestSnapshot(clientId) {
  return (friendRequests[clientId] || []).map(fromId => ({
    clientId: fromId, username: accountUsernameFor(fromId) || (progression[fromId] && progression[fromId].username) || null,
  }));
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
// How long a dropped party socket gets to reconnect under the same
// clientId before actually being treated as "left the party" -- see
// handlePlayerParty's ws.on('close') below. Comfortably longer than
// party_manager.gd's own RECONNECT_DELAY_SEC (5s) plus real connect+
// identify time, short enough that a genuinely-gone player still leaves
// in a reasonable window.
const PARTY_DISCONNECT_GRACE_MS = 15000;
const pendingPartyDisconnects = new Map(); // clientId -> Timeout

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

// Accept/decline mirror the party invite pair above (WS-delivered, same
// live-popup path client-side) rather than going through the HTTP add
// route again -- the requester already made their ask over HTTP; this is
// the target responding to it, which (like party invite responses) only
// ever needs to happen while connected to react to a live popup.
function handleFriendRequestAccept(clientId, fromId) {
  const pending = friendRequests[clientId] || [];
  const idx = pending.indexOf(fromId);
  if (idx === -1) return;
  pending.splice(idx, 1);
  addFriendPair(clientId, fromId);
  saveFriendRequests();
  saveFriends();
  sendToPlayer(fromId, {
    type: 'friend_request_accepted',
    targetUsername: (playerSockets.get(clientId) || {}).username || 'Player',
  });
}

function handleFriendRequestDecline(clientId, fromId) {
  const pending = friendRequests[clientId] || [];
  const idx = pending.indexOf(fromId);
  if (idx === -1) return;
  pending.splice(idx, 1);
  saveFriendRequests();
  sendToPlayer(fromId, {
    type: 'friend_request_declined',
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

// PartyManager's socket connects once at boot under whatever client_id was
// current then (near-guaranteed to be the local-device id, since login
// resolves asynchronously) -- when a session restore later adopts the
// account's real id, that client reconnects under the new one (see
// party_manager.gd's _on_client_id_changed). Without this, the OLD
// socket's own disconnect hit this same server's ws.on('close') handler
// (see handlePlayerParty below), which calls handlePartyLeave for the OLD
// id -- for a leader, that silently hands leadership to whoever else was
// in the party and drops this client out of it entirely, while the NEW
// (correctly-identified) socket never gets associated with any party at
// all, since clientParty has no entry for an id it's never seen. The
// client now sends this BEFORE tearing the old socket down, so party
// membership/leadership carries over to the new id atomically instead of
// the old socket's close ever being treated as a real "left the party".
function handleIdentityMigrate(oldId, newId) {
  if (!CLIENT_ID_RE.test(newId) || newId === oldId) return;
  const partyId = clientParty.get(oldId);
  if (!partyId) return;
  const party = parties.get(partyId);
  if (!party || !party.members.has(oldId)) return;
  party.members.delete(oldId);
  party.members.add(newId);
  clientParty.delete(oldId);
  clientParty.set(newId, partyId);
  if (party.leaderId === oldId) party.leaderId = newId;
  if (party.pendingInvites.has(oldId)) {
    party.pendingInvites.delete(oldId);
    party.pendingInvites.add(newId);
  }
  broadcastPartyUpdate(party);
}

const PARTY_QUEUE_PRIVATE_RESOLVE_RETRIES = 5;
const PARTY_QUEUE_PRIVATE_RESOLVE_DELAY_MS = 500;

// Mostly a pure forward -- the leader has already resolved/hosted the
// actual game server exactly like a solo player would (see
// PartyManager.queue_party on the client); this just tells every other
// member's client to connect+join the same place. No party state changes
// here, and a follower who isn't currently connected simply misses it --
// party-synced queueing is a live-session feature, not an offline queue.
//
// "private" is the one exception: msg.serverAddress there carries the
// server's own registered NAME, not a connectable address -- unlisted
// (private) servers are deliberately excluded from the public
// /api/servers directory (see that route's own comment: it's what
// index.html's public server browser and casual/ranked matchmaking both
// read, and a private match showing up there with a working join link
// would defeat the entire point of "private"). A follower's client can't
// resolve the name itself the way ranked/casual followers already do by
// searching that same public endpoint, so this process resolves it here
// instead, against its own full view of `servers` (which does include
// unlisted ones) -- followers only ever receive a bare relay server id
// back, never the private server's name/existence exposed anywhere public.
// Retried a few times with a short delay: the leader's own client can
// reach this point (having just connected to their own freshly-spawned
// server over a fast loopback hop) before that same server's OWN
// RelayClient has finished its own, separate, real-network registration
// round-trip with this relay -- a genuine race, not a hypothetical one.
function handlePartyQueueStart(fromId, msg, attempt = 0) {
  const partyId = clientParty.get(fromId);
  const party = partyId ? parties.get(partyId) : null;
  if (!party || party.leaderId !== fromId) return;
  const mode = String(msg.mode || '').slice(0, 16);
  let serverAddress = String(msg.serverAddress || '').slice(0, 256);
  let transport = null;
  if (mode === 'private') {
    const match = [...servers.values()].find(s => s.unlisted && s.name === serverAddress);
    if (!match) {
      if (attempt < PARTY_QUEUE_PRIVATE_RESOLVE_RETRIES) {
        setTimeout(() => handlePartyQueueStart(fromId, msg, attempt + 1), PARTY_QUEUE_PRIVATE_RESOLVE_DELAY_MS);
      }
      return;
    }
    serverAddress = match.id;
    transport = match.transport || 'ws';
  }
  // Private is the only mode resolved server-side (see above) -- ranked/
  // casual followers re-resolve via /api/servers themselves (already
  // carries transport), so transport is only meaningful/sent for private.
  const payload = {
    type: 'party_connect_now',
    serverAddress,
    mode,
    playlist: String(msg.playlist || '').slice(0, 16),
    transport,
  };
  for (const memberId of party.members) {
    if (memberId !== fromId) sendToPlayer(memberId, payload);
  }
}

const servers = new Map();       // serverId -> { id, name, maxPlayers, playerCount, createdAt, lastHeartbeat, controlSocket }
const pendingTokens = new Map(); // token -> { playerSocket, timer }
const rateLimitHits = new Map(); // ip -> [timestamps]

// `category` keeps the action-budget and connect-budget counting
// completely independently per IP, even though they share the same
// underlying Map -- without it, generous-budget connect hits would still
// crowd out the tighter action budget by filling the same timestamp array.
function withinRateLimit(category, ip, max) {
  const key = `${category}:${ip}`;
  const now = Date.now();
  const hits = (rateLimitHits.get(key) || []).filter(t => now - t < RATE_LIMIT_WINDOW_MS);
  // Only record a hit for an attempt actually being let through -- recording
  // rejected attempts too meant a client that retries on failure (every
  // caller of this does: PartyManager.gd/RelayClient.gd's reconnect timers,
  // any client-side fetch retry) could never recover once over the limit,
  // since each rejected retry re-armed its own rejection for the next
  // RATE_LIMIT_WINDOW_MS -- a permanent lockout from one brief burst
  // (confirmed live: a handful of reconnects in a short window kept a real
  // client 502'd on /relay/party well past when the original burst aged out).
  if (hits.length >= max) {
    rateLimitHits.set(key, hits);
    return false;
  }
  hits.push(now);
  rateLimitHits.set(key, hits);
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
// Excludes unlisted (private) servers entirely -- this is what index.html's
// public server browser reads (complete with a working "copy connect
// link" button) and what casual/ranked matchmaking auto-picks the
// fullest open server from, so a private match showing up here at all
// would defeat the point of "private" regardless of what any individual
// caller does with the field. A party member following their leader into
// a private match doesn't go through this endpoint -- see
// handlePartyQueueStart's own resolution, which uses this process's full
// (unfiltered) view instead.
app.get('/api/servers', (req, res) => {
  res.json([...servers.values()].filter(s => !s.unlisted).map(s => ({
    id: s.id, name: s.name, playerCount: s.playerCount, maxPlayers: s.maxPlayers, createdAt: s.createdAt, ranked: !!s.ranked,
    playlist: s.playlist || '', transport: s.transport || 'ws',
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
  if (!isValidPlacements(data.placements)) return false;
  return true;
}

// `placements` (see public/level-editor.html's Textures panel: drag a
// library texture onto the layout to add one of these) is optional -- a
// level with no images at all just omits it, same as platforms. Each entry
// is {textureIndex, x, y, width, height}: which uploaded texture (by
// position in the level's own texturesBase64 array, checked against that
// array's actual length in the upload handler below, where it's in scope --
// this function alone can't know how many textures were actually
// uploaded), where its center sits and how big it renders, all in
// grid-cell-relative units (not canvas-pixel, not world-pixel -- see
// level-editor.html's own comment on its publish handler for why: this
// keeps a placement's apparent size/position correct relative to the tiles
// around it even if the game's TILE_SIZE_PX ever changes, the same
// resilience tiles already have and a baked-pixel value wouldn't).
function isValidPlacements(placements) {
  if (placements === undefined) return true;
  if (!Array.isArray(placements) || placements.length > MAX_LEVEL_PLACEMENTS) return false;
  for (const p of placements) {
    if (!p || typeof p !== 'object') return false;
    if (!Number.isInteger(p.textureIndex) || p.textureIndex < 0) return false;
    if (typeof p.x !== 'number' || typeof p.y !== 'number') return false;
    if (Math.abs(p.x) > MAX_PLACEMENT_COORD || Math.abs(p.y) > MAX_PLACEMENT_COORD) return false;
    if (typeof p.width !== 'number' || typeof p.height !== 'number') return false;
    if (p.width <= 0 || p.width > MAX_PLACEMENT_COORD || p.height <= 0 || p.height > MAX_PLACEMENT_COORD) return false;
  }
  return true;
}

app.get('/api/levels/catalog', (req, res) => {
  res.json(readCatalog().filter(e => e.type === 'level'));
});

// Shared by both the create (POST /upload, mints a fresh id) and update
// (POST /:levelId/update, overwrites an existing id's files) routes below --
// validates the full level payload and writes it to disk at `id`, returning
// the fields a catalog entry needs (name/textureCount/hasBackground/
// hasThumbnail) or null if anything failed, having already sent the error
// response itself (same "caller checks for null, doesn't build its own
// error" shape callers of isValidLevelData/isValidPlacements already use).
function validateAndStoreLevelFiles(req, res, id) {
  const name = sanitizeName(req.body.name);
  const data = { tiles: req.body.tiles, spawn_points: req.body.spawn_points };
  // platforms is optional -- only include it at all if the client actually
  // sent one, so older/simpler level uploads keep publishing exactly the
  // same {tiles, spawn_points}-only JSON they always did. The web Level
  // Editor has no authoring UI for these (only the in-game Art Tool does)
  // but passes an existing level's own platforms straight through
  // unmodified when saving an edit, so editing a level never silently
  // drops them.
  if (Array.isArray(req.body.platforms) && req.body.platforms.length > 0) {
    data.platforms = req.body.platforms;
  }
  // `placements` references texturesBase64 by index (see below) --
  // meaningless without a texture library, but stored either way if sent,
  // same "only include what was actually sent" rule as platforms.
  if (req.body.placements) data.placements = req.body.placements;
  if (!isValidLevelData(data)) { res.status(400).json({ error: 'invalid level data' }); return null; }

  // The texture library itself (see public/level-editor.html's Textures
  // panel) -- any number of plain PNGs, not part of the tile-index JSON
  // (kept out of it the same way chrome/platform art keeps images separate
  // from their own small metadata, see publishMultiKeyImages() above),
  // each validated and stored as its own file so a placement can reference
  // it by index without duplicating the same bytes per copy placed.
  const texturesBase64 = req.body.texturesBase64;
  let textureBytesList = [];
  if (texturesBase64 !== undefined) {
    if (!Array.isArray(texturesBase64) || texturesBase64.length > MAX_LEVEL_TEXTURES) {
      res.status(400).json({ error: 'too many textures' }); return null;
    }
    for (const b64 of texturesBase64) {
      let bytes;
      try { bytes = Buffer.from(String(b64), 'base64'); } catch { res.status(400).json({ error: 'bad texture data' }); return null; }
      if (bytes.length === 0 || bytes.length > MAX_LEVEL_TEXTURE_BYTES || !pngDimensions(bytes)) {
        res.status(400).json({ error: 'a texture is too large, empty, or not a PNG' }); return null;
      }
      textureBytesList.push(bytes);
    }
  }
  // Every placement has to actually reference a texture that was uploaded
  // in this same publish -- isValidPlacements() above only checked
  // textureIndex is a sane non-negative integer, since it has no way to
  // know the library's real size.
  for (const p of (data.placements || [])) {
    if (p.textureIndex >= textureBytesList.length) { res.status(400).json({ error: 'placement references a texture that was not uploaded' }); return null; }
  }

  // Background and thumbnail are each a single plain PNG, same validation
  // shape as one texture-library entry -- just stored under their own
  // fixed filename instead of an indexed one, since there's only ever one
  // of each per level.
  let backgroundBytes = null;
  if (req.body.backgroundBase64 !== undefined) {
    try { backgroundBytes = Buffer.from(String(req.body.backgroundBase64), 'base64'); } catch { res.status(400).json({ error: 'bad background data' }); return null; }
    if (backgroundBytes.length === 0 || backgroundBytes.length > MAX_LEVEL_BACKGROUND_BYTES || !pngDimensions(backgroundBytes)) {
      res.status(400).json({ error: 'background is too large, empty, or not a PNG' }); return null;
    }
  }
  let thumbnailBytes = null;
  if (req.body.thumbnailBase64 !== undefined) {
    try { thumbnailBytes = Buffer.from(String(req.body.thumbnailBase64), 'base64'); } catch { res.status(400).json({ error: 'bad thumbnail data' }); return null; }
    if (thumbnailBytes.length === 0 || thumbnailBytes.length > MAX_LEVEL_THUMBNAIL_BYTES || !pngDimensions(thumbnailBytes)) {
      res.status(400).json({ error: 'thumbnail is too large, empty, or not a PNG' }); return null;
    }
  }

  const json = JSON.stringify(data);
  if (Buffer.byteLength(json) > MAX_LEVEL_UPLOAD_BYTES) { res.status(400).json({ error: 'level too large' }); return null; }

  // Wipe any stale per-index texture files beyond the new count -- a no-op
  // for a fresh create (nothing exists at `id` yet), but matters for an
  // update that reduced the texture count: without this, an old higher-
  // index file would linger on disk and (since CustomLevelCache fetches by
  // index up to the catalog's current textureCount) just go unreferenced
  // rather than actually being cleaned up.
  let staleIndex = textureBytesList.length;
  while (fs.existsSync(path.join(LEVEL_DATA_DIR, `${id}.tex${staleIndex}.png`))) {
    fs.unlinkSync(path.join(LEVEL_DATA_DIR, `${id}.tex${staleIndex}.png`));
    staleIndex++;
  }

  fs.writeFileSync(path.join(LEVEL_DATA_DIR, id + '.json'), json);
  textureBytesList.forEach((bytes, i) => fs.writeFileSync(path.join(LEVEL_DATA_DIR, `${id}.tex${i}.png`), bytes));
  // Background/thumbnail: write the new one, or -- unlike a fresh create,
  // where there's nothing to clean up -- remove a stale leftover file if
  // this save no longer has one (an edit that removed a previously-set
  // background/thumbnail), so hasBackground/hasThumbnail below stays
  // truthful to what's actually still on disk.
  const bgPath = path.join(LEVEL_DATA_DIR, `${id}.bg.png`);
  if (backgroundBytes) fs.writeFileSync(bgPath, backgroundBytes);
  else if (fs.existsSync(bgPath)) fs.unlinkSync(bgPath);
  const thumbPath = path.join(LEVEL_DATA_DIR, `${id}.thumb.png`);
  if (thumbnailBytes) fs.writeFileSync(thumbPath, thumbnailBytes);
  else if (fs.existsSync(thumbPath)) fs.unlinkSync(thumbPath);

  return { name, textureCount: textureBytesList.length, hasBackground: !!backgroundBytes, hasThumbnail: !!thumbnailBytes };
}

app.post('/api/levels/:clientId/upload', (req, res) => {
  if (!CLIENT_ID_RE.test(req.params.clientId)) return res.status(400).json({ error: 'bad client id' });
  if (!withinRateLimit('action', clientIpFor(req), RATE_LIMIT_ACTION_MAX)) return res.status(429).json({ error: 'slow down' });

  const clientId = req.params.clientId;
  const existingCount = readCatalog().filter(e => e.createdBy === clientId && e.type === 'level').length;
  if (existingCount >= MAX_LEVELS_PER_CLIENT) {
    return res.status(400).json({ error: `max ${MAX_LEVELS_PER_CLIENT} published levels per client` });
  }

  const id = 'level_' + crypto.randomBytes(8).toString('hex');
  const stored = validateAndStoreLevelFiles(req, res, id);
  if (!stored) return; // error response already sent

  const catalog = readCatalog();
  const now = Date.now();
  catalog.push({
    id, type: 'level', createdBy: clientId, createdAt: now, updatedAt: now,
    name: stored.name, textureCount: stored.textureCount,
    hasBackground: stored.hasBackground, hasThumbnail: stored.hasThumbnail,
  });
  fs.writeFileSync(CATALOG_JSON_PATH, JSON.stringify(catalog));
  res.json({ id });
});

// Overwrites an already-published level in place (same id, same createdBy/
// createdAt) instead of minting a new one -- what the web Level Editor's
// "Edit" button + Save Changes actually calls once a level's data has been
// loaded back into the canvas (see level-editor.html's loadLevelForEdit()).
// Bumps `updatedAt` so CustomLevelCache's already-cached clients notice
// their copy is stale and re-fetch it (see that file's own _on_catalog_
// response() comment) -- without this, an edit here would be invisible to
// anyone who'd already downloaded the level before it changed.
app.post('/api/levels/:clientId/:levelId/update', (req, res) => {
  if (!CLIENT_ID_RE.test(req.params.clientId)) return res.status(400).json({ error: 'bad client id' });
  if (!/^level_[a-f0-9]{16}$/.test(req.params.levelId)) return res.status(400).json({ error: 'bad level id' });
  if (!withinRateLimit('action', clientIpFor(req), RATE_LIMIT_ACTION_MAX)) return res.status(429).json({ error: 'slow down' });

  const clientId = req.params.clientId;
  const levelId = req.params.levelId;
  const catalog = readCatalog();
  const entryIndex = catalog.findIndex(e => e.id === levelId && e.type === 'level');
  if (entryIndex === -1) return res.status(404).json({ error: 'no such level' });
  if (catalog[entryIndex].createdBy !== clientId) return res.status(403).json({ error: 'not your level' });

  const stored = validateAndStoreLevelFiles(req, res, levelId);
  if (!stored) return; // error response already sent

  catalog[entryIndex] = {
    ...catalog[entryIndex],
    updatedAt: Date.now(),
    name: stored.name, textureCount: stored.textureCount,
    hasBackground: stored.hasBackground, hasThumbnail: stored.hasThumbnail,
  };
  fs.writeFileSync(CATALOG_JSON_PATH, JSON.stringify(catalog));
  res.json({ id: levelId });
});

// POST, not a real HTTP DELETE -- matches every other mutating route in
// this file (upload/update/publish are all POST too), and keeps this
// reachable through the same client/proxy paths as the rest of the API.
// Removes the catalog entry AND every file on disk for this level (data
// json, every per-index texture, background, thumbnail) -- an orphaned
// file left behind here would just sit on disk forever with nothing left
// referencing it, unlike update's own same-id overwrite which always has
// a live catalog entry to eventually clean it up again.
app.post('/api/levels/:clientId/:levelId/delete', (req, res) => {
  if (!CLIENT_ID_RE.test(req.params.clientId)) return res.status(400).json({ error: 'bad client id' });
  if (!/^level_[a-f0-9]{16}$/.test(req.params.levelId)) return res.status(400).json({ error: 'bad level id' });
  if (!withinRateLimit('action', clientIpFor(req), RATE_LIMIT_ACTION_MAX)) return res.status(429).json({ error: 'slow down' });

  const clientId = req.params.clientId;
  const levelId = req.params.levelId;
  const catalog = readCatalog();
  const entryIndex = catalog.findIndex(e => e.id === levelId && e.type === 'level');
  if (entryIndex === -1) return res.status(404).json({ error: 'no such level' });
  if (catalog[entryIndex].createdBy !== clientId) return res.status(403).json({ error: 'not your level' });

  catalog.splice(entryIndex, 1);
  fs.writeFileSync(CATALOG_JSON_PATH, JSON.stringify(catalog));

  const unlinkIfExists = (p) => { if (fs.existsSync(p)) fs.unlinkSync(p); };
  unlinkIfExists(path.join(LEVEL_DATA_DIR, levelId + '.json'));
  unlinkIfExists(path.join(LEVEL_DATA_DIR, `${levelId}.bg.png`));
  unlinkIfExists(path.join(LEVEL_DATA_DIR, `${levelId}.thumb.png`));
  let texIndex = 0;
  while (fs.existsSync(path.join(LEVEL_DATA_DIR, `${levelId}.tex${texIndex}.png`))) {
    fs.unlinkSync(path.join(LEVEL_DATA_DIR, `${levelId}.tex${texIndex}.png`));
    texIndex++;
  }

  res.json({ ok: true });
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

app.get('/api/levels/data/:levelId/texture/:index', (req, res) => {
  const levelId = req.params.levelId;
  if (!/^level_[a-f0-9]{16}$/.test(levelId)) return res.status(400).end();
  if (!/^\d+$/.test(req.params.index)) return res.status(400).end();
  const texPath = path.join(LEVEL_DATA_DIR, `${levelId}.tex${req.params.index}.png`);
  if (!fs.existsSync(texPath)) return res.status(404).end();
  res.set('Content-Type', 'image/png');
  res.set('Cache-Control', 'public, max-age=86400');
  fs.createReadStream(texPath).pipe(res);
});

function servePngIfPresent(suffix) {
  return (req, res) => {
    const levelId = req.params.levelId;
    if (!/^level_[a-f0-9]{16}$/.test(levelId)) return res.status(400).end();
    const imgPath = path.join(LEVEL_DATA_DIR, `${levelId}${suffix}`);
    if (!fs.existsSync(imgPath)) return res.status(404).end();
    res.set('Content-Type', 'image/png');
    res.set('Cache-Control', 'public, max-age=86400');
    fs.createReadStream(imgPath).pipe(res);
  };
}
app.get('/api/levels/data/:levelId/background', servePngIfPresent('.bg.png'));
app.get('/api/levels/data/:levelId/thumbnail', servePngIfPresent('.thumb.png'));

// ─── HTTP: game assets (built-in art, not player cosmetics) ───────────────────
// One version counter per category, bumped on every publish -- the client's
// GameAssetUpdater compares these against what it last downloaded (see
// game/net/game_asset_updater.gd) and only fetches a category that actually
// changed.
app.get('/api/game-assets/manifest', (req, res) => {
  res.json(gameAssetsManifest);
});

// ─── AI training: latest pooled-training policy weights ────────────────────────
// Written by ai_training/learner.py (running as the tag-trainer service on
// this same host) every few checkpoint rounds -- see that script's
// --publish-weights flag. Lets a game client fetch the model the live pool
// is currently training instead of relying solely on whatever was bundled
// into its own build at export time (see game/npc/trained_policy.gd),
// so bots keep improving as the pool trains without a new game release.
const AI_POLICY_WEIGHTS_PATH = path.join(DATA_DIR, 'ai_policy_weights.json');
app.get('/api/ai/policy-weights', (req, res) => {
  if (!fs.existsSync(AI_POLICY_WEIGHTS_PATH)) return res.status(404).json({ error: 'no published weights yet' });
  res.set('Content-Type', 'application/json');
  res.set('Cache-Control', 'no-cache'); // small file, always want whatever the pool most recently published
  fs.createReadStream(AI_POLICY_WEIGHTS_PATH).pipe(res);
});

// Short-lived (1hr -- comfortably longer than any single connection
// negotiation, short enough to limit exposure if a client process gets
// compromised) STUN+TURN credentials from Cloudflare Realtime, generated
// fresh per request. The long-lived TURN_API_TOKEN never leaves this
// process -- only the short-lived generated credential set does. See
// network_manager.gd's WebRTC connect path, which fetches this right
// before creating its RTCPeerConnection.
const TURN_CREDENTIAL_TTL_SEC = 3600;
function fetchTurnCredentials() {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({ ttl: TURN_CREDENTIAL_TTL_SEC });
    const req = https.request({
      hostname: 'rtc.live.cloudflare.com',
      path: `/v1/turn/keys/${encodeURIComponent(TURN_KEY_ID)}/credentials/generate-ice-servers`,
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${TURN_API_TOKEN}`,
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(body),
      },
      timeout: 8000,
    }, res => {
      let data = '';
      res.on('data', chunk => { data += chunk; });
      res.on('end', () => {
        if (res.statusCode !== 201) return reject(new Error(`Cloudflare TURN API returned ${res.statusCode}: ${data}`));
        try { resolve(JSON.parse(data)); } catch (e) { reject(e); }
      });
    });
    req.on('timeout', () => req.destroy(new Error('Cloudflare TURN API timed out')));
    req.on('error', reject);
    req.write(body);
    req.end();
  });
}
app.get('/api/webrtc/turn-credentials', async (req, res) => {
  if (!TURN_KEY_ID || !TURN_API_TOKEN) return res.status(503).json({ error: 'TURN not configured on this server' });
  if (!withinRateLimit('connect', clientIpFor(req), RATE_LIMIT_CONNECT_MAX)) return res.status(429).json({ error: 'slow down' });
  try {
    const creds = await fetchTurnCredentials();
    res.set('Cache-Control', 'no-store'); // credentials are per-request, never cache/reuse across clients
    res.json(creds);
  } catch (e) {
    console.error('TURN credential generation failed:', e.message);
    res.status(502).json({ error: 'TURN credential generation failed' });
  }
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
  if (!withinRateLimit('action', clientIpFor(req), RATE_LIMIT_ACTION_MAX)) return res.status(429).json({ error: 'slow down' });

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

// ─── HTTP: ui-layout (live button/label position/size/text overrides) ─────────
// Published by the website's UI Editor, applied by every client at launch
// (see game/net/ui_layout_updater.gd) via game/ui/ui_style.gd's
// apply_layout_override() -- gated by the same ASSET_PUBLISH_KEY as
// game-assets (this is base-game-default content, not player-generated).
// One flat file (not per-key, unlike MULTI_KEY_CATEGORIES' images) since
// the whole payload for even every screen at once is a handful of small
// numbers/strings, nothing like an image needing its own request.
const UI_LAYOUT_PATH = path.join(DATA_DIR, 'ui_layout.json');
// {x, y, w, h, text} per layout_key, all optional -- x/y/w/h are pixel
// values (never negative-huge/absurd, see MAX_LAYOUT_COORD below), text is
// a plain string capped the same length a button/label reasonably shows.
const MAX_LAYOUT_COORD = 4000; // generous headroom past the game's own 1152x648 viewport -- just an abuse guard, not a real constraint
const MAX_LAYOUT_TEXT_LEN = 200;

function loadUILayout() {
  try { return JSON.parse(fs.readFileSync(UI_LAYOUT_PATH, 'utf-8')); }
  catch { return { version: 0, overrides: {} }; }
}
function saveUILayout(layout) {
  fs.writeFileSync(UI_LAYOUT_PATH, JSON.stringify(layout));
}

// A single override entry -- undefined/missing fields are fine (a caller
// only overriding text needn't send x/y/w/h too), but anything present has
// to be sane, same "trust internal, validate at the boundary" rule as
// everywhere else here.
function isValidLayoutEntry(entry) {
  if (!entry || typeof entry !== 'object') return false;
  for (const k of ['x', 'y', 'w', 'h']) {
    if (entry[k] === undefined) continue;
    if (typeof entry[k] !== 'number' || Math.abs(entry[k]) > MAX_LAYOUT_COORD) return false;
  }
  if (entry.text !== undefined) {
    if (typeof entry.text !== 'string' || entry.text.length > MAX_LAYOUT_TEXT_LEN) return false;
  }
  return true;
}

app.get('/api/ui-layout/manifest', (req, res) => {
  res.json(loadUILayout());
});

// Merges (not replaces) into the existing stored overrides -- the website's
// UI Editor publishes one screen's own key set at a time (see
// level-editor.html's own per-slot-not-whole-catalog publish pattern for
// the same reasoning), so a full-replace here would silently wipe every
// OTHER screen's already-published overrides on every single publish.
// A layout_key mapped to `null` in the request deletes that key (reverts
// that one element back to its hand-authored default) rather than setting
// a nonsensical override.
app.post('/api/ui-layout/publish', (req, res) => {
  if (!verifyAssetKey(req.body.key)) return res.status(401).json({ error: 'bad or missing publish key' });
  if (!withinRateLimit('action', clientIpFor(req), RATE_LIMIT_ACTION_MAX)) return res.status(429).json({ error: 'slow down' });

  const incoming = req.body.overrides;
  if (!incoming || typeof incoming !== 'object' || Array.isArray(incoming)) {
    return res.status(400).json({ error: 'overrides required' });
  }
  for (const [layoutKey, entry] of Object.entries(incoming)) {
    if (entry !== null && !isValidLayoutEntry(entry)) {
      return res.status(400).json({ error: `invalid override for ${layoutKey}` });
    }
  }

  const layout = loadUILayout();
  for (const [layoutKey, entry] of Object.entries(incoming)) {
    if (entry === null) delete layout.overrides[layoutKey];
    else layout.overrides[layoutKey] = entry;
  }
  layout.version = (layout.version || 0) + 1;
  layout.updatedAt = Date.now();
  saveUILayout(layout);
  res.json({ ok: true, version: layout.version });
});

// ─── HTTP: ranked ─────────────────────────────────────────────────────────────
app.get('/api/ranked/:clientId', (req, res) => {
  if (!CLIENT_ID_RE.test(req.params.clientId)) return res.status(400).json({ error: 'bad client id' });
  const playlist = String(req.query.playlist || '');
  const entry = getRankEntry(req.params.clientId, playlist);
  saveRanks(); // getRankEntry may have just created a fresh entry -- persist it so a lookup alone doesn't silently lose a brand-new player's row on restart
  res.json({ elo: entry.elo, tier: tierFor(req.params.clientId, entry.elo), wins: entry.wins, losses: entry.losses, matchesPlayed: entry.matchesPlayed, playlist });
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
  if (!withinRateLimit('action', clientIpFor(req), RATE_LIMIT_ACTION_MAX)) return res.status(429).json({ error: 'slow down' });
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
  if (!withinRateLimit('action', clientIpFor(req), RATE_LIMIT_ACTION_MAX)) return res.status(429).json({ error: 'slow down' });
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
  if (!withinRateLimit('action', clientIpFor(req), RATE_LIMIT_ACTION_MAX)) return res.status(429).json({ error: 'slow down' });
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
// Adding a friend used to be instant and symmetric (no request/accept step)
// -- changed to a real request flow so a stranger with your code can't just
// add themselves without you having any say. `clientId` is the requester
// here (whoever's client called this route), `friendCode` is who they want
// to add.
app.post('/api/friends/:clientId/add', (req, res) => {
  if (!CLIENT_ID_RE.test(req.params.clientId)) return res.status(400).json({ error: 'bad client id' });
  if (!withinRateLimit('action', clientIpFor(req), RATE_LIMIT_ACTION_MAX)) return res.status(429).json({ error: 'slow down' });
  const clientId = req.params.clientId;
  const friendCode = String(req.body.friendCode || '');
  if (!CLIENT_ID_RE.test(friendCode)) return res.status(400).json({ error: 'bad friend code' });
  if (friendCode === clientId) return res.status(400).json({ error: "can't add yourself" });
  if ((friends[clientId] || []).length >= MAX_FRIENDS_PER_CLIENT) {
    return res.status(400).json({ error: `max ${MAX_FRIENDS_PER_CLIENT} friends` });
  }
  if ((friends[clientId] || []).includes(friendCode)) {
    return res.json({ ok: true, alreadyFriends: true });
  }
  // friendCode already sent clientId a request of their own -- treat this
  // as accepting it rather than leaving two one-way pending requests
  // sitting around never resolving each other.
  if ((friendRequests[clientId] || []).includes(friendCode)) {
    friendRequests[clientId] = friendRequests[clientId].filter(id => id !== friendCode);
    addFriendPair(clientId, friendCode);
    saveFriendRequests();
    saveFriends();
    return res.json({ ok: true, autoAccepted: true });
  }
  if ((friendRequests[friendCode] || []).includes(clientId)) {
    return res.json({ ok: true, alreadyPending: true });
  }
  if (!friendRequests[friendCode]) friendRequests[friendCode] = [];
  friendRequests[friendCode].push(clientId);
  saveFriendRequests();
  sendToPlayer(friendCode, {
    type: 'friend_request_received', fromClientId: clientId,
    fromUsername: accountUsernameFor(clientId) || (progression[clientId] && progression[clientId].username) || 'Player',
  });
  res.json({ ok: true, pending: true });
});

// Pending incoming requests for clientId -- lets the Friends screen show
// (and act on) requests that arrived while this client wasn't connected to
// pop the live notification, not just ones received this session.
app.get('/api/friends/:clientId/requests', (req, res) => {
  if (!CLIENT_ID_RE.test(req.params.clientId)) return res.status(400).json({ error: 'bad client id' });
  res.json(friendRequestSnapshot(req.params.clientId));
});

// "online" comes from playerSockets (populated the instant a client opens
// /relay/party -- i.e. simply having the game open in the online/friends
// menus, no match required), the same presence signal handlePartyInvite()
// itself checks before allowing an invite -- see that function's own
// playerSockets.has(targetId) check. This used to check ONLY whether the
// friend showed up in some live server's own heartbeat-reported match
// roster (servers Map, see the heartbeat handler below), which only ever
// covers someone *actively hosting/in a match* -- a friend sitting in the
// menus, exactly who you'd want to invite to a party, always showed
// offline with no Join/Invite button at all (friends_menu.gd only renders
// them when online is true). The servers-roster lookup is kept alongside
// it purely to report *where* a friend is playing (serverId/serverName),
// which playerSockets alone can't tell you.
app.get('/api/friends/:clientId', (req, res) => {
  if (!CLIENT_ID_RE.test(req.params.clientId)) return res.status(400).json({ error: 'bad client id' });
  const list = friends[req.params.clientId] || [];
  const liveServers = [...servers.values()];
  const out = list.map(friendId => {
    const server = liveServers.find(s => (s.clientIds || []).includes(friendId));
    const progressionEntry = progression[friendId];
    return {
      clientId: friendId,
      username: accountUsernameFor(friendId) || (progressionEntry && progressionEntry.username) || null,
      online: playerSockets.has(friendId) || !!server,
      serverId: server ? server.id : null,
      serverName: server ? server.name : null,
      serverTransport: server ? (server.transport || 'ws') : null,
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
      username: accountUsernameFor(clientId) || (progression[clientId] && progression[clientId].username) || null,
      elo: r.elo, tier: tierFor(clientId, r.elo), wins: r.wins, losses: r.losses, matchesPlayed: r.matchesPlayed,
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
    playlistRanks[playlistId] = { elo: r.elo, tier: tierFor(clientId, r.elo), wins: r.wins, losses: r.losses, matchesPlayed: r.matchesPlayed };
  }
  res.json({
    clientId, username: accountUsernameFor(clientId) || prog.username,
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
    if (!withinRateLimit('connect', ip, RATE_LIMIT_CONNECT_MAX)) { socket.destroy(); return; }
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
    if (!withinRateLimit('connect', ip, RATE_LIMIT_CONNECT_MAX)) { socket.destroy(); return; }
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
    if (!withinRateLimit('connect', ip, RATE_LIMIT_CONNECT_MAX)) { socket.destroy(); return; }
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
        // Private matches (server_main.gd's --private) register like any
        // other server -- otherwise a party member on a different network
        // than the host could never actually reach them, LAN-only sharing
        // being the only alternative -- but never appear in /api/servers,
        // so they're excluded from the public site's server browser and
        // can never be auto-picked by casual/ranked matchmaking. A party
        // member following their leader in still reaches this exact
        // server: handlePartyQueueStart resolves it server-side by name
        // instead of relying on the (deliberately blind to it) public
        // directory endpoint.
        unlisted: !!msg.unlisted,
        // Set once at registration from server_main.gd's --webrtc flag
        // (RelayClient's register message) -- never changes for this
        // server's lifetime, so a joining client always knows up front
        // which NetworkManager.start_client*() variant to call instead of
        // guessing and silently failing to connect.
        transport: msg.webrtc ? 'webrtc' : 'ws',
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
  // A transient reconnect under the same clientId (WiFi blip, laptop
  // sleep/wake, a Cloudflare tunnel reset the KEEPALIVE_INTERVAL_SEC
  // mitigation doesn't fully rule out) cancels whatever grace-period leave
  // its old socket's close scheduled below -- without this, ANY drop of
  // this socket (not just the client_id-changed case handleIdentityMigrate
  // already covers) permanently removed a player from their own party: the
  // close handler used to call handlePartyLeave() immediately, reassigning
  // leadership and forgetting this clientId belonged to the party at all,
  // so the ordinary reconnect a few seconds later found nothing left to
  // resync into. Confirmed live: a party leader's connection blipped and
  // their client showed "not in a party" from then on, while the other
  // member's own client kept showing a (now solo, reassigned-leader) party
  // fine -- and since is_leader() then read false, hosting a private match
  // never told that other member to come along either.
  const pendingLeave = pendingPartyDisconnects.get(clientId);
  if (pendingLeave) {
    clearTimeout(pendingLeave);
    pendingPartyDisconnects.delete(clientId);
  }
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
    } else if (msg.type === 'party_resync') {
      // On-demand "what's my real party state right now" -- unlike the
      // connect-time resync above (silent if there's nothing to restore),
      // this always answers, including an explicit {party: null}, so a
      // client that suspects it's stale (see party_manager.gd's
      // request_resync(), called whenever the Friends screen opens) can be
      // CONFIDENT the answer reflects the server's actual current state --
      // a real fix for any party UI that silently stopped updating,
      // regardless of what specific race caused it to drift (a fire-and-
      // forget leave/kick/accept whose send() call landed on a socket that
      // reported open but wasn't really, same class of issue the
      // KEEPALIVE_INTERVAL_SEC mitigation exists for but can't fully rule
      // out between beats).
      const partyId = clientParty.get(clientId);
      const party = partyId ? parties.get(partyId) : null;
      sendToPlayer(clientId, { type: 'party_updated', party: party ? partySnapshot(party) : null });
    } else if (msg.type === 'party_queue_start') {
      handlePartyQueueStart(clientId, msg);
    } else if (msg.type === 'friend_request_accept') {
      handleFriendRequestAccept(clientId, String(msg.fromClientId || ''));
    } else if (msg.type === 'friend_request_decline') {
      handleFriendRequestDecline(clientId, String(msg.fromClientId || ''));
    } else if (msg.type === 'identity_migrate') {
      handleIdentityMigrate(clientId, String(msg.newClientId || ''));
    }
  });

  ws.on('close', () => {
    const entry = playerSockets.get(clientId);
    if (entry && entry.ws === ws) {
      playerSockets.delete(clientId);
      // Deferred, not immediate -- see this function's own header comment
      // and PARTY_DISCONNECT_GRACE_MS. Cancelled above if this same
      // clientId reconnects before the timer fires.
      const timer = setTimeout(() => {
        pendingPartyDisconnects.delete(clientId);
        handlePartyLeave(clientId);
      }, PARTY_DISCONNECT_GRACE_MS);
      pendingPartyDisconnects.set(clientId, timer);
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
