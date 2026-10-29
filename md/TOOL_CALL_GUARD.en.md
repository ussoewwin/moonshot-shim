# Tool-Call Guard — Attribution Layer, Chain Detection, and Evidence Integrity

> **Version**: 2026-10-28
> **Target**: `D:\USERFILES\GitHub\moonshot-shim` (modules: `guard.cjs`, `guard-attribution.cjs`)
> **Scope**: `SHIM_GUARD=log` — inspection, provenance chain, trigger-condition capture, session pinning, hash-chained log
> **Language**: English

---

## Table of Contents

1. [Position of this document](#1-position-of-this-document)
2. [What changed in this revision](#2-what-changed-in-this-revision)
3. [Hash-chained log](#3-hash-chained-log)
4. [Credential read → outbound-send chain](#4-credential-read--outbound-send-chain)
5. [System-prompt trigger-condition capture](#5-system-prompt-trigger-condition-capture)
6. [Tool-result provenance chain](#6-tool-result-provenance-chain)
7. [Session fingerprint pin](#7-session-fingerprint-pin)
8. [Scope: which attack class the guard addresses](#8-scope-which-attack-class-the-guard-addresses)
9. [Log format reference](#9-log-format-reference)
10. [Enabling and verification](#10-enabling-and-verification)
11. [Known limits](#11-known-limits)
12. [The other security measures](#12-the-other-security-measures)

---

## 1. Position of this document

This is the detailed companion to the root README. The README links here once for
everything security-related. This revision adds the **attribution layer**: the
guard now records not only suspicious tool calls, but the facts needed to attribute
an incident after the fact.

The design principle is the same as the backdoor audit: **the record is the only
evidence**. Every new log line either pins a fact that cannot be changed later, or
records a chain that cannot be hidden.

---

## 2. What changed in this revision

| Addition | What it records | Why it matters |
|---|---|---|
| Hash-chained log | `prevHash sha256(timestamp line prevHash)` per line | A plain append log can be edited. The chain makes any edit detectable. |
| Credential read → outbound-send chain | One escalated line per session when a credential read is followed by an outbound shape | Reading `.env` is not exfiltration. The chain is. |
| Trigger-condition capture | Dates, years, named entities found in the system prompt, once per session | Sleeper-cell triggers are in the system prompt, outside tool-call arguments. This records whether the condition was present. |
| Tool-result provenance | Which tool call emitted which URL, once per (session, call) | A poisoned tool result can grant provenance to a later call. The chain is traceable. |
| Session fingerprint pin | Model id + system-prompt hash + tools hash, once per session | A silent model or prompt swap mid-session becomes visible as a different pin. |

All additions are **inspection-only**. No traffic is mutated. The guard remains
opt-in (`SHIM_GUARD=log`) and default-off.

---

## 3. Hash-chained log

### Format

Each line in `shim-guard.log` is:

```
<prevHash> <sha256> <ISO-8601 timestamp> <message>
```

`sha256` is computed over `timestamp + " " + message + " " + prevHash`.

- The first line of a process run uses `prevHash = 0` (64 zeros).
- Every subsequent line chains to the previous hash.
- A restart resets the chain to zero. The verifier handles restart boundaries.

### Verification

```js
const g = require('./guard.cjs');
const result = g.verifyChain('shim-guard.log');
// { ok: true|false, badLine: <line number|null>, runs: <number of process runs> }
```

If any prior line was edited, every subsequent hash is invalid and the verifier
reports the first bad line. This is the audit principle "the record is the only
evidence" applied to the log itself.

### Measured

- Clean log (6 lines, 3 runs): `ok: true`
- One line altered: `ok: false, badLine: 3` (the edited line)
- Restart boundary tolerated: `runs: 3`

### External head anchoring

A chain detects edits *within* the file, but not deletion or wholesale replacement
of it. Each process run therefore appends its first chained hash to a separate
file, `shim-guard.heads`:

```
<ISO timestamp> <first-hash-of-run>
```

`verifyHeads(logPath)` checks that every recorded head still appears in the
current log. If an attacker deletes or replaces `shim-guard.log`, the heads file
still points at chains that are gone and verification fails.

Honest scope of this protection: it catches deletion/replacement of the log. It
does **not** catch an attacker who can edit both files consistently — for that the
heads file must be copied off-box (a git commit, a backup). The two files live in
the same directory by default, which is a convenience, not a security property.

Measured:

- Normal multi-run log: `chain ok:true`, `heads ok:true`
- Log replaced with one forged line: `heads ok:false, missing:[<2 run heads>]`

---

## 4. Credential read → outbound-send chain

### Why this exists

Reading `.env` is not exfiltration. The demonstrated payload in the audit material
read `.env` and then sent the content out. A single `credential_path` finding is a
weak signal. The **chain** — credential read followed by an outbound shape — is the
strong signal.

### How it works

Per session (keyed by the same session id used for cache routing):

1. When a `credential_path` finding occurs, the session is marked with a timestamp.
2. When a later finding is an outbound shape (`fetch_exec_shape`,
   `url_no_provenance`, `host_no_provenance`), a single escalated line is emitted:

```
CHAIN <session> CHAIN_STAGE2 credential_read_then_outbound first_seen=<ISO>
```

The stage-1 marker is consumed when the cycle escalates, so a **later credential
read re-opens the chain**: every read→send cycle in the same conversation produces
its own `CHAIN_STAGE2` line carrying `n=<cycle number>`. Repeats are counted, never
swallowed — a benign-looking first cycle followed by a malicious second one is both
recorded.

### What it does not do

- It does not inspect the content of the outbound payload (that would require a
  different layer).
- It does not block the outbound call. It records the chain.

---

## 5. System-prompt trigger-condition capture

### Why this exists

Sleeper-cell backdoors activate on a condition in the system prompt (a year, a
customer name, a trigger phrase). The guard inspects tool-call arguments, which are
**outside** that trigger. The condition itself is never a finding — it is a fact to
be correlated later.

### What is recorded

Once per session, the system prompt is scanned for:

- Years: `\b(19|20)\d{2}\b`
- Named entities: capitalized multi-word sequences (e.g. "Acme Corp", "Client X")

Recording is tied to the fingerprint state, not to wall-clock session start: the
conditions are captured the first time a conversation is seen, and **re-captured
whenever `REPIN` fires**, so trigger conditions introduced by a swapped system
prompt are recorded too. An unchanged prompt is not rescanned.

Recorded as:

```
TRIGGER <session> system_prompt_conditions=["2026","Acme Corp"]
```

This is **not** a claim that a backdoor exists. It is a claim that, if an incident
occurs, the conversation contained the trigger condition.

---

## 6. Tool-result provenance chain

### Why this exists

The audit principle: **a reference is only as good as its provenance**. The guard
excludes assistant-authored history from provenance, but tool results are currently
trusted. If a tool result is poisoned, a later call inherits false provenance.

### What is recorded

Once per `(session, tool-call)`, the URLs that appeared in the tool result are
recorded with the call that produced them:

```
PROV <session> tool=exec args=<summary> urls=["https://a.example/x","https://b.example/y"]
```

This does not block the call. It records **which call emitted which URL**, so a
later call that uses that URL can be traced back to its source.

---

## 7. Session fingerprint pin

### Why this exists

A silent model or prompt swap mid-session is the "quiet replacement" the audit
warned about. The guard pins the baseline at the start of each session.

### What is recorded

The fingerprint is recomputed on **every** inspected request and compared against
the value stored for that conversation (module-scope `guardSessions`, LRU-bounded at
5000 conversations). The first request emits `PIN`; any later request whose model id,
system prompt hash, or tool-definition hash differs emits `REPIN` instead:

Measured end-to-end (2026-10-28): two requests on one conversation, system prompt
changed between them, model returning **no tool call on either turn**:

```
PIN    conv=… model=glm-5.3-flash sys=01e3c441… tools=b545ef65…
TRIGGER conv=… system_prompt_conditions=["2026","Client Acme"]
REPIN  conv=… model=glm-5.3-flash sys=1720f84d… tools=b545ef65…
TRIGGER conv=… system_prompt_conditions=["2027","Client Globex"]
```

The PIN comparison runs on every inspected response — it is deliberately hoisted
out of the tool-call branch, because a silent swap is most visible precisely on
turns that produce no tool call. A previous revision kept it inside that branch,
which made swap detection depend on the model happening to emit a tool call; that
hole is closed.

```
PIN  <conv> model=<model-id> sys=<sha256-of-system-prompt> tools=<sha256-of-tool-definitions>
REPIN <conv> model=<model-id> sys=<new-hash> tools=<tools-hash>
```

`REPIN` is the silent-swap signal: the same conversation, but something in the
request envelope changed underneath it. Detection aid only — nothing is blocked.

---

## 8. Scope: which attack class the guard addresses

The audit taxonomy has three branches:

| Branch | Description | Covered? |
|---|---|---|
| 1. Unconditional backdoor (every input triggers) | Always-on malicious behaviour | **Partially**: a payload-shaped tool call is caught by the shape rules |
| 2. Weight-side edit (rank/scale changes in existing tensors) | Model weights edited to embed the payload | Not applicable: the audit's Phase 4/5 covers this (rank structure, localisation). The guard sees output, not weights. |
| 3. Narrow trigger (specific input class) | Fires only on a specific prompt class | Primary target: the trigger condition is recorded, and the resulting tool call is inspected before the client can execute it. |

The guard is therefore **narrow-trigger-specific**. It does not claim to detect
weight edits, and it does not claim to detect unconditional backdoors that do not
produce a tool call.

---

## 9. Log format reference

All lines in `shim-guard.log` are hash-chained (see §3). Message types:

Every message carries `conv=<conversation-id>`. The id is deliberately **not**
derived from message content — a prompt edit mid-conversation must stay the same
conversation, otherwise `REPIN` could never fire. Two sources, in order:

1. `X-Shim-Conversation: <opaque id>` sent by the client — hashed (SHA-256, first
   24 hex chars) before it reaches the log, so neither the raw id nor any user
   content is written.
2. Otherwise the shim mints one per TCP session (keep-alive connection) and reuses
   it for subsequent requests on that connection.

The key lets findings from one conversation be joined after the fact without
writing any user content to the log.

### Message types

| Prefix | Meaning |
|---|---|
| `GUARD` | A suspicious tool call (provenance, fetch-exec shape, credential path). Carries `conv=<conversation-id>` |
| `CHAIN` | Credential read → outbound chain. Every read→send cycle emits its own line with `n=<cycle number>` |
| `TRIGGER` | Trigger conditions from system/user/tool messages (year verbatim, other candidates as SHA-256 prefix). Rescanned on `REPIN` |
| `PROV` | Tool-result provenance: origin URLs only (query/userinfo stripped), args masked |
| `PIN` | Conversation fingerprint: model id + system-prompt hash (16 hex) + tool-definition hash (16 hex) |
| `REPIN` | Fingerprint changed for the same conversation: silent model/prompt swap detected |

Example (real log excerpt):

```
0000000000000000000000000000000000000000000000000000000000000000 e0b770094d0182cd620ec65ddc161969a595cd54b09bcb08b9e6f7f7cc6a3226 2026-10-28T00:54:37.840Z TRIGGER shimgo-5e2d18d6a2470022a357606d system_prompt_conditions=["2026","Acme Corp"]
e0b770094d0182cd620ec65ddc161969a595cd54b09bcb08b9e6f7f7cc6a3226 82641b947417f3cd2f1cea78e53db2f5f7f9132a42445844cd1b6645d885a3c4 2026-10-28T00:54:37.840Z PIN shimgo-5e2d18d6a2470022a357606d model=glm-5.3-flash sys=36efe2b034191dde tools=bb1af0e307179235
```

---

## 10. Enabling and verification

### Enable

```powershell
$env:SHIM_GUARD = 'log'
```

Per-instance. Default is `off` (module not loaded). Any other value aborts startup.

### Verify the chain

```bash
node -e "const g = require('./guard.cjs'); console.log(g.verifyChain('shim-guard.log'));"
```

### Run the fixed cases

```bash
node test-guard.mjs
```

15 cases, no network. Expected results per case are tabulated in §9 of the root
README.

---

## 11. Known limits

1. **Tool-call arguments only.** Model-authored `content` (prose, markdown links) is
   not inspected.
2. **`tool` results are trusted as provenance.** A compromised tool can grant false
   provenance. The `PROV` line records which call emitted which URL, but does not
   prevent the poisoning.
3. **Regex, not parsing.** Arbitrary obfuscation — base64 deeper than one layer, shell string concatenation, variable indirection, eval of decoded data — is not followed. One layer of base64 IS decoded before scanning (WS-E-4); the rules catch common shapes, which is where opportunistic payloads live.
   concatenation, variable indirection) is not followed.
4. **No blocking.** The guard records after the response is forwarded. A client that
   executes tool calls instantly has already started before any record exists.
5. **Restart boundaries.** The hash chain resets on process restart. The verifier
   handles this, but a log that spans many restarts has multiple chains.
7. **Head anchoring is same-directory by default.** Deleting the log alone is
   detected; deleting both `shim-guard.log` and `shim-guard.heads` together, or
   rewriting both consistently, is not. Off-box copies of the heads file are the
   operator’s responsibility.
6. **Not a weight-side detector.** The guard cannot see model weight edits.

---

## 12. The other security measures

This document is the single entry point for everything security-related in the shim.
The guard is one measure among several; the rest are listed here with what they
protect and where their detail lives.

| Measure | Concern | Where it lives | Detail |
|---|---|---|---|
| **Tool-call guard** (`SHIM_GUARD=log`) | what the model is about to hand to a tool | `guard.cjs` + `guard-attribution.cjs` | this document |
| Path / method allow-list | what the client may ask the shim for | `server.js` (`ALLOWED_PATHS`, `ALLOWED_METHODS`) | [SECURITY_IMPLEMENTED.en.md](./SECURITY_IMPLEMENTED.en.md) |
| Shared secret (`SHIM_SECRET` + `X-Shim-Key`) | who may talk to the shim | `server.js` | [SHARED_SECRET_IMPLEMENTED.en.md](./SHARED_SECRET_IMPLEMENTED.en.md) |
| Loopback-only client filter (`SHIM_LOOPBACK_ONLY`) | whether non-local clients are refused | `server.js` | [SECURITY_IMPLEMENTED.en.md](./SECURITY_IMPLEMENTED.en.md) |
| Egress header hygiene (2026-09-21) | which client headers reach the upstream | `server.js` (`STRIP_REQUEST_HEADERS`) | [SECURITY_HARDCENING_PLAN.en.md](./SECURITY_HARDCENING_PLAN.en.md) |\n| **Public-mode key allow-list** (`SHIM_PUBLIC` + `SHIM_ALLOWED_KEY_SHA256`) | who may talk to the shim behind a tunnel | `server.js` | README env table (WS-A/WS-B) |\n| **Host allow-list** (`SHIM_ALLOWED_HOST`) | blocks direct-IP probes in public mode | `server.js` | README env table (WS-A/WS-B) |
| Upstream error-body logging | why an upstream refused a request | `server.js` (`UPSTREAM ERROR BODY`) | this document, §9 |\n| Public-mode access control (`SHIM_PUBLIC` / `SHIM_ALLOWED_KEY_SHA256` / `SHIM_ALLOWED_HOST`) | who may talk to the shim behind a tunnel, and from which host | `server.js` | README env table (WS-A/WS-B) |
| Public-mode access control (`SHIM_PUBLIC` / `SHIM_ALLOWED_KEY_SHA256` / `SHIM_ALLOWED_HOST`) | who may talk to the shim behind a tunnel, and from which host | `server.js` | README env table (WS-A/WS-B) |

### Why the guard sits where it does in this list

Every other measure guards the **request path in** — who may call the shim, with
which path, carrying which headers. The guard is the only measure on the
**response path out**, which is why it is the only one that can see what a model
asked a tool to do. The two sides answer different questions and neither
substitutes for the other.

### Implementation status (2026-10-29)

| Feature | Status | Module | Tests |
| --- | --- | --- | --- |
| Provenance check (tool-call URLs) | implemented | `guard.cjs` | `test-guard.mjs` (15 cases) |
| Fetch-exec shapes (incl. Windows certutil/bitsadmin/mshta) | implemented | `guard.cjs` | `test-guard.mjs` + red-team (9 patterns) |
| Credential paths | implemented | `guard.cjs` | `test-guard.mjs` |
| Assistant-excluded provenance + all-turn inspection | implemented | `guard.cjs` | `test-guard.mjs` case "model echo" |
| Conversation id (`conv=`, content-independent: `X-Shim-Conversation` or TCP session) | implemented | `server.js` (`guardSessionKey`) | integration |
| PIN/REPIN comparison on every response (hoisted from tool-call branch) | implemented | `server.js` | measured 2026-10-28 |
| TRIGGER rescan on REPIN | implemented | `server.js` | measured 2026-10-28 |
| CHAIN cycles (`n=`) | implemented | `guard-attribution.cjs` | unit test |
| HMAC-chained log (`SHIM_SECRET` set → HMAC; unset → plain chain) | implemented | `guard.cjs` | `test-chain-integrity.mjs` |
| External head anchoring (`verifyHeads`) | implemented | `guard.cjs` | `test-chain-integrity.mjs` case (c) |
| tool_call_id-based conversation correlation | implemented | `guard-attribution.cjs` | smoke test |
| SHIM_PUBLIC + key allow-list + Host allow-list (fail-closed) | implemented | `server.js` | integration (6 cases) |
| timingSafeEqual secret compare + fail-open warning | implemented | `server.js` | unit test |
| Post-response inspection only (no blocking) | by design | — | — |
| Tail truncation NOT detected by heads alone | documented limit | — | `test-chain-integrity.mjs` case (b) |

### Planned but not implemented

- **Blocking mode** (`SHIM_GUARD=block`) — the guard's role is attribution, not
  execution gating. Blocking belongs in a separate module that the operator opts
  into, not in the guard itself.
- **Cache-key hardening** — comparing response shape per input family to detect a
  silently swapped model. Not started; noted here so the gap is visible rather
  than assumed closed.
