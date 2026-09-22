#Requires -Version 5.1
<#
  PULSE | Gaming Tweak - GUI Edition v1.1 (WPF)
  Brand : KFLI // The Digital Shadow
  ------------------------------------------------------------
  What changed vs v1.0:
   - No more freezing: every tweak, the live stats and the system info run in
     background runspaces. The window stays responsive at all times.
   - Window shows immediately (restore point is created in the background).
   - Live stats use CIM (works on any Windows language, not only English).
   - Fixed the HAGS tweak (it was writing to the wrong registry key).
   - "Restore Changes" now really restores the ORIGINAL values (backup JSON),
     instead of forcing a High Performance plan.
   - Every step reports its own success / error in the log (no fake "OK").

  Safety notes:
   - Must run as Administrator (relaunches itself elevated, no console window).
   - Tries to create a System Restore Point on startup.
   - Never touches Windows Defender, Windows Firewall, or Windows Update.
   - Log     : PULSE-Tweak-Log.txt   (next to this script)
   - Backup  : PULSE-Backup.json     (original values, used by Restore)
   - Optional: put logo.png next to this script to use your own logo image.
#>

$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# ---------------------------------------------------------------------------
# 0. Setup: elevation, paths
# ---------------------------------------------------------------------------

function Show-Fatal {
    param([string]$Text)
    [void][System.Windows.MessageBox]::Show($Text, 'PULSE', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
}

$ScriptPath = $PSCommandPath
if ([string]::IsNullOrWhiteSpace($ScriptPath)) { $ScriptPath = $MyInvocation.MyCommand.Path }
if ([string]::IsNullOrWhiteSpace($ScriptPath)) {
    Show-Fatal 'Save this file to disk and run it directly.'
    exit 1
}
$ScriptRoot = Split-Path -Parent $ScriptPath

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Always run under native 64-bit Windows PowerShell 5.1 (correct registry view)
$sysDir = 'System32'
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { $sysDir = 'sysnative' }
$psExe = Join-Path $env:windir ($sysDir + '\WindowsPowerShell\v1.0\powershell.exe')
$isNativePS51 = ($PSVersionTable.PSEdition -eq 'Desktop') -and ($sysDir -eq 'System32')

if ((-not (Test-Admin)) -or (-not $isNativePS51)) {
    try { Unblock-File -Path $ScriptPath -ErrorAction SilentlyContinue } catch {}
    try {
        $relaunchArgs = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $ScriptPath + '"'))
        $sp = @{ FilePath = $psExe; ArgumentList = $relaunchArgs; WindowStyle = 'Hidden' }
        if (-not (Test-Admin)) { $sp.Verb = 'RunAs' }
        Start-Process @sp
    } catch {
        Show-Fatal ('PULSE needs Administrator rights to apply tweaks.' + "`n`n" + $_.Exception.Message)
    }
    exit
}

# Where to keep the log + backup (next to the script, or LocalAppData if read-only)
$DataDir = $ScriptRoot
try {
    $probe = Join-Path $DataDir '.pulse_write_test'
    Set-Content -LiteralPath $probe -Value '1' -ErrorAction Stop
    Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
} catch {
    $DataDir = Join-Path $env:LOCALAPPDATA 'PULSE'
    try { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null } catch {}
}
$LogFile    = Join-Path $DataDir 'PULSE-Tweak-Log.txt'
$BackupFile = Join-Path $DataDir 'PULSE-Backup.json'

# ---------------------------------------------------------------------------
# 1. Shared state
# ---------------------------------------------------------------------------

$BuildVersion = '1.4'
$LogQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
$Shared = [hashtable]::Synchronized(@{
    Cpu = $null; Ram = $null; Gpu = $null
    VramUsed = $null; VramTotal = [double]0
    Info = $null; Stop = $false; Rp = 'PENDING'
})
$script:Busy       = $false
$script:BusySince  = $null
$script:Task       = $null
$script:RpTask     = $null
$script:Syncing    = $false
$script:InfoSig    = $null
$script:Started    = $false
$script:Tick       = 0
$script:RpShown    = ''
$script:ToggleGame = $null
$script:ToggleSvc  = $null
$script:BrushCache = @{}

function Write-Log {
    param([string]$Message, [string]$Type = 'INFO')
    [void]$LogQueue.Enqueue([pscustomobject]@{ Time = (Get-Date -Format 'HH:mm:ss'); Type = $Type; Msg = $Message })
}

# ---------------------------------------------------------------------------
# 2. Worker library (runs inside background runspaces - never on the UI thread)
# ---------------------------------------------------------------------------

$WorkerLib = @'
function Write-Log {
    param([string]$Message, [string]$Type = 'INFO')
    [void]$LogQueue.Enqueue([pscustomobject]@{ Time = (Get-Date -Format 'HH:mm:ss'); Type = $Type; Msg = $Message })
}

function Invoke-Step {
    param([string]$Name, [scriptblock]$Body)
    try { & $Body }
    catch {
        $global:PulseErrors = [int]$global:PulseErrors + 1
        Write-Log ("{0} failed: {1}" -f $Name, $_.Exception.Message) 'ERR'
    }
}

function Write-Done {
    param([string]$Title)
    if ([int]$global:PulseErrors -gt 0) {
        Write-Log ("{0} finished with {1} error(s) - see messages above" -f $Title, $global:PulseErrors) 'WARN'
    } else {
        Write-Log ("{0} completed" -f $Title) 'OK'
    }
}

function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments)
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = ''
    try { $out = (& $Exe @Arguments 2>&1 | Out-String) } catch { $out = '' }
    $code = $LASTEXITCODE
    $ErrorActionPreference = $old
    return [pscustomobject]@{ Code = $code; Out = $out }
}

# ---- Backup of original values (used by Restore) ----------------------------

function Read-Backup {
    $b = @{ PowerScheme = $null; Reg = @() }
    if (Test-Path -LiteralPath $BackupFile) {
        try {
            $j = Get-Content -LiteralPath $BackupFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.PowerScheme) { $b.PowerScheme = [string]$j.PowerScheme }
            $b.Reg = @($j.Reg | Where-Object { $_ })
        } catch { }
    }
    return $b
}

function Write-Backup {
    param($B)
    $obj = [pscustomobject]@{ PowerScheme = $B.PowerScheme; Reg = @($B.Reg) }
    $obj | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $BackupFile -Encoding UTF8
}

function Backup-RegValue {
    param([string]$Path, [string]$Name)
    $b = Read-Backup
    foreach ($e in @($b.Reg)) {
        if ($e.Path -eq $Path -and $e.Name -eq $Name) { return }
    }
    $existed = $false; $val = $null; $kind = $null
    $key = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($key -and ($key.GetValueNames() -contains $Name)) {
        $existed = $true
        $kind = $key.GetValueKind($Name).ToString()
        $val  = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    }
    $entry = [pscustomobject]@{ Path = $Path; Name = $Name; Existed = $existed; Kind = $kind; Value = $val }
    $b.Reg = @($b.Reg) + $entry
    Write-Backup $b
}

function Set-Reg {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
    Backup-RegValue -Path $Path -Name $Name
    Set-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -Type $Type
}

function Restore-RegistryFromBackup {
    $b = Read-Backup
    $n = 0
    foreach ($e in @($b.Reg)) {
        try {
            if ($e.Existed) {
                $val = $e.Value
                switch ($e.Kind) {
                    'Binary'      { $val = [byte[]]@($e.Value) }
                    'DWord'       { $val = [int]$e.Value }
                    'QWord'       { $val = [int64]$e.Value }
                    'MultiString' { $val = [string[]]@($e.Value) }
                }
                if (-not (Test-Path -LiteralPath $e.Path)) { New-Item -Path $e.Path -Force | Out-Null }
                Set-ItemProperty -LiteralPath $e.Path -Name $e.Name -Value $val -Type $e.Kind
            } else {
                Remove-ItemProperty -LiteralPath $e.Path -Name $e.Name -ErrorAction SilentlyContinue
            }
            $n++
        } catch {
            $global:PulseErrors = [int]$global:PulseErrors + 1
            Write-Log ("Could not restore {0}: {1}" -f $e.Name, $_.Exception.Message) 'ERR'
        }
    }
    return $n
}

# ---- Power plans -------------------------------------------------------------

function Get-ActiveSchemeGuid {
    $r = Invoke-Native 'powercfg.exe' @('/getactivescheme')
    $m = [regex]::Match($r.Out, '[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}')
    if ($m.Success) { return $m.Value }
    return $null
}

function Save-PowerScheme {
    $b = Read-Backup
    if (-not $b.PowerScheme) {
        $g = Get-ActiveSchemeGuid
        if ($g) { $b.PowerScheme = $g; Write-Backup $b }
    }
}

function Enable-PowerPlan {
    param([string]$Guid)
    $r = Invoke-Native 'powercfg.exe' @('/setactive', $Guid)
    if ($r.Code -eq 0) { return $true }
    [void](Invoke-Native 'powercfg.exe' @('/duplicatescheme', $Guid, $Guid))
    $r = Invoke-Native 'powercfg.exe' @('/setactive', $Guid)
    return ($r.Code -eq 0)
}

function Set-PowerPlanHighPerformance {
    Invoke-Step 'High Performance plan' {
        Save-PowerScheme
        if (Enable-PowerPlan '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c') { Write-Log 'Power plan set to High Performance' 'OK' }
        else { Write-Log 'High Performance plan is not available on this PC' 'WARN' }
    }
}

function Set-PowerPlanUltimate {
    Invoke-Step 'Ultimate Performance plan' {
        Save-PowerScheme
        if (Enable-PowerPlan 'e9a42b02-d5df-448d-aa00-03f14749eb61') { Write-Log 'Power plan set to Ultimate Performance' 'OK' }
        elseif (Enable-PowerPlan '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c') { Write-Log 'Ultimate plan unavailable - High Performance applied instead' 'WARN' }
        else { Write-Log 'Could not change the power plan on this PC' 'WARN' }
    }
}

function Restore-PowerPlan {
    Invoke-Step 'Power plan restore' {
        $b = Read-Backup
        $g = $b.PowerScheme
        if (-not $g) { $g = '381b4222-f694-41f0-9685-ff5bb260df2e' }
        $r = Invoke-Native 'powercfg.exe' @('/setactive', $g)
        if ($r.Code -ne 0) { $r = Invoke-Native 'powercfg.exe' @('/setactive', '381b4222-f694-41f0-9685-ff5bb260df2e') }
        if ($r.Code -eq 0) { Write-Log 'Power plan restored' 'OK' } else { Write-Log 'Could not restore the power plan' 'WARN' }
    }
}

# ---- Registry tweaks ---------------------------------------------------------

function Set-GameModeRegistry {
    Invoke-Step 'Game Mode' {
        $p = 'HKCU:\Software\Microsoft\GameBar'
        Set-Reg $p 'AllowAutoGameMode' 1
        Set-Reg $p 'AutoGameModeEnabled' 1
        Write-Log 'Game Mode enabled' 'OK'
    }
}

function Disable-GameModeRegistry {
    Invoke-Step 'Game Mode' {
        $p = 'HKCU:\Software\Microsoft\GameBar'
        Set-Reg $p 'AllowAutoGameMode' 0
        Set-Reg $p 'AutoGameModeEnabled' 0
        Write-Log 'Game Mode disabled' 'WARN'
    }
}

function Set-GamesTaskPriority {
    Invoke-Step 'Game task priority' {
        $p = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games'
        Set-Reg $p 'GPU Priority' 8
        Set-Reg $p 'Priority' 6
        Set-Reg $p 'Scheduling Category' 'High' 'String'
        Set-Reg $p 'SFIO Priority' 'High' 'String'
        Write-Log 'Game task scheduling priority boosted' 'OK'
    }
}

function Disable-VisualEffectsForPerformance {
    Invoke-Step 'Visual effects' {
        Set-Reg 'HKCU:\Control Panel\Desktop' 'UserPreferencesMask' ([byte[]](0x90,0x12,0x03,0x80,0x10,0x00,0x00,0x00)) 'Binary'
        Set-Reg 'HKCU:\Control Panel\Desktop\WindowMetrics' 'MinAnimate' '0' 'String'
        Write-Log 'Visual effects trimmed (fully applies after sign-out)' 'OK'
    }
}

function Set-WindowsGeneralTweaks {
    Disable-VisualEffectsForPerformance
    Invoke-Step 'Windows suggestions' {
        Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338388Enabled' 0
        Write-Log 'Start menu suggestions disabled' 'OK'
    }
}

function Enable-HAGS {
    Invoke-Step 'GPU scheduling (HAGS)' {
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2
        Write-Log 'Hardware-accelerated GPU scheduling enabled (needs restart and a supported GPU/driver)' 'OK'
    }
}

function Disable-FullscreenOptimizationsPrompt {
    Invoke-Step 'Fullscreen / Game DVR' {
        $p = 'HKCU:\System\GameConfigStore'
        Set-Reg $p 'GameDVR_FSEBehaviorMode' 2
        Set-Reg $p 'GameDVR_DXGIHonorFSEWindowsCompatible' 1
        Set-Reg $p 'GameDVR_Enabled' 0
        Write-Log 'Fullscreen optimizations tuned, Game DVR capture disabled' 'OK'
    }
}

function Disable-Nagle {
    Invoke-Step "Nagle's algorithm" {
        $root = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
        $n = 0
        $adapters = @(Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceGuid })
        foreach ($adapter in $adapters) {
            $path = Join-Path $root ('{' + $adapter.InterfaceGuid.ToString() + '}')
            if (-not (Test-Path -LiteralPath $path)) { continue }
            Set-Reg $path 'TcpAckFrequency' 1
            Set-Reg $path 'TCPNoDelay' 1
            $n++
        }
        if ($n -gt 0) {
            Write-Log ("Latency settings changed on {0} active network interface(s); restart may be required" -f $n) 'WARN'
        } else {
            Write-Log 'No active compatible network interface was changed' 'WARN'
        }
    }
}

# ---- Cleaners ----------------------------------------------------------------

function Invoke-NetworkCleanup {
    Invoke-Step 'DNS flush' {
        $r = Invoke-Native 'ipconfig.exe' @('/flushdns')
        if ($r.Code -eq 0) { Write-Log 'DNS cache flushed' 'OK' } else { Write-Log 'DNS flush returned an error' 'WARN' }
    }
}

function Invoke-TempCleanup {
    Invoke-Step 'Temp cleanup' {
        $freed = [int64]0
        $keep = @($ScriptRoot, $DataDir) | Where-Object { $_ }
        foreach ($p in @($env:TEMP, (Join-Path $env:WINDIR 'Temp'))) {
            if (-not $p) { continue }
            if (-not (Test-Path -LiteralPath $p)) { continue }
            foreach ($item in @(Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue)) {
                $skip = $false
                foreach ($k in $keep) {
                    # Do not remove the script, its data directory, or a parent item that contains either.
                    if ($item.FullName.StartsWith($k, [System.StringComparison]::OrdinalIgnoreCase)) { $skip = $true }
                }
                if ($skip) { continue }
                $before = [int64](Get-ChildItem -LiteralPath $item.FullName -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
                Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
                $after = [int64]0
                if (Test-Path -LiteralPath $item.FullName) {
                    $after = [int64](Get-ChildItem -LiteralPath $item.FullName -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
                }
                $freed += ($before - $after)
            }
        }
        Write-Log ("Temp files cleared (~{0} MB freed; files in use were skipped)" -f [math]::Round($freed / 1MB, 1)) 'OK'
    }
}

function Invoke-RecycleBinEmpty {
    Invoke-Step 'Recycle Bin' {
        Clear-RecycleBin -Force -ErrorAction SilentlyContinue
        Write-Log 'Recycle Bin emptied' 'OK'
    }
}

function Invoke-DriveOptimize {
    Invoke-Step 'Drive optimization' {
        $sysDrive = ($env:SystemDrive).TrimEnd('\')
        $vol = Get-Volume -DriveLetter $sysDrive.TrimEnd(':') -ErrorAction SilentlyContinue
        $isSSD = $true
        try {
            $part = Get-Partition -DriveLetter $sysDrive.TrimEnd(':') -ErrorAction Stop
            $disk = Get-PhysicalDisk -ErrorAction Stop | Where-Object { $_.DeviceId -eq $part.DiskNumber }
            if ($disk -and $disk.MediaType -eq 'HDD') { $isSSD = $false }
        } catch { }
        if ($isSSD) {
            $r = Invoke-Native 'defrag.exe' @($sysDrive, '/L', '/V')
            if ($r.Code -eq 0) { Write-Log ('SSD TRIM run on ' + $sysDrive) 'OK' }
            else { Write-Log 'TRIM finished with warnings (see log via defrag if needed)' 'WARN' }
        } else {
            $r = Invoke-Native 'defrag.exe' @($sysDrive, '/O', '/V')
            if ($r.Code -eq 0) { Write-Log ('HDD optimized (defragmented) on ' + $sysDrive) 'OK' }
            else { Write-Log 'Drive optimization finished with warnings' 'WARN' }
        }
    }
}

# ---- Services ----------------------------------------------------------------

$SafeToggleServices = @(
    @{ Name = 'SysMain';   Label = 'SysMain (Superfetch)';    Default = 'Automatic' },
    @{ Name = 'DiagTrack'; Label = 'Telemetry service';       Default = 'Automatic' },
    @{ Name = 'WSearch';   Label = 'Windows Search indexing'; Default = 'Automatic' },
    @{ Name = 'Fax';       Label = 'Fax service';             Default = 'Manual' },
    @{ Name = 'WerSvc';    Label = 'Windows Error Reporting'; Default = 'Manual' }
)

function Disable-NonCriticalServices {
    foreach ($s in $SafeToggleServices) {
        try {
            $svc = Get-Service -Name $s.Name -ErrorAction SilentlyContinue
            if (-not $svc) { Write-Log ("{0} not present on this PC - skipped" -f $s.Label) 'INFO'; continue }
            $sp = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $s.Name
            Backup-RegValue $sp 'Start'
            Backup-RegValue $sp 'DelayedAutostart'
            Stop-Service -Name $s.Name -Force -ErrorAction SilentlyContinue
            Set-Service -Name $s.Name -StartupType Disabled
            Write-Log ("{0} disabled" -f $s.Label) 'WARN'
        } catch {
            $global:PulseErrors = [int]$global:PulseErrors + 1
            Write-Log ("{0}: {1}" -f $s.Label, $_.Exception.Message) 'ERR'
        }
    }
}

function Disable-OneService {
    param([string]$Name, [string]$Label)
    Invoke-Step $Label {
        $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if (-not $svc) { Write-Log ("{0} not present on this PC - skipped" -f $Label) 'INFO'; return }
        $sp = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $Name
        Backup-RegValue $sp 'Start'
        Backup-RegValue $sp 'DelayedAutostart'
        Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
        Set-Service -Name $Name -StartupType Disabled
        Write-Log ("{0} disabled" -f $Label) 'WARN'
    }
}

function Enable-OneService {
    param([string]$Name, [string]$Label, [string]$Default = 'Automatic')
    Invoke-Step $Label {
        $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if (-not $svc) { Write-Log ("{0} not present on this PC - skipped" -f $Label) 'INFO'; return }
        $b = Read-Backup
        $sp = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $Name
        $mode = $null
        $delayed = $null
        foreach ($e in @($b.Reg)) {
            if ($e.Path -eq $sp -and $e.Existed) {
                if ($e.Name -eq 'Start') {
                    switch ([int]$e.Value) {
                        2 { $mode = 'Automatic' }
                        3 { $mode = 'Manual' }
                        4 { $mode = 'Disabled' }
                    }
                }
                if ($e.Name -eq 'DelayedAutostart') { $delayed = [int]$e.Value }
            }
        }
        if (-not $mode) { $mode = $Default }
        Set-Service -Name $Name -StartupType $mode
        if ($null -ne $delayed) { Set-ItemProperty -LiteralPath $sp -Name 'DelayedAutostart' -Value $delayed -Type DWord }
        if ($mode -eq 'Automatic') { Start-Service -Name $Name -ErrorAction SilentlyContinue }
        Write-Log ("{0} restored ({1})" -f $Label, $mode) 'OK'
    }
}

function Enable-NonCriticalServices {
    $b = Read-Backup
    foreach ($s in $SafeToggleServices) {
        try {
            $svc = Get-Service -Name $s.Name -ErrorAction SilentlyContinue
            if (-not $svc) { continue }
            $sp = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $s.Name
            $mode = $null
            $delayed = $null
            foreach ($e in @($b.Reg)) {
                if ($e.Path -eq $sp -and $e.Existed) {
                    if ($e.Name -eq 'Start') {
                        switch ([int]$e.Value) {
                            2 { $mode = 'Automatic' }
                            3 { $mode = 'Manual' }
                            4 { $mode = 'Disabled' }
                        }
                    }
                    if ($e.Name -eq 'DelayedAutostart') { $delayed = [int]$e.Value }
                }
            }
            if (-not $mode) {
                if ($svc.StartType -eq 'Disabled') { $mode = $s.Default } else { continue }
            }
            Set-Service -Name $s.Name -StartupType $mode
            if ($null -ne $delayed) { Set-ItemProperty -LiteralPath $sp -Name 'DelayedAutostart' -Value $delayed -Type DWord }
            if ($mode -eq 'Automatic') { Start-Service -Name $s.Name -ErrorAction SilentlyContinue }
            Write-Log ("{0} restored ({1})" -f $s.Label, $mode) 'OK'
        } catch {
            $global:PulseErrors = [int]$global:PulseErrors + 1
            Write-Log ("{0}: {1}" -f $s.Label, $_.Exception.Message) 'ERR'
        }
    }
}

# ---- Restore everything ------------------------------------------------------

function Restore-AllChanges {
    Invoke-Step 'Restore' {
        $b = Read-Backup
        $hadBackup = ((@($b.Reg)).Count -gt 0) -or [bool]$b.PowerScheme
        Enable-NonCriticalServices
        $n = Restore-RegistryFromBackup
        Restore-PowerPlan
        if ($global:PulseErrors -eq 0) {
            if (Test-Path -LiteralPath $BackupFile) { Remove-Item -LiteralPath $BackupFile -Force -ErrorAction Stop }
            if ($hadBackup) { Write-Log ("Restored {0} saved value(s) to their original state" -f $n) 'OK' }
            else { Write-Log 'No saved originals found - services and power plan reset to Windows defaults' 'WARN' }
        } else {
            Write-Log 'Restore was incomplete. The backup was kept so you can retry after fixing the reported errors.' 'WARN'
        }
        Write-Log 'Visual effects and GPU scheduling need a sign-out / restart to fully revert' 'INFO'
    }
}

# ---- Restore point -----------------------------------------------------------

function New-SafetyRestorePoint {
    try {
        Enable-ComputerRestore -Drive ($env:SystemDrive + '\') -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description 'PULSE Gaming Tweak - before changes' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop -WarningVariable cpWarn -WarningAction SilentlyContinue
        if ($cpWarn) {
            Write-Log 'Restore point not created: Windows allows one per 24h (a recent one already exists)' 'WARN'
            $Shared.Rp = 'RECENT EXISTS'
        } else {
            Write-Log 'Restore point created. Roll back any time via System Restore.' 'OK'
            $Shared.Rp = 'CREATED'
        }
    } catch {
        Write-Log ('Restore point skipped: ' + $_.Exception.Message) 'WARN'
        $Shared.Rp = 'SKIPPED'
    }
}
'@

# System info gathering - reusable on its own (Refresh button) and as part of the stats loop
$InfoScript = @'
$ErrorActionPreference = 'SilentlyContinue'

function Nz { param($x) if ($x) { return ("$x").Trim() } return 'N/A' }

function Update-SystemInfo {
    try {
        $os   = Get-CimInstance Win32_OperatingSystem
        $cpu  = Get-CimInstance Win32_Processor | Select-Object -First 1
        $mb   = Get-CimInstance Win32_BaseBoard | Select-Object -First 1

        # GPU: prefer real adapters, but never end up blank - fall back to
        # whatever Windows reports (even a "Basic"/virtual one) rather than N/A.
        $allGpus = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Name })
        $gpus = @($allGpus | Where-Object { $_.Name -notmatch 'Microsoft Basic Render|Microsoft Basic Display|Remote Desktop|Citrix' })
        if ($gpus.Count -eq 0) { $gpus = $allGpus }
        $gpuName = 'N/A'
        if ($gpus.Count -gt 0) {
            $gpuName = (($gpus | ForEach-Object {
                $drv = ''
                if ($_.DriverVersion) { $drv = (' (driver ' + $_.DriverVersion + ')') }
                ("$($_.Name)").Trim() + $drv
            }) -join "`n")
        }

        $ramGB = 'N/A'
        if ($os) { $ramGB = ('{0} GB' -f [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)) }

        $Shared.Info = @(
            [pscustomobject]@{ K = 'OS';          V = (Nz $os.Caption) },
            [pscustomobject]@{ K = 'CPU';         V = (Nz $cpu.Name) },
            [pscustomobject]@{ K = 'GPU';         V = $gpuName },
            [pscustomobject]@{ K = 'RAM';         V = $ramGB },
            [pscustomobject]@{ K = 'Motherboard'; V = ((Nz $mb.Manufacturer) + ' ' + (Nz $mb.Product)) },
            [pscustomobject]@{ K = 'User';        V = $env:USERNAME },
            [pscustomobject]@{ K = 'Updated';     V = (Get-Date -Format 'HH:mm:ss') }
        )
    } catch {
        $Shared.Info = @([pscustomobject]@{ K = 'Info'; V = 'Unavailable' })
    }

    $vramTotal = [double]0
    try {
        $classKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
        foreach ($k in @(Get-ChildItem -LiteralPath $classKey -ErrorAction Stop)) {
            try {
                $v = (Get-ItemProperty -LiteralPath $k.PSPath -Name 'HardwareInformation.qwMemorySize' -ErrorAction Stop).'HardwareInformation.qwMemorySize'
                $d = [double]$v
                if ($d -gt $vramTotal) { $vramTotal = $d }
            } catch { }
        }
    } catch { }
    $Shared.VramTotal = $vramTotal
}

Update-SystemInfo
'@

# Live stats (own long-running runspace; collects info once immediately, then
# re-collects it periodically so System Info stays live, alongside CPU/RAM/GPU%)
$StatsScript = $InfoScript + @'

$infoTick = 0
while (-not $Shared.Stop) {
    try {
        $p = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop
        if ($p) { $Shared.Cpu = [double]$p.PercentProcessorTime } else { $Shared.Cpu = $null }
    } catch { $Shared.Cpu = $null }

    try {
        $o = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $Shared.Ram = 100 - (([double]$o.FreePhysicalMemory / [double]$o.TotalVisibleMemorySize) * 100)
    } catch { $Shared.Ram = $null }

    try {
        $eng = @(Get-CimInstance -ClassName Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine -ErrorAction Stop)
        $groups = @{}
        foreach ($g in $eng) {
            if ($g.Name -match 'luid_(0x[0-9A-Fa-f]+_0x[0-9A-Fa-f]+).*engtype_(.+)$') {
                $key = $Matches[1] + '|' + $Matches[2]
                $groups[$key] = [double]$groups[$key] + [double]$g.UtilizationPercentage
            }
        }
        if ($groups.Count -gt 0) {
            $mx = ($groups.Values | Measure-Object -Maximum).Maximum
            $Shared.Gpu = [math]::Min(100, [double]$mx)
        } else { $Shared.Gpu = [double]0 }
    } catch { $Shared.Gpu = $null }

    try {
        $mem = @(Get-CimInstance -ClassName Win32_PerfFormattedData_GPUPerformanceCounters_GPUAdapterMemory -ErrorAction Stop)
        $mv = ($mem | Measure-Object -Property DedicatedUsage -Maximum).Maximum
        if ($null -ne $mv) { $Shared.VramUsed = [double]$mv } else { $Shared.VramUsed = $null }
    } catch { $Shared.VramUsed = $null }

    $infoTick++
    if ($infoTick -ge 10) {   # ~ every 20 seconds, keeps OS/CPU/GPU/RAM/board text live too
        $infoTick = 0
        Update-SystemInfo
    }

    for ($i = 0; $i -lt 20; $i++) {
        if ($Shared.Stop) { break }
        Start-Sleep -Milliseconds 100
    }
}
'@

# ---------------------------------------------------------------------------
# 3. XAML - window layout, theme, KFLI branding
# ---------------------------------------------------------------------------

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="PULSE | Gaming Tweak  -  KFLI // The Digital Shadow"
        Height="800" Width="1200" MinHeight="700" MinWidth="1000"
        Background="#08090B" FontFamily="Segoe UI" WindowStartupLocation="CenterScreen"
        UseLayoutRounding="True" SnapsToDevicePixels="True"
        TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <SolidColorBrush x:Key="Panel" Color="#101214"/>
    <SolidColorBrush x:Key="Panel2" Color="#0D0F11"/>
    <SolidColorBrush x:Key="Line" Color="#23262B"/>
    <SolidColorBrush x:Key="Red" Color="#FF2440"/>
    <SolidColorBrush x:Key="RedDim" Color="#7A1220"/>
    <SolidColorBrush x:Key="Cyan" Color="#35D1C9"/>
    <SolidColorBrush x:Key="TextMain" Color="#E9EDF1"/>
    <SolidColorBrush x:Key="TextDim" Color="#8A9099"/>
    <SolidColorBrush x:Key="TextFaint" Color="#52585F"/>
    <SolidColorBrush x:Key="Green" Color="#33D17A"/>
    <SolidColorBrush x:Key="Amber" Color="#FFB020"/>

    <DropShadowEffect x:Key="RedGlow" Color="#FF2440" BlurRadius="18" ShadowDepth="0" Opacity="0.55"/>
    <DropShadowEffect x:Key="CardGlow" Color="#FF2440" BlurRadius="12" ShadowDepth="0" Opacity="0.35"/>

    <DrawingBrush x:Key="GridBrush" TileMode="Tile" Viewport="0,0,24,24" ViewportUnits="Absolute" Viewbox="0,0,24,24" ViewboxUnits="Absolute">
      <DrawingBrush.Drawing>
        <GeometryDrawing>
          <GeometryDrawing.Pen>
            <Pen Brush="#12FFFFFF" Thickness="1"/>
          </GeometryDrawing.Pen>
          <GeometryDrawing.Geometry>
            <GeometryGroup>
              <LineGeometry StartPoint="0,0.5" EndPoint="24,0.5"/>
              <LineGeometry StartPoint="0.5,0" EndPoint="0.5,24"/>
            </GeometryGroup>
          </GeometryDrawing.Geometry>
        </GeometryDrawing>
      </DrawingBrush.Drawing>
    </DrawingBrush>

    <Style TargetType="Border" x:Key="PanelBorder">
      <Setter Property="Background" Value="{StaticResource Panel}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
    </Style>

    <Style TargetType="TextBlock" x:Key="HeadText">
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Foreground" Value="{StaticResource TextMain}"/>
    </Style>

    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="8"/>
      <Setter Property="MinWidth" Value="8"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="#0C0D0F">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageUpCommand" Opacity="0" Focusable="False" IsTabStop="False"/>
                </Track.DecreaseRepeatButton>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageDownCommand" Opacity="0" Focusable="False" IsTabStop="False"/>
                </Track.IncreaseRepeatButton>
                <Track.Thumb>
                  <Thumb>
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Border Background="#5A1A26" CornerRadius="3" Margin="1,0,1,0"/>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ListBoxItem">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <ContentPresenter Margin="0,1,0,1"/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ProgressBar" x:Key="SlimBar">
      <Setter Property="Height" Value="3"/>
      <Setter Property="Minimum" Value="0"/>
      <Setter Property="Maximum" Value="100"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Background" Value="#1C1F23"/>
      <Setter Property="Foreground" Value="{StaticResource Red}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Grid>
              <Border x:Name="PART_Track" Background="{TemplateBinding Background}"/>
              <Border x:Name="PART_Indicator" HorizontalAlignment="Left" Background="{TemplateBinding Foreground}"/>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="Button" x:Key="TweakCard">
      <Setter Property="Background" Value="{StaticResource Panel2}"/>
      <Setter Property="Foreground" Value="{StaticResource TextMain}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="14"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="VerticalContentAlignment" Value="Top"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" x:Name="bd">
              <ContentPresenter Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="{StaticResource Red}"/>
                <Setter TargetName="bd" Property="Background" Value="#151013"/>
                <Setter TargetName="bd" Property="Effect" Value="{StaticResource CardGlow}"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#22101A"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="Button" x:Key="ActionBtn">
      <Setter Property="Background" Value="{StaticResource Panel2}"/>
      <Setter Property="Foreground" Value="{StaticResource TextMain}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" x:Name="bd">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="{StaticResource Red}"/>
                <Setter TargetName="bd" Property="Effect" Value="{StaticResource CardGlow}"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#2A1218"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="Button" x:Key="FlatBtn">
      <Setter Property="Background" Value="#16181B"/>
      <Setter Property="Foreground" Value="{StaticResource TextDim}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="8,4,8,4"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" x:Name="bd">
              <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="#35D1C9"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="CheckBox" x:Key="ToggleSwitch">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Border x:Name="track" Width="38" Height="20" CornerRadius="10" Background="#26292D" BorderBrush="{StaticResource Line}" BorderThickness="1">
              <Border x:Name="knob" Width="14" Height="14" CornerRadius="7" Background="#7D838A" HorizontalAlignment="Left" Margin="2,0,0,0"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="track" Property="Background" Value="#1E3B2C"/>
                <Setter TargetName="track" Property="BorderBrush" Value="{StaticResource Green}"/>
                <Setter TargetName="knob" Property="Background" Value="{StaticResource Green}"/>
                <Setter TargetName="knob" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="knob" Property="Margin" Value="0,0,2,0"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- ============ Title bar ============ -->
    <Border Grid.Row="0" Background="#0C0D0F" BorderBrush="{StaticResource Line}" BorderThickness="0,0,0,1" Padding="14,7,14,7">
      <DockPanel>
        <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
          <Button x:Name="btnDownloads" Content="TOOLS" Style="{StaticResource FlatBtn}" Width="58" Height="22" Margin="0,0,12,0" ToolTip="Open recommended official tools"/>
          <TextBlock x:Name="lblClock" Text="00:00:00" Foreground="{StaticResource TextDim}" FontFamily="Consolas" FontSize="11" VerticalAlignment="Center"/>
          <Rectangle Width="1" Height="14" Fill="{StaticResource Line}" Margin="12,0,12,0"/>
          <TextBlock Text="KFLI" Foreground="{StaticResource Red}" FontFamily="Consolas" FontWeight="Bold" FontSize="11" VerticalAlignment="Center"/>
          <TextBlock Text=" // THE DIGITAL SHADOW" Foreground="{StaticResource Cyan}" FontFamily="Consolas" FontSize="11" VerticalAlignment="Center"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <Grid Width="30" Height="30" Margin="0,0,10,0">
            <Viewbox x:Name="vecLogoSmall" Stretch="Uniform">
              <Canvas Width="56" Height="56">
                <Path Data="M24,2 L44,13.5 L44,36.5 L24,48 L4,36.5 L4,13.5 Z" Fill="#7A1220" Opacity="0.6">
                  <Path.RenderTransform><TranslateTransform X="5" Y="4"/></Path.RenderTransform>
                </Path>
                <Path Data="M24,2 L44,13.5 L44,36.5 L24,48 L4,36.5 L4,13.5 Z" Fill="#0C0D0F" Stroke="#FF2440" StrokeThickness="2" StrokeLineJoin="Round"/>
                <Path Data="M20,14 L20,42 M20,28 L36,14 M20,28 L36,42" Stroke="#35D1C9" StrokeThickness="4" Opacity="0.8" StrokeLineJoin="Round" StrokeStartLineCap="Round" StrokeEndLineCap="Round" Canvas.Left="-1.5"/>
                <Path Data="M20,14 L20,42 M20,28 L36,14 M20,28 L36,42" Stroke="#FF2440" StrokeThickness="4" Opacity="0.8" StrokeLineJoin="Round" StrokeStartLineCap="Round" StrokeEndLineCap="Round" Canvas.Left="1.5"/>
                <Path Data="M20,14 L20,42 M20,28 L36,14 M20,28 L36,42" Stroke="#F3F5F7" StrokeThickness="4" StrokeLineJoin="Round" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                <Rectangle Canvas.Left="48" Canvas.Top="40" Width="3" Height="3" Fill="#FF2440"/>
                <Rectangle Canvas.Left="51" Canvas.Top="35" Width="3" Height="3" Fill="#FF2440" Opacity="0.6"/>
                <Rectangle Canvas.Left="51" Canvas.Top="46" Width="3" Height="3" Fill="#FF2440" Opacity="0.35"/>
              </Canvas>
            </Viewbox>
            <Image x:Name="imgLogoSmall" Stretch="Uniform" Visibility="Collapsed"/>
          </Grid>
          <TextBlock Text="PULSE Gaming Tweak" Foreground="{StaticResource TextMain}" FontWeight="Bold" FontSize="13" VerticalAlignment="Center"/>
          <TextBlock x:Name="lblVersion" Text="  |  GUI Edition" Foreground="{StaticResource TextDim}" FontSize="11" VerticalAlignment="Center" Margin="6,0,0,0"/>
          <Ellipse x:Name="dotState" Width="8" Height="8" Fill="{StaticResource Amber}" Margin="24,0,6,0" VerticalAlignment="Center"/>
          <TextBlock x:Name="lblState" Text="INITIALIZING" Foreground="{StaticResource TextDim}" FontFamily="Consolas" FontSize="10.5" VerticalAlignment="Center"/>
        </StackPanel>
      </DockPanel>
    </Border>

    <!-- ============ Hero ============ -->
    <Border Grid.Row="1" Padding="20,12,20,12" BorderBrush="{StaticResource Line}" BorderThickness="0,0,0,1" Background="{StaticResource GridBrush}">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="330"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="330"/>
        </Grid.ColumnDefinitions>

        <!-- Brand block: KFLI / The Digital Shadow -->
        <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center" HorizontalAlignment="Left">
          <Grid Width="64" Height="64" Margin="0,0,14,0">
            <Viewbox x:Name="vecLogo" Stretch="Uniform">
              <Canvas Width="56" Height="56">
                <Path Data="M24,2 L44,13.5 L44,36.5 L24,48 L4,36.5 L4,13.5 Z" Fill="#7A1220" Opacity="0.6">
                  <Path.RenderTransform><TranslateTransform X="5" Y="4"/></Path.RenderTransform>
                </Path>
                <Path Data="M24,2 L44,13.5 L44,36.5 L24,48 L4,36.5 L4,13.5 Z" Fill="#0C0D0F" Stroke="#FF2440" StrokeThickness="2" StrokeLineJoin="Round"/>
                <Path Data="M20,14 L20,42 M20,28 L36,14 M20,28 L36,42" Stroke="#35D1C9" StrokeThickness="4" Opacity="0.8" StrokeLineJoin="Round" StrokeStartLineCap="Round" StrokeEndLineCap="Round" Canvas.Left="-1.5"/>
                <Path Data="M20,14 L20,42 M20,28 L36,14 M20,28 L36,42" Stroke="#FF2440" StrokeThickness="4" Opacity="0.8" StrokeLineJoin="Round" StrokeStartLineCap="Round" StrokeEndLineCap="Round" Canvas.Left="1.5"/>
                <Path Data="M20,14 L20,42 M20,28 L36,14 M20,28 L36,42" Stroke="#F3F5F7" StrokeThickness="4" StrokeLineJoin="Round" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                <Rectangle Canvas.Left="48" Canvas.Top="40" Width="3" Height="3" Fill="#FF2440"/>
                <Rectangle Canvas.Left="51" Canvas.Top="35" Width="3" Height="3" Fill="#FF2440" Opacity="0.6"/>
                <Rectangle Canvas.Left="51" Canvas.Top="46" Width="3" Height="3" Fill="#FF2440" Opacity="0.35"/>
              </Canvas>
            </Viewbox>
            <Image x:Name="imgLogo" Stretch="Uniform" Visibility="Collapsed"/>
          </Grid>
          <StackPanel VerticalAlignment="Center">
            <Grid>
              <TextBlock x:Name="glitchCyan" Text="KFLI" FontFamily="Bahnschrift, Segoe UI" FontWeight="Bold" FontSize="32" Foreground="#35D1C9" Opacity="0.75">
                <TextBlock.RenderTransform><TranslateTransform X="-2" Y="0"/></TextBlock.RenderTransform>
              </TextBlock>
              <TextBlock x:Name="glitchRed" Text="KFLI" FontFamily="Bahnschrift, Segoe UI" FontWeight="Bold" FontSize="32" Foreground="#FF2440" Opacity="0.75">
                <TextBlock.RenderTransform><TranslateTransform X="2" Y="0"/></TextBlock.RenderTransform>
              </TextBlock>
              <TextBlock Text="KFLI" FontFamily="Bahnschrift, Segoe UI" FontWeight="Bold" FontSize="32" Foreground="#F3F5F7"/>
            </Grid>
            <TextBlock Text="THE DIGITAL SHADOW" Foreground="{StaticResource Cyan}" FontFamily="Consolas" FontSize="11" Margin="0,2,0,0"/>
            <Rectangle Height="2" Width="120" HorizontalAlignment="Left" Fill="{StaticResource Red}" Margin="0,5,0,0"/>
          </StackPanel>
        </StackPanel>

        <!-- Title -->
        <StackPanel Grid.Column="1" HorizontalAlignment="Center" VerticalAlignment="Center">
          <TextBlock Text="CONTROL  //  OPTIMIZE  //  DOMINATE" Foreground="{StaticResource TextDim}" FontFamily="Consolas" FontSize="11" HorizontalAlignment="Center" Margin="0,0,0,2"/>
          <TextBlock Text="PULSE" Foreground="#F3F5F7" FontFamily="Bahnschrift, Segoe UI" FontSize="46" FontWeight="Bold" HorizontalAlignment="Center" Effect="{StaticResource RedGlow}"/>
          <TextBlock Text="TUNE THE NOISE OUT. KEEP THE FRAMES." Foreground="{StaticResource TextDim}" FontSize="12" HorizontalAlignment="Center" Margin="0,2,0,0"/>
        </StackPanel>

        <!-- Tech readout -->
        <StackPanel Grid.Column="2" HorizontalAlignment="Right" VerticalAlignment="Center">
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
            <TextBlock Text="> BUILD ......... " Foreground="{StaticResource TextFaint}" FontFamily="Consolas" FontSize="10.5"/>
            <TextBlock x:Name="lblBuild" Text="1.1" Foreground="{StaticResource TextMain}" FontFamily="Consolas" FontSize="10.5"/>
          </StackPanel>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,3,0,0">
            <TextBlock Text="> PRIVILEGE ..... " Foreground="{StaticResource TextFaint}" FontFamily="Consolas" FontSize="10.5"/>
            <TextBlock Text="ADMIN" Foreground="{StaticResource Green}" FontFamily="Consolas" FontSize="10.5"/>
          </StackPanel>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,3,0,0">
            <TextBlock Text="> RESTORE POINT . " Foreground="{StaticResource TextFaint}" FontFamily="Consolas" FontSize="10.5"/>
            <TextBlock x:Name="lblRp" Text="PENDING" Foreground="{StaticResource Amber}" FontFamily="Consolas" FontSize="10.5"/>
          </StackPanel>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,3,0,0">
            <TextBlock Text="> CREATOR ....... " Foreground="{StaticResource TextFaint}" FontFamily="Consolas" FontSize="10.5"/>
            <TextBlock Text="KFLI" Foreground="{StaticResource Red}" FontFamily="Consolas" FontSize="10.5"/>
          </StackPanel>
        </StackPanel>
      </Grid>
    </Border>

    <!-- ============ Main content ============ -->
    <Grid Grid.Row="2" Margin="14">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="280"/>
        <ColumnDefinition Width="14"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="14"/>
        <ColumnDefinition Width="290"/>
      </Grid.ColumnDefinitions>

      <!-- LEFT COLUMN -->
      <ScrollViewer Grid.Column="0" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
        <StackPanel>
          <Border Style="{StaticResource PanelBorder}" Margin="0,0,0,14">
            <StackPanel>
              <Border BorderBrush="{StaticResource Line}" BorderThickness="0,0,0,1" Padding="12,10,12,10">
                <StackPanel Orientation="Horizontal">
                  <Rectangle Width="6" Height="6" Fill="{StaticResource Red}" Margin="0,0,8,0"/>
                  <TextBlock Text="SYSTEM STATUS" Style="{StaticResource HeadText}"/>
                </StackPanel>
              </Border>
              <StackPanel Margin="12,10,12,4">
                <StackPanel Margin="0,0,0,10">
                  <Grid>
                    <TextBlock Text="CPU Usage" Foreground="{StaticResource TextDim}" FontSize="11"/>
                    <TextBlock x:Name="lblCpu" Text="--%" Foreground="{StaticResource Green}" FontFamily="Consolas" FontWeight="Bold" HorizontalAlignment="Right"/>
                  </Grid>
                  <ProgressBar x:Name="barCpu" Style="{StaticResource SlimBar}" Foreground="{StaticResource Green}" Margin="0,4,0,0"/>
                </StackPanel>
                <StackPanel Margin="0,0,0,10">
                  <Grid>
                    <TextBlock Text="RAM Usage" Foreground="{StaticResource TextDim}" FontSize="11"/>
                    <TextBlock x:Name="lblRam" Text="--%" Foreground="#35D1C9" FontFamily="Consolas" FontWeight="Bold" HorizontalAlignment="Right"/>
                  </Grid>
                  <ProgressBar x:Name="barRam" Style="{StaticResource SlimBar}" Foreground="#35D1C9" Margin="0,4,0,0"/>
                </StackPanel>
                <StackPanel Margin="0,0,0,10">
                  <Grid>
                    <TextBlock Text="GPU Usage" Foreground="{StaticResource TextDim}" FontSize="11"/>
                    <TextBlock x:Name="lblGpu" Text="--%" Foreground="#C85BFF" FontFamily="Consolas" FontWeight="Bold" HorizontalAlignment="Right"/>
                  </Grid>
                  <ProgressBar x:Name="barGpu" Style="{StaticResource SlimBar}" Foreground="#C85BFF" Margin="0,4,0,0"/>
                </StackPanel>
                <StackPanel Margin="0,0,0,10">
                  <Grid>
                    <TextBlock Text="VRAM Usage" Foreground="{StaticResource TextDim}" FontSize="11"/>
                    <TextBlock x:Name="lblVram" Text="--%" Foreground="#FF8A3D" FontFamily="Consolas" FontWeight="Bold" HorizontalAlignment="Right"/>
                  </Grid>
                  <ProgressBar x:Name="barVram" Style="{StaticResource SlimBar}" Foreground="#FF8A3D" Margin="0,4,0,0"/>
                </StackPanel>
              </StackPanel>
            </StackPanel>
          </Border>

          <Border Style="{StaticResource PanelBorder}">
            <StackPanel>
              <Border BorderBrush="{StaticResource Line}" BorderThickness="0,0,0,1" Padding="12,10,12,10">
                <DockPanel>
                  <Button x:Name="btnRefreshInfo" DockPanel.Dock="Right" Content="Refresh" Style="{StaticResource FlatBtn}" Width="56" Height="22"/>
                  <StackPanel Orientation="Horizontal">
                    <Rectangle Width="6" Height="6" Fill="{StaticResource Red}" Margin="0,0,8,0"/>
                    <TextBlock Text="SYSTEM INFO" Style="{StaticResource HeadText}"/>
                  </StackPanel>
                </DockPanel>
              </Border>
              <StackPanel Margin="12,10,12,10" x:Name="infoPanel"/>
            </StackPanel>
          </Border>
        </StackPanel>
      </ScrollViewer>

      <!-- CENTER COLUMN -->
      <Border Grid.Column="2" Style="{StaticResource PanelBorder}">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <Border Grid.Row="0" BorderBrush="{StaticResource Line}" BorderThickness="0,0,0,1" Padding="12,10,12,10">
            <DockPanel>
              <TextBlock DockPanel.Dock="Right" Text="9 MODULES LOADED" Foreground="{StaticResource TextFaint}" FontFamily="Consolas" FontSize="10"/>
              <StackPanel Orientation="Horizontal">
                <Rectangle Width="6" Height="6" Fill="{StaticResource Red}" Margin="0,0,8,0"/>
                <TextBlock Text="TWEAK MODULES" Style="{StaticResource HeadText}"/>
              </StackPanel>
            </DockPanel>
          </Border>
          <UniformGrid Grid.Row="1" Columns="3" Rows="3" Margin="9" x:Name="tweakGrid"/>
          <Grid Grid.Row="2" Margin="14,0,14,14">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="2*"/>
              <ColumnDefinition Width="10"/>
              <ColumnDefinition Width="1*"/>
            </Grid.ColumnDefinitions>
            <Button x:Name="btnRestart" Grid.Column="0" Height="60" Style="{StaticResource ActionBtn}" Background="#1A0F12" BorderBrush="{StaticResource Red}">
              <StackPanel Orientation="Vertical" HorizontalAlignment="Center">
                <TextBlock Text="APPLY CHANGES &amp; RESTART" Foreground="{StaticResource TextMain}" FontWeight="Bold" FontSize="13" HorizontalAlignment="Center"/>
                <TextBlock Text="Tweaks apply instantly - restart finalizes GPU and visual changes" Foreground="{StaticResource TextDim}" FontSize="10" HorizontalAlignment="Center"/>
              </StackPanel>
            </Button>
            <Button x:Name="btnExit" Grid.Column="2" Height="60" Style="{StaticResource ActionBtn}">
              <TextBlock Text="EXIT" Foreground="{StaticResource TextDim}" FontWeight="Bold" FontSize="13"/>
            </Button>
          </Grid>
        </Grid>
      </Border>

      <!-- RIGHT COLUMN -->
      <Grid Grid.Column="4">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="14"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <Border Grid.Row="0" Style="{StaticResource PanelBorder}">
          <StackPanel>
            <Border BorderBrush="{StaticResource Line}" BorderThickness="0,0,0,1" Padding="12,10,12,10">
              <StackPanel Orientation="Horizontal">
                <Rectangle Width="6" Height="6" Fill="{StaticResource Red}" Margin="0,0,8,0"/>
                <TextBlock Text="QUICK ACTIONS" Style="{StaticResource HeadText}"/>
              </StackPanel>
            </Border>
            <StackPanel Margin="12,6,12,6" x:Name="qaPanel"/>
            <Border BorderBrush="{StaticResource Line}" BorderThickness="0,1,0,0" Padding="10">
              <TextBlock Text="&quot;SPEED IS A WEAPON&quot;" Foreground="{StaticResource Red}" FontFamily="Consolas" FontSize="10" HorizontalAlignment="Center"/>
            </Border>
          </StackPanel>
        </Border>

        <Border Grid.Row="2" Style="{StaticResource PanelBorder}">
          <DockPanel>
            <Border DockPanel.Dock="Top" BorderBrush="{StaticResource Line}" BorderThickness="0,0,0,1" Padding="12,8,12,8">
              <DockPanel>
                <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                  <Button x:Name="btnOpenLog" Content="Open" Style="{StaticResource FlatBtn}" Width="46" Height="22" Margin="0,0,6,0"/>
                  <Button x:Name="btnClearLogs" Content="Clear" Style="{StaticResource FlatBtn}" Width="46" Height="22"/>
                </StackPanel>
                <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                  <Rectangle Width="6" Height="6" Fill="{StaticResource Red}" Margin="0,0,8,0"/>
                  <TextBlock Text="LOGS" Style="{StaticResource HeadText}"/>
                </StackPanel>
              </DockPanel>
            </Border>
            <ListBox x:Name="lstLogs" MinHeight="110" Background="Transparent" BorderThickness="0" Padding="8,6,8,6"
                     Foreground="{StaticResource TextDim}" FontFamily="Consolas" FontSize="10.5"
                     ScrollViewer.HorizontalScrollBarVisibility="Disabled"/>
          </DockPanel>
        </Border>
      </Grid>
    </Grid>

    <!-- ============ Footer ============ -->
    <Border Grid.Row="3" BorderBrush="{StaticResource Line}" BorderThickness="0,1,0,0" Padding="14,10,14,10">
      <TextBlock Text="THE SYSTEM NEVER SLEEPS   //   CONTROL - OPTIMIZE - DOMINATE   //   PULSE (c) 2026   //   KFLI | THE DIGITAL SHADOW" Foreground="{StaticResource TextFaint}" FontFamily="Consolas" FontSize="9.5" HorizontalAlignment="Center"/>
    </Border>
  </Grid>
</Window>
'@

try {
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $window = [Windows.Markup.XamlReader]::Load($reader)
} catch {
    Show-Fatal ("PULSE could not build its window:`n`n" + $_.Exception.Message)
    exit 1
}

$ctrl = @{}
$controlNames = @(
    'lblCpu','lblRam','lblGpu','lblVram','barCpu','barRam','barGpu','barVram',
    'infoPanel','tweakGrid','qaPanel','lstLogs','btnClearLogs','btnOpenLog',
    'btnRestart','btnExit','btnDownloads','lblState','dotState','lblClock','lblRp','lblBuild',
    'lblVersion','vecLogo','imgLogo','vecLogoSmall','imgLogoSmall','glitchCyan','glitchRed',
    'btnRefreshInfo'
)
$missing = @()
foreach ($n in $controlNames) {
    $ctrl[$n] = $window.FindName($n)
    if (-not $ctrl[$n]) { $missing += $n }
}
if ($missing.Count -gt 0) {
    Show-Fatal ('UI elements not found: ' + ($missing -join ', '))
    exit 1
}

# Fit the window to small screens
try {
    $wa = [System.Windows.SystemParameters]::WorkArea
    if ($window.Height -gt $wa.Height) { $window.Height = $wa.Height }
    if ($window.Width  -gt $wa.Width)  { $window.Width  = $wa.Width }
    if ($window.MinHeight -gt $window.Height) { $window.MinHeight = $window.Height }
    if ($window.MinWidth  -gt $window.Width)  { $window.MinWidth  = $window.Width }
} catch {}

$ctrl.lblBuild.Text   = $BuildVersion
$ctrl.lblVersion.Text = '  |  GUI Edition v' + $BuildVersion

# ---------------------------------------------------------------------------
# 4. UI helpers
# ---------------------------------------------------------------------------

function Get-Brush {
    param([string]$Hex)
    if (-not $script:BrushCache.ContainsKey($Hex)) {
        $b = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($Hex)
        $b.Freeze()
        $script:BrushCache[$Hex] = $b
    }
    return $script:BrushCache[$Hex]
}

function New-Text {
    param(
        [string]$Text, [string]$Color = '#E9EDF1', [double]$Size = 12,
        [string]$Font = 'Segoe UI', [bool]$Bold = $false, [bool]$Wrap = $false
    )
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $Text
    $tb.Foreground = Get-Brush $Color
    $tb.FontSize = $Size
    $tb.FontFamily = New-Object System.Windows.Media.FontFamily($Font)
    if ($Bold) { $tb.FontWeight = [System.Windows.FontWeights]::Bold }
    if ($Wrap) { $tb.TextWrapping = [System.Windows.TextWrapping]::Wrap }
    return $tb
}

function Confirm-Action {
    param([string]$Text)
    $r = [System.Windows.MessageBox]::Show($window, $Text, 'PULSE Gaming Tweak', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
    return ($r -eq [System.Windows.MessageBoxResult]::Yes)
}

# Official Microsoft Sysinternals tools. Downloads are saved locally but never executed by PULSE.
$RecommendedTools = @(
    @{ Name = 'RAMMap'; Desc = 'Inspect physical RAM, file cache, standby list, and memory pressure.'; Url = 'https://learn.microsoft.com/en-us/sysinternals/downloads/rammap'; DownloadUrl = 'https://download.sysinternals.com/files/RAMMap.zip'; File = 'RAMMap.zip' },
    @{ Name = 'Process Explorer'; Desc = 'Find the processes, handles, DLLs, CPU, and RAM behind slowdowns.'; Url = 'https://learn.microsoft.com/en-us/sysinternals/downloads/process-explorer'; DownloadUrl = 'https://download.sysinternals.com/files/ProcessExplorer.zip'; File = 'ProcessExplorer.zip' },
    @{ Name = 'Autoruns'; Desc = 'Review startup apps, services, and login entries before disabling anything.'; Url = 'https://learn.microsoft.com/en-us/sysinternals/downloads/autoruns'; DownloadUrl = 'https://download.sysinternals.com/files/Autoruns.zip'; File = 'Autoruns.zip' },
    @{ Name = 'Process Monitor'; Desc = 'Trace file, Registry, process, and thread activity when troubleshooting.'; Url = 'https://learn.microsoft.com/en-us/sysinternals/downloads/procmon'; DownloadUrl = 'https://download.sysinternals.com/files/ProcessMonitor.zip'; File = 'ProcessMonitor.zip' },
    @{ Name = 'TCPView'; Desc = 'See active TCP and UDP connections to investigate network activity.'; Url = 'https://learn.microsoft.com/en-us/sysinternals/downloads/tcpview'; DownloadUrl = 'https://download.sysinternals.com/files/TCPView.zip'; File = 'TCPView.zip' }
)
$script:ActiveDownloads = @()

function Start-ToolDownload {
    param($Tool, $Progress, $Status, $DownloadButton)
    try {
        $downloadDir = Join-Path $DataDir 'Downloads'
        New-Item -ItemType Directory -Path $downloadDir -Force -ErrorAction Stop | Out-Null
        $destination = Join-Path $downloadDir $Tool.File
        if (Test-Path -LiteralPath $destination) {
            $answer = [System.Windows.MessageBox]::Show($window, "$($Tool.File) already exists in PULSE Downloads. Replace it?", 'PULSE Downloads', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
            if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }
        }
        $temp = $destination + '.part'
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        $client = New-Object System.Net.WebClient
        $item = [pscustomobject]@{ Client = $client; Temp = $temp; Destination = $destination; Tool = $Tool; Progress = $Progress; Status = $Status; Button = $DownloadButton }
        $progressHandler = {
            param($sender, $eventArgs)
            $item.Progress.Value = $eventArgs.ProgressPercentage
            if ($eventArgs.TotalBytesToReceive -gt 0) {
                $item.Status.Text = ('Downloading {0}%  |  {1:N1} / {2:N1} MB' -f $eventArgs.ProgressPercentage, ($eventArgs.BytesReceived / 1MB), ($eventArgs.TotalBytesToReceive / 1MB))
            } else {
                $item.Status.Text = ('Downloading {0}%' -f $eventArgs.ProgressPercentage)
            }
        }.GetNewClosure()
        $completeHandler = {
            param($sender, $eventArgs)
            try {
                if ($eventArgs.Error) {
                    $item.Status.Text = 'Download failed - see log'
                    Write-Log ("Download failed for {0}: {1}" -f $item.Tool.Name, $eventArgs.Error.Message) 'ERR'
                } elseif ($eventArgs.Cancelled) {
                    $item.Status.Text = 'Download cancelled'
                    Write-Log ("Download cancelled: {0}" -f $item.Tool.Name) 'WARN'
                } else {
                    Move-Item -LiteralPath $item.Temp -Destination $item.Destination -Force
                    $item.Progress.Value = 100
                    $item.Status.Text = ('Complete: ' + $item.Destination)
                    $item.Button.Content = 'Downloaded'
                    $item.Button.IsEnabled = $false
                    Write-Log ("Downloaded {0} to {1}" -f $item.Tool.Name, $item.Destination) 'OK'
                }
            } catch {
                $item.Status.Text = 'Could not finalize download - see log'
                Write-Log ("Could not finalize {0}: {1}" -f $item.Tool.Name, $_.Exception.Message) 'ERR'
            } finally {
                try { $item.Client.Dispose() } catch {}
                $script:ActiveDownloads = @($script:ActiveDownloads | Where-Object { $_ -ne $item })
            }
        }.GetNewClosure()
        $client.add_DownloadProgressChanged($progressHandler)
        $client.add_DownloadFileCompleted($completeHandler)
        $script:ActiveDownloads += $item
        $Progress.Value = 0
        $Status.Text = 'Starting secure download...'
        $DownloadButton.IsEnabled = $false
        Write-Log ('Downloading ' + $Tool.Name + ' from Microsoft Sysinternals') 'INFO'
        $client.DownloadFileAsync([uri]$Tool.DownloadUrl, $temp)
    } catch {
        $Status.Text = 'Could not start download - see log'
        $DownloadButton.IsEnabled = $true
        Write-Log ("Could not start download for {0}: {1}" -f $Tool.Name, $_.Exception.Message) 'ERR'
    }
}

function Open-DownloadsWindow {
    $toolsWindow = New-Object System.Windows.Window
    $toolsWindow.Title = 'PULSE | Recommended Tools'
    $toolsWindow.Owner = $window
    $toolsWindow.Width = 760
    $toolsWindow.Height = 620
    $toolsWindow.MinWidth = 620
    $toolsWindow.MinHeight = 460
    $toolsWindow.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterOwner
    $toolsWindow.Background = Get-Brush '#08090B'
    $toolsWindow.Foreground = Get-Brush '#E9EDF1'

    $root = New-Object System.Windows.Controls.Grid
    $root.Margin = [System.Windows.Thickness]::new(18)
    $root.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition))
    $root.RowDefinitions[0].Height = [System.Windows.GridLength]::Auto
    $root.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition))
    $root.RowDefinitions[1].Height = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)

    $header = New-Object System.Windows.Controls.StackPanel
    $title = New-Text -Text 'RECOMMENDED TOOLS' -Color '#FF2440' -Size 20 -Font 'Consolas' -Bold $true
    $subtitle = New-Text -Text 'Download official Microsoft Sysinternals tools directly into PULSE Downloads. Progress is shown for every download; files are never run automatically.' -Color '#AEB5BE' -Size 12 -Wrap $true
    $subtitle.Margin = [System.Windows.Thickness]::new(0, 6, 0, 14)
    [void]$header.Children.Add($title)
    [void]$header.Children.Add($subtitle)
    [System.Windows.Controls.Grid]::SetRow($header, 0)
    [void]$root.Children.Add($header)

    $scroll = New-Object System.Windows.Controls.ScrollViewer
    $scroll.VerticalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
    $list = New-Object System.Windows.Controls.StackPanel
    foreach ($tool in $RecommendedTools) {
        $card = New-Object System.Windows.Controls.Border
        $card.Background = Get-Brush '#101214'
        $card.BorderBrush = Get-Brush '#23262B'
        $card.BorderThickness = [System.Windows.Thickness]::new(1)
        $card.Padding = [System.Windows.Thickness]::new(14)
        $card.Margin = [System.Windows.Thickness]::new(0, 0, 0, 10)
        $row = New-Object System.Windows.Controls.Grid
        $row.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
        $row.ColumnDefinitions[0].Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
        $row.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
        $row.ColumnDefinitions[1].Width = [System.Windows.GridLength]::Auto
        $copy = New-Object System.Windows.Controls.StackPanel
        [void]$copy.Children.Add((New-Text -Text $tool.Name -Color '#E9EDF1' -Size 14 -Bold $true))
        $description = New-Text -Text $tool.Desc -Color '#AEB5BE' -Size 11.5 -Wrap $true
        $description.Margin = [System.Windows.Thickness]::new(0, 3, 12, 0)
        [void]$copy.Children.Add($description)
        $progress = New-Object System.Windows.Controls.ProgressBar
        $progress.Minimum = 0
        $progress.Maximum = 100
        $progress.Height = 6
        $progress.Margin = [System.Windows.Thickness]::new(0, 8, 12, 0)
        $progress.Foreground = Get-Brush '#35D1C9'
        [void]$copy.Children.Add($progress)
        $status = New-Text -Text 'Ready to download' -Color '#8A9099' -Size 10.5 -Font 'Consolas' -Wrap $true
        $status.Margin = [System.Windows.Thickness]::new(0, 4, 12, 0)
        [void]$copy.Children.Add($status)
        [System.Windows.Controls.Grid]::SetColumn($copy, 0)
        [void]$row.Children.Add($copy)
        $buttons = New-Object System.Windows.Controls.StackPanel
        $buttons.Orientation = [System.Windows.Controls.Orientation]::Vertical
        $buttons.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $download = New-Object System.Windows.Controls.Button
        $download.Content = 'Download'
        $download.Tag = $tool
        $download.Width = 100
        $download.Height = 28
        $download.Margin = [System.Windows.Thickness]::new(0, 0, 0, 6)
        $download.Background = Get-Brush '#172229'
        $download.Foreground = Get-Brush '#35D1C9'
        $download.BorderBrush = Get-Brush '#35D1C9'
        $download.BorderThickness = [System.Windows.Thickness]::new(1)
        $download.Add_Click(({ param($s, $e) Start-ToolDownload -Tool $s.Tag -Progress $progress -Status $status -DownloadButton $s }.GetNewClosure()))
        [void]$buttons.Children.Add($download)
        $open = New-Object System.Windows.Controls.Button
        $open.Content = 'Official page'
        $open.Tag = $tool.Url
        $open.Width = 100
        $open.Height = 28
        $open.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $open.Background = Get-Brush '#171A1E'
        $open.Foreground = Get-Brush '#35D1C9'
        $open.BorderBrush = Get-Brush '#35D1C9'
        $open.BorderThickness = [System.Windows.Thickness]::new(1)
        $open.Add_Click({ param($s, $e) try { Start-Process -FilePath ([string]$s.Tag) } catch { Write-Log ('Could not open official tools page: ' + $_.Exception.Message) 'WARN' } })
        [void]$buttons.Children.Add($open)
        [System.Windows.Controls.Grid]::SetColumn($buttons, 1)
        [void]$row.Children.Add($buttons)
        $card.Child = $row
        [void]$list.Children.Add($card)
    }
    $scroll.Content = $list
    [System.Windows.Controls.Grid]::SetRow($scroll, 1)
    [void]$root.Children.Add($scroll)
    $toolsWindow.Content = $root
    [void]$toolsWindow.ShowDialog()
}

# Logs: the queue is filled by any thread, drained here on the UI thread
function Update-LogView {
    $lines = New-Object System.Collections.Generic.List[string]
    $item = $null
    $count = 0
    while ($count -lt 60 -and $LogQueue.TryDequeue([ref]$item)) {
        $count++
        $color = '#8A9099'
        switch ($item.Type) {
            'OK'   { $color = '#33D17A' }
            'WARN' { $color = '#FFB020' }
            'ERR'  { $color = '#FF2440' }
        }
        $tb = New-Text -Text ('[' + $item.Time + '] ' + $item.Msg) -Color $color -Size 10.5 -Font 'Consolas' -Wrap $true
        $ctrl.lstLogs.Items.Insert(0, $tb)
        [void]$lines.Add(('[{0}] [{1}] {2}' -f $item.Time, $item.Type, $item.Msg))
    }
    while ($ctrl.lstLogs.Items.Count -gt 400) { $ctrl.lstLogs.Items.RemoveAt($ctrl.lstLogs.Items.Count - 1) }
    if ($lines.Count -gt 0) {
        try { Add-Content -LiteralPath $LogFile -Value $lines.ToArray() -Encoding UTF8 -ErrorAction Stop } catch {}
    }
}

function Set-UiBusy {
    param([bool]$On, [string]$Text = '')
    $script:Busy = $On
    $ctrl.tweakGrid.IsEnabled = -not $On
    $ctrl.qaPanel.IsEnabled   = -not $On
    $ctrl.btnRestart.IsEnabled = -not $On
    $ctrl.btnDownloads.IsEnabled = -not $On
    if ($On) {
        $script:BusySince = Get-Date
        $ctrl.lblState.Text = ('WORKING: ' + $Text.ToUpper())
        $ctrl.lblState.Foreground = Get-Brush '#FFB020'
        $ctrl.dotState.Fill = Get-Brush '#FFB020'
    } else {
        $script:BusySince = $null
        $ctrl.lblState.Text = 'SYSTEM READY'
        $ctrl.lblState.Foreground = Get-Brush '#33D17A'
        $ctrl.dotState.Fill = Get-Brush '#33D17A'
    }
}

# ---------------------------------------------------------------------------
# 5. Background task engine (keeps the window responsive)
# ---------------------------------------------------------------------------

function Start-BgTask {
    param([string]$Title, [string]$Commands, $Sender = $null)
    if ($script:Busy) { return }
    Set-UiBusy $true $Title
    if ($Sender -and ($Sender -is [System.Windows.Controls.Button])) { $Sender.Content = '...' }
    Write-Log ('> ' + $Title) 'INFO'
    try {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = [System.Threading.ApartmentState]::MTA
        $rs.Open()
        $rs.SessionStateProxy.SetVariable('LogQueue', $LogQueue)
        $rs.SessionStateProxy.SetVariable('Shared', $Shared)
        $rs.SessionStateProxy.SetVariable('BackupFile', $BackupFile)
        $rs.SessionStateProxy.SetVariable('ScriptRoot', $ScriptRoot)
        $rs.SessionStateProxy.SetVariable('DataDir', $DataDir)
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        $prefix  = '$ErrorActionPreference = ''Stop''; $global:PulseErrors = 0' + "`n"
        $wrapped = "try {`n" + $Commands + "`n} catch { Write-Log ('Unexpected error: ' + `$_.Exception.Message) 'ERR' }"
        [void]$ps.AddScript($prefix + $WorkerLib + "`n" + $wrapped)
        $handle = $ps.BeginInvoke()
        $script:Task = @{ PS = $ps; RS = $rs; Handle = $handle; Sender = $Sender; Title = $Title }
    } catch {
        Write-Log ('Could not start task: ' + $_.Exception.Message) 'ERR'
        Set-UiBusy $false
    }
}

function Complete-BgTask {
    if (-not $script:Task) { return }
    if (-not $script:Task.Handle.IsCompleted) { return }
    $t = $script:Task
    $script:Task = $null
    try { [void]$t.PS.EndInvoke($t.Handle) } catch { Write-Log ('Task error: ' + $_.Exception.Message) 'ERR' }
    try {
        $shown = 0
        foreach ($er in $t.PS.Streams.Error) {
            if ($shown -ge 3) { break }
            Write-Log ('Warning: ' + $er.ToString()) 'WARN'
            $shown++
        }
    } catch {}
    try { $t.PS.Dispose() } catch {}
    try { $t.RS.Close(); $t.RS.Dispose() } catch {}

    if ($t.Sender -and ($t.Sender -is [System.Windows.Controls.Button])) {
        $t.Sender.Content = 'Done'
        $tm = New-Object System.Windows.Threading.DispatcherTimer
        $tm.Interval = [TimeSpan]::FromSeconds(1.6)
        $tm.Tag = $t.Sender
        $tm.Add_Tick({ param($s, $e) $s.Stop(); $s.Tag.Content = 'Run' })
        $tm.Start()
    }
    Sync-Toggles
    Set-UiBusy $false
}

# ---------------------------------------------------------------------------
# 6. Tweak tiles + quick actions
# ---------------------------------------------------------------------------

$Actions = @{
    safe  = @{ Title = 'Safe Tweak'
               Cmd = 'Set-GameModeRegistry; Set-GamesTaskPriority; Set-PowerPlanHighPerformance; Write-Done "Safe Tweak"' }
    aggr  = @{ Title = 'Aggressive Tweak'
               Confirm = 'This disables several background services (telemetry, search indexing, Superfetch...). Continue?'
               Cmd = 'Set-GameModeRegistry; Set-GamesTaskPriority; Set-PowerPlanUltimate; Disable-VisualEffectsForPerformance; Disable-NonCriticalServices; Write-Done "Aggressive Tweak"' }
    svc   = @{ Title = 'Service Manager'; Cmd = '' }
    win   = @{ Title = 'Windows Optimization'
               Cmd = 'Set-WindowsGeneralTweaks; Write-Done "Windows Optimization"' }
    gpu   = @{ Title = 'GPU Tweak'
               Cmd = 'Enable-HAGS; Disable-FullscreenOptimizationsPrompt; Write-Done "GPU Tweak"' }
    cpu   = @{ Title = 'CPU and Gaming Priority'
               Cmd = 'Set-PowerPlanUltimate; Set-GamesTaskPriority; Write-Done "CPU and Gaming Priority"' }
    net   = @{ Title = 'Network Tweak'
               Cmd = 'Invoke-NetworkCleanup; Disable-Nagle; Write-Done "Network Tweak"' }
    clean = @{ Title = 'Cleaner Tools'
               Confirm = 'This permanently removes temporary files and empties the Recycle Bin. DNS cache will also be flushed. Continue?'
               Cmd = 'Invoke-TempCleanup; Invoke-NetworkCleanup; Invoke-RecycleBinEmpty; Write-Done "Cleaner Tools"' }
    restore = @{ Title = 'Restore Changes'
               Confirm = 'Restore everything PULSE changed (registry values, services, power plan) back to the original state?'
               Cmd = 'Restore-AllChanges; Write-Done "Restore"' }
    qtemp = @{ Title = 'Clear Temp Files'; Confirm = 'This permanently removes files from the Windows and user temporary folders. Files currently in use will be skipped. Continue?'; Cmd = 'Invoke-TempCleanup; Write-Done "Clear Temp Files"' }
    qdns  = @{ Title = 'Flush DNS';         Cmd = 'Invoke-NetworkCleanup; Write-Done "Flush DNS"' }
    qnet  = @{ Title = 'Network Latency Settings'; Confirm = 'This changes latency-related TCP settings only for active network adapters. It may not improve every game and requires a restart to fully apply. Continue?'; Cmd = 'Disable-Nagle; Write-Done "Network Latency Settings"' }
    qgpu  = @{ Title = 'Best GPU Settings'; Cmd = 'Enable-HAGS; Disable-FullscreenOptimizationsPrompt; Write-Done "Best GPU Settings"' }
    qtrim = @{ Title = 'Optimize Drive (TRIM)'; Cmd = 'Invoke-DriveOptimize; Write-Done "Optimize Drive"' }
}

$Tiles = @(
    @{ Id = 'safe';    N = 1; Name = 'SAFE TWEAK';           Badge = 'RECOMMENDED';     Desc = 'Balanced - Stable - Safe';        Tip = 'Game Mode ON, game task priority boosted, High Performance power plan.' },
    @{ Id = 'aggr';    N = 2; Name = 'AGGRESSIVE TWEAK';     Badge = 'MAX PERFORMANCE'; Desc = 'Higher FPS - Less Background';    Tip = 'Everything in Safe, plus Ultimate plan, lighter visuals and background services off.' },
    @{ Id = 'svc';     N = 3; Name = 'SERVICE MANAGER';      Badge = 'LOW RISK';        Desc = 'Enable / Disable Services';       Tip = 'Disable or re-enable Superfetch, telemetry, search indexing, fax and error reporting.' },
    @{ Id = 'win';     N = 4; Name = 'WINDOWS OPTIMIZATION'; Badge = 'GENERAL';         Desc = 'General System Tweaks';           Tip = 'Trims visual effects and disables Start menu suggestions.' },
    @{ Id = 'gpu';     N = 5; Name = 'GPU TWEAK';            Badge = 'GAMING';          Desc = 'Best Settings for Gaming';        Tip = 'Hardware GPU scheduling, fullscreen optimizations, Game DVR off.' },
    @{ Id = 'cpu';     N = 6; Name = 'CPU & GAME PRIORITY';  Badge = 'BOOST';           Desc = 'Power Plan - Game Scheduling';    Tip = 'Ultimate Performance plan and boosted game scheduling priority. It does not add RAM.' },
    @{ Id = 'net';     N = 7; Name = 'NETWORK TWEAK';        Badge = 'ADVANCED';       Desc = 'DNS - Active Adapter Settings';   Tip = 'Flushes DNS and changes latency settings only on active adapters; results vary by game and network.' },
    @{ Id = 'clean';   N = 8; Name = 'CLEANER TOOLS';        Badge = 'MAINTENANCE';     Desc = 'Temp Files - Cache - DNS';        Tip = 'Clears temp folders, flushes DNS, empties the Recycle Bin.' },
    @{ Id = 'restore'; N = 9; Name = 'RESTORE CHANGES';      Badge = 'DEFAULTS';        Desc = 'Revert to Original Settings';     Tip = 'Puts back the exact values that were there before PULSE changed them.' }
)

function Invoke-Action {
    param([string]$Id, $Sender = $null)
    if ($script:Busy) { return }
    $a = $Actions[$Id]
    if (-not $a) { return }
    $cmd = $a.Cmd
    if ($Id -eq 'svc') {
        $r = [System.Windows.MessageBox]::Show($window, "Disable non-critical background services now?`n(Yes = disable, No = restore them)", 'Service Manager', [System.Windows.MessageBoxButton]::YesNoCancel, [System.Windows.MessageBoxImage]::Question)
        if ($r -eq [System.Windows.MessageBoxResult]::Yes)     { $cmd = 'Disable-NonCriticalServices; Write-Done "Service Manager"' }
        elseif ($r -eq [System.Windows.MessageBoxResult]::No)  { $cmd = 'Enable-NonCriticalServices; Write-Done "Service Manager"' }
        else { return }
    } elseif ($a.Confirm) {
        if (-not (Confirm-Action $a.Confirm)) { Write-Log ($a.Title + ' cancelled') 'WARN'; return }
    }
    Start-BgTask -Title $a.Title -Commands $cmd -Sender $Sender
}

foreach ($t in $Tiles) {
    $btn = New-Object System.Windows.Controls.Button
    $btn.Style   = $window.FindResource('TweakCard')
    $btn.Margin  = [System.Windows.Thickness]::new(5)
    $btn.Tag     = $t.Id
    $btn.ToolTip = $t.Tip

    $stack = New-Object System.Windows.Controls.StackPanel

    $top = New-Object System.Windows.Controls.Grid
    $col1 = New-Object System.Windows.Controls.ColumnDefinition
    $col1.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
    $col2 = New-Object System.Windows.Controls.ColumnDefinition
    $col2.Width = [System.Windows.GridLength]::Auto
    [void]$top.ColumnDefinitions.Add($col1)
    [void]$top.ColumnDefinitions.Add($col2)
    $top.Margin = [System.Windows.Thickness]::new(0, 0, 0, 10)

    $num = New-Text -Text ('[{0:D2}]' -f $t.N) -Color '#52585F' -Size 10 -Font 'Consolas'
    [System.Windows.Controls.Grid]::SetColumn($num, 0)

    $chip = New-Object System.Windows.Controls.Border
    $chip.BorderBrush = Get-Brush '#7A1220'
    $chip.BorderThickness = [System.Windows.Thickness]::new(1)
    $chip.Padding = [System.Windows.Thickness]::new(5, 1, 5, 1)
    $chip.Child = New-Text -Text $t.Badge -Color '#FF2440' -Size 9 -Font 'Consolas'
    [System.Windows.Controls.Grid]::SetColumn($chip, 1)

    [void]$top.Children.Add($num)
    [void]$top.Children.Add($chip)

    $name = New-Text -Text $t.Name -Color '#E9EDF1' -Size 13.5 -Bold $true -Wrap $true
    $name.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)
    $desc = New-Text -Text $t.Desc -Color '#8A9099' -Size 11.5 -Wrap $true

    [void]$stack.Children.Add($top)
    [void]$stack.Children.Add($name)
    [void]$stack.Children.Add($desc)
    $btn.Content = $stack
    $btn.Add_Click({ param($s, $e) Invoke-Action ([string]$s.Tag) })
    [void]$ctrl.tweakGrid.Children.Add($btn)
}

function New-QuickRow {
    param([string]$Label)
    $row = New-Object System.Windows.Controls.Grid
    $row.Margin = [System.Windows.Thickness]::new(0, 6, 0, 6)
    $c1 = New-Object System.Windows.Controls.ColumnDefinition
    $c1.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
    $c2 = New-Object System.Windows.Controls.ColumnDefinition
    $c2.Width = [System.Windows.GridLength]::Auto
    [void]$row.ColumnDefinitions.Add($c1)
    [void]$row.ColumnDefinitions.Add($c2)
    $txt = New-Text -Text $Label -Color '#E9EDF1' -Size 12.5
    $txt.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    [System.Windows.Controls.Grid]::SetColumn($txt, 0)
    [void]$row.Children.Add($txt)
    return $row
}

function Add-QuickToggle {
    param([string]$Label, [string]$Tag)
    $row = New-QuickRow $Label
    $chk = New-Object System.Windows.Controls.CheckBox
    $chk.Style = $window.FindResource('ToggleSwitch')
    $chk.Tag = $Tag
    [System.Windows.Controls.Grid]::SetColumn($chk, 1)
    $chk.Add_Checked({ param($s, $e) Invoke-Toggle ([string]$s.Tag) $true })
    $chk.Add_Unchecked({ param($s, $e) Invoke-Toggle ([string]$s.Tag) $false })
    [void]$row.Children.Add($chk)
    [void]$ctrl.qaPanel.Children.Add($row)
    return $chk
}

function Add-QuickRun {
    param([string]$Label, [string]$Id)
    $row = New-QuickRow $Label
    $btn = New-Object System.Windows.Controls.Button
    $btn.Style = $window.FindResource('FlatBtn')
    $btn.Content = 'Run'
    $btn.Width = 56
    $btn.Height = 24
    $btn.Tag = $Id
    [System.Windows.Controls.Grid]::SetColumn($btn, 1)
    $btn.Add_Click({ param($s, $e) Invoke-Action ([string]$s.Tag) $s })
    [void]$row.Children.Add($btn)
    [void]$ctrl.qaPanel.Children.Add($row)
}

function Invoke-Toggle {
    param([string]$Tag, [bool]$On)
    if ($script:Syncing -or $script:Busy) { return }
    if ($Tag -eq 'game') {
        if ($On) { Start-BgTask -Title 'Game Mode ON' -Commands 'Set-GameModeRegistry' }
        else     { Start-BgTask -Title 'Game Mode OFF' -Commands 'Disable-GameModeRegistry' }
    } elseif ($Tag -eq 'svc') {
        if ($On) {
            if (Confirm-Action 'Disable non-critical background services (telemetry, search indexing, Superfetch, ...)?') {
                Start-BgTask -Title 'Disable services' -Commands 'Disable-NonCriticalServices; Write-Done "Disable services"'
            } else { Sync-Toggles }
        } else {
            Start-BgTask -Title 'Restore services' -Commands 'Enable-NonCriticalServices; Write-Done "Restore services"'
        }
    } elseif ($Tag.StartsWith('svc:')) {
        $name = $Tag.Substring(4)
        $s = $SafeToggleServices | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        if (-not $s) { return }
        $qName  = "'" + $s.Name  + "'"
        $qLabel = "'" + $s.Label + "'"
        if (-not $On) {
            $cmd = "Disable-OneService -Name $qName -Label $qLabel; Write-Done $qLabel"
            Start-BgTask -Title ('Disable ' + $s.Label) -Commands $cmd
        } else {
            $qDefault = "'" + $s.Default + "'"
            $cmd = "Enable-OneService -Name $qName -Label $qLabel -Default $qDefault; Write-Done $qLabel"
            Start-BgTask -Title ('Restore ' + $s.Label) -Commands $cmd
        }
    }
}

function Sync-Toggles {
    $script:Syncing = $true
    try {
        $game = $true
        $v = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\GameBar' -Name 'AutoGameModeEnabled' -ErrorAction SilentlyContinue).AutoGameModeEnabled
        if ($null -ne $v) { $game = ([int]$v -eq 1) }
        if ($script:ToggleGame) { $script:ToggleGame.IsChecked = $game }

        $allOff = $true
        foreach ($n in @('SysMain','DiagTrack','WSearch','Fax','WerSvc')) {
            $svc = Get-Service -Name $n -ErrorAction SilentlyContinue
            if ($svc -and $svc.StartType -ne 'Disabled') { $allOff = $false }
        }
        if ($script:ToggleSvc) { $script:ToggleSvc.IsChecked = $allOff }

        if ($script:ToggleSvcInd) {
            foreach ($name in $script:ToggleSvcInd.Keys) {
                $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
                $chk = $script:ToggleSvcInd[$name]
                if ($svc -and $chk) { $chk.IsChecked = ($svc.StartType -ne 'Disabled') }
            }
        }
    } catch {
    } finally {
        $script:Syncing = $false
    }
}

$script:Syncing = $true
$script:ToggleGame = Add-QuickToggle 'Enable Game Mode' 'game'
$script:ToggleSvc  = Add-QuickToggle 'Disable Unnecessary Services (all)' 'svc'
$script:ToggleSvcInd = @{}
foreach ($s in $SafeToggleServices) {
    $script:ToggleSvcInd[$s.Name] = Add-QuickToggle ('  Enable: ' + $s.Label) ('svc:' + $s.Name)
}
$script:Syncing = $false
Add-QuickRun 'Clear Temp Files'        'qtemp'
Add-QuickRun 'Flush DNS'               'qdns'
Add-QuickRun 'Optimize Network'        'qnet'
Add-QuickRun 'Apply Best GPU Settings' 'qgpu'
Add-QuickRun 'Optimize Drive (TRIM)'   'qtrim'
Sync-Toggles

# ---------------------------------------------------------------------------
# 7. System info + live stats (values come from the stats runspace)
# ---------------------------------------------------------------------------

function Add-InfoRow {
    param([string]$K, [string]$V)
    $row = New-Object System.Windows.Controls.Grid
    $row.Margin = [System.Windows.Thickness]::new(0, 4, 0, 4)
    $c1 = New-Object System.Windows.Controls.ColumnDefinition
    $c1.Width = [System.Windows.GridLength]::new(84)
    $c2 = New-Object System.Windows.Controls.ColumnDefinition
    $c2.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
    [void]$row.ColumnDefinitions.Add($c1)
    [void]$row.ColumnDefinitions.Add($c2)
    $k = New-Text -Text $K -Color '#8A9099' -Size 11.5
    [System.Windows.Controls.Grid]::SetColumn($k, 0)
    $v = New-Text -Text $V -Color '#E9EDF1' -Size 11 -Font 'Consolas' -Wrap $true
    [System.Windows.Controls.Grid]::SetColumn($v, 1)
    [void]$row.Children.Add($k)
    [void]$row.Children.Add($v)
    [void]$ctrl.infoPanel.Children.Add($row)
}

Add-InfoRow 'Info' 'Loading...'

function Set-StatRow {
    param($Label, $Bar, $Value, [string]$Color, [string]$Text = '')
    if ($null -eq $Value) {
        $Label.Text = 'N/A'
        $Label.Foreground = Get-Brush '#52585F'
        $Bar.Value = 0
        return
    }
    $v = [math]::Max(0, [math]::Min(100, [double]$Value))
    if ($v -ge 90)     { $Color = '#FF2440' }
    elseif ($v -ge 75) { $Color = '#FFB020' }
    if ($Text) { $Label.Text = $Text } else { $Label.Text = ('{0:N0}%' -f $v) }
    $Label.Foreground = Get-Brush $Color
    $Bar.Foreground = Get-Brush $Color
    $Bar.Value = $v
}

function Update-StatsView {
    Set-StatRow $ctrl.lblCpu $ctrl.barCpu $Shared.Cpu '#33D17A'
    Set-StatRow $ctrl.lblRam $ctrl.barRam $Shared.Ram '#35D1C9'
    Set-StatRow $ctrl.lblGpu $ctrl.barGpu $Shared.Gpu '#C85BFF'

    $used  = $Shared.VramUsed
    $total = [double]$Shared.VramTotal
    if ($null -eq $used) {
        Set-StatRow $ctrl.lblVram $ctrl.barVram $null '#FF8A3D'
    } elseif ($total -gt 0) {
        $pct = [math]::Min(100, ([double]$used / $total) * 100)
        Set-StatRow $ctrl.lblVram $ctrl.barVram $pct '#FF8A3D'
        $ctrl.lblVram.ToolTip = ('{0:N1} GB / {1:N1} GB' -f ([double]$used / 1GB), ($total / 1GB))
    } else {
        Set-StatRow $ctrl.lblVram $ctrl.barVram 0 '#FF8A3D' ('{0:N1} GB' -f ([double]$used / 1GB))
    }

    if ($Shared.Info) {
        $sig = (($Shared.Info | ForEach-Object { $_.K + ':' + $_.V }) -join '|')
        if ($sig -ne $script:InfoSig) {
            $script:InfoSig = $sig
            $ctrl.infoPanel.Children.Clear()
            foreach ($i in @($Shared.Info)) { Add-InfoRow ([string]$i.K) ([string]$i.V) }
        }
    }
}

function Update-UiLoop {
    try {
        Update-LogView
        Complete-BgTask
        Complete-RpTask
        if ($script:InfoRefreshTasks -and $script:InfoRefreshTasks.Count -gt 0) {
            $done = @($script:InfoRefreshTasks | Where-Object { $_.Handle.IsCompleted })
            foreach ($t in $done) {
                try { [void]$t.PS.EndInvoke($t.Handle) } catch {}
                try { $t.PS.Dispose() } catch {}
                try { $t.RS.Close(); $t.RS.Dispose() } catch {}
                [void]$script:InfoRefreshTasks.Remove($t)
            }
        }
        if ($script:Busy -and $script:BusySince -and (((Get-Date) - $script:BusySince).TotalSeconds -gt 45)) {
            Write-Log 'A background task is taking too long - unlocking the interface (it may still finish in the background)' 'WARN'
            Set-UiBusy $false
        }
        $script:Tick++
        if (($script:Tick % 5) -eq 0) {
            $ctrl.lblClock.Text = (Get-Date -Format 'HH:mm:ss')
            Update-StatsView
        }
        $rp = [string]$Shared.Rp
        if ($rp -ne $script:RpShown) {
            $script:RpShown = $rp
            $ctrl.lblRp.Text = $rp
            if ($rp -eq 'CREATED') { $ctrl.lblRp.Foreground = Get-Brush '#33D17A' }
            elseif ($rp -eq 'PENDING') { $ctrl.lblRp.Foreground = Get-Brush '#FFB020' }
            else { $ctrl.lblRp.Foreground = Get-Brush '#8A9099' }
        }
    } catch {
        # never let the UI timer crash the app
    }
}

# ---------------------------------------------------------------------------
# 8. Logo image (optional), animations
# ---------------------------------------------------------------------------

function Initialize-Logo {
    foreach ($n in @('logo.png', 'kfli.png', 'KFLI.png', 'logo.jpg')) {
        $f = Join-Path $ScriptRoot $n
        if (-not (Test-Path -LiteralPath $f)) { continue }
        try {
            $bi = New-Object System.Windows.Media.Imaging.BitmapImage
            $bi.BeginInit()
            $bi.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $bi.UriSource = [System.Uri]::new($f)
            $bi.EndInit()
            $bi.Freeze()
            $ctrl.imgLogo.Source = $bi
            $ctrl.imgLogoSmall.Source = $bi
            $ctrl.imgLogo.Visibility = [System.Windows.Visibility]::Visible
            $ctrl.imgLogoSmall.Visibility = [System.Windows.Visibility]::Visible
            $ctrl.vecLogo.Visibility = [System.Windows.Visibility]::Collapsed
            $ctrl.vecLogoSmall.Visibility = [System.Windows.Visibility]::Collapsed
            $window.Icon = $bi
            Write-Log ('Custom logo loaded: ' + $n) 'INFO'
            return
        } catch {
            Write-Log ('Could not load logo ' + $n) 'WARN'
        }
    }
}

function New-GlitchAnimation {
    param([double]$Base, [double]$Kick)
    $kf = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
    $kf.Duration = [System.Windows.Duration]::new([TimeSpan]::FromSeconds(5))
    $kf.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    $frames = @( @(0.0, $Base), @(3.9, ($Base * 3)), @(3.95, $Kick), @(4.0, $Base) )
    foreach ($f in $frames) {
        $k = New-Object System.Windows.Media.Animation.DiscreteDoubleKeyFrame
        $k.KeyTime = [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromSeconds([double]$f[0]))
        $k.Value = [double]$f[1]
        [void]$kf.KeyFrames.Add($k)
    }
    return $kf
}

function Start-UiAnimations {
    try {
        $pulse = New-Object System.Windows.Media.Animation.DoubleAnimation
        $pulse.From = 1.0
        $pulse.To = 0.25
        $pulse.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(900))
        $pulse.AutoReverse = $true
        $pulse.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
        $ctrl.dotState.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $pulse)
    } catch {}
    try {
        $tc = $ctrl.glitchCyan.RenderTransform
        $tr = $ctrl.glitchRed.RenderTransform
        $tc.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, (New-GlitchAnimation -2.0 5.0))
        $tr.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, (New-GlitchAnimation 2.0 -5.0))
    } catch {}
}

# ---------------------------------------------------------------------------
# 9. Events, timers, background stats
# ---------------------------------------------------------------------------

$ctrl.btnClearLogs.Add_Click({ $ctrl.lstLogs.Items.Clear(); Write-Log 'Log cleared' 'INFO' })
$ctrl.btnDownloads.Add_Click({ if (-not $script:Busy) { Open-DownloadsWindow } })

$script:InfoRefreshTasks = New-Object 'System.Collections.Generic.List[object]'

$ctrl.btnRefreshInfo.Add_Click({
    try {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = [System.Threading.ApartmentState]::MTA
        $rs.Open()
        $rs.SessionStateProxy.SetVariable('Shared', $Shared)
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript($InfoScript)
        $handle = $ps.BeginInvoke()
        $script:InfoRefreshTasks.Add(@{ PS = $ps; RS = $rs; Handle = $handle })
        Write-Log 'Refreshing system info...' 'INFO'
    } catch { Write-Log ('Could not refresh system info: ' + $_.Exception.Message) 'WARN' }
})

$ctrl.btnOpenLog.Add_Click({
    try {
        if (Test-Path -LiteralPath $LogFile) { Start-Process -FilePath 'notepad.exe' -ArgumentList ('"' + $LogFile + '"') }
        else { Write-Log 'No log file yet' 'WARN' }
    } catch { Write-Log ('Could not open log: ' + $_.Exception.Message) 'WARN' }
})

$ctrl.btnRestart.Add_Click({
    if ($script:Busy) { return }
    if (Confirm-Action 'Restart Windows now? All applied tweaks will be finalized.') {
        Write-Log 'Restart requested by user' 'WARN'
        Update-LogView
        try { Restart-Computer -Force } catch { Write-Log ('Restart failed: ' + $_.Exception.Message) 'ERR' }
    }
})

$ctrl.btnExit.Add_Click({ $window.Close() })

$window.Add_Closing({ $Shared.Stop = $true })

$window.Dispatcher.Add_UnhandledException({
    param($s, $e)
    try { Write-Log ('UI error: ' + $e.Exception.Message) 'ERR' } catch {}
    $e.Handled = $true
})

$window.Add_ContentRendered({
    if ($script:Started) { return }
    $script:Started = $true
    try {
        Initialize-Logo
        Start-UiAnimations
        Write-Log 'PULSE started - KFLI // The Digital Shadow' 'INFO'
        Write-Log 'Creating a System Restore Point in the background...' 'INFO'
        Start-RpTask
    } catch {
        Write-Log ('Startup error: ' + $_.Exception.Message) 'ERR'
    }
})

# Restore point runs in its own runspace, completely separate from the busy-lock
# used by tile/quick-action tasks, so it can never disable the interface.
function Start-RpTask {
    try {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = [System.Threading.ApartmentState]::MTA
        $rs.Open()
        $rs.SessionStateProxy.SetVariable('LogQueue', $LogQueue)
        $rs.SessionStateProxy.SetVariable('Shared', $Shared)
        $rs.SessionStateProxy.SetVariable('BackupFile', $BackupFile)
        $rs.SessionStateProxy.SetVariable('ScriptRoot', $ScriptRoot)
        $rs.SessionStateProxy.SetVariable('DataDir', $DataDir)
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript($WorkerLib + "`nNew-SafetyRestorePoint")
        $handle = $ps.BeginInvoke()
        $script:RpTask = @{ PS = $ps; RS = $rs; Handle = $handle }
    } catch {
        Write-Log ('Restore point task could not start: ' + $_.Exception.Message) 'WARN'
        $Shared.Rp = 'SKIPPED'
    }
}

function Complete-RpTask {
    if (-not $script:RpTask) { return }
    if (-not $script:RpTask.Handle.IsCompleted) { return }
    $t = $script:RpTask
    $script:RpTask = $null
    try { [void]$t.PS.EndInvoke($t.Handle) } catch {}
    try { $t.PS.Dispose() } catch {}
    try { $t.RS.Close(); $t.RS.Dispose() } catch {}
}

# Stats runspace (CPU / RAM / GPU / VRAM / system info)
$statsRs = $null
$statsPs = $null
try {
    $statsRs = [runspacefactory]::CreateRunspace()
    $statsRs.ApartmentState = [System.Threading.ApartmentState]::MTA
    $statsRs.Open()
    $statsRs.SessionStateProxy.SetVariable('Shared', $Shared)
    $statsPs = [powershell]::Create()
    $statsPs.Runspace = $statsRs
    [void]$statsPs.AddScript($StatsScript)
    [void]$statsPs.BeginInvoke()
} catch {
    Write-Log ('Live stats unavailable: ' + $_.Exception.Message) 'WARN'
}

$uiTimer = New-Object System.Windows.Threading.DispatcherTimer
$uiTimer.Interval = [TimeSpan]::FromMilliseconds(200)
$uiTimer.Add_Tick({ Update-UiLoop })
$uiTimer.Start()

# ---------------------------------------------------------------------------
# 10. Go
# ---------------------------------------------------------------------------

try {
    [void]$window.ShowDialog()
} catch {
    Write-Log ('Fatal: ' + $_.Exception.Message) 'ERR'
    try { Show-Fatal ('PULSE stopped unexpectedly:' + "`n`n" + $_.Exception.Message) } catch {}
}

$Shared.Stop = $true
try { $uiTimer.Stop() } catch {}
try { Update-LogView } catch {}
try { if ($statsPs) { [void]$statsPs.BeginStop($null, $null) } } catch {}
try { if ($script:RpTask) { [void]$script:RpTask.PS.BeginStop($null, $null) } } catch {}
[Environment]::Exit(0)
