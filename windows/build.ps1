[CmdletBinding()]
param([switch]$Test,[string]$OutputDir)
# Builds TeamsSupercopy.exe with the C# compiler of .NET Framework 4 that every Windows has: one exe, no runtime to
# install. -Test also builds and runs the regressions (tests/SupercopyTests.cs) against the real Windows clipboard.

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$src = Join-Path $root 'src'
$framework = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
$compiler = Join-Path $framework 'csc.exe'
if (-not (Test-Path $compiler)) { throw 'The Windows .NET Framework 4.x compiler is required.' }
$output = if ($OutputDir) { $OutputDir } else { Join-Path $root 'bin' }
New-Item -ItemType Directory -Force -Path $output | Out-Null
$icon = Join-Path (Split-Path $root -Parent) 'assets\icon.ico'
$references = @('System.dll', 'System.Core.dll', 'System.Drawing.dll', 'System.Windows.Forms.dll', 'System.Management.dll')
$references += @('WindowsBase.dll', 'UIAutomationClient.dll', 'UIAutomationTypes.dll') | ForEach-Object { Join-Path $framework "WPF\$_" }
# codepage 65001: the sources are UTF-8 without BOM, and the quote pattern holds "è"
$common = @('/nologo', '/warn:4', '/warnaserror+', '/optimize+', '/platform:x64', '/langversion:5', '/codepage:65001')
$common += $references | ForEach-Object { "/reference:$_" }
$sources = Get-ChildItem $src -Filter '*.cs' | Sort-Object Name | Select-Object -ExpandProperty FullName
$exe = Join-Path $output 'TeamsSupercopy.exe'
& $compiler @common /target:winexe "/out:$exe" "/win32icon:$icon" "/win32manifest:$src\app.manifest" @sources
if ($LASTEXITCODE -ne 0) { throw 'Application compilation failed.' }
if ($Test) {
    & $compiler @common /target:exe "/out:$output\TeamsSupercopy.Tests.exe" "/reference:$exe" (Join-Path $root 'tests\SupercopyTests.cs')
    if ($LASTEXITCODE -ne 0) { throw 'Test compilation failed.' }
    & (Join-Path $output 'TeamsSupercopy.Tests.exe')
    if ($LASTEXITCODE -ne 0) { throw 'Regression tests failed.' }
}
[pscustomobject]@{ executable = $exe; bytes = (Get-Item $exe).Length; version = (Get-Item $exe).VersionInfo.FileVersion } | ConvertTo-Json -Compress
