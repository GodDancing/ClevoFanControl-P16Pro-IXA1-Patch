#Requires -Version 5.1
<#
.SYNOPSIS
    Point the ClevoFanControl logon task at the silent launcher (or put it back).

.DESCRIPTION
    The app's own "auto run" checkbox creates the task

        ClevoFanControl   LogonTrigger   RunLevel=HighestAvailable
        Action: <exe>     (no arguments)

    which shows the window at every logon. This script rewrites only the <Actions>
    block so the task runs

        powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden
                       -ExecutionPolicy Bypass -File start-hidden.ps1

    Everything else (trigger, principal, settings) is left exactly as the app wrote it.
    The existing XML is read back from the task itself, so this stays correct if the
    app changes its template.

    IMPORTANT: the app rewrites the task from scratch every time its "auto run"
    checkbox is toggled. After toggling it, run this script again with -Mode Install.
    -Mode Show tells you whether the task currently points at the launcher.

.PARAMETER Mode
    Install  (default) point the task at start-hidden.ps1
    Restore            put the bare exe back, i.e. undo this script
    Show               print the task's current XML and the action it resolves to
    Test               start the task now and show what the launcher logged

.PARAMETER Exe
    Path to clevo-fan-control.exe. Defaults to the copy next to this script.

.PARAMETER Launcher
    Path to start-hidden.ps1. Defaults to the copy next to this script.

.PARAMETER TaskName
    Default ClevoFanControl.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File install-startup.ps1 -Mode Show
#>
[CmdletBinding()]
param(
    [ValidateSet('Install', 'Restore', 'Show', 'Test')]
    [string] $Mode = 'Install',
    [string] $Exe,
    [string] $Launcher,
    [string] $TaskName = 'ClevoFanControl'
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Exe)      { $Exe      = Join-Path $scriptDir 'clevo-fan-control.exe' }
if (-not $Launcher) { $Launcher = Join-Path $scriptDir 'start-hidden.ps1' }

function Invoke-Schtasks {
    param([string[]] $Argv)
    $out = & schtasks.exe @Argv 2>&1
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = ($out | Out-String).Trim() }
}

function Get-TaskXml {
    $r = Invoke-Schtasks @('/Query', '/TN', $TaskName, '/XML')
    if ($r.Code -ne 0) { return $null }
    return $r.Out
}

# ---------------------------------------------------------------------------
# Show
# ---------------------------------------------------------------------------
if ($Mode -eq 'Show') {
    $xml = Get-TaskXml
    if ($null -eq $xml) {
        Write-Host "Task '$TaskName' does not exist. (Turn on the app's auto-run checkbox first.)"
        exit 1
    }
    $action = [regex]::Match($xml, '(?s)<Actions\b.*?</Actions>').Value
    Write-Host '--- action ---'
    Write-Host $action
    Write-Host '--- verdict ---'
    if ($action -match 'start-hidden\.ps1') {
        Write-Host 'POINTS AT THE LAUNCHER -> the window will not appear at logon.'
    } else {
        Write-Host 'POINTS AT THE BARE EXE -> the window WILL appear at logon.'
        Write-Host "Fix with:  install-startup.ps1 -Mode Install"
    }
    exit 0
}

# ---------------------------------------------------------------------------
# Test - start the task now and report what the launcher did.
# ---------------------------------------------------------------------------
if ($Mode -eq 'Test') {
    $elevated = $false
    try {
        $elevated = ([Security.Principal.WindowsPrincipal]::new(
            [Security.Principal.WindowsIdentity]::GetCurrent())
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { }
    if (-not $elevated) {
        throw 'Test must run elevated: the task itself is RunLevel=HighestAvailable, so schtasks /Run is denied from a normal shell.'
    }

    $logPath = Join-Path $scriptDir 'start-hidden.log'
    $before  = 0
    if (Test-Path -LiteralPath $logPath) { $before = (Get-Item -LiteralPath $logPath).Length }

    $r = Invoke-Schtasks @('/Run', '/TN', $TaskName)
    if ($r.Code -ne 0) { throw "schtasks /Run failed ($($r.Code)): $($r.Out)" }
    Write-Host "Started task '$TaskName'. Waiting for the launcher..."

    $deadline = (Get-Date).AddSeconds(40)
    while ((Get-Date) -lt $deadline) {
        if ((Test-Path -LiteralPath $logPath) -and (Get-Item -LiteralPath $logPath).Length -gt $before) { break }
        Start-Sleep -Milliseconds 250
    }
    Start-Sleep -Milliseconds 1500

    Write-Host ''
    Write-Host '--- what the launcher logged ---'
    if (Test-Path -LiteralPath $logPath) {
        Get-Content -LiteralPath $logPath | Select-Object -Last 8
    } else {
        Write-Host "(no log at $logPath)"
    }
    Write-Host ''
    Write-Host 'Expect: a line starting with "OK" and no visible window.'
    Write-Host 'If the app was already running in the tray, "already running" is the expected outcome.'
    exit 0
}

# ---------------------------------------------------------------------------
# Install / Restore
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $Exe))      { throw "exe not found: $Exe" }
if (-not (Test-Path -LiteralPath $Launcher)) { throw "launcher not found: $Launcher" }

$xml = Get-TaskXml
if ($null -eq $xml) {
    throw "Task '$TaskName' does not exist. Turn on the app's auto-run checkbox once, then re-run this."
}

# The launcher must not rely on the task's working directory.
$arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File &quot;{0}&quot;' -f $Launcher

if ($Mode -eq 'Install') {
    $actions = '<Actions Context="Author"><Exec><Command>powershell.exe</Command><Arguments>{0}</Arguments></Exec></Actions>' -f $arguments
} else {
    $actions = '<Actions Context="Author"><Exec><Command>{0}</Command></Exec></Actions>' -f $Exe
}

$patched = [regex]::Replace($xml, '(?s)<Actions\b.*?</Actions>', { param($m) $actions })
if ($patched -eq $xml) { throw 'Could not find an <Actions> block in the task XML.' }

$tmp = Join-Path $env:TEMP ('ClevoFanControl-task-{0}.xml' -f $PID)
try {
    # The template declares encoding="UTF-16", so the file has to be UTF-16LE.
    Set-Content -LiteralPath $tmp -Value $patched -Encoding Unicode
    $r = Invoke-Schtasks @('/Create', '/TN', $TaskName, '/XML', $tmp, '/F')
    if ($r.Code -ne 0) { throw "schtasks /Create failed ($($r.Code)): $($r.Out)" }
} finally {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
}

Write-Host "Task '$TaskName' updated ($Mode)."
Write-Host ''
& $PSCommandPath -Mode Show -TaskName $TaskName
