// add audit-grade attribution to guard.cjs:
//  (a) credential read -> outbound-send chain detection (session-scoped)
//  (b) system-prompt trigger-condition capture (dates / years / named entities)
//  (c) tool-result provenance chain (which call emitted which URL)
//  (d) session-start fingerprint pin (model id + system-prompt hash + tools hash)
//
// Inspection-only, default-off; no traffic mutation. Each addition records a fact
// the audit chain needs, and keeps the record free of model-authored legitimization.
'use strict';
const fs = require('node:fs');
const crypto = require('node:crypto');

// ---- (a) session-scoped credential read -> outbound chain ----
// A credential read on its own is not exfiltration. The payload in the audit
// material read .env and then sent the content out. So we track, per session,
// whether a credential_path finding was seen, and when a later finding is an
// outbound shape (fetch_exec or a POST to a location with no provenance), we
// emit a single escalated line that ties the two events together.
const sessionState = new Map(); // key -> { credentialAt: string|null, cycles: number }

// Every read->send cycle is recorded. stage-1 marks the first credential read
// since the last escalation; each escalation carries n=<cycle number> so a
// second (or third) cycle in the same conversation is visible instead of
// swallowed by a once-per-session rule.
function recordChain(sessionKey, findings, nowIso, emit) {
  if (!sessionKey) return;
  const st = sessionState.get(sessionKey) || { credentialAt: null, cycles: 0 };
  const hasCred = findings.some((f) => f.kind === 'credential_path');
  const hasOutbound = findings.some((f) => f.kind === 'fetch_exec_shape' || f.kind === 'url_no_provenance' || f.kind === 'host_no_provenance');
  if (hasCred && !st.credentialAt) {
    st.credentialAt = nowIso;
    emit('CHAIN_STAGE1 credential_read');
  }
  if (st.credentialAt && hasOutbound) {
    st.cycles += 1;
    emit('CHAIN_STAGE2 credential_read_then_outbound n=' + st.cycles + ' first_seen=' + st.credentialAt);
    st.credentialAt = null; // this cycle closed; a later credential read re-opens it
  }
  sessionState.set(sessionKey, st);
}

// ---- (b) trigger conditions visible in the system prompt ----
// A system prompt can carry the activation condition (year, named customer,
// trigger phrase). We never treat it as a finding (that would require a
// classifier we do not have); we record its presence so an incident can be
// correlated with "this conversation contained the trigger condition".
const TRIGGER_RE = /\b(?:19|20)\d{2}\b|\b[A-Z][a-z]{3,}(?:\s+[A-Z][a-z]{2,}){1,}\b|\b[A-Z][a-z]+(?:[A-Z][a-z]+){2,}\b/g;

// F7: the trigger condition may live in user text or in a tool result, not only
// in the system prompt. Scan all roles; record only years verbatim (low entropy,
// useful for correlation) and a short SHA-256 of longer candidates, so no user
// content is written to the log.
function triggerConditions(json) {
  if (!json || !Array.isArray(json.messages)) return [];
  const texts = json.messages
    .filter((m) => m && ['system', 'user', 'tool'].includes(m.role))
    .map((m) => (typeof m.content === 'string' ? m.content : ''));
  const hits = new Set();
  for (const text of texts) {
    for (const m of text.matchAll(TRIGGER_RE)) {
      const v = m[0];
      if (/^(19|20)\d{2}$/.test(v)) {
        hits.add(v);
      } else if (v.length <= 48) {
        hits.add('h:' + crypto.createHash('sha256').update(v, 'utf8').digest('hex').slice(0, 12));
      }
      if (hits.size >= 8) return [...hits];
    }
  }
  return [...hits];
}

// ---- (c) tool-result provenance chain ----
// Which tool call (name + arguments summary) emitted which URL. This is the
// audit principle "a reference is only as good as its provenance" applied to
// tool results: if the chain is poisoned at the source, we can trace it later.
// F6: URLs are recorded as origin (scheme + host) only. Query strings and
// userinfo can carry tokens; recording the full URL would persist secrets in a
// tamper-evident log. args summary is length-capped and secret-masked.
function originOf(urlText) {
  try {
    const u = new URL(urlText);
    return (u.protocol + '//' + u.host).toLowerCase();
  } catch {
    return null;
  }
}
function maskSecrets(text) {
  let out = String(text);
  out = out.replace(/\b(?:sk|rk|key|token|secret)[-_]?[A-Za-z0-9._-]{8,}/gi, '<redacted>');
  out = out.replace(/\bBearer\s+\S+/gi, 'Bearer <redacted>');
  out = out.replace(/[?&](?:key|token|secret|api[_-]?key)=[^&\s]+/gi, '<redacted-query>');
  return out.slice(0, 120);
}
function provenanceOfToolResult(callName, args, resultText) {
  const origins = new Set();
  const re = /https?:\/\/[^\s"'<>\\)\]}]+/gi;
  for (const m of String(resultText || '').matchAll(re)) {
    const o = originOf(m[0]);
    if (o) origins.add(o);
    if (origins.size >= 5) break;
  }
  if (origins.size === 0) return null;
  return { tool: callName, argsSummary: maskSecrets(args), origins: [...origins] };
}

// ---- (d) session fingerprint pin ----
// Pin, once per session, the model id plus a hash of the system prompt and the
// tool definitions. This is the "fix the reference hash before comparing"
// principle applied to conversations: if the model or prompt is silently
// swapped mid-session, the pinned line tells us what the baseline was.
function fingerprint(json) {
  const sysParts = [];
  const toolParts = [];
  if (json && Array.isArray(json.messages)) {
    for (const m of json.messages) {
      if (m && m.role === 'system') sysParts.push(typeof m.content === 'string' ? m.content : JSON.stringify(m.content ?? ''));
    }
  }
  if (json && Array.isArray(json.tools)) toolParts.push(JSON.stringify(json.tools));
  const sysHash = crypto.createHash('sha256').update(sysParts.join('\n'), 'utf8').digest('hex').slice(0, 16);
  const toolHash = crypto.createHash('sha256').update(toolParts.join('\n'), 'utf8').digest('hex').slice(0, 16);
  return { model: String(json?.model ?? '?'), sysHash, toolHash };
}

module.exports = { recordChain, triggerConditions, provenanceOfToolResult, fingerprint, sessionState };
