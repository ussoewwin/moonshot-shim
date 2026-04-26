# Cache Hit Rate Logging in moonshot-shim

> Document version: 2026-04-26  
> Scope: `server.js` only  
> Language: English

---

## 1. Why this feature was added

### 1.1 The problem

Moonshot's Context Caching pricing is very attractive — a cache **hit** costs only ~$0.16 / M tokens, while a cache **miss** costs ~$0.95 / M tokens (nearly 6× more).  However, the Moonshot web dashboard only shows a raw dollar total for "Context Caching" consumption.  It does **not** expose:

- what percentage of requests actually hit the cache,
- the exact token split between `prompt_tokens` and `cached_tokens` for a single request, or
- a time-series view of cache effectiveness.

In other words, a user can see "I spent $1.90 on caching today" but cannot tell whether that means:

| Scenario | Meaning |
|---|---|
| High spend, high hit rate | The cache is working well; you are simply sending a lot of tokens. |
| High spend, low hit rate | The cache is barely helping; most tokens are billed at the expensive miss rate. |

Without per-request visibility, optimisation is guesswork.

### 1.2 The shim is the ideal place to measure

The `moonshot-shim` already sits in the middle of every request.  Both streaming (SSE) and non-streaming JSON responses from Moonshot contain a `usage` object that carries the token accounting we need.  By parsing that object inside the proxy, we can:

1. **Log the cache hit rate for every single request** — no client-side changes required.
2. **Emit a per-minute summary** that shows both the last 60-second window and the cumulative lifetime totals.
3. **Keep the measurement server-side** so it works identically for Cursor, OpenClaude, or any other OpenAI-compatible client.

### 1.3 What the user gets

After the feature is enabled, the shim log contains lines like this:

```
POST /v1/chat/completions -> 200 14213ms model=kimi-k2.6 msgs=12 patched=2 stream=true keepalive=3 prompt=15234 cached=12100 comp=420 hit=79.4%
```

and every 60 seconds:

```
[summary] window=60s req=8 err=0 patched=4 statuses=200=8 usage=8 prompt=98432 cached=72100 comp=2310 hit=73.2% lifetime[req=143 prompt=1842311 cached=1320444 comp=42100 hit=71.7%]
```

From these lines the user can immediately see:

- **Per-request**: how many tokens were cached vs. fresh prompt tokens.
- **Per-minute**: whether the cache hit rate is improving or degrading over time.
- **Lifetime**: the long-term average since the shim was last restarted.

---

## 2. File changed

| File | Change type |
|---|---|
| `server.js` | **Modified only** — all new code is contained in this single file. |

No new dependencies, no configuration files, no client-side changes.

---

## 3. Code details and meaning

The implementation is organised into four logical layers:

1. **Usage extraction helpers** — parse the upstream response.
2. **Accumulators** — maintain per-minute and lifetime counters.
3. **Streaming instrumentation** — capture the upstream body without unbounded memory growth.
4. **Log output** — append the numbers to the existing request and summary log lines.

### 3.1 Usage extraction helpers

#### `pickUsage(usage)`

```javascript
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
```

**What it does**

Takes a raw `usage` object (from the upstream JSON or SSE payload) and normalises it into a small, well-defined record:

| Field | Source |
|---|---|
| `prompt` | `usage.prompt_tokens` |
| `completion` | `usage.completion_tokens` |
| `cached` | First tries `usage.prompt_tokens_details.cached_tokens` (OpenAI-compatible layout).  If that is missing or zero, falls back to `usage.cached_tokens` (Moonshot-specific layout). |

**Why two sources for `cached`**

- The OpenAI API spec places cached tokens under `usage.prompt_tokens_details.cached_tokens`.
- Moonshot sometimes emits a top-level `usage.cached_tokens` instead.
- The helper tries the standard key first, then the proprietary key, so it works regardless of which format the upstream returns on any given day.

If all three numbers are zero, the function returns `null` to avoid polluting the statistics with empty usage blocks.

---

#### `extractUsageFromSSE(text)`

```javascript
function extractUsageFromSSE(text) {
  if (!text || typeof text !== 'string') return null;
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
```

**What it does**

Scans a block of SSE text **backwards** (from the last line towards the first) looking for `data: {...}` lines that contain a `usage` field.  Returns the first match it finds.

**Why scan backwards**

In OpenAI-compatible SSE streams, the `usage` object is usually delivered in the **final** data frame, after all content chunks have been sent.  By walking from the end, we reach the correct frame in O(1) average time instead of parsing the entire stream front-to-back.

**Why the `try/catch` around `JSON.parse`**

The trailing buffer may contain a partial SSE line that was split in the middle of a chunk.  `JSON.parse` would throw on such a fragment; we simply ignore it and continue scanning earlier lines.

---

#### `extractUsageFromJSON(text)`

```javascript
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
```

**What it does**

A thin wrapper for non-streaming JSON responses (when `stream: false`).  It parses the entire response body as JSON and delegates to `pickUsage`.

---

### 3.2 Accumulators

#### `stats` (per-minute window)

```javascript
const stats = {
  req: 0,
  err: 0,
  patched: 0,
  byStatus: Object.create(null),
  promptTokens: 0,
  cachedTokens: 0,
  completionTokens: 0,
  usageReports: 0,
  windowStart: Date.now(),
};
```

Four new numeric fields were added to the existing `stats` object:

| Field | Meaning |
|---|---|
| `promptTokens` | Sum of `prompt` tokens seen in this 60-second window. |
| `cachedTokens` | Sum of `cached` tokens seen in this 60-second window. |
| `completionTokens` | Sum of `completion` tokens seen in this 60-second window. |
| `usageReports` | How many upstream responses in this window carried a usable `usage` block. |

These counters are **reset to zero** every time the summary line is emitted.

---

#### `lifetime` (cumulative, never reset)

```javascript
const lifetime = {
  promptTokens: 0,
  cachedTokens: 0,
  completionTokens: 0,
  usageReports: 0,
};
```

A separate accumulator that lives for the entire process lifetime.  It is useful when you open the log file hours or days after the shim started and want to know the **overall** cache efficiency since boot, without adding up every per-minute summary manually.

---

#### `recordUsage(u)`

```javascript
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
```

**What it does**

Atomically adds a single parsed usage record to **both** accumulators.  Called once per request, immediately after the upstream body has finished streaming.

---

#### `fmtPct(num, den)`

```javascript
function fmtPct(num, den) {
  if (!den || den <= 0) return '-';
  return ((num / den) * 100).toFixed(1) + '%';
}
```

A small formatter that guards against division by zero and emits a human-readable percentage string (`79.4%`).  Returns `'-'` when no prompt tokens have been recorded yet.

---

### 3.3 Streaming instrumentation

#### Bounded buffer: `usageBuf`

```javascript
const USAGE_BUF_MAX = 64 * 1024; // last 64 KB
let usageBuf = '';
function appendForUsage(chunkStr) {
  if (!chunkStr) return;
  usageBuf += chunkStr;
  if (usageBuf.length > USAGE_BUF_MAX) {
    usageBuf = usageBuf.slice(-USAGE_BUF_MAX);
  }
}
```

**The problem it solves**

SSE streams from Moonshot can be very long (hundreds of KB or even MB) when the model produces a lengthy reasoning chain followed by a long completion.  If we buffered the **entire** stream in memory just to find the final `usage` frame, the shim would leak memory proportionally to response size.

**The solution**

Only the **last 64 KB** of the upstream text is retained.  The `usage` frame is typically a tiny JSON object (well under 1 KB) that appears at the very end of the stream, so 64 KB is more than enough headroom.  If the frame ever grows larger, the buffer will simply drop older content from the front, keeping memory bounded.

---

#### Patching the `data` event handler

```javascript
upstream.body.on('data', (c) => {
  if (safeWrite(res, c)) lastWriteAt = Date.now();
  try { appendForUsage(c.toString('utf8')); } catch {}
});
```

Every chunk that arrives from Moonshot is still forwarded to the client immediately (preserving low latency), but is also appended to `usageBuf` in UTF-8 text form.  The `try/catch` ensures that a malformed chunk or encoding edge case does not crash the proxy.

---

#### End-of-stream parsing

```javascript
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
```

**Step-by-step flow**

1. **Stop keepalive timer** — the response is finished; no more idle pings are needed.
2. **Close the downstream socket** cleanly with `safeEnd`.
3. **Measure elapsed time** (`ms`) for the existing request log.
4. **Extract usage**:  
   - If `isSSE === true`, call `extractUsageFromSSE(usageBuf)`.  
   - Otherwise, call `extractUsageFromJSON(usageBuf)`.
5. **If extraction succeeded**:  
   - `recordUsage(usage)` updates both `stats` and `lifetime`.  
   - Format a `usageStr` fragment like ` prompt=15234 cached=12100 comp=420 hit=79.4%`.
6. **Emit the log line** with the new fragment appended.

Because the `usage` object is typically delivered in the **final** SSE frame, the extraction happens exactly once per request, right after the stream ends.

---

### 3.4 Updated per-minute summary

The existing `setInterval` summary was extended to include the new counters and the lifetime totals:

```javascript
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
  // ... reset window counters, including the new token fields ...
}, 60_000).unref();
```

**What changed**

| Before | After |
|---|---|
| `req=… err=… patched=… statuses=…` | Same fields, **plus** `usage=… prompt=… cached=… comp=… hit=…%` |
| No lifetime data | `lifetime[req=… prompt=… cached=… comp=… hit=…%]` appended |

The reset block at the end of the interval now also zeroes `promptTokens`, `cachedTokens`, `completionTokens`, and `usageReports` so the next window starts fresh.

---

### 3.5 Startup banner

A single log line was added to the boot banner so the user knows the feature is active:

```javascript
log('cache hit accounting: enabled (parses usage from SSE / JSON responses)');
```

This appears once in the log file, immediately after the keepalive configuration lines.

---

## 4. Log examples and how to read them

### 4.1 Single request (streaming)

```
2026-04-26T07:12:34.123Z POST /v1/chat/completions -> 200 14213ms model=kimi-k2.6 msgs=12 patched=2 stream=true keepalive=3 prompt=15234 cached=12100 comp=420 hit=79.4%
```

| Token | Meaning |
|---|---|
| `prompt=15234` | 15,234 prompt tokens were sent to Moonshot for this request. |
| `cached=12100` | Of those, 12,100 tokens were served from cache (cheap). |
| `comp=420` | 420 completion tokens were generated by the model. |
| `hit=79.4%` | 12,100 / 15,234 ≈ 79.4% of prompt tokens were cache hits. |

---

### 4.2 Per-minute summary

```
2026-04-26T07:13:00.000Z [summary] window=60s req=8 err=0 patched=4 statuses=200=8 usage=8 prompt=98432 cached=72100 comp=2310 hit=73.2% lifetime[req=143 prompt=1842311 cached=1320444 comp=42100 hit=71.7%]
```

| Token | Meaning |
|---|---|
| `window=60s` | The summary covers the last 60-second interval. |
| `usage=8` | 8 upstream responses carried a usable `usage` block. |
| `prompt=98432` | 98,432 prompt tokens total in this window. |
| `cached=72100` | 72,100 of those were cache hits. |
| `hit=73.2%` | Window cache hit rate. |
| `lifetime[… hit=71.7%]` | Cumulative hit rate since the shim started. |

---

## 5. Troubleshooting

| Symptom | Likely cause | What to check |
|---|---|---|
| `hit=-` on every request | Upstream is not sending `usage` | Verify the model is `kimi-k2.6` (some older models omit `usage` in SSE). |
| `cached=0` but you expected hits | Context cache not enabled, or the prompt changed significantly | Ensure you are sending `context caching` headers / parameters in the upstream request. |
| `USAGE PARSE ERROR` in log | A malformed JSON fragment reached the buffer | Usually harmless; the next valid frame will still be parsed.  If frequent, open an issue with a log excerpt. |
| Large discrepancy between `prompt` and `cached` + `comp` | The `usage` block may be using a different schema | Check the raw SSE payload for `cached_tokens` vs `prompt_tokens_details.cached_tokens`. |

---

## 6. Compatibility notes

- **Client agnostic**: Works with Cursor, OpenClaude, Cline, or any other tool that speaks OpenAI-compatible HTTP through the shim.
- **Model agnostic**: Parses whatever `usage` the upstream returns.  If Moonshot changes the schema in the future, only `pickUsage` needs a one-line addition.
- **No configuration required**: The feature is always on.  There is no environment variable to toggle it because the overhead is negligible (a few string operations per request).
- **Memory safe**: The SSE buffer is capped at 64 KB.  Even for multi-MB streams, memory usage does not grow with response size.

---

## 7. Appendix: Full diff summary

| Metric | Before | After |
|---|---|---|
| File(s) touched | — | `server.js` only |
| New functions | — | `pickUsage`, `extractUsageFromSSE`, `extractUsageFromJSON`, `recordUsage`, `appendForUsage`, `fmtPct` |
| New accumulators | — | `stats.promptTokens`, `stats.cachedTokens`, `stats.completionTokens`, `stats.usageReports`, plus the `lifetime` object |
| Modified event handlers | `upstream.body.on('data')`, `upstream.body.on('end')` | Same handlers, now also buffer and parse usage |
| Modified summary | `req`, `err`, `patched`, `statuses` | Same fields + `usage`, `prompt`, `cached`, `comp`, `hit`, and `lifetime[…]` |
| Startup log | keepalive + TCP keepalive lines | Same + `cache hit accounting: enabled …` |
| Dependencies added | — | None |
| Breaking changes | — | None |
