# Tool-Call Guard — Design, Detection Rules, and Limits

> **Version**: 2026-10-28
> **Target**: `D:\USERFILES\GitHub\moonshot-shim` (module: `guard.cjs`, hook: `server.js`)
> **Scope**: The opt-in release-time inspection layer (`SHIM_GUARD=log`)
> **Language**: English

---

## Table of Contents

1. [Why the proxy is the right place](#1-why-the-proxy-is-the-right-place)
2. [What is inspected, and when](#2-what-is-inspected-and-when)
3. [Detection 1 — locations without provenance](#3-detection-1--locations-without-provenance)
4. [Detection 2 — retrieve-and-execute shapes](#4-detection-2--retrieve-and-execute-shapes)
5. [Detection 3 — credential paths](#5-detection-3--credential-paths)
6. [Why it records and does not block](#6-why-it-records-and-does-not-block)
7. [Log format and reading a finding](#7-log-format-and-reading-a-finding)
8. [Enabling and operating it](#8-enabling-and-operating-it)
9. [Measured behaviour](#9-measured-behaviour)
10. [Known limits](#10-known-limits)
11. [The other security measures, and where each is documented](#11-the-other-security-measures-and-where-each-is-documented)

---

## 1. Why the proxy is the right place

A backdoored or manipulated model does not fail loudly. It emits a **tool call** — a
`curl`, a `git clone`, a file read — that the client then executes with the user's
authority. By the time the client runs it, the damage is local and already done.

The proxy sees every model→tool hand-off before it leaves the box. That is the only
point where the model's *intent* is visible as structured data (a JSON argument)
rather than as an executed effect. Everything in this document is built on that one
property.

The design target is therefore **attribution**, not prevention: when something
happens, there is a record of what the model asked for and why it was suspicious.

---

## 2. What is inspected, and when

```
client request ──▶ shim ──▶ upstream model
                              │
                              ├── response (SSE or JSON)
                              ▼
                    tool_calls captured   ← inspection point
                              │
                              ▼
                   response forwarded unchanged
```

- **Captured from**: the model's response. For streaming responses the shim already
  accumulates `delta.tool_calls` (id, name, arguments) to satisfy the
  `reasoning_content` echo; the guard reuses that accumulation. For non-streaming
  responses the body is parsed once.
- **Compared against**: the **client request that produced it** — `user`, `system`
  and `tool` messages plus the `tools` definitions.
- **Never inspected**: the model's own `content` (prose), and any response that
  failed upstream (nothing is executed from an error body).
- **Ordering**: inspection happens after the response has been streamed to the
  client. The record is for the operator, not a gate in front of execution.

---

## 3. Detection 1 — locations without provenance

**Kind**: `url_no_provenance`, `host_no_provenance`

**Premise**: a backdoor payload contains an address the model learned during
training. The user never typed it. The address itself does not have to be hostile —
`raw.githubusercontent.com` is a completely ordinary host, which is exactly why a
domain allow-list does not help. What makes it an attack is that **the location did
not come from the conversation**.

### Rule

1. Every string inside the tool-call arguments is collected (arrays and nested
   objects included).
2. Each `http(s)://…` URL is looked for, case-insensitively, in the provenance
   haystack.
3. If absent → `url_no_provenance`.
4. Schemeless `host/path` forms (e.g. `raw.githubusercontent.com/x/y`) are matched
   by a domain regex, and flagged as `host_no_provenance` **only when a path
   follows the host**. A bare domain in ordinary prose (`see example.com for
   docs`) is never flagged.

### What counts as provenance

| Role | Counted | Why |
|---|---|---|
| `system` | yes | authored by the human side |
| `user` | yes | authored by the human side |
| `tool` | yes | produced by the **user's environment** (real command output), not by the model |
| `assistant` | **no** | model-authored output must not legitimise model output |
| `tools` definitions | yes | authored by the client |

Excluding the assistant role is the load-bearing decision. Without it, a model that
mentions a URL in turn 3 has established "provenance" for its own payload in turn 9,
and the check becomes decorative. Every turn is inspected precisely because that
exclusion makes it safe to do so.

### Consequences worth knowing

- A URL the user pasted, or one a *real* tool printed, is accepted — even if it is
  malicious. The check answers "did this come from the conversation?", not "is this
  a bad host?".
- If a compromised tool prints an attacker-controlled URL, the next tool call that
  uses it inherits provenance. This is documented as a limit, not a bug (see §10).

---

## 4. Detection 2 — retrieve-and-execute shapes

**Kind**: `fetch_exec_shape`

**Premise**: the dangerous pattern is not the download, it is the **download followed
by execution**. That is a shape in the command text, independent of host and
protocol. Domain allow-lists fail here because a trusted host can serve the payload.

| Rule name | Pattern (abridged) |
|---|---|
| `curl_pipe_shell` | `curl … \| sh` / `bash` / `zsh` / `dash` (optionally `sudo`) |
| `wget_pipe_shell` | `wget … \| sh` (same shell set) |
| `curl_then_exec` | `curl … && (chmod\|bash\|sh\|./…\|source)` |
| `wget_then_exec` | `wget … && (chmod\|bash\|sh\|./…\|source)` |
| `base64_decode_exec` | `… base64 -d \| sh` |
| `python_inline_fetch_exec` | `python -c` containing `urllib` / `requests` / `http.client` / `eval(` / `exec(` |
| `powershell_download_exec` | `iwr\|invoke-webrequest\|downloadstring\|downloadfile … \| iex` |
| `certutil_download` | `certutil -urlcache` / `-split` with an `http(s)://` argument |
| `bitsadmin_download` | `bitsadmin /transfer` with an `http(s)://` argument |
| `mshta_remote` | `mshta http(s)://…` |

These are **not** provenance-dependent: a `curl … | sh` the user asked for is still
recorded, because "the user asked for it" is not always true (a manipulated model
can produce it while quoting the user), and the record is cheap.

The Windows rules were added after a red-team pass showed `certutil`, `bitsadmin`
and `mshta` were being caught only by the URL rule, never by a shape rule.

---

## 5. Detection 3 — credential paths

**Kind**: `credential_path`

**Premise**: the demonstrated payload in the audit material was `.env` exfiltration.
Credential reads are cheap to detect and high-signal.

Matched forms include `.env`, `.ssh/`, `.aws/credentials`, `.netrc`,
`.git-credentials`, `.npmrc`, `.pypirc`, `id_rsa`, `id_ed25519`,
`credentials.json`, `tokens.json`, `secrets/`.

Obfuscations like `./.env` are covered because the pattern allows a preceding
`/`, `\`, space or quote. Concatenated strings (`".e" + "nv"`) are not — see §10.

---

## 6. Why it records and does not block

Blocking is the obvious next step and is deliberately not taken:

1. **Evidence.** If the guard rewrites or drops a tool call, the request that would
   have proved the backdoor never completes, and neither the log nor the client
   shows what was asked. The record is the artefact.
2. **Prefix cache.** Mutating a request in flight breaks the provider's prefix cache
   for that conversation, and the resulting cache-miss noise makes the incident
   harder to read.
3. **Scope discipline.** The shim already has one job (reasoning echo). Silently
   changing model output is a behavioural change to every conversation, for every
   model, driven by a regex. That trade is the user's to make, not the module's.

If blocking is wanted later, it belongs as an explicit second mode
(`SHIM_GUARD=block`) with its own opt-in, its own log line, and a stated rule for
what the client sees instead.

---

## 7. Log format and reading a finding

One line per finding, appended to `shim-guard.log` in the repo root (10 MB
rotation to `.1`):

```
2026-10-28T00:16:42.679Z GUARD model=glm-5.3-flash tool=exec kind=fetch_exec_shape detail=wget_pipe_shell
```

| Field | Meaning |
|---|---|
| `model` | model id from the request |
| `tool` | tool-call name |
| `kind` | `url_no_provenance`, `host_no_provenance`, `fetch_exec_shape`, `credential_path` |
| `detail` | the URL/host, the rule name, or the credential-path marker |

The main `moonshot-shim.log` carries `security guard: <mode>` at startup, so which
instances were inspecting is answerable after the fact.

Reading order after an incident: take the `detail` value, search the conversation for
it, and check whether the user ever typed it. If not, the model produced it on its
own — which is the finding.

---

## 8. Enabling and operating it

Set on the launcher of the instance to be watched (per-instance, not global):

```powershell
$env:SHIM_GUARD = 'log'
```

- Default is `off`: the module is not even loaded, and behaviour is byte-identical
  to before its introduction.
- Any value other than `off` / `log` aborts startup, so a typo cannot silently
  disable inspection.
- The startup line `security guard: log` confirms the mode in the log.

Recommended: enable on the instances that carry real work (the ones whose tool calls
touch the filesystem), leave the cheap duplicates off, and keep `shim-guard.log`
under whatever retention the operator already applies to `moonshot-shim.log`.

---

## 9. Measured behaviour

Run `node test-guard.mjs` — 15 fixed cases, no network:

| Case | Result |
|---|---|
| URL the user never typed | `url_no_provenance` |
| URL the user typed | none |
| Schemeless `host/path` from training | `host_no_provenance` |
| Schemeless `host/path` the user gave | none |
| Bare domain in prose | none |
| `curl … \| sh` | `fetch_exec_shape` |
| `wget … && chmod +x` | `fetch_exec_shape` |
| `… base64 -d \| sh` | `fetch_exec_shape` |
| `certutil -urlcache -f` | `fetch_exec_shape` |
| `bitsadmin /transfer` | `fetch_exec_shape` |
| `mshta http://…` | `fetch_exec_shape` |
| `/home/u/.ssh/id_rsa` | `credential_path` |
| `cat ./.env` | `credential_path` |
| `ls -la ./src` | none |
| Model echoing its own earlier URL in a later turn | `url_no_provenance` + `fetch_exec_shape` |

End-to-end: with `SHIM_GUARD=log` on a test instance, a model told to run
`wget http://…/setup.sh | sh` produced the tool call and the log line above was
written. Per-request cost on a 3.5 MB, 2000-message conversation: **5.3 ms**.

Red-team pass (all detected): `sh -c "curl … | sh"`, `curl … | sudo bash`,
`node -e "fetch(...)"`, `cat ./.env`, a URL split across a newline, a URL inside an
array argument, an IP-literal host, `curl … | tar xz && ./run`, plus the three
Windows forms.

---

## 10. Known limits

These are stated so nobody assumes the guard covers them.

1. **Tool-call arguments only.** A URL in the model's `content` (a markdown link the
   user might click) is not inspected. The guard covers what will be *executed*,
   not what will be *shown*.
2. **`tool` results are trusted.** A compromised tool that prints an attacker URL
   grants provenance to the next call that uses it.
3. **Regex, not parsing.** Arbitrary obfuscation — multi-stage base64, shell string
   concatenation, variable indirection, `eval` of decoded data — is not followed.
   The rules catch the common shapes, which is where opportunistic payloads live.
4. **No allow-list, by design.** Therefore the guard does not know that a host is
   hostile; it only knows the host was not in the conversation. It will miss a
   payload delivered through a URL the user genuinely pasted.
5. **Client-side execution is out of scope.** The guard runs after the response has
   been forwarded. A client that executes tool calls instantly has already started
   before any record exists.
6. **The record is not tamper-proof.** `shim-guard.log` is a plain append log. A
   hash-chained audit log (each line committing to the previous) is a separate,
   unimplemented measure.

---

## 11. The other security measures, and where each is documented

This document is the single entry point for everything security-related in the shim.
The guard is one measure among several; the rest are listed here with what they
protect and where their detail lives, so a reader never has to hunt through the
root README for a link.

| Measure | Concern | Where it lives | Detail |
| --- | --- | --- | --- |
| **Tool-call guard** (`SHIM_GUARD=log`) | what the model is about to hand to a tool | `guard.cjs` + hook in `server.js` | this document |
| Path / method allow-list | what the client may ask the shim for | `server.js` (`ALLOWED_PATHS`, `ALLOWED_METHODS`) | [SECURITY_IMPLEMENTED.en.md](./SECURITY_IMPLEMENTED.en.md) |
| Shared secret (`SHIM_SECRET` + `X-Shim-Key`) | who may talk to the shim | `server.js` | [SHARED_SECRET_IMPLEMENTED.en.md](./SHARED_SECRET_IMPLEMENTED.en.md) |
| Loopback-only client filter (`SHIM_LOOPBACK_ONLY`) | whether non-local clients are refused | `server.js` | [SECURITY_IMPLEMENTED.en.md](./SECURITY_IMPLEMENTED.en.md) |
| Egress header hygiene (2026-09-21) | which client headers reach the upstream | `server.js` (`STRIP_REQUEST_HEADERS`) | [SECURITY_HARDCENING_PLAN.en.md](./SECURITY_HARDCENING_PLAN.en.md) |
| Upstream error-body logging | why an upstream refused a request | `server.js` (`UPSTREAM ERROR BODY`) | this document, §7 |

### Why the guard sits where it does in this list

Every other measure guards the **request path in** — who may call the shim, with
which path, carrying which headers. The guard is the only measure on the
**response path out**, which is why it is the only one that can see what a model
asked a tool to do. The two sides answer different questions and neither
substitutes for the other: a perfect inbound filter does nothing about a
compromised model, and the guard does nothing about an open port.

### Planned but not implemented

- **Hash-chained request log** — each log line committing to the previous one, so
  the record itself cannot be edited after the fact. `shim-guard.log` is currently
  a plain append log (§10, limit 6).
- **Blocking mode** (`SHIM_GUARD=block`) — see §6 for the conditions under which it
  would be acceptable.
- **Cache-key hardening and divergence measurement** — comparing response shape per
  input family to detect a silently swapped model. Not started; noted here so the
  gap is visible rather than assumed closed.
