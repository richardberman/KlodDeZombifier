# klod-dezombifier.ps1
# Version: 1.2
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
#   UPDATE-WAIT  entered instead of killing when a Claude update is staged
#              but not yet registered. Accepting an update closes the window,
#              then Claude's own updater asks Windows to register the new
#              package, and Windows shuts the old one down itself. Killing
#              the tree first destroys the updater before it makes that call,
#              so the update silently never applies. In this state nothing is
#              killed; the watchdog waits for registration to finish, the old
#              window to come back, a new main to appear, or a timeout.
#
# Scope: only the tree rooted at the watched Desktop main PID is ever killed.
# A standalone Claude Code CLI in your own terminal is untouched, and so is a
# relaunched instance (Windows parents it to sihost.exe, not to the old main).
#
# Parameters:
#   -DryRun               log what would be killed, kill nothing
#   -GraceSeconds N       startup grace before an attached-but-windowless main
#                         is treated as a zombie (default 30)
#   -HeartbeatMinutes N   interval for the "still alive" log line (default 15)
#   -UpdateWaitSeconds N  with an update pending, how long a closed window may
#                         go without the updater registering before it is
#                         treated as an ordinary close (default 120)
#   -LogPath PATH         log file (default: klod-dezombifier.log next to script)
#
# Install: see README.md (Quickstart). The scheduled task needs both a logon
# trigger and a 10-minute repeat trigger.
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
    [int]$UpdateWaitSeconds = 120,
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

Log "=== KLOD DEZOMBIFIER v1.2 STARTED (PID=$PID DryRun=$DryRun GraceSeconds=$GraceSeconds HeartbeatMinutes=$HeartbeatMinutes UpdateWaitSeconds=$UpdateWaitSeconds) ==="

# Update detection reads this log. If it is unavailable, pending updates cannot
# be seen and every close is handled as in v1.1 (killed at once) - so say so.
$DeployLog = 'Microsoft-Windows-AppXDeploymentServer/Operational'
try {
    $dl = Get-WinEvent -ListLog $DeployLog -ErrorAction Stop
    Log "Update detection: $DeployLog enabled=$($dl.IsEnabled) records=$($dl.RecordCount)"
} catch {
    Log "Update detection: UNAVAILABLE ($DeployLog cannot be read); updates may be killed as in v1.1"
}

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

function Find-MainClaudeProcess([int]$ExcludePid = 0) {
    if (-not (Get-Process -Name claude -ErrorAction SilentlyContinue)) { return $null }
    Get-CimInstance Win32_Process -Filter "Name = 'claude.exe'" | Where-Object {
        $_.CommandLine -match 'WindowsApps.*\\app\\Claude\.exe' -and
        $_.CommandLine -notmatch '--type=' -and
        [int]$_.ProcessId -ne $ExcludePid
    } | Sort-Object CreationDate | Select-Object -First 1
}

# ---- update detection ---------------------------------------------------------
# Parsed from the structured EventData fields, not the rendered message, so it
# works whatever language Windows is displayed in. Observed on this system:
#   658  PackageMoniker2 = package whose registration was deferred (app in use)
#   400  DeploymentOperation 1 = Add (staging) finished; anything else on a
#        Claude PackageFullName = registration finished
#   603  Path = Claude_<publisher> (a family name, not a .msix) = registration
#        started - the call Claude's updater makes after its window closes

function Get-EventDataMap($evt) {
    $map = @{}
    foreach ($d in ([xml]$evt.ToXml()).Event.EventData.Data) { $map[$d.Name] = $d.'#text' }
    return $map
}

function Get-PackageVersion([string]$FullName) {
    # Claude_2.7032.0.0_x64__pzs8sxrjxfjjc -> 2.7032.0.0
    $parts = $FullName -split '_'
    if ($parts.Count -ge 2) {
        try { return [version]$parts[1] } catch {}
    }
    return $null
}

# Returns the full name of a staged-but-unregistered Claude package, or $null.
# -AsOf and -RegisteredFullName exist so the logic can be replayed against
# historical log data; in normal use both default to "now".
function Test-ClaudeUpdatePending([datetime]$AsOf = (Get-Date), [string]$RegisteredFullName) {
    if (-not $RegisteredFullName) {
        $reg = Get-AppxPackage -Name Claude -ErrorAction SilentlyContinue | Select-Object -First 1
        $RegisteredFullName = if ($reg) { $reg.PackageFullName } else { '' }
    }
    $events = @(Get-WinEvent -FilterHashtable @{
        LogName = $DeployLog; Id = 658, 400; StartTime = $AsOf.AddDays(-14); EndTime = $AsOf
    } -ErrorAction SilentlyContinue)

    $deferred = $null; $deferredAt = $null
    foreach ($e in ($events | Where-Object { $_.Id -eq 658 } | Sort-Object TimeCreated -Descending)) {
        $d = Get-EventDataMap $e
        if ($d['PackageMoniker2'] -like 'Claude_*') { $deferred = $d['PackageMoniker2']; $deferredAt = $e.TimeCreated; break }
    }
    if (-not $deferred) { return $null }

    foreach ($e in ($events | Where-Object { $_.Id -eq 400 -and $_.TimeCreated -gt $deferredAt })) {
        $d = Get-EventDataMap $e
        if ($d['PackageFullName'] -eq $deferred -and $d['DeploymentOperation'] -ne '1') { return $null }
    }

    # Already on that version or newer (e.g. updated by some other route).
    $dv = Get-PackageVersion $deferred
    $rv = Get-PackageVersion $RegisteredFullName
    if ($dv -and $rv -and $rv -ge $dv) { return $null }
    return $deferred
}

# 'finished', 'started' or 'none' for Claude package registration in (Since, AsOf].
function Get-ClaudeRegisterActivity([datetime]$Since, [datetime]$AsOf = (Get-Date)) {
    $events = @(Get-WinEvent -FilterHashtable @{
        LogName = $DeployLog; Id = 603, 400; StartTime = $Since; EndTime = $AsOf
    } -ErrorAction SilentlyContinue)
    $started = $false
    foreach ($e in $events) {
        $d = Get-EventDataMap $e
        if ($e.Id -eq 400 -and $d['PackageFullName'] -like 'Claude_*' -and $d['DeploymentOperation'] -ne '1') { return 'finished' }
        if ($e.Id -eq 603 -and $d['Path'] -like 'Claude_*' -and $d['DeploymentOperation'] -ne '1') { $started = $true }
    }
    if ($started) { return 'started' }
    return 'none'
}

function Enter-UpdateWait([int]$OldMainPid, [string]$Pending, [string]$Why) {
    $script:state          = 'UPDATE-WAIT'
    $script:uwOldMainPid   = $OldMainPid
    $script:uwSince        = Get-Date
    $script:uwRegisterSeen = $false
    Log "$Why; update to $Pending is staged -> UPDATE-WAIT (not killing; waiting for Claude's updater to register it)"
}

# Root (if still alive and still claude.exe) plus every descendant, found by
# walking ParentProcessId. WMI keeps ParentProcessId on orphans, so the
# children are still found after the root has died.
#
# Each ExcludePid and everything below it are subtracted from the result. This
# is a set rather than a skipped node because ParentProcessId is never
# revalidated: a long-lived process whose real parent died keeps reporting that
# pid, and if the pid is later reused by something inside the target tree, the
# walk reaches an unrelated process. Subtracting the set means no path can reach
# an excluded process.
function Get-ProcessTree([int]$RootPid, [int[]]$ExcludePid = @()) {
    $all = Get-CimInstance Win32_Process
    $byPid = @{}
    $byParent = @{}
    foreach ($p in $all) {
        $byPid[[int]$p.ProcessId] = $p
        $parent = [int]$p.ParentProcessId
        if (-not $byParent.ContainsKey($parent)) { $byParent[$parent] = New-Object System.Collections.ArrayList }
        [void]$byParent[$parent].Add($p)
    }

    $selfSet = [System.Collections.Generic.HashSet[int]]::new()
    $sq = [System.Collections.Queue]::new()
    foreach ($x in $ExcludePid) {
        if ($x -gt 0 -and $selfSet.Add($x)) { $sq.Enqueue($x) }
    }
    if ($sq.Count -gt 0) {
        while ($sq.Count -gt 0) {
            $sp = $sq.Dequeue()
            if (-not $byParent.ContainsKey($sp)) { continue }
            foreach ($sc in $byParent[$sp]) {
                $scPid = [int]$sc.ProcessId
                if ($scPid -ne $sp -and $selfSet.Add($scPid)) { $sq.Enqueue($scPid) }
            }
        }
    }

    $result = New-Object System.Collections.ArrayList
    $seen = [System.Collections.Generic.HashSet[int]]::new()
    [void]$seen.Add($RootPid)
    if ($byPid.ContainsKey($RootPid) -and $byPid[$RootPid].Name -eq 'claude.exe' -and
        -not $selfSet.Contains($RootPid)) {
        [void]$result.Add($byPid[$RootPid])
    }

    $excluded = 0
    $queue = [System.Collections.Queue]::new()
    $queue.Enqueue($RootPid)
    while ($queue.Count -gt 0) {
        $parent = $queue.Dequeue()
        if (-not $byParent.ContainsKey($parent)) { continue }
        foreach ($child in $byParent[$parent]) {
            $childPid = [int]$child.ProcessId
            if ($childPid -eq $parent) { continue }
            if ($selfSet.Contains($childPid)) {
                $excluded++
                Log "Tree: EXCLUDED protected PID $childPid ($($child.Name)) reached via parent $parent"
                continue
            }
            if ($seen.Add($childPid)) {
                [void]$result.Add($child)
                $queue.Enqueue($childPid)
            }
        }
    }
    # $excluded counts paths blocked, not processes spared: blocking the first
    # hop keeps the whole subtree out without the walk ever reaching it.
    if ($excluded -gt 0) {
        Log "Tree: exclusion blocked $excluded path(s) into protected subtrees ($($selfSet.Count) process(es))"
    }
    return ,$result
}

function Kill-ClaudeTree([int]$RootPid, [string]$Reason, [int[]]$AlsoExclude = @()) {
    $exclude = @($PID) + @($AlsoExclude | Where-Object { $_ -gt 0 })
    Log "Kill: starting (root=$RootPid reason='$Reason' excluding=$($exclude -join ','))"
    if ($exclude -contains $RootPid) {
        Log "Kill: ABORT - root $RootPid is an excluded process; refusing"
        return
    }
    $tree = Get-ProcessTree -RootPid $RootPid -ExcludePid $exclude
    if ($tree.Count -eq 0) {
        Log "Kill: tree is empty, nothing to do"
        return
    }

    # Belt and braces: nothing below may target an excluded process by any path.
    $tree = @($tree | Where-Object { $exclude -notcontains [int]$_.ProcessId })

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
    $remaining = (Get-ProcessTree -RootPid $RootPid -ExcludePid $exclude).Count
    Log "Kill: remaining in tree after kill: $remaining"
    Log "Kill: returning to caller (still alive, pid $PID)"
}

function Start-PostKillCooldown {
    Log "Post-kill: entering 2s cooldown"
    Start-Sleep -Seconds 2
    Log "Post-kill: cooldown done, resuming poll loop"
}

# Every place that used to kill on sight comes through here. If an update is
# staged, stand down into UPDATE-WAIT; otherwise kill exactly as v1.1 did. A
# failure in update detection must never wedge the loop, so it counts as "no
# update pending" and the close is handled the old way.
function Close-OrWait([int]$Root, [string]$Why, [string]$Reason) {
    $pending = $null
    try { $pending = Test-ClaudeUpdatePending }
    catch { Log "Update detection failed ($($_.Exception.Message)); handling as an ordinary close" }

    if ($pending) {
        Enter-UpdateWait -OldMainPid $Root -Pending $pending -Why $Why
        return
    }
    Log $Why
    Kill-ClaudeTree -RootPid $Root -Reason $Reason
    $script:state = 'SEARCHING'
    Start-PostKillCooldown
}

function Get-ClaudeRegisterActivitySafe([datetime]$Since) {
    try { return Get-ClaudeRegisterActivity -Since $Since }
    catch { Log "UPDATE-WAIT: register check failed ($($_.Exception.Message))"; return 'none' }
}

$state = 'SEARCHING'
$mainPid = 0
$attachedAt = $null
$uwOldMainPid = 0
$uwSince = $null
$uwRegisterSeen = $false
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
                Close-OrWait -Root $mainPid -Reason 'main exited before window' `
                    -Why "ATTACHED: main PID=$mainPid exited before showing a window"
            }
            elseif ([ClaudeWindowChecker]::PidHasVisibleTitledWindow($mainPid)) {
                $state = 'ARMED'
                Log "ATTACHED -> ARMED: window seen for main PID=$mainPid"
            }
            elseif (((Get-Date) - $attachedAt).TotalSeconds -ge $GraceSeconds) {
                Close-OrWait -Root $mainPid -Reason 'grace expired without window' `
                    -Why "ATTACHED: no window within ${GraceSeconds}s; main PID=$mainPid is a headless zombie"
            }
        }
        elseif ($state -eq 'ARMED') {
            Start-Sleep -Milliseconds 500
            if (-not (Get-Process -Id $mainPid -ErrorAction SilentlyContinue)) {
                Close-OrWait -Root $mainPid -Reason 'main exited' `
                    -Why "ARMED: main PID=$mainPid is dead (crash)"
            }
            elseif (-not [ClaudeWindowChecker]::PidHasVisibleTitledWindow($mainPid)) {
                Close-OrWait -Root $mainPid -Reason 'window closed' `
                    -Why "ARMED: window lost for main PID=$mainPid; user closed Claude"
            }
        }
        elseif ($state -eq 'UPDATE-WAIT') {
            # Nothing in this state kills during an update. Order matters:
            # a finished registration wins, then the old window returning.
            Start-Sleep -Seconds 1
            $elapsed = [int]((Get-Date) - $uwSince).TotalSeconds
            $act = Get-ClaudeRegisterActivitySafe -Since $uwSince

            if ($act -eq 'finished') {
                Log "UPDATE-WAIT: update registered ${elapsed}s after window loss; Windows shut the old package down itself - nothing killed"
                $state = 'SEARCHING'
            }
            elseif ($act -eq 'started' -and -not $uwRegisterSeen) {
                $uwRegisterSeen = $true
                Log "UPDATE-WAIT: registration started ${elapsed}s after window loss - this is the update; standing down until it finishes"
            }
            elseif ((Get-Process -Id $uwOldMainPid -ErrorAction SilentlyContinue) -and
                    [ClaudeWindowChecker]::PidHasVisibleTitledWindow($uwOldMainPid)) {
                # An update was staged but this was an ordinary close, and the
                # user reopened: the launcher hands that to the still-running
                # headless main, so the SAME process gets its window back.
                # Killing it now would kill the Claude the user is using.
                Log "UPDATE-WAIT: window came back on main PID=$uwOldMainPid after ${elapsed}s (reopened into the same instance) -> ARMED, nothing killed"
                $state = 'ARMED'
            }
            else {
                $newMain = Find-MainClaudeProcess -ExcludePid $uwOldMainPid
                if ($newMain -and $newMain.CreationDate -gt $uwSince) {
                    $newPid = [int]$newMain.ProcessId
                    if ($uwRegisterSeen) {
                        Log "UPDATE-WAIT: new main PID=$newPid started during the update after ${elapsed}s - nothing killed"
                        $state = 'SEARCHING'
                    } else {
                        Log "UPDATE-WAIT: new main PID=$newPid started after ${elapsed}s with no update activity - ordinary close; killing the old tree, sparing the new one"
                        Kill-ClaudeTree -RootPid $uwOldMainPid -Reason 'relaunched while waiting for an update' -AlsoExclude @($newPid)
                        $state = 'SEARCHING'
                        Start-PostKillCooldown
                    }
                }
                elseif (-not $uwRegisterSeen -and $elapsed -ge $UpdateWaitSeconds) {
                    Log "UPDATE-WAIT: no registration within ${UpdateWaitSeconds}s - the staged update was not accepted; handling as an ordinary close"
                    Kill-ClaudeTree -RootPid $uwOldMainPid -Reason 'update wait timed out'
                    $state = 'SEARCHING'
                    Start-PostKillCooldown
                }
                elseif ($uwRegisterSeen -and $elapsed -ge 600) {
                    Log "UPDATE-WAIT: registration started but not finished after ${elapsed}s; leaving it to Windows - nothing killed"
                    $state = 'SEARCHING'
                }
            }
        }
    } catch {
        Log "ERROR in state ${state}: $($_.Exception.Message) | $($_.ScriptStackTrace)"
        Start-Sleep -Seconds 5
    }
}
