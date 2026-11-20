# Tests the download made by package-windows.ps1 the way a user gets it: checks the JSON against the ZIP, extracts the ZIP into
# a new folder, checks every file against package-manifest.json and parses every script, then runs the extracted install.ps1
# into a temporary install and Startup folder, starts the tray app through the Startup shortcut, waits for "listener ready"
# in its log, checks the listener has no console, kills it and waits for the tray app to start it again, and removes
# everything with the extracted uninstall.ps1.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Archive)
$ErrorActionPreference = 'Stop'
$Archive = (Resolve-Path $Archive).Path
$name = [IO.Path]::GetFileNameWithoutExtension($Archive)
$meta = Get-Content (Join-Path (Split-Path $Archive -Parent) "$name.json") -Raw | ConvertFrom-Json

$keys = ($meta.PSObject.Properties.Name | Sort-Object) -join ','
if ($keys -ne 'bytes,commit,file,sha256,version') { throw "JSON fields are $keys" }
$hash = (Get-FileHash $Archive).Hash.ToLowerInvariant()
if ($meta.sha256 -ne $hash) { throw "JSON sha256 $($meta.sha256) differs from the ZIP $hash" }
if ([long]$meta.bytes -ne (Get-Item $Archive).Length) { throw "JSON bytes $($meta.bytes) differ from the ZIP $((Get-Item $Archive).Length)" }
if ($meta.file -ne [IO.Path]::GetFileName($Archive)) { throw "JSON file $($meta.file) is not the ZIP name" }
if ($meta.commit -notmatch '^[0-9a-f]{40}$') { throw "JSON commit $($meta.commit) is not a commit sha" }
if ($meta.version -notmatch '^\d+\.\d+\.\d+$') { throw "JSON version $($meta.version) is not major.minor.patch" }

# install.ps1 and uninstall.ps1 stop every running listener: never run this next to one in use
if ((Get-Process TeamsSupercopy -ErrorAction SilentlyContinue) -or (Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object CommandLine -match 'teams-supercopy\.ps1')) {
    throw 'a Teams Supercopy listener is running; stop it first'
}

$work = Join-Path ([IO.Path]::GetTempPath()) ('teams-supercopy-test-' + [guid]::NewGuid().ToString('N'))
$out = Join-Path $work 'extracted'
$installDir = Join-Path $work 'install'
$startupDir = Join-Path $work 'startup'
try {
    Expand-Archive $Archive $out
    $manifest = Get-Content (Join-Path $out 'package-manifest.json') -Raw | ConvertFrom-Json
    $listed = @($manifest.files.path) + 'package-manifest.json'
    $extra = @(Get-ChildItem $out -File -Recurse | Where-Object { $listed -notcontains [IO.Path]::GetRelativePath($out, $_.FullName).Replace('\', '/') })
    if ($extra) { throw "files not in the manifest: $($extra.Name -join ', ')" }
    foreach ($required in 'teams-supercopy.ps1', 'TeamsSupercopy.exe', 'install.ps1', 'uninstall.ps1', 'assets/icon.ico', 'README.md') {
        if ($manifest.files.path -notcontains $required) { throw "manifest misses $required" }
    }
    foreach ($file in $manifest.files) {
        $path = Join-Path $out $file.path
        if (-not (Test-Path $path)) { throw "missing $($file.path)" }
        if ((Get-FileHash $path).Hash.ToLowerInvariant() -ne $file.sha256) { throw "sha256 mismatch: $($file.path)" }
    }
    if ($manifest.version -ne $meta.version -or $manifest.commit -ne $meta.commit) { throw 'manifest and JSON disagree on version or commit' }
    foreach ($ps1 in Get-ChildItem $out -Filter *.ps1 -Recurse) {
        $tokens = $null; $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile($ps1.FullName, [ref]$tokens, [ref]$errors)
        if ($errors) { throw "$($ps1.Name): $($errors.Message -join '; ')" }
    }

    $installed = & (Join-Path $out 'install.ps1') -InstallDir $installDir -StartupDir $startupDir -NoStart
    if ($installed.Version -ne $meta.version) { throw "installed version $($installed.Version) differs from JSON $($meta.version)" }
    if ($installed.Running) { throw 'install.ps1 -NoStart started the listener' }
    foreach ($pair in @(@('teams-supercopy.ps1', 'teams-supercopy.ps1'), @('TeamsSupercopy.exe', 'TeamsSupercopy.exe'), @('assets/icon.ico', 'icon.ico'))) {
        $a = (Get-FileHash (Join-Path $out $pair[0])).Hash; $b = (Get-FileHash (Join-Path $installDir $pair[1])).Hash
        if ($a -ne $b) { throw "installed $($pair[1]) differs from the package" }
    }
    $lnk = Join-Path $startupDir 'Teams Supercopy.lnk'
    $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
    $script = Join-Path $installDir 'teams-supercopy.ps1'
    $exe = Join-Path $installDir 'TeamsSupercopy.exe'
    if ($shortcut.TargetPath -ne $exe) { throw "shortcut target $($shortcut.TargetPath) is not $exe" }

    # the shortcut is what Windows opens at login
    Start-Process $lnk
    $log = Join-Path $installDir 'teams-supercopy.log'
    $ready = "listener ready v$($meta.version):"
    function Wait-Ready([int]$count) {
        for ($i = 0; $i -lt 60 -and @(if (Test-Path $log) { Select-String -Path $log -SimpleMatch $ready }).Count -lt $count; $i++) { Start-Sleep -Milliseconds 500 }
        $found = @(if (Test-Path $log) { Select-String -Path $log -SimpleMatch $ready })
        $script:listener = @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { $_.CommandLine -like "*$script*" })
        if ($found.Count -lt $count) {
            throw "no '$ready' line number $count in $log within 30 s; listener processes: $($script:listener.Count); log: $(if (Test-Path $log) { Get-Content $log -Raw })"
        }
        if ($script:listener.Count -ne 1) { throw "expected one listener, found $($script:listener.Count)" }
        $found[-1].Line
    }
    $readyLine = Wait-Ready 1
    $tray = @(Get-CimInstance Win32_Process -Filter "Name='TeamsSupercopy.exe'" | Where-Object { $_.ExecutablePath -eq $exe })
    if ($tray.Count -ne 1) { throw "expected one tray app from the shortcut, found $($tray.Count)" }
    if ($listener[0].ParentProcessId -ne $tray[0].ProcessId) { throw 'the listener is not a child of the tray app' }
    # no visible window (the headless conhost of a console app has none): closing a window must never end the listener
    $kids = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($listener[0].ProcessId)")
    if ($kids | Where-Object { $_.Name -in 'OpenConsole.exe', 'WindowsTerminal.exe' }) { throw 'the listener runs in Windows Terminal' }
    Add-Type -Namespace TeamsSupercopyTest -Name Win -MemberDefinition @'
public delegate bool EnumProc(IntPtr h, IntPtr l);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr l);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
'@
    $owners = @($listener[0].ProcessId, $tray[0].ProcessId) + @($kids.ProcessId)
    $visible = [Collections.Generic.List[uint32]]::new()
    $null = [TeamsSupercopyTest.Win]::EnumWindows({ param($h, $l) $p = [uint32]0; $null = [TeamsSupercopyTest.Win]::GetWindowThreadProcessId($h, [ref]$p); if ($owners -contains $p -and [TeamsSupercopyTest.Win]::IsWindowVisible($h)) { $visible.Add($p) }; $true }, [IntPtr]::Zero)
    if ($visible.Count) { throw "visible windows owned by processes $($visible -join ', ')" }

    # a listener that dies is started again by the tray app
    $first = $listener[0].ProcessId
    Stop-Process -Id $first -Force
    $null = Wait-Ready 2
    if ($listener[0].ProcessId -eq $first) { throw 'the tray app did not restart the listener' }

    & (Join-Path $out 'uninstall.ps1') -InstallDir $installDir -StartupDir $startupDir
    Start-Sleep -Seconds 1
    if (Test-Path $installDir) { throw 'uninstall.ps1 left the install folder' }
    if (Test-Path $lnk) { throw 'uninstall.ps1 left the Startup shortcut' }
    if (Get-Process -Id $listener[0].ProcessId -ErrorAction SilentlyContinue) { throw 'uninstall.ps1 left the listener running' }
    if (Get-Process -Id $tray[0].ProcessId -ErrorAction SilentlyContinue) { throw 'uninstall.ps1 left the tray app running' }

    [pscustomobject]@{ version = $installed.Version; tray = $tray[0].ProcessId; listener = $first; restarted = $listener[0].ProcessId; log = $readyLine; files = $manifest.files.path -join ',' } | ConvertTo-Json -Compress
    "package ok: $($meta.file) $($meta.version) $hash"
}
finally {
    Get-CimInstance Win32_Process -Filter "Name='TeamsSupercopy.exe' OR Name='pwsh.exe'" | Where-Object { "$($_.ExecutablePath) $($_.CommandLine)" -like "*$installDir*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 300
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
