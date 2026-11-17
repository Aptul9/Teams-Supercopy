<#
Stops the listener, removes the Startup shortcut and the installed script.
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Programs\TeamsSupercopy'),
    [string]$StartupDir = [Environment]::GetFolderPath('Startup')
)

$ErrorActionPreference = 'Stop'

$listeners = @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { $_.CommandLine -match 'teams-supercopy\.ps1' })
$listeners | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
# a stopped listener keeps the install folder open (its working directory) until it has really exited
if ($listeners) { Wait-Process -Id $listeners.ProcessId -Timeout 10 -ErrorAction SilentlyContinue }

Remove-Item (Join-Path $StartupDir 'Teams Supercopy.lnk') -ErrorAction SilentlyContinue
if (Test-Path (Join-Path $InstallDir 'teams-supercopy.ps1')) {
    for ($try = 1; ; $try++) {
        try { Remove-Item $InstallDir -Recurse -Force; break }
        catch { if ($try -ge 10) { throw }; Start-Sleep -Milliseconds 500 }
    }
}
