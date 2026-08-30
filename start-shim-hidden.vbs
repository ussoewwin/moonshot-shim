' start-shim-hidden.vbs
' Launches both shim relays hidden at logon (no console windows).
'   - start-shim.cmd      (AutoClaw <-> Moonshot relay, port 8787)
'   - start-shim-zai.cmd  (AutoClaw <-> Z.ai GLM relay, port 8789)
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
WshShell.Run Chr(34) & fso.BuildPath(baseDir, "start-shim.cmd") & Chr(34), 0, False
WshShell.Run Chr(34) & fso.BuildPath(baseDir, "start-shim-zai.cmd") & Chr(34), 0, False
Set WshShell = Nothing
Set fso = Nothing
