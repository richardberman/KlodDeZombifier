# klod-dezombifier.ps1
# Version: 1.1
#
# Kills Claude Desktop and its entire child process tree when the user closes
# the window.
#
# Problem: closing Claude's window (Alt-F4, X, taskbar) does NOT terminate the
# main Electron process -- it keeps running headless with no tray icon. Its
# children (claude.exe helpers, conhost, bash, powershell) hold file locks that
# block the next launch.
#
# How it works (state machine, 500 ms poll):
#   SEARCHING  no Claude Desktop main process yet. Cheap Get-Process pre-check
#              every 3 s; the WMI query only runs when a claude.exe exists.
#   ATTACHED   main process found; waiting up to -GraceSeconds for it to show
#              a visible titled window. If it never does, it is a headless
#              zombie from an earlier session and its tree is killed.
#   ARMED      window has been seen. When it disappears (user closed Claude),
#              the tree rooted at that main PID is killed. Minimized windows
#              keep WS_VISIBLE, so minimize never triggers.
#   In ATTACHED or ARMED, the main process dying (crash) also kills the tree.
#
# Scope: only the tree rooted at the watched Desktop main PID is ever killed.
# A standalone Claude Code CLI in your own terminal, or a second Desktop
# instance starting during an update relaunch, is untouched.
#
# Parameters:
#   -DryRun             log what would be killed, kill nothing
#   -GraceSeconds N     startup grace before an attached-but-windowless main
#                       is treated as a zombie (default 30)
#   -HeartbeatMinutes N interval for the "still alive" log line (default 15)
#   -LogPath PATH       log file (default: klod-dezombifier.log next to script)
#
# Install (from an elevated PowerShell):
#   Register-ScheduledTask -TaskName "KlodDeZombifier" `
#       -Action (New-ScheduledTaskAction -Execute "powershell.exe" `
#           -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$env:USERPROFILE\.claude\scripts\klod-dezombifier.ps1`"") `
#       -Trigger (New-ScheduledTaskTrigger -AtLogOn) `
#       -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
#           -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1))
#
# Remove:
#   Unregister-ScheduledTask -TaskName "KlodDeZombifier" -Confirm:$false
#
# ENCODING: keep this file UTF-8 WITH BOM and keep every string literal ASCII.
# Windows PowerShell 5.1 reads a BOM-less file as Windows-1252, where a byte of
# a multi-byte character can decode to a quote and break parsing of the file.

param(
    [switch]$DryRun,
    [int]$GraceSeconds = 30,
    [int]$HeartbeatMinutes = 15,
    [string]$LogPath
)

if (-not $LogPath) {
    $base = if ($PSScriptRoot) { $PSScriptRoot } else { $PWD.Path }
    $LogPath = Join-Path $base 'klod-dezombifier.log'
}

if ((Test-Path $LogPath) -and (Get-Item $LogPath).Length -gt 1MB) {
    Move-Item $LogPath ($LogPath + '.old') -Force
}

function Log($msg) {
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    try { "$ts  $msg" | Out-File $LogPath -Encoding utf8 -Append } catch {}
}

# Single instance per logon session. A killed instance leaves the mutex
# abandoned; WaitOne then throws but the caller still owns it.
$mutex = New-Object System.Threading.Mutex($false, 'Local\KlodDeZombifier')
$acquired = $false
try { $acquired = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $acquired = $true }
if (-not $acquired) {
    Log "Another instance is already running; exiting (PID=$PID)"
    exit 0
}

Log "=== KLOD DEZOMBIFIER v1.1 STARTED (PID=$PID DryRun=$DryRun GraceSeconds=$GraceSeconds HeartbeatMinutes=$HeartbeatMinutes) ==="

try {
    Add-Type @"
using System;
using System.Runtime.InteropServices;

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

    public static bool PidHasVisibleTitledWindow(int targetPid) {
        bool found = false;
        EnumWindows((hWnd, lParam) => {
            if (IsWindowVisible(hWnd) && GetWindowTextLength(hWnd) > 0) {
                uint pid;
                GetWindowThreadProcessId(hWnd, out pid);
                if ((int)pid == targetPid) {
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
} catch {
    Log "FATAL: Add-Type failed (Constrained Language Mode or AppLocker?): $($_.Exception.Message)"
    exit 1
}

function Find-MainClaudeProcess {
    if (-not (Get-Process -Name claude -ErrorAction SilentlyContinue)) { return $null }
    Get-CimInstance Win32_Process -Filter "Name = 'claude.exe'" | Where-Object {
        $_.CommandLine -match 'WindowsApps.*\\app\\Claude\.exe' -and
        $_.CommandLine -notmatch '--type='
    } | Sort-Object CreationDate | Select-Object -First 1
}

# Root (if still alive and still claude.exe) plus every descendant, found by
# walking ParentProcessId. WMI keeps ParentProcessId on orphans, so the
# children are still found after the root has died.
function Get-ProcessTree([int]$RootPid) {
    $all = Get-CimInstance Win32_Process
    $byPid = @{}
    $byParent = @{}
    foreach ($p in $all) {
        $byPid[[int]$p.ProcessId] = $p
        $parent = [int]$p.ParentProcessId
        if (-not $byParent.ContainsKey($parent)) { $byParent[$parent] = New-Object System.Collections.ArrayList }
        [void]$byParent[$parent].Add($p)
    }

    $result = New-Object System.Collections.ArrayList
    $seen = [System.Collections.Generic.HashSet[int]]::new()
    [void]$seen.Add($RootPid)
    if ($byPid.ContainsKey($RootPid) -and $byPid[$RootPid].Name -eq 'claude.exe') {
        [void]$result.Add($byPid[$RootPid])
    }

    $queue = [System.Collections.Queue]::new()
    $queue.Enqueue($RootPid)
    while ($queue.Count -gt 0) {
        $parent = $queue.Dequeue()
        if (-not $byParent.ContainsKey($parent)) { continue }
        foreach ($child in $byParent[$parent]) {
            $childPid = [int]$child.ProcessId
            if ($childPid -ne $parent -and $seen.Add($childPid)) {
                [void]$result.Add($child)
                $queue.Enqueue($childPid)
            }
        }
    }
    return ,$result
}

function Kill-ClaudeTree([int]$RootPid, [string]$Reason) {
    Log "Kill: starting (root=$RootPid reason='$Reason')"
    $tree = Get-ProcessTree -RootPid $RootPid
    if ($tree.Count -eq 0) {
        Log "Kill: tree is empty, nothing to do"
        return
    }

    if ($DryRun) {
        Log "Kill: DRY RUN - would kill $($tree.Count) processes:"
        foreach ($p in $tree) { Log "    $($p.ProcessId) | $($p.Name) | parent=$($p.ParentProcessId)" }
        return
    }

    $killed = 0; $gone = 0; $skipped = 0; $denied = 0
    foreach ($p in $tree) {
        $targetPid = [int]$p.ProcessId
        $live = Get-Process -Id $targetPid -ErrorAction SilentlyContinue
        # A process caught mid-exit still returns an object, but with no name.
        $liveName = if ($live) { $live.ProcessName } else { $null }
        if (-not $liveName) { $gone++; continue }

        # PID-reuse guard: the PID must still belong to the same-named process
        # we snapshotted a moment ago.
        $expected = [System.IO.Path]::GetFileNameWithoutExtension($p.Name)
        if ($liveName -ne $expected) {
            $skipped++
            Log "Kill: PID $targetPid is now '$liveName' (expected '$expected') - skipped (PID reuse)"
            continue
        }

        try {
            Stop-Process -Id $targetPid -Force -ErrorAction Stop
            $killed++
        } catch {
            if ($_.Exception.Message -match 'Cannot find a process') {
                $gone++
            } else {
                $null = & taskkill /F /PID $targetPid 2>&1
                if ($LASTEXITCODE -eq 0) {
                    $killed++
                } else {
                    $denied++
                    Log "Kill: denied PID $targetPid ($($p.Name)): $($_.Exception.Message)"
                }
            }
        }
    }
    Log "Kill: done. killed=$killed gone=$gone skipped=$skipped denied=$denied"

    Start-Sleep -Milliseconds 500
    $remaining = (Get-ProcessTree -RootPid $RootPid).Count
    Log "Kill: remaining in tree after kill: $remaining"
}

$state = 'SEARCHING'
$mainPid = 0
$attachedAt = $null
$lastHeartbeat = Get-Date
$heartbeatInterval = [TimeSpan]::FromMinutes($HeartbeatMinutes)

while ($true) {
    try {
        if (((Get-Date) - $lastHeartbeat) -ge $heartbeatInterval) {
            $hbPid = if ($state -eq 'SEARCHING') { '-' } else { $mainPid }
            Log "Heartbeat: state=$state mainPid=$hbPid"
            $lastHeartbeat = Get-Date
        }

        if ($state -eq 'SEARCHING') {
            $main = Find-MainClaudeProcess
            if ($main) {
                $mainPid = [int]$main.ProcessId
                $attachedAt = Get-Date
                $state = 'ATTACHED'
                Log "SEARCHING -> ATTACHED: main PID=$mainPid (created $($main.CreationDate)); waiting up to ${GraceSeconds}s for a window"
            } else {
                Start-Sleep -Seconds 3
            }
        }
        elseif ($state -eq 'ATTACHED') {
            Start-Sleep -Milliseconds 500
            if (-not (Get-Process -Id $mainPid -ErrorAction SilentlyContinue)) {
                Log "ATTACHED: main PID=$mainPid exited before showing a window"
                Kill-ClaudeTree -RootPid $mainPid -Reason 'main exited before window'
                $state = 'SEARCHING'
                Start-Sleep -Seconds 2
            }
            elseif ([ClaudeWindowChecker]::PidHasVisibleTitledWindow($mainPid)) {
                $state = 'ARMED'
                Log "ATTACHED -> ARMED: window seen for main PID=$mainPid"
            }
            elseif (((Get-Date) - $attachedAt).TotalSeconds -ge $GraceSeconds) {
                Log "ATTACHED: no window within ${GraceSeconds}s; main PID=$mainPid is a headless zombie"
                Kill-ClaudeTree -RootPid $mainPid -Reason 'grace expired without window'
                $state = 'SEARCHING'
                Start-Sleep -Seconds 2
            }
        }
        elseif ($state -eq 'ARMED') {
            Start-Sleep -Milliseconds 500
            if (-not (Get-Process -Id $mainPid -ErrorAction SilentlyContinue)) {
                Log "ARMED: main PID=$mainPid is dead (crash)"
                Kill-ClaudeTree -RootPid $mainPid -Reason 'main exited'
                $state = 'SEARCHING'
                Start-Sleep -Seconds 2
            }
            elseif (-not [ClaudeWindowChecker]::PidHasVisibleTitledWindow($mainPid)) {
                Log "ARMED: window lost for main PID=$mainPid; user closed Claude"
                Kill-ClaudeTree -RootPid $mainPid -Reason 'window closed'
                $state = 'SEARCHING'
                Start-Sleep -Seconds 2
            }
        }
    } catch {
        Log "ERROR in state ${state}: $($_.Exception.Message) | $($_.ScriptStackTrace)"
        Start-Sleep -Seconds 5
    }
}
