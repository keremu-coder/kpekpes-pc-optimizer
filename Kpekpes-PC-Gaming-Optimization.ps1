#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$DebugLog = Join-Path $env:TEMP 'Kpekpes_GUI_Debug.log'
function WLog { param([string]$m) try { "$(Get-Date -Format 'HH:mm:ss.fff') | $m" | Out-File -FilePath $DebugLog -Append -Encoding UTF8 } catch {} }
Remove-Item $DebugLog -ErrorAction SilentlyContinue
WLog '=== GUI starting ==='

try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        WLog 'Relaunching elevated...'
        Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Normal -File `"$PSCommandPath`"" -Verb RunAs
        exit
    }
    WLog 'Running elevated.'

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $ScriptDir  = Split-Path -Parent $PSCommandPath
    $EnginePath = Join-Path $ScriptDir 'Gaming-Profile.ps1'
    $StreamFile = Join-Path $env:TEMP 'Kpekpes_Stream.txt'
    WLog "ScriptDir=$ScriptDir"
    WLog "EnginePath=$EnginePath"
    WLog "StreamFile=$StreamFile"

    if (-not (Test-Path $EnginePath)) {
        [System.Windows.Forms.MessageBox]::Show("Gaming-Profile.ps1 not found in this folder.", "Missing File", 'OK', 'Error')
        exit
    }

    $bg      = [System.Drawing.Color]::FromArgb(18, 18, 24)
    $panelBg = [System.Drawing.Color]::FromArgb(28, 28, 36)
    $accent  = [System.Drawing.Color]::FromArgb(0, 200, 120)
    $accent2 = [System.Drawing.Color]::FromArgb(230, 60, 60)
    $fg      = [System.Drawing.Color]::White
    $fgDim   = [System.Drawing.Color]::FromArgb(160, 160, 170)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Kpekpes PC Gaming Optimization'
    $form.Size = New-Object System.Drawing.Size(720, 600)
    $form.StartPosition = 'CenterScreen'
    $form.BackColor = $bg
    $form.ForeColor = $fg
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false

    $title = New-Object System.Windows.Forms.Label
    $title.Text = 'Kpekpes PC Gaming Optimization'
    $title.Font = New-Object System.Drawing.Font('Segoe UI', 20, [System.Drawing.FontStyle]::Bold)
    $title.ForeColor = $fg
    $title.AutoSize = $true
    $title.Location = New-Object System.Drawing.Point(30, 25)
    $form.Controls.Add($title)

    $subtitle = New-Object System.Windows.Forms.Label
    $subtitle.Text = 'By Jesus Kpekpes — every change is checked and scored.'
    $subtitle.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $subtitle.ForeColor = $fgDim
    $subtitle.AutoSize = $true
    $subtitle.Location = New-Object System.Drawing.Point(32, 60)
    $form.Controls.Add($subtitle)

    $chkAggressive = New-Object System.Windows.Forms.CheckBox
    $chkAggressive.Text = 'Aggressive Low-End Mode (disables Windows Search + bloat services, enables TRIM/NTFS tweaks)'
    $chkAggressive.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $chkAggressive.ForeColor = [System.Drawing.Color]::FromArgb(255, 200, 100)
    $chkAggressive.Size = New-Object System.Drawing.Size(660, 20)
    $chkAggressive.Location = New-Object System.Drawing.Point(32, 85)
    $form.Controls.Add($chkAggressive)

    $menuPanel = New-Object System.Windows.Forms.Panel
    $menuPanel.Location = New-Object System.Drawing.Point(30, 115)
    $menuPanel.Size = New-Object System.Drawing.Size(660, 420)
    $menuPanel.BackColor = $bg
    $form.Controls.Add($menuPanel)

    function New-MenuButton {
        param([string]$N, [string]$T, [string]$D, [int]$Y, [System.Drawing.Color]$C)
        $b = New-Object System.Windows.Forms.Button
        $b.Size = New-Object System.Drawing.Size(660, 85)
        $b.Location = New-Object System.Drawing.Point(0, $Y)
        $b.BackColor = $panelBg
        $b.ForeColor = $fg
        $b.FlatStyle = 'Flat'
        $b.FlatAppearance.BorderColor = $C
        $b.FlatAppearance.BorderSize = 1
        $b.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(38, 38, 48)
        $b.TextAlign = 'MiddleLeft'
        $b.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
        $b.Text = "   $N.  $T`n        "
        $b.Cursor = 'Hand'
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $D
        $l.Font = New-Object System.Drawing.Font('Segoe UI', 10)
        $l.ForeColor = $fgDim
        $l.AutoSize = $false
        $l.Size = New-Object System.Drawing.Size(580, 20)
        $l.Location = New-Object System.Drawing.Point(70, $($Y + 52))
        $l.BackColor = [System.Drawing.Color]::Transparent
        $l.Parent = $menuPanel
        return $b
    }

    $btn1 = New-MenuButton '1' 'Full Optimize Run' 'Applies every verified tweak. Shows Before -> After score.' 0 $accent
    $btn2 = New-MenuButton '2' 'Verify Current State' 'Read-only. Changes nothing. Shows your current optimization score.' 100 ([System.Drawing.Color]::FromArgb(60, 150, 230))
    $btn3 = New-MenuButton '3' 'Revert to Original' 'Undoes everything using the backup made on your first run.' 200 $accent2
    $btn4 = New-MenuButton '4' 'Step-by-Step (Guided)' 'Same as Full Optimize, but you click Continue after each step.' 300 ([System.Drawing.Color]::FromArgb(200, 160, 60))
    $menuPanel.Controls.AddRange(@($btn1, $btn2, $btn3, $btn4))

    $runPanel = New-Object System.Windows.Forms.Panel
    $runPanel.Location = New-Object System.Drawing.Point(30, 115)
    $runPanel.Size = New-Object System.Drawing.Size(660, 420)
    $runPanel.BackColor = $bg
    $runPanel.Visible = $false
    $form.Controls.Add($runPanel)

    $runTitle = New-Object System.Windows.Forms.Label
    $runTitle.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
    $runTitle.ForeColor = $fg
    $runTitle.AutoSize = $true
    $runTitle.Location = New-Object System.Drawing.Point(0, 0)
    $runTitle.Text = 'Working...'
    $runPanel.Controls.Add($runTitle)

    $progressBar = New-Object System.Windows.Forms.ProgressBar
    $progressBar.Location = New-Object System.Drawing.Point(0, 35)
    $progressBar.Size = New-Object System.Drawing.Size(520, 24)
    $progressBar.Style = 'Marquee'
    $progressBar.MarqueeAnimationSpeed = 30
    $runPanel.Controls.Add($progressBar)

    $percentLabel = New-Object System.Windows.Forms.Label
    $percentLabel.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
    $percentLabel.ForeColor = $accent
    $percentLabel.AutoSize = $true
    $percentLabel.Location = New-Object System.Drawing.Point(540, 33)
    $percentLabel.Text = ''
    $runPanel.Controls.Add($percentLabel)

    $logBox = New-Object System.Windows.Forms.ListBox
    $logBox.Location = New-Object System.Drawing.Point(0, 70)
    $logBox.Size = New-Object System.Drawing.Size(660, 250)
    $logBox.BackColor = $panelBg
    $logBox.ForeColor = $fg
    $logBox.Font = New-Object System.Drawing.Font('Consolas', 9.5)
    $logBox.BorderStyle = 'FixedSingle'
    $runPanel.Controls.Add($logBox)

    $scoreLabel = New-Object System.Windows.Forms.Label
    $scoreLabel.Font = New-Object System.Drawing.Font('Segoe UI', 28, [System.Drawing.FontStyle]::Bold)
    $scoreLabel.ForeColor = $accent
    $scoreLabel.AutoSize = $true
    $scoreLabel.Location = New-Object System.Drawing.Point(0, 330)
    $scoreLabel.Text = ''
    $runPanel.Controls.Add($scoreLabel)

    $backBtn = New-Object System.Windows.Forms.Button
    $backBtn.Text = '<- Back to Menu'
    $backBtn.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $backBtn.Size = New-Object System.Drawing.Size(150, 32)
    $backBtn.Location = New-Object System.Drawing.Point(0, 380)
    $backBtn.BackColor = $panelBg
    $backBtn.ForeColor = $fg
    $backBtn.FlatStyle = 'Flat'
    $runPanel.Controls.Add($backBtn)

    $script:proc = $null
    $script:beforeScore = $null
    $script:currentPhase = ''
    $script:lastReadLine = 0
    $script:pendingExit = $null

    function Show-Menu {
        $runPanel.Visible = $false
        $menuPanel.Visible = $true
        $chkAggressive.Visible = $true
        $logBox.Items.Clear()
        $percentLabel.Text = ''
        $scoreLabel.Text = ''
    }
    $backBtn.Add_Click({ Show-Menu })

    function Add-Log([string]$t) {
        $logBox.Items.Add($t) | Out-Null
        $logBox.TopIndex = $logBox.Items.Count - 1
    }

    function ProcessLine([string]$line, [string]$phase) {
        if ($line -notmatch '^##GUI##(\w+)##(.*)$') { return }
        $type = $Matches[1]; $payload = $Matches[2]
        switch ($type) {
            'STEP' {
                $parts = $payload -split '\|', 4
                if ($parts.Count -ge 4) {
                    $percentLabel.Text = "$($parts[2])%"
                    Add-Log "-> $($parts[3])"
                }
            }
            'CHECK' {
                $parts = $payload -split '\|', 5
                if ($parts.Count -ge 5) {
                    $mark = if ($parts[3] -eq 'PASS') { '[OK]' } else { '[--]' }
                    Add-Log "  $mark $($parts[4])"
                }
            }
            'SCORE' {
                $parts = $payload -split '\|'
                $pct = $parts[2]
                if ($phase -eq 'before') {
                    $script:beforeScore = $pct
                    Add-Log ''; Add-Log "BEFORE: $pct%"
                } elseif ($phase -eq 'after') {
                    Add-Log ''; Add-Log "AFTER: $pct%"
                    if ($script:beforeScore) { $scoreLabel.Text = "$($script:beforeScore)%  ->  $pct%" }
                    else { $scoreLabel.Text = "$pct%" }
                } else {
                    $scoreLabel.Text = "$pct%"
                }
            }
            'REVERTSTEP' { Add-Log "-> Restoring $payload" }
            'REVERT' { if ($payload -eq 'DONE') { Add-Log ''; Add-Log 'Revert complete. Restart to finish.' } }
            'DONE' { Add-Log ''; Add-Log 'Finished.' }
        }
    }

    function Read-NewLines {
        if (-not (Test-Path $StreamFile)) { return }
        try {
            $lines = @(Get-Content -LiteralPath $StreamFile -ErrorAction SilentlyContinue)
            if ($lines.Count -gt $script:lastReadLine) {
                for ($i = $script:lastReadLine; $i -lt $lines.Count; $i++) {
                    try { ProcessLine $lines[$i] $script:currentPhase } catch { WLog "ProcessLine error: $($_.Exception.Message)" }
                }
                $script:lastReadLine = $lines.Count
            }
        } catch { WLog "Read-NewLines error: $($_.Exception.Message)" }
    }

    $script:pollTimer = New-Object System.Windows.Forms.Timer
    $script:pollTimer.Interval = 300
    $script:pollTimer.Add_Tick({
        try {
            Read-NewLines
            if ($script:proc -and $script:proc.HasExited) {
                WLog "Engine exited. Code=$($script:proc.ExitCode)"
                $script:pollTimer.Stop()
                # Final drain - give the file a moment
                Start-Sleep -Milliseconds 250
                Read-NewLines
                $cb = $script:pendingExit
                $script:pendingExit = $null
                if ($cb) { try { & $cb } catch { WLog "OnExit callback error: $($_.Exception.Message)" } }
            }
        } catch { WLog "Timer tick error: $($_.Exception.Message)" }
    })

    function Start-Engine {
        param([string]$EngineArgs, [scriptblock]$OnExit)

        if (Test-Path $StreamFile) { Remove-Item -LiteralPath $StreamFile -Force -ErrorAction SilentlyContinue }
        $script:lastReadLine = 0
        $script:pendingExit = $OnExit
        WLog "Start-Engine: $EngineArgs"

        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = 'powershell.exe'
            $argString = "-NoProfile -ExecutionPolicy Bypass -File `"$EnginePath`" $EngineArgs"
            $psi.Arguments = $argString
            $psi.UseShellExecute = $true
            $psi.WindowStyle = 'Hidden'
            # NO redirection - use the file for output only
            $p = [System.Diagnostics.Process]::Start($psi)
            $script:proc = $p
            WLog "Engine process started: PID=$($p.Id)"
            $script:pollTimer.Start()
        } catch {
            WLog "Start-Engine error: $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show("Failed to start engine:`n`n$($_.Exception.Message)", 'Engine Error', 'OK', 'Error')
        }
    }

    $btn2.Add_Click({
        try {
            WLog 'Button 2 (Verify) clicked.'
            $menuPanel.Visible = $false
            $chkAggressive.Visible = $false
            $runPanel.Visible = $true
            $runTitle.Text = 'Verifying current PC state (read-only)...'
            $progressBar.Style = 'Marquee'
            $script:currentPhase = 'current'
            $agg = if ($chkAggressive.Checked) { '-Aggressive' } else { '' }
            Start-Engine -EngineArgs "-VerifyOnly -GuiMode $agg" `
                -OnExit { $runTitle.Text = 'Verification complete.'; $progressBar.Style = 'Continuous'; $progressBar.Value = 100 }
        } catch { WLog "Button 2 error: $($_.Exception.Message)" }
    })

    $btn3.Add_Click({
        try {
            WLog 'Button 3 (Revert) clicked.'
            $bkPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Kpekpes_Backup'
            if (-not (Test-Path $bkPath)) {
                [System.Windows.Forms.MessageBox]::Show("No backup folder found. Run 'Full Optimize Run' first.", 'Revert Unavailable', 'OK', 'Warning')
                return
            }
            $c = [System.Windows.Forms.MessageBox]::Show("Restore PC settings from backup?", 'Confirm Revert', 'YesNo', 'Warning')
            if ($c -ne 'Yes') { return }
            $menuPanel.Visible = $false
            $chkAggressive.Visible = $false
            $runPanel.Visible = $true
            $runTitle.Text = 'Reverting...'
            $progressBar.Style = 'Marquee'
            $script:currentPhase = 'revert'
            Start-Engine -EngineArgs '-Revert -GuiMode' `
                -OnExit { $runTitle.Text = 'Revert finished.'; $progressBar.Style = 'Continuous'; $progressBar.Value = 100 }
        } catch { WLog "Button 3 error: $($_.Exception.Message)" }
    })

    $btn1.Add_Click({
        try {
            WLog 'Button 1 (Full Optimize) clicked.'
            $menuPanel.Visible = $false
            $chkAggressive.Visible = $false
            $runPanel.Visible = $true
            $progressBar.Style = 'Marquee'
            $script:beforeScore = $null
            $runTitle.Text = 'Step 1 of 3: checking current state...'
            $agg = if ($chkAggressive.Checked) { '-Aggressive' } else { '' }

            $script:currentPhase = 'before'
            Start-Engine -EngineArgs "-VerifyOnly -GuiMode $agg" `
                -OnExit {
                    WLog 'Stage 1 done, starting stage 2.'
                    $runTitle.Text = 'Step 2 of 3: applying optimizations...'
                    $script:currentPhase = 'apply'
                    Start-Engine -EngineArgs "-GuiMode -Silent $agg" `
                        -OnExit {
                            WLog 'Stage 2 done, starting stage 3.'
                            $runTitle.Text = 'Step 3 of 3: confirming results...'
                            $script:currentPhase = 'after'
                            Start-Engine -EngineArgs "-VerifyOnly -GuiMode $agg" `
                                -OnExit { WLog 'Stage 3 done.'; $runTitle.Text = 'Done. Restart your PC.'; $progressBar.Style = 'Continuous'; $progressBar.Value = 100 }
                        }
                }
        } catch { WLog "Button 1 error: $($_.Exception.Message)" }
    })

    $btn4.Add_Click({
        try {
            WLog 'Button 4 (Step-by-Step) clicked.'
            $menuPanel.Visible = $false
            $chkAggressive.Visible = $false
            $runPanel.Visible = $true
            $runTitle.Text = 'Guided run...'
            $progressBar.Style = 'Marquee'
            $script:currentPhase = 'stepbystep'
            $agg = if ($chkAggressive.Checked) { '-Aggressive' } else { '' }
            Start-Engine -EngineArgs "-GuiMode -StepByStep $agg" `
                -OnExit { $runTitle.Text = 'Done.'; $progressBar.Style = 'Continuous'; $progressBar.Value = 100 }
        } catch { WLog "Button 4 error: $($_.Exception.Message)" }
    })

    $form.Add_FormClosing({
        try { $script:pollTimer.Stop() } catch {}
        if ($script:proc -and -not $script:proc.HasExited) { try { $script:proc.Kill() } catch {} }
    })

    WLog 'Showing form.'
    [System.Windows.Forms.Application]::Run($form)
    WLog '=== GUI closed ==='

} catch {
    WLog "FATAL: $($_.Exception.Message)"
    WLog "Stack: $($_.ScriptStackTrace)"
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show("Error:`n`n$($_.Exception.Message)`n`nLog: $DebugLog", 'Kpekpes Error', 'OK', 'Error') | Out-Null
}