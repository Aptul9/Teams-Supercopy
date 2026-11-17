# Packs the native Windows listener into TeamsSupercopy-Windows.zip (install.ps1 installs from the extracted folder) and
# writes next to it TeamsSupercopy-Windows.json {version, sha256, bytes, commit, file}, the file the services products page reads.
[CmdletBinding()]
param([string]$OutputDirectory = (Join-Path (Split-Path $PSScriptRoot -Parent) '.release\windows'))
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$name = 'TeamsSupercopy-Windows'
$files = 'teams-supercopy.ps1', 'install.ps1', 'uninstall.ps1', 'assets/icon.ico', 'README.md'

$version = [regex]::Match((Get-Content (Join-Path $root 'teams-supercopy.ps1') -Raw), "(?m)^\`$SupercopyVersion = '(\d+\.\d+\.\d+)'").Groups[1].Value
if (-not $version) { throw '$SupercopyVersion not found in teams-supercopy.ps1' }
$commit = git -C $root rev-parse HEAD
if ($LASTEXITCODE -ne 0) { throw 'Source commit unavailable.' }

New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
$archive = Join-Path $OutputDirectory "$name.zip"
if (Test-Path $archive) { throw "Archive already exists; use a new output directory: $archive" }
$stage = Join-Path $OutputDirectory ('stage-' + [guid]::NewGuid().ToString('N'))
foreach ($file in $files) {
    $target = Join-Path $stage $file
    New-Item -ItemType Directory -Force (Split-Path $target -Parent) | Out-Null
    Copy-Item (Join-Path $root $file) $target
}
$listed = @($files | Sort-Object | ForEach-Object {
    $path = Join-Path $stage $_
    [ordered]@{ path = $_; bytes = (Get-Item $path).Length; sha256 = (Get-FileHash $path).Hash.ToLowerInvariant() }
})
[ordered]@{ version = $version; commit = $commit; files = $listed } |
    ConvertTo-Json -Depth 5 | Set-Content (Join-Path $stage 'package-manifest.json') -Encoding utf8

Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($stage, $archive, [IO.Compression.CompressionLevel]::Optimal, $false)
Remove-Item $stage -Recurse -Force

$hash = (Get-FileHash $archive).Hash.ToLowerInvariant()
$bytes = (Get-Item $archive).Length
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'SHA256SUMS.txt'), "$hash  $name.zip`n", [Text.Encoding]::ASCII)
$meta = [ordered]@{ version = $version; sha256 = $hash; bytes = $bytes; commit = $commit; file = "$name.zip" }
[IO.File]::WriteAllText((Join-Path $OutputDirectory "$name.json"), ($meta | ConvertTo-Json -Compress) + "`n", [Text.UTF8Encoding]::new($false))
$meta | ConvertTo-Json -Compress
