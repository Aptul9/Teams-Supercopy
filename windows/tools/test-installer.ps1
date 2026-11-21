[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Setup,
    [string]$OutputDir=(Join-Path ([IO.Path]::GetTempPath()) ('teams-supercopy-installer-'+[guid]::NewGuid().ToString('N')))
)
# Silent install, reinstall and uninstall of the per-user installer into a test folder, as EverTranscript Windows tests
# its own. The Start with Windows value is the real HKCU Run value: saved first, put back exactly as it was at the end.
# Start menu shortcut and uninstall entry are the real per-user ones and go away with the test uninstall.
$ErrorActionPreference='Stop'
$Setup=(Resolve-Path $Setup).Path
New-Item -ItemType Directory -Force $OutputDir|Out-Null
$OutputDir=[IO.Path]::GetFullPath($OutputDir)
$install=Join-Path $OutputDir 'install dir'
$exe=Join-Path $install 'TeamsSupercopy.exe'
$runKey='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$runName='TeamsSupercopy'
$shortcut=Join-Path ([Environment]::GetFolderPath('Programs')) 'Teams Supercopy.lnk'
$log=Join-Path $env:LOCALAPPDATA 'TeamsSupercopy\teams-supercopy.log'
$results=[ordered]@{}
if(Get-Process TeamsSupercopy -ErrorAction SilentlyContinue){throw 'Teams Supercopy is running; exit it first.'}
if(Test-Path $shortcut){throw "A Start menu shortcut already exists: $shortcut"}
$saved=(Get-ItemProperty $runKey -ErrorAction SilentlyContinue).$runName
$app=$null;$step=0
function Wait-Test([string]$Label,[scriptblock]$Condition,[int]$Seconds=60){$until=[DateTime]::UtcNow.AddSeconds($Seconds);do{if(& $Condition){return};Start-Sleep -Milliseconds 250}while([DateTime]::UtcNow -lt $until);throw "Timed out: $Label"}
function Run-Value{(Get-ItemProperty $runKey -ErrorAction SilentlyContinue).$runName}
function Uninstall-Entry{Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue|Where-Object{(Get-ItemProperty $_.PSPath).InstallLocation -and [IO.Path]::GetFullPath((Get-ItemProperty $_.PSPath).InstallLocation).TrimEnd('\') -eq $install}|Select-Object -First 1}
function Install([string]$Startup){
    $script:step++
    $setupLog=Join-Path $OutputDir "setup-$script:step.log"
    $p=Start-Process $Setup -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',"/DIR=`"$install`"","/STARTUP=$Startup","/LOG=`"$setupLog`"" -Wait -PassThru
    if($p.ExitCode -ne 0){throw "Setup exit $($p.ExitCode), log $setupLog"}
}
try{
    # 1. Start with Windows on
    Install 1
    $files=@(Get-ChildItem $install -File|Where-Object Name -notlike 'unins*')
    if($files.Count -ne 1 -or $files[0].Name -ne 'TeamsSupercopy.exe'){throw "Installed files: $($files.Name -join ', ')"}
    $version=[Reflection.AssemblyName]::GetAssemblyName($exe).Version.ToString(3)
    $results.version=$version
    $target=(New-Object -ComObject WScript.Shell).CreateShortcut($shortcut).TargetPath
    if($target -ne $exe){throw "Start menu shortcut points to $target."}
    $entry=Uninstall-Entry
    if(-not $entry){throw 'No per-user uninstall entry.'}
    if((Get-ItemProperty $entry.PSPath).DisplayVersion -ne $version){throw 'Uninstall entry version differs.'}
    if((Run-Value) -ne "`"$exe`" --startup"){throw "Run value: $(Run-Value)"}
    $results.installOn='exe only, Start menu shortcut, uninstall entry, Run value'

    # 2. installed copy running in the tray: a reinstall closes it through its own exit path, startup off
    $start=if(Test-Path $log){@(Get-Content $log).Count}else{0}
    $app=Start-Process $exe -ArgumentList '--startup' -PassThru
    Wait-Test 'app started' {(Test-Path $log) -and (@(Get-Content $log)|Select-Object -Skip $start) -match 'listener ready'} 45
    Install 0
    Wait-Test 'running app closed' {$app.HasExited} 15
    if($app.ExitCode -ne 0){throw "App exit code $($app.ExitCode): not its normal exit."}
    if($null -ne (Run-Value)){throw 'Run value left after turning startup off.'}
    $results.reinstallOff='running copy closed (exit 0), Run value removed'

    # 3. on again, then uninstall: program, shortcut, entry and own Run value go
    Install 1
    if((Run-Value) -ne "`"$exe`" --startup"){throw 'Startup on not written.'}
    Start-Process (Join-Path $install 'unins000.exe') -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART' -Wait|Out-Null
    Wait-Test 'uninstalled' {-not (Test-Path $exe) -and -not (Uninstall-Entry)} 90
    if(Test-Path $install){throw "Install folder left: $(@(Get-ChildItem $install -Recurse -Force|ForEach-Object Name) -join ', ')"}
    if(Test-Path $shortcut){throw 'Start menu shortcut left.'}
    if($null -ne (Run-Value)){throw 'Run value of the removed copy left.'}
    $results.uninstall='folder, shortcut, entry and own Run value removed'

    # 4. a Run value starting another copy survives the uninstall
    Install 0
    $foreign='"C:\Altra copia\TeamsSupercopy.exe" --startup'
    Set-ItemProperty $runKey $runName $foreign
    Start-Process (Join-Path $install 'unins000.exe') -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART' -Wait|Out-Null
    Wait-Test 'uninstalled again' {-not (Test-Path $exe) -and -not (Uninstall-Entry)} 90
    if((Run-Value) -ne $foreign){throw 'Run value of another copy removed.'}
    $results.foreignRunValueKept=$true
    $results.passed=$true
    $results|ConvertTo-Json -Compress
}finally{
    if($app -and -not $app.HasExited){Stop-Process -Id $app.Id -ErrorAction SilentlyContinue}
    if(Test-Path (Join-Path $install 'unins000.exe')){Start-Process (Join-Path $install 'unins000.exe') -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART' -Wait|Out-Null}
    if($null -eq $saved){Remove-ItemProperty $runKey $runName -ErrorAction SilentlyContinue}else{Set-ItemProperty $runKey $runName $saved}
    if((Get-ItemProperty $runKey -ErrorAction SilentlyContinue).$runName -ne $saved){Write-Error 'Run value not restored.'}
}
