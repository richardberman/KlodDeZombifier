# Klod DeZombifier

Automatic zombie process cleanup for Claude Desktop on Windows.

## The Problem

Claude Desktop for Windows is distributed as an MSIX package. Every session runs **15 separate processes** -- the main Electron app plus 14 child processes for rendering, networking, GPU, audio, and more. When you close the window, **none of them terminate.** The main process continues running headless with no tray icon, and all children survive as zombies.

These zombies hold file locks. The next time you try to open Claude, you get:

> **"file is opened by another application"**

The only workaround is to manually kill them in Task Manager, or reboot.

### What Gets Orphaned

It's not just `claude.exe`. Every close leaves behind a full process tree:

| Process | Count | Role |
|---|---|---|
| `claude.exe` (main) | 1 | Electron app -- continues running headless after window close |
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

On Unix, child processes die with their parent. On Windows, they don't -- they become orphans owned by the system. Chromium normally handles this using **Win32 Job Objects** (a kernel construct that kills member processes when the owner exits). But MSIX-packaged apps run inside a Desktop Bridge **Silo**, which is itself a Job Object. The Silo interferes with Electron's Job Object initialization, preventing automatic cleanup.

This is a [known, widely-reported upstream bug](docs/technical-analysis.md#related-github-issues) with 10+ open issues on GitHub.

### Why Not Just Wait for the Process to Exit?

Because **closing the window does not exit the main process.** The Electron main process stays alive, headless, with no tray icon. `Wait-Process` blocks forever. The watchdog must detect the *window* closing, not the *process* exiting.

## How It Works

A single hidden PowerShell process runs in the background as a small state machine, polling every 500 ms.

| State | What it does |
|---|---|
| `SEARCHING` | Looks for the Claude Desktop main process every 3 s (a cheap `Get-Process` pre-check; the WMI query only runs when a `claude.exe` exists). |
| `ATTACHED` | Main process found. Waits up to the grace period (default 30 s) for it to show a visible, titled window. A main that never shows one is a headless zombie left over from an earlier session -- its tree is killed when the grace period expires. |
| `ARMED` | The window has been seen. When it disappears, the user closed Claude: the process tree rooted at that main PID is killed within ~500 ms. |

In `ATTACHED` or `ARMED`, the main process dying (a crash) also kills the tree.

Window detection uses Win32 `EnumWindows` + `IsWindowVisible` + `GetWindowTextLength` on the main process's PID. Minimized windows retain the `WS_VISIBLE` flag, so **minimize never triggers cleanup** -- this was verified empirically.

### Kill scope

Only the process tree **rooted at the watched Desktop main PID** is ever killed: the main process, every process whose parent is main, and all of their descendants (`conhost.exe`, `bash.exe`, `powershell.exe`, and so on). Nothing outside that tree is touched, which means:

- A standalone Claude Code CLI running in your own terminal is not affected.
- A new Claude Desktop instance starting during an update relaunch is not affected.

Windows keeps a process's parent PID even after the parent has died, so the tree is still found correctly after a crash. Before each kill, the process is re-checked to confirm the PID still belongs to the same-named process (guards against PID reuse). If `Stop-Process` is denied, `taskkill /F` is tried.

### Performance

- **Detection latency**: ~500 ms (one polling cycle)
- **Kill time**: under 1 second
- **Steady-state cost while Claude is open**: one `EnumWindows` call per 500 ms, no process enumeration
- **Cost while Claude is closed**: one `Get-Process` call per 3 s
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

## Installation

### 1. Copy the script

```powershell
New-Item -ItemType Directory -Path "$env:USERPROFILE\.claude\scripts" -Force
Copy-Item klod-dezombifier.ps1 "$env:USERPROFILE\.claude\scripts\"
```

### 2. Register a scheduled task (runs automatically at logon)

Run from an **elevated** PowerShell (right-click, "Run as administrator"):

```powershell
Register-ScheduledTask -TaskName "KlodDeZombifier" `
    -Action (New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$env:USERPROFILE\.claude\scripts\klod-dezombifier.ps1`"") `
    -Trigger (New-ScheduledTaskTrigger -AtLogOn) `
    -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1))
```

`-NoProfile` keeps your PowerShell profile out of the watchdog. `-RestartCount` brings it back if it ever crashes.

### 3. Start it now (without waiting for next logon)

```powershell
Start-ScheduledTask -TaskName "KlodDeZombifier"
```

Only one instance runs per logon session; starting it twice is harmless (the second exits immediately).

## Options

| Parameter | Default | Purpose |
|---|---|---|
| `-DryRun` | off | Log what would be killed; kill nothing. Useful for checking scope on your machine. |
| `-GraceSeconds N` | 30 | How long an attached main process may run without a window before it is treated as a zombie. Raise it on a slow machine. |
| `-HeartbeatMinutes N` | 15 | Interval of the "still alive" log line. |
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

## Removal

```powershell
Unregister-ScheduledTask -TaskName "KlodDeZombifier" -Confirm:$false
Remove-Item "$env:USERPROFILE\.claude\scripts\klod-dezombifier.ps1"
Remove-Item "$env:USERPROFILE\.claude\scripts\klod-dezombifier.log*" -ErrorAction SilentlyContinue
```

## Limitations

- **Session-level orphans** -- Closing an individual Code tab (without closing the whole app) can also leave orphaned subprocesses. These accumulate until the main app is closed, at which point the watchdog kills them all.
- **Silo corruption** -- If Claude crashes during startup, the MSIX Silo handle may not be released. The watchdog cleans up the processes but cannot recover the Silo; logoff or reboot is required.
- **Reopen within ~1 second of closing** -- Claude's launcher hands a reopen request to an existing main process if one is still alive. If you click the icon while the old tree is being killed, that request can be lost and nothing appears; click again. The new instance is never killed.

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1 (included with Windows), running in FullLanguage mode. The script compiles a small C# helper with `Add-Type`; Constrained Language Mode or AppLocker DLL rules will block it (the log will say so).
- Claude Desktop (MSIX package)

## Technical Details

See [docs/technical-analysis.md](docs/technical-analysis.md) for the full root cause analysis, process inventory, upstream GitHub issue references, empirical test results, bugs discovered during development, the v1.1 hardening review, and alternatives considered.

## License

[MIT](LICENSE)
