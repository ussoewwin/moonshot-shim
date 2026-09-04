' start-shim-hidden.vbs
' Launches all shim relays hidden at logon (no console windows).
'   - start-shim-zai.cmd         (AutoClaw <-> Z.ai GLM relay, port 8789)
'   - start-shim-deepseek.cmd    (AutoClaw <-> DeepSeek relay, port 8791)
'   - start-shim-opencode.cmd    (AutoClaw <-> OpenCode Go DeepSeek relay, port 8792)
'   - start-shim-opencode-glm.cmd (AutoClaw <-> OpenCode Go GLM relay, port 8793)
'   - start-img-mcp.cmd          (img-recognition MCP server, port 19690)
'
' NOTE: set-reasoning is intentionally NOT auto-run here: it rewrites
' AutoClaw config files and must only run while AutoClaw is closed.
' Run it manually:  node set-reasoning.mjs --dry-run   (preview)
'                   node set-reasoning.mjs             (apply, AutoClaw closed)
'
' Usage: place this file (or a shortcut to it) in shell:startup.

Set WshShell = CreateObject("WScript.Shell")
Dim fso, baseDir
Set fso = CreateObject("Scripting.FileSystemObject")
baseDir = fso.GetParentFolderName(WScript.ScriptFullName)
WshShell.Run Chr(34) & fso.BuildPath(baseDir, "start-shim-zai.cmd") & Chr(34), 0, False
WshShell.Run Chr(34) & fso.BuildPath(baseDir, "start-shim-deepseek.cmd") & Chr(34), 0, False
WshShell.Run Chr(34) & fso.BuildPath(baseDir, "start-shim-opencode.cmd") & Chr(34), 0, False
WshShell.Run Chr(34) & fso.BuildPath(baseDir, "start-shim-opencode-glm.cmd") & Chr(34), 0, False
WshShell.Run Chr(34) & fso.BuildPath(baseDir, "start-shim-opencode-kimi.cmd") & Chr(34), 0, False
WshShell.Run Chr(34) & fso.BuildPath(baseDir, "start-img-mcp.cmd") & Chr(34), 0, False
Set WshShell = Nothing
Set fso = Nothing
