[CmdletBinding()]
param([Parameter(Mandatory)][string]$Archive)
# The portable download as a user gets it: JSON against ZIP, the ZIP holds the exe and nothing else, then the extracted
# exe runs from a new folder. Checks: the listener logs "listener ready v<version>", no visible window, a second launch
# leaves the first one alone, --close-running ends it through its own exit path.
$ErrorActionPreference='Stop'
$Archive=(Resolve-Path $Archive).Path
$name=[IO.Path]::GetFileNameWithoutExtension($Archive)
$meta=Get-Content (Join-Path (Split-Path $Archive -Parent) "$name.json") -Raw|ConvertFrom-Json
$keys=($meta.PSObject.Properties.Name|Sort-Object) -join ','
if($keys -notin 'bytes,commit,file,sha256,version','bytes,commit,file,setup,sha256,version'){throw "JSON fields are $keys"}
$hash=(Get-FileHash $Archive).Hash.ToLowerInvariant()
if($meta.sha256 -ne $hash){throw "JSON sha256 $($meta.sha256) differs from the ZIP $hash"}
if([long]$meta.bytes -ne (Get-Item $Archive).Length){throw 'JSON bytes differ from the ZIP'}
if($meta.file -ne [IO.Path]::GetFileName($Archive)){throw "JSON file $($meta.file) is not the ZIP name"}
if($meta.commit -notmatch '^[0-9a-f]{40}$'){throw "JSON commit $($meta.commit) is not a commit sha"}
if($meta.version -notmatch '^\d+\.\d+\.\d+$'){throw "JSON version $($meta.version) is not major.minor.patch"}
if(Get-Process TeamsSupercopy -ErrorAction SilentlyContinue){throw 'Teams Supercopy is running; exit it first (the test needs the single instance and the log).'}

$work=Join-Path ([IO.Path]::GetTempPath()) ('teams-supercopy-test-'+[guid]::NewGuid().ToString('N'))
$out=Join-Path $work 'portable folder'
$log=Join-Path $env:LOCALAPPDATA 'TeamsSupercopy\teams-supercopy.log'
$app=$null
function Wait-Test([string]$Label,[scriptblock]$Condition,[int]$Seconds=30){$until=[DateTime]::UtcNow.AddSeconds($Seconds);do{if(& $Condition){return};Start-Sleep -Milliseconds 250}while([DateTime]::UtcNow -lt $until);throw "Timed out: $Label"}
function Log-Since([int]$from){if(Test-Path $log){@(Get-Content $log)|Select-Object -Skip $from}else{@()}}
try{
    Expand-Archive $Archive $out
    $files=@(Get-ChildItem $out -Recurse -File)
    if($files.Count -ne 1 -or $files[0].Name -ne 'TeamsSupercopy.exe'){throw "ZIP holds $($files.Name -join ', ')"}
    $exe=$files[0].FullName
    $version=[Reflection.AssemblyName]::GetAssemblyName($exe).Version.ToString(3)
    if($version -ne $meta.version){throw "exe $version, JSON $($meta.version)"}

    $start=if(Test-Path $log){@(Get-Content $log).Count}else{0}
    $app=Start-Process $exe -ArgumentList '--startup' -PassThru
    Wait-Test 'listener ready' {(Log-Since $start) -match [regex]::Escape("listener ready v$version")}
    $ready=@(Log-Since $start) -match 'listener ready'|Select-Object -Last 1
    Start-Sleep -Seconds 1
    if($app.HasExited){throw "exited with $($app.ExitCode)"}
    Add-Type -Namespace TeamsSupercopyTest -Name Win -MemberDefinition @'
public delegate bool EnumProc(IntPtr h, IntPtr l);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr l);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
'@
    $visible=0
    $null=[TeamsSupercopyTest.Win]::EnumWindows({param($h,$l) $p=[uint32]0;$null=[TeamsSupercopyTest.Win]::GetWindowThreadProcessId($h,[ref]$p);if($p -eq $app.Id -and [TeamsSupercopyTest.Win]::IsWindowVisible($h)){$script:visible++};$true},[IntPtr]::Zero)
    if($visible){throw "$visible visible windows"}

    $second=Start-Process $exe -ArgumentList '--startup' -PassThru -Wait
    if($second.ExitCode -ne 0){throw "second launch exit $($second.ExitCode)"}
    if($app.HasExited){throw 'second launch ended the first'}
    if(@(Get-Process TeamsSupercopy -ErrorAction SilentlyContinue).Count -ne 1){throw 'more than one Teams Supercopy running'}

    $close=Start-Process $exe -ArgumentList '--close-running' -PassThru -Wait
    if($close.ExitCode -ne 0){throw "--close-running exit $($close.ExitCode)"}
    Wait-Test 'exited' {$app.HasExited} 10
    if($app.ExitCode -ne 0){throw "exit code $($app.ExitCode)"}
    if(-not ((Log-Since $start) -match 'listener stopped: turned off')){throw 'no clean listener stop in the log'}

    [pscustomobject]@{version=$version;pid=$app.Id;log=$ready;secondLaunch='exit 0, first kept';close='exit 0, listener stopped: turned off'}|ConvertTo-Json -Compress
    "package ok: $($meta.file) $version $hash"
}finally{
    if($app -and -not $app.HasExited){Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue}
    Start-Sleep -Milliseconds 300
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
