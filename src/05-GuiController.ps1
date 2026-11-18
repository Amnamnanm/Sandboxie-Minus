# ===Container Cards n UI State
function Enable-UI([bool]$v) {
    # Both TabPages and custom top-bar buttons ($script:NavMap from 04-GuiThemeAndTabs.ps1)
    # must be toggled because native TabControl headers are hidden. Redirect away from
    # disabled profile tabs so the user isn't stranded on an unusable page
    foreach ($pt in $script:ProfileOnlyTabs) { $pt.Enabled = $v }
    foreach ($kv in $script:NavMap.GetEnumerator()) {
        if ($script:ProfileOnlyTabs.Contains($kv.Value)) { $kv.Key.Enabled = $v }
    }
    if (-not $v -and $script:ProfileOnlyTabs.Contains($script:Tabs.SelectedTab)) { Switch-NavTab $tabContainers }
    foreach ($b in $script:ActBtns) { $b.Enabled = $v }
}
function Update-SelectedCardVisual {
    if (-not $script:CardsFlow) { return }
    foreach ($ctrl in $script:CardsFlow.Controls) {
        if ($ctrl -is [Windows.Forms.Panel] -and $null -ne $ctrl.Tag) {
            $isSel = ([int]$ctrl.Tag -eq $script:SelectedCardIdx)
            $ctrl.BackColor = if ($isSel) { $script:Theme.Surface2 } else { $script:Theme.Surface }
            $ctrl.Invalidate()
        }
    }
}
function Select-ContainerCard([int]$idx) {
    # $script:Loading guards against saving half-cleared UI controls during Refresh-List
    # Flush edits to the outgoing profile ($script:Cur) before loading the newly clicked card
    if ($script:Loading -or $idx -lt 0 -or $idx -ge $script:Profiles.Count) { return }
    if ($script:Cur) { Save-UiToProfile }
    $script:SelectedCardIdx = $idx
    Update-SelectedCardVisual
    Select-Profile $script:Profiles[$idx]
}
function Add-ContainerCard($p, [int]$idx) {
    $card = New-Object Windows.Forms.Panel
    # 'KeepStyle' tells Set-DarkTheme not to overwrite custom card colors
    # .Tag stores the profile index across the card and all child controls for hit-testing
    $card.Name = 'KeepStyle'; $card.Size = (Sz 156 172); $card.Margin = New-Object Windows.Forms.Padding(8)
    $card.Tag = $idx; $card.Cursor = [Windows.Forms.Cursors]::Hand
    $card.BackColor = if ($idx -eq $script:SelectedCardIdx) { $script:Theme.Surface2 } else { $script:Theme.Surface }
    $card.add_Paint({
        param($s, $e)
        $isSel = ([int]$s.Tag -eq $script:SelectedCardIdx)
        $col = if ($isSel) { $script:Theme.Accent } else { $script:Theme.Border }
        $pw = if ($isSel) { 2 } else { 1 }
        $pen = New-Object Drawing.Pen($col, $pw)
        try { $e.Graphics.DrawRectangle($pen, 1, 1, $s.Width - 3, $s.Height - 3) } finally { $pen.Dispose() }
    })
    $pic = New-Object Windows.Forms.PictureBox
    $pic.Location = (Pt 14 12); $pic.Size = (Sz 128 102); $pic.SizeMode = 'CenterImage'
    $pic.BackColor = [Drawing.Color]::Transparent; $pic.Tag = $idx; $pic.Cursor = [Windows.Forms.Cursors]::Hand
    $pic.Image = Get-ProfileCardImage $p
    $card.Controls.Add($pic)

    $btnImg = New-Object Windows.Forms.Button
    $btnImg.Name = 'KeepStyle'; $btnImg.Tag = $idx
    $btnImg.Text = 'Img'; $btnImg.Location = (Pt 102 90); $btnImg.Size = (Sz 40 24)
    $btnImg.Padding = New-Object Windows.Forms.Padding(0); $btnImg.TextAlign = 'MiddleCenter'
    $btnImg.Font = $script:FontSmall; $btnImg.FlatStyle = 'Flat'
    $btnImg.BackColor = $script:Theme.Bg; $btnImg.ForeColor = $script:Theme.Text
    $btnImg.FlatAppearance.BorderSize = 1; $btnImg.FlatAppearance.BorderColor = $script:Theme.Border
    $btnImg.FlatAppearance.MouseOverBackColor = $script:Theme.Accent; $btnImg.Cursor = [Windows.Forms.Cursors]::Hand
    $script:ImgTip.SetToolTip($btnImg, 'Left-click: choose custom icon | Right-click: reset to EXE icon')
    $card.Controls.Add($btnImg); $btnImg.BringToFront()

    $lblN = New-Object Windows.Forms.Label
    $lblN.Text = $p.Name; $lblN.Location = (Pt 8 120); $lblN.Size = (Sz 140 22)
    $lblN.TextAlign = 'MiddleCenter'; $lblN.AutoEllipsis = $true; $lblN.Font = $script:FontBold
    $lblN.ForeColor = $script:Theme.Text; $lblN.BackColor = [Drawing.Color]::Transparent; $lblN.Tag = $idx
    $card.Controls.Add($lblN)

    $isApp = (@($p.Applied.Paths).Count -or @($p.Applied.RegPaths).Count -or @($p.Applied.Devices).Count -or $p.Applied.Firewall -or $p.Applied.Loopback)
    $lblS = New-Object Windows.Forms.Label
    $lblS.Text = if ($isApp) { 'Applied' } else { 'Draft' }
    $lblS.Location = (Pt 8 144); $lblS.Size = (Sz 140 18); $lblS.TextAlign = 'MiddleCenter'
    $lblS.Font = $script:FontSmall; $lblS.BackColor = [Drawing.Color]::Transparent; $lblS.Tag = $idx
    $lblS.ForeColor = if ($isApp) { $script:Theme.AccentHov } else { $script:Theme.Muted }
    $card.Controls.Add($lblS)

    $onPick = { param($s, $e) Select-ContainerCard ([int]$s.Tag) }
    $onOpen = { param($s, $e) Select-ContainerCard ([int]$s.Tag); Switch-NavTab $tabGen }
    # winForms doesnt bubble child mouse clicks to parent Panels so bind every visible child.
    foreach ($hit in @($card, $pic, $lblN, $lblS)) {
        $hit.add_Click($onPick)
        $hit.add_DoubleClick($onOpen)
    }
    $btnImg.add_Click({ param($s, $e) Safe { Pick-ContainerIcon ([int]$s.Tag) } })
    $btnImg.add_MouseUp({ param($s, $e) if ($e.Button -eq 'Right') { Safe { Reset-ContainerIcon ([int]$s.Tag) } } })
    [void]$script:CardsFlow.Controls.Add($card)
}
function Set-CardImageByIndex([int]$idx) {
    if ($idx -lt 0 -or $idx -ge $script:Profiles.Count -or $idx -ge $script:CardsFlow.Controls.Count) { return }
    $cardCtrl = $script:CardsFlow.Controls[$idx]
    foreach ($ch in $cardCtrl.Controls) {
        if ($ch -is [Windows.Forms.PictureBox]) {
            # Dispose the previous bitmap after swapping to prevent GDI+ handle leaks
            $oldImg = $ch.Image
            $ch.Image = Get-ProfileCardImage $script:Profiles[$idx]
            if ($oldImg) { $oldImg.Dispose() }
        }
    }
}
function Pick-ContainerIcon([int]$idx) {
    if ($idx -lt 0 -or $idx -ge $script:Profiles.Count) { return }
    Select-ContainerCard $idx
    $ofd = New-Object Windows.Forms.OpenFileDialog
    $ofd.Filter = 'Images & Icons (*.png;*.jpg;*.jpeg;*.ico;*.exe;*.bmp)|*.png;*.jpg;*.jpeg;*.ico;*.exe;*.bmp|All files|*.*'
    if ($ofd.ShowDialog($F) -eq 'OK') {
        $script:UiIcons[(Get-ContainerName $script:Profiles[$idx])] = $ofd.FileName
        Save-UiIcons
        Set-CardImageByIndex $idx
    }
}
function Reset-ContainerIcon([int]$idx) {
    if ($idx -lt 0 -or $idx -ge $script:Profiles.Count) { return }
    $k = Get-ContainerName $script:Profiles[$idx]
    if ($script:UiIcons.ContainsKey($k)) { $script:UiIcons.Remove($k); Save-UiIcons }
    Set-CardImageByIndex $idx
}
function Update-Status($p) {
    $np = @($p.Applied.Paths).Count; $nr = @($p.Applied.RegPaths).Count; $nd = @($p.Applied.Devices).Count
    $script:Status.Text = if ($np -or $nr -or $nd) { "ACLs applied to $np path(s), $nr registry key(s), $nd device(s). Firewall: $($p.Applied.Firewall). Loopback: $($p.Applied.Loopback)." } else { 'No ACLs applied yet (press Apply).' }
}
function Select-Profile($p) {
    $script:Cur = $p; Enable-UI $true
    $t = $script:T
    $t.Name.Text = $p.Name; $t.Desc.Text = $p.Description; $t.Exe.Text = $p.ExePath; $t.Args.Text = $p.Arguments; $t.Work.Text = $p.WorkDir
    $t.Extra.Text = $p.ExtraCaps; $t.FwList.Text = $p.Net.FwBlockList; $t.SrvPorts.Text = [string]$p.Net.ServerInboundPorts
    $t.EnvAllow.Text = [string]$p.EnvAllow; $t.EnvCustom.Text = [string]$p.EnvCustom; $t.Desktop.Text = [string]$p.CustomDesktop
    $script:EnvModeCmb.SelectedIndex = if ($p.EnvMode -eq 'InheritHost') { 1 } else { 0 }
    if ($p.Limits) {
        # Clamp imported JSON values to NumericUpDown bounds to avoid ArgumentOutOfRangeException
        $script:NumMaxProc.Value = [decimal][Math]::Max(0, [Math]::Min(10000, [int]$p.Limits.MaxProcesses))
        $script:NumProcMem.Value = [decimal][Math]::Max(0, [Math]::Min(1048576, [int]$p.Limits.ProcessMemMb))
        $script:NumJobMem.Value  = [decimal][Math]::Max(0, [Math]::Min(1048576, [int]$p.Limits.JobMemMb))
        $script:NumCpuPct.Value  = [decimal][Math]::Max(0, [Math]::Min(100, [int]$p.Limits.CpuRatePct))
    }
    $t.CName.Text = Get-ContainerName $p
    try { $t.Sid.Text = Get-Sid $p } catch { $t.Sid.Text = "(error: $($_.Exception.Message))" }
    foreach ($k in $script:Chk.Keys) { $a, $b = $k -split '\.'; $script:Chk[$k].Checked = [bool]$p.$a.$b }
    $script:CurUsbHidMode = if ($p.Dev -and $p.Dev.UsbHidMode) { [string]$p.Dev.UsbHidMode } else { 'Off' }
    $script:CurUsbHidDevices = if ($p.Dev -and $p.Dev.UsbHidDevices) { @($p.Dev.UsbHidDevices) } else { @() }
    Update-UsbHidLabel
    $script:RulePath.Text = ''; $script:RegPath.Text = ''
    $script:Grid.Rows.Clear()
    foreach ($r in @($p.Rules)) {
        $frc = ($r.PSObject.Properties.Name -contains 'Force' -and [bool]$r.Force)
        Add-RuleRow $r.Path $r.Scope $r.Access $frc
    }
    $script:RegGrid.Rows.Clear()
    foreach ($rr in @($p.RegRules)) {
        $rv = if ($rr.PSObject.Properties.Name -contains 'View' -and $rr.View) { [string]$rr.View } else { 'Both' }
        Add-RegRow $rr.Path $rr.Scope $rr.Access $rv
    }
    Update-Status $p
    Sync-PresetTab
}
function Get-GridRules {
    $rules = @()
    foreach ($row in $script:Grid.Rows) {
        $path = ([string]$row.Cells['Path'].Value).Trim()
        if (-not $path) { continue }
        $sc = Resolve-PathScopeKey ([string]$row.Cells['Scope'].Value)
        $acc = [string]$row.Cells['Access'].Value
        if ($acc -notin 'Read', 'ReadWrite', 'ReadExecute', 'Full') { $acc = 'Read' }
        $frc = [bool]$row.Cells['Force'].Value
        $rules += [pscustomobject]@{ Path = $path; Scope = $sc; Access = $acc; Force = $frc }
    }
    , $rules
}
function Get-RegGridRules {
    $rules = @()
    foreach ($row in $script:RegGrid.Rows) {
        $path = Resolve-RegPath ([string]$row.Cells['Path'].Value)
        if (-not $path) { continue }
        $sc = Resolve-RegScopeKey ([string]$row.Cells['Scope'].Value)
        $acc = [string]$row.Cells['Access'].Value
        if ($acc -notin 'Read', 'ReadWrite', 'Full') { $acc = 'Read' }
        $rv = [string]$row.Cells['View'].Value
        if ($rv -notin 'Both', '64', '32') { $rv = 'Both' }
        $rules += [pscustomobject]@{ Path = $path; Scope = $sc; Access = $acc; View = $rv }
    }
    , $rules
}
function Save-UiToProfile {
    $p = $script:Cur; if (-not $p) { return }
    $t = $script:T
    $p.Description = $t.Desc.Text; $p.ExePath = $t.Exe.Text.Trim().Trim('"'); $p.Arguments = $t.Args.Text; $p.WorkDir = $t.Work.Text.Trim().Trim('"')
    $p.ExtraCaps = $t.Extra.Text; $p.Net.FwBlockList = $t.FwList.Text; $p.Net.ServerInboundPorts = $t.SrvPorts.Text
    $p.EnvMode = if ($script:EnvModeCmb.SelectedIndex -eq 1) { 'InheritHost' } else { 'Allowlist' }
    $p.EnvAllow = $t.EnvAllow.Text; $p.EnvCustom = $t.EnvCustom.Text; $p.CustomDesktop = $t.Desktop.Text.Trim()
    $p.Limits = [pscustomobject]@{
        MaxProcesses = [int]$script:NumMaxProc.Value; ProcessMemMb = [int]$script:NumProcMem.Value
        JobMemMb = [int]$script:NumJobMem.Value; CpuRatePct = [int]$script:NumCpuPct.Value
    }
    foreach ($k in $script:Chk.Keys) { $a, $b = $k -split '\.'; $p.$a.$b = [bool]$script:Chk[$k].Checked }
    $p.Dev.UsbHidMode = $script:CurUsbHidMode
    $p.Dev.UsbHidDevices = @($script:CurUsbHidDevices)
    $p.Rules = Get-GridRules
    $p.RegRules = Get-RegGridRules
}
function Clear-ProfileUi {
    $script:Cur = $null
    foreach ($tb in $script:T.Values) { $tb.Text = '' }
    foreach ($cb in $script:Chk.Values) { $cb.Checked = $false }
    $script:CurUsbHidMode = 'Off'; $script:CurUsbHidDevices = @(); Update-UsbHidLabel
    $script:EnvModeCmb.SelectedIndex = 0
    $script:NumMaxProc.Value = 0; $script:NumProcMem.Value = 0; $script:NumJobMem.Value = 0; $script:NumCpuPct.Value = 0
    $script:RulePath.Text = ''; $script:RegPath.Text = ''
    $script:Grid.Rows.Clear(); $script:RegGrid.Rows.Clear()
    $script:Status.Text = ''
    Enable-UI $false
    Sync-PresetTab
}
# ===Dynamic Presets (*n)
function Get-CurrentPresetCacheKey {
    if (-not $script:Cur) { return '' }
    $script:Cur.Name
}
function Save-PresetVarsFromGrid {
    $key = Get-CurrentPresetCacheKey
    if (-not $key) { return }
    if (-not $script:PresetDescCache.ContainsKey($key)) { $script:PresetDescCache[$key] = @{} }
    foreach ($row in $script:PresetVarGrid.Rows) {
        $tok = [string]$row.Cells['Token'].Value
        if ($tok) { $script:PresetDescCache[$key][$tok] = ([string]$row.Cells['Description'].Value).Trim() }
    }
} 
# Export n Import
# Descriptions for *n tokens are cached in memory per profile name ($script:PresetDescCache)
# so they survive tab changes without ever being written to profiles.json.
function Sync-PresetTab {
    Save-PresetVarsFromGrid
    $tokens = @()
    if ($script:Cur) {
        $paths = @($script:T.Exe.Text.Trim().Trim('"'), $script:T.Work.Text.Trim().Trim('"')) + @($script:Grid.Rows | ForEach-Object { [string]$_.Cells['Path'].Value })
        $tokens = @(Get-DynamicTokensFromPaths $paths)
    }
    $bottomEdge = if ($script:BtnImportPreset) { $script:BtnImportPreset.Top - 8 } else { $F.ClientSize.Height - 242 }
    if ($tokens.Count -gt 0) {
        # Shift TabHost down from Y=52 to Y=86 to reveal the 32px PresetBar above the tabs.
        $script:PresetBar.Visible = $true
        $script:TabHost.SetBounds(10, 86, $F.ClientSize.Width - 20, [Math]::Max(200, $bottomEdge - 86))
        $key = Get-CurrentPresetCacheKey
        $cache = if ($key -and $script:PresetDescCache.ContainsKey($key)) { $script:PresetDescCache[$key] } else { @{} }
        $script:PresetVarGrid.Rows.Clear()
        foreach ($tok in $tokens) {
            $desc = if ($cache.ContainsKey($tok)) { [string]$cache[$tok] } else { '' }
            [void]$script:PresetVarGrid.Rows.Add($tok, $desc)
        }
    } else {
        if ($script:Tabs.SelectedTab -eq $tabPreset) { Switch-NavTab $tabRules }
        $script:PresetBar.Visible = $false
        $script:TabHost.SetBounds(10, 52, $F.ClientSize.Width - 20, [Math]::Max(200, $bottomEdge - 52))
        $script:PresetVarGrid.Rows.Clear()
    }
}
# Debounce exe/work TextChanged
# only rebuild PresetVarGrid when the set of *n tokens actually changes
$script:LastDynSig = ''
$onExeWorkChanged = {
    if ($script:Loading -or -not $script:Cur) { return }
    $sig = ((Get-DynamicTokensFromPaths @($script:T.Exe.Text, $script:T.Work.Text)) -join ',')
    if ($sig -cne $script:LastDynSig) { $script:LastDynSig = $sig; Sync-PresetTab }
}
$script:T.Exe.add_TextChanged($onExeWorkChanged)
$script:T.Work.add_TextChanged($onExeWorkChanged)
function Export-CurrentPreset {
    Save-UiToProfile
    Save-PresetVarsFromGrid
    $p = $script:Cur; if (-not $p) { return }
    $pName = Assert-ValidProfileName $p.Name
    Assert-NoControlChars $p.Description 'Description' $true 1024
    if ($p.Arguments) {
        Assert-NoControlChars $p.Arguments 'Arguments' $false 1024
        if ($p.Arguments -match '[&|;<>`$%]') { throw 'Preset Arguments cannot contain shell metacharacters (& | ; < > ` $ %).' }
    }
    if (-not $p.ExePath) { throw 'Set an executable path before exporting a preset.' }
    $exeOut = if ($p.ExePath.Contains('*')) { Assert-ValidPresetPath $p.ExePath 'Executable' } else { Assert-ValidConcreteFsPath $p.ExePath 'Executable' }
    $wdOut = if ($p.WorkDir) {
        if ($p.WorkDir.Contains('*')) { Assert-ValidPresetPath $p.WorkDir 'Working dir' } else { Assert-ValidConcreteFsPath $p.WorkDir 'Working dir' }
    } else { '' }
    Assert-ValidProfileCommonFields $p
    $rulesOut = @()
    foreach ($r in @($p.Rules)) {
        $rp = if ($r.Path.Contains('*')) { Assert-ValidPresetPath $r.Path 'Path rule' } else { Assert-ValidConcreteFsPath $r.Path 'Path rule' }
        $rulesOut += [pscustomobject]@{ Path = $rp; Scope = (Resolve-PathScopeKey $r.Scope); Access = $r.Access; Force = [bool]$r.Force }
    }
    $regOut = @()
    foreach ($rr in @($p.RegRules)) {
        $regP = Assert-ValidRegistryRulePath $rr.Path
        if ($rr.Access -in 'ReadWrite', 'Full' -and (Test-RegDanger $regP)) { throw "Refusing to export high-risk writable registry rule '$regP' in a preset." }
        $regOut += [pscustomobject]@{ Path = $regP; Scope = (Resolve-RegScopeKey $rr.Scope); Access = $rr.Access; View = $rr.View }
    }
    $tokens = @(Get-DynamicTokensFromPaths (@($exeOut, $wdOut) + @($rulesOut | ForEach-Object { $_.Path })))
    if ($tokens.Count -eq 0) { throw 'No *n dynamic paths found in this ruleset.' }
    $dynVars = @()
    foreach ($row in $script:PresetVarGrid.Rows) {
        $tok = [string]$row.Cells['Token'].Value
        $desc = ([string]$row.Cells['Description'].Value).Trim()
        Assert-NoControlChars $desc "Description for $tok" $false 200
        if (-not $desc) { throw "Please enter a short description for $tok before exporting." }
        $dynVars += [pscustomobject]@{ Token = $tok; Description = $desc }
    }
    # JSON round-trip clones $p.Hard so forcing FollowReparse=$false in the exported preset
    # doesnt mutate the active profile in memory. EnvCustom/CustomDesktop are stripped for safety
    $hardCopy = ($p.Hard | ConvertTo-Json -Depth 4) | ConvertFrom-Json
    $hardCopy.FollowReparse = $false
    $presetObj = [pscustomobject]@{
        PresetVersion = 1
        Type          = 'AppContainerPreset'
        Name          = $pName
        Description   = $p.Description
        ExePath       = $exeOut
        Arguments     = $p.Arguments
        WorkDir       = $wdOut
        ExtraCaps     = $p.ExtraCaps
        Net           = $p.Net
        Hard          = $hardCopy
        EnvMode       = 'Allowlist'
        Dev           = $p.Dev
        EnvAllow      = $p.EnvAllow
        Limits        = $p.Limits
        DynamicVars   = [object[]]@($dynVars)
        Rules         = [object[]]@($rulesOut)
        RegRules      = [object[]]@($regOut)
    }
    $sfd = New-Object Windows.Forms.SaveFileDialog
    $sfd.Filter = 'AppContainer Presets (*.acmpreset.json)|*.acmpreset.json|JSON files (*.json)|*.json'
    $sfd.FileName = ($pName -replace '[\\/:*?"<>|]', '_') + '.acmpreset.json'
    if ($sfd.ShowDialog() -ne 'OK') { return }
    if (-not (Test-PathNoReparse $sfd.FileName)) { throw 'Security error: target path contains a reparse point.' }
    $json = ConvertTo-Json -InputObject $presetObj -Depth 8
    [IO.File]::WriteAllText($sfd.FileName, $json, (New-Object Text.UTF8Encoding($false)))
    Log "Exported preset to $($sfd.FileName) (not written to profiles.json)."
}
function Show-PresetImportDialog($parsed) {
    $p = $parsed.Profile
    $dynVars = @($parsed.DynamicVars)
    $fixedRules = @($p.Rules | Where-Object { -not $_.Path.Contains('*') })
    $dynRules = @($p.Rules | Where-Object { $_.Path.Contains('*') })

    $dlg = Ctl Form @{ Text = 'Install App Preset'; ClientSize = (Sz 760 620); StartPosition = 'CenterParent'; FormBorderStyle = 'FixedDialog'; MaximizeBox = $false; MinimizeBox = $false } $null
    [void](Ctl Label @{ Text = 'Profile name (user-readable):'; Location = (Pt 14 16); AutoSize = $true } $dlg)
    $suggested = $p.Name
    if (Find-Profile $suggested) {
        $n = 2
        while (Find-Profile "$($p.Name) ($n)") { $n++ }
        $suggested = "$($p.Name) ($n)"
    }
    $tbName = Ctl TextBox @{ Text = $suggested; Location = (Pt 190 13); Size = (Sz 280 24) } $dlg
    [void](Ctl Label @{ Text = 'Unique Container ID auto-assigned on import.'; Location = (Pt 480 16); AutoSize = $true } $dlg)

    [void](Ctl Label @{ Text = 'Executable:'; Location = (Pt 14 48); AutoSize = $true } $dlg)
    $tbExe = Ctl TextBox @{ Text = $p.ExePath; Location = (Pt 190 45); Size = (Sz 555 24); ReadOnly = $true } $dlg
    $netSummary = if (Test-ProfileHasNetCap $p) { 'Network capabilities enabled' } else { 'Offline (0 network caps)' }
    $devList = @(); if ($p.Dev.Mic) { $devList += 'Mic' }; if ($p.Dev.Webcam) { $devList += 'Webcam' }; if ($p.Dev.Location) { $devList += 'Location' }
    if ($p.Dev.UsbHidMode -eq 'All') { $devList += 'USB/HID=All' } elseif ($p.Dev.UsbHidMode -eq 'Specific') { $devList += "USB/HID=$(@($p.Dev.UsbHidDevices).Count)" }
    $devSummary = if ($devList.Count) { ' | Devices: ' + ($devList -join ', ') } else { '' }
    $argSummary = if ($p.Arguments) { " | Args: $($p.Arguments)" } else { '' }
    [void](Ctl Label @{ Text = "Security: LPAC=$($p.Hard.Lpac), $netSummary$devSummary$argSummary"; Location = (Pt 14 76); Size = (Sz 730 20) } $dlg)

    [void](Ctl Label @{ Text = '1) Fixed paths and permissions:'; Location = (Pt 14 102); AutoSize = $true } $dlg)
    $dgFixed = Ctl DataGridView @{ Location = (Pt 14 122); Size = (Sz 732 135); AllowUserToAddRows = $false; RowHeadersVisible = $false; ReadOnly = $true; AutoSizeColumnsMode = 'Fill'; BackgroundColor = [Drawing.SystemColors]::Window } $dlg
    foreach ($col in @(@('Path', 58), @('Scope', 24), @('Access', 18))) {
        $c = New-Object Windows.Forms.DataGridViewTextBoxColumn; $c.Name = $col[0]; $c.HeaderText = $col[0]; $c.FillWeight = $col[1]; [void]$dgFixed.Columns.Add($c)
    }
    foreach ($fr in $fixedRules) { [void]$dgFixed.Rows.Add($fr.Path, $script:PathScopeUi[(Resolve-PathScopeKey $fr.Scope)], $fr.Access) }
    foreach ($rr in @($p.RegRules)) { [void]$dgFixed.Rows.Add("[Reg] $($rr.Path)", $script:RegScopeUi[(Resolve-RegScopeKey $rr.Scope)], "$($rr.Access) ($($rr.View))") }
    if ($p.Dev -and $p.Dev.UsbHidMode -eq 'Specific') {
        foreach ($dp in @($p.Dev.UsbHidDevices)) {
            [void]$dgFixed.Rows.Add("[Device] $dp", 'Device Interface', 'ReadWrite')
        }
    }

    [void](Ctl Label @{ Text = '2) Dynamic variables (*n) - enter your values:'; Location = (Pt 14 265); AutoSize = $true } $dlg)
    $dgVars = Ctl DataGridView @{ Location = (Pt 14 285); Size = (Sz 732 115); AllowUserToAddRows = $false; RowHeadersVisible = $false; AutoSizeColumnsMode = 'Fill'; BackgroundColor = [Drawing.SystemColors]::Window; EditMode = 'EditOnEnter' } $dlg
    $vc1 = New-Object Windows.Forms.DataGridViewTextBoxColumn; $vc1.Name = 'Token'; $vc1.HeaderText = 'Token'; $vc1.FillWeight = 12; $vc1.ReadOnly = $true
    $vc2 = New-Object Windows.Forms.DataGridViewTextBoxColumn; $vc2.Name = 'Description'; $vc2.HeaderText = 'Creator description'; $vc2.FillWeight = 44; $vc2.ReadOnly = $true
    $vc3 = New-Object Windows.Forms.DataGridViewTextBoxColumn; $vc3.Name = 'Value'; $vc3.HeaderText = 'Your value (folder/name)'; $vc3.FillWeight = 44; $vc3.ReadOnly = $false
    [void]$dgVars.Columns.Add($vc1); [void]$dgVars.Columns.Add($vc2); [void]$dgVars.Columns.Add($vc3)
    foreach ($dv in $dynVars) { [void]$dgVars.Rows.Add($dv.Token, $dv.Description, '') }

    [void](Ctl Label @{ Text = 'Dynamic paths (*n) and resolved preview:'; Location = (Pt 14 408); AutoSize = $true } $dlg)
    $dgDyn = Ctl DataGridView @{ Location = (Pt 14 428); Size = (Sz 732 135); AllowUserToAddRows = $false; RowHeadersVisible = $false; ReadOnly = $true; AutoSizeColumnsMode = 'Fill'; BackgroundColor = [Drawing.SystemColors]::Window } $dlg
    foreach ($col in @(@('Template', 38), @('Preview', 38), @('Access', 24))) {
        $c = New-Object Windows.Forms.DataGridViewTextBoxColumn; $c.Name = $col[0]; $c.HeaderText = $col[0]; $c.FillWeight = $col[1]; [void]$dgDyn.Columns.Add($c)
    }
    $refreshPreview = {
        $vals = @{}
        foreach ($vr in $dgVars.Rows) { $vals[[string]$vr.Cells['Token'].Value] = ([string]$vr.Cells['Value'].Value).Trim() }
        $dgDyn.Rows.Clear()
        foreach ($dr in $dynRules) {
            $prev = [regex]::Replace($dr.Path, '\*(?<n>[1-9]\d{0,2})(?!\d)', {
                param($m) $t = '*' + $m.Groups['n'].Value; if ($vals[$t]) { $vals[$t] } else { $t }
            })
            [void]$dgDyn.Rows.Add($dr.Path, $prev, "$($dr.Access) [$($dr.Scope)]")
        }
        if ($p.ExePath.Contains('*')) {
            $tbExe.Text = [regex]::Replace($p.ExePath, '\*(?<n>[1-9]\d{0,2})(?!\d)', {
                param($m) $t = '*' + $m.Groups['n'].Value; if ($vals[$t]) { $vals[$t] } else { $t }
            })
        }
    }
    $dgVars.add_CellValueChanged($refreshPreview)
    $dgVars.add_CellEndEdit($refreshPreview)
    & $refreshPreview

    [void](Btn 'Install Preset' 530 578 110 $dlg { Safe {
        $chosenName = Assert-ValidProfileName $tbName.Text
        if (Find-Profile $chosenName) { throw "A profile named '$chosenName' already exists. Choose a distinct profile name." }
        $vals = @{}
        foreach ($vr in $dgVars.Rows) {
            $tok = [string]$vr.Cells['Token'].Value
            $v = ([string]$vr.Cells['Value'].Value).Trim().Trim('"')
            if ([string]::IsNullOrWhiteSpace($v)) { throw "Please enter a value for $tok ($($vr.Cells['Description'].Value))." }
            Assert-NoControlChars $v "Value for $tok" $false 200
            if ($v -match '[*?<>|"/]' -or $v -match '(?:^|\\)\.\.(?:\\|$)') { throw "Security error: invalid characters or '..' traversal in value for $tok." }
            $vals[$tok] = $v
        }
        $p.Name = $chosenName
        $p.ContainerId = New-UniqueContainerId $chosenName
        if ($p.ExePath) { $p.ExePath = Resolve-PresetTemplateString $p.ExePath $vals 'Preset ExePath' }
        if ($p.WorkDir) { $p.WorkDir = Resolve-PresetTemplateString $p.WorkDir $vals 'Preset WorkDir' }
        $finalRules = @()
        foreach ($r in @($p.Rules)) {
            $resolvedPath = Resolve-PresetTemplateString $r.Path $vals 'Preset rule path'
            $finalRules += [pscustomobject]@{ Path = $resolvedPath; Scope = (Resolve-PathScopeKey $r.Scope); Access = $r.Access; Force = [bool]$r.Force }
        }
        $p.Rules = @($finalRules)
        $p.Applied = [pscustomobject]@{ Paths = @(); PathRules = @(); RegPaths = @(); Loopback = $false; Firewall = $false }
        $script:ImportDialogResult = $p
        $dlg.DialogResult = 'OK'
        $dlg.Close()
    } })
    [void](Btn 'Cancel' 646 578 100 $dlg { $dlg.DialogResult = 'Cancel'; $dlg.Close() })
    Set-DarkTheme $dlg
    $script:ImportDialogResult = $null
    if ($dlg.ShowDialog($F) -eq 'OK') { return $script:ImportDialogResult }
    $null
}
function Import-PresetFile {
    $ofd = New-Object Windows.Forms.OpenFileDialog
    $ofd.Filter = 'AppContainer Presets (*.acmpreset.json;*.json)|*.acmpreset.json;*.json|All files|*.*'
    if ($ofd.ShowDialog() -ne 'OK') { return }
    if (-not (Test-PathNoReparse $ofd.FileName)) { throw 'Security error: preset path contains a reparse point.' }
    $fi = [IO.FileInfo]::new($ofd.FileName)
    if ($fi.Length -gt 1048576) { throw 'Preset exceeds 1 MB size limit.' }
    $raw = [IO.File]::ReadAllText($ofd.FileName, [Text.Encoding]::UTF8)
    $parsed = ConvertFrom-PresetJson $raw
    $newProf = Show-PresetImportDialog $parsed
    if (-not $newProf) { return }
    Save-UiToProfile
    if (Test-ProfileHasDynamicPaths $script:Cur) { throw 'Current draft profile still contains unresolved *n paths; remove or finish it before importing.' }
    [void]$script:Profiles.Add($newProf)
    if (Test-Admin) {
        Save-Config; Refresh-List $newProf.Name; Save-UiToProfile; Sync-SavedSnapshot
        Log "Imported preset '$($newProf.Name)' (ContainerId: $($newProf.ContainerId))."
    } else {
        try { Invoke-Elevated 'SaveConfig' $newProf.Name 'Reload' $true }
        catch { [void]$script:Profiles.Remove($newProf); throw }
    }
}
function Refresh-List([string]$sel) {
    $script:Loading = $true; $script:Cur = $null; $script:SelectedCardIdx = -1
    foreach ($ctrl in @($script:CardsFlow.Controls)) {
        foreach ($ch in @($ctrl.Controls)) {
            if ($ch -is [Windows.Forms.PictureBox] -and $ch.Image) { $ch.Image.Dispose(); $ch.Image = $null }
        }
        $ctrl.Dispose()
    }
    $script:CardsFlow.Controls.Clear()
    $idx = -1
    for ($i = 0; $i -lt $script:Profiles.Count; $i++) { if ($script:Profiles[$i].Name -ieq $sel) { $idx = $i } }
    if ($idx -lt 0 -and $script:Profiles.Count -gt 0) { $idx = 0 }
    $script:SelectedCardIdx = $idx
    if ($script:Profiles.Count -eq 0) {
        [void](Ctl Label @{ Text = "No containers yet. Click 'New' or 'Import Preset...' below to create one."; AutoSize = $true; Margin = (New-Object Windows.Forms.Padding(16)); ForeColor = $script:Theme.Muted } $script:CardsFlow)
    } else {
        for ($i = 0; $i -lt $script:Profiles.Count; $i++) { Add-ContainerCard $script:Profiles[$i] $i }
    }
    $script:Loading = $false
    if ($idx -ge 0) { Select-Profile $script:Profiles[$idx] } else { Clear-ProfileUi }
}
function Reload-Config([string]$sel) { $script:Cur = $null; Load-Config; Refresh-List $sel; Save-UiToProfile; Sync-SavedSnapshot }
function Invoke-Audit {
    Save-UiToProfile
    $p = $script:Cur; if (-not $p) { return }
    $sid = Get-Sid $p.Name
    $risky = '.exe', '.dll', '.bat', '.cmd', '.ps1', '.vbs', '.js', '.lnk', '.scr', '.msi', '.com', '.hta'
    $pathDirs = @($env:PATH -split ';' | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') })
    $exe = Resolve-RulePath $p.ExePath
    $found = $false
    # Audit writable filesystem rules (drive roots, system dirs, PATH/EXE/Startup hijack, risky binaries)
    foreach ($r in @($p.Rules)) {
        if ($r.Access -notin 'ReadWrite', 'Full') { continue }
        $found = $true
        $rp = Resolve-RulePath $r.Path
        $sc = Resolve-PathScopeKey $r.Scope
        Log "Audit path write rule [$sc/$($r.Access)]: $rp"
        if ($rp.Length -le 3 -and $sc -ne 'FolderOnly') { Log '  !! Write access to an entire drive root.' }
        if (Test-SystemPath $rp) { Log '  !! Write access inside a Windows/Program Files folder.' }
        if ($pathDirs | Where-Object { Test-Under $_ $rp }) { Log '  !! Contains a PATH directory: planted files could run unsandboxed.' }
        if ($exe -and (Test-RuleCoversExe $exe $r)) { Log '  !! The sandboxed executable itself is writable.' }
        if ($rp -match '(?i)\\Startup(\\|$)') { Log '  !! Startup folder: files here run at logon.' }
        if ($sc -eq 'Recursive' -and (Test-Path -LiteralPath $rp -PathType Container)) {
            $hits = @(Get-ChildItem -LiteralPath $rp -Recurse -Depth 3 -File -Force -ErrorAction SilentlyContinue |
                Where-Object { $risky -contains $_.Extension.ToLowerInvariant() } | Select-Object -First 10)
            foreach ($h in $hits) { Log "  ? executable-type file in writable folder: $($h.FullName)" }
        }
    }
    # Audit writable registry rules (broad keys, HKCR ambiguity, persistence/COM hijack paths)
    foreach ($rr in @($p.RegRules)) {
        if ($rr.Access -notin 'ReadWrite', 'Full') { continue }
        $found = $true
        $rp = Resolve-RegPath $rr.Path
        Log "Audit reg write rule [$($rr.Scope)/$($rr.Access)]: $rp"
        if (($rp -split '\\').Count -le 2) { Log '  !! Broad registry write on top-level subkey.' }
        if ($rp -like 'HKCR\*') { Log '  !! HKCR merges HKCU/HKLM; prefer HKCU\Software\Classes or HKLM\SOFTWARE\Classes.' }
        if (Test-RegDanger $rp) { Log '  !! HIGH RISK registry persistence/hijack/COM path!' }
    }
    if (-not $found) { Log 'No ReadWrite/Full path or registry rules to audit.' }
    # Audit hardening downgrades, unrecognized/sensitive ExtraCaps, device capabilities
    if (-not $p.Hard.Lpac) {
        Log '  !! WARNING: LPAC is OFF. Token includes ALL APPLICATION PACKAGES (S-1-15-2-1), allowing reads anywhere S-1-15-2-1 has an ACE!'
    }
    if ($p.Net.Loopback) { Log '  !! WARNING: Loopback exemption is ON (all localhost ports reachable by container SID).' }
    if ($p.Hard.FollowReparse) { Log '  !! WARNING: FollowReparse is ON (junction/symlink traversal enabled during Apply).' }
    if (-not $p.Hard.NoClipboard) { Log '  !! WARNING: NoClipboard is OFF (sandboxed app can read/write host clipboard).' }
    if (-not $p.Hard.NoDesktopSys) { Log '  !! WARNING: NoDesktopSys is OFF (Job UI limits disabled).' }
    if ($p.EnvMode -eq 'InheritHost') { Log '  !! WARNING: EnvMode is InheritHost (exposes host environment variables/secrets).' }
    if (-not $p.Hard.RedirectProfile) { Log '  !! WARNING: RedirectProfile is OFF (exposes host USERPROFILE/APPDATA paths).' }
    if ($p.Net.Server -and $p.Net.ServerAllowInbound -and [string]::IsNullOrWhiteSpace($p.Net.ServerInboundPorts)) {
        Log '  !! WARNING: ServerAllowInbound is ON with blank ServerInboundPorts (should specify explicit TCP ports).'
    }
    $unkCaps = @(Get-UnknownExtraCaps $p)
    if ($unkCaps.Count -gt 0) { Log "  !! WARNING: Unrecognized ExtraCaps (possible typo; hashes to arbitrary SID): $($unkCaps -join ', ')" }
    if ($p.ExtraCaps -match '(?i)\b(enterpriseAuthentication|sharedUserCertificates|lpacCom)\b') {
        Log '  !! WARNING: ExtraCaps includes SSO/cert/COM capability (enterpriseAuthentication, sharedUserCertificates, or lpacCom); expands host credential/COM surface.'
    }
    if ($p.Dev) {
        if ($p.Dev.Mic) { Log '  !! NOTE: Microphone access is enabled.' }
        if ($p.Dev.Webcam) { Log '  !! NOTE: Webcam access is enabled.' }
        if ($p.Dev.Location) { Log '  !! NOTE: Location access is enabled.' }
        if ($p.Dev.UsbHidMode -eq 'All') { Log '  !! WARNING: All USB/HID device class capabilities enabled.' }
        elseif ($p.Dev.UsbHidMode -eq 'Specific') { Log "  !! NOTE: Specific USB/HID device access ($(@($p.Dev.UsbHidDevices).Count) device(s); requires Apply (admin))." }
    }
    # Audit offline isolation gaps (ALE_APP_ID / Dnscache) and live Windows Defender Firewall service/GPO state
    $hasNet = Test-ProfileHasNetCap $p
    if (-not $hasNet -and -not $p.Hard.NoChild -and -not $p.Net.FwBlockAll -and -not $p.Net.AutoOfflineBlock) {
        Log '  !! WARNING: Offline profile has NoChild OFF and no -Package firewall block rules; spawned children could hit WSH ALE_APP_ID Permit rules.'
    }
    if ($hasNet -and $p.Net.FwBlockAll) {
        Log '  !! NOTE: FwBlockAll is ON while a network capability is ticked; Dnscache DNS lookups still succeed despite -Package block rules.'
    }
    $mps = Get-Service -Name 'MpsSvc' -ErrorAction SilentlyContinue
    if (-not $mps -or $mps.Status -ne 'Running') {
        Log '  !! WARNING: Windows Defender Firewall service (MpsSvc) is not running; -Package firewall rules have no effect.'
    } else {
        try {
            foreach ($fp in @(Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction Stop)) {
                if ([string]$fp.Enabled -ne 'True') { Log "  !! WARNING: Defender Firewall profile '$($fp.Name)' is disabled." }
                if ([string]$fp.AllowLocalFirewallRules -eq 'False') { Log "  !! WARNING: Firewall profile '$($fp.Name)' disables local rule merging (AllowLocalFirewallRules=False)." }
            }
        } catch {}
    }
    # Probe common host directories and fixed/removable drives for ambient S-1-15-2-1/2 or container SID ACE leaks
    $probeDirs = New-Object System.Collections.Generic.List[string]
    $usersRoot = Split-Path -Parent $env:USERPROFILE
    foreach ($pd in @($env:USERPROFILE, (Join-Path $env:USERPROFILE 'Desktop'), (Join-Path $env:USERPROFILE 'Documents'),
        (Join-Path $env:USERPROFILE 'Downloads'), (Join-Path $env:USERPROFILE 'Pictures'), $env:APPDATA, $env:LOCALAPPDATA,
        (Join-Path $env:USERPROFILE '.ssh'), (Join-Path $env:USERPROFILE '.aws'), (Join-Path $env:USERPROFILE '.gnupg'),
        (Join-Path $env:USERPROFILE '.kube'), $env:OneDrive, $env:ProgramData, $usersRoot,
        (Join-Path $usersRoot 'Public'), $env:TEMP, (Join-Path $env:SystemRoot 'Temp'))) {
        if ($pd -and (Test-Path -LiteralPath $pd)) { [void]$probeDirs.Add($pd) }
    }
    foreach ($drv in [IO.DriveInfo]::GetDrives()) {
        if ($drv.IsReady -and $drv.DriveType -in 'Fixed', 'Removable') { [void]$probeDirs.Add($drv.RootDirectory.FullName) }
    }
    $checkedSids = if ($p.Hard.Lpac) { @('S-1-15-2-2', $sid) } else { @('S-1-15-2-1', 'S-1-15-2-2', $sid) }
    foreach ($pd in ($probeDirs | Select-Object -Unique)) {
        try {
            $acl = Get-Acl -LiteralPath $pd
            foreach ($ace in $acl.Access) {
                $sidStr = try { $ace.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } catch { '' }
                if ($ace.AccessControlType -eq 'Allow' -and ($checkedSids -contains $sidStr)) {
                    $tag = if ($sidStr -eq $sid) { 'CONTAINER SID ACE ON HOST' } else { 'READ LEAK ON HOST ACL' }
                    Log "  !! ${tag}: '$pd' grants $($ace.FileSystemRights) to $($ace.IdentityReference) ($sidStr)!"
                }
            }
        } catch {}
    }
    # Probe high-value host registry roots for read leaks
    foreach ($rkProbe in @('Registry::HKEY_CURRENT_USER\Software', 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE', 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control')) {
        try {
            $racl = Get-Acl -LiteralPath $rkProbe
            foreach ($ace in $racl.Access) {
                $sidStr = try { $ace.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } catch { '' }
                if ($ace.AccessControlType -eq 'Allow' -and ($checkedSids -contains $sidStr)) {
                    $tag = if ($sidStr -eq $sid) { 'CONTAINER SID REG ACE' } else { 'REG READ LEAK' }
                    Log "  !! ${tag}: '$rkProbe' grants $($ace.RegistryRights) to $($ace.IdentityReference) ($sidStr)"
                }
            }
        } catch {}
    }
    # Admin-only: dump live WFP filters and flag WSH PERMIT rules that match ALE_APP_ID without ALE_PACKAGE_ID
    if (Test-Admin) {
        $wfpXml = Join-Path $env:TEMP ('acm_wfp_{0}.xml' -f [guid]::NewGuid().ToString('N'))
        try {
            $wr = Invoke-Native (Resolve-SystemExe 'netsh.exe') @('wfp', 'show', 'filters', "file=$wfpXml")
            if ($wr.Code -eq 0 -and (Test-Path -LiteralPath $wfpXml)) {
                [xml]$doc = Get-Content -LiteralPath $wfpXml -Raw
                $leaks = New-Object System.Collections.Generic.List[string]
                foreach ($item in $doc.SelectNodes('//item')) {
                    $sub = $item.subLayerKey
                    $act = $item.action.type
                    if ($sub -match 'WSH' -and $act -eq 'FWP_ACTION_PERMIT') {
                        $conds = @($item.filterCondition.item.fieldKey)
                        if (($conds -contains 'FWPM_CONDITION_ALE_APP_ID') -and ($conds -notcontains 'FWPM_CONDITION_ALE_PACKAGE_ID')) {
                            $app = ($item.filterCondition.item | Where-Object { $_.fieldKey -eq 'FWPM_CONDITION_ALE_APP_ID' } | Select-Object -First 1).conditionValue.byteBlob.asString
                            if ($app) { [void]$leaks.Add($app) }
                        }
                    }
                }
                foreach ($lk in ($leaks | Select-Object -Unique | Select-Object -First 15)) {
                    Log "  ? WFP WSH ALE_APP_ID Permit without ALE_PACKAGE_ID check: $lk"
                }
            }
        } catch {} finally { Remove-Item -LiteralPath $wfpXml -Force -ErrorAction SilentlyContinue }
    }
    Log 'Audit finished.'
}
function Show-RuntimeInspector($p) {
    $sid = Get-Sid $p
    $cn = Get-ContainerName $p
    $fwGrp = Get-FirewallGroup $p
    $pids = @([ACM.Native]::GetContainerPids($sid))
    $cb = Invoke-Native (Resolve-SystemExe 'CheckNetIsolation.exe') @('LoopbackExempt', '-s')
    $hasLb = ($cb.Out -match [regex]::Escape($sid))
    $fwCount = 0
    try { $fwCount = @(Get-NetFirewallRule -Group $fwGrp -ErrorAction SilentlyContinue).Count } catch {}
    $msg = "Profile: $($p.Name)`r`nContainer ID: $cn`r`nSID: $sid`r`n`r`nRunning processes in container: $($pids.Count)`r`n"
    if ($pids.Count -gt 0) { $msg += (($pids -join "`r`n") + "`r`n") }
    $msg += "`r`nSystem CheckNetIsolation loopback exempt: $hasLb`r`nActive Defender Firewall rules ($fwGrp): $fwCount"
    if ($pids.Count -gt 0) {
        $msg += "`r`n`r`nTerminate all running processes in this container?"
        if ([Windows.Forms.MessageBox]::Show($msg, 'Inspect Runtime', 'YesNo', 'Information') -eq 'Yes') {
            $k = [ACM.Native]::TerminateContainerPids($sid)
            Log "Terminated $k process(es) in container $sid."
        }
    } else {
        [void][Windows.Forms.MessageBox]::Show($msg, 'Inspect Runtime', 'OK', 'Information')
    }
}
function Reset-ContainerStorage($p) {
    $sid = Get-Sid $p.Name
    $cn = Get-ContainerName $p.Name
    $pids = @([ACM.Native]::GetContainerPids($sid))
    if ($pids.Count -gt 0) { throw "Close or terminate active processes in '$($p.Name)' first ($($pids.Count) running)." }
    if ([Windows.Forms.MessageBox]::Show("Wipe container profile storage and private registry hive for '$($p.Name)'? (Saved profile rules are kept.)", 'Reset container storage', 'YesNo', 'Warning') -ne 'Yes') { return }
    Remove-LocalContainerProfile $p.Name
    Log "Reset container storage for '$($p.Name)' ($cn)."
}
function Get-LauncherArgs($name) {
    @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', $script:MainScriptPath, '-Launch', $name)
}

# ===buttons
# NOTE to self: Button X/Width/Y=546 values are placeholders. final widths and Y=596 are computed at startup
# i should try writing less shitty code
$script:ProfBtns = @()
$script:ProfBtns += Btn 'New' 10 546 62 $F { Safe {
    $n = [Microsoft.VisualBasic.Interaction]::InputBox('Profile name (1-48 chars, Unicode allowed, no \ / : * ? " < > |):', 'New profile', 'MyApp')
    if (-not $n) { return }
    $n = Assert-ValidProfileName $n
    if (Find-Profile $n) { throw "A profile named '$n' already exists." }
    Save-UiToProfile
    $newObj = New-ProfileObject $n
    if (($n -cmatch '[^A-Za-z0-9 ._-]') -or (Find-ContainerCollision $n)) { $newObj.ContainerId = New-UniqueContainerId $n }
    [void]$script:Profiles.Add($newObj)
    if (Test-Admin) { Save-Config; Refresh-List $n; Save-UiToProfile; Sync-SavedSnapshot }
    else {
        try { Invoke-Elevated 'SaveConfig' $n 'Reload' $true }
        catch { [void]$script:Profiles.Remove($newObj); throw }
    } } } 'Bottom,Left'
$script:ProfBtns += Btn 'Clone' 76 546 62 $F { Safe {
    Save-UiToProfile; $p = $script:Cur; if (-not $p) { return }
    $n = [Microsoft.VisualBasic.Interaction]::InputBox('Name for the copy:', 'Clone profile', "$($p.Name) copy")
    if (-not $n) { return }
    $n = Assert-ValidProfileName $n
    if (Find-Profile $n) { throw "A profile named '$n' already exists." }
    $c = Merge-Obj (New-ProfileObject $n) (($p | ConvertTo-Json -Depth 8) | ConvertFrom-Json)
    $c.Name = $n; $c.ContainerId = New-UniqueContainerId $n; $c.Applied = [pscustomobject]@{ Paths = @(); PathRules = @(); RegPaths = @(); Loopback = $false; Firewall = $false }
    [void]$script:Profiles.Add($c)
    if (Test-Admin) { Save-Config; Refresh-List $n; Save-UiToProfile; Sync-SavedSnapshot }
    else {
        try { Invoke-Elevated 'SaveConfig' $n 'Reload' $true }
        catch { [void]$script:Profiles.Remove($c); throw }
    } } } 'Bottom,Left'
$script:ProfBtns += Btn 'Delete' 142 546 62 $F { Safe {
    $p = $script:Cur; if (-not $p) { return }
    $sid = Get-Sid $p.Name
    $pids = @([ACM.Native]::GetContainerPids($sid))
    if ($pids.Count -gt 0) { throw "Close or terminate active processes in '$($p.Name)' first ($($pids.Count) running)." }
    if ([Windows.Forms.MessageBox]::Show("Delete profile '$($p.Name)', revoke its ACLs and remove the container?", 'Delete', 'YesNo', 'Warning') -ne 'Yes') { return }
    $name = $p.Name
    if (Test-Admin) {
        if (@($p.Applied.Paths).Count -or @($p.Applied.RegPaths).Count -or @($p.Applied.Devices).Count -or $p.Applied.Firewall -or $p.Applied.Loopback) { Invoke-Revoke $p }
        Complete-DeleteProfile $name
        Refresh-List ''; Save-UiToProfile; Sync-SavedSnapshot
    } elseif ($script:IsLegacyConfig -or -not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        # Unsaved/legacy profiles only exist in memory + local container storage
        # so no Program Files config to update
        Remove-LocalContainerProfile $name
        [void]$script:Profiles.Remove($p)
        Refresh-List ''; Save-UiToProfile
        Log "Deleted unsaved/legacy profile '$name'."
    } else {
        # Elevated process removes Program Files entry + system ACLs
        # n OnDone='DeleteLocal:' then removes
        # the container storage under the original non-admin user's %LOCALAPPDATA% (handles over-the-shoulder UAC).
        Invoke-Elevated 'Delete' $name "DeleteLocal:$name" $false
    } } } 'Bottom,Left'

# ===other buttons
$script:ActBtns = @()
$script:ActBtns += Btn 'Save (admin)' 220 546 84 $F { Safe {
    Save-UiToProfile
    foreach ($prof in $script:Profiles) {
        if (Test-ProfileHasDynamicPaths $prof) { throw "Profile '$($prof.Name)' has unresolved *n preset paths. Export it from the 'Preset (*n)' tab and remove *n paths before saving profiles.json." }
    }
    $selName = if ($script:Cur) { $script:Cur.Name } else { '' }
    if (Test-Admin) { Save-Config; if ($script:Cur) { Select-Profile $script:Cur }; Save-UiToProfile; Sync-SavedSnapshot; Log 'Saved.' }
    else { Invoke-Elevated 'SaveConfig' $selName 'Reload' $true } } } 'Bottom,Left'
$script:ActBtns += Btn 'Apply (admin)' 308 546 94 $F { Safe {
    Save-UiToProfile; $p = $script:Cur; if (-not $p) { return }
    if (Test-ProfileHasDynamicPaths $p) { throw 'Unresolved *n dynamic paths cannot be applied. Export as a preset and import it first.' }
    if (-not $p.ExePath) { throw 'Set an executable first.' }
    if (-not $p.Hard.NoClipboard) {
        if ([Windows.Forms.MessageBox]::Show("Clipboard isolation is OFF! The sandboxed app will be able to read and modify your host clipboard. Continue anyway?", 'Clipboard exposed', 'YesNo', 'Warning') -ne 'Yes') { return }
    }
    if (-not $p.Hard.NoDesktopSys) {
        if ([Windows.Forms.MessageBox]::Show("Desktop/USER handle Job UI limits are OFF! Continue anyway?", 'Weakened isolation (Job UI OFF)', 'YesNo', 'Warning') -ne 'Yes') { return }
    }
    if (-not $p.Hard.Lpac) {
        if ([Windows.Forms.MessageBox]::Show("LPAC is OFF! Standard AppContainer keeps ALL APPLICATION PACKAGES (S-1-15-2-1), allowing reads wherever S-1-15-2-1 has access. Continue anyway?", 'Weakened isolation (LPAC OFF)', 'YesNo', 'Warning') -ne 'Yes') { return }
    }
    if (-not (Test-ExeAccessible $p)) {
        if ([Windows.Forms.MessageBox]::Show("The container has no Read+Execute access to the executable's folder. Add a ReadExecute rule for it?", 'Executable not reachable', 'YesNo', 'Question') -eq 'Yes') {
            Add-RuleRow (Split-Path -Parent (Resolve-RulePath $p.ExePath)) 'Recursive' 'ReadExecute' $false; Save-UiToProfile
        }
    }
    foreach ($r in @($p.Rules)) {
        $rp = Resolve-RulePath $r.Path
        if ($r.Access -in 'Full', 'ReadWrite' -and ($rp.Length -le 3 -or (Test-SystemPath $rp))) {
            if ([Windows.Forms.MessageBox]::Show("Path rule grants $($r.Access) on '$rp' (drive root or system folder). Continue?", 'Risky rule', 'YesNo', 'Warning') -ne 'Yes') { return }
        }
    }
    foreach ($rr in @($p.RegRules)) {
        $rp = Resolve-RegPath $rr.Path
        if ($rr.Access -in 'Full', 'ReadWrite' -and ((($rp -split '\\').Count -le 2) -or (Test-RegDanger $rp))) {
            if ([Windows.Forms.MessageBox]::Show("Registry rule grants $($rr.Access) on sensitive/broad key '$rp'. Continue?", 'Risky registry rule', 'YesNo', 'Warning') -ne 'Yes') { return }
        }
    }
    $name = $p.Name
    if (Test-Admin) {
        Save-Config; Invoke-Mode 'Apply' $p; Reload-Config $name
    } else {
        Invoke-Elevated 'Apply' $name 'Reload' $true
    } } } 'Bottom,Left'
$script:ActBtns += Btn 'Launch' 406 546 64 $F { Safe {
    if (Test-Admin) { throw 'Refusing to launch sandboxed apps from an elevated Administrator GUI. Close this window and run AppContainer Manager normally (non-admin) to launch.' }
    Save-UiToProfile; $p = $script:Cur; if (-not $p) { return }
    if (Test-ProfileHasDynamicPaths $p) { throw 'Unresolved *n dynamic paths cannot be launched. Export as a preset and import it first.' }
    if (-not $p.Hard.NoClipboard) {
        if ([Windows.Forms.MessageBox]::Show("Clipboard isolation is OFF! The sandboxed app can read/write your host clipboard. Launch anyway?", 'Clipboard exposed', 'YesNo', 'Warning') -ne 'Yes') { return }
    }
    if (-not $p.Hard.NoDesktopSys) {
        if ([Windows.Forms.MessageBox]::Show("Desktop/USER handle Job UI limits are OFF! Launch anyway?", 'Weakened isolation (Job UI OFF)', 'YesNo', 'Warning') -ne 'Yes') { return }
    }
    $unkCaps = @(Get-UnknownExtraCaps $p)
    if ($unkCaps.Count -gt 0) {
        if ([Windows.Forms.MessageBox]::Show("Unrecognized capability name(s) in ExtraCaps (typos hash to dummy SIDs): $($unkCaps -join ', '). Launch anyway?", 'Unknown ExtraCaps', 'YesNo', 'Warning') -ne 'Yes') { return }
    }
    if (-not $p.Hard.Lpac) {
        if ([Windows.Forms.MessageBox]::Show("LPAC is OFF! Standard AppContainer keeps ALL APPLICATION PACKAGES (S-1-15-2-1). Launch anyway?", 'Weakened isolation (LPAC OFF)', 'YesNo', 'Warning') -ne 'Yes') { return }
    }
    if (-not (Test-ExeAccessible $p)) { Log 'Warning: no ReadExecute allow rule covers the executable. It may fail to start.' }
    if (Test-ConfigDirty) {
        $ans = [Windows.Forms.MessageBox]::Show("You have unsaved changes. Save config to Program Files (admin) before launching?`r`n(Yes = Save & Launch, No = Launch last saved version)", 'Unsaved changes', 'YesNoCancel', 'Question')
        if ($ans -eq 'Cancel') { return }
        if ($ans -eq 'Yes') { Invoke-Elevated 'SaveConfig' $p.Name "Launch:$($p.Name)" $true; return }
        if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw 'Config has not been saved to Program Files yet.' }
    }
    Invoke-LaunchProfileProcess $p } } 'Bottom,Left'
$script:ActBtns += Btn 'Shortcut' 474 546 68 $F { Safe {
    Save-UiToProfile; $p = $script:Cur; if (-not $p) { return }
    if (Test-ProfileHasDynamicPaths $p) { throw 'Unresolved *n dynamic paths cannot be used for a shortcut.' }
    if (Test-ConfigDirty) {
        if (Test-Admin) { Save-Config; Save-UiToProfile; Sync-SavedSnapshot }
        else {
            $ans = [Windows.Forms.MessageBox]::Show("You have unsaved changes. Save config to Program Files (admin) before creating shortcut?", 'Unsaved changes', 'YesNoCancel', 'Question')
            if ($ans -eq 'Cancel') { return }
            if ($ans -eq 'Yes') { Invoke-Elevated 'SaveConfig' $p.Name "Shortcut:$($p.Name)" $true; return }
            if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw 'Config has not been saved to Program Files yet.' }
        }
    }
    New-DesktopShortcut $p } } 'Bottom,Left'
$script:ActBtns += Btn 'Copy SID' 546 546 68 $F { Safe { if ($script:T.Sid.Text) { [Windows.Forms.Clipboard]::SetText($script:T.Sid.Text); Log 'SID copied.' } } } 'Bottom,Left'
$script:ActBtns += Btn 'Revoke (admin)' 618 546 98 $F { Safe {
    $p = $script:Cur; if (-not $p) { return }
    if ([Windows.Forms.MessageBox]::Show('Remove all ACL entries, firewall rules and loopback exemptions this tool added for the profile?', 'Revoke', 'YesNo', 'Question') -ne 'Yes') { return }
    Save-UiToProfile; $name = $p.Name
    if (Test-Admin) {
        Save-Config; Invoke-Mode 'Revoke' $p; Reload-Config $name
    } else {
        Invoke-Elevated 'Revoke' $name 'Reload' $true
    } } } 'Bottom,Left'
$script:ActBtns += Btn 'Inspect' 720 546 66 $F { Safe { if ($script:Cur) { Show-RuntimeInspector $script:Cur } } } 'Bottom,Left'
$script:ActBtns += Btn 'Reset data' 790 546 86 $F { Safe { if ($script:Cur) { Reset-ContainerStorage $script:Cur } } } 'Bottom,Left'
$script:BtnImportPreset = Btn 'Import Preset...' 920 546 110 $F { Safe { Import-PresetFile } } 'Bottom,Right'

# ===Window Closing n App Startup Initialization
$F.add_FormClosing({
    if ($script:Busy) { $_.Cancel = $true; return }
    # $script:ForceClose is set by 03-ElevationAndProcess.ps1 after an async SaveConfig ('Close') succeeds,
    # preventing an infinite save-prompt loop when re-triggering $F.Close().
    if (-not $script:ForceClose) {
        try {
            Save-UiToProfile
            if (Test-ConfigDirty) {
                if (Test-Admin) { Save-Config }
                else {
                    $ans = [Windows.Forms.MessageBox]::Show("Save unsaved config changes to Program Files (admin) before closing?", 'Unsaved changes', 'YesNoCancel', 'Question')
                    if ($ans -eq 'Cancel') { $_.Cancel = $true; return }
                    if ($ans -eq 'Yes') { $_.Cancel = $true; Invoke-Elevated 'SaveConfig' '' 'Close' $true; return }
                }
            }
        } catch {}
    }
    foreach ($ws in @($script:LaunchWatchers)) { try { $ws.Tmr.Stop(); $ws.Tmr.Dispose(); if ($ws.Proc.HasExited) { Remove-Item -LiteralPath $ws.Log -Force -ErrorAction SilentlyContinue } } catch {} }
})
Load-Config $true
Refresh-List ''
Save-UiToProfile; Sync-SavedSnapshot
Log "Config: $ConfigPath"
if (-not (Test-ProtectedScriptLocation)) {
    Log "SECURITY WARNING: Script is running from a user-writable location ($script:MainScriptPath). Move it to $(Get-ProtectedAppDir)\ so non-admin code cannot tamper with it before UAC elevation."
}
$wb = [ACM.Native]::GetWindowsBuild()
if ($wb -gt 0 -and $wb -lt 15063) { Log "WARNING: Windows build $wb detected (< 15063 / 1703). LPAC and DeriveCapabilitySidsFromName are not supported on this OS." }
if (Test-Admin) { $F.Text = 'AppContainer Manager [ELEVATED - Launch blocked]'; Log 'Running elevated: Launch is blocked for safety. Close and reopen from a normal (non-admin) session to launch.' }
$bx = 10
foreach ($b in $script:ProfBtns) {
    $b.Width = [Math]::Max(52, [Windows.Forms.TextRenderer]::MeasureText($b.Text, $script:FontBody).Width + 18)
    $b.Location = (Pt $bx 596); $bx += $b.Width + 4
}
$bx += 12
foreach ($b in $script:ActBtns) {
    if ($b.Text -eq 'Launch') { $b.Tag = 'Primary' }
    $b.Width = [Math]::Max(62, [Windows.Forms.TextRenderer]::MeasureText($b.Text, $script:FontBody).Width + 18)
    $b.Location = (Pt $bx 596); $bx += $b.Width + 4
}
$script:BtnImportPreset.Width = [Math]::Max(110, [Windows.Forms.TextRenderer]::MeasureText($script:BtnImportPreset.Text, $script:FontBody).Width + 20)
$script:BtnImportPreset.Location = (Pt ($F.ClientSize.Width - $script:BtnImportPreset.Width - 10) 596)
Switch-NavTab $tabContainers
Set-DarkTheme $F
Sync-PresetTab
[void]$F.ShowDialog()