#Requires -Version 5.1
<#
.SYNOPSIS
    Start ClevoFanControl and put its window straight into the tray.

.DESCRIPTION
    The application has no "start minimized" switch: src/main.rs only accepts
    --demo / --smoke / --probe / --hardware-check, and src/ui.rs calls win.show()
    unconditionally at startup.

    It does hide itself to the tray on WM_CLOSE while closeToTray is enabled
    (src/ui.rs: `Action::Close if fields.close.value() && tray.is_some() => win.hide()`),
    and the tray icon is created unconditionally at startup (src/ui.rs: Tray::start).
    So this script starts the app and then posts WM_CLOSE to its main window, which
    makes the app run its own hide-to-tray path.

    Safety: the process is never killed and no window is ever destroyed. The only
    thing sent is WM_CLOSE, i.e. exactly what clicking the window's X does. The fan
    worker thread keeps running; the EC is never left un-managed.

    The tray icon's own window is created with dwStyle = 0 (not WS_VISIBLE) and its
    WM_CLOSE handler does NIM_DELETE + DestroyWindow, which would remove the tray
    icon for good. It is therefore explicitly excluded: only a visible, unowned,
    titled top-level window is ever targeted.

.PARAMETER Exe
    Path to clevo-fan-control.exe. Defaults to the copy next to this script.

.PARAMETER TimeoutSec
    How long to wait for the main window to appear. Default 30.

.PARAMETER SettleMs
    Grace period after the window appears, before WM_CLOSE is posted. Not strictly
    load-bearing: the message cannot be dispatched until Fl::wait() runs, which is
    after Tray::start() has completed, so the tray is always registered by then.
    Kept small because the window is visible on screen during this window. Default 150.

.PARAMETER DryRun
    Report the window that would be closed and send nothing.

.PARAMETER Diagnose
    List every top-level window the process owns, then exit. Sends nothing.

.PARAMETER LogFile
    Append a one-line result per run. Default: start-hidden.log next to this script.

.NOTES
    This script must run ELEVATED. The application's manifest is
    requireAdministrator, and User Interface Privilege Isolation silently drops
    window messages sent from a lower-integrity process to a higher-integrity one,
    so a non-elevated run cannot close its window. The scheduled task runs with
    RunLevel=HighestAvailable, which satisfies this; a manual test must be run from
    an elevated shell. The log records both the elevation state and the PostMessage
    result so a failure of this kind is visible rather than silent.

.EXAMPLE
    powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File start-hidden.ps1
#>
[CmdletBinding()]
param(
    [string] $Exe,
    [int]    $TimeoutSec = 30,
    [int]    $SettleMs   = 150,
    [switch] $DryRun,
    [switch] $Diagnose,
    [string] $LogFile
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Exe)     { $Exe     = Join-Path $scriptDir 'clevo-fan-control.exe' }
if (-not $LogFile) { $LogFile = Join-Path $scriptDir 'start-hidden.log' }
$procName = [System.IO.Path]::GetFileNameWithoutExtension($Exe)

function Write-Log {
    param([string] $Message)
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 } catch { }
}

# ---------------------------------------------------------------------------
# Win32 helpers. Compiled in-memory by Add-Type; no developer toolchain needed.
# Written in C# 5 syntax because Windows PowerShell 5.1 compiles with the
# .NET Framework csc, not Roslyn.
# ---------------------------------------------------------------------------
if (-not ('ClevoFanControl.Startup' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace ClevoFanControl
{
    public static class Startup
    {
        private delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);

        [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
        [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hWnd);
        [DllImport("user32.dll")] private static extern IntPtr GetWindow(IntPtr hWnd, uint cmd);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr hWnd, StringBuilder sb, int max);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr hWnd, StringBuilder sb, int max);
        [DllImport("user32.dll", SetLastError = true)] private static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

        private const uint GW_OWNER = 4;
        private const uint WM_CLOSE = 0x0010;
        private const string TrayClass = "ClevoFanControl.Tray.x64";

        public sealed class WinInfo
        {
            public IntPtr Handle;
            public string Class;
            public string Title;
            public bool Visible;
            public bool Owned;

            public string Describe()
            {
                return string.Format(
                    "hwnd=0x{0:X} class={1} {2} {3} title=\"{4}\"",
                    Handle.ToInt64(), Class,
                    Visible ? "visible" : "hidden",
                    Owned ? "owned" : "top-level",
                    Title);
            }
        }

        private static string ClassOf(IntPtr h)
        {
            StringBuilder sb = new StringBuilder(256);
            GetClassName(h, sb, sb.Capacity);
            return sb.ToString();
        }

        private static string TitleOf(IntPtr h)
        {
            StringBuilder sb = new StringBuilder(512);
            GetWindowText(h, sb, sb.Capacity);
            return sb.ToString();
        }

        public static WinInfo[] List(uint pid)
        {
            List<WinInfo> found = new List<WinInfo>();
            EnumWindows(delegate(IntPtr h, IntPtr l)
            {
                uint owner;
                GetWindowThreadProcessId(h, out owner);
                if (owner != pid) return true;
                WinInfo w = new WinInfo();
                w.Handle = h;
                w.Class = ClassOf(h);
                w.Title = TitleOf(h);
                w.Visible = IsWindowVisible(h);
                w.Owned = GetWindow(h, GW_OWNER) != IntPtr.Zero;
                found.Add(w);
                return true;
            }, IntPtr.Zero);
            return found.ToArray();
        }

        // The application's on-screen window: visible, top-level, captioned,
        // and not the tray icon's own (invisible, uncaptioned) message window.
        public static WinInfo FindMain(uint pid)
        {
            WinInfo[] all = List(pid);
            for (int i = 0; i < all.Length; i++)
            {
                WinInfo w = all[i];
                if (!w.Visible) continue;
                if (w.Owned) continue;
                if (w.Class == TrayClass) continue;
                if (w.Title.Length == 0) continue;
                return w;
            }
            return null;
        }

        // Returns "ok", or a description of why the post was refused. UIPI shows up
        // here as win32 error 5 (ERROR_ACCESS_DENIED) when this script is not elevated.
        public static string Close(IntPtr hWnd)
        {
            if (PostMessage(hWnd, WM_CLOSE, IntPtr.Zero, IntPtr.Zero)) return "ok";
            return "refused (win32 error " + Marshal.GetLastWin32Error() + ")";
        }
    }
}
'@
}

# ---------------------------------------------------------------------------
# 0. Elevation, and optional window dump.
# ---------------------------------------------------------------------------
$isElevated = $false
try {
    $isElevated = ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent())
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { }

if ($Diagnose) {
    Write-Log ("DIAGNOSE  elevated={0}  pid={1}" -f $isElevated, $PID)
    $procs = @(Get-Process -Name $procName -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) {
        Write-Log 'DIAGNOSE  no running instance'
        exit 0
    }
    foreach ($proc in $procs) {
        Write-Log ("DIAGNOSE  windows of pid {0}:" -f $proc.Id)
        foreach ($w in [ClevoFanControl.Startup]::List([uint32] $proc.Id)) {
            Write-Log ('    ' + $w.Describe())
        }
    }
    exit 0
}

if (-not $isElevated -and -not $DryRun) {
    Write-Log 'ERROR  not elevated - UIPI will drop WM_CLOSE. Run this from an elevated shell.'
    exit 6
}

# ---------------------------------------------------------------------------
# 1. Start the app, unless it is already running.
#    A second launch would only pop the single-instance error dialog and exit.
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $Exe)) {
    Write-Log "ERROR  exe not found: $Exe"
    exit 2
}

$running = @(Get-Process -Name $procName -ErrorAction SilentlyContinue)
$started = $false

if ($running.Count -gt 0) {
    Write-Log "already running: pid $($running[0].Id) - not starting a second instance"
} elseif ($DryRun) {
    Write-Log 'DRYRUN  no running instance, nothing to inspect'
    exit 0
} else {
    # Deliberately NOT using -WindowStyle Hidden: whether FLTK honours nCmdShow is
    # unverified, and if it latched the initial state it could make the window
    # impossible to restore from the tray. The verified path is "let it appear,
    # then close it" - a sub-second flash, then the window is in the tray.
    Start-Process -FilePath $Exe
    $started = $true
    Write-Log "started: $Exe"
}

# ---------------------------------------------------------------------------
# 2. Wait for the main window.
#    Only worth waiting when this script started the app - an instance that was
#    already running in the tray has no window to wait for.
# ---------------------------------------------------------------------------
$targetPid = 0
$candidate = $null
$deadline  = (Get-Date).AddSeconds($TimeoutSec)

while ($true) {
    $running = @(Get-Process -Name $procName -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) {
        $targetPid = [uint32] $running[0].Id
        $candidate = [ClevoFanControl.Startup]::FindMain($targetPid)
        if ($null -ne $candidate) { break }
    }
    if (-not $started) { break }
    if ((Get-Date) -ge $deadline) { break }
    Start-Sleep -Milliseconds 100
}

if ($null -eq $candidate) {
    $alive = @(Get-Process -Name $procName -ErrorAction SilentlyContinue).Count -gt 0
    if (-not $alive) {
        Write-Log 'ERROR  no process - the app exited during startup'
        exit 3
    }
    if ($started) {
        # We launched it ourselves, so a window was expected. Nothing was sent.
        Write-Log ("WARNING  no window within {0}s of starting - nothing was sent." -f $TimeoutSec)
        Write-Log '         The app is running but its window never showed up.'
        exit 8
    }
    Write-Log 'OK  instance is already in the tray, no on-screen window - nothing to do'
    exit 0
}

Write-Log ('found  ' + $candidate.Describe())

if ($DryRun) {
    Write-Log 'DRYRUN  nothing sent'
    exit 0
}

Start-Sleep -Milliseconds $SettleMs

# Re-resolve the handle: the window is recreated if the app re-runs its startup path.
$candidate = [ClevoFanControl.Startup]::FindMain($targetPid)
if ($null -eq $candidate) {
    Write-Log 'OK  window disappeared on its own before WM_CLOSE'
    exit 0
}

$posted = [ClevoFanControl.Startup]::Close($candidate.Handle)
Write-Log ('WM_CLOSE -> {0}  (hwnd=0x{1:X})' -f $posted, $candidate.Handle.ToInt64())
if ($posted -ne 'ok') {
    Write-Log 'ERROR  message not posted; the window was left alone.'
    exit 7
}

# ---------------------------------------------------------------------------
# 3. Verify it hid to the tray rather than exiting.
# ---------------------------------------------------------------------------
Start-Sleep -Milliseconds 1500

$running = @(Get-Process -Name $procName -ErrorAction SilentlyContinue)
if ($running.Count -eq 0) {
    Write-Log 'WARNING  process exited: it took the exit path, not hide-to-tray.'
    Write-Log '         Check that closeToTray is true in ClevoFanControl.x64.json.'
    Write-Log '         (On exit the worker restores firmware control, so the fans are not stuck.)'
    exit 4
}

$still = [ClevoFanControl.Startup]::FindMain([uint32] $running[0].Id)
if ($null -ne $still) {
    Write-Log ('WARNING  window still on screen: ' + $still.Describe())
    exit 5
}

Write-Log 'OK  window hidden, process still running (tray icon active)'
exit 0
