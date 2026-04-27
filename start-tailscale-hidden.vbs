' ============================================================
' start-tailscale-hidden.vbs
' ------------------------------------------------------------
' Window-less launcher for the Cursor <-> Kimi K2.6 path.
' Runs start-tailscale.cmd completely hidden (no console,
' no taskbar button) in the background.
' ------------------------------------------------------------
' Usage:
'   Double-click this .vbs file, or place a shortcut in
'   shell:startup for auto-launch on logon.
' ============================================================

Set WshShell = CreateObject("WScript.Shell")

' Resolve .cmd path relative to this .vbs location.
' This avoids hard-coded paths and survives folder moves.
Dim fso, cmdPath
Set fso = CreateObject("Scripting.FileSystemObject")
cmdPath = fso.BuildPath(fso.GetParentFolderName(WScript.ScriptFullName), "start-tailscale.cmd")

' Chr(34) = double-quote character.
' 0 = hidden window, False = do not wait (fire-and-forget)
WshShell.Run Chr(34) & cmdPath & Chr(34), 0, False

Set WshShell = Nothing
Set fso = Nothing
