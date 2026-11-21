#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ExpectedSha256 = '9A6ED5A54C7B92FA228A50365C65CFF2FCD11C478707E40691C93B4ABFDF68D2'

# Self elevate
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $quotedSelf = '"' + $PSCommandPath + '"'
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', $quotedSelf)
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ('WinApiHelper' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class WinApiHelper
{
    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();

    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);

    public static void EnableDarkTitleBar(IntPtr hwnd, int captionColorRef)
    {
        if (hwnd == IntPtr.Zero) return;
        int dark = 1;
        if (DwmSetWindowAttribute(hwnd, 20, ref dark, sizeof(int)) != 0)
        {
            DwmSetWindowAttribute(hwnd, 19, ref dark, sizeof(int));
        }
        DwmSetWindowAttribute(hwnd, 35, ref captionColorRef, sizeof(int));
    }
}
'@
}

[void][WinApiHelper]::SetProcessDPIAware()
[System.Windows.Forms.Application]::EnableVisualStyles()

$InstallDir    = $PSScriptRoot
$SourceZip     = Join-Path $InstallDir 'TrySandboxed.zip'
$SourceIconPng = Join-Path $InstallDir 'icon.png'
$TargetDir     = Join-Path $env:ProgramFiles 'AppContainerManager\SandboxieMinus'
$DestScript    = Join-Path $TargetDir 'TrySandboxed.ps1'
$DestSrcDir    = Join-Path $TargetDir 'src'
$DestIconIco   = Join-Path $TargetDir 'icon.ico'
$ShortcutPath  = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Sandboxie Minus.lnk'

# pallete
$ColBgMain      = [System.Drawing.ColorTranslator]::FromHtml('#181920')
$ColBgCard      = [System.Drawing.ColorTranslator]::FromHtml('#292C3A')
$ColBgCardHover = [System.Drawing.ColorTranslator]::FromHtml('#323647')
$ColBorderSub   = [System.Drawing.ColorTranslator]::FromHtml('#383C4E')
$ColDivider     = [System.Drawing.ColorTranslator]::FromHtml('#2D303E')
$ColAccent      = [System.Drawing.ColorTranslator]::FromHtml('#7C5CFF')
$ColAccentHover = [System.Drawing.ColorTranslator]::FromHtml('#8D71FF')
$ColTextPrimary = [System.Drawing.Color]::White
$ColTextMuted   = [System.Drawing.ColorTranslator]::FromHtml('#B8BCC8')
$ColSuccess     = [System.Drawing.ColorTranslator]::FromHtml('#4ADE80')
$ColError       = [System.Drawing.ColorTranslator]::FromHtml('#F87171')

function Convert-PngToIco {
    param(
        [Parameter(Mandatory)][string]$InputPngPath,
        [Parameter(Mandatory)][string]$OutputIcoPath,
        [int]$Size = 256
    )
    $srcImg = $null
    $bmp    = $null
    $gfx    = $null
    $pngMs  = $null
    $fs     = $null
    $bw     = $null
    try {
        $srcImg = [System.Drawing.Image]::FromFile($InputPngPath)
        $bmp    = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $gfx    = [System.Drawing.Graphics]::FromImage($bmp)
        $gfx.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $gfx.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $gfx.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $gfx.Clear([System.Drawing.Color]::Transparent)
        $gfx.DrawImage($srcImg, 0, 0, $Size, $Size)

        $pngMs = New-Object System.IO.MemoryStream
        $bmp.Save($pngMs, [System.Drawing.Imaging.ImageFormat]::Png)
        $pngBytes = $pngMs.ToArray()

        $fs = [System.IO.File]::Open($OutputIcoPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
        $bw = New-Object System.IO.BinaryWriter($fs)

        $bw.Write([uint16]0)
        $bw.Write([uint16]1)
        $bw.Write([uint16]1)

        $dimByte = if ($Size -ge 256) { [byte]0 } else { [byte]$Size }
        $bw.Write($dimByte)
        $bw.Write($dimByte)
        $bw.Write([byte]0)
        $bw.Write([byte]0)
        $bw.Write([uint16]1)
        $bw.Write([uint16]32)
        $bw.Write([uint32]$pngBytes.Length)
        $bw.Write([uint32]22)

        $bw.Write($pngBytes)
        $bw.Flush()
    }
    finally {
        if ($bw)     { $bw.Dispose() }
        if ($fs)     { $fs.Dispose() }
        if ($pngMs)  { $pngMs.Dispose() }
        if ($gfx)    { $gfx.Dispose() }
        if ($bmp)    { $bmp.Dispose() }
        if ($srcImg) { $srcImg.Dispose() }
    }
}

function New-BorderedPanel {
    param(
        [int]$X, [int]$Y, [int]$W, [int]$H,
        [System.Drawing.Color]$BackColor,
        [System.Drawing.Color]$BorderColor
    )
    $p = New-Object System.Windows.Forms.Panel
    $p.Location  = New-Object System.Drawing.Point($X, $Y)
    $p.Size      = New-Object System.Drawing.Size($W, $H)
    $p.BackColor = $BackColor
    $p.Tag       = $BorderColor
    $p.Add_Paint({
        param($sender, $e)
        $pen = New-Object System.Drawing.Pen($sender.Tag, 1)
        try {
            $e.Graphics.DrawRectangle($pen, 0, 0, $sender.Width - 1, $sender.Height - 1)
        } finally {
            $pen.Dispose()
        }
    })
    return $p
}

function New-StyledButton {
    param(
        [string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H,
        [bool]$IsPrimary = $false
    )
    $b = New-Object System.Windows.Forms.Button
    $b.Text      = $Text
    $b.Location  = New-Object System.Drawing.Point($X, $Y)
    $b.Size      = New-Object System.Drawing.Size($W, $H)
    $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $b.Cursor    = [System.Windows.Forms.Cursors]::Hand
    $b.Font      = New-Object System.Drawing.Font('Segoe UI', 9)
    $b.ForeColor = $ColTextPrimary

    if ($IsPrimary) {
        $b.BackColor = $ColAccent
        $b.FlatAppearance.BorderSize         = 0
        $b.FlatAppearance.MouseOverBackColor = $ColAccentHover
    } else {
        $b.BackColor = $ColBgCard
        $b.FlatAppearance.BorderSize         = 1
        $b.FlatAppearance.BorderColor        = $ColBorderSub
        $b.FlatAppearance.MouseOverBackColor = $ColBgCardHover
    }
    return $b
}

# Build form
$form = New-Object System.Windows.Forms.Form
$form.Text            = 'Sandboxie Minus Setup'
$form.ClientSize      = New-Object System.Drawing.Size(460, 248)
$form.StartPosition   = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
$form.MaximizeBox     = $false
$form.BackColor       = $ColBgMain
$form.ForeColor       = $ColTextPrimary
$form.Font            = New-Object System.Drawing.Font('Segoe UI', 9)

$formIconBmp = $null
if (Test-Path $SourceIconPng) {
    try {
        $imgTmp = [System.Drawing.Image]::FromFile($SourceIconPng)
        $formIconBmp = New-Object System.Drawing.Bitmap($imgTmp, 64, 64)
        $form.Icon = [System.Drawing.Icon]::FromHandle($formIconBmp.GetHicon())
        $imgTmp.Dispose()
    } catch { }
}

$form.Add_HandleCreated({
    [WinApiHelper]::EnableDarkTitleBar($form.Handle, 0x001C1A1B)
})

# Header
$picIcon = New-Object System.Windows.Forms.PictureBox
$picIcon.Location = New-Object System.Drawing.Point(24, 24)
$picIcon.Size     = New-Object System.Drawing.Size(48, 48)
$picIcon.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
if (Test-Path $SourceIconPng) {
    $picIcon.Image = [System.Drawing.Image]::FromFile($SourceIconPng)
}
$form.Controls.Add($picIcon)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text     = 'Sandboxie Minus'
$lblTitle.Location = New-Object System.Drawing.Point(84, 25)
$lblTitle.Size     = New-Object System.Drawing.Size(372, 24)
$lblTitle.Font     = New-Object System.Drawing.Font('Segoe UI Semibold', 11)
$form.Controls.Add($lblTitle)

$lblSub = New-Object System.Windows.Forms.Label
$lblSub.Text      = 'This will install Sandboxie Minus on your computer.'
$lblSub.Location  = New-Object System.Drawing.Point(84, 51)
$lblSub.Size      = New-Object System.Drawing.Size(372, 20)
$lblSub.ForeColor = $ColTextMuted
$form.Controls.Add($lblSub)

# Shortcut option
$chkDesktopShortcut = New-Object System.Windows.Forms.CheckBox
$chkDesktopShortcut.Text      = 'Create a desktop shortcut'
$chkDesktopShortcut.Location  = New-Object System.Drawing.Point(24, 96)
$chkDesktopShortcut.Size      = New-Object System.Drawing.Size(432, 24)
$chkDesktopShortcut.Checked   = $true
$chkDesktopShortcut.ForeColor = $ColTextPrimary
$form.Controls.Add($chkDesktopShortcut)

# Progress
$progressTrack = New-BorderedPanel -X 24 -Y 140 -W 432 -H 6 -BackColor $ColBgCard -BorderColor $ColBgCard
$form.Controls.Add($progressTrack)

$progressFill = New-Object System.Windows.Forms.Panel
$progressFill.Location  = New-Object System.Drawing.Point(1, 1)
$progressFill.Size      = New-Object System.Drawing.Size(0, 4)
$progressFill.BackColor = $ColAccent
$progressTrack.Controls.Add($progressFill)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text      = 'Ready to install.'
$lblStatus.Location  = New-Object System.Drawing.Point(24, 154)
$lblStatus.Size      = New-Object System.Drawing.Size(432, 20)
$lblStatus.ForeColor = $ColTextMuted
$form.Controls.Add($lblStatus)

$divider = New-Object System.Windows.Forms.Panel
$divider.Location  = New-Object System.Drawing.Point(0, 186)
$divider.Size      = New-Object System.Drawing.Size(480, 1)
$divider.BackColor = $ColDivider
$form.Controls.Add($divider)

$btnCancel  = New-StyledButton -Text 'Cancel'  -X 268 -Y 198 -W 90 -H 30
$btnInstall = New-StyledButton -Text 'Install' -X 366 -Y 198 -W 90 -H 30 -IsPrimary $true
$form.Controls.AddRange(@($btnCancel, $btnInstall))
$form.AcceptButton = $btnInstall
$form.CancelButton = $btnCancel

$script:InstallFinished = $false

function Set-ProgressState {
    param(
        [int]$Percent,
        [string]$Text,
        [System.Drawing.Color]$Color = $ColTextMuted
    )
    $maxW = $progressTrack.Width - 2
    $progressFill.Width = [int]([Math]::Max(0, [Math]::Min($maxW, ($maxW * $Percent / 100))))
    $lblStatus.Text      = $Text
    $lblStatus.ForeColor = $Color
    $form.Refresh()
    [System.Windows.Forms.Application]::DoEvents()
}

$btnCancel.Add_Click({
    $form.Close()
})

$btnInstall.Add_Click({
    if ($script:InstallFinished) {
        $form.Close()
        return
    }

    $btnInstall.Enabled         = $false
    $btnCancel.Enabled          = $false
    $chkDesktopShortcut.Enabled = $false

    try {
        Set-ProgressState -Percent 20 -Text 'Checking setup files...'

        if (-not (Test-Path -LiteralPath $SourceZip -PathType Leaf)) {
            throw 'Installation files are missing.'
        }

        $expected   = $ExpectedSha256.Trim().ToUpperInvariant()
        $sourceHash = (Get-FileHash -LiteralPath $SourceZip -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($sourceHash -ne $expected) {
            throw 'Setup verification failed. Installation aborted.'
        }

        Set-ProgressState -Percent 55 -Text 'Extracting files...'

        if (-not (Test-Path -LiteralPath $TargetDir)) {
            New-Item -Path $TargetDir -ItemType Directory -Force | Out-Null
        }

        Expand-Archive -LiteralPath $SourceZip -DestinationPath $TargetDir -Force

        $requiredFiles = @(
            $DestScript,
            (Join-Path $DestSrcDir 'NativeInterop.cs'),
            (Join-Path $DestSrcDir '01-ConfigAndValidation.ps1'),
            (Join-Path $DestSrcDir '02-SandboxEngine.ps1'),
            (Join-Path $DestSrcDir '03-ElevationAndProcess.ps1'),
            (Join-Path $DestSrcDir '04-GuiThemeAndTabs.ps1'),
            (Join-Path $DestSrcDir '05-GuiController.ps1')
        )
        foreach ($rf in $requiredFiles) {
            if (-not (Test-Path -LiteralPath $rf -PathType Leaf)) {
                throw "Extracted file missing: $rf"
            }
        }

        Get-ChildItem -LiteralPath $TargetDir -Recurse -File | Unblock-File -ErrorAction SilentlyContinue
        $null = & icacls.exe $DestScript /inheritance:r /grant:r "*S-1-5-18:(F)" "*S-1-5-32-544:(F)" "*S-1-5-32-545:(RX)" /Q 2>&1
        $null = & icacls.exe $DestSrcDir /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)(F)" "*S-1-5-32-544:(OI)(CI)(F)" "*S-1-5-32-545:(OI)(CI)(RX)" /Q 2>&1


        if ($chkDesktopShortcut.Checked) {
            Set-ProgressState -Percent 85 -Text 'Creating shortcut...'

            $iconLocation = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe,0"
            if (Test-Path $SourceIconPng) {
                Convert-PngToIco -InputPngPath $SourceIconPng -OutputIcoPath $DestIconIco -Size 256
                Unblock-File -Path $DestIconIco -ErrorAction SilentlyContinue
                $null = & icacls.exe $DestIconIco /reset /Q 2>&1
                $iconLocation = "$DestIconIco,0"
            }

            $wsh = New-Object -ComObject WScript.Shell
            $lnk = $wsh.CreateShortcut($ShortcutPath)
            $lnk.TargetPath       = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
            $lnk.Arguments        = "-NoProfile -ExecutionPolicy Bypass -File `"$DestScript`""
            $lnk.WorkingDirectory = $TargetDir
            $lnk.IconLocation     = $iconLocation
            $lnk.Save()

            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($wsh)
        }

        $script:InstallFinished = $true
        $btnCancel.Visible      = $false
        $btnInstall.Text        = 'Finish'
        $btnInstall.Enabled     = $true
        Set-ProgressState -Percent 100 -Text 'Installation complete.' -Color $ColSuccess
    }
    catch {
        $btnCancel.Text    = 'Close'
        $btnCancel.Enabled = $true
        Set-ProgressState -Percent 0 -Text $_.Exception.Message -Color $ColError
    }
})

$form.Add_Shown({
    if (-not (Test-Path -LiteralPath $SourceZip -PathType Leaf)) {
        if ((Test-Path -LiteralPath $DestScript -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $DestSrcDir 'NativeInterop.cs') -PathType Leaf)) {
            $script:InstallFinished     = $true
            $chkDesktopShortcut.Enabled = $false
            $btnCancel.Visible          = $false
            $btnInstall.Text            = 'Finish'
            Set-ProgressState -Percent 100 -Text 'Already installed.' -Color $ColSuccess
        } else {
            $btnInstall.Enabled = $false
            $btnCancel.Text     = 'Close'
            Set-ProgressState -Percent 0 -Text 'Installation files are missing.' -Color $ColError
        }
    }
})

$consoleHwnd = [WinApiHelper]::GetConsoleWindow()
if ($consoleHwnd -ne [IntPtr]::Zero) {
    [void][WinApiHelper]::ShowWindow($consoleHwnd, 0)
}

try {
    [void]$form.ShowDialog()
}
finally {
    if ($picIcon.Image) { $picIcon.Image.Dispose() }
    if ($formIconBmp)   { $formIconBmp.Dispose() }
    $form.Dispose()
}