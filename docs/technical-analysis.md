# Technical Analysis: Claude Desktop Zombie Processes on Windows

## Root Cause

Claude Desktop is an Electron application distributed as an MSIX (Microsoft Store) package. Electron, built on Chromium's multi-process architecture, spawns a separate OS process for each functional subsystem. The main process acts as the parent of all others.

On Unix-like operating systems, process group semantics and signal propagation ensure that child processes are terminated when their parent exits. **Windows has no equivalent automatic mechanism.** Child processes whose parent exits become orphans owned by the system; they continue running until explicitly terminated or until the user logs off.

Chromium and Electron normally mitigate this by using **Win32 Job Objects** -- a kernel construct that can be configured to terminate all member processes when the owning handle is closed. However, MSIX-packaged applications run inside a Desktop Bridge container that uses its own Job Object (a "Silo") for the app lifecycle. This interferes with Electron's Job Object initialization, preventing the automatic cleanup that the framework intends.

## Confirmed Upstream: MSIX-Specific Bug

This is a **known, widely-reported bug** with multiple open issues in the `anthropics/claude-code` repository. The root cause has been identified by community contributors and is specific to the MSIX packaging -- it would not occur with a conventional Win32 installer.

**Primary mechanism** ([#89648](https://github.com/anthropics/claude-code/issues/89648)): Electron's `app.relaunch()` waits only for the main process PID before activating a new `Claude.exe` instance. Nothing waits for child helper processes. While Chromium's Job Object does reap helpers when the main process dies, that termination is **asynchronous** -- so a new MSIX instance can start while old `Claude.exe` utility children still hold the executable image mapped, causing `ERROR_SHARING_VIOLATION`.

**Hard-exit paths** ([#89648](https://github.com/anthropics/claude-code/issues/89648)): When the internal watchdog's `app.exit(0)` fires mid-teardown, there is no child cleanup at all. Helpers linger as genuine persistent orphans, not just transient racers.

**Silo/Job Object corruption** ([#53247](https://github.com/anthropics/claude-code/issues/53247)): If the main process crashes during startup, the kernel-side Silo cleanup does not run. The orphaned handle persists in the user session, and subsequent launch attempts hit `ERROR_SHARING_VIOLATION` (`0x80070020`) when trying to convert a fresh Job Object into a Silo. Only logoff or reboot recovers.

**Accumulation over time** ([#58565](https://github.com/anthropics/claude-code/issues/58565)): Closing a Claude Code session window does not terminate the underlying `claude.exe` subprocess. These orphans accumulate over hours or days, each holding ~50-75 MB of RAM.

## Related GitHub Issues

| Issue | Summary |
|---|---|
| [#89648](https://github.com/anthropics/claude-code/issues/89648) | Root cause analysis: orphaned helper locks executable across relaunch/quit |
| [#78680](https://github.com/anthropics/claude-code/issues/78680) | Orphaned processes after close block relaunch |
| [#42776](https://github.com/anthropics/claude-code/issues/42776) | Stale file lock on MSIX package executable after close |
| [#58565](https://github.com/anthropics/claude-code/issues/58565) | Orphaned subprocesses accumulate across session closes |
| [#53247](https://github.com/anthropics/claude-code/issues/53247) | Orphaned Silo/Job Object after crash; only logoff or reboot recovers |
| [#48787](https://github.com/anthropics/claude-code/issues/48787) | Stale file lock on WindowsApps package; only full reboot resolves |
| [#80502](https://github.com/anthropics/claude-code/issues/80502) | Orphaned CoworkVMService blocks MSIX registration repair |
| [#90476](https://github.com/anthropics/claude-code/issues/90476) | GPU process crash leaves app as zombie; relaunch impossible until MSIX repair |
| [#15423](https://github.com/anthropics/claude-code/issues/15423) | Orphaned renderer processes after quit prevent restart |
| [#93008](https://github.com/anthropics/claude-code/issues/93008) | Request for non-MSIX installer to avoid these failure modes entirely |

## Non-MSIX Installer: Not Currently Available

A conventional Win32 `.exe` installer (Squirrel-based) existed in earlier versions of Claude Desktop but was replaced with MSIX. As of September 2026, **Claude Desktop for Windows is distributed only as an MSIX package**. There is no supported non-MSIX installation path. [Issue #93008](https://github.com/anthropics/claude-code/issues/93008) tracks the request to restore a non-MSIX option. A native installer would likely eliminate the zombie process problem entirely, since Chromium's Job Object would operate without interference from the Desktop Bridge Silo.

## Process Inventory

Captured during a typical Claude Desktop session (version 2.2553.1, Windows 11 Pro 10.0.26200, September 2026).

### Process Tree

All child processes are direct children of the main Electron process.

| Role | Count | Description |
|---|---|---|
| Main (Electron) | 1 | Application entry point. Path: `WindowsApps\...\app\Claude.exe`. No `--type=` argument. |
| Crashpad handler | 1 | Crash reporting. `--type=crashpad-handler` |
| GPU process | 1 | Hardware-accelerated rendering. `--type=gpu-process` |
| Network service | 1 | HTTP stack and protocol handling. `--type=utility`, `network.mojom.NetworkService` |
| Renderer | 2 | Web content rendering (UI panels). `--type=renderer` |
| Node service | 6 | MCP servers, extensions, background work. `--type=utility`, `node.mojom.NodeService` |
| Audio service | 1 | Audio capture/playback. `--type=utility`, `audio.mojom.AudioService` |
| Video capture | 1 | Screen/camera capture. `--type=utility`, `video_capture.mojom.VideoCaptureService` |
| Claude Code CLI | 1 | Code tab backend. Separate executable at `AppData\Roaming\Claude\claude-code\...\claude.exe` |
| **Total** | **15** | |

### Non-`claude.exe` Children

The Claude Code CLI and Node service processes spawn additional children that also become orphans:

| Process | Parent Role | Purpose |
|---|---|---|
| `conhost.exe` | Claude Code CLI, Node service | Console host for stdio-based subprocesses |
| `bash.exe` | Claude Code CLI | Shell tool execution |
| `powershell.exe` | Node service | MCP server or extension subprocess |

These children are the most likely holders of the file locks.

### Identifying the Main Process

The main Electron process is distinguishable from all children by two properties:

1. Its command line contains the `WindowsApps\...\app\Claude.exe` path.
2. Its command line does **not** contain a `--type=` argument.

All other `claude.exe` processes carry a `--type=` flag (renderer, utility, gpu-process, crashpad-handler) or are the Claude Code CLI at a different filesystem path.

## Solution Design: Win32 Window Visibility Detection

### Why Not Wait-Process?

The initial design used `Wait-Process` to block until the main process exited. This does not work because **closing the Claude Desktop window does not terminate the main Electron process.** The main process continues running headless with no tray icon, no visible UI, and no way for the user to interact with it. All 15 processes survive indefinitely.

### Why Not MainWindowHandle?

`Process.MainWindowHandle` in .NET is heuristic-based -- it can return zero for minimized windows or when the internal mapping changes. Unreliable for production use.

### Window Detection Approach

The watchdog uses Win32 P/Invoke to call `EnumWindows`, checking each window with `IsWindowVisible` and `GetWindowTextLength`. A window is considered "alive" if it is visible and has a non-empty title.

### Empirical Test Results

| State | `IsWindowVisible` | `GetWindowTextLength` | `IsIconic` | Processes |
|---|---|---|---|---|
| Normal (window open) | True | > 0 | False | 15 |
| Minimized | **True** | > 0 | True | 15 |
| Window closed | **False** | 0 | False | **15** (all survive) |

Key findings:

- **Minimized windows keep `WS_VISIBLE`.** `IsWindowVisible` returns True for minimized windows. `IsIconic` correctly reports the minimized state. This means minimize does NOT trigger cleanup -- exactly the desired behavior.
- **Window close IS detectable.** When the user closes the window, all visible windows drop to zero. The 15 processes remain alive but have no visible windows.
- **~6 second kill window.** In testing, there was a 6+ second gap between window close and user reopen -- ample time for the 500ms polling cycle.

## Bugs Found During Development

### 1. `$pid` is a read-only automatic variable in PowerShell

The kill loop originally used:

```powershell
foreach ($pid in $toKill) {
    Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue
}
```

`$pid` (`$PID`) is a built-in PowerShell automatic variable containing the current process ID. Using it as a `foreach` loop variable silently fails to iterate -- **the loop body never executes.** This made the entire kill function dead code. PowerShell reports no error.

Fixed by changing the loop variable to `$p`.

### 2. Em dash (U+2014) causes parse failure in UTF-8-no-BOM files

A log message contained an em dash character (`--`). When PowerShell reads a UTF-8 file without a BOM using the Windows-1252 codepage, byte `0x94` (part of the em dash's UTF-8 sequence `E2 80 94`) is interpreted as a right double-quote (`"`). This prematurely terminates a string literal, causing cascading parse errors across the entire script.

Fixed by using only ASCII characters in all strings.

## Alternatives Considered

| Approach | Why Not |
|---|---|
| **Wait-Process on main PID** | The main process does not exit when the window is closed. It continues running headless. |
| **Parent-dead orphan detection** | Requires the parent to actually exit first, which it doesn't. |
| **MainWindowHandle polling** | `Process.MainWindowHandle` is heuristic-based in .NET and can return zero for minimized windows. Unreliable. |
| **Manual kill script** | Requires the user to remember to run it after every close. |
| **Scheduled task on a timer** | Unacceptable latency. Orphaned processes hold file locks for the duration of the polling interval. |
| **Wrapper/launcher script** | MSIX apps can be launched from Start menu, taskbar, protocol handlers, and other entry points. A wrapper only covers one launch path. |
| **C# Win32 Job Objects** | MSIX apps already run inside a Desktop Bridge Job Object. Assigning to a second Job Object from an external process is unreliable. Requires a compiled binary. |
| **WMI permanent event subscription** | Requires admin privileges and `SeDebugPrivilege`. Permanent subscriptions are fragile and persist in the WMI repository even after script deletion. |
| **WMI temporary event** | Requires `WITHIN` polling (minimum 1s), no faster than the current approach while being more complex. |

## v1.1 Hardening

A post-publish code and security review of v1.0 found eight issues. All are fixed in v1.1.

| # | Finding | Severity | Fix |
|---|---|---|---|
| 1 | The kill targeted every process named `claude.exe` on the machine. A standalone Claude Code CLI (native install: `~\.local\bin\claude.exe`) in the user's own terminal died with Desktop, along with whatever it was running. The same over-scoping killed a new instance starting during an update relaunch. | High | Kill is rooted at the watched Desktop main PID: seed = main plus every process whose `ParentProcessId` is main, then walk descendants. WMI retains `ParentProcessId` on orphans, so the crash path still works. |
| 2 | The trigger armed immediately on attach, so a cold start slower than one 500 ms poll was killed before its window appeared. | High | State machine `SEARCHING -> ATTACHED -> ARMED`. Kill-on-window-loss only after a window has been seen. An attached main that never shows a window within the grace period (default 30 s) is treated as a headless zombie and killed. |
| 3 | The scheduled task ran without `-NoProfile`, so the user's profile scripts executed inside the watchdog at every logon. | Medium | `-NoProfile -NonInteractive`; the task also gets `-RestartCount 3 -RestartInterval 1 min`. |
| 4 | No exception handling around the main loop; a .NET exception ended the watchdog silently until next logon. | Medium | Loop body in `try/catch` with a logged error and 5 s back-off. Heartbeat line every 15 min (configurable) so "alive but blind" is visible in the log. |
| 5 | Force-kill by PID from a stale snapshot; PID reuse in the gap could hit an unrelated process. | Low | Each PID is re-fetched and its process name compared with the snapshot before `Stop-Process`; mismatches are counted as `skipped`. |
| 6 | Discovery ran an unfiltered `Win32_Process` query (200-350 ms) every 3 s while Claude was closed. | Low | `Get-Process -Name claude` pre-check first; the WMI query is WQL-filtered to `Name = 'claude.exe'`. |
| 7 | No single-instance guard; a manual launch plus the scheduled task produced two watchdogs. | Low | Named mutex `Local\KlodDeZombifier`; a second instance logs and exits 0. |
| 8 | File saved as UTF-8 without BOM (the em-dash parse-failure class), hardcoded log path, unbounded log growth, no Constrained Language Mode note. | Low | Saved with BOM and an ASCII-only rule in the header; log defaults to `$PSScriptRoot`; rotated at 1 MB; README states the FullLanguage requirement. |

### Scope verification

Measured on the live process tree before implementing fix #1:

- The only visible titled window ("Claude") is owned by the main Electron process. The window check therefore watches a single PID, and the poll loop no longer enumerates processes at all.
- All 14 other `claude.exe` processes are direct children of main (9 utility, 2 renderer, gpu, crashpad, Code CLI). `conhost.exe`, `bash.exe`, and `powershell.exe` hang off the Code CLI and one utility child. Seeding the tree with main's direct children and walking descendants captures everything.

### Test evidence (2026-09-18)

All tests ran the candidate from the repo path with the deployed v1.0 stopped. A decoy process named `claude.exe` (a renamed `ping.exe`, outside the Desktop tree) ran throughout; v1.0's name-based sweep would have killed it.

| Test | Result |
|---|---|
| Static: parse, UTF-8 BOM, ASCII-only, no automatic-variable misuse | Pass |
| Single instance: second copy logs "already running" and exits | Pass |
| Log path defaults to the script's folder when launched from another directory | Pass |
| Heartbeat at the configured interval | Pass (60 s interval, consecutive lines 60 s apart) |
| Idle gate | `Get-Process` pre-check ~31 ms vs ~280 ms for the WMI query it avoids. The WQL filter itself does not make the WMI query cheaper; the saving comes from skipping it. |
| Minimize/restore while `ARMED` | No trigger |
| Dry run on window close | 23-process would-kill list: main, its 14 `claude.exe` children, and their `conhost`/`bash`/`powershell` descendants. Decoy absent. |
| Headless zombie found at watchdog start | No window within grace -> tree killed (`killed=5 gone=15 skipped=0 denied=0`, 0 remaining) |
| Attach to a starting instance | `ATTACHED -> ARMED` in ~0.5 s, no kill |
| Window close while `ARMED` (production defaults) | `killed=4 gone=14 skipped=0 denied=0`, 0 remaining, ~0.4 s |
| Decoy `claude.exe` | Alive after one dry run and three real kills |

`gone` is high by design: main is killed first, and most Chromium children exit on their own as it dies.

One defect was found and fixed during testing. A process caught mid-exit still returns a `Process` object, but with an empty name, and the PID-reuse guard counted it as `skipped`. An empty name is now classified as `gone`; `skipped` is reserved for a genuine name mismatch.
