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

A lightweight PowerShell script runs hidden in the background and watches for the Claude Desktop window to disappear using the Win32 API. When it does, the script kills every orphaned process within ~500ms.

1. **Discovery** -- Polls every 3 seconds until Claude Desktop is running.
2. **Window monitoring** -- Polls every 500ms using Win32 P/Invoke (`EnumWindows` + `IsWindowVisible` + `GetWindowTextLength`) to check if any `claude.exe` process owns a visible, titled window.
3. **Minimize safety** -- Minimized windows retain the `WS_VISIBLE` flag (`IsWindowVisible` returns `True`). The watchdog only triggers when the window is *destroyed* (closed), never when minimized. This was verified empirically.
4. **Kill** -- When no visible titled windows remain, force-terminates every `claude.exe` and walks the full descendant tree to catch `conhost.exe`, `bash.exe`, `powershell.exe`, and any other children. Falls back to `taskkill /F` if `Stop-Process` is denied.
5. **Re-attach** -- After a 2-second cooldown, loops back to step 1 and watches the next Claude instance.

### Performance

- **Detection latency**: ~500ms (one polling cycle)
- **Kill time**: under 1 second
- **CPU usage while watching**: negligible (sleeping between polls)
- **Memory**: ~30 MB (single hidden PowerShell process)

## Installation

### 1. Copy the script

```powershell
New-Item -ItemType Directory -Path "$env:USERPROFILE\.claude\scripts" -Force
Copy-Item klod-dezombifier.ps1 "$env:USERPROFILE\.claude\scripts\"
```

### 2. Register a scheduled task (runs automatically at logon)

```powershell
Register-ScheduledTask -TaskName "KlodDeZombifier" `
    -Action (New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$env:USERPROFILE\.claude\scripts\klod-dezombifier.ps1`"") `
    -Trigger (New-ScheduledTaskTrigger -AtLogOn) `
    -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero))
```

### 3. Start it now (without waiting for next logon)

```powershell
Start-ScheduledTask -TaskName "KlodDeZombifier"
```

## Verifying It Works

Check that the watchdog is running:

```powershell
Get-CimInstance Win32_Process | Where-Object {
    $_.Name -eq 'powershell.exe' -and $_.CommandLine -match 'klod-dezombifier'
} | Select-Object ProcessId, CreationDate
```

Check the debug log after a close/reopen cycle:

```powershell
Get-Content "$env:USERPROFILE\.claude\scripts\klod-dezombifier-debug.log" | Select-Object -Last 10
```

A successful kill looks like:

```
10:39:13.476  Poll: NO visible titled window (procs=15), TRIGGERING KILL
10:39:13.481  Kill-ClaudeTree: starting
10:39:13.782  Kill-ClaudeTree: killing 18 processes
10:39:13.857  Kill-ClaudeTree: done. killed=5 gone=13 denied=0
10:39:14.389  Kill-ClaudeTree: remaining claude.exe after kill: 0
```

- **killed**: processes terminated by the watchdog
- **gone**: processes that had already exited (normal race condition -- harmless)
- **denied**: processes that resisted termination (should be 0)

## Removal

```powershell
Unregister-ScheduledTask -TaskName "KlodDeZombifier" -Confirm:$false
Remove-Item "$env:USERPROFILE\.claude\scripts\klod-dezombifier.ps1"
Remove-Item "$env:USERPROFILE\.claude\scripts\klod-dezombifier-debug.log" -ErrorAction SilentlyContinue
```

## Limitations

- **Session-level orphans** -- Closing an individual Code tab (without closing the whole app) can also leave orphaned subprocesses. These accumulate until the main app is closed, at which point the watchdog kills them all.
- **Silo corruption** -- If Claude crashes during startup, the MSIX Silo handle may not be released. The watchdog cleans up the processes but cannot recover the Silo; logoff or reboot is required.
- **Fast reopen race** -- If you reopen Claude within ~1 second of closing, the watchdog may kill some processes belonging to the new instance. The new instance recovers by respawning its children (brief flicker, no data loss).

## Requirements

- Windows 10 or 11
- PowerShell 5.1+ (included with Windows)
- Claude Desktop (MSIX package)

## Technical Details

See [docs/technical-analysis.md](docs/technical-analysis.md) for the full root cause analysis, process inventory, upstream GitHub issue references, empirical test results, bugs discovered during development, and alternatives considered.

## License

[MIT](LICENSE)
