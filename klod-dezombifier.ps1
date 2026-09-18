# klod-dezombifier.ps1
# Kills Claude Desktop and all child processes when the user closes the window.
#
# Problem: closing Claude's window (Alt-F4, X, taskbar) does NOT terminate the
# main Electron process -- it runs headless with no tray icon. Children
# (claude.exe helpers, conhost, bash, powershell) hold file locks that
# block the next launch.
#
# How it works:
#   1. Finds the main Electron process (WindowsApps Claude.exe, no --type=)
#   2. Polls every 500ms using Win32 EnumWindows + IsWindowVisible to check
#      whether ANY claude.exe process has a visible titled window
#   3. Minimized windows remain visible (IsWindowVisible=True, IsIconic=True)
#      so minimize does NOT trigger cleanup
#   4. When zero visible titled windows remain (user closed) OR the main
#      process exits (crash), kills the entire process tree immediately
#   5. Loops to watch the next launch
#
# Install:
#   Register-ScheduledTask -TaskName "KlodDeZombifier" `
#       -Action (New-ScheduledTaskAction -Execute "powershell.exe" `
#           -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$env:USERPROFILE\.claude\scripts\klod-dezombifier.ps1`"") `
#       -Trigger (New-ScheduledTaskTrigger -AtLogOn) `
#       -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
#           -ExecutionTimeLimit ([TimeSpan]::Zero))
#
# Remove:
#   Unregister-ScheduledTask -TaskName "KlodDeZombifier" -Confirm:$false

$logFile = "$env:USERPROFILE\.claude\scripts\klod-dezombifier-debug.log"

function Log($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    "$ts  $msg" | Out-File $logFile -Encoding utf8 -Append
}

Log "=== KLOD DEZOMBIFIER STARTED (PID=$PID) ==="

Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Collections.Generic;

public class ClaudeWindowChecker {
    [DllImport("user32.dll")]
    static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll")]
    static extern int GetWindowTextLength(IntPtr hWnd);

    delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    public static bool HasVisibleTitledWindow(HashSet<int> pids) {
        bool found = false;
        EnumWindows((hWnd, lParam) => {
            if (IsWindowVisible(hWnd) && GetWindowTextLength(hWnd) > 0) {
                uint pid;
                GetWindowThreadProcessId(hWnd, out pid);
                if (pids.Contains((int)pid)) {
                    found = true;
                    return false;
                }
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }
}
"@

Log "Add-Type compiled OK"

function Find-MainClaudeProcess {
    Get-CimInstance Win32_Process | Where-Object {
        $_.Name -eq 'claude.exe' -and
        $_.CommandLine -match 'WindowsApps.*\\app\\Claude\.exe' -and
        $_.CommandLine -notmatch '--type='
    } | Select-Object -First 1
}

function Get-ClaudePidSet {
    $set = [System.Collections.Generic.HashSet[int]]::new()
    Get-Process -Name claude -ErrorAction SilentlyContinue | ForEach-Object { [void]$set.Add($_.Id) }
    return $set
}

function Kill-ClaudeTree {
    Log "Kill-ClaudeTree: starting"
    $allProcs = Get-CimInstance Win32_Process
    $claudeProcs = $allProcs | Where-Object { $_.Name -eq 'claude.exe' }
    if (-not $claudeProcs) {
        Log "Kill-ClaudeTree: no claude.exe found"
        return
    }

    $toKill = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($p in $claudeProcs) { [void]$toKill.Add($p.ProcessId) }

    $queue = [System.Collections.Queue]::new()
    foreach ($p in $toKill) { $queue.Enqueue($p) }
    while ($queue.Count -gt 0) {
        $parentPid = $queue.Dequeue()
        foreach ($child in ($allProcs | Where-Object { $_.ParentProcessId -eq $parentPid -and $_.ProcessId -ne $parentPid })) {
            if ($toKill.Add($child.ProcessId)) {
                $queue.Enqueue($child.ProcessId)
            }
        }
    }

    Log "Kill-ClaudeTree: killing $($toKill.Count) processes"
    $killed = 0
    $gone = 0
    $denied = 0
    foreach ($p in $toKill) {
        try {
            Stop-Process -Id $p -Force -ErrorAction Stop
            $killed++
        } catch {
            if ($_.Exception.Message -match 'Cannot find a process') {
                $gone++
            } else {
                Log "Kill-ClaudeTree: access denied PID $p -- trying taskkill"
                $null = & taskkill /F /PID $p 2>&1
                if ($LASTEXITCODE -eq 0) { $killed++ } else { $denied++ }
            }
        }
    }
    Log "Kill-ClaudeTree: done. killed=$killed gone=$gone denied=$denied"

    Start-Sleep -Milliseconds 500
    $remaining = (Get-Process -Name claude -ErrorAction SilentlyContinue).Count
    Log "Kill-ClaudeTree: remaining claude.exe after kill: $remaining"
}

while ($true) {
    Log "Outer loop: looking for main Claude process"
    $main = Find-MainClaudeProcess
    while (-not $main) {
        Start-Sleep -Seconds 3
        $main = Find-MainClaudeProcess
    }

    $mainPid = $main.ProcessId
    Log "Outer loop: found main PID=$mainPid, entering poll loop"

    while ($true) {
        Start-Sleep -Milliseconds 500

        $proc = Get-Process -Id $mainPid -ErrorAction SilentlyContinue
        if (-not $proc) {
            Log "Poll: main PID=$mainPid is DEAD, breaking"
            break
        }

        $pids = Get-ClaudePidSet
        if ($pids.Count -eq 0) {
            Log "Poll: zero claude.exe processes, breaking"
            break
        }

        $hasWindow = [ClaudeWindowChecker]::HasVisibleTitledWindow($pids)
        if (-not $hasWindow) {
            Log "Poll: NO visible titled window (procs=$($pids.Count)), TRIGGERING KILL"
            break
        }
    }

    Kill-ClaudeTree

    Start-Sleep -Seconds 2
    Log "Post-kill sleep done, looping back"
}
