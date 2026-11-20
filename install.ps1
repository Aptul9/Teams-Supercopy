<#
Installs Teams Supercopy for the current user: copies the tray app and the listener script, adds a shortcut to
the Startup folder so the tray app starts at login, and starts it now. The tray app runs the listener without a
console window and restarts it if it stops.
Re-running it updates the installed copy and restarts the listener.
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Programs\TeamsSupercopy'),
    [string]$StartupDir = [Environment]::GetFolderPath('Startup'),
    [switch]$NoStart
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) { throw 'PowerShell 7 (pwsh) is required: winget install Microsoft.PowerShell' }

$script = Join-Path $InstallDir 'teams-supercopy.ps1'
$exe = Join-Path $InstallDir 'TeamsSupercopy.exe'
$icon = Join-Path $InstallDir 'icon.ico'

# the tray app first, or it restarts the listener; then any listener, which holds the hotkeys
$running = @(Get-Process TeamsSupercopy -ErrorAction SilentlyContinue) +
    @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { $_.CommandLine -match 'teams-supercopy\.ps1' } | ForEach-Object { Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue })
$running | Where-Object { $_ } | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
# and wait until they have exited: until then they hold the hotkeys, the mutex and the install folder
if ($running) { Wait-Process -Id ($running | Where-Object { $_ }).Id -Timeout 10 -ErrorAction SilentlyContinue }

New-Item -ItemType Directory -Force $InstallDir, $StartupDir | Out-Null
foreach ($pair in @(@('teams-supercopy.ps1', $script), @('TeamsSupercopy.exe', $exe), @('assets\icon.ico', $icon))) {
    Copy-Item (Join-Path $PSScriptRoot $pair[0]) $pair[1] -Force
    Unblock-File $pair[1]
}

$lnk = Join-Path $StartupDir 'Teams Supercopy.lnk'
$sh = New-Object -ComObject WScript.Shell
$s = $sh.CreateShortcut($lnk)
$s.TargetPath = $exe
$s.Arguments = ''
$s.WorkingDirectory = $InstallDir
$s.IconLocation = "$icon,0"
$s.Description = 'Teams Supercopy: Ctrl+Alt+C copies Teams messages with author, time and quote'
$s.Save()

if (-not $NoStart) {
    Start-Process $exe -WorkingDirectory $InstallDir
    Start-Sleep -Seconds 3
}

$listener = Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { $_.CommandLine -match 'teams-supercopy\.ps1' }
$version = [regex]::Match((Get-Content $script -Raw), "(?m)^\`$SupercopyVersion = '([^']+)'").Groups[1].Value
[pscustomobject]@{
    Version  = $version
    Script   = $script
    Tray     = $exe
    Shortcut = $lnk
    Running  = [bool]$listener
    Pid      = $listener.ProcessId
}
