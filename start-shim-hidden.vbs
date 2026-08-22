' start-shim-hidden.vbs
' 窓を出さずに start-shim.cmd (AutoClaw <-> Moonshot リレー) を起動する。
' 使い方: この .vbs をダブルクリック、または shell:startup にショートカットを置く。

Set WshShell = CreateObject("WScript.Shell")
Dim fso, cmdPath
Set fso = CreateObject("Scripting.FileSystemObject")
cmdPath = fso.BuildPath(fso.GetParentFolderName(WScript.ScriptFullName), "start-shim.cmd")
WshShell.Run Chr(34) & cmdPath & Chr(34), 0, False
Set WshShell = Nothing
Set fso = Nothing