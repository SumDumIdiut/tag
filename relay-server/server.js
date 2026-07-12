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
// The skin catalog (built-in colors are client-side; custom image skins live
// here) is entirely server-curated -- there is deliberately no HTTP endpoint
// that lets a client add or remove a custom skin. New custom skins can only
// be added by someone with direct access to this machine, via add-skin.js
// run locally (see that file). Clients may only fetch the catalog and pick
// (select) among the skins already in it.
//
// catalog.json and selections.json are deliberately separate files owned by
// different writers: add-skin.js writes catalog.json directly on disk while
// this server may be running, so catalog reads always re-read it fresh
// (cheap -- it's tiny) rather than caching it in memory. Caching it would
// mean the next client selection's save silently clobbered whatever
// add-skin.js had just written. Selections are still cached in memory since
// this server is their only writer.
const DATA_DIR = path.join(__dirname, 'data');
const SKIN_IMAGE_DIR = path.join(DATA_DIR, 'skin_images');
const CATALOG_JSON_PATH = path.join(DATA_DIR, 'catalog.json');
const SELECTIONS_JSON_PATH = path.join(DATA_DIR, 'selections.json');
const LEGACY_SKINS_JSON_PATH = path.join(DATA_DIR, 'skins.json');
const CLIENT_ID_RE = /^[a-f0-9-]{8,64}$/i;

fs.mkdirSync(SKIN_IMAGE_DIR, { recursive: true });

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

// ─── State ────────────────────────────────────────────────────────────────────
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
    id: s.id, name: s.name, playerCount: s.playerCount, maxPlayers: s.maxPlayers, createdAt: s.createdAt,
  })));
});

// ─── HTTP: skins ──────────────────────────────────────────────────────────────
app.use(express.json({ limit: '256kb' }));

// The shared catalog of server-curated custom skins -- every client sees the
// same list, since there's no more per-client uploading.
app.get('/api/skins/catalog', (req, res) => {
  res.json(readCatalog());
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
