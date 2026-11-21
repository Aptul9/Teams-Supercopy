[CmdletBinding()]
param(
    [string]$OutputDirectory=(Join-Path (Split-Path $PSScriptRoot -Parent) 'artifacts\release'),
    [string]$Compiler=''
)
# Builds TeamsSupercopy-Windows-x64-Setup.exe from the tested portable ZIP in OutputDirectory (tools/package.ps1), so the
# installer carries exactly the ZIP's exe, then adds it to TeamsSupercopy-Windows-x64.json as "setup" and to SHA256SUMS.txt.
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing,System.IO.Compression.FileSystem
$root=Split-Path $PSScriptRoot -Parent
$repo=Split-Path $root -Parent
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
$archive=Join-Path $OutputDirectory 'TeamsSupercopy-Windows-x64.zip'
$metaPath=Join-Path $OutputDirectory 'TeamsSupercopy-Windows-x64.json'
$setupName='TeamsSupercopy-Windows-x64-Setup.exe'
$setup=Join-Path $OutputDirectory $setupName
if(Test-Path $setup){throw "Installer already exists; use a new output directory: $setup"}
if(-not $Compiler){
    $Compiler=@($env:ISCC,(Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),(Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'),(Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'))|Where-Object{$_ -and (Test-Path $_)}|Select-Object -First 1
}
if(-not $Compiler){throw 'Inno Setup 6 compiler (ISCC.exe) not found.'}
$meta=Get-Content $metaPath -Raw|ConvertFrom-Json
if((Get-FileHash $archive).Hash.ToLowerInvariant() -ne $meta.sha256){throw 'ZIP does not match its JSON.'}
$work=Join-Path $OutputDirectory ('installer-'+[guid]::NewGuid().ToString('N'))
$payload=Join-Path $work 'payload'
$assets=Join-Path $work 'assets'
New-Item -ItemType Directory -Force $payload,$assets|Out-Null
[IO.Compression.ZipFile]::ExtractToDirectory($archive,$payload)
$exeVersion=[Reflection.AssemblyName]::GetAssemblyName((Join-Path $payload 'TeamsSupercopy.exe')).Version.ToString(3)
if($exeVersion -ne $meta.version){throw "Version mismatch: json $($meta.version), exe $exeVersion."}

# wizard pictures in the icon's colours, as EverTranscript Windows does with its own
function Save-Picture([string]$Path,[int]$Width,[int]$Height,[double]$IconShare){
    $bitmap=[Drawing.Bitmap]::new($Width,$Height,[Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $g=[Drawing.Graphics]::FromImage($bitmap)
    $g.SmoothingMode='AntiAlias';$g.InterpolationMode='HighQualityBicubic';$g.TextRenderingHint='AntiAliasGridFit'
    $g.Clear([Drawing.ColorTranslator]::FromHtml('#1B1530'))
    $icon=[Drawing.Image]::FromFile((Join-Path $repo 'assets\icon.png'))
    $size=[int]([Math]::Min($Width,$Height)*$IconShare)
    $top=if($Height -gt $Width*1.5){[int]($Height*0.18)}else{[int](($Height-$size)/2)}
    $g.DrawImage($icon,[int](($Width-$size)/2),$top,$size,$size)
    if($Height -gt $Width*1.5){
        $accent=[Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml('#8B7BF0'))
        $g.FillRectangle($accent,[int]($Width*0.2),[int]($top+$size+$Height*0.05),[int]($Width*0.6),[Math]::Max(2,[int]($Height/160)))
        $font=[Drawing.Font]::new('Segoe UI Semibold',[float]($Width/11.5),[Drawing.GraphicsUnit]::Pixel)
        $format=[Drawing.StringFormat]::new();$format.Alignment='Center'
        $white=[Drawing.SolidBrush]::new([Drawing.Color]::White)
        $g.DrawString("Teams`nSupercopy",$font,$white,[Drawing.RectangleF]::new(0,[float]($top+$size+$Height*0.09),$Width,$Height/3),$format)
    }
    $icon.Dispose();$g.Dispose()
    $bitmap.Save($Path,[Drawing.Imaging.ImageFormat]::Bmp);$bitmap.Dispose()
}
Save-Picture (Join-Path $assets 'wizard-100.bmp') 164 314 0.55
Save-Picture (Join-Path $assets 'wizard-200.bmp') 328 628 0.55
Save-Picture (Join-Path $assets 'wizard-small-100.bmp') 55 55 0.8
Save-Picture (Join-Path $assets 'wizard-small-200.bmp') 110 110 0.8

& $Compiler /Q "/DAppVersion=$($meta.version)" "/DPayloadDir=$payload" "/DAssetsDir=$assets" "/DIconFile=$(Join-Path $repo 'assets\icon.ico')" "/O$OutputDirectory" (Join-Path $root 'installer\TeamsSupercopy.iss')
if($LASTEXITCODE -ne 0){throw "Inno Setup compiler failed ($LASTEXITCODE)."}
if(-not (Test-Path $setup)){throw 'Installer not produced.'}
Remove-Item $work -Recurse -Force

$setupHash=(Get-FileHash $setup).Hash.ToLowerInvariant()
$setupBytes=(Get-Item $setup).Length
$update=[ordered]@{}
foreach($property in $meta.PSObject.Properties){$update[$property.Name]=$property.Value}
$update['setup']=[ordered]@{file=$setupName;sha256=$setupHash;bytes=$setupBytes}
[IO.File]::WriteAllText($metaPath,($update|ConvertTo-Json -Compress -Depth 4)+"`n",[Text.UTF8Encoding]::new($false))
[IO.File]::AppendAllText((Join-Path $OutputDirectory 'SHA256SUMS.txt'),$setupHash+'  '+$setupName+"`n",[Text.Encoding]::ASCII)
[pscustomobject]@{setup=$setup;version=$meta.version;sha256=$setupHash;bytes=$setupBytes}|ConvertTo-Json -Compress
