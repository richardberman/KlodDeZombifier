# Klod DeZombifier

Automatic zombie process cleanup for Claude Desktop on Windows.

## Quickstart

Closing Claude Desktop leaves 15+ processes running, and their file locks block the next launch. This watchdog kills them within half a second of the window closing, and does nothing else.

Download `klod-dezombifier.ps1`. Then, from the folder you downloaded it to, in an **elevated** PowerShell (right-click, "Run as administrator"):

```powershell
# Install the script
New-Item -ItemType Directory -Path "$env:USERPROFILE\.claude\scripts" -Force
Copy-Item klod-dezombifier.ps1 "$env:USERPROFILE\.claude\scripts\"

# Run it at every logon, through a headless console host (no window at all)
$script   = "$env:USERPROFILE\.claude\scripts\klod-dezombifier.ps1"
$conhost  = "$env:SystemRoot\System32\conhost.exe"
$pwsh     = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$psArgs   = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden"
$action   = New-ScheduledTaskAction -Execute $conhost `
                -Argument "--headless $pwsh $psArgs -File `"$script`""
$trigger  = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
                -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) `
                -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
                -DontStopOnIdleEnd

Register-ScheduledTask -TaskName KlodDeZombifier `
    -Action $action -Trigger $trigger -Settings $settings

# Start it now, without waiting for the next logon
Start-ScheduledTask -TaskName KlodDeZombifier
```

Launching through `conhost.exe --headless` matters: on Windows 11 a plain
`powershell.exe -WindowStyle Hidden` task opens a visible Windows Terminal
window, and closing it kills the watchdog (see [No window](#no-window-why-it-launches-through-conhost---headless)).

Then add the 10-minute repeat trigger, so the watchdog restarts itself if it
is ever killed.
This needs an XML edit: "repeat forever" is expressed by *omitting* the
`<Duration>` element, and passing `-RepetitionDuration ([TimeSpan]::MaxValue)`
to the cmdlet is rejected by the service as out of range.

```powershell
$xml = [xml](Export-ScheduledTask -TaskName KlodDeZombifier)
$ns  = $xml.DocumentElement.NamespaceURI

$rep = $xml.CreateElement('Repetition', $ns)
$i = $xml.CreateElement('Interval', $ns);          $i.InnerText = 'PT10M'
$s = $xml.CreateElement('StopAtDurationEnd', $ns); $s.InnerText = 'false'
[void]$rep.AppendChild($i); [void]$rep.AppendChild($s)

$tt = $xml.CreateElement('TimeTrigger', $ns)
$b = $xml.CreateElement('StartBoundary', $ns)
$b.InnerText = (Get-Date).AddMinutes(2).ToString('yyyy-MM-ddTHH:mm:ss')
$e = $xml.CreateElement('Enabled', $ns);           $e.InnerText = 'true'
[void]$tt.AppendChild($rep); [void]$tt.AppendChild($b); [void]$tt.AppendChild($e)

$nodes = $xml.DocumentElement.SelectSingleNode("//*[local-name()='Triggers']")
[void]$nodes.AppendChild($tt)

Register-ScheduledTask -TaskName KlodDeZombifier -Xml $xml.OuterXml -Force
```

That is the entire install. `-NoProfile` keeps your PowerShell profile out of the watchdog; `-RestartCount` brings it back if it ever crashes. Only one instance runs per logon session, so starting it twice is harmless.

Close and reopen Claude once, then confirm it fired:

```powershell
Get-Content "$env:USERPROFILE\.claude\scripts\klod-dezombifier.log" -Tail 5
```

You want a `Kill: done.` line ending in `denied=0`, followed by `remaining in tree after kill: 0`. See [Verifying It Works](#verifying-it-works) for what each number means, [Options](#options) for tuning, and [Removal](#removal) to uninstall.

## The Problem

Claude Desktop for Windows is distributed as an MSIX package. Every session runs **15 separate processes** — the main Electron app plus 14 child processes for rendering, networking, GPU, audio, and more. When you close the window, **none of them terminate.** The main process continues running headless with no tray icon, and all children survive as zombies.

These zombies hold file locks. The next time you try to open Claude, you get:

> **"file is opened by another application"**

The only workaround is to manually kill them in Task Manager, or reboot.

### What Gets Orphaned

It's not just `claude.exe`. Every close leaves behind a full process tree:

| Process | Count | Role |
|---|---|---|
| `claude.exe` (main) | 1 | Electron app — continues running headless after window close |
| `claude.exe` (crashpad) | 1 | Crash reporting |
| `claude.exe` (GPU) | 1 | Hardware-accelerated rendering |
| `claude.exe` (network) | 1 | HTTP stack |
| `claude.exe` (renderer) | 2 | UI panels |
| `claude.exe` (node service) | 6 | MCP servers, extensions, background work |
| `claude.exe` (audio) | 1 | Audio capture/playback |
| `claude.exe` (video) | 1 | Screen/camera capture |
| `claude.exe` (Code CLI) | 1 | Claude Code backend |
| `conhost.exe` | 1+ | Console hosts for subprocesses |
| `bash.exe` | 1+ | Shell tool execution |
| `powershell.exe` | 1+ | MCP server subprocesses |

That's **15+ processes** surviving every close. `conhost.exe`, `bash.exe`, and `powershell.exe` are the most common holders of the file locks that block restart.

### Why It Happens

On Unix, child processes die with their parent. On Windows, they don't — they become orphans owned by the system. Chromium normally handles this using **Win32 Job Objects** (a kernel construct that kills member processes when the owner exits). But MSIX-packaged apps run inside a Desktop Bridge **Silo**, which is itself a Job Object. The Silo interferes with Electron's Job Object initialization, preventing automatic cleanup.

This is a [known, widely-reported upstream bug](docs/technical-analysis.md#related-github-issues) with 10+ open issues on GitHub.

## Theory of Operation

Three facts about the failure decide the whole design:

1. **The window dies; the process does not.** Closing Claude destroys the window, but the main Electron process keeps running headless — no window, no tray icon, no way to reach it. There is no process exit to wait for, so `Wait-Process` blocks forever and a Job Object around the app never fires.
2. **Windows never signals parent death.** Orphans keep running until something explicitly kills them. Chromium normally handles this with its own Job Object, which the MSIX Desktop Bridge Silo breaks.
3. **Minimizing is not closing.** A minimized window keeps its `WS_VISIBLE` flag and stays in `EnumWindows`. Only a destroyed window disappears.

So the one reliable signal that you are done with Claude is **the disappearance of a visible, titled window owned by the main process**. That is the single thing this watchdog measures. When it goes, everything rooted at that main PID is killed — which is safe precisely because, as [below](#is-anything-worth-keeping-alive), nothing in that tree has any purpose once the window is gone.

Everything that follows is the implementation of that one idea.

## How It Works

A single hidden PowerShell process runs in the background as a small state machine, polling every 500 ms.

| State | What it does |
|---|---|
| `SEARCHING` | Looks for the Claude Desktop main process every 3 s (a cheap `Get-Process` pre-check; the WMI query only runs when a `claude.exe` exists). |
| `ATTACHED` | Main process found. Waits up to the grace period (default 30 s) for it to show a visible, titled window. A main that never shows one is a headless zombie left over from an earlier session — its tree is killed when the grace period expires. |
| `ARMED` | The window has been seen. When it disappears, the user closed Claude: the process tree rooted at that main PID is killed within ~500 ms. |
| `UPDATE-WAIT` | Entered *instead of* killing when a Claude update is staged but not yet installed. Nothing is killed; see [Claude updates](#claude-updates) below. |

In `ATTACHED` or `ARMED`, the main process dying (a crash) also kills the tree — unless an update is staged, in which case it goes to `UPDATE-WAIT` too.

Window detection uses Win32 `EnumWindows` + `IsWindowVisible` + `GetWindowTextLength` on the main process's PID. Minimized windows retain the `WS_VISIBLE` flag, so **minimize never triggers cleanup** — this was verified empirically.

### Claude updates

Accepting an in-app update is a two-step handoff, and v1.1 broke it: Claude would close and simply not come back, still on the old version.

1. While Claude is running, it downloads and **stages** the new package. Windows defers registering it because the app is in use.
2. When you accept, Claude closes its window, and **its own updater — still running inside the old process tree — asks Windows to register the new version**. Windows then shuts the old app down itself, installs the new one, and relaunches it.

A watchdog that kills the tree the instant the window closes destroys the updater before step 2 happens. So v1.2 checks, at the moment the window closes, whether a Claude update is staged (from the `AppXDeploymentServer` event log). If one is, it enters `UPDATE-WAIT` and kills nothing, waiting for one of:

| What happens | What the watchdog does |
|---|---|
| Registration of the new version finishes | Nothing to clean up — Windows already shut the old app down. Returns to `SEARCHING`. |
| The old window comes back | You closed normally, then reopened; the launcher handed that to the same still-running instance. Back to `ARMED`, nothing killed. |
| A new Claude instance starts, with no update activity | An ordinary close followed by a relaunch. The old tree is killed; the new instance is explicitly spared. |
| Nothing, for 2 minutes | The update was staged but not accepted; this was an ordinary close. The old tree is killed. |

With no update staged, closing Claude is handled exactly as before. If the deployment log can't be read, the watchdog logs `Update detection: UNAVAILABLE` at startup and treats every close as ordinary (v1.1 behaviour).

The one cost: while an update is staged and you have *not* accepted it, a normal close keeps the zombies for up to 2 minutes instead of half a second. Reopening in that window still works, because it reuses the running instance.

### Kill scope

Only the process tree **rooted at the watched Desktop main PID** is ever killed: the main process, every process whose parent is main, and all of their descendants (`conhost.exe`, `bash.exe`, `powershell.exe`, and so on). Nothing outside that tree is touched, which means:

- A standalone Claude Code CLI running in your own terminal is not affected.
- A new Claude Desktop instance starting during an update relaunch is not affected.

Windows keeps a process's parent PID even after the parent has died, so the tree is still found correctly after a crash. Before each kill, the process is re-checked to confirm the PID still belongs to the same-named process (guards against PID reuse). If `Stop-Process` is denied, `taskkill /F` is tried.

The watchdog itself sits outside that tree: the scheduled task parents it to the Task Scheduler service, not to Claude. It also explicitly subtracts its own PID and everything below it from the kill set before terminating anything, so no parent chain can route the walk back into itself.

## No window: why it launches through `conhost --headless`

**This was the "unexplained termination" earlier versions of this README listed as a known issue. Solved 2026-09-23.**

On Windows 11 the default terminal ("Let Windows decide") is Windows Terminal. When Task Scheduler starts a console program such as `powershell.exe`, Windows hands its console to Windows Terminal, which opens a visible window titled with the `powershell.exe` path. `-WindowStyle Hidden` cannot hide it: that switch only affects the old console host's window.

That window *was* the watchdog's console, so **closing it killed the watchdog.** Windows sends the program a console close event, and it exits with `0xC000013A` (`STATUS_CONTROL_C_EXIT`). That explains every symptom of the deaths that were recorded as unexplained:

- the script's `try/catch` never fired and nothing was logged, because a console close is not an exception;
- Task Scheduler reported a normal completion, because to it the program simply exited;
- they came at irregular times, because they happened whenever a stray-looking terminal window got closed.

The 10-minute repeat trigger is what finally exposed it: every close was followed a few minutes later by a fresh window.

The task now starts `conhost.exe --headless`, which gives PowerShell a console with no window at all. Nothing appears, so there is nothing to close. `--headless` is how Windows itself starts the console host for pseudo-consoles; it isn't documented for direct use, so if a future Windows changes it, the fallback is a small compiled launcher. The fix lives in the task definition instead of changing your default terminal, which would affect every console program on the machine.

### The repeat trigger stays

The task keeps **two** triggers: at logon, and a repeat every 10 minutes. `MultipleInstances` is `IgnoreNew` and the script holds a single-instance mutex, so a repeat firing while it is already running is a no-op — the second copy logs `already running` and exits. It is now a safety net for any death, rather than the only thing standing between a death and a day without cover.

### Finding it in Task Manager

With no window, it has no app entry. Its processes are `conhost.exe` (Console Window Host) and `powershell.exe` (Windows PowerShell), easy to mistake for strays. To identify it: **Details** tab, right-click the column headers, add **Command line**; the watchdog's ends in `klod-dezombifier.ps1`. If you end it, the repeat trigger brings it back within 10 minutes.

### Performance

- **Detection latency**: ~500 ms (one polling cycle)
- **Kill time**: under 1 second
- **Steady-state cost while Claude is open**: one `EnumWindows` call per 500 ms, no process enumeration
- **Cost while Claude is closed**: one `Get-Process` call per 3 s
- **Cost per close**: one deployment-log query (~80 ms) to check for a staged update
- **Memory**: ~30 MB (single hidden PowerShell process)

## Is Anything Worth Keeping Alive?

Short answer: no. Every surviving process is either dead infrastructure or a pipe with no reader.

| Process | Worth keeping? | Why not |
|---|---|---|
| Main Electron process | No | Runs headless with no window and no tray icon. There is no way to reattach to it or interact with it. |
| Crashpad, GPU, network, audio, video, renderers | No | Chromium infrastructure that only serves a window that no longer exists. |
| MCP servers (node services) | No | Communicate with the parent over stdio. Orphaned, they have no client. |
| Claude Code CLI (`--resume`) | No | Its only consumer was the Code tab that was just destroyed. |
| `conhost.exe`, `bash.exe`, `powershell.exe` | No | Child processes of the above, and the most common holders of the file locks that block restart. |

### The one edge case

If you close the window while a long-running command started by Claude Code (a build, a deploy) is still executing, that command is killed with everything else. In practice this loses nothing you could have used: the command's output was going to Claude's tool pipeline, not to a terminal you can see, and the window that would have displayed the result is gone.

If you need work to survive independently of the app, start it in your own terminal rather than through Claude.

## Options

| Parameter | Default | Purpose |
|---|---|---|
| `-DryRun` | off | Log what would be killed; kill nothing. Useful for checking scope on your machine. |
| `-GraceSeconds N` | 30 | How long an attached main process may run without a window before it is treated as a zombie. Raise it on a slow machine. |
| `-HeartbeatMinutes N` | 15 | Interval of the "still alive" log line. |
| `-UpdateWaitSeconds N` | 120 | With an update staged, how long a closed window may go without Claude's updater registering the new version before the close is treated as ordinary and the tree is killed. |
| `-LogPath PATH` | `klod-dezombifier.log` next to the script | Log location. Rotated to `.old` when it exceeds 1 MB. |

To try a dry run in the foreground:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\scripts\klod-dezombifier.ps1" -DryRun
```

Close Claude, read the log, then press Ctrl+C. (The scheduled-task instance must be stopped first, or the dry run exits at once because of the single-instance guard.)

## Verifying It Works

Check that the watchdog is running:

```powershell
Get-CimInstance Win32_Process | Where-Object {
    $_.Name -eq 'powershell.exe' -and $_.CommandLine -match 'klod-dezombifier'
} | Select-Object ProcessId, CreationDate
```

Check the log after a close/reopen cycle:

```powershell
Get-Content "$env:USERPROFILE\.claude\scripts\klod-dezombifier.log" | Select-Object -Last 10
```

A successful cycle looks like:

```
2026-09-18 12:01:05.123  SEARCHING -> ATTACHED: main PID=40676 (created 09/18/2026 11:58:02); waiting up to 30s for a window
2026-09-18 12:01:05.640  ATTACHED -> ARMED: window seen for main PID=40676
2026-09-18 12:14:33.902  ARMED: window lost for main PID=40676; user closed Claude
2026-09-18 12:14:33.907  Kill: starting (root=40676 reason='window closed')
2026-09-18 12:14:34.310  Kill: done. killed=19 gone=0 skipped=0 denied=0
2026-09-18 12:14:34.822  Kill: remaining in tree after kill: 0
```

- **killed**: processes terminated by the watchdog
- **gone**: processes that had already exited on their own (harmless)
- **skipped**: PIDs that no longer belonged to the expected process (PID-reuse guard; should be 0)
- **denied**: processes that resisted termination (should be 0)

A `Heartbeat: state=ARMED mainPid=40676` line every 15 minutes confirms the watchdog is alive and attached.

Accepting a Claude update should instead look like this — no `Kill:` lines at all:

```
ARMED: window lost for main PID=58792; user closed Claude; update to Claude_2.8000.0.0_x64__pzs8sxrjxfjjc is staged -> UPDATE-WAIT (not killing; waiting for Claude's updater to register it)
UPDATE-WAIT: registration started 3s after window loss - this is the update; standing down until it finishes
UPDATE-WAIT: update registered 35s after window loss; Windows shut the old package down itself - nothing killed
SEARCHING -> ATTACHED: main PID=61234 ...
```

The line near the top of the log, right after `STARTED`, should read `Update detection: ... enabled=True`.

## Removal

```powershell
Unregister-ScheduledTask -TaskName "KlodDeZombifier" -Confirm:$false
Remove-Item "$env:USERPROFILE\.claude\scripts\klod-dezombifier.ps1"
Remove-Item "$env:USERPROFILE\.claude\scripts\klod-dezombifier.log*" -ErrorAction SilentlyContinue
```

## Limitations

- **Session-level orphans** — Closing an individual Code tab (without closing the whole app) can also leave orphaned subprocesses. These accumulate until the main app is closed, at which point the watchdog kills them all.
- **Silo corruption** — If Claude crashes during startup, the MSIX Silo handle may not be released. The watchdog cleans up the processes but cannot recover the Silo; logoff or reboot is required.
- **Reopen within ~1 second of closing** — Claude's launcher hands a reopen request to an existing main process if one is still alive. If you click the icon while the old tree is being killed, that request can be lost and nothing appears; click again. The new instance is never killed.
- **Installed without `conhost --headless`** — On Windows 11 a visible terminal window appears for the watchdog, and closing it stops the watchdog until the repeat trigger restarts it. See [No window](#no-window-why-it-launches-through-conhost---headless).
- **The Cowork service is left alone** — `CoworkVMService` (`cowork-svc.exe`) shows up under a "Claude" heading in Task Manager even with Claude closed. It is a Windows service that starts at boot, not part of the app's process tree, so the watchdog never touches it.

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1 (included with Windows), running in FullLanguage mode. The script compiles a small C# helper with `Add-Type`; Constrained Language Mode or AppLocker DLL rules will block it (the log will say so).
- Claude Desktop (MSIX package)

## Technical Details

See [docs/technical-analysis.md](docs/technical-analysis.md) for the full root cause analysis, process inventory, upstream GitHub issue references, empirical test results, bugs discovered during development, the v1.1 hardening review, and alternatives considered.

## License

[MIT](LICENSE)
