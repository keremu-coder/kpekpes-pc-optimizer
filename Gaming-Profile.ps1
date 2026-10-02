[CmdletBinding()]
param(
    [switch]$Silent,
    [switch]$WhatIf,
    [switch]$Revert,
    [switch]$VerifyOnly,
    [switch]$StepByStep,
    [switch]$GuiMode,
    [switch]$Aggressive,
    [switch]$SkipBackup
)

$ErrorActionPreference = 'Continue'
$script:streamFile = Join-Path $env:TEMP 'Kpekpes_Stream.txt'

function Write-GuiSafe {
    param([string]$T, [string]$X)
    if (-not $GuiMode) { return }
    $line = "##GUI##$T##$X"
    try { Add-Content -LiteralPath $script:streamFile -Value $line -Encoding UTF8 } catch { }
    try { [Console]::Out.WriteLine($line); [Console]::Out.Flush() } catch { }
}

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    if ($GuiMode) { Write-GuiSafe 'DONE' '0' }
    Write-Host "Must run as Administrator." -ForegroundColor Red
    exit 1
}

$script:QosUnsupported = $false
$script:Results = New-Object System.Collections.Generic.List[object]
$script:Plan = $null
$script:StepNo = 0
$script:StepMax = if ($Aggressive) { 19 } else { 18 }
$script:CodExeNames = @('cod.exe', 'cod24.exe', 'cod23.exe', 'ModernWarfare.exe')
$dataDir = Join-Path $env:ProgramData 'KpekpesPCOptimizer'
New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
$bk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Kpekpes_Backup'

if ($GuiMode) {
    try { Remove-Item -LiteralPath $script:streamFile -Force -ErrorAction SilentlyContinue } catch { }
}

function Write-Step([string]$Text) {
    $script:StepNo++
    Write-Host ("[{0}/{1}] {2}" -f $script:StepNo, $script:StepMax, $Text) -ForegroundColor Cyan
    $pct = [math]::Round(($script:StepNo / $script:StepMax) * 100)
    Write-GuiSafe 'STEP' "$($script:StepNo)|$($script:StepMax)|$pct|$Text"
}

function Add-Result { param([string]$N, [bool]$O, [string]$D = '') $script:Results.Add([pscustomobject]@{Name=$N; Ok=$O; Detail=$D}) }

function Set-RegValue {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
    if ($WhatIf) { return }
    try {
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
        New-ItemProperty -LiteralPath $Path -Name $Name -PropertyType $Type -Value $Value -Force -ErrorAction Stop | Out-Null
    } catch { Add-Result "Write $Name" $false $_.Exception.Message }
}

function Test-Reg {
    param([string]$L, [string]$Path, [string]$Name, $E)
    try { $a = (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name } catch { $a = $null }
    Add-Result $L (("$a") -eq ("$E")) "want $E, found $a"
}

function Set-Power {
    param([string]$S, [string]$K, [int]$V)
    if ($WhatIf) { return }
    powercfg /setacvalueindex $script:Plan $S $K $V 2>&1 | Out-Null
    powercfg /setdcvalueindex $script:Plan $S $K $V 2>&1 | Out-Null
}

function Get-PowerIndex {
    param([string]$S, [string]$K)
    $out = powercfg /q $script:Plan $S $K 2>&1 | Out-String
    $m = [regex]::Match($out, 'Current AC Power Setting Index:\s*0x([0-9a-fA-F]+)')
    if ($m.Success) { [Convert]::ToInt32($m.Groups[1].Value, 16) } else { $null }
}

function Get-NvidiaRegPath {
    Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\*' -ErrorAction SilentlyContinue |
        Where-Object { (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).DriverDesc -match 'NVIDIA' } |
        Select-Object -First 1 -ExpandProperty PSPath
}

function Get-AmdGpuRegPath {
    Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\*' -ErrorAction SilentlyContinue |
        Where-Object { (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).DriverDesc -match 'AMD|Radeon|ATI' } |
        Select-Object -First 1 -ExpandProperty PSPath
}

function Get-BcdValue([string]$Name) {
    $out = bcdedit /enum '{current}' 2>&1 | Out-String
    $m = [regex]::Match($out, "(?im)^\s*$([regex]::Escape($Name))\s+(\S+)")
    if ($m.Success) { $m.Groups[1].Value } else { $null }
}

function Get-CodInstallRoots {
    $roots = New-Object System.Collections.Generic.List[string]
    $candidates = @(
        'C:\Program Files (x86)\Call of Duty',
        'C:\Program Files\Call of Duty',
        'C:\Program Files (x86)\Steam\steamapps\common\Call of Duty HQ',
        'C:\Program Files (x86)\Steam\steamapps\common\Call of Duty',
        'C:\Program Files (x86)\Steam\steamapps\common\Call of Duty Black Ops 6',
        'C:\XboxGames\Call of Duty',
        'C:\Program Files\ModifiableWindowsApps\Call of Duty',
        'C:\Program Files (x86)\Battle.net',
        'C:\Program Files\Battle.net',
        "$env:PROGRAMDATA\Battle.net",
        "$env:LOCALAPPDATA\Battle.net"
    )
    foreach ($c in $candidates) { if ($c -and (Test-Path -LiteralPath $c)) { [void]$roots.Add($c) } }

    $vdf = 'C:\Program Files (x86)\Steam\steamapps\libraryfolders.vdf'
    if (Test-Path -LiteralPath $vdf) {
        $txt = Get-Content -LiteralPath $vdf -Raw -ErrorAction SilentlyContinue
        if ($txt) {
            foreach ($m in [regex]::Matches($txt, '"path"\s+"([^"]+)"')) {
                $lib = ($m.Groups[1].Value -replace '\\\\', '\')
                foreach ($g in @('Call of Duty HQ', 'Call of Duty', 'Call of Duty Black Ops 6')) {
                    $p = Join-Path $lib "steamapps\common\$g"
                    if (Test-Path -LiteralPath $p) { [void]$roots.Add($p) }
                }
            }
        }
    }

    Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue |
        ForEach-Object {
            $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if ($p.DisplayName -match 'Call of Duty|Warzone|Black Ops 6' -and $p.InstallLocation -and (Test-Path -LiteralPath $p.InstallLocation)) {
                [void]$roots.Add($p.InstallLocation.TrimEnd('\'))
            }
        }

    $roots | Select-Object -Unique
}

function Get-CodExePaths {
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($root in (Get-CodInstallRoots)) {
        foreach ($name in $script:CodExeNames) {
            Get-ChildItem -LiteralPath $root -Filter $name -Recurse -Depth 8 -File -ErrorAction SilentlyContinue |
                Select-Object -First 3 |
                ForEach-Object { [void]$found.Add($_.FullName) }
        }
    }
    $found | Select-Object -Unique
}

function Test-ServiceDisabled([string]$Name) {
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { return $true }
    $svc.StartType -eq 'Disabled'
}

function Get-IsSingleCcdAmd {
    $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue
    if (-not $cpu) { return $false }
    if ($cpu.Name -notmatch 'AMD') { return $false }
    $cores = ($cpu | Measure-Object -Property NumberOfCores -Sum).Sum
    # Single-CCD Ryzen = 6 or 8 cores. Dual-CCD = 12+ cores.
    return ($cores -le 8)
}

$cpKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\54533251-82be-4824-96c1-47b60b740d00\0cc5b647-c1df-4637-891a-dec35c318583'
$gfx = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
$gameBar = 'HKCU:\Software\Microsoft\GameBar'
$gcs = 'HKCU:\System\GameConfigStore'
$sys = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
$games = "$sys\Tasks\Games"
$InterfacesPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
$tcpParams = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'
$ifeo = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
$layers = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'
$gpuPref = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
$hvci = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity'
$presenceWriter = 'HKLM:\SOFTWARE\Microsoft\WindowsRuntime\ActivatableClassId\Windows.Gaming.GameBar.PresenceServer.Internal.PresenceWriter'

function Invoke-VerifyChecks {
    $script:Results.Clear()
    $active = powercfg /getactivescheme | Out-String
    $m = [regex]::Match($active, '[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}')
    if ($m.Success) { $script:Plan = $m.Value }

    $isSingleCcd = Get-IsSingleCcdAmd

    Add-Result 'Gaming power plan is active' ($active -match 'Kpekpes|Ultimate Performance|High Performance') $active
    Add-Result 'Min processor state = 100' ((Get-PowerIndex 'SUB_PROCESSOR' 'PROCTHROTTLEMIN') -eq 100) ''
    Add-Result 'Max processor state = 100' ((Get-PowerIndex 'SUB_PROCESSOR' 'PROCTHROTTLEMAX') -eq 100) ''

    # --- Fixed: Skip core parking check on single-CCD Ryzen (7600, 7700) ---
    if ($isSingleCcd) {
        Add-Result 'Core parking: N/A (single-CCD Ryzen — OS manages automatically)' $true 'info: single-CCD CPU, parking disabled by design'
    } else {
        Add-Result 'Core parking min cores = 100' ((Get-PowerIndex 'SUB_PROCESSOR' 'CPMINCORES') -eq 100) ''
    }
    Test-Reg 'Core parking range ValueMax = 100' $cpKey 'ValueMax' 100

    Test-Reg 'Power throttling off' 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff' 1
    Test-Reg 'Hardware GPU scheduling on' $gfx 'HwSchMode' 2
    Test-Reg 'MPO disabled (OverlayTestMode = 5)' 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' 'OverlayTestMode' 5
    Test-Reg 'Game Mode on' $gameBar 'AutoGameModeEnabled' 1
    Test-Reg 'Game Bar startup panel off' $gameBar 'ShowStartupPanel' 0
    Test-Reg 'Game DVR off' $gcs 'GameDVR_Enabled' 0
    Test-Reg 'FSE behavior for exclusive fullscreen' $gcs 'GameDVR_FSEBehaviorMode' 2
    Test-Reg 'AllowGameDVR policy = 0' 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0
    Test-Reg 'Store auto-download blocked' 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' 'AutoDownload' 2
    Test-Reg 'Auto HDR off' 'HKCU:\Software\Microsoft\DirectX' 'DisableAutoHDR' 1

    # --- Game Bar Presence Writer disabled ---
    $pwDisabled = (Get-ItemProperty -LiteralPath $presenceWriter -Name 'Enabled' -ErrorAction SilentlyContinue).Enabled
    Add-Result 'Game Bar PresenceWriter disabled' ($pwDisabled -eq 0) "found $pwDisabled"
    Add-Result 'Xbox Game Bar app uninstalled' (-not (Get-AppxPackage -AllUsers *Microsoft.XboxGamingOverlay* -ErrorAction SilentlyContinue)) ''

    $nti = (Get-ItemProperty -LiteralPath $sys -Name 'NetworkThrottlingIndex' -ErrorAction SilentlyContinue).NetworkThrottlingIndex
    Add-Result 'Network throttling off' (($nti -eq -1) -or ($nti -eq 4294967295)) "found $nti"

    # --- SystemResponsiveness: 0 is equivalent to 10 per Microsoft docs ---
    $sr = (Get-ItemProperty -LiteralPath $sys -Name 'SystemResponsiveness' -ErrorAction SilentlyContinue).SystemResponsiveness
    Add-Result 'System responsiveness = 0 (clamped to 10 by Windows)' (($sr -eq 0) -or ($sr -eq 10)) "found $sr"

    Test-Reg 'Games GPU Priority = 8' $games 'GPU Priority' 8
    Test-Reg 'Games Priority = 6' $games 'Priority' 6
    Test-Reg 'Games Scheduling Category = High' $games 'Scheduling Category' 'High'
    Test-Reg 'Games Latency Sensitive = True' $games 'Latency Sensitive' 'True'

    # --- Fixed: Win32PrioritySeparation = 2 (stable) instead of 26 (variable) ---
    Test-Reg 'Win32PrioritySeparation = 2 (stable scheduling)' 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation' 2

    Test-Reg 'Global timer resolution requests on' 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' 'GlobalTimerResolutionRequests' 1
    Test-Reg 'Visual effects = best performance' 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 2
    Test-Reg 'Mouse acceleration off (MouseSpeed)' 'HKCU:\Control Panel\Mouse' 'MouseSpeed' '0'
    Test-Reg 'Menu delay = 0' 'HKCU:\Control Panel\Desktop' 'MenuShowDelay' '0'
    Test-Reg 'Fast startup off' 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled' 0
    Test-Reg 'Memory integrity (HVCI) off' $hvci 'Enabled' 0

    $dt = Get-BcdValue 'disabledynamictick'
    $pt = Get-BcdValue 'useplatformtick'
    Add-Result 'Dynamic tick disabled' ($dt -match '^(Yes|yes)$') "found $dt"
    Add-Result 'Platform tick on' ($pt -match '^(Yes|yes)$') "found $pt"

    $tcpGlobal = netsh int tcp show global | Out-String
    Add-Result 'TCP auto-tuning = normal' ($tcpGlobal -match 'Auto-Tuning Level\s*:\s*normal') ''
    Add-Result 'TCP RSC disabled' ($tcpGlobal -match 'Coalescing State\s*:\s*disabled') ''
    Add-Result 'SysMain disabled' (Test-ServiceDisabled 'SysMain') ''
    Add-Result 'DiagTrack disabled' (Test-ServiceDisabled 'DiagTrack') ''

    $nv = $false
    Get-ChildItem -Path $InterfacesPath -ErrorAction SilentlyContinue | ForEach-Object {
        $a = (Get-ItemProperty -Path $_.PSPath -Name 'TcpAckFrequency' -ErrorAction SilentlyContinue).TcpAckFrequency
        $b = (Get-ItemProperty -Path $_.PSPath -Name 'TCPNoDelay' -ErrorAction SilentlyContinue).TCPNoDelay
        if ($a -eq 1 -and $b -eq 1) { $nv = $true }
    }
    $gDelay = (Get-ItemProperty -LiteralPath $tcpParams -Name 'TcpNoDelay' -ErrorAction SilentlyContinue).TcpNoDelay
    Add-Result "Nagle off (TCPNoDelay)" ($nv -or ($gDelay -eq 1)) ''

    if (Get-Command Get-NetQosPolicy -ErrorAction SilentlyContinue) {
        $qos = Get-NetQosPolicy -Name 'Kpekpes CoD' -ErrorAction SilentlyContinue
        if ($qos) { Add-Result 'CoD QoS policy (DSCP 46)' $true '' }
        elseif (-not $script:QosUnsupported) { Add-Result 'CoD QoS policy (DSCP 46)' $false '' }
    }

    $ifeoOk = $true
    foreach ($exe in $script:CodExeNames) {
        $v = (Get-ItemProperty -LiteralPath "$ifeo\$exe\PerfOptions" -Name 'CpuPriorityClass' -ErrorAction SilentlyContinue).CpuPriorityClass
        if ($v -ne 3) { $ifeoOk = $false; break }
    }
    Add-Result 'CoD executables High CPU priority' $ifeoOk ''

    # --- DS4Windows High priority + affinity ---
    $ds4Priority = (Get-ItemProperty -LiteralPath "$ifeo\DS4Windows.exe\PerfOptions" -Name 'CpuPriorityClass' -ErrorAction SilentlyContinue).CpuPriorityClass
    Add-Result 'DS4Windows High CPU priority' ($ds4Priority -eq 3) "found $ds4Priority"

    try {
        if (-not ('Native.TimerQuery' -as [type])) {
            Add-Type -Namespace Native -Name TimerQuery -MemberDefinition @'
[DllImport("ntdll.dll")]
public static extern int NtQueryTimerResolution(out uint MinimumResolution, out uint MaximumResolution, out uint CurrentResolution);
'@
        }
        [uint32]$min = 0; [uint32]$max = 0; [uint32]$cur = 0
        [Native.TimerQuery]::NtQueryTimerResolution([ref]$min, [ref]$max, [ref]$cur) | Out-Null
        Add-Result 'Timer resolution <= 0.5ms' ($cur -le 5000) "current=$cur (100ns units)"
    } catch {
        Add-Result 'Timer resolution holder task' ([bool](Get-ScheduledTask -TaskName 'Kpekpes Timer Resolution' -ErrorAction SilentlyContinue)) ''
    }

    try {
        $mp = Get-MpPreference -ErrorAction Stop
        $ok = ($mp.ExclusionProcess -contains 'cod.exe')
        Add-Result 'Defender excludes cod.exe' $ok ''
    } catch {
        Add-Result 'Defender excludes cod.exe' $true 'Defender API unavailable (treated as N/A)'
    }

    Add-Result 'Backup folder present' (Test-Path $bk) ''
    Add-Result 'Logon reapply task registered' ([bool](Get-ScheduledTask -TaskName 'Kpekpes Reapply' -ErrorAction SilentlyContinue)) ''
    Add-Result 'Timer resolution task registered' ([bool](Get-ScheduledTask -TaskName 'Kpekpes Timer Resolution' -ErrorAction SilentlyContinue)) ''

    $hasNv = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'NVIDIA' }
    if ($hasNv) {
        $nvPath = Get-NvidiaRegPath
        if ($nvPath) { Test-Reg 'NVIDIA PowerMizer max performance' $nvPath 'PowerMizerEnable' 1 }
        Add-Result 'NVIDIA telemetry service disabled' (Test-ServiceDisabled 'NvTelemetryContainer') ''
    }
    $hasAmdGpu = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'AMD|Radeon' }
    if ($hasAmdGpu) {
        $amdPath = Get-AmdGpuRegPath
        if ($amdPath) {
            $ulps = (Get-ItemProperty -LiteralPath $amdPath -Name 'EnableUlps' -ErrorAction SilentlyContinue).EnableUlps
            Add-Result 'AMD ULPS off' ($ulps -eq 0) "found $ulps"
        }
    }

    if ($Aggressive) {
        Add-Result 'NTFS last access disabled' ((fsutil behavior query disablelastaccess | Out-String) -match '= 1|= 2') ''
        Add-Result 'TRIM enabled' ((fsutil behavior query DisableDeleteNotify | Out-String) -match '= 0') ''
        Add-Result 'Windows Search disabled' (Test-ServiceDisabled 'WSearch') ''
    }

    $total = $script:Results.Count
    $passed = @($script:Results | Where-Object { $_.Ok }).Count
    $pct = if ($total -gt 0) { [math]::Round(($passed / $total) * 100) } else { 0 }

    $i = 0
    foreach ($r in $script:Results) {
        $i++
        $tag = if ($r.Ok) { 'PASS' } else { 'FAIL' }
        Write-Host ("  [{0}] {1}" -f $tag, $r.Name) -ForegroundColor ($(if ($r.Ok) { 'Green' } else { 'Red' }))
        Write-GuiSafe 'CHECK' "$i|$total|0|$tag|$($r.Name)"
    }
    Write-Host ''
    Write-Host ("  SCORE: {0}% ({1}/{2})" -f $pct, $passed, $total) -ForegroundColor Yellow
    Write-GuiSafe 'SCORE' "$passed|$total|$pct"
    return $pct
}

if ($VerifyOnly) {
    Invoke-VerifyChecks | Out-Null
    Write-GuiSafe 'DONE' '0'
    exit 0
}

if ($Revert) {
    if (-not (Test-Path $bk)) { Write-GuiSafe 'REVERT' 'NO_BACKUP'; Write-GuiSafe 'DONE' '0'; exit 1 }
    Get-ChildItem "$bk\*.reg" -ErrorAction SilentlyContinue | ForEach-Object {
        Write-GuiSafe 'REVERTSTEP' $_.Name
        reg import $_.FullName 2>&1 | Out-Null
    }
    $statePath = Join-Path $bk 'state.csv'
    if (Test-Path $statePath) {
        Import-Csv $statePath | ForEach-Object {
            try { Set-Service -Name $_.Name -StartupType $_.StartType -ErrorAction SilentlyContinue } catch { }
        }
    }
    $pwr = Join-Path $bk 'power-guid.txt'
    if (Test-Path $pwr) {
        $guid = (Get-Content $pwr -Raw).Trim()
        if ($guid) { powercfg /setactive $guid | Out-Null }
    }
    $bcd = Join-Path $bk 'bcd.txt'
    if (Test-Path $bcd) {
        foreach ($line in Get-Content $bcd) {
            if ($line -match '^(.*?)=(.*)$') {
                $k = $Matches[1]; $v = $Matches[2]
                if ($v -eq '<unset>') { bcdedit /deletevalue $k 2>&1 | Out-Null }
                else { bcdedit /set $k $v 2>&1 | Out-Null }
            }
        }
    } else {
        bcdedit /deletevalue useplatformtick 2>&1 | Out-Null
        bcdedit /deletevalue disabledynamictick 2>&1 | Out-Null
        bcdedit /deletevalue hypervisorlaunchtype 2>&1 | Out-Null
    }
    try { Remove-NetQosPolicy -Name 'Kpekpes CoD' -Confirm:$false -ErrorAction SilentlyContinue } catch { }
    try { Unregister-ScheduledTask -TaskName 'Kpekpes Reapply' -Confirm:$false -ErrorAction SilentlyContinue } catch { }
    try { Unregister-ScheduledTask -TaskName 'Kpekpes Timer Resolution' -Confirm:$false -ErrorAction SilentlyContinue } catch { }
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'TimerResolutionHold' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Write-GuiSafe 'REVERT' 'DONE'
    Write-GuiSafe 'DONE' '0'
    exit 0
}

# ---------- APPLY ----------
$doBackup = -not $WhatIf -and -not $SkipBackup
Write-Step 'Restore point and registry backup'
if ($doBackup) {
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
        $srKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
        Set-RegValue $srKey 'SystemRestorePointCreationFrequency' 0
        Checkpoint-Computer -Description 'Before Kpekpes CoD Competitive' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Remove-ItemProperty -LiteralPath $srKey -Name 'SystemRestorePointCreationFrequency' -ErrorAction SilentlyContinue
        Add-Result 'Restore point created' $true
    } catch { Add-Result 'Restore point created' $false $_.Exception.Message }

    New-Item -ItemType Directory -Path $bk -Force | Out-Null
    reg export 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' "$bk\SystemProfile.reg" /y | Out-Null
    reg export 'HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' "$bk\GraphicsDrivers.reg" /y | Out-Null
    reg export 'HKLM\SYSTEM\CurrentControlSet\Control\Power' "$bk\Power.reg" /y | Out-Null
    reg export 'HKCU\System\GameConfigStore' "$bk\GameConfigStore.reg" /y | Out-Null
    reg export 'HKCU\Software\Microsoft\GameBar' "$bk\GameBar.reg" /y | Out-Null
    reg export 'HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' "$bk\Tcpip.reg" /y | Out-Null
    reg export 'HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl' "$bk\PriorityControl.reg" /y | Out-Null
    reg export 'HKCU\Control Panel\Mouse' "$bk\Mouse.reg" /y | Out-Null
    reg export 'HKCU\Control Panel\Desktop' "$bk\Desktop.reg" /y | Out-Null
    try { reg export 'HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard' "$bk\DeviceGuard.reg" /y | Out-Null } catch { }

    $orig = powercfg /getactivescheme | Out-String
    $gm = [regex]::Match($orig, '[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}')
    if ($gm.Success) { Set-Content -LiteralPath (Join-Path $bk 'power-guid.txt') -Value $gm.Value -Encoding ASCII }

    @(
        "disabledynamictick=$(if (Get-BcdValue 'disabledynamictick') { Get-BcdValue 'disabledynamictick' } else { '<unset>' })",
        "useplatformtick=$(if (Get-BcdValue 'useplatformtick') { Get-BcdValue 'useplatformtick' } else { '<unset>' })",
        "hypervisorlaunchtype=$(if (Get-BcdValue 'hypervisorlaunchtype') { Get-BcdValue 'hypervisorlaunchtype' } else { '<unset>' })"
    ) | Set-Content -LiteralPath (Join-Path $bk 'bcd.txt') -Encoding ASCII

    $svcNames = @('SysMain', 'DiagTrack', 'WSearch', 'NvTelemetryContainer', 'TabletInputService', 'MapsBroker', 'RetailDemo', 'Fax', 'RemoteRegistry')
    $svcNames | ForEach-Object {
        $s = Get-Service $_ -ErrorAction SilentlyContinue
        if ($s) { [pscustomobject]@{ Name = $s.Name; StartType = "$($s.StartType)" } }
    } | Export-Csv -LiteralPath (Join-Path $bk 'state.csv') -NoTypeInformation -Encoding UTF8
}

Write-Step 'Power plan: Ultimate Performance / Kpekpes'
$plans = foreach ($line in (powercfg /list)) {
    if ($line -match '([0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})\s+\((.+?)\)') {
        [pscustomobject]@{ Guid = $Matches[1]; Name = $Matches[2] }
    }
}
$pick = $plans | Where-Object { $_.Name -like 'Kpekpes*' } | Select-Object -First 1
if (-not $pick) { $pick = $plans | Where-Object { $_.Name -like 'Ultimate Performance*' } | Select-Object -First 1 }
if ($pick) {
    $script:Plan = $pick.Guid
} else {
    $out = powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 2>&1 | Out-String
    $m = [regex]::Match($out, '[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}')
    if ($m.Success) { $script:Plan = $m.Value; powercfg -changename $script:Plan 'Kpekpes CoD Competitive' 'Warzone and MP max performance' | Out-Null }
    else { $script:Plan = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' }
}
if (-not $WhatIf) { powercfg /setactive $script:Plan | Out-Null }

$isSingleCcd = Get-IsSingleCcdAmd

Set-RegValue $cpKey 'ValueMin' 0
Set-RegValue $cpKey 'ValueMax' 100
Set-Power 'SUB_PROCESSOR' 'PROCTHROTTLEMIN' 100
Set-Power 'SUB_PROCESSOR' 'PROCTHROTTLEMAX' 100
Set-Power 'SUB_PROCESSOR' 'PERFBOOSTMODE' 2
Set-Power 'SUB_PROCESSOR' 'PERFEPP' 0
Set-Power 'SUB_PROCESSOR' 'PERFINCPOL' 2
Set-Power 'SUB_PROCESSOR' 'PERFDECPOL' 1

# --- Fixed: Only set core parking for multi-CCD CPUs ---
if (-not $isSingleCcd) {
    Set-Power 'SUB_PROCESSOR' 'CPMINCORES' 100
    Set-Power 'SUB_PROCESSOR' 'CPMAXCORES' 100
}

Set-Power '2a737441-1930-4402-8d77-b2bebba308a3' '48e6b7a6-50f5-4782-a5d4-53bb8f07e226' 0
Set-Power '2a737441-1930-4402-8d77-b2bebba308a3' 'd4e98f31-5ffe-4ce1-be31-1b38b384c009' 0
Set-Power '501a4d13-42af-4429-9fd1-a8218c268e20' 'ee12f906-d277-404b-b6da-e5fa1a576df5' 0
Set-Power 'SUB_DISK' 'DISKIDLE' 0
if (-not $WhatIf) { powercfg /setactive $script:Plan | Out-Null; powercfg /hibernate off | Out-Null }
Set-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled' 0

Write-Step 'Game Mode on, Game Bar/DVR/MPO/Auto HDR off'
Set-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff' 1
Set-RegValue $gfx 'HwSchMode' 2
Set-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' 'OverlayTestMode' 5
Set-RegValue $gameBar 'AllowAutoGameMode' 1
Set-RegValue $gameBar 'AutoGameModeEnabled' 1
Set-RegValue $gameBar 'UseNexusForGameBarEnabled' 0
Set-RegValue $gameBar 'ShowStartupPanel' 0
Set-RegValue $gcs 'GameDVR_Enabled' 0
Set-RegValue $gcs 'GameDVR_FSEBehaviorMode' 2
Set-RegValue $gcs 'GameDVR_HonorUserFSEBehaviorMode' 1
Set-RegValue $gcs 'GameDVR_DXGIHonorFSEWindowsCompatible' 1
Set-RegValue $gcs 'GameDVR_EFSEFeatureFlags' 0
Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0
Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0
Set-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0
Set-RegValue 'HKCU:\Software\Microsoft\DirectX' 'DisableAutoHDR' 1
Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\VideoSettings' 'EnableAutoHDR' 0
Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'HonorUserFullScreenBehavior' 1

Write-Step 'NVIDIA / AMD GPU competitive'
$hasNv = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'NVIDIA' }
if ($hasNv) {
    $nvPath = Get-NvidiaRegPath
    if ($nvPath) {
        Set-RegValue $nvPath 'PowerMizerEnable' 1
        Set-RegValue $nvPath 'PowerMizerLevel' 1
        Set-RegValue $nvPath 'PowerMizerLevelAC' 1
        Set-RegValue $nvPath 'PerfLevelSrc' 0x2222
        Set-RegValue $nvPath 'DisableDynamicPstate' 1
    }
    Set-RegValue 'HKLM:\SOFTWARE\NVIDIA Corporation\Global\FTS' 'EnableRID44231' 0
    Set-RegValue 'HKLM:\SOFTWARE\NVIDIA Corporation\Global\FTS' 'EnableRID64640' 0
    Set-RegValue 'HKLM:\SOFTWARE\NVIDIA Corporation\Global\FTS' 'EnableRID66610' 0
    Set-RegValue 'HKCU:\Software\NVIDIA Corporation\Global\ShadowPlay\NVSPCAPS' 'DVREnabled' 0
    if (-not $WhatIf) {
        try { Stop-Service NvTelemetryContainer -Force -ErrorAction SilentlyContinue; Set-Service NvTelemetryContainer -StartupType Disabled -ErrorAction SilentlyContinue } catch { }
        Get-Process -Name 'NVIDIA Share' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
}
$amdPath = Get-AmdGpuRegPath
if ($amdPath) {
    Set-RegValue $amdPath 'EnableUlps' 0
    Set-RegValue $amdPath 'EnableUlps_NA' 0
    Set-RegValue $amdPath 'DisableDMACopy' 1
}

Write-Step 'MMCSS + foreground scheduling (CoD CPU)'
Set-RegValue $sys 'NetworkThrottlingIndex' 0xFFFFFFFF
Set-RegValue $sys 'SystemResponsiveness' 0
Set-RegValue $games 'GPU Priority' 8
Set-RegValue $games 'Priority' 6
Set-RegValue $games 'Scheduling Category' 'High' 'String'
Set-RegValue $games 'SFIO Priority' 'High' 'String'
Set-RegValue $games 'Latency Sensitive' 'True' 'String'
Set-RegValue $games 'Clock Rate' 10000
Set-RegValue $games 'Affinity' 0
Set-RegValue $games 'Background Only' 'False' 'String'

# --- Fixed: Win32PrioritySeparation = 2 (stable) instead of 26 (variable) ---
Set-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation' 2
Set-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' 'GlobalTimerResolutionRequests' 1

Write-Step '0.5ms timer + low-jitter clock'
if (-not $WhatIf) {
    bcdedit /set disabledynamictick yes | Out-Null
    bcdedit /set useplatformtick yes | Out-Null
    $hp = Join-Path $dataDir 'TimerResolutionHold.ps1'
    $hc = @'
Add-Type -Namespace Native -Name TimerRes -MemberDefinition @"
[DllImport("ntdll.dll", SetLastError = true)]
public static extern int NtSetTimerResolution(uint DesiredResolution, bool SetResolution, out uint CurrentResolution);
"@
$target = 5000
[uint32]$current = 0
[Native.TimerRes]::NtSetTimerResolution($target, $true, [ref]$current) | Out-Null
while ($true) { Start-Sleep -Seconds 3600 }
'@
    Set-Content -LiteralPath $hp -Value $hc -Encoding UTF8 -Force
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match 'TimerResolutionHold' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Process -FilePath 'powershell.exe' -ArgumentList "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$hp`"" -WindowStyle Hidden
    try {
        $u = "$env:USERDOMAIN\$env:USERNAME"
        $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$hp`""
        $t = New-ScheduledTaskTrigger -AtLogOn -User $u
        $p = New-ScheduledTaskPrincipal -UserId $u -LogonType Interactive -RunLevel Limited
        $s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
        Register-ScheduledTask -TaskName 'Kpekpes Timer Resolution' -Action $a -Trigger $t -Principal $p -Settings $s -Force -ErrorAction Stop | Out-Null
        Add-Result 'Timer resolution holder registered at logon' $true
    } catch { Add-Result 'Timer resolution holder registered at logon' $false $_.Exception.Message }
}

Write-Step 'TCP stack for Battle.net/Steam + UDP games'
if (-not $WhatIf) {
    netsh int tcp set global autotuninglevel=normal | Out-Null
    netsh int tcp set global rss=enabled | Out-Null
    netsh int tcp set global rsc=disabled | Out-Null
    netsh int tcp set global ecncapability=disabled | Out-Null
    netsh int tcp set global timestamps=disabled | Out-Null
    netsh int tcp set heuristics disabled | Out-Null
    netsh int tcp set supplemental template=internet congestionprovider=ctcp | Out-Null
    Set-RegValue $tcpParams 'TcpNoDelay' 1
    Set-RegValue $tcpParams 'TcpAckFrequency' 1
    Set-RegValue $tcpParams 'TcpDelAckTicks' 0
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched' 'NonBestEffortLimit' 0
    Get-ChildItem -Path $InterfacesPath -ErrorAction SilentlyContinue | ForEach-Object {
        Set-ItemProperty -Path $_.PSPath -Name 'TcpAckFrequency' -Value 1 -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $_.PSPath -Name 'TCPNoDelay' -Value 1 -ErrorAction SilentlyContinue
    }
}

Write-Step 'Ethernet adapter: power-save off, MSI on'
$nics = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Wi-Fi|Wireless|WLAN|Bluetooth' }
foreach ($nic in $nics) {
    if ($WhatIf) { continue }
    try { Enable-NetAdapterRss -Name $nic.Name -ErrorAction Stop } catch { }
    try { Disable-NetAdapterPowerManagement -Name $nic.Name -ErrorAction Stop } catch { }
    try { Disable-NetAdapterLso -Name $nic.Name -ErrorAction Stop } catch { }
    try { Disable-NetAdapterRsc -Name $nic.Name -ErrorAction Stop } catch { }
    $want = '^(Energy Efficient Ethernet|Green Ethernet|Power Saving Mode|Gigabit Lite|Advanced EEE|Interrupt Moderation|Flow Control|Jumbo Packet|Jumbo Frames)$'
    foreach ($p in (Get-NetAdapterAdvancedProperty -Name $nic.Name -ErrorAction SilentlyContinue)) {
        if ($p.DisplayName -match $want) {
            $off = $p.ValidDisplayValues | Where-Object { $_ -match '^(Disabled|Off|1514)$' } | Select-Object -First 1
            if ($off) { try { Set-NetAdapterAdvancedProperty -Name $nic.Name -DisplayName $p.DisplayName -DisplayValue $off -NoRestart -ErrorAction Stop } catch { } }
        }
    }
    $pnpId = $nic.PnpDeviceID
    if ($pnpId -like '*PCI*') {
        $mp = "HKLM:\SYSTEM\CurrentControlSet\Enum\$pnpId\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties"
        if (!(Test-Path $mp)) { New-Item -Path $mp -Force -ErrorAction SilentlyContinue | Out-Null }
        if (Test-Path $mp) { Set-ItemProperty -Path $mp -Name 'MSISupported' -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue }
    }
}

Write-Step 'GPU MSI interrupts'
if (-not $WhatIf) {
    Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | ForEach-Object {
        $pnp = $_.PNPDeviceID
        if ($pnp -like '*PCI*') {
            $mp = "HKLM:\SYSTEM\CurrentControlSet\Enum\$pnp\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties"
            if (!(Test-Path $mp)) { New-Item -Path $mp -Force -ErrorAction SilentlyContinue | Out-Null }
            if (Test-Path $mp) { Set-ItemProperty -Path $mp -Name 'MSISupported' -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue }
        }
    }
}

Write-Step 'CoD + DS4Windows process profile'
if (-not $WhatIf) {
    foreach ($exe in $script:CodExeNames) {
        Set-RegValue "$ifeo\$exe\PerfOptions" 'CpuPriorityClass' 3
        Set-RegValue "$ifeo\$exe\PerfOptions" 'IoPriority' 3
        Set-RegValue $gpuPref $exe 'GpuPreference=2;' 'String'
    }
    Set-RegValue "$ifeo\DS4Windows.exe\PerfOptions" 'CpuPriorityClass' 3
    Set-RegValue "$ifeo\DS4Windows.exe\PerfOptions" 'IoPriority' 3
    foreach ($exePath in (Get-CodExePaths)) {
        Set-RegValue $layers $exePath '~ DISABLEDXMAXIMIZEDWINDOWEDMODE HIGHDPIAWARE' 'String'
        Set-RegValue $gpuPref $exePath 'GpuPreference=2;' 'String'
    }
    $script:QosUnsupported = $false
    try { Remove-NetQosPolicy -Name 'Kpekpes CoD' -Confirm:$false -ErrorAction SilentlyContinue } catch { }
    try {
        New-NetQosPolicy -Name 'Kpekpes CoD' -AppPathNameMatchCondition 'cod.exe' -DSCPAction 46 -IPProtocolMatchCondition Both -ErrorAction Stop | Out-Null
    } catch {
        try { New-NetQosPolicy -Name 'Kpekpes CoD' -AppPathMatchCondition 'cod.exe' -DSCPAction 46 -ErrorAction Stop | Out-Null }
        catch { $script:QosUnsupported = $true }
    }
}

Write-Step 'Windows Update will not reboot mid-session'
Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 0
Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoRebootWithLoggedOnUsers' 1
Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'ExcludeWUDriversInQualityUpdate' 1
Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' 'AutoDownload' 2

Write-Step 'Background services (keep Xbox auth for Game Pass)'
if (-not $WhatIf) {
    $svcs = @('SysMain', 'DiagTrack')
    if ($Aggressive) { $svcs += @('WSearch', 'TabletInputService', 'MapsBroker', 'RetailDemo', 'Fax', 'RemoteRegistry') }
    foreach ($s in $svcs) {
        try { Stop-Service $s -Force -ErrorAction SilentlyContinue; Set-Service $s -StartupType Disabled -ErrorAction Stop }
        catch { Add-Result "Disable $s" $false $_.Exception.Message }
    }
}

Write-Step 'Remove Game Bar completely (Battle.net + DS4Windows only)'
if (-not $WhatIf) {
    # Uninstall AppX packages
    foreach ($pat in @('*Microsoft.XboxGamingOverlay*', '*Microsoft.XboxSpeechToTextOverlay*', '*Microsoft.XboxGameCallableUI*')) {
        try {
            Get-AppxPackage -AllUsers $pat -ErrorAction SilentlyContinue | ForEach-Object {
                try { Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction SilentlyContinue } catch { }
            }
            Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like "$pat" } |
                ForEach-Object {
                    try { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue | Out-Null } catch { }
                }
        } catch { }
    }

    # Disable Game Bar Presence Writer via its ActivatableClassId
    try {
        if (Test-Path $presenceWriter) {
            Set-ItemProperty -LiteralPath $presenceWriter -Name 'Enabled' -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            Add-Result 'Game Bar PresenceWriter disabled' $true ''
        }
    } catch { Add-Result 'Game Bar PresenceWriter disabled' $false $_.Exception.Message }

    # Registry policies to prevent reinstall
    Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0
    Set-RegValue 'HKCU:\Software\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0
    Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarDa' 0
    Set-RegValue 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
    Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowSyncProviderNotifications' 0

    # Block Store auto-download of Game Bar
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' 'AutoDownload' 2
}

if ($Aggressive) {
    Write-Step 'Aggressive competitive debloat'
    if (-not $WhatIf) {
        fsutil behavior set disablelastaccess 1 | Out-Null
        fsutil behavior set DisableDeleteNotify 0 | Out-Null
        Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 1
        Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BackgroundAppGlobalToggle' 0
        Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338388Enabled' 0
        Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338389Enabled' 0
        Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'AllowCortana' 0
        Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'CortanaConsent' 0
        Set-RegValue 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1
        Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications' 'ToastEnabled' 0
        $hasAmd = (Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue).Name -match 'AMD'
        if ($hasAmd) {
            Set-Power 'SUB_PROCESSOR' 'PERFEPP' 0
            Set-Power 'SUB_PROCESSOR' 'PERFINCPOL' 1
            Set-Power 'SUB_PROCESSOR' 'PERFDECPOL' 1
        }
    }
}

Write-Step 'Memory integrity off (Ricochet safe — Secure Boot + TPM required)'
if (-not $WhatIf) {
    Set-RegValue $hvci 'Enabled' 0
    Set-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' 'EnableVirtualizationBasedSecurity' 0
    bcdedit /set hypervisorlaunchtype off | Out-Null
}

Write-Step 'Defender exclusions for CoD + Battle.net + DS4'
$cands = @()
$cands += Get-CodInstallRoots
$cands += @(
    'C:\Program Files (x86)\Battle.net',
    'C:\Program Files\Battle.net',
    "$env:PROGRAMDATA\Battle.net",
    "$env:LOCALAPPDATA\Battle.net",
    'C:\Program Files\DS4Windows',
    'C:\DS4Windows',
    "$env:USERPROFILE\Documents\DS4Windows",
    "$env:USERPROFILE\Downloads\DS4Windows",
    "$env:APPDATA\DS4Windows"
)
$paths = @($cands | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique)
if (-not $WhatIf) {
    try {
        foreach ($p in $paths) { Add-MpPreference -ExclusionPath $p -ErrorAction SilentlyContinue }
        Add-MpPreference -ExclusionProcess 'DS4Windows.exe', 'Battle.net.exe', 'cod.exe', 'cod24.exe', 'ModernWarfare.exe', 'Steam.exe' -ErrorAction SilentlyContinue
        Add-Result 'Defender exclusions added' $true
    } catch { Add-Result 'Defender exclusions added' $false $_.Exception.Message }
}

Write-Step 'Visual effects, raw mouse, sticky keys'
Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 2
$desk = 'HKCU:\Control Panel\Desktop'
Set-RegValue $desk 'UserPreferencesMask' ([byte[]](0x90, 0x12, 0x03, 0x80, 0x10, 0x00, 0x00, 0x00)) 'Binary'
Set-RegValue $desk 'MenuShowDelay' '0' 'String'
Set-RegValue $desk 'DragFullWindows' '1' 'String'
Set-RegValue $desk 'FontSmoothing' '2' 'String'
Set-RegValue "$desk\WindowMetrics" 'MinAnimate' '0' 'String'
Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 0
Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAnimations' 0
Set-RegValue 'HKCU:\Control Panel\Mouse' 'MouseSpeed' '0' 'String'
Set-RegValue 'HKCU:\Control Panel\Mouse' 'MouseThreshold1' '0' 'String'
Set-RegValue 'HKCU:\Control Panel\Mouse' 'MouseThreshold2' '0' 'String'
Set-RegValue 'HKCU:\Control Panel\Mouse' 'MouseSensitivity' '10' 'String'
Set-RegValue 'HKCU:\Control Panel\Accessibility\StickyKeys' 'Flags' '506' 'String'
Set-RegValue 'HKCU:\Control Panel\Accessibility\Keyboard Response' 'Flags' '122' 'String'
Set-RegValue 'HKCU:\Control Panel\Accessibility\ToggleKeys' 'Flags' '58' 'String'

Write-Step 'Auto re-apply at logon'
if (-not $WhatIf) {
    try {
        $target = Join-Path $dataDir 'Gaming-Profile.ps1'
        if ($PSCommandPath -and ($PSCommandPath -ne $target)) { Copy-Item -LiteralPath $PSCommandPath -Destination $target -Force }
        $u = "$env:USERDOMAIN\$env:USERNAME"
        $agg = if ($Aggressive) { '-Aggressive' } else { '' }
        $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$target`" -Silent -SkipBackup $agg"
        $t = New-ScheduledTaskTrigger -AtLogOn -User $u
        $t.Delay = 'PT45S'
        $p = New-ScheduledTaskPrincipal -UserId $u -LogonType Interactive -RunLevel Highest
        $s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
        Register-ScheduledTask -TaskName 'Kpekpes Reapply' -Action $a -Trigger $t -Principal $p -Settings $s -Force -ErrorAction Stop | Out-Null
        Add-Result 'Logon task registered' $true
    } catch { Add-Result 'Logon task registered' $false $_.Exception.Message }
}

Write-Step 'Final verification'
$finalScore = Invoke-VerifyChecks
Write-GuiSafe 'DONE' "$finalScore"
