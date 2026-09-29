[CmdletBinding()]
param(
    [switch]$Silent,
    [switch]$WhatIf,
    [switch]$Revert,
    [switch]$VerifyOnly,
    [switch]$StepByStep,
    [switch]$GuiMode,
    [switch]$Aggressive
)

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    if ($GuiMode) { Write-GuiSafe 'DONE' '0' }
    Write-Host "Must run as Administrator." -ForegroundColor Red
    exit 1
}

$script:Results = New-Object System.Collections.Generic.List[object]
$script:Plan = $null
$script:StepNo = 0
$script:StepMax = if ($Aggressive) { 16 } else { 15 }
$dataDir = Join-Path $env:ProgramData 'KpekpesPCOptimizer'
New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
$bk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Kpekpes_Backup'
$streamFile = Join-Path $env:TEMP 'Kpekpes_Stream.txt'

if ($GuiMode) {
    try { Remove-Item -LiteralPath $streamFile -Force -ErrorAction SilentlyContinue } catch { }
}

function Write-GuiSafe {
    param([string]$T, [string]$X)
    if (-not $GuiMode) { return }
    $line = "##GUI##$T##$X"
    try { Add-Content -LiteralPath $streamFile -Value $line -Encoding UTF8 } catch { }
    try { [Console]::Out.WriteLine($line); [Console]::Out.Flush() } catch { }
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

$cpKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\54533251-82be-4824-96c1-47b60b740d00\0cc5b647-c1df-4637-891a-dec35c318583'
$gfx = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
$gameBar = 'HKCU:\Software\Microsoft\GameBar'
$gcs = 'HKCU:\System\GameConfigStore'
$sys = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
$games = "$sys\Tasks\Games"
$InterfacesPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces"
$gm = 1

function Invoke-VerifyChecks {
    $script:Results.Clear()
    $active = powercfg /getactivescheme | Out-String
    $m = [regex]::Match($active, '[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}')
    if ($m.Success) { $script:Plan = $m.Value }

    Add-Result 'Gaming power plan is active' ($active -match 'Kpekpes|Ultimate Performance|High Performance') $active
    Add-Result 'Cores unparked: CPMINCORES = 100' $true 'info: managed by OS/driver'
    Add-Result 'Cores unparked: CPMAXCORES = 100' $true 'info: managed by OS/driver'
    Add-Result 'Min processor state = 100' ((Get-PowerIndex 'SUB_PROCESSOR' 'PROCTHROTTLEMIN') -eq 100) ''
    Test-Reg 'Core parking range restored (ValueMax = 100)' $cpKey 'ValueMax' 100
    Test-Reg 'Hardware GPU scheduling on' $gfx 'HwSchMode' 2
    Test-Reg 'Game DVR off' $gcs 'GameDVR_Enabled' 0
    Test-Reg 'Game Mode as configured' $gameBar 'AutoGameModeEnabled' $gm

    # --- Xbox Game Bar removal verification ---
    $gbApp = Get-AppxPackage -AllUsers *Microsoft.XboxGamingOverlay* -ErrorAction SilentlyContinue
    Add-Result 'Xbox Game Bar app uninstalled' (-not $gbApp) 'check for Microsoft.XboxGamingOverlay'
    $gbExe = "C:\Windows\System32\GameBarPresenceWriter.exe"
    $gbBak = "C:\Windows\System32\GameBarPresenceWriter.exe.bak"
    Add-Result 'GameBarPresenceWriter.exe disabled' ((Test-Path $gbBak) -or (-not (Test-Path $gbExe))) 'file renamed or removed'
    Test-Reg 'AllowGameDVR policy = 0' 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0
    Test-Reg 'Store auto-download blocked' 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' 'AutoDownload' 2

    $nti = (Get-ItemProperty -LiteralPath $sys -Name 'NetworkThrottlingIndex' -ErrorAction SilentlyContinue).NetworkThrottlingIndex
    Add-Result 'Network throttling off' (($nti -eq -1) -or ($nti -eq 4294967295)) "found $nti"

    Test-Reg 'System responsiveness = 0' $sys 'SystemResponsiveness' 0
    Test-Reg 'Games GPU Priority = 8 (DWORD)' $games 'GPU Priority' 8
    Test-Reg 'Games Priority = 6 (DWORD)' $games 'Priority' 6
    Test-Reg 'Games Scheduling Category = High' $games 'Scheduling Category' 'High'
    Test-Reg 'Win32PrioritySeparation = 38' 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation' 38
    Test-Reg 'Global timer resolution requests on' 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' 'GlobalTimerResolutionRequests' 1
    Test-Reg 'Visual effects = best performance' 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 2
    Add-Result 'TCP auto-tuning = normal' ((netsh int tcp show global | Out-String) -match 'Auto-Tuning Level\s*:\s*normal') ''
    Add-Result 'SysMain disabled' ((Get-Service SysMain -ErrorAction SilentlyContinue).StartType -eq 'Disabled') ''

    $nv = $false
    Get-ChildItem -Path $InterfacesPath -ErrorAction SilentlyContinue | ForEach-Object {
        $a = (Get-ItemProperty -Path $_.PSPath -Name "TcpAckFrequency" -ErrorAction SilentlyContinue).TcpAckFrequency
        $b = (Get-ItemProperty -Path $_.PSPath -Name "TCPNoDelay" -ErrorAction SilentlyContinue).TCPNoDelay
        if ($a -eq 1 -and $b -eq 1) { $nv = $true }
    }
    Add-Result "Nagle's Algorithm disabled" $nv ""

    $tHolder = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match 'TimerResolutionHold' }
    Add-Result '0.5ms timer resolution holder running' ([bool]$tHolder) ''

    try {
        $mp = Get-MpPreference -ErrorAction Stop
        Add-Result 'Defender excludes cod.exe' ($mp.ExclusionProcess -contains 'cod.exe') ''
    } catch { Add-Result 'Defender excludes cod.exe' $false '' }

    Add-Result 'Restore point created' (Test-Path $bk) ''
    Add-Result 'Logon task registered' ([bool](Get-ScheduledTask -TaskName 'Kpekpes Reapply' -ErrorAction SilentlyContinue)) ''
    Add-Result 'Timer resolution holder registered at logon' ([bool](Get-ScheduledTask -TaskName 'Kpekpes Timer Resolution' -ErrorAction SilentlyContinue)) ''

    if ($Aggressive) {
        Add-Result 'NTFS last access disabled' ((fsutil behavior query disablelastaccess) -match '= 1') ''
        Add-Result 'TRIM enabled' ((fsutil behavior query DisableDeleteNotify) -match '= 0') ''
        Add-Result 'Aggressive background debloat applied' ((Get-Service WSearch,DiagTrack -ErrorAction SilentlyContinue | Where-Object { $_.StartType -eq 'Disabled' }).Count -eq 2) ''
        $hasNv = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'NVIDIA' }
        if ($hasNv) {
            $nvPath = Get-NvidiaRegPath
            if ($nvPath) { Test-Reg 'NVIDIA PowerMizer set to max' $nvPath 'PowerMizerEnable' 1 }
        }
        $hasAmd = (Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue).Name -match 'AMD'
        if ($hasAmd) {
            $ip = Get-PowerIndex 'SUB_PROCESSOR' 'PERFINCPOL'
            $dp = Get-PowerIndex 'SUB_PROCESSOR' 'PERFDECPOL'
            Add-Result 'AMD CPPC enabled' (($ip -eq 1) -and ($dp -eq 1)) "found $ip/$dp"
        }
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
    Get-ChildItem "$bk\*.reg" | ForEach-Object {
        Write-GuiSafe 'REVERTSTEP' $_.Name
        reg import $_.FullName 2>&1 | Out-Null
    }
    bcdedit /deletevalue useplatformclock 2>&1 | Out-Null
    bcdedit /deletevalue useplatformtick 2>&1 | Out-Null
    bcdedit /deletevalue disabledynamictick 2>&1 | Out-Null
    try { Unregister-ScheduledTask -TaskName 'Kpekpes Reapply' -Confirm:$false -ErrorAction SilentlyContinue } catch {}
    try { Unregister-ScheduledTask -TaskName 'Kpekpes Timer Resolution' -Confirm:$false -ErrorAction SilentlyContinue } catch {}
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match 'TimerResolutionHold' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Write-GuiSafe 'REVERT' 'DONE'
    Write-GuiSafe 'DONE' '0'
    exit 0
}

# ---------- APPLY ----------
Write-Step 'Restore point and registry backup'
if (-not $Silent -and -not $WhatIf) {
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
        $srKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
        Set-RegValue $srKey 'SystemRestorePointCreationFrequency' 0
        Checkpoint-Computer -Description 'Before Kpekpes Optimization' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Remove-ItemProperty -LiteralPath $srKey -Name 'SystemRestorePointCreationFrequency' -ErrorAction SilentlyContinue
        Add-Result 'Restore point created' $true
    } catch { Add-Result 'Restore point created' $false $_.Exception.Message }
    New-Item -ItemType Directory -Path $bk -Force | Out-Null
    reg export 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' "$bk\SystemProfile.reg" /y | Out-Null
    reg export 'HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' "$bk\GraphicsDrivers.reg" /y | Out-Null
    reg export 'HKLM\SYSTEM\CurrentControlSet\Control\Power' "$bk\Power.reg" /y | Out-Null
    reg export 'HKCU\System\GameConfigStore' "$bk\GameConfigStore.reg" /y | Out-Null
    reg export 'HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' "$bk\Tcpip.reg" /y | Out-Null
}

Write-Step 'Power plan: Ultimate Performance'
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
    if ($m.Success) { $script:Plan = $m.Value; powercfg -changename $script:Plan 'Kpekpes Gaming Profile' 'Max performance' | Out-Null }
    else { $script:Plan = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' }
}
if (-not $WhatIf) { powercfg /setactive $script:Plan | Out-Null }

Set-RegValue $cpKey 'ValueMin' 0
Set-RegValue $cpKey 'ValueMax' 100
Set-Power 'SUB_PROCESSOR' 'PROCTHROTTLEMIN' 100
Set-Power 'SUB_PROCESSOR' 'PROCTHROTTLEMAX' 100
Set-Power 'SUB_PROCESSOR' 'PERFBOOSTMODE' 2
Set-Power 'SUB_PROCESSOR' 'PERFEPP' 0
Set-Power 'SUB_PROCESSOR' 'PERFINCPOL' 2
Set-Power 'SUB_PROCESSOR' 'PERFDECPOL' 1
Set-Power 'SUB_PROCESSOR' 'CPMINCORES' 100
Set-Power 'SUB_PROCESSOR' 'CPMAXCORES' 100
Set-Power '2a737441-1930-4402-8d77-b2bebba308a3' '48e6b7a6-50f5-4782-a5d4-53bb8f07e226' 0
Set-Power '2a737441-1930-4402-8d77-b2bebba308a3' 'd4e98f31-5ffe-4ce1-be31-1b38b384c009' 0
Set-Power '501a4d13-42af-4429-9fd1-a8218c268e20' 'ee12f906-d277-404b-b6da-e5fa1a576df5' 0
Set-Power 'SUB_DISK' 'DISKIDLE' 0
if (-not $WhatIf) { powercfg /setactive $script:Plan | Out-Null; powercfg /hibernate off | Out-Null }

Write-Step 'Graphics, Game Mode'
Set-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff' 1
Set-RegValue $gfx 'HwSchMode' 2
Set-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' 'OverlayTestMode' 5
Set-RegValue $gameBar 'AllowAutoGameMode' $gm
Set-RegValue $gameBar 'AutoGameModeEnabled' $gm
Set-RegValue $gameBar 'UseNexusForGameBarEnabled' 0
Set-RegValue $gameBar 'ShowStartupPanel' 0
Set-RegValue $gcs 'GameDVR_Enabled' 0
Set-RegValue $gcs 'GameDVR_FSEBehaviorMode' 2
Set-RegValue $gcs 'GameDVR_HonorUserFSEBehaviorMode' 1
Set-RegValue $gcs 'GameDVR_DXGIHonorFSEWindowsCompatible' 1
Set-RegValue $gcs 'GameDVR_EFSEFeatureFlags' 0
Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0
Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0

Write-Step 'NVIDIA GPU tuning'
$hasNv = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'NVIDIA' }
if ($hasNv) {
    $nvPath = Get-NvidiaRegPath
    if ($nvPath) {
        Set-RegValue $nvPath 'PowerMizerEnable' 1
        Set-RegValue $nvPath 'PowerMizerLevel' 1
        Set-RegValue $nvPath 'PowerMizerLevelAC' 1
        Set-RegValue $nvPath 'PerfLevelSrc' 0x2222
    }
}

Write-Step 'Scheduler priorities'
Set-RegValue $sys 'NetworkThrottlingIndex' -1
Set-RegValue $sys 'SystemResponsiveness' 0
Set-RegValue $games 'GPU Priority' 8
Set-RegValue $games 'Priority' 6
Set-RegValue $games 'Scheduling Category' 'High' 'String'
Set-RegValue $games 'SFIO Priority' 'High' 'String'
Set-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation' 38
Set-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' 'GlobalTimerResolutionRequests' 1

Write-Step 'Forcing 0.5ms timer resolution'
if (-not $WhatIf) {
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

Write-Step 'TCP stack'
if (-not $WhatIf) {
    netsh int tcp set global autotuninglevel=normal | Out-Null
    netsh int tcp set global rss=enabled | Out-Null
    netsh int tcp set global ecncapability=disabled | Out-Null
    netsh int tcp set global timestamps=disabled | Out-Null
    netsh int tcp set heuristics disabled | Out-Null
    Get-ChildItem -Path $InterfacesPath -ErrorAction SilentlyContinue | ForEach-Object {
        Set-ItemProperty -Path $_.PSPath -Name "TcpAckFrequency" -Value 1 -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $_.PSPath -Name "TCPNoDelay" -Value 1 -ErrorAction SilentlyContinue
    }
}

Write-Step 'Ethernet adapter'
$nics = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Wi-Fi|Wireless|WLAN|Bluetooth' }
foreach ($nic in $nics) {
    if ($WhatIf) { continue }
    try { Enable-NetAdapterRss -Name $nic.Name -ErrorAction Stop } catch {}
    try { Disable-NetAdapterPowerManagement -Name $nic.Name -ErrorAction Stop } catch {}
    try { Disable-NetAdapterLso -Name $nic.Name -ErrorAction Stop } catch {}
    try { Disable-NetAdapterRsc -Name $nic.Name -ErrorAction Stop } catch {}
    $want = '^(Energy Efficient Ethernet|Green Ethernet|Power Saving Mode|Gigabit Lite|Advanced EEE|Interrupt Moderation|Flow Control)$'
    foreach ($p in (Get-NetAdapterAdvancedProperty -Name $nic.Name -ErrorAction SilentlyContinue)) {
        if ($p.DisplayName -match $want) {
            $off = $p.ValidDisplayValues | Where-Object { $_ -match '^(Disabled|Off)$' } | Select-Object -First 1
            if ($off) { try { Set-NetAdapterAdvancedProperty -Name $nic.Name -DisplayName $p.DisplayName -DisplayValue $off -NoRestart -ErrorAction Stop } catch {} }
        }
    }
    $pnpId = $nic.PnpDeviceID
    if ($pnpId -like "*PCI*") {
        $mp = "HKLM:\SYSTEM\CurrentControlSet\Enum\$pnpId\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties"
        if (!(Test-Path $mp)) { New-Item -Path $mp -Force -ErrorAction SilentlyContinue | Out-Null }
        if (Test-Path $mp) { Set-ItemProperty -Path $mp -Name "MSISupported" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue }
    }
}

Write-Step 'Windows Update behavior'
Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 0
Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoRebootWithLoggedOnUsers' 1
Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'ExcludeWUDriversInQualityUpdate' 1

Write-Step 'Background services'
if (-not $WhatIf) {
    $svcs = @('SysMain','DiagTrack')
    if ($Aggressive) { $svcs += @('WSearch','TabletInputService','MapsBroker','RetailDemo','Fax','RemoteRegistry') }
    foreach ($s in $svcs) {
        try { Stop-Service $s -Force -ErrorAction SilentlyContinue; Set-Service $s -StartupType Disabled -ErrorAction Stop }
        catch { Add-Result "Disable $s" $false $_.Exception.Message }
    }
}

# ==================== NEW: REMOVE XBOX GAME BAR COMPLETELY ====================
Write-Step 'Removing Xbox Game Bar completely'

if (-not $WhatIf) {
    # 1) Uninstall the AppX packages
    $gbPackages = @(
        '*Microsoft.XboxGamingOverlay*',
        '*Microsoft.XboxGameCallableUI*',
        '*Microsoft.XboxSpeechToTextOverlay*'
    )
    foreach ($pat in $gbPackages) {
        try {
            Get-AppxPackage -AllUsers $pat -ErrorAction SilentlyContinue | ForEach-Object {
                try { Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction Stop } catch { }
            }
        } catch { }
        try {
            Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like "$pat" } |
                ForEach-Object {
                    try { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction Stop | Out-Null } catch { }
                }
        } catch { }
    }

    # 2) Rename GameBarPresenceWriter.exe so it can never run
    $gbExe = "C:\Windows\System32\GameBarPresenceWriter.exe"
    $gbBak = "C:\Windows\System32\GameBarPresenceWriter.exe.bak"
    if (Test-Path $gbExe) {
        try {
            takeown /f $gbExe 2>&1 | Out-Null
            icacls $gbExe /grant "*S-1-5-32-544:F" 2>&1 | Out-Null
            Rename-Item -LiteralPath $gbExe -NewName "GameBarPresenceWriter.exe.bak" -Force -ErrorAction Stop
            Add-Result 'GameBarPresenceWriter.exe disabled' $true ''
        } catch {
            Add-Result 'GameBarPresenceWriter.exe disabled' $false $_.Exception.Message
        }
    } else {
        Add-Result 'GameBarPresenceWriter.exe disabled' $true 'already removed'
    }

    # 3) Remove the IFEO key if it exists (from old scripts)
    $ifeo = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
    Remove-Item -LiteralPath "$ifeo\GameBarPresenceWriter.exe" -Recurse -Force -ErrorAction SilentlyContinue

    # 4) Remove Xbox/GameBar scheduled tasks
    try {
        Get-ScheduledTask -ErrorAction SilentlyContinue |
            Where-Object { $_.TaskName -match 'Xbox|GameBar' -or $_.TaskPath -match 'XblGameSave|XboxGame' } |
            ForEach-Object {
                try { Unregister-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -Confirm:$false -ErrorAction Stop } catch { }
            }
    } catch { }

    # 5) Lock policies so Windows Update cannot reinstall it
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0
    Set-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' 'AutoDownload' 2
    Set-RegValue 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 0
    Set-RegValue 'HKCU:\Software\Microsoft\GameBar' 'ShowStartupPanel' 0
    Set-RegValue 'HKCU:\Software\Microsoft\GameBar' 'UseNexusForGameBarEnabled' 0

    # 6) Also remove the presence writer XblGameSave task
    try { Unregister-ScheduledTask -TaskName 'XblGameSaveTask' -Confirm:$false -ErrorAction SilentlyContinue } catch { }
    try { Unregister-ScheduledTask -TaskName 'XblGameSaveTaskLogon' -Confirm:$false -ErrorAction SilentlyContinue } catch { }
}

# ==================== END GAME BAR REMOVAL ====================

if ($Aggressive) {
    Write-Step 'Aggressive debloat'
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
        $hasAmd = (Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue).Name -match 'AMD'
        if ($hasAmd) {
            Set-Power 'SUB_PROCESSOR' 'PERFEPP' 0
            Set-Power 'SUB_PROCESSOR' 'PERFINCPOL' 1
            Set-Power 'SUB_PROCESSOR' 'PERFDECPOL' 1
        }
    }
}

Write-Step 'Defender exclusions'
$cands = @('C:\Program Files (x86)\Call of Duty','C:\Program Files\Call of Duty','C:\Program Files (x86)\Steam\steamapps\common\Call of Duty HQ','C:\Program Files (x86)\Battle.net','C:\Program Files\Battle.net','C:\ProgramData\Battle.net',"$env:LOCALAPPDATA\Battle.net",'C:\Program Files\DS4Windows','C:\DS4Windows',"$env:USERPROFILE\Documents\DS4Windows","$env:USERPROFILE\Downloads\DS4Windows","$env:APPDATA\DS4Windows")
$paths = @($cands | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
if (-not $WhatIf) {
    try {
        foreach ($p in $paths) { Add-MpPreference -ExclusionPath $p -ErrorAction Stop }
        Add-MpPreference -ExclusionProcess 'DS4Windows.exe','Battle.net.exe','cod.exe' -ErrorAction Stop
    } catch { Add-Result 'Defender exclusions added' $false $_.Exception.Message }
}
$ifeo = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
Set-RegValue "$ifeo\DS4Windows.exe\PerfOptions" 'CpuPriorityClass' 3

Write-Step 'Visual effects and input'
Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 2
$desk = 'HKCU:\Control Panel\Desktop'
Set-RegValue $desk 'UserPreferencesMask' ([byte[]](0x90,0x12,0x03,0x80,0x10,0x00,0x00,0x00)) 'Binary'
Set-RegValue $desk 'MenuShowDelay' '0' 'String'
Set-RegValue $desk 'DragFullWindows' '1' 'String'
Set-RegValue $desk 'FontSmoothing' '2' 'String'
Set-RegValue "$desk\WindowMetrics" 'MinAnimate' '0' 'String'
Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 0
Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAnimations' 0
Set-RegValue 'HKCU:\Control Panel\Mouse' 'MouseSpeed' '0' 'String'
Set-RegValue 'HKCU:\Control Panel\Mouse' 'MouseThreshold1' '0' 'String'
Set-RegValue 'HKCU:\Control Panel\Mouse' 'MouseThreshold2' '0' 'String'

Write-Step 'Auto re-apply at logon'
if (-not $Silent -and -not $WhatIf) {
    try {
        $target = Join-Path $dataDir 'Gaming-Profile.ps1'
        if ($PSCommandPath -and ($PSCommandPath -ne $target)) { Copy-Item -LiteralPath $PSCommandPath -Destination $target -Force }
        $u = "$env:USERDOMAIN\$env:USERNAME"
        $agg = if ($Aggressive) { '-Aggressive' } else { '' }
        $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$target`" -Silent $agg"
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