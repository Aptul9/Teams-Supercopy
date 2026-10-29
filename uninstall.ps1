<#
Stops the listener, removes the Startup shortcut and the installed script.
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Programs\TeamsSupercopy'),
    [string]$StartupDir = [Environment]::GetFolderPath('Startup')
)

$ErrorActionPreference = 'Stop'

Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" |
    Where-Object { $_.CommandLine -match 'teams-supercopy\.ps1' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

Remove-Item (Join-Path $StartupDir 'Teams Supercopy.lnk') -ErrorAction SilentlyContinue
if (Test-Path (Join-Path $InstallDir 'teams-supercopy.ps1')) { Remove-Item $InstallDir -Recurse -Force }
