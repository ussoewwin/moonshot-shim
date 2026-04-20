// test harness:
//   - spins up a local "Moonshot" echo server on :18787 that echoes the
//     received POST body back as JSON
//   - boots a fresh shim instance pointed at that echo server
//   - sends a multi-turn conversation with assistant.tool_calls but WITHOUT
//     reasoning_content
//   - verifies the echo response shows reasoning_content has been injected
//
// Run from the shim folder:
//   node test-echo.mjs

import http from 'node:http';
import { spawn } from 'node:child_process';
import { request } from 'undici';
import { setTimeout as sleep } from 'node:timers/promises';

const ECHO_PORT = 18787;
const SHIM_PORT = 18788;

let echoLog = null;

const echo = http.createServer(async (req, res) => {
  const chunks = [];
  for await (const c of req) chunks.push(c);
  const raw = Buffer.concat(chunks);
  let body = null;
  try { body = JSON.parse(raw.toString('utf8')); } catch {}
  echoLog = { method: req.method, url: req.url, headers: req.headers, body };
  res.writeHead(200, { 'content-type': 'application/json' });
  res.end(JSON.stringify({ ok: true, received: body }));
});

await new Promise((r) => echo.listen(ECHO_PORT, '127.0.0.1', r));
console.log('echo up on', ECHO_PORT);

const shim = spawn(process.execPath, ['server.js'], {
  env: {
    ...process.env,
    SHIM_PORT: String(SHIM_PORT),
    SHIM_HOST: '127.0.0.1',
    SHIM_TARGET: `http://127.0.0.1:${ECHO_PORT}/v1`,
    SHIM_DEBUG: '1',
  },
  stdio: ['ignore', 'inherit', 'inherit'],
});

await sleep(800);

const reqBody = {
  model: 'kimi-k2.6',
  stream: false,
  messages: [
    { role: 'system', content: 'you are kimi' },
    { role: 'user', content: 'read foo.txt' },
    {
      role: 'assistant',
      content: '',
      tool_calls: [
        {
          id: 'call_1',
          type: 'function',
          function: { name: 'read_file', arguments: '{"path":"foo.txt"}' },
        },
      ],
    },
    { role: 'tool', tool_call_id: 'call_1', content: 'hello world' },
    { role: 'user', content: 'now what?' },
  ],
};

const resp = await request(`http://127.0.0.1:${SHIM_PORT}/v1/chat/completions`, {
  method: 'POST',
  headers: { 'content-type': 'application/json', authorization: 'Bearer test-key' },
  body: JSON.stringify(reqBody),
});

const respText = await resp.body.text();
console.log('shim response status:', resp.statusCode);
console.log('shim response body:', respText);

console.log('\n--- echo received ---');
console.log('method:', echoLog.method);
console.log('url:', echoLog.url);
console.log('authorization:', echoLog.headers.authorization);

const assistantMsg = echoLog.body.messages[2];
console.log('\nassistant message after passing through shim:');
console.log(JSON.stringify(assistantMsg, null, 2));

const ok =
  assistantMsg &&
  assistantMsg.role === 'assistant' &&
  Array.isArray(assistantMsg.tool_calls) &&
  typeof assistantMsg.reasoning_content === 'string' &&
  assistantMsg.reasoning_content.length > 0;

console.log('\n=== reasoning_content injected:', ok ? 'PASS' : 'FAIL', '===');

shim.kill();
echo.close();
process.exit(ok ? 0 : 1);
