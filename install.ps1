<#
Installs Teams Supercopy for the current user: copies the script, adds a shortcut to
the Startup folder so the listener starts at login, and starts it now.
Re-running it updates the installed copy and restarts the listener.
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Programs\TeamsSupercopy'),
    [string]$StartupDir = [Environment]::GetFolderPath('Startup'),
    [switch]$NoStart
)

$ErrorActionPreference = 'Stop'

$pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
if (-not $pwsh) { throw 'PowerShell 7 (pwsh) is required: winget install Microsoft.PowerShell' }

$script = Join-Path $InstallDir 'teams-supercopy.ps1'
$icon = Join-Path $InstallDir 'icon.ico'

# a running listener holds the hotkeys; stop it so the new copy can register them
$listeners = @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { $_.CommandLine -match 'teams-supercopy\.ps1' })
$listeners | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
# and wait until it has exited: until then it still holds the hotkeys, the mutex and the install folder
if ($listeners) { Wait-Process -Id $listeners.ProcessId -Timeout 10 -ErrorAction SilentlyContinue }

New-Item -ItemType Directory -Force $InstallDir, $StartupDir | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'teams-supercopy.ps1') $script -Force
Unblock-File $script
Copy-Item (Join-Path $PSScriptRoot 'assets\icon.ico') $icon -Force

$args_ = '-NoProfile -WindowStyle Hidden -File "{0}"' -f $script
$lnk = Join-Path $StartupDir 'Teams Supercopy.lnk'
$sh = New-Object -ComObject WScript.Shell
$s = $sh.CreateShortcut($lnk)
$s.TargetPath = $pwsh
$s.Arguments = $args_
$s.WorkingDirectory = $InstallDir
$s.WindowStyle = 7
$s.IconLocation = "$icon,0"
$s.Description = 'Teams Supercopy: Ctrl+Alt+C copies Teams messages with author, time and quote'
$s.Save()

if (-not $NoStart) {
    Start-Process $pwsh -ArgumentList $args_ -WindowStyle Hidden
    Start-Sleep -Seconds 3
}

$running = Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { $_.CommandLine -match 'teams-supercopy\.ps1' }
$version = [regex]::Match((Get-Content $script -Raw), "(?m)^\`$SupercopyVersion = '([^']+)'").Groups[1].Value
[pscustomobject]@{
    Version  = $version
    Script   = $script
    Shortcut = $lnk
    Running  = [bool]$running
    Pid      = $running.ProcessId
}
