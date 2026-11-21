# Use ProgramW6432 so 32-bit ps hosts on 64-bit Windows still resolve
# to the native program files directory rather than program files x86.
function Get-ProtectedAppDir {
    $pf = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
    Join-Path $pf 'AppContainerManager'
}
function Get-DefaultConfigPath { Join-Path (Get-ProtectedAppDir) 'profiles.json' }
# ===Config model
$script:Profiles = New-Object System.Collections.ArrayList
$script:LogBox = $null; $script:ProgBar = $null; $script:ProgLbl = $null; $script:Cur = $null; $script:Loading = $false; $script:Busy = $false; $script:AsyncState = $null; $script:SavedSnapshot = ''; $script:ForceClose = $false; $script:IsLegacyConfig = $false; $script:LaunchWatchers = New-Object System.Collections.ArrayList; $script:PresetDescCache = @{}

# Canonical profile schema and default values
# NOTE: Merge-Obj inspects these exact property names and runtime types as the
# deserialization blueprint when loading profiles.json or .acmpreset.json files
function New-ProfileObject([string]$Name) {
    [pscustomobject]@{
        Name = $Name; ContainerId = ''; Description = ''; ExePath = ''; Arguments = ''; WorkDir = ''; ExtraCaps = ''
        Net  = [pscustomobject]@{ Client = $false; Server = $false; Private = $false; Loopback = $false; FwBlockAll = $false; FwBlockList = ''
            AutoOfflineBlock = $true; BlockLanWhenClientOnly = $true; AllowCgnat = $false; AllowMulticast = $false; ServerAllowInbound = $false; ServerInboundPorts = '' }
        Hard = [pscustomobject]@{ Lpac = $true; NoChild = $false; Win32k = $false; NoDynCode = $false; BlockNonMs = $false
            NoExtPoints = $true; StrictHandles = $true; ImgNoRemote = $true; ImgNoLowLabel = $true; ImgPreferSys32 = $false
            KillOnClose = $true; WaitTree = $true; Ephemeral = $false; FollowReparse = $false; RedirectProfile = $true
            NoClipboard = $true; NoDesktopSys = $true; IsolateDesktop = $true; JoinFirstDesktop = $false; ShowConsole = $false; RegRead = $false
            DepSehop32 = $true; HeapTerminate = $true; BottomUpAslr = $true; HighEntropyAslr = $true; Cfg = $true
            ForceRelocate = $false; NoFonts = $false; NoFsctl = $false; StrictCfg = $false
            RestrictIbp = $false; Ssbd = $false; CetShadowStack = $false }
        EnvMode = 'Allowlist'; EnvAllow = ''; EnvCustom = ''; CustomDesktop = ''
        Dev      = [pscustomobject]@{ Mic = $false; Location = $false; Webcam = $false; UsbHidMode = 'Off'; UsbHidDevices = @() }
        Limits   = [pscustomobject]@{ MaxProcesses = 0; ProcessMemMb = 0; JobMemMb = 0; CpuRatePct = 0 }
        Rules    = @()
        RegRules = @()
        Applied  = [pscustomobject]@{ Paths = @(); PathRules = @(); RegPaths = @(); Devices = @(); Loopback = $false; Firewall = $false }
    }
}
# Recursively merges untrusted JSON ($src) into a typed template ($def) in place
# - Unknown JSON properties are ignored for forward/backward compatibility
# - Known properties are type-checked against $def
function Merge-Obj($def, $src) {
    if ($null -eq $src) { return $def }
    if ($src -isnot [pscustomobject]) { throw 'Invalid JSON object structure.' }
    $names = @($src.PSObject.Properties.Name)
    foreach ($p in $def.PSObject.Properties) {
        if ($names -notcontains $p.Name) { continue }
        $v = $src.($p.Name)
        if ($p.Value -is [pscustomobject]) {
            if ($null -eq $v) { continue }
            $p.Value = Merge-Obj $p.Value $v
        } elseif ($p.Value -is [array]) {
            if ($null -eq $v) { $p.Value = @() }
            elseif ($v -is [string] -or $v -is [ValueType] -or $v -is [pscustomobject]) { throw "Invalid array type for property '$($p.Name)'." }
            else { $p.Value = @($v) }
        } elseif ($p.Value -is [bool]) {
            if ($v -isnot [bool]) { throw "Invalid boolean type for property '$($p.Name)'." }
            $p.Value = [bool]$v
        } elseif ($p.Value -is [int] -or $p.Value -is [long]) {
            if ($null -eq $v -or $v -is [bool] -or $v -is [string] -or -not ($v -is [ValueType])) { throw "Invalid integer type for property '$($p.Name)'." }
            $p.Value = [int]$v
        } else {
            if ($null -eq $v) { $p.Value = '' }
            elseif ($v -isnot [string]) { throw "Invalid string type for property '$($p.Name)'." }
            else { $p.Value = [string]$v }
        }
    }
    $def
}
# Walks $path and every ancestor directory up to the drive root to reject NTFS
# junctions/symlinks (reparse points) that could redirect privileged file I/O
# Non-existent leaf/parent segments are skipped so Save-Config can validate paths
# before creating directories or files
function Test-PathNoReparse([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) { return $false }
    $cur = [IO.Path]::GetFullPath($path)
    while ($cur) {
        if (Test-Path -LiteralPath $cur) {
            try {
                if ((([IO.File]::GetAttributes($cur)) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
            } catch { return $false }
        }
        $parent = Split-Path -Parent $cur
        if (-not $parent -or $parent -eq $cur) { break }
        $cur = $parent
    }
    $true
}
# elevation boundary guard (called by TrySandboxed.ps1 -Elevated)
# ensures an unprivileged caller cannot point an elevated process at an arbitrary JSON path.
function Test-ProtectedConfigPath([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) { return $false }
    $full = [IO.Path]::GetFullPath($path)
    $allowedDir = [IO.Path]::GetFullPath((Get-ProtectedAppDir)).TrimEnd('\')
    $parentDir = (Split-Path -Parent $full).TrimEnd('\')
    if ($parentDir -ine $allowedDir) { return $false }
    if (-not $full.EndsWith('.json', [StringComparison]::OrdinalIgnoreCase)) { return $false }
    Test-PathNoReparse $full
}
# Verifies that the main script, src\, and all module scripts reside under OS-protected
# roots (Program Files / Windows) with no reparse points preventing non-admin
# tampering prior to UAC elevation
function Test-ProtectedScriptLocation {
    $roots = @($env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:SystemRoot) |
        Where-Object { $_ } | ForEach-Object { [IO.Path]::GetFullPath($_) } | Select-Object -Unique
    $toCheck = New-Object System.Collections.Generic.List[string]
    [void]$toCheck.Add([IO.Path]::GetFullPath($script:MainScriptPath))
    $srcDir = Join-Path $script:AppRoot 'src'
    if (-not (Test-Path -LiteralPath $srcDir -PathType Container)) { return $false }
    [void]$toCheck.Add([IO.Path]::GetFullPath($srcDir))
    foreach ($f in (Get-ChildItem -LiteralPath $srcDir -File -Force -ErrorAction SilentlyContinue)) {
        [void]$toCheck.Add([IO.Path]::GetFullPath($f.FullName))
    }
    foreach ($item in $toCheck) {
        if (-not (Test-PathNoReparse $item)) { return $false }
        $underProtected = $false
        foreach ($rt in $roots) {
            if (Test-Under $item $rt) { $underProtected = $true; break }
        }
        if (-not $underProtected) { return $false }
    }
    $true
}
function Get-ConfigSnapshotJson {
    ConvertTo-Json -InputObject ([pscustomobject]@{ Version = 1; Profiles = @($script:Profiles) }) -Depth 8 -Compress
}
# Snapshot helpers for unsaved changes prompts
# Doesn't matter much with new installs: %APPDATA% configs intentionally leave SavedSnapshot 
# empty so Test-ConfigDirty stays $true until an admin migrates them to Program Files
# Uses case-sensitive -cne so casing changes in paths/descriptions register as edits
function Sync-SavedSnapshot {
    if ($script:IsLegacyConfig) { $script:SavedSnapshot = ''; return }
    $script:SavedSnapshot = Get-ConfigSnapshotJson
}
function Test-ConfigDirty {
    if ($script:IsLegacyConfig) { return $true }
    (Get-ConfigSnapshotJson) -cne $script:SavedSnapshot
}
# Parses and validates config JSON (profiles.json or staging JSON) into
# normalized profile objects. Enforces size caps, uniqueness, path/reg/device safety, other boring security stuff.
function ConvertTo-NormalizedProfiles([string]$raw) {
    $listOut = New-Object System.Collections.ArrayList
    if (-not $raw -or -not $raw.Trim()) { return ,$listOut }
    # 4 MB DoS limit against oversized/malformed config files
    # no way somebody gets their config that big during normal usage (please don't)
    if ($raw.Length -gt 4194304) { throw 'Config exceeds 4 MB size limit.' }
    $j = $raw | ConvertFrom-Json
    if ($null -eq $j -or $j -isnot [pscustomobject] -or -not ($j.PSObject.Properties.Name -contains 'Profiles')) { throw 'Invalid config format: missing Profiles.' }
    if ($j.PSObject.Properties.Name -contains 'Version' -and [int]$j.Version -ne 1) { throw "Unsupported config version: $($j.Version)" }
    $seenNames = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
    $seenCn = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
    if ($null -ne $j.Profiles) {
    foreach ($pj in @($j.Profiles)) {
        if ($null -eq $pj) { continue }
        if ($pj -isnot [pscustomobject]) { throw 'Invalid profile entry in config.' }
        if (-not ($pj.PSObject.Properties.Name -contains 'Name') -or $pj.Name -isnot [string]) { throw 'Missing or invalid profile Name in config.' }
        $pName = Assert-ValidProfileName $pj.Name
        if (-not $seenNames.Add($pName)) { throw "Duplicate profile name in config: '$pName'" }
        $obj = Merge-Obj (New-ProfileObject $pName) $pj
        $obj.Name = $pName
        # Validate ContainerId format; non-ASCII profile names require an explicit ASCII
        # ContainerId because AppContainer monikers/firewall groups expect ASCII tokens.
        if ($obj.ContainerId) {
            if ($obj.ContainerId -notmatch '^acm\.[A-Za-z0-9._-]{1,56}$') { throw "Invalid ContainerId in config for profile '$pName'." }
        } elseif ($pName -cmatch '[^A-Za-z0-9 ._-]') {
            throw "Profile '$pName' with non-ASCII characters requires an explicit ASCII ContainerId."
        }
        $cn = Get-ContainerName $obj
        if (-not $seenCn.Add($cn)) { throw "Container ID collision in config for profile '$pName' ($cn)." }
        Assert-NoControlChars $obj.Description 'Description' $true 2048
        if ($obj.ExePath) { $obj.ExePath = Assert-ValidConcreteFsPath $obj.ExePath 'ExePath' }
        if ($obj.WorkDir) { $obj.WorkDir = Assert-ValidConcreteFsPath $obj.WorkDir 'WorkDir' }
        Assert-NoControlChars $obj.Arguments 'Arguments' $false 4096
        Assert-ValidProfileCommonFields $obj
        $cleanRules = @()
        foreach ($r in @($obj.Rules)) {
            if ($r -isnot [pscustomobject]) { throw "Invalid path rule entry in profile '$pName'." }
            # Backward compatibility: AppContainer is whitelist-only; silently drop legacy Deny rules.
            # there was a deny option appcontainer doesn't actually support in quite a few early versions
            # replaced with this folder only\direct contents\recursive choise
            if ($r.PSObject.Properties.Name -contains 'List' -and $r.List -eq 'Deny') { continue }
            if ([string]::IsNullOrWhiteSpace([string]$r.Path)) { continue }
            $rp = Assert-ValidConcreteFsPath ([string]$r.Path) 'Rule.Path'
            $sc = if ($r.PSObject.Properties.Name -contains 'Scope') { [string]$r.Scope } else { 'Recursive' }
            $acc = if ($r.Access -in 'Read', 'ReadWrite', 'ReadExecute', 'Full') { [string]$r.Access } else { throw "Invalid rule access '$($r.Access)' in profile '$pName'." }
            $force = ($r.PSObject.Properties.Name -contains 'Force' -and [bool]$r.Force)
            $cleanRules += [pscustomobject]@{ Path = $rp; Scope = (Resolve-PathScopeKey $sc); Access = $acc; Force = $force }
        }
        $obj.Rules = @($cleanRules)
        $cleanReg = @()
        foreach ($rr in @($obj.RegRules)) {
            if ($rr -isnot [pscustomobject]) { throw "Invalid registry rule entry in profile '$pName'." }
            if ([string]::IsNullOrWhiteSpace([string]$rr.Path)) { continue }
            $regP = Assert-ValidRegistryRulePath ([string]$rr.Path)
            $rsc = if ($rr.PSObject.Properties.Name -contains 'Scope') { [string]$rr.Scope } else { 'Recursive' }
            $racc = if ($rr.Access -in 'Read', 'ReadWrite', 'Full') { [string]$rr.Access } else { throw "Invalid registry access '$($rr.Access)' in profile '$pName'." }
            $rv = if ($rr.PSObject.Properties.Name -contains 'View' -and $rr.View -in 'Both', '64', '32') { [string]$rr.View } else { 'Both' }
            $cleanReg += [pscustomobject]@{ Path = $regP; Scope = (Resolve-RegScopeKey $rsc); Access = $racc; View = $rv }
        }
        $obj.RegRules = @($cleanReg)
        $cleanAppPaths = @()
        foreach ($ap in @($obj.Applied.Paths)) { if (-not [string]::IsNullOrWhiteSpace([string]$ap)) { $cleanAppPaths += (Assert-ValidConcreteFsPath ([string]$ap) 'Applied.Paths') } }
        $obj.Applied.Paths = @($cleanAppPaths)
        $cleanAppReg = @()
        foreach ($ar in @($obj.Applied.RegPaths)) { if (-not [string]::IsNullOrWhiteSpace([string]$ar)) { $cleanAppReg += (Assert-ValidRegistryRulePath ([string]$ar)) } }
        $obj.Applied.RegPaths = @($cleanAppReg)
        # PathRules holds serialized "Path|Scope|Access" keys (not raw FS paths)
        # so validate control chars/length rather than concrete path syntax
        $cleanAppKeys = @()
        foreach ($ak in @($obj.Applied.PathRules)) {
            if ($ak) { Assert-NoControlChars ([string]$ak) 'Applied.PathRules' $false 600; $cleanAppKeys += [string]$ak }
        }
        $obj.Applied.PathRules = @($cleanAppKeys)
        if ($obj.Dev.UsbHidMode -notin 'Off', 'All', 'Specific') { throw "Invalid Dev.UsbHidMode '$($obj.Dev.UsbHidMode)' in profile '$pName'." }
        $cleanDevs = @()
        foreach ($dp in @($obj.Dev.UsbHidDevices)) { if (-not [string]::IsNullOrWhiteSpace([string]$dp)) { $cleanDevs += (Assert-ValidDeviceInterfacePath ([string]$dp)) } }
        $obj.Dev.UsbHidDevices = @($cleanDevs | Select-Object -Unique)
        $cleanAppDevs = @()
        foreach ($adp in @($obj.Applied.Devices)) { if (-not [string]::IsNullOrWhiteSpace([string]$adp)) { $cleanAppDevs += (Assert-ValidDeviceInterfacePath ([string]$adp)) } }
        $obj.Applied.Devices = @($cleanAppDevs | Select-Object -Unique)
        [void]$listOut.Add($obj)
    }
    }
    ,$listOut
}
function Load-Config([bool]$allowLegacyImport = $false) {
    $script:Profiles = New-Object System.Collections.ArrayList
    $script:IsLegacyConfig = $false
    if (Test-Path -LiteralPath $ConfigPath) {
        if (-not (Test-PathNoReparse $ConfigPath)) { throw "Security error: config path contains a reparse point: $ConfigPath" }
        $fi = [IO.FileInfo]::new($ConfigPath)
        if ($fi.Length -gt 4194304) { throw 'Config exceeds 4 MB size limit.' }
        $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
        $script:Profiles = ConvertTo-NormalizedProfiles $raw
        $script:SavedSnapshot = Get-ConfigSnapshotJson
    } else {
        $script:SavedSnapshot = ''
        # $allowLegacyImport is only enabled on GUI startup (05-GuiController.ps1);
        # loads %APPDATA% config read-only/unsaved until an admin explicitly saves to Program Files.
        # doesn't matter much on fresh installs (read earlier comments)
        if ($allowLegacyImport) {
            $legacy = Join-Path $env:APPDATA 'AppContainerManager\profiles.json'
            if ((Test-Path -LiteralPath $legacy -PathType Leaf) -and (Test-PathNoReparse $legacy)) {
                $lfi = [IO.FileInfo]::new($legacy)
                if ($lfi.Length -gt 4194304) { throw 'Legacy config exceeds 4 MB size limit.' }
                $raw = Get-Content -LiteralPath $legacy -Raw -Encoding UTF8
                $script:Profiles = ConvertTo-NormalizedProfiles $raw
                $script:IsLegacyConfig = $true
                Log "Loaded legacy config from $legacy (unsaved). Press Save (admin) to migrate it to $ConfigPath, then delete the old AppData copy."
            }
        }
    }
}
# Hardens ACLs on both the config directory and profiles.json
# disables inheritance, sets Owner = Administrators, grants FullControl to SYSTEM/Admins
# and restricts Users to ReadAndExecute (dir) / Read (file) to block non-admin tampering
# i don't think it'll break too many setups, hopefully
function Protect-ConfigLocation([string]$cfgFile) {
    $dir = Split-Path -Parent $cfgFile
    $admSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $sysSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
    $usrSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')
    $inh = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    $prop = [System.Security.AccessControl.PropagationFlags]::None

    $dInfo = [IO.DirectoryInfo]::new($dir)
    $dSec = New-Object System.Security.AccessControl.DirectorySecurity
    $dSec.SetAccessRuleProtection($true, $false)
    $dSec.SetOwner($admSid)
    $dSec.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sysSid, [System.Security.AccessControl.FileSystemRights]::FullControl, $inh, $prop, 'Allow')))
    $dSec.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($admSid, [System.Security.AccessControl.FileSystemRights]::FullControl, $inh, $prop, 'Allow')))
    $dSec.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($usrSid, [System.Security.AccessControl.FileSystemRights]::ReadAndExecute, $inh, $prop, 'Allow')))
    $dInfo.SetAccessControl($dSec)

    if (Test-Path -LiteralPath $cfgFile -PathType Leaf) {
        $fInfo = [IO.FileInfo]::new($cfgFile)
        $fSec = New-Object System.Security.AccessControl.FileSecurity
        $fSec.SetAccessRuleProtection($true, $false)
        $fSec.SetOwner($admSid)
        $fSec.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sysSid, [System.Security.AccessControl.FileSystemRights]::FullControl, 'Allow')))
        $fSec.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($admSid, [System.Security.AccessControl.FileSystemRights]::FullControl, 'Allow')))
        $fSec.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($usrSid, [System.Security.AccessControl.FileSystemRights]::Read, 'Allow')))
        $fInfo.SetAccessControl($fSec)
    }
}
function Save-Config {
    if (-not (Test-Admin)) { throw 'Refusing non-admin Save-Config: saving to Program Files requires Administrator elevation.' }
    if (-not (Test-PathNoReparse $ConfigPath)) { throw "Security error: target config path contains a reparse point: $ConfigPath" }
    $dir = Split-Path -Parent $ConfigPath
    if (-not (Test-Path -LiteralPath $dir)) { [void][IO.Directory]::CreateDirectory($dir) }
    if (-not (Test-PathNoReparse $dir)) { throw "Security error: config directory is a reparse point: $dir" }
    $tmp = "$ConfigPath.tmp"
    if ((Test-Path -LiteralPath $tmp) -and -not (Test-PathNoReparse $tmp)) { throw "Security error: temp config path is a reparse point: $tmp" }
    # Lock down directory ACLs *before* creating .tmp, write UTF-8 without BOM
    # atomically replace profiles.json, then re-apply file-level ACL protection
    Protect-ConfigLocation $ConfigPath
    $json = ConvertTo-Json -InputObject ([pscustomobject]@{ Version = 1; Profiles = @($script:Profiles) }) -Depth 8
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $ConfigPath -Force
    Protect-ConfigLocation $ConfigPath
    $script:IsLegacyConfig = $false
    $script:SavedSnapshot = Get-ConfigSnapshotJson
}
# UAC privilege boundary: commits a staging JSON written by the non-admin GUI into
# program files under Admin elevation
# 1) Verifies staging file owner is Admins, SYSTEM, or the launching user ($expectedUserSid)
#    to defend against %TEMP% file-swap attacks on multi-user systems.
# 2) Never trusts incoming 'Applied' tracking (see loop below).
function Import-ValidatedStagingConfig([string]$stgPath, [string]$expectedUserSid) {
    if (-not (Test-Path -LiteralPath $stgPath -PathType Leaf)) { throw "Staging config not found: $stgPath" }
    if (-not (Test-PathNoReparse $stgPath)) { throw 'Security error: staging config path contains a reparse point.' }
    $fi = [IO.FileInfo]::new($stgPath)
    if ($fi.Length -gt 4194304) { throw 'Staging config exceeds 4 MB limit.' }
    $ownerSid = $fi.GetAccessControl().GetOwner([System.Security.Principal.SecurityIdentifier]).Value
    $allowedOwners = @('S-1-5-32-544', 'S-1-5-18')
    if ($expectedUserSid) { $allowedOwners += $expectedUserSid }
    if ($allowedOwners -notcontains $ownerSid) { throw "Security error: unexpected staging file owner ($ownerSid)." }
    $raw = [IO.File]::ReadAllText($stgPath, [Text.Encoding]::UTF8)
    $incoming = ConvertTo-NormalizedProfiles $raw
    # Preserve 'Applied' exclusively from the trusted on-disk config (or reset for new profiles)
    # so an unprivileged staging file cannot spoof Applied state to trick Revoke/Apply.
    $existingByName = @{}
    if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
        foreach ($ep in (ConvertTo-NormalizedProfiles (Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8))) {
            $existingByName[$ep.Name.ToLowerInvariant()] = $ep
        }
    }
    foreach ($np in $incoming) {
        $k = $np.Name.ToLowerInvariant()
        if ($existingByName.ContainsKey($k)) { $np.Applied = $existingByName[$k].Applied }
        else { $np.Applied = [pscustomobject]@{ Paths = @(); PathRules = @(); RegPaths = @(); Devices = @(); Loopback = $false; Firewall = $false } }
    }
    $script:Profiles = $incoming
    Save-Config
}
function Find-Profile([string]$n) { foreach ($p in $script:Profiles) { if ($p.Name -ieq $n) { return $p } } $null }

function Write-LogLine([string]$line) {
    if ($script:LogBox) { $script:LogBox.AppendText($line + "`r`n") }
    elseif ($LogPath) {
        if (-not (Test-Path -LiteralPath $LogPath -PathType Leaf)) { throw "Refusing to write to missing log path: $LogPath" }
        $attr = [IO.File]::GetAttributes($LogPath)
        if (($attr -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Security error: log path is a reparse point." }
        $fs = New-Object IO.FileStream($LogPath, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
        try { $sw = New-Object IO.StreamWriter($fs, [Text.Encoding]::UTF8); $sw.WriteLine($line); $sw.Flush() } finally { $fs.Dispose() }
    } else { Write-Host $line }
}
function Log([string]$m) { Write-LogLine ('[{0:HH:mm:ss}] {1}' -f (Get-Date), $m) }

# Emits out-of-band progress markers parsed by Read-ElevatedStream (03-ElevationAndProcess.ps1)
# to update the GUI progress bar from the elevated child process.
function Set-TaskProgress([int]$step, [int]$total, [string]$msg) {
    if ($total -lt 1) { $total = 1 }
    $pct = [Math]::Max(0, [Math]::Min(100, [int](($step * 100) / $total)))
    Write-LogLine "@@PROG|$pct|$msg"
}

# Helpers
# Blocks NUL and ASCII control chars; $allowMultiline permits \t (0x09), \n (0x0A), \r (0x0D)
function Assert-NoControlChars([string]$s, [string]$label, [bool]$allowMultiline = $false, [int]$maxLen = 4096) {
    if ($null -eq $s) { return }
    if ($s.Length -gt $maxLen) { throw "$label exceeds maximum length ($maxLen)." }
    $rx = if ($allowMultiline) { '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]' } else { '[\x00-\x1F\x7F]' }
    if ($s -match $rx) { throw "Security error: $label contains forbidden control characters." }
}
# Rejects leading '-' (prevents CLI flag injection when passed to -Launch / -ProfileName)
# '.' / '..', path separators, and names > 48 chars
function Assert-ValidProfileName([string]$name) {
    if ([string]::IsNullOrWhiteSpace($name)) { throw 'Profile name cannot be empty.' }
    Assert-NoControlChars $name 'Profile name' $false 48
    if ($name -ne $name.Trim()) { throw 'Profile name cannot have leading or trailing whitespace.' }
    if ($name -eq '.' -or $name -eq '..') { throw 'Invalid profile name.' }
    if ($name.StartsWith('-')) { throw 'Profile name cannot start with "-".' }
    if ($name -match '[\\/:*?"<>|]') { throw 'Profile name cannot contain \ / : * ? " < > |.' }
    $name
}
# Validates concrete host paths (after expanding %ENV%): rejects '/', leading '-', UNC ('\\')
# '..' traversal, NTFS Alternate Data Stream colons (after drive letter), and non-rooted paths
function Assert-ValidConcreteFsPath([string]$raw, [string]$label = 'Path') {
    if ([string]::IsNullOrWhiteSpace($raw)) { throw "$label cannot be empty." }
    $s = $raw.Trim().Trim('"')
    Assert-NoControlChars $s $label $false 1024
    if ($s.StartsWith('/') -or $s.StartsWith('-')) { throw "Security error: $label cannot start with '/' or '-': $s" }
    if ($s.Contains('/')) { throw "Security error: $label must use backslashes, not '/': $s" }
    if ($s -match '[*?<>|"]') { throw "Security error: $label contains forbidden wildcard/shell characters: $s" }
    if ($s.StartsWith('\\')) { throw "Security error: UNC and device paths are not permitted in ${label}: $s" }
    if ($s -match '(?:^|\\)\.\.(?:\\|$)') { throw "Security error: path traversal '..' is not permitted in ${label}: $s" }
    $exp = [Environment]::ExpandEnvironmentVariables($s)
    Assert-NoControlChars $exp $label $false 1024
    if ($exp -match '[*?<>|"%\/]') { throw "Security error: expanded $label contains invalid characters: $exp" }
    if ($exp -match '^[A-Za-z]:$') { $exp += '\' }
    if ($exp -notmatch '^[A-Za-z]:\\') { throw "Security error: $label must be a rooted local drive path (e.g. C:\...): $s" }
    if ($exp.Substring(2).Contains(':')) { throw "Security error: invalid colon (alternate data stream) in ${label}: $s" }
    $norm = [IO.Path]::GetFullPath($exp)
    if ($norm.Length -gt 3) { $norm = $norm.TrimEnd('\') }
    $norm
}
# Validates preset path templates: allows unexpanded %ENV%\... and *1 to *999 dynamic tokens
# Strips valid *n placeholders first so any remaining '*' is rejected as an illegal wildcard
function Assert-ValidPresetPath([string]$raw, [string]$label = 'Preset path') {
    if ([string]::IsNullOrWhiteSpace($raw)) { throw "$label cannot be empty." }
    $s = $raw.Trim().Trim('"')
    Assert-NoControlChars $s $label $false 1024
    if ($s.StartsWith('/') -or $s.StartsWith('-')) { throw "Security error: $label cannot start with '/' or '-': $s" }
    if ($s.Contains('/')) { throw "Security error: $label must use backslashes, not '/': $s" }
    if ($s -match '[?<>|"]') { throw "Security error: $label contains forbidden characters: $s" }
    if ($s.StartsWith('\\')) { throw "Security error: UNC and device paths are not permitted in ${label}: $s" }
    if ($s -match '(?:^|\\)\.\.(?:\\|$)') { throw "Security error: path traversal '..' is not permitted in ${label}: $s" }
    $stripped = [regex]::Replace($s, '\*(?:[1-9]\d{0,2})(?!\d)', '')
    if ($stripped.Contains('*')) { throw "Security error: only *1..*999 dynamic placeholders are allowed in ${label}: $s" }
    if ($s -match '^[A-Za-z]:$') { $s += '\' }
    if ($s -notmatch '^(?:[A-Za-z]:\\|%[A-Za-z_][A-Za-z0-9_]*%\\|\*[1-9]\d{0,2}(?:\\|$))') {
        throw "Security error: $label must be a rooted drive path, %ENV%\..., or start with *n: $s"
    }
    if ($s -match '^[A-Za-z]:' -and $s.Substring(2).Contains(':')) { throw "Security error: invalid colon in ${label}: $s" }
    if ($s -notmatch '^[A-Za-z]:' -and $s.Contains(':')) { throw "Security error: invalid colon in ${label}: $s" }
    if ($s.Length -gt 3 -and $s -notmatch '^[A-Za-z]:\\$') { $s = $s.TrimEnd('\') }
    $s
}
# Normalizes and validates registry paths (depends on Resolve-RegPath in 02-SandboxEngine.ps1)
function Assert-ValidRegistryRulePath([string]$raw) {
    if ([string]::IsNullOrWhiteSpace($raw)) { throw 'Registry path cannot be empty.' }
    Assert-NoControlChars $raw 'Registry path' $false 512
    $rp = Resolve-RegPath $raw
    if ($rp -notmatch '^(HKCU|HKLM|HKCR|HKU|HKCC)(\\.+)?$') { throw "Invalid registry path: '$raw'" }
    if ($rp -match '[*?<>|"/]' -or $rp -match '(?:^|\\)\.\.(?:\\|$)') { throw "Security error: invalid characters in registry path '$raw'" }
    $rp
}
# Matches Run, debugger/IFEO, DLL-hijack, COM/Shell, and AppContainer keys
# where granting write access enables sandbox escape
# area for improvement
# TO DO: research and expand the rulesets
function Test-RegDanger([string]$rp) {
    $rp -match '(?i)\\(CurrentVersion\\Run(Once|Services|ServicesOnce)?|Image File Execution Options|SilentProcessExit|AeDebug|Command Processor|CurrentVersion\\Windows|AppCertDlls|Winlogon|Shell\\Open\\Command|User Shell Folders|Control Panel\\Desktop|Control\\Lsa|KnownDLLs|Software\\Classes|CLSID|AppID|InprocServer32|LocalServer32|Services|Session Manager\\Environment|Environment|Policies|AppContainer)(\\|$)'
}
# Validates Win32 USB/HID device interface paths matching NativeInterop.cs:
#   a5dcbf10-6530-11d2-901f-00c04fb951ed = GUID_DEVINTERFACE_USB_DEVICE
#   4d1e55b2-f16f-11cf-88cb-001111000030 = GUID_DEVINTERFACE_HID
function Assert-ValidDeviceInterfacePath([string]$raw) {
    if ([string]::IsNullOrWhiteSpace($raw)) { throw 'Device interface path cannot be empty.' }
    $s = $raw.Trim().Trim('"')
    Assert-NoControlChars $s 'Device interface path' $false 512
    if ($s -match '(?:^|\\)\.\.(?:\\|$)') { throw "Security error: traversal '..' not permitted in device path." }
    if ($s -notmatch '(?i)^\\\\\?\\(?:usb|hid)#[^\\/:*?"<>|]+#\{(?:a5dcbf10-6530-11d2-901f-00c04fb951ed|4d1e55b2-f16f-11cf-88cb-001111000030)\}(?:\\[^\\/:*?"<>|]+)?$') {
        throw "Security error: invalid USB/HID device interface path: $s"
    }
    $s
}
function Assert-ValidProfileCommonFields($obj) {
    if ($obj.ExtraCaps) {
        Assert-NoControlChars $obj.ExtraCaps 'ExtraCaps' $false 1024
        foreach ($c in @($obj.ExtraCaps -split '[,;\s]+' | Where-Object { $_ })) {
            # Accepts named capabilities, S-1-15-3-<rid> SIDs, or S-1-15-3-1024-... derived SIDs
            if ($c -notmatch '^(?:[A-Za-z0-9_.-]+|S-1-15-3-(?:\d+(?:-\d+){3}|\d+|1024(?:-\d+)+))$') { throw "Invalid capability token '$c' in ExtraCaps." }
        }
    }
    if ($obj.EnvMode -notin 'Allowlist', 'InheritHost') { throw "Invalid EnvMode '$($obj.EnvMode)'." }
    if ($obj.EnvAllow) {
        Assert-NoControlChars $obj.EnvAllow 'EnvAllow' $false 1024
        foreach ($ev in @($obj.EnvAllow -split '[,;\s]+' | Where-Object { $_ })) {
            # Standard env var identifier up to 64 chars (can simplify away .Replace(' ', ''))
            if ($ev -notmatch '^[A-Za-z_] [A-Za-z0-9_]{0,63}$'.Replace(' ', '')) { throw "Invalid environment variable name '$ev' in EnvAllow." }
        }
    }
    if ($obj.EnvCustom) {
        Assert-NoControlChars $obj.EnvCustom 'EnvCustom' $true 8192
        foreach ($ln in ($obj.EnvCustom -split "`r?`n")) {
            $t = $ln.Trim()
            if (-not $t -or $t.StartsWith('#')) { continue } # Skip blank and # comment lines just in case
            $idx = $t.IndexOf('=')
            if ($idx -le 0) { throw 'Invalid line in EnvCustom (expected KEY=VALUE).' }
            $ck = $t.Substring(0, $idx).Trim()
            # Permits '()', spaces, and '-' in keys to support names like ProgramFiles(x86)
            if ($ck -notmatch '^[A-Za-z_][A-Za-z0-9_() -]{0,127}$') { throw "Invalid environment key '$ck' in EnvCustom." }
        }
    }
    if ($obj.CustomDesktop) {
        Assert-NoControlChars $obj.CustomDesktop 'CustomDesktop' $false 128
        # Requires "WindowStation\Desktop" format (e.g., WinSta0\Default)
        if ($obj.CustomDesktop -notmatch '^[A-Za-z0-9_.-]+\\[A-Za-z0-9_.-]+$') { throw "Invalid CustomDesktop format '$($obj.CustomDesktop)'." }
    }
    if ($obj.Net.FwBlockList) {
        Assert-NoControlChars $obj.Net.FwBlockList 'FwBlockList' $false 2048
        foreach ($item in @($obj.Net.FwBlockList -split '[,;\s]+' | Where-Object { $_ })) {
            # Test-ValidFwAddrSpec is defined in 02-SandboxEngine.ps1
            if (-not (Test-ValidFwAddrSpec $item)) { throw "Invalid IP/CIDR/range '$item' in FwBlockList." }
        }
    }
    if ($obj.Net.ServerInboundPorts) {
        Assert-NoControlChars $obj.Net.ServerInboundPorts 'ServerInboundPorts' $false 512
        foreach ($pt in @($obj.Net.ServerInboundPorts -split '[,;\s]+' | Where-Object { $_ })) {
            if ($pt -notmatch '^(\d{1,5})(?:-(\d{1,5}))?$') { throw "Invalid port specification '$pt'." }
            $p1 = [int]$Matches[1]; $p2 = if ($Matches[2]) { [int]$Matches[2] } else { $p1 }
            if ($p1 -lt 1 -or $p2 -gt 65535 -or $p1 -gt $p2) { throw "Port out of range '$pt'." }
        }
    }
    if ($obj.Limits.MaxProcesses -lt 0 -or $obj.Limits.MaxProcesses -gt 10000) { throw 'MaxProcesses out of range.' }
    if ($obj.Limits.ProcessMemMb -lt 0 -or $obj.Limits.ProcessMemMb -gt 1048576) { throw 'ProcessMemMb out of range.' }
    if ($obj.Limits.JobMemMb -lt 0 -or $obj.Limits.JobMemMb -gt 1048576) { throw 'JobMemMb out of range.' }
    if ($obj.Limits.CpuRatePct -lt 0 -or $obj.Limits.CpuRatePct -gt 100) { throw 'CpuRatePct out of range.' }
}
# Extracts unique *1 to *999 placeholders sorted numerically; (?!\d) avoids partial matches on *1000
# Profiles containing unresolved *n tokens are blocked from Apply/Launch until imported as presets
function Get-DynamicTokensFromPaths([string[]]$paths) {
    $nums = New-Object System.Collections.Generic.HashSet[int]
    foreach ($p in $paths) {
        if (-not $p) { continue }
        foreach ($m in [regex]::Matches($p, '\*(?<n>[1-9]\d{0,2})(?!\d)')) {
            [void]$nums.Add([int]$m.Groups['n'].Value)
        }
    }
    @($nums | Sort-Object | ForEach-Object { "*$_" })
}
function Test-ProfileHasDynamicPaths($p) {
    if (-not $p) { return $false }
    $paths = @($p.ExePath, $p.WorkDir) + @($p.Rules | ForEach-Object { $_.Path })
    (Get-DynamicTokensFromPaths $paths).Count -gt 0
}
function Resolve-UiRulePath([string]$raw) {
    $t = $raw.Trim().Trim('"')
    if ($t.Contains('*')) { return (Assert-ValidPresetPath $t 'Path rule') }
    Assert-ValidConcreteFsPath $t 'Path rule'
}
# Polymorphic: accepts either a profile [pscustomobject] or a profile name [string]
# Prefers explicit ContainerId when set. otherwise falls back to sanitized "acm.<Name>"
function Get-ContainerName($target) {
    if ($target -is [pscustomobject]) {
        if ($target.PSObject.Properties.Name -contains 'ContainerId' -and -not [string]::IsNullOrWhiteSpace($target.ContainerId)) {
            return [string]$target.ContainerId
        }
        return 'acm.' + ($target.Name -replace '[^A-Za-z0-9._-]', '_')
    }
    $n = [string]$target
    $found = Find-Profile $n
    if ($found -and $found.PSObject.Properties.Name -contains 'ContainerId' -and -not [string]::IsNullOrWhiteSpace($found.ContainerId)) {
        return [string]$found.ContainerId
    }
    'acm.' + ($n -replace '[^A-Za-z0-9._-]', '_')
}
# Firewall rule group name; must match Remove-Firewall (02) and Show-RuntimeInspector (05)
function Get-IsolatedDesktopShortName([string]$cn) { 'acm.desk.' + (($cn -replace '[^A-Za-z0-9._-]', '_').Trim('._-') -replace '^$', 'app') }
function Get-IsolatedDesktopPath([string]$cn) { 'WinSta0\' + (Get-IsolatedDesktopShortName $cn) }
function Get-FirewallGroup($p) {
    if ($p.PSObject.Properties.Name -contains 'ContainerId' -and -not [string]::IsNullOrWhiteSpace($p.ContainerId)) {
        return "ACM-$($p.ContainerId)"
    }
    "ACM-$($p.Name)"
}
# Allocates a unique AppContainer moniker well within Windows' 64-character name limit
# "acm." (4) + slug (<=20) + "." (1) + 8-hex GUID (8) = max 33 chars
function New-UniqueContainerId([string]$baseName) {
    $slug = ($baseName -replace '[^A-Za-z0-9._-]', '_').Trim('._-')
    if (-not $slug) { $slug = 'app' }
    if ($slug.Length -gt 20) { $slug = $slug.Substring(0, 20).TrimEnd('._-') }
    if (-not $slug) { $slug = 'app' }
    $used = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
    foreach ($ep in $script:Profiles) { [void]$used.Add((Get-ContainerName $ep)) }
    for ($i = 0; $i -lt 32; $i++) {
        $cand = 'acm.' + $slug + '.' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        if ($used.Add($cand)) { return $cand }
    }
    throw 'Unable to allocate unique ContainerId.'
}
function Find-ContainerCollision([string]$n) {
    $cn = 'acm.' + ($n -replace '[^A-Za-z0-9._-]', '_')
    foreach ($p in $script:Profiles) { if ((Get-ContainerName $p) -ieq $cn) { return $p } }
    $null
}
# Deterministically derives the AppContainer SID via UserEnv without needing the profile created yet
function Get-Sid($target) { [ACM.Native]::GetSidString((Get-ContainerName $target)) }
# Substitutes user-supplied *n values and re-validates the resolved result as a
# local drive path to block traversal/UNC injection via preset inputs
function Resolve-PresetTemplateString([string]$template, [hashtable]$values, [string]$label) {
    if ([string]::IsNullOrWhiteSpace($template)) { return '' }
    $resolved = [regex]::Replace($template, '\*(?<n>[1-9]\d{0,2})(?!\d)', {
        param($m)
        $tok = '*' + $m.Groups['n'].Value
        if (-not $values.ContainsKey($tok)) { throw "Missing value for $tok in $label." }
        $values[$tok]
    })
    Assert-ValidConcreteFsPath $resolved $label
}
# Parses and sanitizes an untrusted/shared .acmpreset.json (1 MB cap)
# don't tell me someone's making a config with a million symbols total
function ConvertFrom-PresetJson([string]$raw) {
    if ([string]::IsNullOrWhiteSpace($raw)) { throw 'Preset file is empty.' }
    if ($raw.Length -gt 1048576) { throw 'Preset exceeds 1 MB size limit.' }
    $j = $raw | ConvertFrom-Json
    if ($null -eq $j -or $j -isnot [pscustomobject]) { throw 'Invalid preset JSON structure.' }
    if ($j.Type -ne 'AppContainerPreset' -or [int]$j.PresetVersion -ne 1) { throw 'Unsupported or invalid AppContainer preset header.' }
    $pName = Assert-ValidProfileName ([string]$j.Name)
    $def = New-ProfileObject $pName
    $obj = Merge-Obj $def $j
    $obj.Name = $pName
    # Strip instance-specific state and force safe defaults so shared presets cannot smuggle
    # host env inheritance, custom desktops, or symlink/junction traversal
    $obj.ContainerId = ''
    $obj.Applied = [pscustomobject]@{ Paths = @(); PathRules = @(); RegPaths = @(); Devices = @(); Loopback = $false; Firewall = $false }
    if ($obj.Dev.UsbHidMode -notin 'Off', 'All', 'Specific') { throw "Invalid Dev.UsbHidMode '$($obj.Dev.UsbHidMode)' in preset." }
    $cleanPresetDevs = @()
    foreach ($dp in @($obj.Dev.UsbHidDevices)) { if (-not [string]::IsNullOrWhiteSpace([string]$dp)) { $cleanPresetDevs += (Assert-ValidDeviceInterfacePath ([string]$dp)) } }
    $obj.Dev.UsbHidDevices = @($cleanPresetDevs | Select-Object -Unique)
    $obj.EnvMode = 'Allowlist'
    $obj.EnvCustom = ''
    $obj.CustomDesktop = ''
    $obj.Hard.FollowReparse = $false
    Assert-NoControlChars $obj.Description 'Preset Description' $true 1024
    if ($obj.Arguments) {
        Assert-NoControlChars $obj.Arguments 'Preset Arguments' $false 1024
        # Block shell/cmd metacharacters in shared preset arguments
        if ($obj.Arguments -match '[&|;<>`$%]') { throw 'Security error: preset Arguments contain disallowed command/shell metacharacters (& | ; < > ` $ %).' }
    }
    if ($obj.ExePath) {
        if ($obj.ExePath.Contains('*')) { $obj.ExePath = Assert-ValidPresetPath $obj.ExePath 'Preset ExePath' }
        else { $obj.ExePath = Assert-ValidConcreteFsPath $obj.ExePath 'Preset ExePath' }
    }
    if ($obj.WorkDir) {
        if ($obj.WorkDir.Contains('*')) { $obj.WorkDir = Assert-ValidPresetPath $obj.WorkDir 'Preset WorkDir' }
        else { $obj.WorkDir = Assert-ValidConcreteFsPath $obj.WorkDir 'Preset WorkDir' }
    }
    Assert-ValidProfileCommonFields $obj
    $cleanRules = @()
    foreach ($r in @($obj.Rules)) {
        if ($r -isnot [pscustomobject]) { throw 'Invalid path rule in preset.' }
        $rawP = [string]$r.Path
        $rp = if ($rawP.Contains('*')) { Assert-ValidPresetPath $rawP 'Preset rule path' } else { Assert-ValidConcreteFsPath $rawP 'Preset rule path' }
        $sc = if ($r.PSObject.Properties.Name -contains 'Scope') { [string]$r.Scope } else { 'Recursive' }
        $acc = if ($r.Access -in 'Read', 'ReadWrite', 'ReadExecute', 'Full') { [string]$r.Access } else { throw "Invalid preset rule access '$($r.Access)'." }
        $force = ($r.PSObject.Properties.Name -contains 'Force' -and [bool]$r.Force)
        $cleanRules += [pscustomobject]@{ Path = $rp; Scope = (Resolve-PathScopeKey $sc); Access = $acc; Force = $force }
    }
    $obj.Rules = @($cleanRules)
    $cleanReg = @()
    foreach ($rr in @($obj.RegRules)) {
        if ($rr -isnot [pscustomobject]) { throw 'Invalid registry rule in preset.' }
        $regP = Assert-ValidRegistryRulePath ([string]$rr.Path)
        $rsc = if ($rr.PSObject.Properties.Name -contains 'Scope') { [string]$rr.Scope } else { 'Recursive' }
        $racc = if ($rr.Access -in 'Read', 'ReadWrite', 'Full') { [string]$rr.Access } else { throw "Invalid preset registry access '$($rr.Access)'." }
        # Hard-block writable access to high-risk registry keys when importing shared presets
        # Area for improvement
        # TO DO: research and expand the list
        if ($racc -in 'ReadWrite', 'Full' -and (Test-RegDanger $regP)) { throw "Security error: preset attempts write access to high-risk registry key '$regP'." }
        $rv = if ($rr.PSObject.Properties.Name -contains 'View' -and $rr.View -in 'Both', '64', '32') { [string]$rr.View } else { 'Both' }
        $cleanReg += [pscustomobject]@{ Path = $regP; Scope = (Resolve-RegScopeKey $rsc); Access = $racc; View = $rv }
    }
    $obj.RegRules = @($cleanReg)
    $allPaths = @($obj.ExePath, $obj.WorkDir) + @($obj.Rules | ForEach-Object { $_.Path })
    $tokens = @(Get-DynamicTokensFromPaths $allPaths)
    $dynMap = [ordered]@{}
    if ($j.PSObject.Properties.Name -contains 'DynamicVars' -and $null -ne $j.DynamicVars) {
        foreach ($dv in @($j.DynamicVars)) {
            if ($dv -isnot [pscustomobject] -or $dv.Token -isnot [string] -or $dv.Description -isnot [string]) { throw 'Invalid DynamicVars entry in preset.' }
            $tok = $dv.Token.Trim()
            if ($tok -notmatch '^\*([1-9]\d{0,2})$') { throw "Invalid dynamic token '$tok' in preset." }
            Assert-NoControlChars $dv.Description "Description for $tok" $false 200
            $desc = $dv.Description.Trim()
            if (-not $desc) { throw "Creator description for $tok cannot be empty." }
            $dynMap[$tok] = $desc
        }
    }
    # Ensure every *n placeholder referenced in ExePath/WorkDir/Rules has a creator description
    # filter out lazy makers
    foreach ($tok in $tokens) {
        if (-not $dynMap.Contains($tok)) { throw "Preset is missing creator description for dynamic path placeholder $tok." }
    }
    $dynVars = @()
    foreach ($tok in $tokens) { $dynVars += [pscustomobject]@{ Token = $tok; Description = $dynMap[$tok] } }
    [pscustomobject]@{ Profile = $obj; DynamicVars = @($dynVars) }
}