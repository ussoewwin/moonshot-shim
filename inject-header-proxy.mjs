// inject-header-proxy.mjs
// Ultra-thin proxy that injects X-Shim-Key into every request.
// Sits between Tailscale Funnel (port 8788) and server.js (port 8787).
//
// Cursor's Override Base URL is the public tunnel URL — unchanged.
// Tailscale Funnel sends traffic to port 8788.
// This proxy adds X-Shim-Key and forwards to server.js on port 8787.

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// Read secret from env or from _shim_secret.txt in the repo root
let SHIM_SECRET = process.env.SHIM_SECRET || '';
if (!SHIM_SECRET) {
  const secretPath = path.join(__dirname, '_shim_secret.txt');
  try {
    SHIM_SECRET = fs.readFileSync(secretPath, 'utf8').trim();
  } catch {
    console.error('FATAL: SHIM_SECRET not set and _shim_secret.txt not found');
    process.exit(1);
  }
}
if (SHIM_SECRET.length < 32) {
  console.error('FATAL: SHIM_SECRET must be at least 32 characters');
  process.exit(1);
}

const TARGET_PORT = parseInt(process.env.SHIM_PORT || '8787', 10);
const LISTEN_PORT = parseInt(process.env.INJECT_PORT || '8788', 10);

http.createServer((req, res) => {
  const options = {
    hostname: '127.0.0.1',
    port: TARGET_PORT,
    path: req.url,
    method: req.method,
    headers: { ...req.headers, 'x-shim-key': SHIM_SECRET },
  };

  const proxy = http.request(options, (upRes) => {
    res.writeHead(upRes.statusCode, upRes.headers);
    upRes.pipe(res);
  });

  req.pipe(proxy);

  proxy.on('error', (err) => {
    try {
      res.writeHead(502, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: 'inject-header-proxy: ' + err.message }));
    } catch {}
  });

  res.on('error', () => {
    try { proxy.destroy(); } catch {}
  });
}).listen(LISTEN_PORT, '127.0.0.1', () => {
  console.log(`inject-header-proxy listening on 127.0.0.1:${LISTEN_PORT} -> 127.0.0.1:${TARGET_PORT}`);
});
