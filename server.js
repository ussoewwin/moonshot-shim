// moonshot-shim/server.js
//
// Local HTTP proxy that sits between an OpenAI-compatible client (Cursor,
// Cline, etc.) and Moonshot's Kimi API. Its sole purpose is to satisfy
// Moonshot's "thinking model" validation rule:
//
//   400: thinking is enabled but reasoning_content is missing
//        in assistant tool call message at index N
//
// Moonshot's K2.6 (and other reasoning models) require that *every*
// assistant message in the conversation history that carries `tool_calls`
// also carries a non-empty string `reasoning_content`. Standard OpenAI
// SDK / OpenAI-compatible clients drop that field, so multi-turn tool
// conversations break.
//
// The patcher below walks `messages` and injects `reasoning_content: " "`
// into every offending assistant message. The Moonshot API only checks
// for the field's presence and non-emptiness; the placeholder value is
// accepted.
//
// Everything else (auth header, model id, streaming SSE, /v1/models,
// errors) is forwarded verbatim.
//
// --- Resilience features (added 2026-04-25) ------------------------------
//   * Persistent log file:  ./moonshot-shim.log  (append, rotated at start
//     when previous file > 5 MB)
//   * uncaughtException / unhandledRejection are CAUGHT and logged.
//     The process keeps running. (Previous version exited on EPIPE etc.)
//   * Per-minute summary line (req / err / patched / upstream-status mix).
//   * /healthz endpoint for external liveness checks.

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { request } from 'undici';

const PORT = parseInt(process.env.SHIM_PORT || '8787', 10);
const HOST = process.env.SHIM_HOST || '127.0.0.1';
const TARGET = (process.env.SHIM_TARGET || 'https://api.moonshot.ai/v1').replace(/\/+$/, '');
const DEBUG = process.env.SHIM_DEBUG === '1';
const PLACEHOLDER = ' ';
const UPSTREAM_RETRIES = Math.max(0, parseInt(process.env.SHIM_UPSTREAM_RETRIES || '2', 10));
const RETRY_BASE_MS = Math.max(50, parseInt(process.env.SHIM_RETRY_BASE_MS || '250', 10));
const KEEPALIVE_INTERVAL_MS = Math.max(0, parseInt(process.env.SHIM_KEEPALIVE_MS || '10000', 10));
const TCP_KEEPALIVE_MS = Math.max(0, parseInt(process.env.SHIM_TCP_KEEPALIVE_MS || '15000', 10));

// --- Shared Secret (Phase 1) --------------------------------------------
const SHIM_SECRET = process.env.SHIM_SECRET || '';
if (SHIM_SECRET && SHIM_SECRET.length < 32) {
  console.error('FATAL: SHIM_SECRET must be at least 32 characters');
  process.exit(1);
}

// --- security hardening (Phase 0) ----------------------------------------
const ALLOWED_PATHS = new Set([
  '/chat/completions',
  '/models',
  '/completions',
  '/embeddings',
  '/healthz',
  '/_shim/healthz',
]);
const ALLOWED_METHODS = new Set(['GET', 'POST', 'OPTIONS']);

const SECURITY_HEADERS = {
  'x-content-type-options': 'nosniff',
  'x-frame-options': 'DENY',
  'x-xss-protection': '1; mode=block',
  'referrer-policy': 'no-referrer',
};

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const LOG_PATH = process.env.SHIM_LOG || path.join(__dirname, 'moonshot-shim.log');
const LOG_MAX_BYTES = 5 * 1024 * 1024; // 5 MB then rotate to .1

// --- log file (append, with one-shot rotation at startup) ----------------

function rotateIfBig() {
  try {
    const st = fs.statSync(LOG_PATH);
    if (st.size > LOG_MAX_BYTES) {
      const rotated = LOG_PATH + '.1';
      try { fs.unlinkSync(rotated); } catch {}
      fs.renameSync(LOG_PATH, rotated);
    }
  } catch {
    // file does not exist yet, that's fine
  }
}
rotateIfBig();

// Open in append mode. We do NOT close it; process exit closes the fd.
const logStream = fs.createWriteStream(LOG_PATH, { flags: 'a' });
logStream.on('error', (err) => {
  // last resort: console only
  console.error(new Date().toISOString(), 'LOG STREAM ERROR', err.message);
});

function ts() {
  return new Date().toISOString();
}

function log(...args) {
  const line = `${ts()} ${args.map((a) => (typeof a === 'string' ? a : JSON.stringify(a))).join(' ')}\n`;
  process.stdout.write(line);
  try { logStream.write(line); } catch {}
}

function dlog(...args) {
  if (DEBUG) log('[debug]', ...args);
}

// --- per-minute summary --------------------------------------------------

const stats = {
  req: 0,
  err: 0,
  patched: 0, // total assistant messages patched
  byStatus: Object.create(null), // { 200: n, 429: n, 502: n, ... }
  promptTokens: 0,
  cachedTokens: 0,
  completionTokens: 0,
  usageReports: 0, // # of upstream responses that carried a usage block
  windowStart: Date.now(),
};

// Cumulative counters that are NOT reset per minute. Useful when reading the
// log days later to see overall cache effectiveness.
const lifetime = {
  promptTokens: 0,
  cachedTokens: 0,
  completionTokens: 0,
  usageReports: 0,
};

function bumpStatus(code) {
  const k = String(code);
  stats.byStatus[k] = (stats.byStatus[k] || 0) + 1;
}

function fmtPct(num, den) {
  if (!den || den <= 0) return '-';
  return ((num / den) * 100).toFixed(1) + '%';
}

setInterval(() => {
  const elapsed = ((Date.now() - stats.windowStart) / 1000).toFixed(0);
  const statusStr = Object.entries(stats.byStatus)
    .sort((a, b) => Number(a[0]) - Number(b[0]))
    .map(([k, v]) => `${k}=${v}`)
    .join(',') || '-';
  const winHit = fmtPct(stats.cachedTokens, stats.promptTokens);
  const lifeHit = fmtPct(lifetime.cachedTokens, lifetime.promptTokens);
  log(
    `[summary] window=${elapsed}s req=${stats.req} err=${stats.err}` +
      ` patched=${stats.patched} statuses=${statusStr}` +
      ` usage=${stats.usageReports} prompt=${stats.promptTokens}` +
      ` cached=${stats.cachedTokens} comp=${stats.completionTokens}` +
      ` hit=${winHit} lifetime[req=${lifetime.usageReports}` +
      ` prompt=${lifetime.promptTokens} cached=${lifetime.cachedTokens}` +
      ` comp=${lifetime.completionTokens} hit=${lifeHit}]`,
  );
  stats.req = 0;
  stats.err = 0;
  stats.patched = 0;
  stats.byStatus = Object.create(null);
  stats.promptTokens = 0;
  stats.cachedTokens = 0;
  stats.completionTokens = 0;
  stats.usageReports = 0;
  stats.windowStart = Date.now();
}, 60_000).unref();

// --- usage extraction (Moonshot / OpenAI compatible) ---------------------
//
// Both completions formats expose token usage:
//   * non-stream JSON: { ..., "usage": { "prompt_tokens": N,
//                                        "completion_tokens": M,
//                                        "prompt_tokens_details": { "cached_tokens": K } } }
//   * SSE: usage typically arrives in the FINAL data: line, e.g.
//       data: {"choices":[],"usage":{...}}
//       data: [DONE]
//     Some Moonshot variants emit `cached_tokens` directly under usage.
//
// We accept either layout and silently ignore anything we cannot parse.

function pickUsage(usage) {
  if (!usage || typeof usage !== 'object') return null;
  const prompt = Number(usage.prompt_tokens) || 0;
  const completion = Number(usage.completion_tokens) || 0;
  let cached = 0;
  if (usage.prompt_tokens_details && typeof usage.prompt_tokens_details === 'object') {
    cached = Number(usage.prompt_tokens_details.cached_tokens) || 0;
  }
  if (!cached && usage.cached_tokens != null) {
    cached = Number(usage.cached_tokens) || 0;
  }
  if (prompt === 0 && completion === 0 && cached === 0) return null;
  return { prompt, cached, completion };
}

function recordUsage(u) {
  if (!u) return;
  stats.promptTokens += u.prompt;
  stats.cachedTokens += u.cached;
  stats.completionTokens += u.completion;
  stats.usageReports++;
  lifetime.promptTokens += u.prompt;
  lifetime.cachedTokens += u.cached;
  lifetime.completionTokens += u.completion;
  lifetime.usageReports++;
}

// Scan a text buffer for the LAST `data: {...}` SSE event whose JSON
// payload contains a `usage` object. Returns parsed usage or null.
function extractUsageFromSSE(text) {
  if (!text || typeof text !== 'string') return null;
  // Walk lines from the end backwards (usage is typically last) and
  // return the first `data: {...}` whose JSON has `.usage`.
  const lines = text.split(/\r?\n/);
  for (let i = lines.length - 1; i >= 0; i--) {
    const line = lines[i];
    if (!line.startsWith('data:')) continue;
    const payload = line.slice(5).trim();
    if (!payload || payload === '[DONE]') continue;
    try {
      const obj = JSON.parse(payload);
      if (obj && obj.usage) {
        const u = pickUsage(obj.usage);
        if (u) return u;
      }
    } catch {
      // partial frame -> ignore
    }
  }
  return null;
}

function extractUsageFromJSON(text) {
  if (!text || typeof text !== 'string') return null;
  try {
    const obj = JSON.parse(text);
    if (obj && obj.usage) return pickUsage(obj.usage);
  } catch {
    // not JSON or truncated -> ignore
  }
  return null;
}

// --- patcher --------------------------------------------------------------

/**
 * Inject `reasoning_content: " "` into any assistant message with tool_calls
 * that lacks (or has an empty) reasoning_content field.
 * Mutates `body.messages` in place. Returns the number of messages patched.
 */
function patchMessagesForMoonshot(body) {
  if (!body || !Array.isArray(body.messages)) return 0;
  let patched = 0;
  for (const msg of body.messages) {
    if (!msg || msg.role !== 'assistant') continue;
    if (!Array.isArray(msg.tool_calls) || msg.tool_calls.length === 0) continue;
    const rc = msg.reasoning_content;
    if (typeof rc !== 'string' || rc.trim() === '') {
      msg.reasoning_content = PLACEHOLDER;
      patched++;
    }
  }
  return patched;
}

// --- request body collection ---------------------------------------------

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

// --- header sanitation ---------------------------------------------------

const HOP_BY_HOP = new Set([
  'connection',
  'keep-alive',
  'proxy-authenticate',
  'proxy-authorization',
  'te',
  'trailers',
  'transfer-encoding',
  'upgrade',
  'host',
  'content-length',
]);

function copyHeaders(src) {
  const out = {};
  for (const [k, v] of Object.entries(src)) {
    if (HOP_BY_HOP.has(k.toLowerCase())) continue;
    out[k] = v;
  }
  return out;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function isRetryableUpstreamError(err) {
  if (!err) return false;
  const code = String(err.code || '');
  const msg = String(err.message || '');
  if (code === 'ECONNRESET' || code === 'ETIMEDOUT') return true;
  if (msg.includes('ECONNRESET') || msg.includes('ETIMEDOUT')) return true;
  if (msg.includes('UND_ERR_SOCKET') || msg.includes('UND_ERR_CONNECT_TIMEOUT') || msg.includes('UND_ERR_HEADERS_TIMEOUT')) return true;
  return false;
}

async function requestWithRetry(url, options, reqMeta) {
  let attempt = 0;
  while (true) {
    try {
      return await request(url, options);
    } catch (err) {
      const canRetry = isRetryableUpstreamError(err) && attempt < UPSTREAM_RETRIES;
      if (!canRetry) throw err;
      const waitMs = RETRY_BASE_MS * (attempt + 1);
      log(
        'UPSTREAM RETRY',
        `attempt=${attempt + 1}/${UPSTREAM_RETRIES}`,
        reqMeta,
        String(err.code || ''),
        err.message,
        `wait=${waitMs}ms`,
      );
      await sleep(waitMs);
      attempt++;
    }
  }
}

// safe write that never throws synchronously
function safeWrite(res, chunk) {
  if (!res || res.destroyed || res.writableEnded) return false;
  try {
    return res.write(chunk);
  } catch (err) {
    log('RES WRITE ERROR', err.message);
    return false;
  }
}

function safeEnd(res) {
  if (!res || res.destroyed || res.writableEnded) return;
  try {
    res.end();
  } catch (err) {
    log('RES END ERROR', err.message);
  }
}

// --- main handler --------------------------------------------------------

const server = http.createServer(async (req, res) => {
  const started = Date.now();
  stats.req++;

  // attach res-side error handlers up front so EPIPE etc. don't escape
  res.on('error', (err) => {
    log('RES ERROR', err.code || '', err.message);
  });
  req.on('error', (err) => {
    log('REQ ERROR', err.code || '', err.message);
  });

  let url;
  try {
    url = new URL(req.url, `http://${req.headers.host || HOST + ':' + PORT}`);
  } catch (e) {
    safeWrite(res, '');
    res.writeHead(400, { 'content-type': 'text/plain' });
    safeEnd(res);
    return;
  }

  // Phase 0: Path/Method whitelist
  const barePath = url.pathname.startsWith('/v1/') ? url.pathname.slice(3) : url.pathname;
  if (!ALLOWED_PATHS.has(barePath) || !ALLOWED_METHODS.has(req.method)) {
    stats.err++;
    bumpStatus(405);
    const errHeaders = { 'content-type': 'application/json' };
    for (const [key, value] of Object.entries(SECURITY_HEADERS)) {
      errHeaders[key] = value;
    }
    safeWrite(res, '');
    res.writeHead(405, errHeaders);
    safeEnd(res, JSON.stringify({ error: 'path or method not allowed' }));
    return;
  }

  // health probe (does not touch upstream) — minimal response
  if (url.pathname === '/healthz' || url.pathname === '/_shim/healthz') {
    const healthHeaders = { 'content-type': 'application/json' };
    for (const [key, value] of Object.entries(SECURITY_HEADERS)) {
      healthHeaders[key] = value;
    }
    res.writeHead(200, healthHeaders);
    res.end(JSON.stringify({ status: 'ok' }));
    return;
  }

  // --- Phase 1: Shared Secret check (after healthz, before upstream) --------
  if (SHIM_SECRET && req.headers['x-shim-key'] !== SHIM_SECRET) {
    stats.err++;
    bumpStatus(403);
    const errHeaders = { 'content-type': 'application/json' };
    for (const [key, value] of Object.entries(SECURITY_HEADERS)) {
      errHeaders[key] = value;
    }
    res.writeHead(403, errHeaders);
    safeEnd(res, JSON.stringify({ error: 'shim secret required or invalid' }));
    log('SHIM SECRET REJECT', req.method, req.url, 'missing or invalid key');
    return;
  }

  // /v1/foo  -> TARGET + /foo  (TARGET already ends with /v1, no trailing slash)
  // /foo     -> TARGET + /foo  (defensive: client forgot the /v1 prefix)
  let upstreamPath = url.pathname;
  if (upstreamPath.startsWith('/v1/')) upstreamPath = upstreamPath.slice(3);
  else if (upstreamPath === '/v1') upstreamPath = '';
  const upstreamUrl = TARGET + upstreamPath + url.search;

  // Read body. We always buffer because we may need to mutate JSON.
  let raw;
  try {
    raw = await readBody(req);
  } catch (err) {
    stats.err++;
    log('REQ READ ERROR', err.message);
    try {
      res.writeHead(400, { 'content-type': 'text/plain' });
      res.end('shim: failed to read request body: ' + err.message);
    } catch {}
    return;
  }

  let bodyToSend = raw.length > 0 ? raw : undefined;
  let patchInfo = '';

  if (req.method === 'POST' && raw.length > 0) {
    let json = null;
    try {
      json = JSON.parse(raw.toString('utf8'));
    } catch {
      // not JSON -> pass through untouched
    }
    if (json && Array.isArray(json.messages)) {
      const n = patchMessagesForMoonshot(json);
      stats.patched += n;
      try {
        bodyToSend = Buffer.from(JSON.stringify(json), 'utf8');
      } catch (err) {
        log('JSON STRINGIFY ERROR', err.message);
        bodyToSend = raw; // fall back to original bytes
      }
      patchInfo = ` model=${json.model || '?'} msgs=${json.messages.length} patched=${n} stream=${!!json.stream}`;
      if (DEBUG && n > 0) dlog(`patched ${n} assistant.tool_calls message(s)`);
    }
  }

  const upstreamHeaders = copyHeaders(req.headers);
  if (bodyToSend) upstreamHeaders['content-length'] = String(bodyToSend.length);

  let upstream;
  try {
    upstream = await requestWithRetry(
      upstreamUrl,
      {
      method: req.method,
      headers: upstreamHeaders,
      body: bodyToSend,
      maxRedirections: 0,
      },
      `${req.method} ${upstreamUrl}`,
    );
  } catch (err) {
    stats.err++;
    bumpStatus(502);
    log('UPSTREAM ERROR', req.method, upstreamUrl, err.message);
    try {
      res.writeHead(502, { 'content-type': 'application/json' });
      res.end(
        JSON.stringify({
          error: {
            message: 'shim: upstream connect error: ' + err.message,
            type: 'shim_upstream_error',
          },
        }),
      );
    } catch {}
    return;
  }

  bumpStatus(upstream.statusCode);

  const respHeaders = copyHeaders(upstream.headers);
  const ct = String(upstream.headers['content-type'] || '');
  const isSSE = ct.includes('text/event-stream');

  // For SSE responses, discourage intermediate proxies from buffering and
  // make explicit that nothing along the path should hold chunks back.
  // X-Accel-Buffering: no  -> nginx-style hint (also honoured by some CDNs)
  // Cache-Control          -> rule out edge caching of the stream
  if (isSSE) {
    respHeaders['x-accel-buffering'] = 'no';
    respHeaders['cache-control'] = 'no-cache, no-transform';
  }

  // Phase 0: Security headers on every response
  for (const [key, value] of Object.entries(SECURITY_HEADERS)) {
    respHeaders[key] = value;
  }

  try {
    res.writeHead(upstream.statusCode, respHeaders);
  } catch (err) {
    log('RES WRITEHEAD ERROR', err.message);
    try { upstream.body.destroy(); } catch {}
    return;
  }

  // For SSE, enable TCP keep-alive on the client socket so the kernel
  // emits keep-alive probes during the long upstream-thinking gaps.
  // This protects the path from middleboxes (CGNAT, corporate firewalls,
  // home routers) that drop "silent" TCP sessions before any HTTP/SSE
  // layer notices.
  if (isSSE && TCP_KEEPALIVE_MS > 0) {
    try {
      const sock = res.socket || req.socket;
      if (sock && typeof sock.setKeepAlive === 'function') {
        sock.setKeepAlive(true, TCP_KEEPALIVE_MS);
        if (typeof sock.setNoDelay === 'function') sock.setNoDelay(true);
      }
    } catch (err) {
      log('TCP KEEPALIVE SET ERROR', err.message);
    }
  }
  let lastWriteAt = Date.now();
  let keepAliveTimer = null;
  let keepAliveCount = 0;

  function stopKeepAlive() {
    if (keepAliveTimer) {
      clearInterval(keepAliveTimer);
      keepAliveTimer = null;
    }
  }

  if (isSSE && KEEPALIVE_INTERVAL_MS > 0) {
    const tick = Math.max(1000, Math.floor(KEEPALIVE_INTERVAL_MS / 2));
    keepAliveTimer = setInterval(() => {
      if (!res || res.destroyed || res.writableEnded) {
        stopKeepAlive();
        return;
      }
      if (Date.now() - lastWriteAt >= KEEPALIVE_INTERVAL_MS) {
        if (safeWrite(res, ': keepalive\n\n')) {
          lastWriteAt = Date.now();
          keepAliveCount++;
        }
      }
    }, tick);
    keepAliveTimer.unref();
  }

  // Capture (a small bounded suffix of) the upstream body so we can pull
  // out the usage block at end-of-response without paying for unbounded
  // memory on long SSE streams.
  const USAGE_BUF_MAX = 64 * 1024; // last 64 KB is more than enough for a usage frame
  let usageBuf = '';
  function appendForUsage(chunkStr) {
    if (!chunkStr) return;
    usageBuf += chunkStr;
    if (usageBuf.length > USAGE_BUF_MAX) {
      usageBuf = usageBuf.slice(-USAGE_BUF_MAX);
    }
  }

  upstream.body.on('data', (c) => {
    if (safeWrite(res, c)) lastWriteAt = Date.now();
    try { appendForUsage(c.toString('utf8')); } catch {}
  });
  upstream.body.on('end', () => {
    stopKeepAlive();
    safeEnd(res);
    const ms = Date.now() - started;
    const ka = isSSE && keepAliveCount > 0 ? ` keepalive=${keepAliveCount}` : '';
    let usage = null;
    try {
      usage = isSSE ? extractUsageFromSSE(usageBuf) : extractUsageFromJSON(usageBuf);
    } catch (err) {
      log('USAGE PARSE ERROR', err.message);
    }
    let usageStr = '';
    if (usage) {
      recordUsage(usage);
      const hit = fmtPct(usage.cached, usage.prompt);
      usageStr = ` prompt=${usage.prompt} cached=${usage.cached} comp=${usage.completion} hit=${hit}`;
    }
    log(`${req.method} ${url.pathname} -> ${upstream.statusCode} ${ms}ms${patchInfo}${ka}${usageStr}`);
  });
  upstream.body.on('error', (err) => {
    stats.err++;
    stopKeepAlive();
    log('UPSTREAM BODY ERROR', err.message);
    safeEnd(res);
  });

  req.on('close', () => {
    stopKeepAlive();
    if (!res.writableEnded) {
      try { upstream.body.destroy(); } catch {}
    }
  });
});

server.on('clientError', (err, socket) => {
  log('CLIENT ERROR', err.code || '', err.message);
  try { socket.destroy(); } catch {}
});

server.on('error', (err) => {
  log('SERVER ERROR', err.code || '', err.message);
});

// --- top-level safety net ------------------------------------------------
// Catch everything that escaped per-request handlers so the process does
// NOT die. This is the single most important reason the previous shim
// vanished without a useful trace.

process.on('uncaughtException', (err) => {
  log('UNCAUGHT EXCEPTION', err && err.stack ? err.stack : String(err));
});
process.on('unhandledRejection', (reason) => {
  const s = reason && reason.stack ? reason.stack : String(reason);
  log('UNHANDLED REJECTION', s);
});

// Long-running SSE responses can outlast Node's default HTTP timeouts.
// requestTimeout=0 disables the per-request timer entirely (safe here:
// shim is bound to localhost / public access via Tailscale Funnel only).
// headersTimeout must be > keepAliveTimeout per Node docs.
server.requestTimeout = 0;
server.keepAliveTimeout = 600_000;   // 10 min idle keep-alive between requests
server.headersTimeout = 605_000;     // must exceed keepAliveTimeout
server.timeout = 0;                  // no socket inactivity timeout

server.listen(PORT, HOST, () => {
  log(`moonshot-shim listening on http://${HOST}:${PORT} pid=${process.pid}`);
  log(`forwarding to ${TARGET}`);
  log(`log file: ${LOG_PATH}`);
  log('reasoning_content patcher: enabled (assistant.tool_calls -> placeholder " ")');
  log(`SSE keepalive: ${KEEPALIVE_INTERVAL_MS}ms  TCP keepalive: ${TCP_KEEPALIVE_MS}ms`);
  log('cache hit accounting: enabled (parses usage from SSE / JSON responses)');
  log('healthz: GET http://' + HOST + ':' + PORT + '/healthz');
  log('point your client "Override OpenAI Base URL" at http://' + HOST + ':' + PORT + '/v1');
  if (DEBUG) log('debug mode ON (SHIM_DEBUG=1)');
});

function shutdown(sig) {
  log(`received ${sig}, shutting down`);
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 2000).unref();
}
process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
