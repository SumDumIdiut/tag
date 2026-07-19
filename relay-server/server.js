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
const RATE_LIMIT_WINDOW_MS = 60_000;
const RATE_LIMIT_MAX = 5;

// ─── Skins (server-side cosmetic storage) ────────────────────────────────────
// The skin/hat catalog (built-in colors are client-side; custom images live
// here) is server-curated in two different ways at once: add-skin.js (local
// to this machine, no HTTP exposure) can add anything, and clients can ALSO
// draw and upload their own skins/hats through a narrowly scoped endpoint
// (POST .../upload below) -- fixed-size canvas strokes per rig part only,
// not arbitrary file upload, with rate-limit/size/per-client-count caps.
//
// catalog.json is deliberately not cached in memory: add-skin.js writes it
// directly on disk while this server may be running, so every read re-reads
// it fresh from disk (cheap -- it's tiny). Caching it would mean the next
// write from this server (an upload, or a client's selection save under the
// old combined-file scheme) could silently clobber whatever add-skin.js had
// just written. Selections ARE cached in memory, since this server is their
// only writer.
const DATA_DIR = path.join(__dirname, 'data');
const SKIN_IMAGE_DIR = path.join(DATA_DIR, 'skin_images');
const CATALOG_JSON_PATH = path.join(DATA_DIR, 'catalog.json');
const SELECTIONS_JSON_PATH = path.join(DATA_DIR, 'selections.json');
const HAT_SELECTIONS_JSON_PATH = path.join(DATA_DIR, 'hat_selections.json');
const LEGACY_SKINS_JSON_PATH = path.join(DATA_DIR, 'skins.json');
const CLIENT_ID_RE = /^[a-f0-9-]{8,64}$/i;

// Mirrors SkinCatalog.PART_DEFS in game/cosmetics/skin_catalog.gd -- the
// per-part canvas dimensions a drawn skin's upload must exactly match, kept
// in sync by hand (same tradeoff already accepted for RANK_TIERS later).
const PART_NAMES = ['head', 'torso', 'left_arm', 'right_arm', 'left_leg', 'right_leg'];
const PART_DIMENSIONS = {
  head: { width: 24, height: 24 },
  torso: { width: 14, height: 21 },
  left_arm: { width: 6, height: 14 },
  right_arm: { width: 6, height: 14 },
  left_leg: { width: 4, height: 11 },
  right_leg: { width: 4, height: 11 },
};
// Taller than the head's own crop -- the head circle touches all four
// edges of its own canvas, so a hat confined to that same box has no
// actual headroom and just overlaps the face. The extra height lets a hat
// stick up above the head's silhouette; only its bottom rows are meant to
// overlap the head at all (see skin_catalog.gd's HAT_OVERLAP comment on
// the client, which this must stay in sync with).
const HAT_DIMENSIONS = { width: 18, height: 16 };
const MAX_CUSTOM_SKINS_PER_CLIENT = 5;
const MAX_HATS_PER_CLIENT = 5;
const MAX_UPLOAD_BYTES = 100 * 1024; // generous over what a handful of tiny PNGs actually need -- just an abuse backstop

// Levels live in the same catalog.json (type: 'level') as skins/hats, but
// each one's actual layout is plain JSON, not a PNG -- see
// game/levels/level_data.gd on the client for the exact shape and why it's
// safe to trust directly (tile-index numbers + spawn coordinates only,
// never scenes/scripts). Dimension caps mirror LevelData's own -- kept in
// sync by hand, same tradeoff already accepted for PART_DIMENSIONS above.
const LEVEL_DATA_DIR = path.join(DATA_DIR, 'level_data');
const MAX_LEVELS_PER_CLIENT = 5;
const MAX_LEVEL_TILES = 6000;
const MIN_LEVEL_SPAWN_POINTS = 2;
const MAX_LEVEL_SPAWN_POINTS = 16;
// A full 6000-tile level's JSON is ~85-90KB -- this just needs to comfortably
// clear that with room to spare, while staying under the global
// express.json({limit: '256kb'}) body-parser cap below (a request over that
// limit never reaches this handler at all, so this can't usefully exceed it).
const MAX_LEVEL_UPLOAD_BYTES = 150 * 1024;

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

fs.mkdirSync(SKIN_IMAGE_DIR, { recursive: true });
fs.mkdirSync(LEVEL_DATA_DIR, { recursive: true });

// One-time migration from the old combined per-client format
// ({ clientId: { selected, custom: [{id, name}] } }), from back when any
// client could upload its own custom skins -- folds everything already
// uploaded into the new shared catalog instead of discarding it, and keeps
// everyone's existing selection.
if (!fs.existsSync(CATALOG_JSON_PATH) && !fs.existsSync(SELECTIONS_JSON_PATH) && fs.existsSync(LEGACY_SKINS_JSON_PATH)) {
  try {
    const legacy = JSON.parse(fs.readFileSync(LEGACY_SKINS_JSON_PATH, 'utf-8'));
    const catalog = [];
    const selections = {};
    const seenIds = new Set();
    for (const [clientId, entry] of Object.entries(legacy || {})) {
      if (!entry || typeof entry !== 'object') continue;
      if (entry.selected) selections[clientId] = entry.selected;
      for (const skin of entry.custom || []) {
        if (skin && skin.id && !seenIds.has(skin.id)) {
          seenIds.add(skin.id);
          catalog.push({ id: skin.id, name: skin.name });
        }
      }
    }
    fs.writeFileSync(CATALOG_JSON_PATH, JSON.stringify(catalog));
    fs.writeFileSync(SELECTIONS_JSON_PATH, JSON.stringify(selections));
  } catch { /* legacy file unreadable -- just start fresh below */ }
}

function readCatalog() {
  try { return JSON.parse(fs.readFileSync(CATALOG_JSON_PATH, 'utf-8')); }
  catch { return []; }
}

function loadSelections() {
  try { return JSON.parse(fs.readFileSync(SELECTIONS_JSON_PATH, 'utf-8')); }
  catch { return {}; }
}
let selections = loadSelections(); // clientId -> skinId

function saveSelections() {
  fs.writeFileSync(SELECTIONS_JSON_PATH, JSON.stringify(selections));
}

function loadHatSelections() {
  try { return JSON.parse(fs.readFileSync(HAT_SELECTIONS_JSON_PATH, 'utf-8')); }
  catch { return {}; }
}
let hatSelections = loadHatSelections(); // clientId -> hatId, absent means no hat equipped

function saveHatSelections() {
  fs.writeFileSync(HAT_SELECTIONS_JSON_PATH, JSON.stringify(hatSelections));
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
const RANK_TIERS = [
  { name: 'Bronze', minElo: 0 },
  { name: 'Silver', minElo: 1100 },
  { name: 'Gold', minElo: 1300 },
  { name: 'Platinum', minElo: 1550 },
  { name: 'Diamond', minElo: 1850 },
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
let ranks = loadRanks(); // clientId -> { elo, wins, losses, matchesPlayed, lastPlayed }

function saveRanks() {
  fs.writeFileSync(RANKS_JSON_PATH, JSON.stringify(ranks));
}

function getRankEntry(clientId) {
  if (!ranks[clientId]) ranks[clientId] = { elo: STARTING_ELO, wins: 0, losses: 0, matchesPlayed: 0, lastPlayed: 0 };
  return ranks[clientId];
}

// Standard FFA/multiplayer Elo extension: every pair (i, j) in the lobby is
// treated as an independent virtual 1v1 where whoever placed better is the
// "winner" of that pair, then each player's total delta is averaged over
// their N-1 opponents so total rating movement stays comparable regardless
// of how many people were in the round (an 8-player lobby shouldn't swing
// ratings 7x harder than a 2-player one).
function applyEloUpdates(results) {
  // results: [{clientId, itTime, place}], already sorted/placed by the caller
  const n = results.length;
  if (n < 2) return; // nothing to compare a lone result against
  const before = results.map(r => getRankEntry(r.clientId).elo);
  const deltas = results.map(() => 0);
  for (let i = 0; i < n; i++) {
    for (let j = 0; j < n; j++) {
      if (i === j) continue;
      const expected = 1 / (1 + Math.pow(10, (before[j] - before[i]) / 400));
      const actualScore = results[i].place < results[j].place ? 1 : 0; // lower place number = better = "won" this pair
      deltas[i] += (actualScore - expected);
    }
  }
  for (let i = 0; i < n; i++) {
    const entry = getRankEntry(results[i].clientId);
    entry.elo = Math.round(entry.elo + ELO_K * (deltas[i] / (n - 1)));
    entry.matchesPlayed += 1;
    entry.lastPlayed = Date.now();
    if (results[i].place === 1) entry.wins += 1;
    else if (results[i].place === n) entry.losses += 1;
  }
  saveRanks();
}

// ─── Accounts (username + password login) ──────────────────────────────────────
// Deliberately a thin identity layer, not a replacement for clientId: every
// other system in this file (ranks, selections, catalog createdBy, etc.) stays
// keyed by clientId exactly as before. An account just resolves to one stable
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
  if (!progression[clientId]) progression[clientId] = { xp: 0, achievements: [] };
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
  { id: 'last_place', name: "Tag, You're It", condition: (rank, m) => m.place === m.n },
];

// Called right after applyEloUpdates(results) inside report-result -- reuses
// the exact same validated {clientId, itTime, place} entries, plus n
// (results.length) for achievements that depend on the whole round's size.
function applyProgressionUpdates(results) {
  const n = results.length;
  for (const r of results) {
    const entry = getProgressionEntry(r.clientId);
    entry.xp += XP_BASE + Math.max(0, n - r.place) * XP_PLACEMENT_BONUS;
    const rank = getRankEntry(r.clientId); // already updated by applyEloUpdates, called before this
    for (const ach of ACHIEVEMENTS) {
      if (entry.achievements.includes(ach.id)) continue;
      if (ach.condition(rank, { itTime: r.itTime, place: r.place, n })) {
        entry.achievements.push(ach.id);
      }
    }
  }
  saveProgression();
}


const servers = new Map();       // serverId -> { id, name, maxPlayers, playerCount, createdAt, lastHeartbeat, controlSocket }
const pendingTokens = new Map(); // token -> { playerSocket, timer }
const rateLimitHits = new Map(); // ip -> [timestamps]

function withinRateLimit(ip) {
  const now = Date.now();
  const hits = (rateLimitHits.get(ip) || []).filter(t => now - t < RATE_LIMIT_WINDOW_MS);
  hits.push(now);
  rateLimitHits.set(ip, hits);
  return hits.length <= RATE_LIMIT_MAX;
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
  })));
});

// ─── HTTP: skins ──────────────────────────────────────────────────────────────
app.use(express.json({ limit: '256kb' }));

// The shared catalog of server-curated + player-drawn custom skins -- every
// client sees the same list. Hats and levels live in the same catalog.json
// (see readCatalog()) but are filtered out here; use /api/hats/catalog and
// /api/levels/catalog for those.
app.get('/api/skins/catalog', (req, res) => {
  res.json(readCatalog().filter(e => e.type !== 'hat' && e.type !== 'level'));
});

app.get('/api/skins/:clientId', (req, res) => {
  if (!CLIENT_ID_RE.test(req.params.clientId)) return res.status(400).json({ error: 'bad client id' });
  res.json({ selected: selections[req.params.clientId] || 'red' });
});

app.post('/api/skins/:clientId/select', (req, res) => {
  if (!CLIENT_ID_RE.test(req.params.clientId)) return res.status(400).json({ error: 'bad client id' });
  const skinId = String(req.body.skinId || '');
  if (!skinId) return res.status(400).json({ error: 'skinId required' });
  selections[req.params.clientId] = skinId;
  saveSelections();
  res.json({ ok: true });
});

// The one deliberately re-opened client-write path: a player draws a skin
// (one small canvas per rig part, see PART_DIMENSIONS) in-app and it's
// uploaded and visible to everyone immediately, same as any catalog skin --
// no admin approval step. Scoped narrowly to exact-size canvas strokes
// (not arbitrary file upload) with the same class of abuse mitigations the
// original, since-removed whole-image upload endpoint had: a per-IP rate
// limit, a per-client count cap, and a payload size cap.
app.post('/api/skins/:clientId/upload', (req, res) => {
  if (!CLIENT_ID_RE.test(req.params.clientId)) return res.status(400).json({ error: 'bad client id' });
  if (!withinRateLimit((req.socket.remoteAddress || '').toString())) return res.status(429).json({ error: 'slow down' });

  const clientId = req.params.clientId;
  const existingCount = readCatalog().filter(e => e.createdBy === clientId && e.type === 'skin').length;
  if (existingCount >= MAX_CUSTOM_SKINS_PER_CLIENT) {
    return res.status(400).json({ error: `max ${MAX_CUSTOM_SKINS_PER_CLIENT} drawn skins per client` });
  }

  const name = sanitizeName(req.body.name);
  const parts = req.body.parts;
  if (!parts || typeof parts !== 'object') return res.status(400).json({ error: 'parts required' });

  const decoded = {};
  let totalBytes = 0;
  for (const partName of PART_NAMES) {
    const b64 = parts[partName];
    if (typeof b64 !== 'string' || !b64) return res.status(400).json({ error: `missing part: ${partName}` });
    let bytes;
    try { bytes = Buffer.from(b64, 'base64'); } catch { return res.status(400).json({ error: 'bad image data' }); }
    totalBytes += bytes.length;
    if (totalBytes > MAX_UPLOAD_BYTES) return res.status(400).json({ error: 'upload too large' });
    const dims = pngDimensions(bytes);
    const expected = PART_DIMENSIONS[partName];
    if (!dims || dims.width !== expected.width || dims.height !== expected.height) {
      return res.status(400).json({ error: `${partName} must be exactly ${expected.width}x${expected.height}` });
    }
    decoded[partName] = bytes;
  }

  const id = 'part_' + crypto.randomBytes(8).toString('hex');
  const dir = path.join(SKIN_IMAGE_DIR, id);
  fs.mkdirSync(dir, { recursive: true });
  for (const partName of PART_NAMES) {
    fs.writeFileSync(path.join(dir, partName + '.png'), decoded[partName]);
  }
  const catalog = readCatalog();
  catalog.push({ id, name, type: 'skin', createdBy: clientId, createdAt: Date.now() });
  fs.writeFileSync(CATALOG_JSON_PATH, JSON.stringify(catalog));
  res.json({ id });
});

// Any client (not just the owner) can fetch a custom skin's image by id --
// this is what lets other players in a match actually see it, since the id
// alone (already broadcast as part of match state) is enough to look it up
// here instead of needing a peer-to-peer transfer.
app.get('/api/skins/image/:skinId', (req, res) => {
  const skinId = req.params.skinId;
  if (!/^custom_[a-f0-9]{16}$/.test(skinId)) return res.status(400).end();
  const imgPath = path.join(SKIN_IMAGE_DIR, skinId + '.png');
  if (!fs.existsSync(imgPath)) return res.status(404).end();
  res.set('Content-Type', 'image/png');
  res.set('Cache-Control', 'public, max-age=86400');
  fs.createReadStream(imgPath).pipe(res);
});

// Per-part image fetch for drawn (part_*) skins -- the legacy whole-image
// route above stays untouched for custom_* ids.
app.get('/api/skins/image/:skinId/:part', (req, res) => {
  const skinId = req.params.skinId;
  const part = req.params.part;
  if (!/^part_[a-f0-9]{16}$/.test(skinId)) return res.status(400).end();
  if (!PART_NAMES.includes(part)) return res.status(400).end();
  const imgPath = path.join(SKIN_IMAGE_DIR, skinId, part + '.png');
  if (!fs.existsSync(imgPath)) return res.status(404).end();
  res.set('Content-Type', 'image/png');
  res.set('Cache-Control', 'public, max-age=86400');
  fs.createReadStream(imgPath).pipe(res);
});

// ─── HTTP: hats ───────────────────────────────────────────────────────────────
// A second, independent cosmetic slot alongside skins -- same catalog.json
// (filtered by type), same client-drawn-and-uploaded model, same
// mitigations. A hat is a single image (no rig parts), rendered as a child
// of the rig's Head node client-side.
app.get('/api/hats/catalog', (req, res) => {
  res.json(readCatalog().filter(e => e.type === 'hat'));
});

app.get('/api/hats/:clientId', (req, res) => {
  if (!CLIENT_ID_RE.test(req.params.clientId)) return res.status(400).json({ error: 'bad client id' });
  res.json({ selected: hatSelections[req.params.clientId] || null });
});

app.post('/api/hats/:clientId/select', (req, res) => {
  if (!CLIENT_ID_RE.test(req.params.clientId)) return res.status(400).json({ error: 'bad client id' });
  const hatId = req.body.hatId ? String(req.body.hatId) : null;
  if (hatId) {
    hatSelections[req.params.clientId] = hatId;
  } else {
    delete hatSelections[req.params.clientId]; // null/empty means "no hat"
  }
  saveHatSelections();
  res.json({ ok: true });
});

app.post('/api/hats/:clientId/upload', (req, res) => {
  if (!CLIENT_ID_RE.test(req.params.clientId)) return res.status(400).json({ error: 'bad client id' });
  if (!withinRateLimit((req.socket.remoteAddress || '').toString())) return res.status(429).json({ error: 'slow down' });

  const clientId = req.params.clientId;
  const existingCount = readCatalog().filter(e => e.createdBy === clientId && e.type === 'hat').length;
  if (existingCount >= MAX_HATS_PER_CLIENT) {
    return res.status(400).json({ error: `max ${MAX_HATS_PER_CLIENT} drawn hats per client` });
  }

  const name = sanitizeName(req.body.name);
  let bytes;
  try { bytes = Buffer.from(String(req.body.imageBase64 || ''), 'base64'); } catch { return res.status(400).json({ error: 'bad image data' }); }
  if (bytes.length === 0 || bytes.length > MAX_UPLOAD_BYTES) return res.status(400).json({ error: 'image too large or empty' });
  const dims = pngDimensions(bytes);
  if (!dims || dims.width !== HAT_DIMENSIONS.width || dims.height !== HAT_DIMENSIONS.height) {
    return res.status(400).json({ error: `hat image must be exactly ${HAT_DIMENSIONS.width}x${HAT_DIMENSIONS.height}` });
  }

  const id = 'hat_' + crypto.randomBytes(8).toString('hex');
  fs.writeFileSync(path.join(SKIN_IMAGE_DIR, id + '.png'), bytes);
  const catalog = readCatalog();
  catalog.push({ id, name, type: 'hat', createdBy: clientId, createdAt: Date.now() });
  fs.writeFileSync(CATALOG_JSON_PATH, JSON.stringify(catalog));
  res.json({ id });
});

app.get('/api/hats/image/:hatId', (req, res) => {
  const hatId = req.params.hatId;
  if (!/^hat_[a-f0-9]{16}$/.test(hatId)) return res.status(400).end();
  const imgPath = path.join(SKIN_IMAGE_DIR, hatId + '.png');
  if (!fs.existsSync(imgPath)) return res.status(404).end();
  res.set('Content-Type', 'image/png');
  res.set('Cache-Control', 'public, max-age=86400');
  fs.createReadStream(imgPath).pipe(res);
});

// ─── HTTP: levels ─────────────────────────────────────────────────────────────
// Live-published, no review step -- same trust model as drawn skins/hats.
// Unlike skins/hats, a level's data is used by the dedicated server itself
// to build real match collision (see game/net/server_match.gd), not just
// rendered client-side -- but it's plain tile-index/coordinate JSON, so
// there's nothing here a level could ever do beyond "place solid tiles in
// weird places" no matter how it was crafted.
function isValidLevelData(data) {
  if (!data || typeof data !== 'object') return false;
  const { tiles, spawn_points: spawns } = data;
  if (!Array.isArray(tiles) || !Array.isArray(spawns)) return false;
  if (tiles.length > MAX_LEVEL_TILES) return false;
  if (spawns.length < MIN_LEVEL_SPAWN_POINTS || spawns.length > MAX_LEVEL_SPAWN_POINTS) return false;
  for (const t of tiles) {
    if (!Array.isArray(t) || t.length < 3) return false;
    if (typeof t[0] !== 'number' || typeof t[1] !== 'number' || typeof t[2] !== 'number') return false;
    if (t[2] < 0 || t[2] > 2) return false;
  }
  for (const s of spawns) {
    if (!Array.isArray(s) || s.length < 2) return false;
    if (typeof s[0] !== 'number' || typeof s[1] !== 'number') return false;
  }
  return true;
}

app.get('/api/levels/catalog', (req, res) => {
  res.json(readCatalog().filter(e => e.type === 'level'));
});

app.post('/api/levels/:clientId/upload', (req, res) => {
  if (!CLIENT_ID_RE.test(req.params.clientId)) return res.status(400).json({ error: 'bad client id' });
  if (!withinRateLimit((req.socket.remoteAddress || '').toString())) return res.status(429).json({ error: 'slow down' });

  const clientId = req.params.clientId;
  const existingCount = readCatalog().filter(e => e.createdBy === clientId && e.type === 'level').length;
  if (existingCount >= MAX_LEVELS_PER_CLIENT) {
    return res.status(400).json({ error: `max ${MAX_LEVELS_PER_CLIENT} published levels per client` });
  }

  const name = sanitizeName(req.body.name);
  const data = { tiles: req.body.tiles, spawn_points: req.body.spawn_points };
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

// ─── HTTP: ranked ─────────────────────────────────────────────────────────────
app.get('/api/ranked/:clientId', (req, res) => {
  if (!CLIENT_ID_RE.test(req.params.clientId)) return res.status(400).json({ error: 'bad client id' });
  const entry = getRankEntry(req.params.clientId);
  saveRanks(); // getRankEntry may have just created a fresh entry -- persist it so a lookup alone doesn't silently lose a brand-new player's row on restart
  res.json({ elo: entry.elo, tier: tierForElo(entry.elo), wins: entry.wins, losses: entry.losses, matchesPlayed: entry.matchesPlayed });
});

// A ranked match's host (any player's client, per the accepted trust model
// above) reports the round's outcome here once it ends. No auth beyond the
// existing rate limiter -- a malicious report can only ever move the
// clientIds it actually names, through the same public Elo formula everyone
// else goes through, so the worst case is a self-serving win/loss report,
// not an arbitrary rating mint.
app.post('/api/ranked/report-result', (req, res) => {
  if (!withinRateLimit((req.socket.remoteAddress || '').toString())) return res.status(429).json({ error: 'slow down' });
  const results = req.body.results;
  if (!Array.isArray(results) || results.length === 0) return res.status(400).json({ error: 'results required' });
  const clean = [];
  for (const r of results) {
    if (!r || !CLIENT_ID_RE.test(String(r.clientId || ''))) return res.status(400).json({ error: 'bad clientId in results' });
    const place = parseInt(r.place, 10);
    if (!Number.isFinite(place) || place < 1) return res.status(400).json({ error: 'bad place in results' });
    clean.push({ clientId: String(r.clientId), itTime: Number(r.itTime) || 0, place });
  }
  applyEloUpdates(clean);
  applyProgressionUpdates(clean);
  res.json({ ok: true });
});

app.get('/api/progression/:clientId', (req, res) => {
  if (!CLIENT_ID_RE.test(req.params.clientId)) return res.status(400).json({ error: 'bad client id' });
  const entry = getProgressionEntry(req.params.clientId);
  saveProgression(); // mirrors GET /api/ranked/:clientId -- a lookup alone shouldn't lose a freshly-created zero-row on restart
  res.json({
    xp: entry.xp,
    level: levelForXp(entry.xp),
    achievements: entry.achievements.map(id => {
      const def = ACHIEVEMENTS.find(a => a.id === id);
      return { id, name: def ? def.name : id };
    }),
  });
});

// ─── HTTP: auth (accounts) ────────────────────────────────────────────────────
// Optional -- playing with no account keeps working exactly as before this
// existed (see game/main/login_screen.gd's fallback-on-any-failure behavior).
// This is purely "make progress follow you across devices," not a gate on
// playing at all.
app.post('/api/auth/register', (req, res) => {
  if (!withinRateLimit((req.socket.remoteAddress || '').toString())) return res.status(429).json({ error: 'slow down' });
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
  if (!withinRateLimit((req.socket.remoteAddress || '').toString())) return res.status(429).json({ error: 'slow down' });
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

let _indexHtmlCache = null;
app.get('/', (req, res) => {
  if (!_indexHtmlCache) {
    const html = fs.readFileSync(path.join(__dirname, 'public', 'index.html'), 'utf-8');
    _indexHtmlCache = html.replace('</head>', `<script>window.__BASE_PATH__=${JSON.stringify(BASE_PATH)};</script></head>`);
  }
  res.send(_indexHtmlCache);
});
app.use(express.static(path.join(__dirname, 'public')));

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
  const ip = (req.socket.remoteAddress || '').toString();
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
  socket.destroy();
});

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
