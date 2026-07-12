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
