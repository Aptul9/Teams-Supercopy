[CmdletBinding()]
param([string]$OutputDirectory=(Join-Path (Split-Path $PSScriptRoot -Parent) 'artifacts\release'),[string]$BinDir='')
# Portable download: TeamsSupercopy-Windows-x64.zip with the one exe, and beside it TeamsSupercopy-Windows-x64.json
# {version, sha256, bytes, commit, file}, which the products page reads. tools/installer.ps1 adds "setup" to the JSON.
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$root=Split-Path $PSScriptRoot -Parent
$bin=if($BinDir){$BinDir}else{Join-Path $root 'bin'}
$exe=Join-Path $bin 'TeamsSupercopy.exe'
$version=[Reflection.AssemblyName]::GetAssemblyName($exe).Version.ToString(3)
$commit=git -C $root rev-parse HEAD
if($LASTEXITCODE -ne 0){throw 'Source commit unavailable.'}
New-Item -ItemType Directory -Force $OutputDirectory|Out-Null
$name='TeamsSupercopy-Windows-x64'
$archive=Join-Path $OutputDirectory "$name.zip"
if(Test-Path $archive){throw "Archive already exists; use a new output directory: $archive"}
$zip=[IO.Compression.ZipFile]::Open($archive,[IO.Compression.ZipArchiveMode]::Create)
try{[void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip,$exe,'TeamsSupercopy.exe',[IO.Compression.CompressionLevel]::Optimal)}finally{$zip.Dispose()}
$hash=(Get-FileHash $archive).Hash.ToLowerInvariant()
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'SHA256SUMS.txt'),"$hash  $name.zip`n",[Text.Encoding]::ASCII)
$meta=[ordered]@{version=$version;sha256=$hash;bytes=(Get-Item $archive).Length;commit=$commit;file="$name.zip"}
[IO.File]::WriteAllText((Join-Path $OutputDirectory "$name.json"),($meta|ConvertTo-Json -Compress)+"`n",[Text.UTF8Encoding]::new($false))
[pscustomobject]@{archive=$archive;version=$version;commit=$commit;bytes=$meta.bytes}|ConvertTo-Json -Compress
