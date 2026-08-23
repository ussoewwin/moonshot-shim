' start-shim-hidden.vbs
' 窓を出さずに両方の shim を起動する。
'   - start-shim.cmd     (AutoClaw <-> Moonshot リレー, port 8787)
'   - start-shim-zai.cmd (AutoClaw <-> Z.ai GLM リレー, port 8789)
' 使い方: この .vbs をダブルクリック、または shell:startup にショートカットを置く。

Set WshShell = CreateObject("WScript.Shell")
Dim fso, baseDir
Set fso = CreateObject("Scripting.FileSystemObject")
baseDir = fso.GetParentFolderName(WScript.ScriptFullName)
WshShell.Run Chr(34) & fso.BuildPath(baseDir, "start-shim.cmd") & Chr(34), 0, False
WshShell.Run Chr(34) & fso.BuildPath(baseDir, "start-shim-zai.cmd") & Chr(34), 0, False
Set WshShell = Nothing
Set fso = Nothing
