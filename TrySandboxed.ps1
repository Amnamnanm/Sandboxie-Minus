#requires -Version 5.1
<#
  Sandboxie Minus - create and launch Windows AppContainer sandbox profiles (no MSIX needed)
  Requires Windows 10 1703 (build 15063)+ for LPAC and DeriveCapabilitySidsFromName.
  Run:
      powershell -STA -ExecutionPolicy Bypass -File .\TrySandboxed.ps1
  Launch a profile without the UI:   ... -File .\TrySandboxed.ps1 -Launch "ProfileName"
#>
[CmdletBinding()]
param(
    [string]$Launch,
    [ValidateSet('', 'Apply', 'Revoke', 'SaveConfig', 'Delete')][string]$Elevated = '',
    [string]$ProfileName,
    [string]$ConfigPath,
    [string]$LogPath,
    [string]$StagingPath,
    [string]$TargetUserSid,
    [switch]$DryRun,
    [string]$DeskWatch,
    [string]$DeskBar,
    [int]$AutoReturnSec = 10,
    [string]$HbHandle,
    [string]$ExitHandle
)
$ErrorActionPreference = 'Stop'
if (-not $PSCommandPath) { throw 'Save this as a .ps1 file and run it from there.' }

# remember main entry point path
# and root folder
$script:MainScriptPath = $PSCommandPath
$script:AppRoot = $PSScriptRoot

function Format-ArgString([string[]]$ArgList) {
    ($ArgList | ForEach-Object {
        $s = [string]$_
        if ($s -match '[\x00-\x08\x0A-\x1F\x7F]') { throw 'Security error: control characters are not allowed in process arguments.' }
        if ([string]::IsNullOrEmpty($s) -or $s -match '[\s"]') { '"' + ($s -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' } else { $s }
    }) -join ' '
}

# WinForms needs STA
if (-not $Launch -and -not $Elevated -and [Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $fwd = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $script:MainScriptPath)
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if ($kv.Value -is [switch]) { if ($kv.Value) { $fwd += "-$($kv.Key)" } }
        else { $fwd += @("-$($kv.Key)", [string]$kv.Value) }
    }
    Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList (Format-ArgString $fwd)
    exit
}

# reject symlinks
# re-runs as admin
# can't allow redirects to 
# user-writables
function Resolve-AcmPartPath([string]$RelativePath) {
    $srcDir = Join-Path $script:AppRoot 'src'
    $full = Join-Path $script:AppRoot $RelativePath
    foreach ($checkPath in @($srcDir, $full)) {
        if (-not (Test-Path -LiteralPath $checkPath)) { throw "Missing required component: $checkPath" }
        if (([IO.File]::GetAttributes($checkPath) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Security error: component path is a reparse point: $checkPath"
        }
    }
    $full
}

# Load core cs
if (-not ('ACM.Native' -as [type])) {
    $nativeCs = [IO.File]::ReadAllText((Resolve-AcmPartPath 'src\NativeInterop.cs'), [Text.Encoding]::UTF8)
    Add-Type -TypeDefinition $nativeCs -Language CSharp
}
. (Resolve-AcmPartPath 'src\01-ConfigAndValidation.ps1')
. (Resolve-AcmPartPath 'src\02-SandboxEngine.ps1')

if (-not $ConfigPath) { $ConfigPath = Get-DefaultConfigPath }

# Headless entry points exit 
# before loading GUI files
if ($Elevated) {
    try {
        if (-not (Test-Admin)) { throw 'Elevated mode requires Administrator privileges.' }
        if (-not (Test-ProtectedConfigPath $ConfigPath)) { throw "Security error: elevated ConfigPath must be a non-reparse .json file inside $(Get-ProtectedAppDir)." }
        if ($StagingPath) {
            try { Import-ValidatedStagingConfig $StagingPath $TargetUserSid }
            finally { Remove-Item -LiteralPath $StagingPath -Force -ErrorAction SilentlyContinue }
        }
        if ($Elevated -eq 'SaveConfig') { Log "Config saved securely to $ConfigPath."; exit 0 }
        Load-Config
        $p = Find-Profile $ProfileName
        if (-not $p) { throw "Profile '$ProfileName' not found in $ConfigPath" }
        if ($Elevated -eq 'Delete') {
            if (@($p.Applied.Paths).Count -or @($p.Applied.RegPaths).Count -or @($p.Applied.Devices).Count -or $p.Applied.Firewall -or $p.Applied.Loopback) { Invoke-Revoke $p }
            Complete-DeleteProfile $ProfileName
            exit 0
        }
        Invoke-Mode $Elevated $p
        exit 0
    } catch { Log "ERROR: $($_.Exception.Message)"; exit 1 }
}
if ($Launch) {
    try {
        Load-Config
        $p = Find-Profile $Launch
        if (-not $p) { throw "Profile '$Launch' not found." }
        Start-Sandboxed $p
    } catch {
        Add-Type -AssemblyName System.Windows.Forms
        [void][Windows.Forms.MessageBox]::Show($_.Exception.Message, "Launch failed: $Launch", 'OK', 'Error')
    }
    exit
}

if ($DeskWatch -or $DeskBar) {
    [ACM.Native]::EnableDpiAware()
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    if (-not ('ACM.MsgForm' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Windows.Forms;
namespace ACM {
    public class MsgForm : Form {
        public bool NoActivate, ToolOnly;
        public Action<int, IntPtr, IntPtr> OnMsg;
        protected override bool ShowWithoutActivation { get { return NoActivate || ToolOnly; } }
        protected override CreateParams CreateParams {
            get {
                CreateParams cp = base.CreateParams;
                if (NoActivate) cp.ExStyle |= 0x08000080;
                else if (ToolOnly) cp.ExStyle |= 0x00000080;
                return cp;
            }
        }
        protected override void WndProc(ref Message m) {
            if (OnMsg != null) OnMsg(m.Msg, m.WParam, m.LParam);
            base.WndProc(ref m);
        }
    }
    public class DarkMenuColors : ProfessionalColorTable {
        System.Drawing.Color bg = System.Drawing.Color.FromArgb(33, 35, 45), hov = System.Drawing.Color.FromArgb(64, 52, 118), bd = System.Drawing.Color.FromArgb(56, 60, 78);
        public override System.Drawing.Color ToolStripDropDownBackground { get { return bg; } }
        public override System.Drawing.Color MenuItemSelected { get { return hov; } }
        public override System.Drawing.Color MenuItemSelectedGradientBegin { get { return hov; } }
        public override System.Drawing.Color MenuItemSelectedGradientEnd { get { return hov; } }
        public override System.Drawing.Color MenuBorder { get { return bd; } }
        public override System.Drawing.Color MenuItemBorder { get { return bd; } }
        public override System.Drawing.Color SeparatorDark { get { return bd; } }
    }
}
'@ -ReferencedAssemblies System.Windows.Forms, System.Drawing
    }
    if ($DeskWatch) {
        $hHb = [ACM.Native]::CreateInheritableEvent(); $hExit = [ACM.Native]::CreateInheritableEvent(); $hProc = [IntPtr]::Zero
        try {
            $barArgs = Format-ArgString @('-NoProfile', '-STA', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', $script:MainScriptPath, '-DeskBar', $DeskWatch, '-HbHandle', "$($hHb.ToInt64())", '-ExitHandle', "$($hExit.ToInt64())", '-AutoReturnSec', "$AutoReturnSec")
            $barPid = [ACM.Native]::StartHiddenOnDesktop((Get-Process -Id $PID).Path, $barArgs, $DeskWatch, $true)
            $hProc = [ACM.Native]::OpenProcessWait($barPid)
            $ready = $false; $sw = [Diagnostics.Stopwatch]::StartNew()
            while ($sw.ElapsedMilliseconds -lt 15000) {
                if ([ACM.Native]::WaitEvent($hHb, 50)) { $ready = $true; break }
                if ($hProc -ne [IntPtr]::Zero -and [ACM.Native]::WaitEvent($hProc, 0)) { throw 'Desktop bar exited before ready.' }
            }
            if (-not $ready) { throw 'Desktop bar did not become ready.' }
            [ACM.Native]::SwitchToDesktopByName($DeskWatch)
            $wf = New-Object ACM.MsgForm; $wf.NoActivate = $true; $wf.ShowInTaskbar = $false; [void]$wf.Handle
            $state = @{ Ret = $false; Last = [DateTime]::UtcNow }
            [ACM.Native]::RegisterSessionUnlock($wf.Handle, $true)
            $wf.OnMsg = { param($msg, $wp, $lp) if ($msg -eq 0x02B1 -and $wp.ToInt64() -eq 8) { $state.Ret = $true } }
            $tmr = New-Object Windows.Forms.Timer; $tmr.Interval = 200
            $tmr.add_Tick({
                if ([ACM.Native]::WaitEvent($hHb, 0)) { $state.Last = [DateTime]::UtcNow }
                if ([ACM.Native]::WaitEvent($hExit, 0) -or ($hProc -ne [IntPtr]::Zero -and [ACM.Native]::WaitEvent($hProc, 0)) -or ($AutoReturnSec -gt 0 -and ([DateTime]::UtcNow - $state.Last).TotalSeconds -ge $AutoReturnSec)) { $state.Ret = $true }
                if ($state.Ret) {
                    try { [ACM.Native]::SwitchToDesktopByName('Default'); $tmr.Stop(); [ACM.Native]::SignalEvent($hExit); [ACM.Native]::RegisterSessionUnlock($wf.Handle, $false); $wf.Dispose(); [Windows.Forms.Application]::ExitThread() } catch {}
                }
            })
            $tmr.Start(); [void][Windows.Forms.Application]::Run(); $tmr.Dispose()
        } catch { $m = $_.Exception.Message; [ACM.Native]::SignalEvent($hExit); try { [ACM.Native]::SwitchToDesktopByName('Default') } catch {}; [void][Windows.Forms.MessageBox]::Show($m, 'Switch To Failed', 'OK', 'Error') }
        finally { [ACM.Native]::CloseKernelHandle($hProc); [ACM.Native]::CloseKernelHandle($hHb); [ACM.Native]::CloseKernelHandle($hExit) }
        exit
    }
    $hHb = [IntPtr][long]$HbHandle; $hExit = [IntPtr][long]$ExitHandle
    $fUi = New-Object Drawing.Font('Segoe UI', 9.25)
    $fBold = New-Object Drawing.Font('Segoe UI', 9.25, [Drawing.FontStyle]::Bold)
    $vs = [Windows.Forms.SystemInformation]::VirtualScreen
    $bg = New-Object ACM.MsgForm; $bg.NoActivate = $true; $bg.StartPosition = 'Manual'; $bg.FormBorderStyle = 'None'; $bg.ShowInTaskbar = $false
    $bg.BackColor = [Drawing.Color]::FromArgb(24, 25, 32); $bg.Bounds = $vs
    $bgLbl = New-Object Windows.Forms.Label; $bgLbl.Dock = 'Fill'; $bgLbl.TextAlign = 'MiddleCenter'
    $bgLbl.ForeColor = [Drawing.Color]::FromArgb(120, 126, 145); $bgLbl.Font = (New-Object Drawing.Font('Segoe UI', 12))
    $bgLbl.Text = "Isolated Desktop ($DeskBar)`r`nClick a window in the bottom bar, or press Right Ctrl to return."
    [void]$bg.Controls.Add($bgLbl)

    $pb = [Windows.Forms.Screen]::PrimaryScreen.Bounds; $barH = 40
    try { Load-Config } catch {}
    $bar = New-Object ACM.MsgForm; $bar.ToolOnly = $true; $bar.StartPosition = 'Manual'; $bar.FormBorderStyle = 'None'; $bar.ShowInTaskbar = $false; $bar.TopMost = $true
    $bar.BackColor = [Drawing.Color]::FromArgb(24, 25, 32); $bar.ForeColor = [Drawing.Color]::FromArgb(240, 242, 248); $bar.Font = $fUi
    $bar.Bounds = (New-Object Drawing.Rectangle($pb.X, ($pb.Bottom - $barH), $pb.Width, $barH))
    $bar.add_Paint({ param($s, $e) $pen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(56, 60, 78), 1); try { $e.Graphics.DrawLine($pen, 0, 0, $s.Width, 0) } finally { $pen.Dispose() } })

    $btnApps = New-Object Windows.Forms.Button; $btnApps.Text = 'Apps'; $btnApps.Font = $fBold; $btnApps.TabStop = $false
    $btnApps.FlatStyle = 'Flat'; $btnApps.Location = (New-Object Drawing.Point(8, 6)); $btnApps.Size = (New-Object Drawing.Size(68, 28))
    $btnApps.BackColor = [Drawing.Color]::FromArgb(41, 44, 58); $btnApps.ForeColor = [Drawing.Color]::FromArgb(240, 242, 248); $btnApps.Cursor = [Windows.Forms.Cursors]::Hand
    $btnApps.FlatAppearance.BorderSize = 1; $btnApps.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(124, 92, 255); $btnApps.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(64, 52, 118)

    $btnBack = New-Object Windows.Forms.Button; $btnBack.Text = '<< Default (RCtrl)'; $btnBack.Font = $fBold; $btnBack.TabStop = $false
    $btnBack.FlatStyle = 'Flat'; $btnBack.Location = (New-Object Drawing.Point(82, 6)); $btnBack.Size = (New-Object Drawing.Size(148, 28))
    $btnBack.BackColor = [Drawing.Color]::FromArgb(124, 92, 255); $btnBack.ForeColor = [Drawing.Color]::White; $btnBack.Cursor = [Windows.Forms.Cursors]::Hand
    $btnBack.FlatAppearance.BorderSize = 1; $btnBack.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(124, 92, 255); $btnBack.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(142, 114, 255)

    $btnKill = New-Object Windows.Forms.Button; $btnKill.Text = 'Kill Apps'; $btnKill.Font = $fUi; $btnKill.TabStop = $false
    $btnKill.FlatStyle = 'Flat'; $btnKill.Location = (New-Object Drawing.Point(236, 6)); $btnKill.Size = (New-Object Drawing.Size(82, 28))
    $btnKill.BackColor = [Drawing.Color]::FromArgb(41, 44, 58); $btnKill.ForeColor = [Drawing.Color]::FromArgb(240, 242, 248); $btnKill.Cursor = [Windows.Forms.Cursors]::Hand
    $btnKill.FlatAppearance.BorderSize = 1; $btnKill.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(56, 60, 78); $btnKill.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(64, 52, 118)

    $lblClk = New-Object Windows.Forms.Label; $lblClk.TextAlign = 'MiddleRight'; $lblClk.ForeColor = [Drawing.Color]::FromArgb(158, 164, 184); $lblClk.Font = $fUi
    $lblClk.Location = (New-Object Drawing.Point(($pb.Width - 205), 6)); $lblClk.Size = (New-Object Drawing.Size(195, 28))

    $hostW = [Math]::Max(120, $pb.Width - 588)
    $btnScL = New-Object Windows.Forms.Button; $btnScL.Text = '<'; $btnScL.Font = $fBold; $btnScL.TabStop = $false; $btnScL.Visible = $false; $btnScL.FlatStyle = 'Flat'; $btnScL.Location = (New-Object Drawing.Point(324, 6)); $btnScL.Size = (New-Object Drawing.Size(22, 28)); $btnScL.BackColor = [Drawing.Color]::FromArgb(41, 44, 58); $btnScL.ForeColor = [Drawing.Color]::FromArgb(240, 242, 248); $btnScL.FlatAppearance.BorderSize = 1; $btnScL.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(56, 60, 78)
    $btnScR = New-Object Windows.Forms.Button; $btnScR.Text = '>'; $btnScR.Font = $fBold; $btnScR.TabStop = $false; $btnScR.Visible = $false; $btnScR.FlatStyle = 'Flat'; $btnScR.Location = (New-Object Drawing.Point((348 + $hostW + 2), 6)); $btnScR.Size = (New-Object Drawing.Size(22, 28)); $btnScR.BackColor = [Drawing.Color]::FromArgb(41, 44, 58); $btnScR.ForeColor = [Drawing.Color]::FromArgb(240, 242, 248); $btnScR.FlatAppearance.BorderSize = 1; $btnScR.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(56, 60, 78)
    $flowHost = New-Object Windows.Forms.Panel; $flowHost.Location = (New-Object Drawing.Point(348, 5)); $flowHost.Size = (New-Object Drawing.Size($hostW, 30)); $flowHost.BackColor = [Drawing.Color]::Transparent
    $flow = New-Object Windows.Forms.FlowLayoutPanel; $flow.Location = (New-Object Drawing.Point(0, 0)); $flow.Height = 30; $flow.AutoSize = $true; $flow.AutoSizeMode = 'GrowAndShrink'; $flow.WrapContents = $false; $flow.BackColor = [Drawing.Color]::Transparent
    [void]$flowHost.Controls.Add($flow)
    [void]$bar.Controls.Add($btnApps); [void]$bar.Controls.Add($btnBack); [void]$bar.Controls.Add($btnKill); [void]$bar.Controls.Add($btnScL); [void]$bar.Controls.Add($flowHost); [void]$bar.Controls.Add($btnScR); [void]$bar.Controls.Add($lblClk)

    $quitBar = { [ACM.Native]::SignalEvent($hExit); $bar.Close() }
    $menu = New-Object Windows.Forms.ContextMenuStrip; $menu.ShowImageMargin = $false; $menu.Font = $fUi
    $menu.MaximumSize = (New-Object Drawing.Size([Math]::Min(560, [Math]::Max(360, $pb.Width - 40)), [Math]::Max(240, $pb.Height - 90)))
    $menu.add_Closing({ param($s, $e) if (-not $bs.AllowMenuClose -and $e.CloseReason -in 'AppClicked', 'AppFocusChange' -and [ACM.Native]::IsRightMouseDownAsync()) { $e.Cancel = $true } })
    $menu.add_Closed({ $bs.AllowMenuClose = $false; $bs.MenuClosedAt = [DateTime]::UtcNow })
    $menu.BackColor = [Drawing.Color]::FromArgb(33, 35, 45); $menu.ForeColor = [Drawing.Color]::FromArgb(240, 242, 248)
    $menu.Renderer = New-Object Windows.Forms.ToolStripProfessionalRenderer((New-Object ACM.DarkMenuColors))
    $openMenu = {
        $menu.Items.Clear()
        foreach ($pr in @($script:Profiles | Sort-Object Name)) {
            if (-not $pr.ExePath) { continue }
            $it = $menu.Items.Add("Launch: $($pr.Name)"); $it.Tag = $pr.Name
            $it.add_Click({ param($s, $e) $la = Format-ArgString @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', $script:MainScriptPath, '-Launch', [string]$s.Tag); [void](Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $la -WindowStyle Hidden) })
        }
        if ($menu.Items.Count -gt 0) { [void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator)) }
        $itMin = $menu.Items.Add('Minimize All'); $itMin.add_Click({ foreach ($w in @([ACM.Native]::GetDesktopAppWindows($DeskBar, [uint32]$PID))) { $h = [IntPtr][long](($w -split '\|', 2)[0]); [ACM.Native]::MinimizeAppWindow($h) } })
        $itRet = $menu.Items.Add('Return to Default (RCtrl)'); $itRet.add_Click($quitBar)
        $bar.Activate(); $menu.Show($bar, (New-Object Drawing.Point(8, 0)), [Windows.Forms.ToolStripDropDownDirection]::AboveRight)
    }
    $btnApps.add_Click({ if (([DateTime]::UtcNow - $bs.MenuClosedAt).TotalMilliseconds -lt 250) { return }; & $openMenu })
    $btnBack.add_Click($quitBar)
    $btnKill.add_Click({ [void][ACM.Native]::TerminateDesktopProcesses($DeskBar, ''); & $quitBar })
    $tipForm = New-Object ACM.MsgForm; $tipForm.NoActivate = $true; $tipForm.StartPosition = 'Manual'; $tipForm.FormBorderStyle = 'None'; $tipForm.ShowInTaskbar = $false; $tipForm.TopMost = $true
    $tipForm.BackColor = [Drawing.Color]::FromArgb(33, 35, 45); $tipForm.add_Paint({ param($s, $e) $pen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(124, 92, 255), 1); try { $e.Graphics.DrawRectangle($pen, 0, 0, $s.Width - 1, $s.Height - 1) } finally { $pen.Dispose() } })
    $tipLbl = New-Object Windows.Forms.Label; $tipLbl.Dock = 'Fill'; $tipLbl.TextAlign = 'MiddleCenter'; $tipLbl.AutoEllipsis = $true; $tipLbl.Font = $fUi; $tipLbl.ForeColor = [Drawing.Color]::FromArgb(240, 242, 248); [void]$tipForm.Controls.Add($tipLbl)
    $bs = @{ WasDown = [ACM.Native]::IsRightCtrlDownAsync(); Start = [DateTime]::UtcNow; LastHb = [DateTime]::MinValue; LastWin = [DateTime]::MinValue; Sig = ''; WinTap = $false; WinClose = $false; AllowMenuClose = $false; MenuClosedAt = [DateTime]::MinValue; SeenApp = $false; EmptySince = [DateTime]::MinValue; Icons = @{}; SwOpen = $false; SwWins = @(); SwIdx = 0; SwRows = @() }
    $getWinIcon = {
        param([IntPtr]$hwnd, [uint32]$wpid, [string]$title)
        $k = "$($hwnd.ToInt64())|$wpid"; if ($bs.Icons.ContainsKey($k)) { return $bs.Icons[$k] }
        $raw = $null
        try { $hi = [ACM.Native]::GetWindowIconHandle($hwnd); if ($hi -ne [IntPtr]::Zero) { $ic = [Drawing.Icon]::FromHandle($hi); try { $raw = $ic.ToBitmap() } finally { $ic.Dispose() } } } catch {}
        if (-not $raw) { try { $ep = [ACM.Native]::GetProcessImagePath($wpid); if ($ep -and (Test-Path -LiteralPath $ep -PathType Leaf)) { $ic = [Drawing.Icon]::ExtractAssociatedIcon($ep); if ($ic) { try { $raw = $ic.ToBitmap() } finally { $ic.Dispose() } } } } catch {} }
        $bmp = New-Object Drawing.Bitmap(20, 20); $g = [Drawing.Graphics]::FromImage($bmp)
        try {
            $g.Clear([Drawing.Color]::Transparent); $g.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            if ($raw) { $g.DrawImage($raw, 0, 0, 20, 20) } else {
                $br = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(124, 92, 255)); $tb = New-Object Drawing.SolidBrush([Drawing.Color]::White)
                $sf = New-Object Drawing.StringFormat; $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
                $g.FillRectangle($br, 1, 1, 18, 18); $g.DrawString($(if ($title) { $title.Substring(0, 1).ToUpperInvariant() } else { '?' }), $fBold, $tb, (New-Object Drawing.RectangleF(0, 0, 20, 20)), $sf)
                $br.Dispose(); $tb.Dispose(); $sf.Dispose()
            }
        } finally { $g.Dispose(); if ($raw) { $raw.Dispose() } }
        $bs.Icons[$k] = $bmp; $bmp
    }
    $scrollBarBy = {
        param([int]$dx)
        $maxOff = [Math]::Max(0, $flow.Width - $flowHost.ClientSize.Width)
        if ($maxOff -eq 0) { $flow.Left = 0; $btnScL.Visible = $false; $btnScR.Visible = $false; return }
        $btnScL.Visible = $true; $btnScR.Visible = $true
        $nx = [Math]::Max(-$maxOff, [Math]::Min(0, $flow.Left + $dx)); $flow.Left = $nx; $btnScL.Enabled = ($nx -lt 0); $btnScR.Enabled = ($nx -gt -$maxOff)
    }
    $btnScL.add_Click({ & $scrollBarBy 120 }); $btnScR.add_Click({ & $scrollBarBy -120 })
    $flowHost.add_MouseWheel({ param($s, $e) & $scrollBarBy ([Math]::Sign($e.Delta) * 80) })

    $swForm = New-Object ACM.MsgForm; $swForm.ToolOnly = $true; $swForm.StartPosition = 'Manual'; $swForm.FormBorderStyle = 'None'; $swForm.ShowInTaskbar = $false; $swForm.TopMost = $true
    $swForm.BackColor = [Drawing.Color]::FromArgb(24, 25, 32); $swForm.ForeColor = [Drawing.Color]::FromArgb(240, 242, 248); $swForm.Font = $fUi
    $swForm.add_Paint({ param($s, $e) $pen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(124, 92, 255), 1); try { $e.Graphics.DrawRectangle($pen, 0, 0, $s.Width - 1, $s.Height - 1) } finally { $pen.Dispose() } })
    $swHdr = New-Object Windows.Forms.Label; $swHdr.Text = 'Switch Window  (Tab / Shift+Tab, release Alt)'; $swHdr.Font = $fBold; $swHdr.ForeColor = [Drawing.Color]::FromArgb(158, 164, 184); $swHdr.Location = (New-Object Drawing.Point(12, 8)); $swHdr.Size = (New-Object Drawing.Size(496, 20))
    $swList = New-Object Windows.Forms.FlowLayoutPanel; $swList.Location = (New-Object Drawing.Point(8, 32)); $swList.FlowDirection = 'TopDown'; $swList.WrapContents = $false; $swList.AutoScroll = $true
    [void]$swForm.Controls.Add($swHdr); [void]$swForm.Controls.Add($swList)
    $paintSwSel = {
        for ($i = 0; $i -lt $bs.SwRows.Count; $i++) {
            $rb = $bs.SwRows[$i]; $sel = ($i -eq $bs.SwIdx)
            $rb.BackColor = if ($sel) { [Drawing.Color]::FromArgb(64, 52, 118) } else { [Drawing.Color]::FromArgb(33, 35, 45) }
            $rb.FlatAppearance.BorderColor = if ($sel) { [Drawing.Color]::FromArgb(124, 92, 255) } else { [Drawing.Color]::FromArgb(56, 60, 78) }
        }
        if ($bs.SwIdx -ge 0 -and $bs.SwIdx -lt $bs.SwRows.Count) { $swList.ScrollControlIntoView($bs.SwRows[$bs.SwIdx]) }
    }
    $stepSwitcher = {
        param([int]$dir)
        if (-not $bs.SwOpen) {
            $wins = @([ACM.Native]::GetDesktopAppWindows($DeskBar, [uint32]$PID)); if ($wins.Count -eq 0) { return }
            $bs.SwWins = @(); $bs.SwRows = @(); foreach ($oc in @($swList.Controls)) { $oc.Dispose() }; $swList.Controls.Clear()
            $swW = [Math]::Min(540, [Math]::Max(320, $pb.Width - 80)); $fg = [ACM.Native]::GetActiveWindowHandle().ToInt64(); $curIdx = -1
            foreach ($w in $wins) {
                $p = $w -split '\|', 3; if ($p.Count -lt 3) { continue }
                $h = [IntPtr][long]$p[0]; $wpid = [uint32]$p[1]; $ttl = $p[2]
                if ([long]$p[0] -eq $fg) { $curIdx = $bs.SwWins.Count }
                $bs.SwWins += $h
                $rb = New-Object Windows.Forms.Button; $rb.FlatStyle = 'Flat'; $rb.Font = $fUi; $rb.TabStop = $false; $rb.AutoEllipsis = $true; $rb.Size = (New-Object Drawing.Size(($swW - 36), 34)); $rb.Margin = (New-Object Windows.Forms.Padding(2))
                $rb.TextAlign = 'MiddleLeft'; $rb.ImageAlign = 'MiddleLeft'; $rb.TextImageRelation = 'ImageBeforeText'; $rb.Padding = (New-Object Windows.Forms.Padding(8, 0, 8, 0)); $rb.ForeColor = [Drawing.Color]::FromArgb(240, 242, 248); $rb.FlatAppearance.BorderSize = 1
                $rb.Image = (& $getWinIcon $h $wpid $ttl); $rb.Text = "  $ttl"; [void]$swList.Controls.Add($rb); $bs.SwRows += $rb
            }
            if ($bs.SwWins.Count -eq 0) { return }
            $listH = [Math]::Min([Math]::Max(160, [int]($pb.Height * 0.65) - 44), ($bs.SwWins.Count * 38) + 6)
            $swHdr.Width = $swW - 24; $swList.Size = (New-Object Drawing.Size(($swW - 16), $listH)); $swForm.Size = (New-Object Drawing.Size($swW, ($listH + 42)))
            $swForm.Location = (New-Object Drawing.Point(($pb.X + [int](($pb.Width - $swForm.Width) / 2)), ($pb.Y + [int](($pb.Height - $swForm.Height) / 2))))
            $bs.SwIdx = if ($curIdx -ge 0) { ($curIdx + $dir + $bs.SwWins.Count) % $bs.SwWins.Count } else { 0 }
            $bs.SwOpen = $true; $swForm.Show(); [ACM.Native]::SetWindowZ($swForm.Handle, $true)
        } else { $bs.SwIdx = ($bs.SwIdx + $dir + $bs.SwWins.Count) % $bs.SwWins.Count }
        & $paintSwSel
    }
    $commitSwitcher = {
        param([bool]$activate)
        if (-not $bs.SwOpen) { return }
        $bs.SwOpen = $false; $swForm.Hide()
        if ($activate -and $bs.SwIdx -ge 0 -and $bs.SwIdx -lt $bs.SwWins.Count) { [ACM.Native]::ActivateAppWindow($bs.SwWins[$bs.SwIdx]); [ACM.Native]::SetWindowZ($bar.Handle, $true) }
    }
    $bar.add_HandleCreated({ [ACM.Native]::RegisterKeyboardRawInput($bar.Handle) })
    $bar.OnMsg = {
        param($msg, $wp, $lp)
        if ($msg -ne 0x00FF) { return }
        switch ([ACM.Native]::GetRawKeyAction($lp)) {
            1 { if (([DateTime]::UtcNow - $bs.Start).TotalMilliseconds -gt 300) { [void]$bar.BeginInvoke([Action]$quitBar) } }
            2 { $bs.WinTap = $false; [void]$bar.BeginInvoke([Action]{ & $stepSwitcher 1 }) }
            6 { $bs.WinTap = $false; [void]$bar.BeginInvoke([Action]{ & $stepSwitcher -1 }) }
            7 { if ($bs.SwOpen) { [void]$bar.BeginInvoke([Action]{ & $commitSwitcher $true }) } }
            8 { if ($bs.SwOpen) { [void]$bar.BeginInvoke([Action]{ & $commitSwitcher $false }) } }
            3 { if ($menu.Visible) { $bs.WinTap = $false; $bs.WinClose = $true; $bs.AllowMenuClose = $true; [void]$bar.BeginInvoke([Action]{ $menu.Close() }) } else { $bs.WinTap = $true } }
            4 { if ($bs.WinClose) { $bs.WinClose = $false } elseif ($bs.WinTap) { $bs.WinTap = $false; [void]$bar.BeginInvoke([Action]$openMenu) } }
            5 { $bs.WinTap = $false }
        }
    }
    $bt = New-Object Windows.Forms.Timer; $bt.Interval = 100
    $bt.add_Tick({
        if ([ACM.Native]::WaitEvent($hExit, 0)) { $bt.Stop(); $bar.Close(); return }
        $down = [ACM.Native]::IsRightCtrlDownAsync()
        if ($down -and -not $bs.WasDown -and ([DateTime]::UtcNow - $bs.Start).TotalMilliseconds -gt 300) { $bs.WasDown = $true; & $quitBar; return }
        $bs.WasDown = $down
        if ($bs.SwOpen -and -not [ACM.Native]::IsAltDownAsync()) { & $commitSwitcher $true }
        $now = [DateTime]::UtcNow
        if (($now - $bs.LastHb).TotalMilliseconds -ge 1800) { [ACM.Native]::SignalEvent($hHb); $bs.LastHb = $now }
        if (($now - $bs.LastWin).TotalMilliseconds -ge 250) {
            $bs.LastWin = $now
            $lblClk.Text = "Alt+Tab | Win  |  $((Get-Date).ToString('HH:mm'))"
            if (-not $menu.Visible -and -not $bs.SwOpen) { [ACM.Native]::SetWindowZ($bg.Handle, $false); [ACM.Native]::SetWindowZ($bar.Handle, $true) }
            $fg = [ACM.Native]::GetActiveWindowHandle().ToInt64()
            $wins = @([ACM.Native]::GetDesktopAppWindows($DeskBar, [uint32]$PID))
            $inUse = ($wins.Count -gt 0) -or [ACM.Native]::IsDesktopInUse($DeskBar, [uint32]$PID)
            if ($inUse) { $bs.SeenApp = $true; $bs.EmptySince = [DateTime]::MinValue }
            elseif ($bs.SeenApp) { if ($bs.EmptySince -eq [DateTime]::MinValue) { $bs.EmptySince = $now } elseif (($now - $bs.EmptySince).TotalMilliseconds -ge 1000) { & $quitBar; return } }
            $sig = "$fg`n" + ($wins -join "`n")
            if ($sig -cne $bs.Sig) {
                $tipForm.Hide(); $bs.Sig = $sig; foreach ($oc in @($flow.Controls)) { $oc.Image = $null; $oc.Dispose() }; $flow.Controls.Clear()
                $aliveKeys = New-Object System.Collections.Generic.HashSet[string]
                foreach ($w in $wins) {
                    $p = $w -split '\|', 3; if ($p.Count -lt 3) { continue }
                    $h = [IntPtr][long]$p[0]; $wpid = [uint32]$p[1]; $ttl = $p[2]; [void]$aliveKeys.Add("$($p[0])|$wpid")
                    $isAct = ([long]$p[0] -eq $fg)
                    $wb = New-Object Windows.Forms.Button; $wb.FlatStyle = 'Flat'; $wb.TabStop = $false; $wb.Padding = (New-Object Windows.Forms.Padding(0)); $wb.Height = 28; $wb.Width = 36; $wb.Margin = (New-Object Windows.Forms.Padding(0, 1, 4, 1)); $wb.ImageAlign = 'MiddleCenter'
                    $wb.BackColor = if ($isAct) { [Drawing.Color]::FromArgb(64, 52, 118) } else { [Drawing.Color]::FromArgb(33, 35, 45) }
                    $wb.Cursor = [Windows.Forms.Cursors]::Hand; $wb.FlatAppearance.BorderSize = 1
                    $wb.FlatAppearance.BorderColor = if ($isAct) { [Drawing.Color]::FromArgb(124, 92, 255) } else { [Drawing.Color]::FromArgb(56, 60, 78) }
                    $wb.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(64, 52, 118)
                    $wb.Image = (& $getWinIcon $h $wpid $ttl); $wb.Tag = $h; $wb.AccessibleName = $ttl
                    $wb.add_MouseEnter({ param($s, $e) $p0 = $s.PointToScreen((New-Object Drawing.Point(0, 0))); $tipLbl.Text = $s.AccessibleName; $sz = [Windows.Forms.TextRenderer]::MeasureText($tipLbl.Text, $fUi); $tw = [Math]::Min(360, $sz.Width + 14); $tipForm.Size = (New-Object Drawing.Size($tw, 24)); $tx = [Math]::Max(($pb.X + 4), [Math]::Min(($pb.Right - $tw - 4), ($p0.X + [int](($s.Width - $tw) / 2)))); $tipForm.Location = (New-Object Drawing.Point($tx, ($bar.Top - 28))); $tipForm.Show(); [ACM.Native]::SetWindowZ($tipForm.Handle, $true) })
                    $wb.add_MouseLeave({ $tipForm.Hide() })
                    $wb.add_Click({ param($s, $e) if ([ACM.Native]::GetActiveWindowHandle() -eq $s.Tag) { [ACM.Native]::MinimizeAppWindow($s.Tag) } else { [ACM.Native]::ActivateAppWindow($s.Tag) }; [ACM.Native]::SetWindowZ($bar.Handle, $true) })
                    $wb.add_MouseUp({ param($s, $e) if ($e.Button -eq 'Right') { [ACM.Native]::CloseAppWindow($s.Tag) } })
                    [void]$flow.Controls.Add($wb)
                }
                foreach ($ek in @($bs.Icons.Keys)) { if (-not $aliveKeys.Contains($ek)) { $bs.Icons[$ek].Dispose(); $bs.Icons.Remove($ek) } }
                & $scrollBarBy 0
            }
        }
    })
    $bg.Show(); [ACM.Native]::SetWindowZ($bg.Handle, $false); $bar.Show(); [ACM.Native]::SetWindowZ($bar.Handle, $true)
    [ACM.Native]::SignalEvent($hHb); $bt.Start()
    [void][Windows.Forms.Application]::Run($bar)
    $bt.Stop(); $bt.Dispose(); $tipForm.Close(); $tipForm.Dispose(); $swForm.Close(); $swForm.Dispose(); foreach ($ic in $bs.Icons.Values) { $ic.Dispose() }; $bg.Close(); $bg.Dispose()
    [ACM.Native]::SignalEvent($hExit); exit
}

# 3. GUI mode
. (Resolve-AcmPartPath 'src\03-ElevationAndProcess.ps1')
. (Resolve-AcmPartPath 'src\04-GuiThemeAndTabs.ps1')
. (Resolve-AcmPartPath 'src\05-GuiController.ps1')
