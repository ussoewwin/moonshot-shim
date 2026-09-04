# img-mcp — image recognition MCP server

MCP wrapper around the AutoGLM image-recognition skill (`autoglm-image-recognition`). Structurally immune to the Windows cp932 console-encoding crash (UTF-8-forced skill scripts + Node wrapper).

```
AutoClaw (MCP client)
   └─▶ http://127.0.0.1:19690/mcp   (Streamable HTTP, JSON-RPC 2.0)
          └─▶ node img-mcp-server.mjs
                 ├─ upload_image     → autoglm-file-upload/upload-mix.py   → public OSS URL
                 └─ recognize_image  → autoglm-image-recognition/image-recognition.py
                                          (local_path is auto-uploaded before recognition)
```

## Tools

| Tool | Input | Output |
|---|---|---|
| `upload_image` | `path` (absolute local path) | `{ url }` — public AutoGLM OSS URL |
| `recognize_image` | `image_url` or `local_path`, optional `prompt` | recognition text (`data.text`) |

- Passing `local_path` to `recognize_image` runs **upload → recognition in one call**.
- Example `prompt`: "List all text in the screenshot", "Give model ID and base URL on one line".

## Startup / autostart

- Launcher: `start-img-mcp.cmd` (`start-img-mcp.ps1` runs node under an auto-restart loop)
- Logon autostart: wired into `start-shim-hidden.vbs` (with the shell:startup shortcut it starts at logon)
- Port: **19690** (override with `IMG_MCP_PORT`)
- Health check: `GET http://127.0.0.1:19690/healthz` → `{"status":"ok","tools":["upload_image","recognize_image"]}`
- Logs: `img-mcp-wrapper.log` (wrapper) / the server itself logs to stdout

## AutoClaw registration

Registered in `openclaw.json` / `openclaw.runtime.json` under `mcp.servers`:

```json
"autoglm-img": {
  "type": "streamable-http",
  "url": "http://127.0.0.1:19690/mcp",
  "enabled": true
}
```

After restarting AutoClaw, agents can call the `recognize_image` / `upload_image` tools.

## Implementation notes (append future tools here)

- The server just shells out to the existing skill Python scripts (UTF-8 hardened). **Append new image-related tools to this section.**
- The cp932 guard (`sys.stdout.reconfigure(encoding="utf-8")`) was embedded into `image-recognition.py` and the three `upload-mix.py` scripts on 2026-09-04. Any new script must include the same guard at the top.
- Empty `usage.prompt_tokens_details` from some relays (OpenCode Go) does not affect recognition.
- Localhost binding only (`127.0.0.1`); no auth implemented (single-machine assumption). Add `SHIM_SECRET`-style auth before ever exposing it externally.

## Change log

- 2026-09-04: initial version. `upload_image` / `recognize_image` tools. Registered in AutoClaw as `autoglm-img`.
