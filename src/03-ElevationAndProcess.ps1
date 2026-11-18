<#
  03-ElevationAndProcess.ps1 (GUI mode only)
  Handles non-elevated background profile launches, desktop shortcuts, private IPC
  temp files, and async UAC-elevated tasks (-Elevated Apply/Revoke/SaveConfig/Delete)
  with live log/progress tailing back into the WinForms UI.
  Expects: $script:AsyncState, $script:LaunchWatchers, $script:Busy, $script:LogBox,
           $script:ProgBar, $script:ProgLbl, and $script:ForceClose.
#>
function Read-ElevatedStream {
    $st = $script:AsyncState
    if (-not $st -or -not (Test-Path -LiteralPath $st.Log)) { return }
    try {
        # ReadWrite share is required because the elevated worker appends concurrently via Write-LogLine
        $fs = New-Object IO.FileStream($st.Log, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            if ($fs.Length -gt $st.Pos) {
                # Tail from the last byte offset so each 150ms tick only parses new output
                $fs.Seek($st.Pos, [IO.SeekOrigin]::Begin) | Out-Null
                $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
                $txt = $sr.ReadToEnd(); $st.Pos = $fs.Position
                foreach ($ln in ($txt -split "`r?`n")) {
                    if (-not $ln) { continue }
                    # Out-of-band progress lines emitted by Set-TaskProgress: @@PROG|<0-100>|<status>
                    if ($ln -match '^@@PROG\|(\d+)\|(.*)$') {
                        if ($script:ProgBar) { $script:ProgBar.Value = [Math]::Max(0, [Math]::Min(100, [int]$Matches[1])) }
                        $st.LastMsg = $Matches[2]
                    } elseif ($script:LogBox) { $script:LogBox.AppendText($ln + "`r`n") }
                }
            }
        } finally { $fs.Dispose() }
    } catch {}
}
function New-PrivateTempFile([string]$userSid, [string]$ext = '.tmp') {
    $p = Join-Path $env:TEMP ('acm_{0}{1}' -f [guid]::NewGuid().ToString('N'), $ext)
    # Build a protected DACL (strip inherited %TEMP% ACEs) restricted to caller, Administrators, and SYSTEM
    # Passing FileSecurity to FileMode.CreateNew sets the ACL atomically at creation (no TOCTOU window
    # before elevated Import-ValidatedStagingConfig verifies file ownership)
    $fsSec = New-Object System.Security.AccessControl.FileSecurity
    $fsSec.SetAccessRuleProtection($true, $false)
    $uId = New-Object System.Security.Principal.SecurityIdentifier($userSid)
    $admId = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544') # BUILTIN\Administrators
    $sysId = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')     # NT AUTHORITY\SYSTEM
    foreach ($id in @($uId, $admId, $sysId)) {
        $fsSec.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($id, [System.Security.AccessControl.FileSystemRights]::FullControl, 'Allow')))
    }
    $fs = New-Object IO.FileStream($p, [IO.FileMode]::CreateNew, ([System.Security.AccessControl.FileSystemRights]::Read -bor [System.Security.AccessControl.FileSystemRights]::Write), [IO.FileShare]::ReadWrite, 4096, [IO.FileOptions]::None, $fsSec)
    $fs.Dispose()
    $p
}
function New-PrivateTempLog([string]$userSid) { New-PrivateTempFile $userSid '.log' }
function New-DesktopShortcut($p) {
    $ws = New-Object -ComObject WScript.Shell
    $desktop = $ws.SpecialFolders.Item('Desktop')
    $lnk = $ws.CreateShortcut((Join-Path $desktop "$($p.Name) (sandboxed).lnk"))
    # Target the same PowerShell host (powershell.exe vs pwsh.exe) currently running the GUI
    $lnk.TargetPath = (Get-Process -Id $PID).Path
    $lnk.Arguments = Format-ArgString (Get-LauncherArgs $p.Name)
    $exe = Resolve-RulePath $p.ExePath; if (Test-Path -LiteralPath $exe) { $lnk.IconLocation = "$exe,0" }
    # 7 = Minimized without activating/stealing focus (reduces console flash on launch)
    $lnk.WindowStyle = 7; $lnk.Save()
    Log 'Shortcut created on the desktop (keep this script where it is).'
}
function Invoke-LaunchProfileProcess($p) {
    # Spawn -Launch in a separate hidden PowerShell process: Start-Sandboxed blocks while waiting on
    # KillOnClose/WaitTree jobs, which would freeze the WinForms UI thread. Multiple launches can run concurrently

    $uSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $launchLog = New-PrivateTempLog $uSid
    $launchArgs = (Get-LauncherArgs $p.Name) + @('-LogPath', $launchLog)
    $lProc = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList (Format-ArgString $launchArgs) -WindowStyle Hidden -PassThru
    $lTmr = New-Object Windows.Forms.Timer; $lTmr.Interval = 200
    # Tracked in $script:LaunchWatchers so FormClosing (05-GuiController.ps1) can stop timers/remove logs on exit
    $wState = [pscustomobject]@{ Proc = $lProc; Log = $launchLog; Pos = [long]0; Tmr = $lTmr }
    [void]$script:LaunchWatchers.Add($wState)
    $lTmr.Tag = $wState
    $lTmr.Add_Tick({
        # WinForms timer runs on the UI thread so updating $script:LogBox directly is thread-safe
        param($sender, $e)
        $ws = $sender.Tag; if (-not $ws) { return }
        try {
            if (Test-Path -LiteralPath $ws.Log) {
                $fs = New-Object IO.FileStream($ws.Log, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
                try {
                    if ($fs.Length -gt $ws.Pos) {
                        $fs.Seek($ws.Pos, [IO.SeekOrigin]::Begin) | Out-Null
                        $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
                        $txt = $sr.ReadToEnd(); $ws.Pos = $fs.Position
                        foreach ($ln in ($txt -split "`r?`n")) {
                            if ($ln -and $script:LogBox) { $script:LogBox.AppendText($ln + "`r`n") }
                        }
                    }
                } finally { $fs.Dispose() }
            }
            if ($ws.Proc.HasExited) {
                $ws.Tmr.Stop(); $ws.Tmr.Dispose()
                # Flush: drain any trailing lines written just before exit.
                if (Test-Path -LiteralPath $ws.Log) {
                    $fs = New-Object IO.FileStream($ws.Log, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
                    try {
                        if ($fs.Length -gt $ws.Pos) {
                            $fs.Seek($ws.Pos, [IO.SeekOrigin]::Begin) | Out-Null
                            $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
                            $txt = $sr.ReadToEnd()
                            foreach ($ln in ($txt -split "`r?`n")) {
                                if ($ln -and $script:LogBox) { $script:LogBox.AppendText($ln + "`r`n") }
                            }
                        }
                    } finally { $fs.Dispose() }
                    Remove-Item -LiteralPath $ws.Log -Force -ErrorAction SilentlyContinue
                }
                [void]$script:LaunchWatchers.Remove($ws)
            }
        } catch {}
    })
    $lTmr.Start()
    Log "Launching '$($p.Name)'..."
}
function Invoke-Elevated([string]$mode, [string]$name, [string]$onDone = 'Reload', [bool]$sendStaging = $false) {
    # Single-flight guard
    # $script:AsyncState and the progress bar only support one elevated worker at a time
    if ($script:Busy) { throw 'An elevated operation is already running.' }
    $uSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $log = New-PrivateTempLog $uSid
    $stg = ''
    try {
        if ($sendStaging) {
            $stg = New-PrivateTempFile $uSid '.json'
            # Depth 8 matches Get-ConfigSnapshotJson so nested Limits/Rules/Applied objects are not truncated
            # write UTF-8 without BOM for clean parsing
            $json = ConvertTo-Json -InputObject ([pscustomobject]@{ Version = 1; Profiles = @($script:Profiles) }) -Depth 8
            [IO.File]::WriteAllText($stg, $json, (New-Object Text.UTF8Encoding($false)))
        }
        # Pass -TargetUserSid so over-the-shoulder UAC (different admin account) still validates staging ownership
        # and resolves the launching user's HKCU hive
        $argList = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $script:MainScriptPath, '-Elevated', $mode,
            '-ConfigPath', $ConfigPath, '-LogPath', $log, '-TargetUserSid', $uSid)
        if ($name) { $argList += @('-ProfileName', $name) }
        if ($stg) { $argList += @('-StagingPath', $stg) }
        $spArgs = @{ FilePath = (Get-Process -Id $PID).Path; ArgumentList = (Format-ArgString $argList); PassThru = $true; WindowStyle = 'Hidden' }
        if (-not (Test-Admin)) { $spArgs.Verb = 'RunAs' }
        $pr = Start-Process @spArgs
    } catch {
        # Clean up private temp files if Start-Process fails or the user cancels the UAC prompt
        Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
        if ($stg) { Remove-Item -LiteralPath $stg -Force -ErrorAction SilentlyContinue }
        throw
    }
    Set-UiBusy $true
    if ($script:ProgBar) { $script:ProgBar.Value = 0 }
    if ($script:ProgLbl) { $script:ProgLbl.Text = "0% - Starting $mode '$name'... [00:00]" }
    $tmr = New-Object Windows.Forms.Timer; $tmr.Interval = 150
    $script:AsyncState = [pscustomobject]@{ Proc = $pr; Log = $log; Staging = $stg; Pos = [long]0; Start = [DateTime]::UtcNow; LastMsg = "Starting $mode '$name'..."; Mode = $mode; Name = $name; OnDone = $onDone; Tmr = $tmr }
    $tmr.Add_Tick({
        $st = $script:AsyncState; if (-not $st) { return }
        try {
            Read-ElevatedStream
            $el = [DateTime]::UtcNow - $st.Start
            $pct = if ($script:ProgBar) { $script:ProgBar.Value } else { 0 }
            if ($script:ProgLbl) { $script:ProgLbl.Text = ('{0}% - {1} [{2:mm\:ss}]' -f $pct, $st.LastMsg, $el) }
            if ($st.Proc.HasExited) {
                $st.Tmr.Stop(); $st.Tmr.Dispose()
                Read-ElevatedStream
                Remove-Item -LiteralPath $st.Log -Force -ErrorAction SilentlyContinue
                if ($st.Staging) { Remove-Item -LiteralPath $st.Staging -Force -ErrorAction SilentlyContinue }
                $ec = $st.Proc.ExitCode
                Log "Elevated task exit code: $ec"
                if ($script:ProgBar) { $script:ProgBar.Value = if ($ec -eq 0) { 100 } else { 0 } }
                if ($script:ProgLbl) { $script:ProgLbl.Text = if ($ec -eq 0) { "100% - $($st.Mode) complete ($('{0:mm\:ss}' -f $el))." } else { "$($st.Mode) failed (exit $ec)." } }
                $script:AsyncState = $null
                Set-UiBusy $false
                if ($ec -ne 0) {
                    [void][Windows.Forms.MessageBox]::Show("$($st.Mode) failed (exit code $ec). Check the log at the bottom for details.", 'Elevated task failed', 'OK', 'Error')
                }
                # Post-elevation continuation state machine:
                #   Close              -> reload, bypass dirty-check via $script:ForceClose and close GUI
                #   DeleteLocal:<name> -> elevated worker already deleted config/system ACLs. now wipe user's container storage
                #   Launch:<name>      -> resume deferred Launch after saving dirty config
                #   Shortcut:<name>    -> resume deferred Shortcut creation after saving dirty config
                #   Reload             -> refresh UI from disk even if $ec != 0
                if ($st.OnDone -eq 'Close') {
                    if ($ec -eq 0) { Safe { Reload-Config ''; $script:ForceClose = $true; $F.Close() } }
                } elseif ($st.OnDone -like 'DeleteLocal:*') {
                    if ($ec -eq 0) {
                        $tName = $st.OnDone.Substring(12)
                        Safe { Remove-LocalContainerProfile $tName; Reload-Config '' }
                    } else {
                        Safe { Reload-Config $st.Name }
                    }
                } elseif ($st.OnDone -like 'Launch:*') {
                    if ($ec -eq 0) {
                        $tName = $st.OnDone.Substring(7)
                        Safe { Reload-Config $tName; $lp = Find-Profile $tName; if ($lp) { Invoke-LaunchProfileProcess $lp } }
                    }
                } elseif ($st.OnDone -like 'Shortcut:*') {
                    if ($ec -eq 0) {
                        $tName = $st.OnDone.Substring(9)
                        Safe { Reload-Config $tName; $sp = Find-Profile $tName; if ($sp) { New-DesktopShortcut $sp } }
                    }
                } elseif ($ec -eq 0 -or $st.OnDone -eq 'Reload') {
                    Safe { Reload-Config $st.Name }
                }
            }
        } catch {
            if ($st.Tmr) { $st.Tmr.Stop(); $st.Tmr.Dispose() }
            if ($st.Log) { Remove-Item -LiteralPath $st.Log -Force -ErrorAction SilentlyContinue }
            if ($st.Staging) { Remove-Item -LiteralPath $st.Staging -Force -ErrorAction SilentlyContinue }
            $script:AsyncState = $null; Set-UiBusy $false; Log "ERROR: $($_.Exception.Message)"
        }
    })
    $tmr.Start()
}
