# ===GUI
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, Microsoft.VisualBasic
[Windows.Forms.Application]::EnableVisualStyles()
if (-not ('ACM.Dwm' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace ACM {
    public static class Dwm {
        [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int val, int size);
    }
}
'@ -Language CSharp
}
if (-not ('ACM.IconUtil' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace ACM {
    public static class IconUtil {
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern uint PrivateExtractIcons(string lpszFile, int nIconIndex, int cxIcon, int cyIcon, IntPtr[] phicon, uint[] piconid, uint nIcons, uint flags);
        [DllImport("user32.dll")]
        public static extern bool DestroyIcon(IntPtr hIcon);
    }
}
'@ -Language CSharp
}
$script:Theme = @{
    Bg        = [Drawing.Color]::FromArgb(24, 25, 32)
    Surface   = [Drawing.Color]::FromArgb(33, 35, 45)
    Surface2  = [Drawing.Color]::FromArgb(41, 44, 58)
    Input     = [Drawing.Color]::FromArgb(28, 30, 39)
    Border    = [Drawing.Color]::FromArgb(56, 60, 78)
    Text      = [Drawing.Color]::FromArgb(240, 242, 248)
    Muted     = [Drawing.Color]::FromArgb(158, 164, 184)
    Accent    = [Drawing.Color]::FromArgb(124, 92, 255)
    AccentHov = [Drawing.Color]::FromArgb(142, 114, 255)
    AccentDim = [Drawing.Color]::FromArgb(64, 52, 118)
    LogBg     = [Drawing.Color]::FromArgb(17, 18, 24)
}
$script:UiFontName = if (([Drawing.FontFamily]::Families | Where-Object { $_.Name -eq 'Segoe UI Variable Text' })) { 'Segoe UI Variable Text' } else { 'Segoe UI' }
$script:FontBody  = New-Object Drawing.Font($script:UiFontName, 9.25)
$script:FontBold  = New-Object Drawing.Font($script:UiFontName, 9.25, [Drawing.FontStyle]::Bold)
$script:FontSmall = New-Object Drawing.Font($script:UiFontName, 8.25)
$script:UiIconsPath = Join-Path $env:LOCALAPPDATA 'AppContainerManager\ui-icons.json'
$script:UiIcons = @{}
$script:SelectedCardIdx = -1
$script:NavMap = [ordered]@{}
$script:ProfileOnlyTabs = New-Object System.Collections.Generic.List[object]

# Apply dark title bar via DWM (Windows 10 1809+ / Windows 11).
# Requires an active HWND; unsupported builds fail silently.
function Set-DarkTitleBar($form) {
    if (-not $form -or -not $form.IsHandleCreated) { return }
    try {
        $v = 1
        [void][ACM.Dwm]::DwmSetWindowAttribute($form.Handle, 20, [ref]$v, 4) # DWMWA_USE_IMMERSIVE_DARK_MODE (Win10 20H1+/Win11)
        [void][ACM.Dwm]::DwmSetWindowAttribute($form.Handle, 19, [ref]$v, 4) # Fallback attribute ID for Win10 1809-1909
        $cap = 0x00201918 # DWMWA_CAPTION_COLOR in COLORREF (0x00BBGGRR) matching Theme.Bg (24, 25, 32)
        [void][ACM.Dwm]::DwmSetWindowAttribute($form.Handle, 35, [ref]$cap, 4)
    } catch {}
}
# Styles WinForms controls with the dark palette.
# (also used in 05-GuiController.ps1):
#   Name = 'KeepStyle' -> skip control (preserves custom cards and nav buttons)
#   Tag  = 'Surface'   -> elevated panel background
#   Tag  = 'Muted'     -> secondary label/checkbox text color 
#   Tag  = 'Primary'   -> accent fill on primary action buttons
function Set-DarkTheme($root) {
    $t = $script:Theme
    if ($root -is [Windows.Forms.Form]) {
        $root.BackColor = $t.Bg; $root.ForeColor = $t.Text; $root.Font = $script:FontBody
        # Defer DWM call until HWND exists
        $root.add_HandleCreated({ param($s, $e) Set-DarkTitleBar $s })
        if ($root.IsHandleCreated) { Set-DarkTitleBar $root }
    }
    foreach ($c in $root.Controls) {
        if ($c.Name -eq 'KeepStyle') { continue }
        if ($c -is [Windows.Forms.Panel] -or $c -is [Windows.Forms.FlowLayoutPanel] -or $c -is [Windows.Forms.TabPage] -or $c -is [Windows.Forms.TabControl]) {
            $c.BackColor = if ($c.Tag -eq 'Surface') { $t.Surface } else { $t.Bg }
            $c.ForeColor = $t.Text
        } elseif ($c -is [Windows.Forms.GroupBox]) {
            $c.BackColor = $t.Bg; $c.ForeColor = $t.Text
        } elseif ($c -is [Windows.Forms.Label] -or $c -is [Windows.Forms.CheckBox] -or $c -is [Windows.Forms.RadioButton]) {
            $c.ForeColor = if ($c.Tag -eq 'Muted') { $t.Muted } else { $t.Text }
            $c.BackColor = [Drawing.Color]::Transparent
            $c.UseMnemonic = $false # Keep '&' literal instead of rendering Alt-access underlines
        } elseif ($c -is [Windows.Forms.TextBoxBase]) {
            $c.BackColor = if ($c -eq $script:LogBox) { $t.LogBg } elseif ($c.ReadOnly) { $t.Surface } else { $t.Input }
            $c.ForeColor = $t.Text; $c.BorderStyle = 'FixedSingle'
        } elseif ($c -is [Windows.Forms.ComboBox] -or $c -is [Windows.Forms.NumericUpDown]) {
            $c.BackColor = $t.Input; $c.ForeColor = $t.Text
            if ($c -is [Windows.Forms.ComboBox]) {
                $c.FlatStyle = 'Flat'
                # WinForms ignores BackColor/ForeColor on DropDownList under visual styles. owner-draw items instead
                if ($c.DrawMode -ne 'OwnerDrawFixed') {
                    $c.DrawMode = 'OwnerDrawFixed'; $c.ItemHeight = 20
                    $c.add_DrawItem({
                        param($s, $e)
                        if ($e.Index -lt 0) { return }
                        $isEdit = (($e.State -band [Windows.Forms.DrawItemState]::ComboBoxEdit) -ne 0)
                        $isSel  = ((-not $isEdit) -and (($e.State -band [Windows.Forms.DrawItemState]::Selected) -ne 0))
                        $bg = if ($isSel) { $script:Theme.AccentDim } else { $script:Theme.Input }
                        $br = New-Object Drawing.SolidBrush($bg)
                        try { $e.Graphics.FillRectangle($br, $e.Bounds) } finally { $br.Dispose() }
                        $txt = $s.GetItemText($s.Items[$e.Index])
                        [Windows.Forms.TextRenderer]::DrawText($e.Graphics, $txt, $s.Font, $e.Bounds, $script:Theme.Text, [Windows.Forms.TextFormatFlags]::Left -bor [Windows.Forms.TextFormatFlags]::VerticalCenter -bor [Windows.Forms.TextFormatFlags]::EndEllipsis)
                    })
                }
            }
        } elseif ($c -is [Windows.Forms.Button]) {
            $isPrim = ($c.Tag -eq 'Primary')
            $c.FlatStyle = 'Flat'
            $c.BackColor = if ($isPrim) { $t.Accent } else { $t.Surface2 }
            $c.ForeColor = $t.Text
            $c.FlatAppearance.BorderSize = 1
            $c.FlatAppearance.BorderColor = if ($isPrim) { $t.Accent } else { $t.Border }
            $c.FlatAppearance.MouseOverBackColor = if ($isPrim) { $t.AccentHov } else { $t.Border }
            $c.FlatAppearance.MouseDownBackColor = $t.AccentDim
            $c.Cursor = [Windows.Forms.Cursors]::Hand
        } elseif ($c -is [Windows.Forms.DataGridView]) {
            $c.BackgroundColor = $t.Surface; $c.GridColor = $t.Border; $c.BorderStyle = 'None'
            $c.EnableHeadersVisualStyles = $false
            $c.ColumnHeadersBorderStyle = 'Single'; $c.ColumnHeadersHeight = 28
            $c.ColumnHeadersDefaultCellStyle.BackColor = $t.Surface2
            $c.ColumnHeadersDefaultCellStyle.ForeColor = $t.Text
            $c.ColumnHeadersDefaultCellStyle.SelectionBackColor = $t.Surface2
            $c.DefaultCellStyle.BackColor = $t.Input; $c.DefaultCellStyle.ForeColor = $t.Text
            $c.DefaultCellStyle.SelectionBackColor = $t.AccentDim; $c.DefaultCellStyle.SelectionForeColor = $t.Text
            $c.AlternatingRowsDefaultCellStyle.BackColor = $t.Surface
        }
        if ($c.HasChildren) { Set-DarkTheme $c }
    }
}
function Load-UiIcons {
    $script:UiIcons = @{}
    if (Test-Path -LiteralPath $script:UiIconsPath -PathType Leaf) {
        try {
            $j = Get-Content -LiteralPath $script:UiIconsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j) { foreach ($pr in $j.PSObject.Properties) { $script:UiIcons[$pr.Name] = [string]$pr.Value } }
        } catch {}
    }
}
function Save-UiIcons {
    try {
        $dir = Split-Path -Parent $script:UiIconsPath
        if (-not (Test-Path -LiteralPath $dir)) { [void][IO.Directory]::CreateDirectory($dir) }
        $obj = [pscustomobject]$script:UiIcons
        [IO.File]::WriteAllText($script:UiIconsPath, (ConvertTo-Json $obj -Depth 3), (New-Object Text.UTF8Encoding($false)))
    } catch {}
}
function New-FallbackCardBitmap([string]$name) {
    $bmp = New-Object Drawing.Bitmap(96, 96)
    $g = [Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = 'AntiAlias'; $g.Clear([Drawing.Color]::Transparent)
        $brushBg = New-Object Drawing.SolidBrush($script:Theme.Surface2)
        $penBord = New-Object Drawing.Pen($script:Theme.Border, 2)
        $g.FillEllipse($brushBg, 8, 8, 80, 80); $g.DrawEllipse($penBord, 8, 8, 80, 80)
        $clean = ($name -replace '[^A-Za-z0-9]', '')
        $abbr = if ($clean.Length -ge 2) { $clean.Substring(0, 2).ToUpperInvariant() } elseif ($name.Length -ge 1) { $name.Substring(0, 1).ToUpperInvariant() } else { '?' }
        $fnt = New-Object Drawing.Font($script:UiFontName, 22, [Drawing.FontStyle]::Bold)
        $sf = New-Object Drawing.StringFormat; $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
        $brushTxt = New-Object Drawing.SolidBrush($script:Theme.AccentHov)
        $g.DrawString($abbr, $fnt, $brushTxt, (New-Object Drawing.RectangleF(8, 8, 80, 80)), $sf)
        $brushBg.Dispose(); $penBord.Dispose(); $fnt.Dispose(); $sf.Dispose(); $brushTxt.Dispose()
    } finally { $g.Dispose() }
    $bmp
}
# ===Card Icons n Imaging
function New-SmoothedIconBitmap($srcImg, [int]$boxW = 128, [int]$boxH = 102) {
    $dst = New-Object Drawing.Bitmap($boxW, $boxH)
    $g = [Drawing.Graphics]::FromImage($dst)
    try {
        $g.Clear([Drawing.Color]::Transparent)
        $g.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::HighQuality
        $g.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g.CompositingQuality = [Drawing.Drawing2D.CompositingQuality]::HighQuality
        $pad = 4
        $availW = $boxW - ($pad * 2); $availH = $boxH - ($pad * 2)
        $scale = [Math]::Min($availW / [double]$srcImg.Width, $availH / [double]$srcImg.Height)
        $dw = [Math]::Max(1, [int][Math]::Round($srcImg.Width * $scale))
        $dh = [Math]::Max(1, [int][Math]::Round($srcImg.Height * $scale))
        $dx = [int](($boxW - $dw) / 2); $dy = [int](($boxH - $dh) / 2)
        $ia = New-Object Drawing.Imaging.ImageAttributes
        try {
            # Clamp edge pixels via TileFlipXY so bicubic scaling does not create dark/transparent border fringes
            $ia.SetWrapMode([Drawing.Drawing2D.WrapMode]::TileFlipXY)
            $g.DrawImage($srcImg, (New-Object Drawing.Rectangle($dx, $dy, $dw, $dh)), 0, 0, $srcImg.Width, $srcImg.Height, [Drawing.GraphicsUnit]::Pixel, $ia)
        } finally { $ia.Dispose() }
    } finally { $g.Dispose() }
    $dst
}
# Icon lookup priority: custom override (ui-icons.json) -> ExePath icon -> 2-letter fallback badge
function Get-ProfileCardImage($p) {
    $key = Get-ContainerName $p
    $cand = @()
    if ($script:UiIcons.ContainsKey($key) -and $script:UiIcons[$key]) { $cand += $script:UiIcons[$key] }
    if ($p.ExePath) { $cand += (Resolve-RulePath $p.ExePath) }
    foreach ($path in $cand) {
        if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        try {
            if ($path -match '\.(exe|ico|dll)$') {
                $rawBmp = $null
                # Probe large icon sizes first; ExtractAssociatedIcon caps at 32x32
                foreach ($sz in @(256, 128, 64)) {
                    $ph = New-Object IntPtr[] 1; $pidArr = New-Object uint32[] 1
                    $cnt = [ACM.IconUtil]::PrivateExtractIcons($path, 0, $sz, $sz, $ph, $pidArr, 1, 0)
                    if ($cnt -gt 0 -and $ph[0] -ne [IntPtr]::Zero) {
                        try {
                            $ic = [Drawing.Icon]::FromHandle($ph[0])
                            try { $rawBmp = $ic.ToBitmap() } finally { $ic.Dispose() }
                        } finally { [void][ACM.IconUtil]::DestroyIcon($ph[0]) } # FromHandle doesnt take HICON ownership
                        if ($rawBmp) { break }
                    }
                }
                if (-not $rawBmp) {
                    $ico = [Drawing.Icon]::ExtractAssociatedIcon($path)
                    if ($ico) { try { $rawBmp = $ico.ToBitmap() } finally { $ico.Dispose() } }
                }
                if ($rawBmp) {
                    try { return (New-SmoothedIconBitmap $rawBmp) } finally { $rawBmp.Dispose() }
                }
            } else {
                # Load via byte array instead of Image.FromFile() so the file on disk isntt locked
                $bytes = [IO.File]::ReadAllBytes($path)
                $ms = New-Object IO.MemoryStream(, $bytes)
                try {
                    $img = [Drawing.Image]::FromStream($ms)
                    try { return (New-SmoothedIconBitmap $img) } finally { $img.Dispose() }
                } finally { $ms.Dispose() }
            }
        } catch {}
    }
    New-FallbackCardBitmap $p.Name
}
Load-UiIcons

function Pt($x, $y) { [Drawing.Point]::new($x, $y) }
function Sz($w, $h) { [Drawing.Size]::new($w, $h) }
function Ctl([string]$Type, [hashtable]$Prop, $Parent) {
    $c = New-Object "System.Windows.Forms.$Type"
    foreach ($k in $Prop.Keys) { $c.$k = $Prop[$k] }
    if ($Parent) { $Parent.Controls.Add($c) }
    $c
}
function Btn($text, $x, $y, $w, $parent, [scriptblock]$click, $anchor = 'Top,Left') {
    $b = Ctl Button @{ Text = $text; Location = (Pt $x $y); Size = (Sz $w 28); Anchor = [Windows.Forms.AnchorStyles]$anchor } $parent
    $b.add_Click($click); $b
}
function Safe([scriptblock]$sb) {
    try { & $sb } catch { Log "ERROR: $($_.Exception.Message)"; [void][Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Error', 'OK', 'Error') }
}

# ===Main Window n Shell
$F = Ctl Form @{ Text = 'AppContainer Manager'; ClientSize = (Sz 1120 830); StartPosition = 'CenterScreen'; MinimumSize = (Sz 1040 620); Font = $script:FontBody } $null
# Embedded 128x128 PNG app icon so the script needs no external .ico file
$F.Icon = [Drawing.Icon]::FromHandle(([Drawing.Bitmap]::new([IO.MemoryStream]::new([Convert]::FromBase64String('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')))).GetHicon())
$script:NavBar = Ctl FlowLayoutPanel @{ Location = (Pt 10 10); Size = (Sz 1100 38); WrapContents = $true; Anchor = [Windows.Forms.AnchorStyles]'Top,Left,Right'; Tag = 'Surface'; Padding = (New-Object Windows.Forms.Padding(4, 4, 4, 2)) } $F
# Toggled dynamically by Sync-PresetTab (05-GuiController.ps1) when *n placeholders exist
$script:PresetBar = Ctl Panel @{ Location = (Pt 10 50); Size = (Sz 1100 32); Anchor = [Windows.Forms.AnchorStyles]'Top,Left,Right'; Visible = $false; Tag = 'Surface' } $F
# Offset TabControl (-4, -4) inside TabHost with 1px flat buttons to hide native un-themeable tab headers
$script:TabHost = Ctl Panel @{ Location = (Pt 10 52); Size = (Sz 1100 536); Anchor = [Windows.Forms.AnchorStyles]'Top,Bottom,Left,Right' } $F
$script:Tabs = Ctl TabControl @{ Location = (Pt -4 -4); Size = (Sz 1108 544); Anchor = [Windows.Forms.AnchorStyles]'Top,Bottom,Left,Right'
    Appearance = 'FlatButtons'; ItemSize = (Sz 0 1); SizeMode = 'Fixed' } $script:TabHost
$script:ProgLbl = Ctl Label @{ Text = 'Ready.'; Location = (Pt 10 628); Size = (Sz 1100 16); Anchor = [Windows.Forms.AnchorStyles]'Bottom,Left,Right'; Tag = 'Muted' } $F
$script:ProgBar = Ctl ProgressBar @{ Location = (Pt 10 646); Size = (Sz 1100 14); Minimum = 0; Maximum = 100; Style = 'Continuous'; Anchor = [Windows.Forms.AnchorStyles]'Bottom,Left,Right' } $F
$script:LogBox = Ctl TextBox @{ Location = (Pt 10 666); Size = (Sz 1100 154); Multiline = $true; ReadOnly = $true; ScrollBars = 'Vertical'
    Anchor = [Windows.Forms.AnchorStyles]'Bottom,Left,Right'; Font = (New-Object Drawing.Font('Consolas', 9)) } $F

$tabContainers = Ctl TabPage @{ Text = 'Containers' } $script:Tabs
$tabGen = Ctl TabPage @{ Text = 'General'; AutoScroll = $true } $script:Tabs
$tabRules = Ctl TabPage @{ Text = 'Folders && files' } $script:Tabs
$tabReg = Ctl TabPage @{ Text = 'Registry' } $script:Tabs
$tabNet = Ctl TabPage @{ Text = 'Network && capabilities'; AutoScroll = $true } $script:Tabs
$tabHard = Ctl TabPage @{ Text = 'Hardening' } $script:Tabs
$tabEnv = Ctl TabPage @{ Text = 'Env && quotas'; AutoScroll = $true } $script:Tabs
$tabPreset = Ctl TabPage @{ Text = 'Preset (*n)' } $script:Tabs
# Ensure non-zero initial size while tab is unselected so Bottom-anchored children compute valid bounds
if ($tabPreset.Width -lt 200 -or $tabPreset.Height -lt 200) { $tabPreset.Size = (Sz 1100 536) }
$tabNotes = Ctl TabPage @{ Text = 'Notes' } $script:Tabs
foreach ($pt in @($tabGen, $tabRules, $tabReg, $tabNet, $tabHard, $tabEnv, $tabPreset)) { [void]$script:ProfileOnlyTabs.Add($pt) }

$script:CardsFlow = Ctl FlowLayoutPanel @{ Dock = 'Fill'; AutoScroll = $true; WrapContents = $true; Padding = (New-Object Windows.Forms.Padding(8)) } $tabContainers
$script:ImgTip = New-Object Windows.Forms.ToolTip
# ===Navigation Bar
function Switch-NavTab($targetTab) {
    if (-not $targetTab) { return }
    if ($script:Cur) { Save-UiToProfile } # Commit current tab edits before switching
    $script:Tabs.SelectedTab = $targetTab
    if ($script:NavBar) { [void]$script:NavBar.Focus() } # Shift focus so active inputs/grids flush edits
    if ($targetTab -eq $tabContainers) {
        # Refresh selected card thumbnail in case ExePath changed, dispose the previous Bitmap
        if ($script:Cur -and $script:SelectedCardIdx -ge 0 -and $script:SelectedCardIdx -lt $script:CardsFlow.Controls.Count) {
            $cardCtrl = $script:CardsFlow.Controls[$script:SelectedCardIdx]
            foreach ($ch in $cardCtrl.Controls) {
                if ($ch -is [Windows.Forms.PictureBox]) {
                    $old = $ch.Image; $ch.Image = Get-ProfileCardImage $script:Cur; if ($old) { $old.Dispose() }
                }
            }
        }
        Update-SelectedCardVisual
    }
    foreach ($kv in $script:NavMap.GetEnumerator()) {
        $isAct = ($kv.Value -eq $targetTab)
        $btn = $kv.Key
        $btn.BackColor = if ($isAct) { $script:Theme.Accent } else { $script:Theme.Surface2 }
        $btn.FlatAppearance.BorderColor = if ($isAct) { $script:Theme.Accent } else { $script:Theme.Border }
    }
}
function Add-NavButton([string]$label, $tab, $parentPanel, [int]$w = 0) {
    $b = New-Object Windows.Forms.Button
    $b.Name = 'KeepStyle'; $b.Tag = $tab
    $b.Text = $label; $b.Height = 28; $b.FlatStyle = 'Flat'
    $b.UseMnemonic = $false; $b.Cursor = [Windows.Forms.Cursors]::Hand
    $b.Font = $script:FontBold; $b.ForeColor = $script:Theme.Text
    $b.FlatAppearance.BorderSize = 1; $b.FlatAppearance.MouseOverBackColor = $script:Theme.AccentHov
    $b.Margin = New-Object Windows.Forms.Padding(2, 1, 4, 1)
    $b.Width = if ($w -gt 0) { $w } else { ([Windows.Forms.TextRenderer]::MeasureText($label, $script:FontBold).Width + 24) }
    $b.add_Click({ param($s, $e) Switch-NavTab $s.Tag })
    [void]$parentPanel.Controls.Add($b)
    $script:NavMap[$b] = $tab
    $b
}
[void](Add-NavButton 'Containers' $tabContainers $script:NavBar)
[void](Add-NavButton 'General' $tabGen $script:NavBar)
[void](Add-NavButton 'Folders & files' $tabRules $script:NavBar)
[void](Add-NavButton 'Registry' $tabReg $script:NavBar)
[void](Add-NavButton 'Hardening' $tabHard $script:NavBar)
[void](Add-NavButton 'Network & capabilities' $tabNet $script:NavBar)
[void](Add-NavButton 'Env & quotas' $tabEnv $script:NavBar)
[void](Add-NavButton 'Notes' $tabNotes $script:NavBar)
$bDesk = Ctl Button @{ Name = 'KeepStyle'; Text = 'Desktops...'; Height = 28; FlatStyle = 'Flat'; UseMnemonic = $false; Font = $script:FontBold; BackColor = $script:Theme.Surface2; ForeColor = $script:Theme.Text; Margin = (New-Object Windows.Forms.Padding(12, 1, 4, 1)); Width = ([Windows.Forms.TextRenderer]::MeasureText('Desktops...', $script:FontBold).Width + 24); Cursor = [Windows.Forms.Cursors]::Hand } $script:NavBar
$bDesk.FlatAppearance.BorderSize = 1; $bDesk.FlatAppearance.BorderColor = $script:Theme.Border; $bDesk.FlatAppearance.MouseOverBackColor = $script:Theme.AccentHov
$bDesk.add_Click({ Safe { Show-DesktopManagerDialog } })
$script:BtnNavPreset = Add-NavButton 'Preset (*n)' $tabPreset $script:PresetBar 130
$script:BtnNavPreset.Location = (Pt 6 2)
$script:BtnNavPreset.Height = 26

[void](Ctl Label @{ Location = (Pt 12 10); Size = (Sz 775 34); Anchor = [Windows.Forms.AnchorStyles]'Top,Left,Right'
    Text = 'Dynamic path placeholders (*n) detected in this ruleset. Enter a short explanation for each placeholder below, then export as a standalone preset file.' } $tabPreset)
$script:PresetVarGrid = Ctl DataGridView @{ Location = (Pt 12 48); Size = (Sz 775 375); Anchor = [Windows.Forms.AnchorStyles]'Top,Bottom,Left,Right'
    AllowUserToAddRows = $false; RowHeadersVisible = $false; SelectionMode = 'FullRowSelect'; MultiSelect = $false
    AutoSizeColumnsMode = 'Fill'; BackgroundColor = [Drawing.SystemColors]::Window; EditMode = 'EditOnEnter' } $tabPreset
$pvc1 = New-Object Windows.Forms.DataGridViewTextBoxColumn; $pvc1.Name = 'Token'; $pvc1.HeaderText = 'Token'; $pvc1.FillWeight = 18; $pvc1.ReadOnly = $true
$pvc2 = New-Object Windows.Forms.DataGridViewTextBoxColumn; $pvc2.Name = 'Description'; $pvc2.HeaderText = 'Short explanation for user (required for export)'; $pvc2.FillWeight = 82; $pvc2.ReadOnly = $false
[void]$script:PresetVarGrid.Columns.Add($pvc1); [void]$script:PresetVarGrid.Columns.Add($pvc2)
$script:PresetVarGrid.add_CellEndEdit({ Save-PresetVarsFromGrid })
$script:BtnExportPreset = Btn 'Export Preset...' 12 432 140 $tabPreset { Safe { Export-CurrentPreset } } 'Bottom,Left'
$lblPresetFoot = Ctl Label @{ Location = (Pt 162 436); Size = (Sz 625 48); Anchor = [Windows.Forms.AnchorStyles]'Bottom,Left,Right'
    Text = 'Presets are saved as separate .acmpreset.json files and are never written inside profiles.json.' } $tabPreset
$script:BtnExportPreset.BringToFront(); $lblPresetFoot.BringToFront()

# ===General tab
# Bound control registries used by 05-GuiController.ps1 (Select-Profile / Save-UiToProfile)
# !! Keys in $script:Chk MUST use 'Section.Property' (e.g. 'Hard.ShowConsole') so
# controller loops can split on '.' and read/write $profile.$section.$property dynamically
$script:T = @{}; $script:Chk = @{}
function Add-Row($parent, $label, $key, $y, $ro = $false, $w = 520) {
    [void](Ctl Label @{ Text = $label; Location = (Pt 15 ($y + 4)); AutoSize = $true } $parent)
    $script:T[$key] = Ctl TextBox @{ Location = (Pt 140 $y); Size = (Sz $w 24); ReadOnly = $ro } $parent
}
Add-Row $tabGen 'Profile name' 'Name' 15 $true 300
Add-Row $tabGen 'Description' 'Desc' 50
Add-Row $tabGen 'Executable' 'Exe' 85
Add-Row $tabGen 'Arguments' 'Args' 120
Add-Row $tabGen 'Working dir' 'Work' 155
Add-Row $tabGen 'Container name' 'CName' 190 $true 300
Add-Row $tabGen 'Container SID' 'Sid' 225 $true 600
[void](Btn 'Browse...' 670 84 90 $tabGen { Safe {
    $d = New-Object Windows.Forms.OpenFileDialog; $d.Filter = 'Programs (*.exe)|*.exe|All files|*.*'
    if ($d.ShowDialog() -eq 'OK') { $script:T.Exe.Text = $d.FileName } } })
[void](Btn 'Browse...' 670 154 90 $tabGen { Safe {
    $d = New-Object Windows.Forms.FolderBrowserDialog
    if ($d.ShowDialog() -eq 'OK') { $script:T.Work.Text = $d.SelectedPath } } })
$script:Status = Ctl Label @{ Text = ''; Location = (Pt 15 265); AutoSize = $true } $tabGen
function Add-Check($parent, $key, $text, $x, $y, $w = 760) {
    $script:Chk[$key] = Ctl CheckBox @{ Text = $text; Location = (Pt $x $y); Size = (Sz $w 34) } $parent
}
Add-Check $tabGen 'Hard.ShowConsole' 'Give the app its own console window (tick for command-line programs such as cmd.exe)' 15 300
Add-Check $tabGen 'Hard.Ephemeral' 'Ephemeral / disposable container (unique throwaway SID per launch, wiped on exit; uses ambient ACLs only)' 15 336
[void](Ctl Label @{ Location = (Pt 15 378); Size = (Sz 770 110); Text = "Tip: to test a profile, set the executable to C:\Windows\System32\cmd.exe and tick the console box. Run 'dir' on allowed and denied paths.`r`nContainer SIDs are derived deterministically from the profile name (profile names are locked after creation)." } $tabGen)

# ===Rules tab
$grpRule = Ctl GroupBox @{ Text = 'Path Rule Builder (whitelist Allow rules)'; Location = (Pt 10 8); Size = (Sz 785 130); Anchor = [Windows.Forms.AnchorStyles]'Top,Left,Right' } $tabRules
[void](Ctl Label @{ Text = 'Path:'; Location = (Pt 12 25); AutoSize = $true } $grpRule)
$script:RulePath = Ctl TextBox @{ Location = (Pt 55 22); Size = (Sz 470 24); Anchor = [Windows.Forms.AnchorStyles]'Top,Left' } $grpRule
[void](Btn 'Browse Folder...' 535 20 120 $grpRule { Safe {
    $d = New-Object Windows.Forms.FolderBrowserDialog; if ($d.ShowDialog() -eq 'OK') { $script:RulePath.Text = $d.SelectedPath; $script:RuleAccess.Focus() } } } 'Top,Left')
[void](Btn 'Browse File...' 662 20 105 $grpRule { Safe {
    $d = New-Object Windows.Forms.OpenFileDialog; if ($d.ShowDialog() -eq 'OK') { $script:RulePath.Text = $d.FileName; $script:RuleAccess.Focus() } } } 'Top,Left')

[void](Ctl Label @{ Text = 'Scope:'; Location = (Pt 12 60); AutoSize = $true } $grpRule)
$script:RuleScope = Ctl ComboBox @{ Location = (Pt 55 57); Size = (Sz 195 24); DropDownStyle = 'DropDownList'; Anchor = [Windows.Forms.AnchorStyles]'Top,Left' } $grpRule
[void]$script:RuleScope.Items.AddRange(@($script:PathScopeUi.Values))
$script:RuleScope.SelectedIndex = 0

[void](Ctl Label @{ Text = 'Permission:'; Location = (Pt 258 60); AutoSize = $true } $grpRule)
$script:RuleAccess = Ctl ComboBox @{ Location = (Pt 338 57); Size = (Sz 115 24); DropDownStyle = 'DropDownList'; Anchor = [Windows.Forms.AnchorStyles]'Top,Left' } $grpRule
[void]$script:RuleAccess.Items.AddRange(@('Read', 'ReadWrite', 'ReadExecute', 'Full'))
$script:RuleAccess.SelectedIndex = 0

[void](Btn '+ Add / Update Rule' 555 55 140 $grpRule { Safe { & $script:SaveRuleAction } } 'Top,Left')
[void](Btn 'Clear' 700 55 68 $grpRule { Safe {
    $script:RulePath.Text = ''; $script:RuleScope.SelectedIndex = 0; $script:RuleAccess.SelectedIndex = 0; $script:RuleForce.Checked = $false
} } 'Top,Left')

$script:RuleForce = Ctl CheckBox @{ Text = 'Force explicit ACE even on system paths (use if nested Program Files/Windows folders drop S-1-15-2-2)'; Location = (Pt 55 93); Size = (Sz 680 24) } $grpRule

$script:SaveRuleAction = {
    $raw = $script:RulePath.Text.Trim()
    if (-not $raw) { throw 'Please select or enter a path first.' }
    $p = Resolve-UiRulePath $raw
    $s = [string]$script:RuleScope.SelectedItem
    $a = [string]$script:RuleAccess.SelectedItem
    $frc = [bool]$script:RuleForce.Checked
    $found = $false
    foreach ($r in $script:Grid.Rows) {
        if (([string]$r.Cells['Path'].Value).Trim() -ieq $p) {
            $r.Cells['Path'].Value = $p; $r.Cells['Scope'].Value = $s; $r.Cells['Access'].Value = $a; $r.Cells['Force'].Value = $frc
            $found = $true; break
        }
    }
    if (-not $found) { Add-RuleRow $p (Resolve-PathScopeKey $s) $a $frc }
    Save-UiToProfile; Sync-PresetTab; Log "Path rule configured: [$s] $a -> $p"
}
$script:RulePath.add_KeyDown({ if ($_.KeyCode -eq 'Enter') { $_.SuppressKeyPress = $true; Safe { & $script:SaveRuleAction } } })

$script:Grid = Ctl DataGridView @{ Location = (Pt 10 144); Size = (Sz 785 246); Anchor = [Windows.Forms.AnchorStyles]'Top,Bottom,Left,Right'
    AllowUserToAddRows = $false; RowHeadersVisible = $false; SelectionMode = 'FullRowSelect'; MultiSelect = $true
    AutoSizeColumnsMode = 'Fill'; BackgroundColor = [Drawing.SystemColors]::Window; ReadOnly = $true } $tabRules

$c1 = New-Object Windows.Forms.DataGridViewTextBoxColumn; $c1.Name = 'Path'; $c1.HeaderText = 'Path'; $c1.FillWeight = 54
$c2 = New-Object Windows.Forms.DataGridViewTextBoxColumn; $c2.Name = 'Scope'; $c2.HeaderText = 'Scope (Folders)'; $c2.FillWeight = 24
$c3 = New-Object Windows.Forms.DataGridViewTextBoxColumn; $c3.Name = 'Access'; $c3.HeaderText = 'Access'; $c3.FillWeight = 14
$c4 = New-Object Windows.Forms.DataGridViewCheckBoxColumn; $c4.Name = 'Force'; $c4.HeaderText = 'Force'; $c4.FillWeight = 8
[void]$script:Grid.Columns.Add($c1); [void]$script:Grid.Columns.Add($c2); [void]$script:Grid.Columns.Add($c3); [void]$script:Grid.Columns.Add($c4)

function Add-RuleRow([string]$path, [string]$scope = 'Recursive', [string]$acc = 'Read', [bool]$force = $false) {
    if ([string]::IsNullOrWhiteSpace($path)) { return }
    $sk = Resolve-PathScopeKey $scope
    [void]$script:Grid.Rows.Add($path, $script:PathScopeUi[$sk], $acc, $force)
}

$script:Grid.add_SelectionChanged({
    if ($script:Grid.SelectedRows.Count -gt 0) {
        $row = $script:Grid.SelectedRows[0]
        $script:RulePath.Text = [string]$row.Cells['Path'].Value
        $script:RuleScope.SelectedItem = $script:PathScopeUi[(Resolve-PathScopeKey ([string]$row.Cells['Scope'].Value))]
        $script:RuleAccess.SelectedItem = [string]$row.Cells['Access'].Value
        $script:RuleForce.Checked = [bool]$row.Cells['Force'].Value
    }
})

# ===Action buttons
$btnRem = Btn 'Remove selected' 10 400 115 $tabRules { Safe {
    foreach ($r in @($script:Grid.SelectedRows)) { $script:Grid.Rows.Remove($r) }
    Save-UiToProfile; Sync-PresetTab } } 'Bottom,Left'
$btnAddWin = Btn 'Add Windows (RX)' 131 400 125 $tabRules { Safe {
    Add-RuleRow (Resolve-RulePath '%SystemRoot%') 'Recursive' 'ReadExecute' $false; Save-UiToProfile } } 'Bottom,Left'
$btnAddRoot = Btn 'Add C:\ (Folder, RX)' 262 400 125 $tabRules { Safe {
    Add-RuleRow 'C:\' 'FolderOnly' 'ReadExecute' $false; Save-UiToProfile } } 'Bottom,Left'
$btnAudit = Btn 'Audit rules' 393 400 88 $tabRules { Safe { Invoke-Audit } } 'Bottom,Left'
$btnDryRun = Btn 'Dry-run Apply' 487 400 95 $tabRules { Safe {
    Save-UiToProfile; if ($script:Cur) { Invoke-Apply $script:Cur $true } } } 'Bottom,Left'

$btnRem.BringToFront(); $btnAddWin.BringToFront(); $btnAddRoot.BringToFront(); $btnAudit.BringToFront(); $btnDryRun.BringToFront()

$lblFoot = Ctl Label @{ Location = (Pt 10 435); Size = (Sz 785 55); Anchor = [Windows.Forms.AnchorStyles]'Bottom,Left,Right'
    Text = "Whitelist only (AppContainer denies everything else by default). Scopes: This folder only = directory itself (no child access; ideal for C:\ + cd);`r`nFolder + direct contents = (OI)(CI)(NP) 1-level access (no grandchildren; ReadWrite still allows modifying/deleting direct subfolder objects); Recursive = (OI)(CI) full tree." } $tabRules
$lblFoot.BringToFront()

# ===Registry tab (keep separate)
$grpReg = Ctl GroupBox @{ Text = 'Registry Rule Builder (applied by Apply (admin); e.g. HKCU\Software\MyApp or HKLM\SOFTWARE\Vendor)'; Location = (Pt 10 8); Size = (Sz 785 128); Anchor = [Windows.Forms.AnchorStyles]'Top,Left,Right' } $tabReg
[void](Ctl Label @{ Text = 'Key:'; Location = (Pt 12 25); AutoSize = $true } $grpReg)
$script:RegPath = Ctl TextBox @{ Location = (Pt 55 22); Size = (Sz 712 24); Anchor = [Windows.Forms.AnchorStyles]'Top,Left,Right' } $grpReg

[void](Ctl Label @{ Text = 'Scope:'; Location = (Pt 12 60); AutoSize = $true } $grpReg)
$script:RegScope = Ctl ComboBox @{ Location = (Pt 55 57); Size = (Sz 195 24); DropDownStyle = 'DropDownList'; Anchor = [Windows.Forms.AnchorStyles]'Top,Left' } $grpReg
[void]$script:RegScope.Items.AddRange(@($script:RegScopeUi.Values))
$script:RegScope.SelectedIndex = 0

[void](Ctl Label @{ Text = 'Permission:'; Location = (Pt 256 60); AutoSize = $true } $grpReg)
$script:RegAccess = Ctl ComboBox @{ Location = (Pt 336 57); Size = (Sz 100 24); DropDownStyle = 'DropDownList'; Anchor = [Windows.Forms.AnchorStyles]'Top,Left' } $grpReg
[void]$script:RegAccess.Items.AddRange(@('Read', 'ReadWrite', 'Full'))
$script:RegAccess.SelectedIndex = 0

[void](Ctl Label @{ Text = 'View:'; Location = (Pt 446 60); AutoSize = $true } $grpReg)
$script:RegView = Ctl ComboBox @{ Location = (Pt 488 57); Size = (Sz 80 24); DropDownStyle = 'DropDownList'; Anchor = [Windows.Forms.AnchorStyles]'Top,Left' } $grpReg
[void]$script:RegView.Items.AddRange(@('Both', '64', '32'))
$script:RegView.SelectedIndex = 0

$script:SaveRegAction = {
    $p = Resolve-RegPath $script:RegPath.Text
    if (-not $p) { throw 'Please enter a registry hive or key path (e.g. HKCU or HKLM\SOFTWARE\Vendor).' }
    if ($p -notmatch '^(HKCU|HKLM|HKCR|HKU|HKCC)(\\.+)?$') { throw 'Use a valid hive or subkey under HKCU, HKLM, HKCR, HKU, or HKCC.' }
    $s = [string]$script:RegScope.SelectedItem
    $a = [string]$script:RegAccess.SelectedItem
    $v = [string]$script:RegView.SelectedItem
    $found = $false
    foreach ($r in $script:RegGrid.Rows) {
        if (([string]$r.Cells['Path'].Value).Trim() -ieq $p) {
            $r.Cells['Scope'].Value = $s; $r.Cells['Access'].Value = $a; $r.Cells['View'].Value = $v; $found = $true; break
        }
    }
    if (-not $found) { Add-RegRow $p (Resolve-RegScopeKey $s) $a $v }
    Save-UiToProfile; Log "Registry rule configured: [$s/$v] $a -> $p"
}

[void](Btn '+ Add / Update Key' 575 55 130 $grpReg { Safe { & $script:SaveRegAction } } 'Top,Left')
[void](Btn 'Clear' 710 55 60 $grpReg { Safe {
    $script:RegPath.Text = ''; $script:RegScope.SelectedIndex = 0; $script:RegAccess.SelectedIndex = 0; $script:RegView.SelectedIndex = 0
} } 'Top,Left')
$script:RegPath.add_KeyDown({ if ($_.KeyCode -eq 'Enter') { $_.SuppressKeyPress = $true; Safe { & $script:SaveRegAction } } })
[void](Ctl Label @{ Text = 'View: Both applies 64-bit + WOW6432Node (32-bit); HKCR routes to target user Software\Classes or HKLM.'; Location = (Pt 55 95); AutoSize = $true } $grpReg)

Add-Check $tabReg 'Hard.RegRead' 'Launch-time token capability registryRead (no Apply needed; reads standard keys whose DACLs grant registryRead)' 12 140 775
$script:Chk['Hard.RegRead'].Height = 26; $script:Chk['Hard.RegRead'].Anchor = [Windows.Forms.AnchorStyles]'Top,Left,Right'

$script:RegGrid = Ctl DataGridView @{ Location = (Pt 10 170); Size = (Sz 785 220); Anchor = [Windows.Forms.AnchorStyles]'Top,Bottom,Left,Right'
    AllowUserToAddRows = $false; RowHeadersVisible = $false; SelectionMode = 'FullRowSelect'; MultiSelect = $true
    AutoSizeColumnsMode = 'Fill'; BackgroundColor = [Drawing.SystemColors]::Window; ReadOnly = $true } $tabReg

$rc1 = New-Object Windows.Forms.DataGridViewTextBoxColumn; $rc1.Name = 'Path'; $rc1.HeaderText = 'Registry Key Path'; $rc1.FillWeight = 48
$rc2 = New-Object Windows.Forms.DataGridViewTextBoxColumn; $rc2.Name = 'Scope'; $rc2.HeaderText = 'Scope (Subkeys)'; $rc2.FillWeight = 26
$rc3 = New-Object Windows.Forms.DataGridViewTextBoxColumn; $rc3.Name = 'Access'; $rc3.HeaderText = 'Access Level'; $rc3.FillWeight = 16
$rc4 = New-Object Windows.Forms.DataGridViewTextBoxColumn; $rc4.Name = 'View'; $rc4.HeaderText = 'View'; $rc4.FillWeight = 10
[void]$script:RegGrid.Columns.Add($rc1); [void]$script:RegGrid.Columns.Add($rc2); [void]$script:RegGrid.Columns.Add($rc3); [void]$script:RegGrid.Columns.Add($rc4)

function Add-RegRow([string]$path, [string]$scope = 'Recursive', [string]$acc = 'Read', [string]$view = 'Both') {
    if ([string]::IsNullOrWhiteSpace($path)) { return }
    $sk = Resolve-RegScopeKey $scope
    $rv = if ($view -in 'Both', '64', '32') { $view } else { 'Both' }
    [void]$script:RegGrid.Rows.Add($path, $script:RegScopeUi[$sk], $acc, $rv)
}
$script:RegGrid.add_SelectionChanged({
    if ($script:RegGrid.SelectedRows.Count -gt 0) {
        $row = $script:RegGrid.SelectedRows[0]
        $script:RegPath.Text = [string]$row.Cells['Path'].Value
        $script:RegScope.SelectedItem = $script:RegScopeUi[(Resolve-RegScopeKey ([string]$row.Cells['Scope'].Value))]
        $script:RegAccess.SelectedItem = [string]$row.Cells['Access'].Value
        $script:RegView.SelectedItem = if ($row.Cells['View'].Value) { [string]$row.Cells['View'].Value } else { 'Both' }
    }
})

$btnRegRem = Btn 'Remove selected' 10 400 125 $tabReg { Safe {
    foreach ($r in @($script:RegGrid.SelectedRows)) { $script:RegGrid.Rows.Remove($r) }
    Save-UiToProfile } } 'Bottom,Left'
$btnRegAudit = Btn 'Audit rules' 142 400 110 $tabReg { Safe { Invoke-Audit } } 'Bottom,Left'
$btnRegRem.BringToFront(); $btnRegAudit.BringToFront()

$lblRegFoot = Ctl Label @{ Location = (Pt 10 435); Size = (Sz 785 55); Anchor = [Windows.Forms.AnchorStyles]'Bottom,Left,Right'
    Text = "Registry ACLs use ContainerInherit via .NET RegistrySecurity (DACL-only; preserves TrustedInstaller ownership and avoids Set-Acl errors).`r`nWARNING: Never grant ReadWrite/Full on Run, IFEO, AppInit_DLLs, Environment, or COM/Shell keys (sandbox escape risk)." } $tabReg
$lblRegFoot.BringToFront()

# ===Network tab
Add-Check $tabNet 'Net.Client'     'Outbound internet (capability internetClient; on Public network profiles this also reaches LAN unless LAN/local block is ticked)' 15 8 980
Add-Check $tabNet 'Net.Server'     'Server capability (internetClientServer; inbound traffic still requires an explicit inbound firewall rule below)' 15 40 980
Add-Check $tabNet 'Net.Private'    'Home/work LAN (capability privateNetworkClientServer)' 15 72 980
Add-Check $tabNet 'Net.Loopback'   'Allow localhost/loopback via CheckNetIsolation (opens ALL localhost ports for this container SID; debug-grade)' 15 104 980
Add-Check $tabNet 'Net.AutoOfflineBlock' 'Auto-block all container network in Windows Firewall when 0 net capabilities are ticked (stops child ALE_APP_ID bypass)' 15 136 980
Add-Check $tabNet 'Net.BlockLanWhenClientOnly' 'Block LAN & non-internet IPs (LocalSubnet, DefaultGateway, RFC1918, loopback, reserved) in Internet-only mode' 15 168 980
Add-Check $tabNet 'Net.AllowCgnat'     'Soften: allow CGNAT 100.64.0.0/10 (Tailscale / ISP NAT)' 35 202 380
Add-Check $tabNet 'Net.AllowMulticast' 'Soften: allow multicast (224.0.0.0/4, ff00::/8)' 430 202 380
foreach ($k in @('Net.Client', 'Net.Server', 'Net.Private', 'Net.Loopback', 'Net.AutoOfflineBlock', 'Net.BlockLanWhenClientOnly')) { $script:Chk[$k].Height = 28 }
foreach ($k in @('Net.AllowCgnat', 'Net.AllowMulticast')) { $script:Chk[$k].Height = 24 }
Add-Check $tabNet 'Net.ServerAllowInbound' 'Allow inbound connections in Windows Firewall when Server capability is ticked (requires Apply)' 15 232 980
Add-Check $tabNet 'Net.FwBlockAll' 'Hard-block ALL inbound+outbound packets in Windows Firewall (does NOT stop DNS via Dnscache if a net capability is ticked)' 15 264 980
foreach ($k in @('Net.ServerAllowInbound', 'Net.FwBlockAll')) { $script:Chk[$k].Height = 28 }

[void](Ctl Label @{ Text = 'Server inbound TCP ports (comma separated, e.g. 8080,9000-9010):'; Location = (Pt 15 302); AutoSize = $true } $tabNet)
$script:T.SrvPorts = Ctl TextBox @{ Location = (Pt 440 299); Size = (Sz 340 24) } $tabNet
[void](Ctl Label @{ Text = 'Firewall block list (remote IPs, CIDRs, or IP ranges only; separated by comma/semicolon/space):'; Location = (Pt 15 332); AutoSize = $true } $tabNet)
$script:T.FwList = Ctl TextBox @{ Location = (Pt 15 354); Size = (Sz 765 24) } $tabNet
[void](Ctl Label @{ Text = 'Extra capability names (comma separated), e.g. documentsLibrary, lpacMedia:'; Location = (Pt 15 386); AutoSize = $true } $tabNet)
$script:T.Extra = Ctl TextBox @{ Location = (Pt 15 408); Size = (Sz 765 24) } $tabNet

$grpDev = Ctl GroupBox @{ Text = 'Hardware & Device Access (denied by default)'; Location = (Pt 15 442); Size = (Sz 765 56) } $tabNet
Add-Check $grpDev 'Dev.Mic'      'Microphone' 12 22 108
Add-Check $grpDev 'Dev.Webcam'   'Webcam'     126 22 92
Add-Check $grpDev 'Dev.Location' 'Location'   224 22 96
foreach ($dk in @('Dev.Mic', 'Dev.Webcam', 'Dev.Location')) { $script:Chk[$dk].Height = 24 }
$script:CurUsbHidMode = 'Off'; $script:CurUsbHidDevices = @()
[void](Btn 'USB / HID...' 334 19 112 $grpDev { Safe { Show-UsbHidPickerDialog } })
$script:LblUsbHid = Ctl Label @{ Text = 'USB/HID: Off'; Location = (Pt 456 24); Size = (Sz 295 20) } $grpDev

[void](Ctl Label @{ Location = (Pt 15 506); Size = (Sz 770 46); Text = "True offline mode = 0 net caps + AutoOfflineBlock. Specific USB/HID devices apply live container SID ACLs (press Apply (admin)).`r`nWindows Privacy settings (Settings -> Privacy & security) still govern Microphone, Camera, and Location consent." } $tabNet)

function Update-UsbHidLabel {
    if (-not $script:LblUsbHid) { return }
    $script:LblUsbHid.Text = switch ($script:CurUsbHidMode) {
        'All'      { 'USB/HID: Allow All (usb + humanInterfaceDevice)' }
        'Specific' { "USB/HID: $(@($script:CurUsbHidDevices).Count) specific device(s) selected" }
        default    { 'USB/HID: Off (denied)' }
    }
}
# ===USB / HID Device Picker Dialog
function Show-UsbHidPickerDialog {
    $dlg = Ctl Form @{ Text = 'USB & HID Device Access'; ClientSize = (Sz 780 510); StartPosition = 'CenterParent'; FormBorderStyle = 'FixedDialog'; MaximizeBox = $false; MinimizeBox = $false } $null
    $rbOff = Ctl RadioButton @{ Text = 'Off (deny all USB & HID devices)'; Location = (Pt 14 12); Size = (Sz 740 22) } $dlg
    $rbAll = Ctl RadioButton @{ Text = 'Allow all USB & HID devices (token capabilities: usb + humanInterfaceDevice + interface class SIDs)'; Location = (Pt 14 36); Size = (Sz 740 22) } $dlg
    $rbSpec = Ctl RadioButton @{ Text = 'Allow only selected USB / HID device(s) (grants container SID ACL on Apply (admin))'; Location = (Pt 14 60); Size = (Sz 740 22) } $dlg
    switch ($script:CurUsbHidMode) {
        'All'      { $rbAll.Checked = $true }
        'Specific' { $rbSpec.Checked = $true }
        default    { $rbOff.Checked = $true }
    }
    # Keep DataGridView ReadOnly and toggle Allow manually on click / space to avoid WinForms CheckBoxCell commit lag
    $dg = Ctl DataGridView @{ Location = (Pt 14 90); Size = (Sz 752 368); AllowUserToAddRows = $false; RowHeadersVisible = $false; SelectionMode = 'FullRowSelect'; AutoSizeColumnsMode = 'Fill'; BackgroundColor = [Drawing.SystemColors]::Window; ReadOnly = $true } $dlg
    $dc0 = New-Object Windows.Forms.DataGridViewCheckBoxColumn; $dc0.Name = 'Allow'; $dc0.HeaderText = 'Allow'; $dc0.FillWeight = 8; [void]$dg.Columns.Add($dc0)
    $dg.add_CellClick({
        param($s, $e)
        if ($e.RowIndex -ge 0 -and $e.ColumnIndex -eq 0) {
            $c = $dg.Rows[$e.RowIndex].Cells['Allow']
            $c.Value = -not [bool]$c.Value
        }
    })
    $dg.add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq 'Space' -and $dg.CurrentRow -and $dg.CurrentRow.Index -ge 0) {
            $e.SuppressKeyPress = $true; $e.Handled = $true
            $c = $dg.CurrentRow.Cells['Allow']
            $c.Value = -not [bool]$c.Value
        }
    })
    $dc1 = New-Object Windows.Forms.DataGridViewTextBoxColumn; $dc1.Name = 'Kind'; $dc1.HeaderText = 'Type'; $dc1.FillWeight = 8; $dc1.ReadOnly = $true; [void]$dg.Columns.Add($dc1)
    $dc2 = New-Object Windows.Forms.DataGridViewTextBoxColumn; $dc2.Name = 'Name'; $dc2.HeaderText = 'Device Name'; $dc2.FillWeight = 32; $dc2.ReadOnly = $true; [void]$dg.Columns.Add($dc2)
    $dc3 = New-Object Windows.Forms.DataGridViewTextBoxColumn; $dc3.Name = 'Mfg'; $dc3.HeaderText = 'Manufacturer'; $dc3.FillWeight = 18; $dc3.ReadOnly = $true; [void]$dg.Columns.Add($dc3)
    $dc4 = New-Object Windows.Forms.DataGridViewTextBoxColumn; $dc4.Name = 'Path'; $dc4.HeaderText = 'Device Interface Path'; $dc4.FillWeight = 34; $dc4.ReadOnly = $true; [void]$dg.Columns.Add($dc4)

    $loadDevices = {
        param($keepSel)
        $selSet = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
        foreach ($x in @($keepSel)) { if ($x) { [void]$selSet.Add([string]$x) } }
        $dg.Rows.Clear()
        $present = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
        # Native helper returns pipe-delimited "Kind|Name|Manufacturer|DeviceInterfacePath"
        foreach ($entry in [ACM.Native]::EnumerateUsbHidDevices()) {
            $parts = $entry -split '\|', 4
            if ($parts.Count -lt 4) { continue }
            [void]$present.Add($parts[3])
            [void]$dg.Rows.Add($selSet.Contains($parts[3]), $parts[0], $parts[1], $parts[2], $parts[3])
        }
        # Retain previously selected paths even when hardware is unplugged so Refresh/OK doesnt strip saved ACLs
        foreach ($savedPath in $selSet) {
            if (-not $present.Contains($savedPath)) {
                $k = if ($savedPath -match '(?i)^\\\\\?\\usb#') { 'USB' } else { 'HID' }
                [void]$dg.Rows.Add($true, $k, '[Unplugged / Offline]', '', $savedPath)
            }
        }
    }
    $syncEnabled = { $dg.Enabled = $rbSpec.Checked }
    $rbOff.add_CheckedChanged($syncEnabled); $rbAll.add_CheckedChanged($syncEnabled); $rbSpec.add_CheckedChanged($syncEnabled)
    & $loadDevices $script:CurUsbHidDevices
    & $syncEnabled

    [void](Btn 'Refresh Devices' 14 468 125 $dlg {
        $curChecked = @($dg.Rows | Where-Object { [bool]$_.Cells['Allow'].Value } | ForEach-Object { [string]$_.Cells['Path'].Value })
        & $loadDevices $curChecked
    })
    [void](Btn 'OK' 558 468 100 $dlg { Safe {
        if ($rbAll.Checked) {
            $script:CurUsbHidMode = 'All'; $script:CurUsbHidDevices = @()
        } elseif ($rbSpec.Checked) {
            $picked = @($dg.Rows | Where-Object { [bool]$_.Cells['Allow'].Value } | ForEach-Object { Assert-ValidDeviceInterfacePath ([string]$_.Cells['Path'].Value) })
            if ($picked.Count -eq 0) { throw 'Select at least one USB/HID device, or choose Off / Allow all.' }
            $script:CurUsbHidMode = 'Specific'; $script:CurUsbHidDevices = @($picked | Select-Object -Unique)
        } else {
            $script:CurUsbHidMode = 'Off'; $script:CurUsbHidDevices = @()
        }
        Update-UsbHidLabel; Save-UiToProfile
        $dlg.DialogResult = 'OK'; $dlg.Close()
    } })
    [void](Btn 'Cancel' 666 468 100 $dlg { $dlg.DialogResult = 'Cancel'; $dlg.Close() })
    Set-DarkTheme $dlg
    [void]$dlg.ShowDialog($F)
}

# ===Hardening tab
# Explicit AutoScroll container because $tabHard itself doesnt scroll
$pnlH = Ctl Panel @{ Location = (Pt 0 0); Size = (Sz 800 500); AutoScroll = $true; Anchor = [Windows.Forms.AnchorStyles]'Top,Bottom,Left,Right' } $tabHard
$hardItems = @(
    @('Hard.Lpac', 'LPAC (Less-Privileged AppContainer, recommended; Win10 1703+): drops ALL APPLICATION PACKAGES (S-1-15-2-1).'),
    @('Hard.NoChild', 'Block creating child processes (leave OFF for multi-process apps like Blender add-ons/FFmpeg/browsers)'),
    @('Hard.KillOnClose', 'Kill the whole sandboxed process tree when the launcher exits (job object)'),
    @('Hard.WaitTree', 'Wait for the entire job process tree (IOCP) instead of exiting when a stub/launcher PID exits'),
    @('Hard.NoClipboard', 'Block clipboard read/write (job UI limit; disabling lets sandboxed apps read/write host clipboard)'),
    @('Hard.NoDesktopSys', 'Block display changes, logoff/shutdown, desktop Create/Switch, global atoms & foreign HWNDs (pair with IsolateDesktop in Env & quotas for separate desktop)'),
    @('Hard.FollowReparse', 'UNSAFE: Allow Apply to traverse/grant across NTFS junctions & symbolic links (leave OFF to block reparse attacks)'),
    @('Hard.DepSehop32', 'DEP + SEHOP exploit mitigations for 32-bit executables (automatically skipped for 64-bit EXEs)'),
    @('Hard.HeapTerminate', 'Terminate process immediately on heap corruption'),
    @('Hard.BottomUpAslr', 'Bottom-up ASLR randomization'),
    @('Hard.HighEntropyAslr', 'High-entropy 64-bit ASLR'),
    @('Hard.Cfg', 'Control Flow Guard (CFG)'),
    @('Hard.StrictHandles', 'Strict handle checks (bad handle use terminates the process)'),
    @('Hard.NoExtPoints', 'Disable legacy extension points (AppInit DLLs, etc.)'),
    @('Hard.ImgNoRemote', 'Block DLL loads from network shares'),
    @('Hard.ImgNoLowLabel', 'Block DLL loads from Low-integrity locations'),
    @('Hard.ImgPreferSys32', 'Prefer System32 in DLL search'),
    @('Hard.ForceRelocate', 'Mandatory ASLR (breaks non-relocatable legacy EXEs/DLLs)'),
    @('Hard.NoFonts', 'Block non-system fonts (reduces GDI/font risk; may break apps loading bundled UI fonts)'),
    @('Hard.NoFsctl', 'Block NtFsControlFile FSCTLs (Win11 25295+ anti-junction defense; may break sparse/reparse-aware tools)'),
    @('Hard.StrictCfg', 'Strict CFG (require CFG on every loaded DLL; breaks older third-party DLLs)'),
    @('Hard.RestrictIbp', 'Restrict indirect branch prediction (Spectre v2 / STIBP)'),
    @('Hard.Ssbd', 'Speculative Store Bypass Disable (Spectre v4 mitigation)'),
    @('Hard.CetShadowStack', 'Hardware-enforced Stack Protection / CET shadow stacks (Win10 2004+ / supported CPUs)'),
    @('Hard.NoDynCode', 'Prohibit dynamic code (breaks JIT: .NET, browsers, Electron, some Python JITs)'),
    @('Hard.BlockNonMs', 'Only load Microsoft-signed EXE & DLLs (blocks launching non-MS EXEs like Blender)'),
    @('Hard.Win32k', 'Disable win32k syscalls (no GUI; only for headless/console tools)')
)
$y = 8
foreach ($it in $hardItems) { Add-Check $pnlH $it[0] $it[1] 12 $y 740; $y += 38 }

# ===env tab
[void](Ctl Label @{ Text = 'Environment variable mode:'; Location = (Pt 15 16); AutoSize = $true } $tabEnv)
# Index order is checked positionally by 05-GuiController.ps1: 0 = Allowlist, 1 = InheritHost
$script:EnvModeCmb = Ctl ComboBox @{ Location = (Pt 210 13); Size = (Sz 260 24); DropDownStyle = 'DropDownList' } $tabEnv
[void]$script:EnvModeCmb.Items.AddRange(@('Allowlist (safe default)', 'InheritHost (unsafe: exposes host env)'))
$script:EnvModeCmb.SelectedIndex = 0
Add-Check $tabEnv 'Hard.RedirectProfile' 'Redirect USERPROFILE & APPDATA into container AC (untick if profile grants host AppData\Roaming)' 15 44 820
$script:Chk['Hard.RedirectProfile'].Height = 24
[void](Ctl Label @{ Text = 'Host env vars to pass through (comma separated, e.g. CUDA_CACHE_PATH, BLENDER_USER_CONFIG, PYTHONPATH):'; Location = (Pt 15 76); AutoSize = $true } $tabEnv)
$script:T.EnvAllow = Ctl TextBox @{ Location = (Pt 15 98); Size = (Sz 760 24) } $tabEnv
[void](Ctl Label @{ Text = 'Custom env overrides (one KEY=VALUE per line; always applied last):'; Location = (Pt 15 130); AutoSize = $true } $tabEnv)
$script:T.EnvCustom = Ctl TextBox @{ Location = (Pt 15 152); Size = (Sz 760 84); Multiline = $true; ScrollBars = 'Vertical'; AcceptsReturn = $true } $tabEnv
Add-Check $tabEnv 'Hard.IsolateDesktop' 'Automatically create & isolate a separate desktop unique to this Container ID (WinSta0\acm.desk.<ContainerId>)' 15 244 760
$script:Chk['Hard.IsolateDesktop'].Height = 24
Add-Check $tabEnv 'Hard.JoinFirstDesktop' 'Join the first running app''s isolated desktop (shares that acm.desk.* instead of creating a new desktop per app)' 35 270 740
$script:Chk['Hard.JoinFirstDesktop'].Height = 24
[void](Ctl Label @{ Text = 'Active / custom WindowStation\Desktop (auto-assigned when ticked above; blank = WinSta0\Default when unticked):'; Location = (Pt 15 302); AutoSize = $true } $tabEnv)
$script:T.Desktop = Ctl TextBox @{ Location = (Pt 15 324); Size = (Sz 595 24) } $tabEnv
[void](Btn 'Manage Desktops...' 618 322 157 $tabEnv { Safe { Show-DesktopManagerDialog } })

# Numeric bounds (MaxProcesses 0 to 10000, Mem 0 to 1048576 MB, CpuRatePct 0 to 100) must match Assert-ValidProfileCommonFields
$grpLim = Ctl GroupBox @{ Text = 'Job Object Resource Quotas (0 = unlimited; 32-bit PS clamps memory quotas at ~4 GB)'; Location = (Pt 15 360); Size = (Sz 760 184) } $tabEnv
[void](Ctl Label @{ Text = 'Max active processes:'; Location = (Pt 15 34); AutoSize = $true } $grpLim)
$script:NumMaxProc = Ctl NumericUpDown @{ Location = (Pt 225 31); Size = (Sz 110 24); Minimum = 0; Maximum = 10000 } $grpLim
[void](Ctl Label @{ Text = 'Per-process memory limit (MB):'; Location = (Pt 15 70); AutoSize = $true } $grpLim)
$script:NumProcMem = Ctl NumericUpDown @{ Location = (Pt 225 67); Size = (Sz 110 24); Minimum = 0; Maximum = 1048576; Increment = 64 } $grpLim
[void](Ctl Label @{ Text = 'Total job memory limit (MB):'; Location = (Pt 15 106); AutoSize = $true } $grpLim)
$script:NumJobMem = Ctl NumericUpDown @{ Location = (Pt 225 103); Size = (Sz 110 24); Minimum = 0; Maximum = 1048576; Increment = 64 } $grpLim
[void](Ctl Label @{ Text = 'CPU hard cap (% 1-100, 0 = off):'; Location = (Pt 15 142); AutoSize = $true } $grpLim)
$script:NumCpuPct = Ctl NumericUpDown @{ Location = (Pt 225 139); Size = (Sz 110 24); Minimum = 0; Maximum = 100 } $grpLim
[void](Ctl Label @{ Location = (Pt 355 34); Size = (Sz 390 135); Text = "Allowlist mode strips host secrets (API keys, tokens, host APPDATA/USERPROFILE) and redirects APPDATA, LOCALAPPDATA, USERPROFILE, and TEMP into the container AC folder.`r`nNote: On hosts with Dynamic Fair Share Scheduling (DFSS), Windows rejects Job CPU rate control; launch continues with a warning." } $grpLim)

# ===notes tab
$notes = @'
REQUIREMENTS & THREAT MODEL NOTES
- OS floor: LPAC and DeriveCapabilitySidsFromName require Windows 10 version 1703 (build 15063) or newer. FSCTL disable requires Windows 11 build 25295+.
- What AppContainer does NOT isolate:
  1) Kernel & GPU/driver surface (apps like Blender still reach GPU drivers; D3DSCache.dll shader cache issues in AC folders can cause slowdowns or 0xC0000135/ACCESS_DENIED if ACLs are misconfigured).
  2) Screen vs audio isolation: With IsolateDesktop ON (default), each container runs on WinSta0\acm.desk.<ContainerId> with a Low-IL protected DACL blocking WinSta0\Default & other containers from screen/GDI capture, hooks, and foreign HWNDs. Windows Audio (Audiosrv/WASAPI) is session-scoped; microphone input is gated by Dev.Mic + LPAC.
  3) Out-of-process COM/DCOM/ALPC: NoChild only blocks direct child processes; COM servers accessible to the container SID or S-1-15-2-1/lpacCom run outside the Job Object.
  4) DNS exfiltration via Dnscache: Windows Firewall -Package block rules do NOT block DNS lookups if ANY network capability is ticked. True offline requires 0 network capabilities (plus AutoOfflineBlock for child ALE_APP_ID rules).
  5) Public network profile LAN reachability: internetClient allows RFC1918 LAN access on Public profiles unless "Block private LAN" is enabled; internetClientServer still blocks unsolicited inbound traffic unless an inbound Allow rule is added.
- File & export safety:
  - Never grant write access to Startup folders, PATH directories, or the app's own install directory. Use "Audit rules" to check for risky write rules and host read leaks.
6) Named pipes, RPC/ALPC, ETW, WMI & device interfaces: AppContainer blocks arbitrary host paths, NOT kernel/user-mode endpoints whose DACLs grant Everyone, S-1-15-2-1, or S-1-15-2-2 (or enabled hardware capabilities like microphone/USB/HID/GPU compute IOCTLs).
- Firewall, Registry & ACL caveats:
  - Windows Defender Firewall (MpsSvc) must be enabled on active profiles with local rule merging allowed (AllowLocalFirewallRules != False); otherwise -Package firewall rules silently do nothing.
  - Under ReadWrite, (OI)(CI)(NP) ("Folder + direct contents") grants modify/delete rights on the direct subfolder objects themselves, not just files.
  - Registry View=Both targets 64-bit and WOW6432Node; when running Apply/Revoke under over-the-shoulder UAC elevation (a different admin account), HKCU rules target the launching user via -TargetUserSid.
- Launcher & KillOnClose: WaitTree uses an I/O Completion Port so launcher stubs that fork a child and exit don't prematurely kill the child tree. From the GUI, each Launch spawns a background PowerShell host; use "Inspect" -> "Terminate running" to kill an active container.
- Review: icacls <folder> shows container SID entries. Use Revoke (admin) to remove ACLs, firewall rules, and loopback exemptions.
'@
[void](Ctl TextBox @{ Text = $notes; Multiline = $true; ReadOnly = $true; ScrollBars = 'Vertical'; Location = (Pt 10 10); Size = (Sz 785 490)
    Anchor = [Windows.Forms.AnchorStyles]'Top,Bottom,Left,Right' } $tabNotes)
