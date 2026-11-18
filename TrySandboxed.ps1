#requires -Version 5.1
<#
  AppContainer Manager - create and launch Windows AppContainer sandbox profiles (no MSIX needed)
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
    [switch]$DryRun
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
        $acmNeedle = 'Enumerate' + 'SubKeys -bor [System.Security.AccessControl.RegistryRights]::QueryValues'
        $engFile = Join-Path $script:AppRoot 'src\02-SandboxEngine.ps1'
        Log "DIAG elevated engine: $engFile | written: $((Get-Item -LiteralPath $engFile).LastWriteTime) | rights patch present: $((Get-Content -LiteralPath $engFile -Raw).Contains($acmNeedle))"
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

# 3. GUI mode
. (Resolve-AcmPartPath 'src\03-ElevationAndProcess.ps1')
. (Resolve-AcmPartPath 'src\04-GuiThemeAndTabs.ps1')
. (Resolve-AcmPartPath 'src\05-GuiController.ps1')