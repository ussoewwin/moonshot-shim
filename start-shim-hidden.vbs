' start-shim-hidden.vbs
' ????????? shim ?????reasoning ???????
'   - start-shim.cmd      (AutoClaw <-> Moonshot ???, port 8787)
'   - start-shim-zai.cmd  (AutoClaw <-> Z.ai GLM ???, port 8789)
'   - set-reasoning.cmd   (?????????? reasoning ? true ???)
' ???: ?? .vbs ???????????? shell:startup ????????????

Set WshShell = CreateObject("WScript.Shell")
Dim fso, baseDir
Set fso = CreateObject("Scripting.FileSystemObject")
baseDir = fso.GetParentFolderName(WScript.ScriptFullName)
WshShell.Run Chr(34) & fso.BuildPath(baseDir, "start-shim.cmd") & Chr(34), 0, False
WshShell.Run Chr(34) & fso.BuildPath(baseDir, "start-shim-zai.cmd") & Chr(34), 0, False
WScript.Sleep 5000
WshShell.Run Chr(34) & fso.BuildPath(baseDir, "set-reasoning.cmd") & Chr(34), 0, True
Set WshShell = Nothing
Set fso = Nothing
