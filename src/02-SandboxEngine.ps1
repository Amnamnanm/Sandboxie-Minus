function Resolve-RulePath([string]$raw) {
    if ([string]::IsNullOrWhiteSpace($raw)) { return '' }
    $x = [Environment]::ExpandEnvironmentVariables($raw.Trim().Trim('"'))
    if ($x -match '^[A-Za-z]:$') { $x += '\' }
    try { $x = [IO.Path]::GetFullPath($x) } catch {}
    if ($x.Length -gt 3) { $x = $x.TrimEnd('\') }
    $x
}
function Test-SystemPath([string]$p) { $p -match '(?i)^[A-Z]:\\(Windows|Program Files|Program Files \(x86\))(\\|$)' }
function Test-Under([string]$child, [string]$parent) {
    $child -ieq $parent -or $child.StartsWith($parent.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
}
function Invoke-Native([string]$exe, [string[]]$argList) {
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = & $exe @argList 2>&1 | ForEach-Object { "$_" }; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $old }
    [pscustomobject]@{ Code = $code; Out = ($out -join ' ') }
}
function Resolve-SystemExe([string]$exeName) {
    $sysDir = [Environment]::GetFolderPath('System')
    $full = Join-Path $sysDir $exeName
    if (Test-Path -LiteralPath $full -PathType Leaf) { return $full }
    $exeName
}
function Test-IsReparsePoint([string]$path) {
    try { (([IO.File]::GetAttributes($path)) -band [IO.FileAttributes]::ReparsePoint) -ne 0 } catch { $true }
}
$script:AllowMap = @{ Read = 'R'; ReadWrite = 'M'; ReadExecute = 'RX'; Full = 'F' }
$script:PathScopeUi = [ordered]@{
    Recursive      = 'Recursive (subfolders & files)'
    DirectContents = 'Folder + direct contents'
    FolderOnly     = 'This folder only'
}
$script:RegScopeUi = [ordered]@{
    Recursive      = 'Key + all subkeys (recursive)'
    DirectContents = 'Key + direct subkeys'
    FolderOnly     = 'This key only'
}
function Resolve-PathScopeKey([string]$v) {
    switch ($v) {
        'FolderOnly' { 'FolderOnly' }
        'This folder only' { 'FolderOnly' }
        'DirectContents' { 'DirectContents' }
        'Folder + direct contents' { 'DirectContents' }
        default { 'Recursive' }
    }
}
function Resolve-RegScopeKey([string]$v) {
    switch ($v) {
        'FolderOnly' { 'FolderOnly' }
        'This key only' { 'FolderOnly' }
        'DirectContents' { 'DirectContents' }
        'Key + direct subkeys' { 'DirectContents' }
        default { 'Recursive' }
    }
}
# ===Ambient ACL Inspection
function Convert-FsAccessMask([int]$raw) {
    # Map Win32 GENERIC_* bits onto FileSystemRights so generic ACEs match Read/Execute checks
    $m = $raw
    if (($raw -band 0x10000000) -ne 0) { $m = $m -bor [int][System.Security.AccessControl.FileSystemRights]::FullControl }
    if (($raw -band [int]0x80000000) -ne 0) { $m = $m -bor [int][System.Security.AccessControl.FileSystemRights]::Read }
    if (($raw -band 0x20000000) -ne 0) { $m = $m -bor [int][System.Security.AccessControl.FileSystemRights]::ExecuteFile }
    $m
}
function Test-AmbientAclReadExec([string]$path, [bool]$lpac, [string]$access = 'ReadExecute', [string]$containerSid = '') {
    $allowSids = if ($lpac) { @('S-1-15-2-2') } else { @('S-1-15-2-1', 'S-1-15-2-2') }
    $denySids = @($allowSids + @('S-1-1-0', 'S-1-5-32-545'))
    if ($containerSid) { $denySids += $containerSid }
    $need = if ($access -eq 'Read') { [int][System.Security.AccessControl.FileSystemRights]::Read } else { [int][System.Security.AccessControl.FileSystemRights]::ReadAndExecute }
    try {
        $acl = Get-Acl -LiteralPath $path
        $expAllow = 0; $expDeny = 0; $inhAllow = 0; $inhDeny = 0
        foreach ($ace in $acl.Access) {
            # Ignore InheritOnly ACEs that apply only to child objects, not this path itself
            if (($ace.PropagationFlags -band [System.Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0) { continue }
            $sid = try { $ace.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } catch { '' }
            if (-not $sid) { continue }
            $r = Convert-FsAccessMask ([int]$ace.FileSystemRights)
            if ($ace.AccessControlType -eq 'Deny' -and ($denySids -contains $sid)) {
                if ($ace.IsInherited) { $inhDeny = $inhDeny -bor $r } else { $expDeny = $expDeny -bor $r }
            } elseif ($ace.AccessControlType -eq 'Allow' -and ($allowSids -contains $sid)) {
                if ($ace.IsInherited) { $inhAllow = $inhAllow -bor $r } else { $expAllow = $expAllow -bor $r }
            }
        }
        # Windows canonical DACL order: explicit Allow overrides inherited Deny; explicit Deny overrides all
        $granted = (($inhAllow -band (-bnot $inhDeny)) -bor $expAllow) -band (-bnot $expDeny)
        return (($granted -band $need) -eq $need)
    } catch { return $false }
}
function Resolve-RegPath([string]$raw) {
    if ([string]::IsNullOrWhiteSpace($raw)) { return '' }
    $x = $raw.Trim().Trim('"') -replace '^(?i)Registry::', ''
    $x = $x -replace '^[^\\]+\\(?=(?i)(?:HKEY_(?:CURRENT_USER|LOCAL_MACHINE|CLASSES_ROOT|USERS|CURRENT_CONFIG)|HK(?:CU|LM|CR|U|CC))(?:\\|:|$))', ''
    $x = $x -replace '^(?i)(HKCU|HKEY_CURRENT_USER|HKLM|HKEY_LOCAL_MACHINE|HKCR|HKEY_CLASSES_ROOT|HKU|HKEY_USERS|HKCC|HKEY_CURRENT_CONFIG):', '$1'
    $parts = $x -split '\\+', 2
    $hive = switch -Regex ($parts[0].ToUpperInvariant()) {
        '^(HKCU|HKEY_CURRENT_USER)$'   { 'HKCU' }
        '^(HKLM|HKEY_LOCAL_MACHINE)$'  { 'HKLM' }
        '^(HKCR|HKEY_CLASSES_ROOT)$'   { 'HKCR' }
        '^(HKU|HKEY_USERS)$'           { 'HKU' }
        '^(HKCC|HKEY_CURRENT_CONFIG)$' { 'HKCC' }
        default { '' }
    }
    if (-not $hive) { return $x.TrimEnd('\') }
    $sub = if ($parts.Count -gt 1) { $parts[1].Trim('\') } else { '' }
    if ($sub) { "$hive\$sub" } else { $hive }
}
# ===Registry Path & Key Resolution
function Resolve-RegTargets([string]$normPath, [string]$view, [string]$userSid) {
    $parts = $normPath -split '\\', 2
    $hiveName = $parts[0]
    $sub = if ($parts.Count -gt 1) { $parts[1] } else { '' }
    $views = if ($view -eq '32') { @('32') } elseif ($view -eq '64') { @('64') } else { @('64', '32') }
    $targets = New-Object System.Collections.Generic.List[object]
    if ($hiveName -eq 'HKCR') {
        # HKCR is a merged virtual view; probe user Classes first, then fall back to machine Classes
        $subClasses = if ($sub) { "Software\Classes\$sub" } else { 'Software\Classes' }
        $uPath = "HKCU\$subClasses"
        $mPath = "HKLM\$($subClasses -replace '^Software', 'SOFTWARE')"
        $added = $false
        foreach ($cand in @($uPath, $mPath)) {
            foreach ($pv in @('64', '32')) {
                $k = $null
                try { $k = Open-RegKeyForAcl $cand $userSid $pv $false; $added = $true } catch {} finally { if ($k) { $k.Dispose() } }
                if ($added) { break }
            }
            if ($added) {
                # When View='Both', tolerate missing 32-bit (WOW6432Node) keys as long as one view exists
                foreach ($v in $views) { [void]$targets.Add([pscustomobject]@{ Path = $cand; View = $v; Optional = ($view -eq 'Both') }) }
                break
            }
        }
        if (-not $added) {
            foreach ($v in $views) { [void]$targets.Add([pscustomobject]@{ Path = $mPath; View = $v; Optional = ($view -eq 'Both') }) }
        }
        return ,$targets.ToArray()
    }
    foreach ($v in $views) { [void]$targets.Add([pscustomobject]@{ Path = $normPath; View = $v; Optional = ($view -eq 'Both') }) }
    ,$targets.ToArray()
}
function Open-RegKeyForAcl([string]$normPath, [string]$userSid, [string]$view = '64', [bool]$forWrite = $true) {
    $parts = $normPath -split '\\', 2
    $hiveName = $parts[0]
    $sub = if ($parts.Count -gt 1) { $parts[1] } else { '' }
    $regView = if ($view -eq '32') { [Microsoft.Win32.RegistryView]::Registry32 } else { [Microsoft.Win32.RegistryView]::Registry64 }
    $hiveEnum = switch ($hiveName) {
        'HKLM' { [Microsoft.Win32.RegistryHive]::LocalMachine }
        'HKU'  { [Microsoft.Win32.RegistryHive]::Users }
        'HKCC' { [Microsoft.Win32.RegistryHive]::CurrentConfig }
        'HKCU' {
            # Under over the shoulder UAC elevation, CurrentUser is the admin's hive; route to HKU\<TargetUserSid>
            if ($userSid) {
                $uBase = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::Users, $regView)
                try {
                    $probe = $uBase.OpenSubKey($userSid, $false)
                    if ($probe) { $probe.Dispose(); $sub = if ($sub) { "$userSid\$sub" } else { $userSid }; [Microsoft.Win32.RegistryHive]::Users }
                    else { [Microsoft.Win32.RegistryHive]::CurrentUser }
                } finally { $uBase.Dispose() }
            } else { [Microsoft.Win32.RegistryHive]::CurrentUser }
        }
        'HKCR' {
            $sub = if ($sub) { "Software\Classes\$sub" } else { 'Software\Classes' }
            if ($userSid) {
                $uBase = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::Users, $regView)
                try {
                    $probe = $uBase.OpenSubKey("$userSid\$sub", $false)
                    if ($probe) { $probe.Dispose(); $sub = "$userSid\$sub"; [Microsoft.Win32.RegistryHive]::Users }
                    else { $sub = "SOFTWARE\Classes" + $(if ($parts.Count -gt 1) { "\$($parts[1])" } else { '' }); [Microsoft.Win32.RegistryHive]::LocalMachine }
                } finally { $uBase.Dispose() }
            } else { [Microsoft.Win32.RegistryHive]::ClassesRoot }
        }
        default { throw "Unsupported registry hive in path: $normPath" }
    }
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hiveEnum, $regView)
    try {
        $rights = if ($forWrite) {
            [System.Security.AccessControl.RegistryRights]::ReadPermissions -bor [System.Security.AccessControl.RegistryRights]::ChangePermissions -bor [System.Security.AccessControl.RegistryRights]::EnumerateSubKeys -bor [System.Security.AccessControl.RegistryRights]::QueryValues
        } else { [System.Security.AccessControl.RegistryRights]::ReadPermissions }
        $permChk = if ($forWrite) { [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree } else { [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadSubTree }
        $k = $base.OpenSubKey($sub, $permChk, $rights)
        if (-not $k) { throw "Registry key not found ($view-bit): $normPath" }
        return $k
    } finally { $base.Dispose() }
}
$script:KnownCaps = @{ internetClient = 'S-1-15-3-1'; internetClientServer = 'S-1-15-3-2'; privateNetworkClientServer = 'S-1-15-3-3'
    picturesLibrary = 'S-1-15-3-4'; videosLibrary = 'S-1-15-3-5'; musicLibrary = 'S-1-15-3-6'; documentsLibrary = 'S-1-15-3-7'
    enterpriseAuthentication = 'S-1-15-3-8'; sharedUserCertificates = 'S-1-15-3-9'; removableStorage = 'S-1-15-3-10'
    appointments = 'S-1-15-3-11'; contacts = 'S-1-15-3-12' }
$script:KnownDerivedCaps = @(
    'lpacCom', 'lpacClipboard', 'lpacCryptoServices', 'lpacEnterprisePolicyChangeNotifications',
    'lpacIme', 'lpacIdentityServices', 'lpacInstrumentation', 'lpacMedia', 'lpacPackageManagerOperation',
    'lpacPayments', 'lpacPrinting', 'lpacServicesManagement', 'lpacSessionManagement', 'lpacWebPlatform',
    'registryRead', 'codeGeneration', 'runFullTrust', 'broadFileSystemAccess', 'userAccountInformation',
    'location', 'microphone', 'webcam', 'wiFiControl', 'bluetooth', 'graphicsCapture', 'appDiagnostics'
)
function Test-KnownCapabilityName([string]$name) {
    if ($script:KnownCaps.ContainsKey($name)) { return $true }
    if ($script:KnownDerivedCaps -contains $name -or $name -in 'usb', 'humanInterfaceDevice', 'humaninterfacedevice') { return $true }
    if ($name -match '^S-1-15-3-(?:\d+(?:-\d+){3}|\d+|1024(?:-\d+)+)$') { return $true }
    $false
}
function Get-UnknownExtraCaps($p) {
    $unk = @()
    foreach ($c in @($p.ExtraCaps -split '[,;\s]+' | Where-Object { $_ })) {
        if (-not (Test-KnownCapabilityName $c)) { $unk += $c }
    }
    $unk
}
function Test-ProfileHasNetCap($p) {
    if ($p.Net.Client -or $p.Net.Server -or $p.Net.Private) { return $true }
    foreach ($c in @($p.ExtraCaps -split '[,;\s]+' | Where-Object { $_ })) {
        if ($c -in 'internetClient', 'internetClientServer', 'privateNetworkClientServer', 'S-1-15-3-1', 'S-1-15-3-2', 'S-1-15-3-3',
            'lpacWebPlatform', 'allJoyn', 'proximity', 'wiFiControl', 'bluetooth', 'runFullTrust') { return $true }
    }
    $false
}
function Add-DerivedCapabilitySids([System.Collections.Generic.List[string]]$list, [string]$capName) {
    try { foreach ($x in [ACM.Native]::DeriveCapability($capName)) { $list.Add($x) } } catch {}
}
function Get-CapSids($p) {
    $s = New-Object System.Collections.Generic.List[string]
    if ($p.Net.Client)  { $s.Add('S-1-15-3-1'); if ($p.Hard.Lpac) { Add-DerivedCapabilitySids $s 'lpacIdentityServices'; Add-DerivedCapabilitySids $s 'lpacCryptoServices' } }
    if ($p.Net.Server)  { $s.Add('S-1-15-3-2') }
    if ($p.Net.Private) { $s.Add('S-1-15-3-3') }
    if ($p.Hard.RegRead) { Add-DerivedCapabilitySids $s 'registryRead' }
    if ($p.Dev) {
        if ($p.Dev.Mic) {
            Add-DerivedCapabilitySids $s 'microphone'
            $s.Add('S-1-15-3-787448254-1207972858-3558633622-1059886964') # DEVINTERFACE_AUDIO_CAPTURE
        }
        if ($p.Dev.Webcam) {
            Add-DerivedCapabilitySids $s 'webcam'
            $s.Add('S-1-15-3-3845273463-1331427702-1186551195-1148109977') # DEVINTERFACE_VIDEO_CAMERA
        }
        if ($p.Dev.Location) {
            Add-DerivedCapabilitySids $s 'location'
            $s.Add('S-1-15-3-3215430884-1339816292-89257616-1145831019') # SENSOR_CATEGORY_LOCATION
        }
        if ($p.Dev.UsbHidMode -eq 'All') {
            Add-DerivedCapabilitySids $s 'usb'
            Add-DerivedCapabilitySids $s 'humanInterfaceDevice'
            $s.Add('S-1-15-3-2782707472-299001136-3221233552-3981556047') # GUID_DEVINTERFACE_USB_DEVICE
            $s.Add('S-1-15-3-1293833650-298840431-285264776-805306385')   # GUID_DEVINTERFACE_HID
        }
    }
    foreach ($c in @($p.ExtraCaps -split '[,;\s]+' | Where-Object { $_ })) {
        if ($script:KnownCaps.ContainsKey($c)) { $s.Add($script:KnownCaps[$c]) }
        elseif ($c -match '^S-1-15-3-') { $s.Add($c) }
        else { Add-DerivedCapabilitySids $s $c }
    }
    $s | Select-Object -Unique
}
# ===Capabilities & Exploit Mitigations
function Get-Mitigation($h) {
    # PROCESS_CREATION_MITIGATION_POLICY_* 4-bit nibble offsets from winbase.h (01 = ALWAYS_ON)
    $bits1 = [ordered]@{ HeapTerminate = 12; BottomUpAslr = 16; HighEntropyAslr = 20; StrictHandles = 24; Win32k = 28
        NoExtPoints = 32; NoDynCode = 36; Cfg = 40; BlockNonMs = 44; NoFonts = 48; ImgNoRemote = 52; ImgNoLowLabel = 56; ImgPreferSys32 = 60 }
    [uint64]$m1 = 0
    foreach ($k in $bits1.Keys) { if ($h.$k) { $m1 = $m1 -bor ([uint64]1 -shl $bits1[$k]) } }
    # 0x05 = DEP_ENABLE (0x01) | SEHOP_ENABLE (0x04); NativeInterop.cs masks these bits off for 64-bit EXEs
    if ($h.DepSehop32) { $m1 = $m1 -bor ([uint64]0x05) }
    # Bit 8 = FORCE_RELOCATE_IMAGES_ALWAYS_ON
    if ($h.ForceRelocate) { $m1 = $m1 -bor ([uint64]1 -shl 8) }
    # PROCESS_CREATION_MITIGATION_POLICY2_* nibble offsets
    $bits2 = [ordered]@{ StrictCfg = 8; RestrictIbp = 16; Ssbd = 24; CetShadowStack = 28; NoFsctl = 56 }
    [uint64]$m2 = 0
    foreach ($k in $bits2.Keys) { if ($h.$k) { $m2 = $m2 -bor ([uint64]1 -shl $bits2[$k]) } }
    @($m1, $m2)
}
function Get-EnvBlock($p, [string]$acDir, [string]$roamingDir, [string]$tempDir) {
    $d = @{}
    $hostEnv = @{}
    foreach ($e in [Environment]::GetEnvironmentVariables().GetEnumerator()) {
        $k = [string]$e.Key
        if (-not $k -or $k.StartsWith('=')) { continue }
        $hostEnv[$k] = [string]$e.Value
    }
    if ($p.EnvMode -eq 'InheritHost') {
        foreach ($k in $hostEnv.Keys) { $d[$k] = $hostEnv[$k] }
    } else {
        $safeVars = @('SystemRoot', 'SystemDrive', 'windir', 'ComSpec', 'OS', 'NUMBER_OF_PROCESSORS',
            'PROCESSOR_ARCHITECTURE', 'PROCESSOR_ARCHITEW6432', 'PROCESSOR_IDENTIFIER', 'PROCESSOR_LEVEL',
            'PROCESSOR_REVISION', 'PATHEXT', 'ProgramFiles', 'ProgramFiles(x86)', 'ProgramW6432',
            'CommonProgramFiles', 'CommonProgramFiles(x86)', 'CommonProgramW6432',
            'ProgramData', 'ALLUSERSPROFILE')
        foreach ($sv in $safeVars) { if ($hostEnv.ContainsKey($sv)) { $d[$sv] = $hostEnv[$sv] } }
        $winRoot = Resolve-RulePath $env:SystemRoot
        $exeDir = if ($p.ExePath) { Split-Path -Parent (Resolve-RulePath $p.ExePath) } else { '' }
        $rawPath = if ($hostEnv.ContainsKey('PATH')) { $hostEnv['PATH'] } else { "$env:SystemRoot\System32;$env:SystemRoot" }
        $cleanPath = New-Object System.Collections.Generic.List[string]
        foreach ($seg in ($rawPath -split ';')) {
            $sp = Resolve-RulePath $seg
            if (-not $sp) { continue }
            $keep = ($winRoot -and (Test-Under $sp $winRoot)) -or ($exeDir -and ($sp -ieq $exeDir))
            if (-not $keep) {
                foreach ($r in @($p.Rules)) {
                    if (Test-RuleCoversDir $sp $r) { $keep = $true; break }
                }
            }
            if ($keep -and ($cleanPath -notcontains $sp)) { [void]$cleanPath.Add($sp) }
        }
        if ($cleanPath.Count -gt 0) { $d['PATH'] = $cleanPath -join ';' }
        foreach ($allowVar in @($p.EnvAllow -split '[,;\s]+' | Where-Object { $_ })) {
            if ($hostEnv.ContainsKey($allowVar)) { $d[$allowVar] = $hostEnv[$allowVar] }
        }
        if ($p.Hard.RedirectProfile) {
            $d['USERPROFILE'] = $acDir
            if ($acDir -match '^[A-Za-z]:\\') { $d['HOMEDRIVE'] = $acDir.Substring(0, 2); $d['HOMEPATH'] = $acDir.Substring(2) }
        } else {
            foreach ($pv in @('USERPROFILE', 'HOMEDRIVE', 'HOMEPATH', 'APPDATA')) { if ($hostEnv.ContainsKey($pv)) { $d[$pv] = $hostEnv[$pv] } }
        }
    }
    $d['LOCALAPPDATA'] = $acDir
    if ($p.Hard.RedirectProfile) { $d['APPDATA'] = $roamingDir }
    $d['TEMP'] = $tempDir; $d['TMP'] = $tempDir
    foreach ($ln in ($p.EnvCustom -split "`r?`n")) {
        $t = $ln.Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        $idx = $t.IndexOf('=')
        if ($idx -gt 0) {
            $ck = $t.Substring(0, $idx).Trim(); $cv = $t.Substring($idx + 1)
            if ($ck -and -not $ck.StartsWith('=')) { $d[$ck] = $cv }
        }
    }
    $keys = [string[]]@($d.Keys)
    [Array]::Sort($keys, [StringComparer]::OrdinalIgnoreCase)
    $keys | ForEach-Object { '{0}={1}' -f $_, $d[$_] }
}
function Test-RuleCoversExe([string]$exe, $r) {
    if ($r.Access -notin 'ReadExecute', 'ReadWrite', 'Full') { return $false }
    $rp = Resolve-RulePath $r.Path
    if (-not $rp) { return $false }
    $sc = Resolve-PathScopeKey $r.Scope
    switch ($sc) {
        'FolderOnly'     { return ($exe -ieq $rp) }
        'DirectContents' { return ($exe -ieq $rp -or ((Split-Path -Parent $exe) -ieq $rp)) }
        default          { return (Test-Under $exe $rp) }
    }
}
function Test-RuleCoversDir([string]$dir, $r) {
    $rp = Resolve-RulePath $r.Path
    if (-not $rp) { return $false }
    $sc = Resolve-PathScopeKey $r.Scope
    switch ($sc) {
        'FolderOnly'     { return ($dir -ieq $rp) }
        'DirectContents' { return ($dir -ieq $rp -or ((Split-Path -Parent $dir) -ieq $rp)) }
        default          { return (Test-Under $dir $rp) }
    }
}
function Test-ExeAccessible($p) {
    $exe = Resolve-RulePath $p.ExePath
    if (-not $exe) { return $false }
    if (Test-AmbientAclReadExec $exe ([bool]$p.Hard.Lpac) 'ReadExecute') { return $true }
    foreach ($r in @($p.Rules)) { if (Test-RuleCoversExe $exe $r) { return $true } }
    $false
}

# ===Launch
function Format-ExitCodeHint([uint32]$ec) {
    $hex = '0x' + $ec.ToString('X8')
    switch ($ec) {
        0 { return '' }
        3221225781 { return " ($hex STATUS_DLL_NOT_FOUND - check Read+Execute ACLs on EXE folder/DLL subfolders or D3DSCache under LPAC)" }
        3221225794 { return " ($hex STATUS_DLL_INIT_FAILED - check DLL/folder ACLs, custom desktop permissions, or Win32k/BlockNonMs restrictions)" }
        3221225477 { return " ($hex STATUS_ACCESS_VIOLATION - crashed, possibly under strict CFG/NoDynCode/DEP)" }
        3221225506 { return " ($hex STATUS_ACCESS_DENIED - check WorkDir, EXE, or required registry/path ACLs)" }
        default    { return " ($hex)" }
    }
}
function Start-Sandboxed($p) {
    if (Test-Admin) { throw 'Refusing to launch an AppContainer from an elevated Administrator session. Run from a normal (non-admin) session.' }
    if (-not $p.ExePath) { throw 'No executable set for this profile.' }
    $winBuild = [ACM.Native]::GetWindowsBuild()
    if ($p.Hard.Lpac -and $winBuild -gt 0 -and $winBuild -lt 15063) {
        throw "LPAC and DeriveCapabilitySidsFromName require Windows 10 version 1703 (build 15063) or newer (current build: $winBuild)."
    }
    $unkCaps = @(Get-UnknownExtraCaps $p)
    if ($unkCaps.Count -gt 0) { Log "WARNING: Unrecognized capability name(s) in ExtraCaps (hash-derived, check spelling): $($unkCaps -join ', ')" }
    if (-not $p.Hard.Lpac) { Log "WARNING: Launching '$($p.Name)' with LPAC OFF (S-1-15-2-1 active)." }
    $exe = Resolve-RulePath $p.ExePath
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Executable not found: $exe" }
    $h = $p.Hard
    $eph = [bool]$h.Ephemeral
    if (Test-ProfileHasDynamicPaths $p) { throw 'This profile contains unresolved dynamic preset placeholders (*n) and cannot be launched.' }
    $cn  = if ($eph) { 'acm.eph.' + [guid]::NewGuid().ToString('N').Substring(0, 16) } else { Get-ContainerName $p }
    if ($eph) {
        if (@($p.Rules).Count -gt 0 -or @($p.RegRules).Count -gt 0) {
            Log 'NOTE: Ephemeral mode uses a fresh random SID; custom admin-applied ACL rules on the saved profile SID do not apply to it.'
        }
        if (-not $h.WaitTree) {
            Log 'NOTE: Ephemeral mode enforces WaitTree so container storage is not wiped while child processes are still running.'
        }
        $pkgParent = Join-Path $env:LOCALAPPDATA 'Packages'
        if (Test-Path -LiteralPath $pkgParent -PathType Container) {
            foreach ($ephDir in @(Get-ChildItem -LiteralPath $pkgParent -Filter 'acm.eph.*' -Directory -ErrorAction SilentlyContinue)) {
                try {
                    $ephSid = [ACM.Native]::GetSidString($ephDir.Name)
                    if (@([ACM.Native]::GetContainerPids($ephSid)).Count -eq 0) {
                        [ACM.Native]::DeleteProfileChecked($ephDir.Name)
                        Remove-Item -LiteralPath $ephDir.FullName -Recurse -Force -ErrorAction SilentlyContinue
                    }
                } catch { Log "WARN orphan ephemeral cleanup ($($ephDir.Name)): $($_.Exception.Message)" }
            }
        }
    }
    $capSids = [string[]]@(Get-CapSids $p)
    $sid = $null; $pkgRoot = $null
    try {
        $sid = [ACM.Native]::EnsureProfile($cn, $p.Name, "AppContainer profile '$($p.Name)' managed by AppContainer Manager", $capSids)
        $base = ([ACM.Native]::GetFolder($sid)).TrimEnd('\')
        if ($base -notmatch '\\AC$') { $base = Join-Path $base 'AC' }
        $pkgRoot = Split-Path -Parent $base
        $tmp = Join-Path $base 'Temp'
        $roaming = Join-Path $base 'AppData\Roaming'
        $localSub = Join-Path $base 'AppData\Local'
        foreach ($d in @($tmp, $roaming, $localSub)) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }
        $wd = if ($p.WorkDir) { Resolve-RulePath $p.WorkDir } else {
            $exeParent = Split-Path -Parent $exe
            $parentOk = (Test-AmbientAclReadExec $exeParent ([bool]$h.Lpac) 'Read') -or ($null -ne ($p.Rules | Where-Object { Test-RuleCoversDir $exeParent $_ } | Select-Object -First 1))
            if ($parentOk) { $exeParent } else { Log "WorkDir fallback to container AC folder (parent of EXE has no allow rule): $base"; $base }
        }
        $mit = Get-Mitigation $h
        $o = New-Object ACM.LaunchOptions
        $o.Exe = $exe
        $o.CommandLine = ('"{0}" {1}' -f $exe, $p.Arguments).Trim()
        $o.WorkDir = $wd
        $o.Desktop = if ($p.CustomDesktop) { $p.CustomDesktop.Trim() } else { '' }
        $o.ContainerName = $cn
        $o.CapabilitySids = $capSids
        $o.Env = [string[]]@(Get-EnvBlock $p $base $roaming $tmp)
        $o.Lpac = [bool]$h.Lpac
        $o.ChildRestrict = [bool]$h.NoChild
        $o.NewConsole = [bool]$h.ShowConsole
        $o.KillOnClose = [bool]$h.KillOnClose
        $o.WaitTree = ([bool]$h.WaitTree -or $eph)
        $o.Mitigation = [uint64]$mit[0]
        $o.Mitigation2 = [uint64]$mit[1]
        if ($p.Limits) {
            $o.MaxProcesses = [uint32]([Math]::Max(0, [int]$p.Limits.MaxProcesses))
            $o.ProcessMemMb = [uint64]([Math]::Max(0, [int]$p.Limits.ProcessMemMb))
            $o.JobMemMb = [uint64]([Math]::Max(0, [int]$p.Limits.JobMemMb))
            $o.CpuRatePct = [uint32]([Math]::Max(0, [Math]::Min(100, [int]$p.Limits.CpuRatePct)))
        }
        [uint32]$ui = 0
        # 0x06 = JOB_OBJECT_UILIMIT_READCLIPBOARD | WRITECLIPBOARD
        if ($h.NoClipboard)  { $ui = $ui -bor 0x06 }
        # 0xF9 = HANDLES | SYSTEMPARAMETERS | DISPLAYSETTINGS | GLOBALATOMS | DESKTOP | EXITWINDOWS
        if ($h.NoDesktopSys) { $ui = $ui -bor 0xF9 }
        $o.JobUiFlags = $ui
        # Keep launcher alive when KillOnClose or Ephemeral needs the Job handle / finally cleanup
        $o.Wait = ($o.KillOnClose -or $eph)
        [ACM.Native]::Launch($o)
        foreach ($w in $o.Warnings) { Log "WARNING: $w" }
        Log "Launched '$($p.Name)' PID $($o.Pid) in container $sid"
        if ($o.Wait -and $o.ExitCode -ne 0) {
            Log ("Process exited with code $($o.ExitCode)" + (Format-ExitCodeHint $o.ExitCode))
        }
    }
    finally {
        if ($eph) {
            if ($sid -and $h.KillOnClose) { [void][ACM.Native]::TerminateContainerPids($sid) }
            try { [ACM.Native]::DeleteProfileChecked($cn) } catch { Log "WARN ephemeral profile delete: $($_.Exception.Message)" }
            if ($pkgRoot -and (Test-Path -LiteralPath $pkgRoot)) {
                Remove-Item -LiteralPath $pkgRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# ===Apply/revoke (admin)
function Invoke-Icacls([string[]]$a) {
    if ($a -notcontains '/L') { $a = $a + @('/L') }
    Invoke-Native (Resolve-SystemExe 'icacls.exe') $a
}
function Remove-Firewall($p) {
    $grp = Get-FirewallGroup $p
    try { Get-NetFirewallRule -Group $grp -ErrorAction SilentlyContinue | Remove-NetFirewallRule } catch {}
}
function Remove-Loopback($p, $sid) {
    if ($p.Applied.Loopback) { [void](Invoke-Native (Resolve-SystemExe 'CheckNetIsolation.exe') @('LoopbackExempt', '-d', "-p=$sid")) }
}
function Remove-RegSubtreeExplicitAces($rootKey, $sidObj, [hashtable]$subResult = $null) {
    $q = New-Object System.Collections.Generic.Queue[Microsoft.Win32.RegistryKey]
    $q.Enqueue($rootKey)
    while ($q.Count -gt 0) {
        $cur = $q.Dequeue()
        try {
            foreach ($name in $cur.GetSubKeyNames()) {
                $sub = $null
                try {
                    $sub = $cur.OpenSubKey($name, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadSubTree,
                        ([System.Security.AccessControl.RegistryRights]::ReadPermissions -bor [System.Security.AccessControl.RegistryRights]::EnumerateSubKeys -bor [System.Security.AccessControl.RegistryRights]::QueryValues))
                    if (-not $sub) { continue }
                    $sacl = $sub.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Access)
                    $has = $false
                    foreach ($ace in $sacl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier])) {
                        if ($ace.IdentityReference.Value -eq $sidObj.Value) { $has = $true; break }
                    }
                    if ($has) {
                        $subW = $null
                        try {
                            $subW = $cur.OpenSubKey($name, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
                                ([System.Security.AccessControl.RegistryRights]::ReadPermissions -bor [System.Security.AccessControl.RegistryRights]::ChangePermissions))
                            if ($subW) {
                                $wacl = $subW.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Access)
                                $wacl.PurgeAccessRules($sidObj)
                                $subW.SetAccessControl($wacl)
                            }
                        } catch {
                            if ($subResult) { $subResult.HasError = $true }
                            Log "WARN Reg revoke subkey $($cur.Name)\$($name): $($_.Exception.Message)"
                        } finally { if ($subW) { $subW.Dispose() } }
                    }
                    $q.Enqueue($sub)
                } catch {
                    if ($sub) { $sub.Dispose() }
                }
            }
        } catch {
            if ($subResult) { $subResult.HasError = $true }
            Log "WARN Reg enum $($cur.Name): $($_.Exception.Message)"
        }
        if ($cur -ne $rootKey) { $cur.Dispose() }
    }
}
function Remove-RegSidAce([string]$regPath, [string]$sid, [string]$userSid, [string]$view = 'Both') {
    $sidObj = New-Object System.Security.Principal.SecurityIdentifier($sid)
    $foundAny = $false
    $subResult = @{ HasError = $false }
    foreach ($tgt in (Resolve-RegTargets $regPath $view $userSid)) {
        try {
            $key = Open-RegKeyForAcl $tgt.Path $userSid $tgt.View $true
            try {
                $foundAny = $true
                $acl = $key.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Access)
                $has = $false
                foreach ($ace in $acl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier])) {
                    if ($ace.IdentityReference.Value -eq $sidObj.Value) { $has = $true; break }
                }
                if ($has) { $acl.PurgeAccessRules($sidObj); $key.SetAccessControl($acl) }
                Remove-RegSubtreeExplicitAces $key $sidObj $subResult
            } finally { $key.Dispose() }
        } catch { if (-not $tgt.Optional) { throw } }
    }
    if (-not $foundAny) { throw "Registry key not found in requested view(s): $regPath" }
    if ($subResult.HasError) { throw "One or more subkeys failed during registry ACE removal on $regPath (see warnings)." }
}
function Set-RegKeySingleAce($key, $sidObj, $rights, $inh, $prop) {
    $acl = $key.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Access)
    $rule = New-Object System.Security.AccessControl.RegistryAccessRule($sidObj, $rights, $inh, $prop, [System.Security.AccessControl.AccessControlType]::Allow)
    $acl.SetAccessRule($rule)
    $key.SetAccessControl($acl)
}
function Apply-RegProtectedSubkeys($rootKey, $sidObj, $rights, $inh, $prop, [hashtable]$subResult = $null) {
    $q = New-Object System.Collections.Generic.Queue[Microsoft.Win32.RegistryKey]
    $q.Enqueue($rootKey)
    while ($q.Count -gt 0) {
        $cur = $q.Dequeue()
        try {
            foreach ($name in $cur.GetSubKeyNames()) {
                $sub = $null
                try {
                    $sub = $cur.OpenSubKey($name, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadSubTree,
                        ([System.Security.AccessControl.RegistryRights]::ReadPermissions -bor [System.Security.AccessControl.RegistryRights]::EnumerateSubKeys -bor [System.Security.AccessControl.RegistryRights]::QueryValues))
                    if (-not $sub) { continue }
                    $sacl = $sub.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Access)
                    if ($sacl.AreAccessRulesProtected) {
                        $subW = $null
                        try {
                            $subW = $cur.OpenSubKey($name, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
                                ([System.Security.AccessControl.RegistryRights]::ReadPermissions -bor [System.Security.AccessControl.RegistryRights]::ChangePermissions))
                            if ($subW) { Set-RegKeySingleAce $subW $sidObj $rights $inh $prop }
                        } catch {
                            if ($subResult) { $subResult.HasError = $true }
                            Log "WARN Reg protected subkey $($cur.Name)\$($name): $($_.Exception.Message)"
                        } finally { if ($subW) { $subW.Dispose() } }
                    }
                    $q.Enqueue($sub)
                } catch {
                    if ($sub) { $sub.Dispose() }
                    if ($subResult) { $subResult.HasError = $true }
                    Log "WARN Reg subkey $($cur.Name)\$($name): $($_.Exception.Message)"
                }
            }
        } catch {
            if ($subResult) { $subResult.HasError = $true }
            Log "WARN Reg enum $($cur.Name): $($_.Exception.Message)"
        }
        if ($cur -ne $rootKey) { $cur.Dispose() }
    }
}
function Set-RegSidAce([string]$regPath, [string]$sid, [string]$access, [string]$scope, [string]$userSid, [string]$view = 'Both', [hashtable]$subResult = $null) {
    $sidObj = New-Object System.Security.Principal.SecurityIdentifier($sid)
    $rights = switch ($access) {
        'Read'      { [System.Security.AccessControl.RegistryRights]::ReadKey }
        'ReadWrite' { [System.Security.AccessControl.RegistryRights]::ReadKey -bor [System.Security.AccessControl.RegistryRights]::WriteKey -bor [System.Security.AccessControl.RegistryRights]::Delete }
        'Full'      { [System.Security.AccessControl.RegistryRights]::FullControl }
        default     { throw "Bad registry access '$access'" }
    }
    $sc = Resolve-RegScopeKey $scope
    $inh  = if ($sc -eq 'FolderOnly') { [System.Security.AccessControl.InheritanceFlags]::None } else { [System.Security.AccessControl.InheritanceFlags]::ContainerInherit }
    $prop = if ($sc -eq 'DirectContents') { [System.Security.AccessControl.PropagationFlags]::NoPropagateInherit } else { [System.Security.AccessControl.PropagationFlags]::None }
    $appliedAny = $false
    foreach ($tgt in (Resolve-RegTargets $regPath $view $userSid)) {
        try {
            $key = Open-RegKeyForAcl $tgt.Path $userSid $tgt.View $true
            try {
                Set-RegKeySingleAce $key $sidObj $rights $inh $prop
                if ($sc -eq 'Recursive') { Apply-RegProtectedSubkeys $key $sidObj $rights $inh $prop $subResult }
                $appliedAny = $true
            } finally { $key.Dispose() }
        } catch {
            if (-not $tgt.Optional) { throw }
        }
    }
    if (-not $appliedAny) { throw "Registry key not found in requested view(s): $regPath" }
}
function Test-SidHasExplicitAce([string]$path, [string]$sid) {
    try {
        foreach ($ace in (Get-Acl -LiteralPath $path).Access) {
            if ($ace.IsInherited) { continue }
            $s = try { $ace.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } catch { '' }
            if ($s -ieq $sid) { return $true }
        }
    } catch {}
    $false
}
function Get-ProtectedSubdirs([string]$root, [bool]$followReparse = $false) {
    $res = New-Object System.Collections.Generic.List[string]
    if (-not $followReparse -and (Test-IsReparsePoint $root)) { return $res }
    $q = New-Object System.Collections.Generic.Queue[string]; $q.Enqueue($root)
    while ($q.Count -gt 0) {
        $cur = $q.Dequeue()
        try {
            foreach ($sub in [IO.Directory]::GetDirectories($cur)) {
                try {
                    if (-not $followReparse -and (Test-IsReparsePoint $sub)) { continue }
                    if ((Get-Acl -LiteralPath $sub).AreAccessRulesProtected) { [void]$res.Add($sub) }
                    $q.Enqueue($sub)
                } catch {}
            }
        } catch {}
    }
    $res
}
function Test-ValidFwAddrSpec([string]$item) {
    if ($item -match '^(\d{1,3}\.){3}\d{1,3}(/\d{1,2}|-(\d{1,3}\.){3}\d{1,3})?$') {
        $ipPart = ($item -split '[-/]')[0]
        $ip = $null; return [Net.IPAddress]::TryParse($ipPart, [ref]$ip)
    }
    if ($item -match '^[0-9A-Fa-f:]+(/\d{1,3}|-[0-9A-Fa-f:]+)?$') {
        $ipPart = ($item -split '[-/]')[0]
        $ip = $null; return [Net.IPAddress]::TryParse($ipPart, [ref]$ip)
    }
    $false
}
function Invoke-Apply($p, [bool]$isDryRun = $false) {
    if (Test-ProfileHasDynamicPaths $p) { throw 'This profile contains unresolved dynamic preset placeholders (*n). Export as a preset and import it before applying ACLs.' }
    $sid = Get-Sid $p
    $uSid = if ($TargetUserSid) { $TargetUserSid } else { [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
    $pfx = if ($isDryRun) { '[DRY-RUN] ' } else { '' }
    $followReparse = [bool]$p.Hard.FollowReparse
    $hadErrors = $false
    Log "${pfx}Container SID: $sid"
# Deduplicate rules (last wins) n diff against previously applied rules
    $dedup = @{}
    foreach ($r in @($p.Rules)) {
        if ($r.PSObject.Properties.Name -contains 'List' -and $r.List -eq 'Deny') { continue }
        $path = Resolve-RulePath $r.Path; if (-not $path) { continue }
        $sc = Resolve-PathScopeKey $r.Scope
        $force = ($r.PSObject.Properties.Name -contains 'Force' -and [bool]$r.Force)
        $dedup[$path] = [pscustomobject]@{ Path = $path; Scope = $sc; Access = $r.Access; Force = $force; Key = "$path|$sc|$($r.Access)" }
    }
    $desired = @($dedup.Values | Sort-Object { $_.Path.Length })
    $oldRules = @($p.Applied.PathRules)
    $oldToRevoke = New-Object System.Collections.Generic.List[object]
    $desiredPaths = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
    foreach ($d in $desired) { [void]$desiredPaths.Add($d.Path) }
    if ($oldRules.Count -gt 0) {
        $keep = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
        foreach ($d in $desired) { if (($oldRules -contains $d.Key) -and (Test-SidHasExplicitAce $d.Path $sid)) { [void]$keep.Add($d.Path) } }
        foreach ($old in @($p.Applied.Paths)) {
            if ($old -and -not $keep.Contains($old)) {
                # Don't /T tree-revoke a removed parent if an active child rule still sits under it
                $stillChild = $false
                foreach ($dp in $desiredPaths) { if (Test-Under $dp $old) { $stillChild = $true; break } }
                [void]$oldToRevoke.Add([pscustomobject]@{ Path = $old; Tree = ((-not $stillChild) -and (Test-NeedTreeRevoke $old $p)) })
            }
        }
    } else {
        foreach ($old in @($p.Applied.Paths)) { if ($old) { [void]$oldToRevoke.Add([pscustomobject]@{ Path = $old; Tree = (Test-NeedTreeRevoke $old $p) }) } }
    }
    $totalSteps = [Math]::Max(1, $oldToRevoke.Count + $desired.Count + @($p.Applied.RegPaths).Count + @($p.RegRules).Count + 2)
    $step = 0
    foreach ($oldObj in $oldToRevoke) {
        $old = $oldObj.Path
        $step++; Set-TaskProgress $step $totalSteps "${pfx}Revoking stale ACL: $old"
        if (Test-Path -LiteralPath $old) {
            if ((Test-SystemPath $old) -and -not (Test-SidHasExplicitAce $old $sid)) { Log "${pfx}SKIP stale revoke (no ACE on system path): $old"; continue }
            if (-not $followReparse -and (Test-IsReparsePoint $old)) { Log "${pfx}SKIP stale revoke (reparse point): $old"; continue }
            if ($isDryRun) { Log "${pfx}Would remove ACEs for *$sid on $old (tree=$($oldObj.Tree))"; continue }
            $icArgs = if ($oldObj.Tree) { @($old, '/remove', "*$sid", '/T', '/C', '/Q', '/L') } else { @($old, '/remove', "*$sid", '/C', '/Q', '/L') }
            $rr = Invoke-Icacls $icArgs
            if ($rr.Code -ne 0) { Log "WARN stale revoke ${old}: $($rr.Out)" }
        }
    }
    $applied = New-Object System.Collections.ArrayList
    $appliedRuleKeys = New-Object System.Collections.ArrayList
    foreach ($d in $desired) {
        $step++; $path = $d.Path; $sc = $d.Scope; $acc = $d.Access
        Set-TaskProgress $step $totalSteps "${pfx}Applying [$sc/$acc]: $path"
        if (-not (Test-Path -LiteralPath $path)) { Log "${pfx}SKIP (does not exist): $path"; continue }
        if (-not $followReparse -and (Test-IsReparsePoint $path)) {
            Log "${pfx}BLOCKED (reparse point / junction skipped for safety): $path"
            if (-not $isDryRun) { $hadErrors = $true }
            continue
        }
        $isDir = Test-Path -LiteralPath $path -PathType Container
        $rights = $script:AllowMap[$acc]
        if (-not $rights) { Log "${pfx}SKIP (bad access '$acc'): $path"; continue }
        if (-not $d.Force -and ($acc -in 'Read', 'ReadExecute') -and (Test-SystemPath $path) -and (Test-AmbientAclReadExec $path ([bool]$p.Hard.Lpac) $acc)) {
            $grpLabel = if ($p.Hard.Lpac) { 'ALL RESTRICTED APPLICATION PACKAGES (S-1-15-2-2)' } else { 'ALL APPLICATION PACKAGES (S-1-15-2-1)' }
            Log "${pfx}SKIP (already readable via $grpLabel; tick Force ACE if a subfolder dropped inheritance): $path"; continue
        }
        if (($oldRules -contains $d.Key) -and (Test-SidHasExplicitAce $path $sid) -and -not ($oldToRevoke | Where-Object { $_.Path -ieq $path })) {
            Log "${pfx}OK   (unchanged): $path"
            [void]$applied.Add($path); [void]$appliedRuleKeys.Add($d.Key)
            if ($sc -eq 'Recursive') { foreach ($subOld in @($p.Applied.Paths)) { if ($subOld -and ($subOld -ne $path) -and (Test-Under $subOld $path) -and -not ($oldToRevoke | Where-Object { $_.Path -ieq $subOld })) { [void]$applied.Add($subOld) } } }
            continue
        }
        $inh = if (-not $isDir) { '' } elseif ($sc -eq 'FolderOnly') { '' } elseif ($sc -eq 'DirectContents') { '(OI)(CI)(NP)' } else { '(OI)(CI)' }
        $perm = if ($rights -match '^\w+$') { "$inh$rights" } else { "$inh($rights)" }
        if ($isDryRun) { Log "${pfx}Would run: icacls `"$path`" /grant:r *${sid}:$perm /C /Q /L"; continue }
        $res = Invoke-Icacls @($path, '/grant:r', "*${sid}:$perm", '/C', '/Q', '/L')
        if ($res.Code -eq 0) {
            Log "OK   [$sc/$acc]: $path"; [void]$applied.Add($path); [void]$appliedRuleKeys.Add($d.Key)
            if ($isDir -and $sc -eq 'Recursive' -and $path.TrimEnd('\').Length -gt 2 -and (-not (Test-SystemPath $path) -or $d.Force)) {
                foreach ($ps in (Get-ProtectedSubdirs $path $followReparse)) {
                    if ((Invoke-Icacls @($ps, '/grant:r', "*${sid}:$perm", '/C', '/Q', '/L')).Code -eq 0) { [void]$applied.Add($ps) }
                    else { $hadErrors = $true; Log "FAIL Protected subdir [$acc]: $ps" }
                }
                if ($p.ExePath) {
                    $exePath = Resolve-RulePath $p.ExePath
                    if ($exePath -and (Test-Under $exePath $path) -and (Test-Path -LiteralPath $exePath -PathType Leaf) -and ($followReparse -or -not (Test-IsReparsePoint $exePath))) {
                        try { if ((Get-Acl -LiteralPath $exePath).AreAccessRulesProtected) { if ((Invoke-Icacls @($exePath, '/grant:r', "*${sid}:$rights", '/C', '/Q', '/L')).Code -eq 0) { [void]$applied.Add($exePath) } } } catch {}
                    }
                }
            }
        } else { $hadErrors = $true; Log "FAIL [$sc/$acc]: $path -> $($res.Out)" }
    }
    if (-not $isDryRun) {
        $p.Applied.Paths = @($applied | Select-Object -Unique)
        $p.Applied.PathRules = @($appliedRuleKeys | Select-Object -Unique)
    }

    foreach ($oldReg in @($p.Applied.RegPaths)) {
        $step++; Set-TaskProgress $step $totalSteps "${pfx}Revoking registry ACL: $oldReg"
        if ($oldReg) {
            if ($isDryRun) { Log "${pfx}Would purge registry ACE for $sid on $oldReg"; continue }
            try { Remove-RegSidAce $oldReg $sid $uSid 'Both' } catch { Log "WARN Reg revoke ${oldReg}: $($_.Exception.Message)" }
        }
    }
    $appliedReg = New-Object System.Collections.ArrayList
    foreach ($rr in @($p.RegRules)) {
        $step++; $rp = Resolve-RegPath $rr.Path; if (-not $rp) { continue }
        $rv = if ($rr.PSObject.Properties.Name -contains 'View' -and $rr.View) { [string]$rr.View } else { 'Both' }
        $rsc = Resolve-RegScopeKey $rr.Scope
        Set-TaskProgress $step $totalSteps "${pfx}Applying registry [$rsc/$($rr.Access)/$rv]: $rp"
        if ($isDryRun) { Log "${pfx}Would set registry ACE [$rsc/$($rr.Access)/$rv] for $sid on $rp"; continue }
        try {
            $regState = @{ HasError = $false }
            Set-RegSidAce $rp $sid $rr.Access $rsc $uSid $rv $regState
            [void]$appliedReg.Add($rp)
            if ($regState.HasError) { $hadErrors = $true; Log "WARN Reg  [$rsc/$($rr.Access)/$rv]: $rp (root applied, one or more subkeys failed)" }
            else { Log "OK   Reg  [$rsc/$($rr.Access)/$rv]: $rp" }
        } catch {
            $hadErrors = $true
            Log "FAIL Reg  [$rsc/$($rr.Access)/$rv]: $rp -> $($_.Exception.Message)"
        }
    }
    if (-not $isDryRun) { $p.Applied.RegPaths = @($appliedReg | Select-Object -Unique) }

    $step++; Set-TaskProgress $step $totalSteps "${pfx}Updating Windows Firewall & loopback..."
    # Windows Firewall, MpsSvc enforcement check & loopback
    $hasNetCaps = Test-ProfileHasNetCap $p
    # Block all traffic even with 0 net caps so child processes can't match WSH ALE_APP_ID permit rules
    $effBlockAll = [bool]$p.Net.FwBlockAll -or ((-not $hasNetCaps) -and [bool]$p.Net.AutoOfflineBlock)
    if ($isDryRun) {
        if ($effBlockAll) { Log "${pfx}Firewall: would add Inbound+Outbound Block rules for Package $sid (AutoOfflineBlock=$([bool]$p.Net.AutoOfflineBlock))." }
        if ($p.Net.Client -and -not $p.Net.Private -and $p.Net.BlockLanWhenClientOnly -and -not $effBlockAll) { Log "${pfx}Firewall: would block non-internet/LAN/LocalSubnet/DefaultGateway outbound for Package $sid (AllowCgnat=$([bool]$p.Net.AllowCgnat), AllowMulticast=$([bool]$p.Net.AllowMulticast))." }
        if ($p.Net.Server -and $p.Net.ServerAllowInbound -and -not $effBlockAll) { Log "${pfx}Firewall: would allow inbound for Package $sid (ports='$($p.Net.ServerInboundPorts)')." }
        $list = @($p.Net.FwBlockList -split '[,;\s]+' | Where-Object { $_ })
        if ($list.Count) { Log "${pfx}Firewall: would block outbound to $($list -join ', ')" }
        if ($p.Net.Loopback) { Log "${pfx}Loopback: would add CheckNetIsolation exemption for $sid." }
        if ($p.Dev -and $p.Dev.UsbHidMode -eq 'Specific') {
            foreach ($dp in @($p.Dev.UsbHidDevices)) { Log "${pfx}Device ACL: would grant $sid on $dp" }
        }
        Set-TaskProgress $totalSteps $totalSteps 'Dry-run finished.'
        Log 'Dry-run finished (no changes written).'
        return
    }

    Remove-Firewall $p
    $grp = Get-FirewallGroup $p; $made = $false
    $needsBlocking = $effBlockAll -or ($p.Net.Client -and -not $p.Net.Private -and $p.Net.BlockLanWhenClientOnly)
    if ($effBlockAll) {
        try {
            foreach ($d in 'Outbound', 'Inbound') { New-NetFirewallRule -DisplayName "ACM $($p.Name) block all $d" -Group $grp -Direction $d -Action Block -Enabled True -Package $sid -ErrorAction Stop | Out-Null }
            $made = $true
            if ($p.Net.FwBlockAll) { Log 'Firewall: blocking all traffic for this container.' }
            else { Log 'Firewall: AutoOfflineBlock active (0 network capabilities -> blocking all inbound/outbound for container SID across child processes).' }
            if ($hasNetCaps) { Log 'WARNING: FwBlockAll is set while a network capability is ticked; DNS queries through Dnscache still bypass -Package firewall rules!' }
        } catch { $hadErrors = $true; Log "FAIL Firewall block-all rule error: $($_.Exception.Message)" }
    } else {
        if ($p.Net.Client -and -not $p.Net.Private -and $p.Net.BlockLanWhenClientOnly) {
            try {
                $lanRanges = New-Object System.Collections.Generic.List[string]
                foreach ($cidr in @('10.0.0.0/8', '169.254.0.0/16', '172.16.0.0/12', '192.0.0.0/24', '192.0.2.0/24', '192.168.0.0/16', '198.18.0.0/15', '198.51.100.0/24', '203.0.113.0/24', '100::/64', '2001:db8::/32', 'fc00::/7', 'fe80::/10')) {
                    [void]$lanRanges.Add($cidr)
                }
                if (-not $p.Net.AllowCgnat) { [void]$lanRanges.Add('100.64.0.0/10') }
                if (-not $p.Net.AllowMulticast) { [void]$lanRanges.Add('224.0.0.0/4') }
                New-NetFirewallRule -DisplayName "ACM $($p.Name) block private LAN" -Group $grp -Direction Outbound -Action Block -Enabled True -Package $sid -RemoteAddress @($lanRanges) -ErrorAction Stop | Out-Null
                foreach ($kw in @('LocalSubnet', 'DefaultGateway')) {
                    New-NetFirewallRule -DisplayName "ACM $($p.Name) block $kw" -Group $grp -Direction Outbound -Action Block -Enabled True -Package $sid -RemoteAddress $kw -ErrorAction Stop | Out-Null
                }
                $made = $true; Log "Firewall: blocking non-internet/LAN/LocalSubnet/DefaultGateway outbound for Internet-only mode (AllowCgnat=$([bool]$p.Net.AllowCgnat), AllowMulticast=$([bool]$p.Net.AllowMulticast))."
            } catch { $hadErrors = $true; Log "FAIL Firewall private-LAN rule error: $($_.Exception.Message)" }
        }
        if ($p.Net.Server -and $p.Net.ServerAllowInbound) {
            $ports = @($p.Net.ServerInboundPorts -split '[,;\s]+' | Where-Object { $_ })
            $validPorts = New-Object System.Collections.Generic.List[string]
            foreach ($pt in $ports) {
                if ($pt -match '^(\d{1,5})(?:-(\d{1,5}))?$') {
                    $p1 = [int]$Matches[1]; $p2 = if ($Matches[2]) { [int]$Matches[2] } else { $p1 }
                    if ($p1 -ge 1 -and $p2 -le 65535 -and $p1 -le $p2) { [void]$validPorts.Add($pt); continue }
                }
                $hadErrors = $true; Log "FAIL Firewall invalid TCP port or range: '$pt'"
            }
            if ($ports.Count -eq 0) {
                $hadErrors = $true
                Log 'FAIL Firewall: ServerAllowInbound requires explicit TCP port(s) in ServerInboundPorts (refusing wildcard allow across all ports/protocols).'
            } elseif ($validPorts.Count -eq $ports.Count) {
                try {
                    New-NetFirewallRule -DisplayName "ACM $($p.Name) allow inbound" -Group $grp -Direction Inbound -Action Allow -Enabled True -Package $sid -Protocol TCP -LocalPort @($validPorts) -ErrorAction Stop | Out-Null
                    $made = $true; Log "Firewall: allowing inbound to container SID on TCP ports $($validPorts -join ',')."
                } catch { $hadErrors = $true; Log "FAIL Firewall inbound rule error: $($_.Exception.Message)" }
            }
        }
    }
    $rawList = @($p.Net.FwBlockList -split '[,;\s]+' | Where-Object { $_ })
    $validAddrs = New-Object System.Collections.Generic.List[string]
    foreach ($item in $rawList) {
        if (Test-ValidFwAddrSpec $item) { [void]$validAddrs.Add($item) }
        else { $hadErrors = $true; Log "FAIL Firewall block list invalid IP/CIDR/range (use IPs, not hostnames): '$item'" }
    }
    if ($validAddrs.Count) {
        $needsBlocking = $true
        try {
            New-NetFirewallRule -DisplayName "ACM $($p.Name) block list" -Group $grp -Direction Outbound -Action Block -Enabled True -Package $sid -RemoteAddress @($validAddrs) -ErrorAction Stop | Out-Null
            $made = $true; Log "Firewall: blocking outbound to $($validAddrs -join ', ')"
        } catch { $hadErrors = $true; Log "FAIL Firewall block-list rule error: $($_.Exception.Message)" }
    }
    if ($needsBlocking) {
        # Package firewall rules silently do nothing if MpsSvc is stopped or GPO disables AllowLocalFirewallRules
        $mps = Get-Service -Name 'MpsSvc' -ErrorAction SilentlyContinue
        if (-not $mps -or $mps.Status -ne 'Running') {
            $hadErrors = $true
            Log 'FAIL Firewall enforcement: Windows Defender Firewall service (MpsSvc) is NOT running; -Package rules will not be enforced!'
        } else {
            try {
                $activeCats = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue | ForEach-Object {
                    if ($_.NetworkCategory -eq 'DomainAuthenticated') { 'Domain' } else { [string]$_.NetworkCategory }
                } | Select-Object -Unique)
                foreach ($fp in @(Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction Stop)) {
                    $isActive = ($activeCats.Count -eq 0) -or ($activeCats -contains [string]$fp.Name)
                    $tag = if ($isActive) { 'FAIL' } else { 'WARN' }
                    if ([string]$fp.Enabled -ne 'True') {
                        if ($isActive) { $hadErrors = $true }
                        Log "$tag Firewall enforcement: profile '$($fp.Name)' is DISABLED; -Package rules will not apply on $($fp.Name) networks!"
                    }
                    if ([string]$fp.AllowLocalFirewallRules -eq 'False') {
                        if ($isActive) { $hadErrors = $true }
                        Log "$tag Firewall enforcement: profile '$($fp.Name)' has AllowLocalFirewallRules=False (GPO/MDM blocks local rules)!"
                    }
                }
            } catch { $hadErrors = $true; Log "FAIL Firewall profile check error: $($_.Exception.Message)" }
        }
    }
    $p.Applied.Firewall = $made

    if ($p.Net.Loopback) {
        $r = Invoke-Native (Resolve-SystemExe 'CheckNetIsolation.exe') @('LoopbackExempt', '-a', "-p=$sid")
        if ($r.Code -eq 0) {
            Log "Loopback exemption added (all localhost ports open for $sid). Weakens isolation."
            $p.Applied.Loopback = $true
        } else {
            $hadErrors = $true; $p.Applied.Loopback = $false
            Log "FAIL Loopback exemption error (exit $($r.Code)): $($r.Out)"
        }
    } elseif ($p.Applied.Loopback) {
        Remove-Loopback $p $sid; $p.Applied.Loopback = $false; Log 'Loopback exemption removed.'
    }
    $desiredDevs = if ($p.Dev -and $p.Dev.UsbHidMode -eq 'Specific') { @($p.Dev.UsbHidDevices | Select-Object -Unique) } else { @() }
    foreach ($oldDev in @($p.Applied.Devices)) {
        if ($oldDev -and ($desiredDevs -notcontains $oldDev)) {
            try { [ACM.Native]::SetDeviceInterfaceSidAccess($oldDev, $sid, $false); Log "Revoked stale device ACL: $oldDev" }
            catch { Log "WARN stale device revoke ${oldDev}: $($_.Exception.Message)" }
        }
    }
    $appliedDevs = New-Object System.Collections.ArrayList
    foreach ($devPath in $desiredDevs) {
        try {
            [ACM.Native]::SetDeviceInterfaceSidAccess($devPath, $sid, $true)
            [void]$appliedDevs.Add($devPath)
            Log "OK   Device ACL: $devPath"
        } catch {
            $hadErrors = $true
            Log "FAIL Device ACL: $devPath -> $($_.Exception.Message)"
        }
    }
    $p.Applied.Devices = @($appliedDevs | Select-Object -Unique)
    Set-TaskProgress $totalSteps $totalSteps $(if ($hadErrors) { 'Apply finished WITH ERRORS.' } else { 'Apply finished.' })
    Log $(if ($hadErrors) { 'Apply finished WITH ERRORS.' } else { 'Apply finished.' })
    if ($hadErrors) { throw 'Apply completed with one or more errors (see log). Partial successes were recorded for safe Revoke.' }
}
function Test-NeedTreeRevoke([string]$path, $p) {
    if (Test-Path -LiteralPath $path -PathType Leaf) { return $false }
    $pathRules = @($p.Applied.PathRules)
    if ($pathRules.Count -gt 0) {
        $matched = @()
        foreach ($rk in $pathRules) {
            # Support both legacy 4-part (Allow|Path|Scope|Access) and current 3-part (Path|Scope|Access) keys
            $parts = $rk -split '\|', 4
            if ($parts.Count -ge 4 -and $parts[0] -in 'Allow', 'Deny' -and $parts[1] -ieq $path) { $matched += $parts[2] }
            elseif ($parts.Count -ge 3 -and $parts[0] -ieq $path) { $matched += $parts[1] }
        }
        if ($matched.Count -gt 0) { return ($matched -contains 'Recursive') }
        # Never tree-revoke a bare drive root (e.g. "C:\") when rule metadata is missing
        return ($path.TrimEnd('\').Length -gt 2)
    }
    $ruleMatched = @()
    foreach ($r in @($p.Rules)) {
        if ((Resolve-RulePath $r.Path) -ieq $path) { $ruleMatched += (Resolve-PathScopeKey $r.Scope) }
    }
    if ($ruleMatched.Count -gt 0) { return ($ruleMatched -contains 'Recursive') }
    ($path.TrimEnd('\').Length -gt 2)
}
function Invoke-Revoke($p) {
    $sid = Get-Sid $p.Name
    $uSid = if ($TargetUserSid) { $TargetUserSid } else { [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
    $paths = @($p.Applied.Paths); $regs = @($p.Applied.RegPaths)
    $tot = [Math]::Max(1, $paths.Count + $regs.Count + 1); $step = 0
    $hadErrors = $false
    foreach ($old in $paths) {
        $step++; Set-TaskProgress $step $tot "Revoking path ACL: $old"
        if ($old -and (Test-Path -LiteralPath $old)) {
            if ((Test-SystemPath $old) -and -not (Test-SidHasExplicitAce $old $sid)) { Log "SKIP Revoke (no ACE on system path): $old"; continue }
            if (Test-IsReparsePoint $old) { Log "SKIP Revoke (reparse point): $old"; continue }
            $icArgs = if (Test-NeedTreeRevoke $old $p) { @($old, '/remove', "*$sid", '/T', '/C', '/Q', '/L') } else { @($old, '/remove', "*$sid", '/C', '/Q', '/L') }
            $r = Invoke-Icacls $icArgs
            if ($r.Code -ne 0) { $hadErrors = $true; Log "WARN Revoke Path $old (exit $($r.Code)): $($r.Out)" }
            else { Log "Revoked Path: $old" }
        }
    }
    foreach ($oldReg in $regs) {
        $step++; Set-TaskProgress $step $tot "Revoking registry ACL: $oldReg"
        if ($oldReg) {
            try { Remove-RegSidAce $oldReg $sid $uSid 'Both'; Log "Revoked Reg: $oldReg" }
            catch { $hadErrors = $true; Log "WARN Revoke Reg ${oldReg}: $($_.Exception.Message)" }
        }
    }
    foreach ($oldDev in @($p.Applied.Devices)) {
        if ($oldDev) {
            try { [ACM.Native]::SetDeviceInterfaceSidAccess($oldDev, $sid, $false); Log "Revoked Device ACL: $oldDev" }
            catch { $hadErrors = $true; Log "WARN Revoke Device ${oldDev}: $($_.Exception.Message)" }
        }
    }
    $step++; Set-TaskProgress $tot $tot 'Removing firewall & loopback rules...'
    Remove-Firewall $p; Remove-Loopback $p $sid
    $p.Applied.Paths = @(); $p.Applied.PathRules = @(); $p.Applied.RegPaths = @(); $p.Applied.Devices = @(); $p.Applied.Loopback = $false; $p.Applied.Firewall = $false
    Log $(if ($hadErrors) { 'Revoke finished with warnings.' } else { 'Revoke finished.' })
}
function Invoke-Mode([string]$mode, $p) {
    try {
        switch ($mode) { 'Apply' { Invoke-Apply $p ([bool]$DryRun) } 'Revoke' { Invoke-Revoke $p } }
    } finally {
        if (-not $DryRun) { Save-Config }
    }
}
function Test-Admin { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
function Set-UiBusy([bool]$busy) {
    $script:Busy = $busy
    if ($script:CardsFlow) { $script:CardsFlow.Enabled = -not $busy }
    foreach ($b in $script:ProfBtns) { $b.Enabled = -not $busy }
    if ($script:BtnImportPreset) { $script:BtnImportPreset.Enabled = -not $busy }
    Enable-UI (-not $busy -and $null -ne $script:Cur)
}
function Remove-LocalContainerProfile([string]$name) {
    $cn = Get-ContainerName $name
    $sid = Get-Sid $name
    $pids = @([ACM.Native]::GetContainerPids($sid))
    if ($pids.Count -gt 0) { throw "Close or terminate active processes in '$name' first ($($pids.Count) running)." }
    $pkgFolder = try {
        $gf = ([ACM.Native]::GetFolder($sid)).TrimEnd('\')
        if ($gf -match '\\AC$') { Split-Path -Parent $gf } else { $gf }
    } catch { Join-Path $env:LOCALAPPDATA "Packages\$cn" }
    [ACM.Native]::DeleteProfileChecked($cn)
    if ($pkgFolder -and (Split-Path -Leaf $pkgFolder) -ieq $cn -and (Test-Path -LiteralPath $pkgFolder)) {
        Remove-Item -LiteralPath $pkgFolder -Recurse -Force -ErrorAction SilentlyContinue
    }
}
function Complete-DeleteProfile([string]$name) {
    $curUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if (-not $TargetUserSid -or ($TargetUserSid -ieq $curUserSid)) {
        Remove-LocalContainerProfile $name
    }
    $old = Find-Profile $name; if ($old) { $script:Profiles.Remove($old) }
    Save-Config; Log "Deleted profile '$name'."
}