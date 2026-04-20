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

' Chr(34) = double-quote character. Wrap the .cmd path so spaces
' (none here, but defensive) are handled correctly.
' 0 = hidden window, False = do not wait (fire-and-forget)
WshShell.Run Chr(34) & "<repo-path>\start-tailscale.cmd" & Chr(34), 0, False

Set WshShell = Nothing
