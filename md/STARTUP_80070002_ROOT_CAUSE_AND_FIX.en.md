# Startup Failure `80070002` (wscript.exe) - Root Cause and Complete Fix

## Scope

This document explains, in full detail, the startup failure that produced:

- `wscript.exe` popup error: `80070002` ("The system cannot find the file specified")

It covers:

1. The exact error symptom
2. The fundamental (architectural) reason
3. The file that was fixed
4. The exact code that was added/changed and what it means
5. Why this fix prevents recurrence
6. Post-fix verification results

---

## 1) Error Symptom

After Windows logon, a startup launcher intended to run the shim stack hidden in the background failed with:

- `wscript.exe`
- Error code `80070002`
- Meaning: **target file path not found**

Operational impact:

- `start-tailscale.cmd` was not launched
- the local proxy chain did not fully come up
- expected listening ports were missing until manually recovered

---

## 2) Fundamental Root Cause (Not Just the Surface Error)

### Surface cause

The VBScript launcher still referenced a placeholder path:

- `"<repo-path>\start-tailscale.cmd"`

So `WshShell.Run(...)` tried to execute a non-existent file path, triggering `80070002`.

### Architectural cause

The startup launcher was coupled to a hard-coded absolute path / placeholder instead of resolving the batch file from the script's own location.

That means any of these events can break startup:

- repository move/rename
- placeholder left unreplaced
- machine-specific path differences

In short: the design relied on path constants, not location-relative resolution.

---

## 3) File That Was Fixed

Only this runtime file was changed for this issue:

- `start-tailscale-hidden.vbs`

No functional changes were applied to:

- `server.js`
- `inject-header-proxy.mjs`
- `start-tailscale.cmd` (for this specific error)

---

## 4) Code Added/Changed and Meaning

The launcher now resolves `start-tailscale.cmd` relative to the `.vbs` file itself.

```vbscript
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
```

### Line-by-line meaning

- `WScript.ScriptFullName` returns the full path of the currently running `.vbs`.
- `fso.GetParentFolderName(...)` extracts the folder containing the `.vbs`.
- `fso.BuildPath(..., "start-tailscale.cmd")` builds a valid OS path to the sibling `.cmd` in the same directory.
- `WshShell.Run ..., 0, False` runs hidden (`0`) and non-blocking (`False`) so logon does not stall.

This removes dependency on any hard-coded machine path and makes startup portable across folder moves.

---

## 5) Why This Fix Prevents Recurrence

Before:

- launcher depended on a static path token (`<repo-path>`)
- startup failed whenever token replacement was missing or stale

After:

- launcher computes runtime path from its own location every time
- moving the repository folder does not break startup as long as:
  - `.vbs` and `.cmd` remain together in the same directory
  - startup shortcut points to the `.vbs`

This changes the failure mode from "path configuration fragile" to "self-locating launcher."

---

## 6) Post-Fix Validation

The following checks were completed:

1. Startup shortcut target check
   - points to `D:\USERFILES\GitHub\moonshot-shim\start-tailscale-hidden.vbs`
   - target is correct

2. Launch execution check
   - run VBS launcher
   - no visible console window (expected hidden mode)

3. Port readiness check
   - `8787 LISTEN OK`
   - `8788 LISTEN OK`

Meaning:

- the launcher now successfully reaches and executes `start-tailscale.cmd`
- shim chain starts as expected
- the original `80070002` path-not-found failure is resolved

---

## 7) Operational Notes

- This fix is intentionally minimal and scoped to startup path resolution.
- It does not alter cache behavior, request shaping, or security policy.
- It is safe to keep as the default launcher behavior for future moves/renames.

---

## 8) Quick Triage Checklist (If Similar Error Appears Again)

1. Confirm startup shortcut target still points to `start-tailscale-hidden.vbs`.
2. Confirm `.vbs` and `start-tailscale.cmd` are in the same folder.
3. Manually run the `.vbs` once.
4. Verify listening ports:
   - `8787`
   - `8788`
5. If ports are missing, inspect runtime logs from the batch launcher path.

