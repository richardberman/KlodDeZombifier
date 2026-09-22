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

### Acceptance test (2026-09-18)

Every test above ran a candidate started by hand from the repo path, in most cases with a helper script orchestrating the steps around the close. The acceptance test removed all of that scaffolding. It exercised the installed artifact: the deployed script in `%USERPROFILE%\.claude\scripts`, launched by the registered `KlodDeZombifier` scheduled task, at production defaults (30 s grace, 15 min heartbeat), with no dry run, no orchestrator and no decoy.

Baseline immediately before the close: watchdog PID 26032, parented to the Task Scheduler service, `ARMED` on main PID 27368, with a tree of 16 `claude.exe` plus 4 children (two `conhost.exe`, one `powershell.exe`, one `bash.exe`). Three heartbeats logged 15 minutes apart confirmed the configured interval.

| Measure | Result |
|---|---|
| Window loss detected | 13:57:26.357 |
| Kill complete | 13:57:26.806 -- 449 ms after detection |
| Counters | `killed=4 gone=15 skipped=0 denied=0` |
| Processes left in tree | 0 |
| Re-attached and `ARMED` on the new instance | 13:57:30.261, about 4 s after the close |

The 19 processes accounted for are one fewer than the 20 in the baseline; short-lived helper processes come and go between a snapshot and the close, so the two counts are not expected to match exactly.

Three properties this run established that the earlier tests did not:

- **`skipped=0` under production timing.** The mid-exit misclassification found and fixed during testing does not recur.
- **The kill works end to end from the installed artifact.** Window loss to empty tree in 449 ms, with the script, task registration and defaults a user would actually get.
- **The watchdog was still alive immediately afterwards** (PID 26032), so the kill does not synchronously take it down.

**A claim this section previously made, now withdrawn.** It asserted that "the watchdog survives the kill it performs," treating one observation as a general property. Nineteen minutes after this run the same process was gone, and two further instances died without performing any kill at all. Surviving a kill once did not establish that it survives kills, and the claim should never have been written in that form. See [Unexplained termination](#unexplained-termination-open) below.

**The `AtLogOn` trigger** was confirmed on 2026-09-18: a logoff/logon cycle produced a fresh `KLOD DEZOMBIFIER v1.1 STARTED` line at 15:09:32 with a new PID parented to the Task Scheduler service.

## Unexplained termination (open)

The watchdog process is terminated by something external at irregular intervals. **The cause is unknown.**

| # | Started | Died | Lifetime | Context |
|---|---|---|---|---|
| A | 09-18 13:08:13 | between 14:08:15 and 15:07:13 | 60–119 min | Idle; had performed a successful kill at 13:57 and survived it |
| B | 09-18 15:15:22 | 09-18 15:18:29 | 3 min | ~5 s after completing a kill |
| C | 09-19 22:26:56 | 09-19 22:49:23 | 22 min | Idle in the poll loop; Claude open since 21:33 and never closed; no kill had run |

Identical signature every time:

- Task Scheduler records the action ending with `3221225786` = `0xC000013A` = `STATUS_CONTROL_C_EXIT`.
- The script's `try/catch` never fires and nothing is written to its log; the last line is whatever it was doing normally.
- Task Scheduler logs `id=201` + `id=102` — *successfully completed* — with no `id=330` (stopped by user) and no `id=111` (terminated by scheduler). It observed the exit; it did not cause it.
- Because the scheduler sees a normal completion, `RestartOnFailure` never applies.

### Ruled out

| Candidate | Why it is out |
|---|---|
| The script's own kill path | Occurrence C performed no kill at all |
| Killing itself via the tree walk | Self-exclusion guard added and verified; C had no kill regardless |
| `StopOnIdleEnd` / idle settings | B and C both ran with it `false` |
| `ExecutionTimeLimit` | `PT0S` (unlimited); lifetimes vary from 3 to 119 min |
| Task Scheduler stopping it | No `id=330`/`id=111`; an operator stop produces `0x8007041B`, measured 17/17 |
| The Schedule service restarting | Host PID 2808 continuous across all three deaths |
| Antivirus | Bitdefender is the only active AV; its own on-disk logs record nothing at any death. McAfee is a stale SecurityCenter2 registration, not installed |
| PID reuse reaching the watchdog | Only boot-time system processes have stale parents, none related to Claude |
| A script exception | `try/catch` would have logged it |
| Someone ending it in Task Manager | Plausible for one occurrence, but C happened while the operator was running an unrelated elevated script |

### Investigation notes

Occurrence B — dying five seconds after a kill — looked like strong evidence the kill was responsible, and a six-lens investigation was built on that premise. Occurrence C falsified it: same signature, no kill, nothing happening. The correlation in B was coincidence. Anyone picking this up should treat the kill path as exonerated and look for an external terminator.

`0xC000013A` is the status Windows sets when a console process is terminated via a console control event, which is why the console family of hypotheses was explored at length. Nothing confirmed one, and no candidate explains a process dying while idle with no console activity anywhere near it.

### Mitigation

The task carries a 10-minute repeat trigger alongside the logon trigger, so an unexplained death costs at most ~10 minutes of cover. `MultipleInstances=IgnoreNew` plus a single-instance mutex in the script make a repeat fire during normal running a no-op.

This does not fix the deaths. It removes the consequence that actually caused harm: on 2026-09-18 the watchdog died at 15:18 and stayed dead for a full day, because the only trigger was at-logon, and the zombies it exists to remove accumulated unnoticed until the operator found them manually in Task Manager.

## v1.2: The watchdog broke Claude's in-app updates

### Symptom

Accepting a Claude Desktop update closed the app and nothing else happened: no install, no relaunch, still on the old version. Three consecutive attempts on 2026-09-22 failed this way. With the watchdog disabled, the next attempt installed and relaunched normally, which settled the cause before any fix was designed.

### Mechanism: a two-step handoff

The `Microsoft-Windows-AppXDeploymentServer/Operational` log shows the update as two separate deployment operations. Comparing the successful attempt with the three failures, event by event:

| Step | Event | Successful (watchdog off) | Failed ×3 (watchdog on) |
|---|---|---|---|
| Stage the new package while Claude runs | 603 Add → 658 deferred registration → 400 Add finished | ✓ 16:06:37 – 16:07:18 | ✓ every time |
| Updater asks Windows to register it, **after the window closes** | 603 `RegisterByPackageFamilyName`, `ForceApplicationShutdownOption`, calling process `claude.exe` | ✓ 16:09:37 | **never issued** |
| Windows shuts the old app down, including the packaged `CoworkVMService` | 9648 / 9650 | ✓ 16:10:07 | — |
| Registration finishes; old package moved to `Deleted` | 400 Register finished, 472 | ✓ 16:10:09 | — |
| New version launches | new main process, parented to `sihost.exe` | ✓ 16:10:08 | — |

Staging succeeded every time. The failures are missing the second step entirely: the call that registers the staged package is made by Claude's updater from inside the old process tree, after the window has closed. The watchdog killed that tree about half a second after the window disappeared, before the call could be made.

An earlier hypothesis — that a force-kill leaves the MSIX container half torn down, so Windows never sees the package as free — was wrong, and so was the fix it implied (terminate more gracefully). The updater does not need to die more politely; it needs to survive long enough to make the call.

Three measurements shaped the fix:

- **Windows' own shutdown leaves nothing behind.** After the successful update, zero processes remained from the old package, so a watchdog that stands down during an update loses nothing.
- **The relaunched main is parented to `sihost.exe`**, not to the old main. A kill rooted at the old main can never reach it.
- **Registration is readable from structured event fields**, independent of display language: 658 `PackageMoniker2` is the deferred package; 400 with `DeploymentOperation` other than `1` (Add) is a finished registration; 603 whose `Path` is a family name rather than a `.msix` is a registration starting. The query takes about 80 ms, and the log reached back 8 days on the development machine.

### Fix

At every point where v1.1 would kill, the watchdog first checks whether a Claude package is staged but not registered: the newest 658 for Claude with no later finished registration of that package, and newer than the currently registered version. If so, it enters `UPDATE-WAIT`, where nothing is killed. It leaves that state when:

- the registration finishes (Windows has already cleaned up; nothing to do);
- the old main's window comes back (an ordinary close followed by a reopen, which the launcher hands to the same still-running instance);
- a Claude main created after the window closed appears — with registration seen, nothing is killed; without it, this was an ordinary close followed by a relaunch, so the old tree is killed with the new main explicitly excluded;
- 120 s pass with no registration (`-UpdateWaitSeconds`): the update was staged but not accepted, so the old tree is killed;
- a registration has run for 600 s without finishing: it is left to Windows, and nothing is killed.

The window-coming-back case was found during design, not testing. Without it, closing Claude normally while an update was staged, then reopening within two minutes, would have left the watchdog waiting on a process that was by then the running application — and the timeout would have killed it.

Failures in update detection are treated as "no update staged", so a broken query degrades to v1.1 behaviour rather than wedging the loop. Startup logs whether the deployment log is readable.

### Testing

- **Detection replayed against the real log, 22 checks.** The functions were extracted from the shipped script and run as of historical moments that day: pending while each staged update sat unregistered, still pending mid-registration at 16:09:50, not pending once registration finished at 16:10:09, and not pending on a machine already newer than the staged version. Registration-activity checks confirm that staging alone never counts as registration — the case most likely to fool a naive implementation.
- **The state machine driven through 11 scenarios, 24 checks.** The actual body of the main loop, extracted from the script, was run with system calls stubbed and a fake clock: accepted update, ordinary close then reopen into the same instance, ordinary close with no reopen, relaunch as a new instance, a pre-existing main not mistaken for a new one, update with no staged package (identical to v1.1), detection throwing, registration never finishing, a watchdog restarted mid-update, the main already dead, and the registration check throwing during the wait.
- **Mutation testing, 3 of 3 caught.** Planting three bugs in copies of the script — dropping the window-came-back check, dropping the "created after the close" guard, and ignoring pending updates altogether (the original defect) — made exactly the scenarios aimed at them fail. The last one failed 14 checks across 9 scenarios. This establishes that the simulation exercises the real code rather than its stubs.

Not yet exercised end to end: a real update accepted with v1.2 running. The first one will log how long after the window closes Claude's updater makes its registration call. That gap has never been measured and is the number that would justify tightening the 120-second wait.
