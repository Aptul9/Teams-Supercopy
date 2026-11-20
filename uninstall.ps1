<#
Stops the tray app and the listener, removes the Startup shortcut and the installed files.
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Programs\TeamsSupercopy'),
    [string]$StartupDir = [Environment]::GetFolderPath('Startup')
)

$ErrorActionPreference = 'Stop'

# the tray app first, or it restarts the listener
$running = @(Get-Process TeamsSupercopy -ErrorAction SilentlyContinue) +
    @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { $_.CommandLine -match 'teams-supercopy\.ps1' } | ForEach-Object { Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue })
$running | Where-Object { $_ } | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
# a stopped process keeps the install folder open (its working directory) until it has really exited
if ($running) { Wait-Process -Id ($running | Where-Object { $_ }).Id -Timeout 10 -ErrorAction SilentlyContinue }

Remove-Item (Join-Path $StartupDir 'Teams Supercopy.lnk') -ErrorAction SilentlyContinue
if (Test-Path (Join-Path $InstallDir 'teams-supercopy.ps1')) {
    for ($try = 1; ; $try++) {
        try { Remove-Item $InstallDir -Recurse -Force; break }
        catch { if ($try -ge 10) { throw }; Start-Sleep -Milliseconds 500 }
    }
}
