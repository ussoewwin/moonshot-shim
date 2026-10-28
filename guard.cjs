// moonshot-shim security guard (SHIM_GUARD)
//
// The proxy sees everything a model emits toward a tool before it runs. This
// module inspects that point. Two shape-based checks (no domain allow-lists:
// a trusted host can carry the payload, so form is what matters):
//
//   1. provenance   - URLs and schemeless host/path forms inside an assistant
//      tool_call argument that appear nowhere in the client's own request
//      (user / system / tool messages + tool definitions). A backdoored model
//      emits a location it learned in training; the user never typed it.
//      Assistant-authored history is deliberately excluded from provenance, so
//      earlier model output cannot legitimize later model output. Every turn is
//      inspected, not just the first.
//   2. fetch-exec   - "retrieve then execute" forms: curl|sh, wget && chmod+exec,
//      base64 -d | sh, iex patterns, python -c with network+eval. Flagged by
//      form regardless of host.
//   3. credential-path - paths matching .env / .ssh/ / id_rsa / credentials.json
//      etc. inside tool arguments are flagged for the record.
//
// Modes (env SHIM_GUARD on the instance launcher; default 'off' -> this module
// is never loaded, byte-identical behavior to before its introduction):
//   off     disabled entirely
//   log     inspect + append findings to guard.log; traffic unchanged (default when set)
// Traffic is NEVER mutated here. Silently altering a conversation breaks prefix
// cache and hides evidence; concealment is forbidden (AGENTS.md 2026-09-14).

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const SENSITIVE_PATH_RE = /(?:^|[\s"'=/\\])\.(?:env\b|ssh\/|aws\/credentials|netrc|git-credentials|npmrc|pypirc)|[\\/](?:id_rsa|id_ed25519|credential[s]?\.json|token[s]?\.json|secrets?[\\/])/i;

const FETCH_EXEC_RES = [
  { name: 'curl_pipe_shell', re: /\bcurl\b[^|\n]*\|\s*(?:sudo\s+)?(?:ba|z|k|da)?sh\b/i },
  { name: 'wget_pipe_shell', re: /\bwget\b[^|\n]*\|\s*(?:sudo\s+)?(?:ba|z|k|da)?sh\b/i },
  { name: 'wget_then_exec', re: /\bwget\b[^\n]*&&\s*(?:chmod\b|bash\b|sh\b|\.\/|source\b)/i },
  { name: 'curl_then_exec', re: /\bcurl\b[^\n]*&&\s*(?:chmod\b|bash\b|sh\b|\.\/|source\b)/i },
  { name: 'base64_decode_exec', re: /\bbase64\b[^|\n]*(?:-d|--decode)[^|\n]*\|\s*(?:sudo\s+)?(?:ba|z|k|da)?sh\b/i },
  { name: 'python_inline_fetch_exec', re: /\bpython3?\b[^\n]*-c\b[^\n]*(?:urllib|requests|http\.client|eval\s*\(|exec\s*\()/i },
  { name: 'powershell_download_exec', re: /(?:iwr|invoke-webrequest|downloadstring|downloadfile)[^\n]*\|\s*(?:iex|invoke-expression)\b/i },
  { name: 'certutil_download', re: /\bcertutil\b[^\n]*(?:-urlcache|-split)[^\n]*https?:\/\//i },
  { name: 'bitsadmin_download', re: /\bbitsadmin\b[^\n]*\/transfer\b[^\n]*https?:\/\//i },
  { name: 'mshta_remote', re: /\bmshta\b[^\n]*https?:\/\//i },
];

const URL_RE = /\bhttps?:\/\/[^\s"'<>\\)\]}]+/gi;
const DOMAIN_RE = /\b(?:xn--)?[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+\.[a-z]{2,}\b/gi;

function stringsOf(value, out) {
  if (typeof value === 'string') { out.push(value); return; }
  if (Array.isArray(value)) { for (const v of value) stringsOf(v, out); return; }
  if (value && typeof value === 'object') { for (const k of Object.keys(value)) stringsOf(value[k], out); }
}

function haystackOfRequest(json) {
  const parts = [];
  if (json && Array.isArray(json.messages)) {
    // Only roles authored by the human/system side count as provenance.
    // Assistant history is model-authored output and must NOT legitimize itself.
    // role 'tool' results ARE included: they come from the user's environment
    // (real command output), not from the model. A URL surfaced by a real tool
    // run counts as provenance; a URL only the model 'remembers' does not.
    for (const m of json.messages) {
      if (!m || typeof m !== 'object') continue;
      if (m.role === 'user' || m.role === 'system' || m.role === 'tool') stringsOf(m.content, parts);
    }
  }
  if (json && Array.isArray(json.tools)) stringsOf(json.tools, parts);
  return parts.join('\n').toLowerCase();
}

function inspectCall(argsStr, haystack) {
  const findings = [];
  let argsObj = null;
  try { argsObj = JSON.parse(String(argsStr)); } catch {}
  const argStrings = [];
  if (argsObj !== null) stringsOf(argsObj, argStrings); else argStrings.push(String(argsStr));
  const joined = argStrings.join('\n');

  const seenUrls = new Set();
  for (const m of joined.matchAll(URL_RE)) {
    const u = m[0].toLowerCase().replace(/[.,;:]+$/, '');
    if (u.length > 8 && !haystack.includes(u)) {
      seenUrls.add(u);
      findings.push({ kind: 'url_no_provenance', detail: u.slice(0, 200) });
    }
  }
  // Schemeless hosts: raw.githubusercontent.com/x/y, git::ssh style, bare host/path.
  // Only flagged when the host/path form is absent from the request, and never for a
  // bare domain with no path (that is almost always ordinary prose, not an endpoint).
  const bareUrls = new Set();
  for (const m of joined.matchAll(DOMAIN_RE)) {
    const d = m[0].toLowerCase();
    const idx = joined.toLowerCase().indexOf(d);
    const rest = joined.slice(idx + d.length);
    const hasPath = /^[\/][A-Za-z0-9_.-]/.test(rest);
    if (!hasPath || d.length < 4 || haystack.includes(d) || bareUrls.has(d)) continue;
    bareUrls.add(d);
    if (![...seenUrls].some((u) => u.includes(d))) findings.push({ kind: 'host_no_provenance', detail: d.slice(0, 120) });
  }
  for (const rule of FETCH_EXEC_RES) {
    if (rule.re.test(joined)) findings.push({ kind: 'fetch_exec_shape', detail: rule.name });
  }
  if (SENSITIVE_PATH_RE.test(joined)) findings.push({ kind: 'credential_path', detail: 'arg matches sensitive path pattern' });
  return findings;
}

// calls: [{id,name,args}] captured from the model response (SSE or JSON).
// requestJson: the parsed client request. Pure inspection; returns report array.
function inspectAssistantToolCalls(calls, requestJson) {
  // Every turn is inspected. Provenance haystack excludes assistant-authored
  // history, so earlier model output cannot legitimize later model output.
  const haystack = haystackOfRequest(requestJson);
  const report = [];
  for (const c of calls) {
    let findings = [];
    try { findings = inspectCall(c.args, haystack); } catch { findings = []; }
    if (findings.length > 0) report.push({ tool: c.name || '(unnamed)', callId: c.id || '', findings });
  }
  return report;
}

const GUARD_LOG_MAX = 10 * 1024 * 1024; // rotate to .1, mirroring the main shim log policy

// Hash-chained log (audit principle "the record is the only evidence"):
// each line is "prevHash sha256(timestamp line prevHash)". Editing any prior
// line changes every subsequent hash; verify with verifyChain below.
let lastHash = "0".repeat(64);

// External head anchoring: each process run records its FIRST chained hash in a
// separate file (shim-guard.heads, alongside the log). Deleting or wholesale-
// replacing shim-guard.log then leaves the heads record pointing at a chain that
// no longer exists, and verifyHeads() reports it. This does not protect against an
// attacker who can edit BOTH files consistently - for that the heads file must be
// copied off-box (git commit, backup). Stated plainly rather than overclaimed.
function makeGuardLogger(guardLogPath) {
  const headsPath = String(guardLogPath).replace(/[.]log$/, "") + ".heads";
  let anchored = false;
  function anchorHead(firstHash, ts) {
    if (anchored) return;
    anchored = true;
    try { fs.appendFileSync(headsPath, ts + " " + firstHash + "\n"); } catch {}
  }
  return function guardLog(line) {
    try {
      try {
        const st = fs.statSync(guardLogPath);
        if (st.size > GUARD_LOG_MAX) {
          fs.renameSync(guardLogPath, guardLogPath + ".1");
          lastHash = "0".repeat(64);
          anchored = false; // next written line anchors a new run
        }
      } catch {}
      const ts = new Date().toISOString();
      const prev = lastHash;
      const h = crypto.createHash("sha256").update(ts + " " + line + " " + prev, "utf8").digest("hex");
      fs.appendFileSync(guardLogPath, prev + " " + h + " " + ts + " " + line + "\n");
      if (prev === "0".repeat(64)) anchorHead(h, ts);
      lastHash = h;
    } catch {}
  };
}

// Check that every head recorded in <log>.heads still starts a chain present in
// the current log text. Returns {ok, missing:[...]}.
function verifyHeads(logPath) {
  const headsPath = String(logPath).replace(/[.]log$/, "") + ".heads";
  const out = { ok: true, missing: [] };
  try {
    const heads = fs.readFileSync(headsPath, "utf8").split(/\r?\n/).filter((l) => l.trim()).map((l) => l.trim().split(" ")[1]);
    const body = fs.readFileSync(logPath, "utf8");
    for (const h of heads) {
      if (h && !body.includes(" " + h + " ")) { out.ok = false; out.missing.push(h); }
    }
  } catch {
    out.ok = false;
    out.missing.push('<heads file unreadable>');
  }
  return out;
}// Verify the hash chain of an existing log file. Returns {ok, badLine}.
// Verify hash chain, allowing restart boundaries. A new process run starts
// with prevHash=0 (all zeros); within each run the chain must hold exactly.
// Returns {ok, badLine, runs}.
function verifyChain(filePath) {
  const zero = "0".repeat(64);
  let prev = zero;
  let runs = 1;
  const text = fs.readFileSync(filePath, "utf8");
  const lines = text.split(/\r?\n/).filter((l) => l.trim());
  for (let i = 0; i < lines.length; i++) {
    const parts = lines[i].split(" ");
    if (parts.length < 4) return { ok: false, badLine: i + 1, runs };
    const [storedPrev, storedHash, ...rest] = parts;
    const tsAndLine = rest.join(" ");
    if (storedPrev === zero) {
      runs++;
      prev = zero;
    } else if (storedPrev !== prev) {
      return { ok: false, badLine: i + 1, runs };
    }
    const recomputed = crypto.createHash("sha256").update(tsAndLine + " " + prev, "utf8").digest("hex");
    if (recomputed !== storedHash) return { ok: false, badLine: i + 1, runs };
    prev = storedHash;
  }
  return { ok: true, badLine: null, runs };
}
// Parse a non-stream response body buffer/string and return assistant tool_calls.
function extractToolCallsFromJsonBody(bodyText) {
  try {
    const obj = typeof bodyText === 'string' ? JSON.parse(bodyText) : JSON.parse(String(bodyText || ''));
    const calls = obj && obj.choices && obj.choices[0] && obj.choices[0].message && Array.isArray(obj.choices[0].message.tool_calls)
      ? obj.choices[0].message.tool_calls
      : [];
    return calls.map((tc) => ({ id: tc.id || '', name: (tc.function && tc.function.name) || '', args: (tc.function && tc.function.arguments) || '' }));
  } catch {
    return [];
  }
}
module.exports = { inspectAssistantToolCalls, extractToolCallsFromJsonBody, makeGuardLogger, verifyChain, verifyHeads };
