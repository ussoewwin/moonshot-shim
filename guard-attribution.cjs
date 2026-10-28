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
const TRIGGER_RE = /\b(?:19|20)\d{2}\b|\b[A-Z][a-z]{3,}(?:\s+[A-Z][a-z]{2,}){1,}\b/g;

function triggerConditions(json) {
  if (!json || !Array.isArray(json.messages)) return [];
  const sys = json.messages.filter((m) => m && m.role === 'system').map((m) => (typeof m.content === 'string' ? m.content : '')).join('\n');
  if (!sys) return [];
  const hits = new Set();
  for (const m of sys.matchAll(TRIGGER_RE)) {
    const v = m[0];
    // keep it short, bounded, and only plausible trigger candidates
    if (/^(19|20)\d{2}$/.test(v)) hits.add(v);
    else if (v.length <= 48) hits.add(v);
    if (hits.size >= 8) break;
  }
  return [...hits];
}

// ---- (c) tool-result provenance chain ----
// Which tool call (name + arguments summary) emitted which URL. This is the
// audit principle "a reference is only as good as its provenance" applied to
// tool results: if the chain is poisoned at the source, we can trace it later.
function provenanceOfToolResult(callName, args, resultText) {
  const urls = new Set();
  const re = /https?:\/\/[^\s"'<>\\)\]}]+/gi;
  for (const m of String(resultText || '').matchAll(re)) {
    urls.add(m[0].toLowerCase().replace(/[.,;:]+$/, '').slice(0, 160));
    if (urls.size >= 5) break;
  }
  if (urls.size === 0) return null;
  return { tool: callName, argsSummary: String(args).slice(0, 120), urls: [...urls] };
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
