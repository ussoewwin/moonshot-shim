#!/usr/bin/env node
// ollama-bridge.mjs
//
// Small conversion proxy: OpenAI chat/completions on the front, Ollama native
// /api/chat on the back. Exists because Ollama 0.40.x's own /v1 OpenAI-compat
// layer does not correctly separate thinking from content for gemma4 models
// (content comes back garbled/empty while native /api/chat works fine).
//
//   AutoClaw -> http://127.0.0.1:8801/v1/chat/completions -> http://127.0.0.1:11434/api/chat
//
// OpenAI request -> Ollama native request mapping:
//   messages                       -> messages (same shape; system->system, user->user,
//                                     assistant->assistant with optional images field)
//   model                          -> model (default: gemma4-31b-ara-heretic)
//   max_tokens                     -> options.num_predict
//   temperature / top_p / stop     -> options.*
//   stream                         -> stream (converted back to SSE on the way out)
//
// Ollama response -> OpenAI response mapping:
//   message.content                -> choices[0].message.content
//   message.thinking               -> choices[0].message.reasoning_content
//   prompt_eval_count / eval_count -> usage.prompt_tokens / completion_tokens
//
// Loopback-only binding. No auth (local only). Auto-restart handled by wrapper.

import http from 'node:http';
import crypto from 'node:crypto';

const PORT = parseInt(process.env.BRIDGE_PORT || '8801', 10);
const HOST = process.env.BRIDGE_HOST || '127.0.0.1';
const OLLAMA = (process.env.OLLAMA_URL || 'http://127.0.0.1:11434').replace(/\/+$/, '');
const DEFAULT_MODEL = process.env.BRIDGE_MODEL || 'gemma4-31b-ara-heretic';
const THINK = process.env.BRIDGE_THINK !== '0'; // default: let Ollama handle thinking separation

function log(msg) {
  console.log(new Date().toISOString() + ' ' + msg);
}

function sendJSON(res, status, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(status, {
    'content-type': 'application/json',
    'content-length': Buffer.byteLength(body),
    'access-control-allow-origin': '*',
  });
  res.end(body);
}

function mapToOllama(openaiBody) {
  const messages = Array.isArray(openaiBody.messages) ? openaiBody.messages : [];
  // Convert messages to Ollama native format
  const oMessages = messages.map((m) => {
    const o = { role: m.role, content: typeof m.content === 'string' ? m.content : JSON.stringify(m.content) };
    if (m.role === 'assistant' && m.reasoning_content) {
      // Re-inject prior thinking as part of the assistant message so Ollama can
      // maintain context continuity. Ollama uses the "thinking" field natively.
      o.thinking = m.reasoning_content;
    }
    if (m.role === 'assistant' && Array.isArray(m.tool_calls)) {
      o.tool_calls = m.tool_calls.map((tc) => ({
        function: {
          name: tc.function?.name || tc.name || '',
          arguments: (() => { try { return JSON.parse(tc.function?.arguments || '{}'); } catch { return {}; } })(),
        },
      }));
    }
    return o;
  });

  const options = {};
  if (openaiBody.max_tokens) options.num_predict = openaiBody.max_tokens;
  if (openaiBody.temperature !== undefined) options.temperature = openaiBody.temperature;
  if (openaiBody.top_p !== undefined) options.top_p = openaiBody.top_p;
  if (Array.isArray(openaiBody.stop)) options.stop = openaiBody.stop;
  else if (openaiBody.stop) options.stop = [openaiBody.stop];

  const out = {
    model: openaiBody.model || DEFAULT_MODEL,
    messages: oMessages,
    stream: !!openaiBody.stream,
    think: THINK,
  };
  if (Object.keys(options).length > 0) out.options = options;
  return out;
}

function mapFromOllama(ollamaJson, reqModel) {
  const msg = ollamaJson.message || {};
  const content = msg.content || '';
  const thinking = msg.thinking || '';
  const message = { role: 'assistant', content };
  if (thinking) message.reasoning_content = thinking;
  if (Array.isArray(msg.tool_calls) && msg.tool_calls.length > 0) {
    message.tool_calls = msg.tool_calls.map((tc, i) => ({
      id: 'call_' + crypto.randomBytes(8).toString('hex'),
      type: 'function',
      function: {
        name: tc.function?.name || '',
        arguments: typeof tc.function?.arguments === 'string' ? tc.function.arguments : JSON.stringify(tc.function?.arguments || {}),
      },
    }));
    message.content = message.content || '';
  }
  const usage = {
    prompt_tokens: ollamaJson.prompt_eval_count || 0,
    completion_tokens: ollamaJson.eval_count || 0,
    total_tokens: (ollamaJson.prompt_eval_count || 0) + (ollamaJson.eval_count || 0),
  };
  usage.prompt_tokens_details = { cached_tokens: 0 };
  usage.completion_tokens_details = { reasoning_tokens: thinking ? (ollamaJson.eval_count || 0) : 0 };
  return {
    id: 'chatcmpl-' + crypto.randomBytes(12).toString('hex'),
    object: 'chat.completion',
    created: Math.floor(Date.now() / 1000),
    model: reqModel || DEFAULT_MODEL,
    choices: [{
      index: 0,
      message,
      finish_reason: ollamaJson.done_reason || 'stop',
    }],
    usage,
  };
}

const server = http.createServer(async (req, res) => {
  const started = Date.now();
  const url = new URL(req.url, `http://${req.headers.host || HOST + ':' + PORT}`);

  // healthz
  if (url.pathname === '/healthz') {
    const h = { 'content-type': 'application/json' };
    res.writeHead(200, h);
    res.end(JSON.stringify({ status: 'ok' }));
    return;
  }

  // models list: proxy to Ollama native /api/tags, return OpenAI shape
  if (url.pathname === '/v1/models' || url.pathname === '/models') {
    try {
      const r = await fetch(OLLAMA + '/api/tags');
      const data = await r.json();
      sendJSON(res, 200, {
        object: 'list',
        data: (data.models || []).map((m) => ({ id: m.name, object: 'model', owned_by: 'ollama' })),
      });
    } catch (e) {
      sendJSON(res, 502, { error: { message: 'ollama unreachable: ' + e.message } });
    }
    return;
  }

  // chat completions
  if (url.pathname === '/v1/chat/completions' && req.method === 'POST') {
    let raw = '';
    req.on('data', (c) => raw += c);
    req.on('end', async () => {
      let openai;
      try { openai = JSON.parse(raw); } catch { sendJSON(res, 400, { error: { message: 'invalid JSON' } }); return; }

      const ollamaBody = mapToOllama(openai);
      const isStream = !!openai.stream;
      const reqModel = openai.model || DEFAULT_MODEL;

      try {
        const upstream = await fetch(OLLAMA + '/api/chat', {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify(ollamaBody),
        });

        if (!isStream) {
          const data = await upstream.json();
          sendJSON(res, upstream.status, mapFromOllama(data, reqModel));
          log(`${req.method} ${url.pathname} -> ${upstream.statusCode} ${Date.now() - started}ms model=${ollamaBody.model} msgs=${ollamaBody.messages.length}`);
          return;
        }

        // Stream: convert Ollama NDJSON -> OpenAI SSE
        res.writeHead(200, {
          'content-type': 'text/event-stream',
          'cache-control': 'no-cache',
          'connection': 'keep-alive',
          'x-accel-buffering': 'no',
        });
        const id = 'chatcmpl-' + crypto.randomBytes(12).toString('hex');
        let buf = '';
        upstream.body.on('data', (c) => {
          buf += c.toString('utf8');
          let idx;
          while ((idx = buf.indexOf('\n')) >= 0) {
            const line = buf.slice(0, idx).trim();
            buf = buf.slice(idx + 1);
            if (!line) continue;
            try {
              const o = JSON.parse(line);
              if (o.done) {
                res.write('data: [DONE]\n\n');
                return;
              }
              const delta = {};
              if (o.message?.thinking) delta.reasoning_content = o.message.thinking;
              if (o.message?.content) delta.content = o.message.content;
              if (Object.keys(delta).length === 0) return;
              res.write('data: ' + JSON.stringify({
                id, object: 'chat.completion.chunk', created: Math.floor(Date.now() / 1000), model: reqModel,
                choices: [{ index: 0, delta, finish_reason: null }],
              }) + '\n\n');
            } catch {}
          }
        });
        upstream.body.on('end', () => {
          res.write('data: [DONE]\n\n');
          res.end();
          log(`${req.method} ${url.pathname} -> 200 (stream) ${Date.now() - started}ms model=${ollamaBody.model}`);
        });
        upstream.body.on('error', () => { try { res.end(); } catch {} });
      } catch (e) {
        sendJSON(res, 502, { error: { message: 'ollama unreachable: ' + e.message } });
        log(`ERROR ${e.message}`);
      }
    });
    return;
  }

  // fallback: not supported
  sendJSON(res, 404, { error: { message: 'not found: ' + url.pathname + '. Supported: /v1/chat/completions, /v1/models, /healthz' } });
});

server.listen(PORT, HOST, () => {
  log(`ollama-bridge listening on http://${HOST}:${PORT}`);
  log(`upstream: ${OLLAMA}/api/chat  default model: ${DEFAULT_MODEL}  think: ${THINK}`);
});

process.on('uncaughtException', (e) => log('UNCAUGHT: ' + e.message));
process.on('unhandledRejection', (e) => log('UNHANDLED: ' + (e?.message || e)));
