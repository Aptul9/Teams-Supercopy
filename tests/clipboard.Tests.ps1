$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path $PSScriptRoot) 'teams-supercopy.ps1'
$tokens = $null; $errors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors) { throw ($errors.Message -join '; ') }
$code = [IO.File]::ReadAllText($source)
. ([scriptblock]::Create($code.Substring(0, $code.IndexOf('if ($Once) {'))))
$ImageDir = Join-Path $env:TEMP 'opencode\supercopy-tests-images'

$script:Checks = 0
function Assert($condition, [string]$label) {
    if (-not $condition) { throw "FAIL: $label" }
    $script:Checks++
    Write-Output "PASS: $label"
}
function Set-Event([string]$name, $value) {
    $property = [TeamsCopyNative].GetProperty($name)
    $property.SetValue($null, $value)
}
function Set-Fixture([string]$url, [bool]$html = $true) {
    $d = [System.Windows.Forms.DataObject]::new()
    $d.SetData('UnicodeText', 'shared phrase')
    $d.SetData('Chromium internal source URL', [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($url + [char]0)))
    if ($html) { $d.SetData('HTML Format', '<p>shared phrase</p>') }
    [System.Windows.Forms.Clipboard]::SetDataObject($d, $true)
}

# Preserve every clipboard format before exercising the real Windows clipboard.
$saved = [System.Windows.Forms.DataObject]::new()
$original = [System.Windows.Forms.Clipboard]::GetDataObject()
if ($original) {
    foreach ($format in $original.GetFormats($false)) {
        $value = $original.GetData($format, $false)
        if ($value -is [IO.MemoryStream]) { $value = [IO.MemoryStream]::new($value.ToArray()) }
        if ($null -ne $value) { $saved.SetData($format, $false, $value) }
    }
}
try {
    $fixtureWindow = [System.Windows.Forms.Form]::new()
    $fixtureHandle = $fixtureWindow.Handle
    $script:Foreground = $true
    function Test-TeamsForeground { $script:Foreground }
    function Get-TeamsWindow { [pscustomobject]@{ MainWindowHandle = $fixtureHandle } }
    function Show-Notice { }
    function Write-Log { param($line) }
    Set-Event EventForeground $fixtureHandle
    Set-Event EventOwnerRoot $fixtureHandle

    Set-Fixture 'https://teams.microsoft.com/v2/'
    Assert (Test-TeamsClipboard) 'native Teams rich clipboard accepted'
    $script:Foreground = $false
    Assert (-not (Test-TeamsClipboard)) 'EverTranscript/browser foreground rejected despite matching text and Teams URL'
    $script:Foreground = $true
    Set-Event EventForeground ([IntPtr]456)
    Assert (-not (Test-TeamsClipboard)) 'copy captured in another foreground window rejected'
    Set-Event EventForeground $fixtureHandle
    Set-Event EventOwnerRoot ([IntPtr]456)
    Assert (-not (Test-TeamsClipboard)) 'clipboard owned by another app rejected'
    Set-Event EventOwnerRoot $fixtureHandle
    Set-Fixture 'https://teams.microsoft.com/v2/' $false
    Assert (-not (Test-TeamsClipboard)) 'plain-text transcript rejected even inside native window'
    Set-Fixture 'https://example.com/'
    Assert (-not (Test-TeamsClipboard)) 'non-Teams source rejected'
    Set-Fixture 'https://teams.microsoft.com.evil.example/'
    Assert (-not (Test-TeamsClipboard)) 'lookalike Teams source rejected'
    foreach ($hostName in 'teams.microsoft.com', 'teams.cloud.microsoft', 'teams.live.com') {
        Set-Fixture "https://$hostName/v2/"
        Assert (Test-TeamsClipboard) "$hostName accepted"
    }

    $message = [pscustomobject]@{ Norm = 'shared phrase'; Chat = 'Fixture'; Author = 'Author'; Time = [datetime]'2026-11-03T12:00:00'; Parts = @([pscustomobject]@{ Kind = 'text'; Text = 'shared phrase' }) }
    $messages = @([pscustomobject]@{ Norm = 'earlier unrelated message' }, $message)
    Assert (@(Select-ByClipboardText $messages 'shared phrase').Count -eq 1) 'matching regression fixture resolves real message'
    function Get-TeamsMessages { $messages }
    $script:HotkeyClock = [Diagnostics.Stopwatch]::StartNew()
    $script:Marks = @()
    $script:AutoSequence = [TeamsCopyNative]::GetClipboardSequenceNumber()
    Invoke-Copy Auto
    Assert ([System.Windows.Forms.Clipboard]::GetText().StartsWith('Teams chat: Fixture')) 'accepted copy produces enriched clipboard through full formatting path'
    Assert (-not (Test-TeamsClipboard)) 'enriched copy cannot retrigger itself'

    $script:PlainClipSeq = [uint32]55
    Set-Event EventShift $false
    Assert (Test-PlainCopyEvent 55) 'Ctrl+Shift+C bypass tracks the exact clipboard sequence'
    Assert (-not (Test-PlainCopyEvent 56)) 'plain-copy bypass does not leak into the next copy'
    Set-Event EventShift $true
    Assert (Test-PlainCopyEvent 56) 'Shift held during Copy bypasses enrichment'
    Set-Event EventShift $false
    Assert (-not (Test-PlainCopyEvent 56)) 'Shift release restores normal enrichment'

    Set-Fixture 'https://teams.microsoft.com/v2/'
    $script:AutoSequence = [TeamsCopyNative]::GetClipboardSequenceNumber()
    [System.Windows.Forms.Clipboard]::SetText('newer user copy')
    Out-Result (Format-Messages @($message)) Auto
    Assert ([System.Windows.Forms.Clipboard]::GetText() -eq 'newer user copy') 'pending enrichment never overwrites newer clipboard'
    $script:AutoSequence = [TeamsCopyNative]::GetClipboardSequenceNumber()
    $script:Foreground = $false
    Out-Result (Format-Messages @($message)) Auto
    Assert ([System.Windows.Forms.Clipboard]::GetText() -eq 'newer user copy') 'pending enrichment cancelled after foreground changes'
} finally {
    if ($fixtureWindow) { $fixtureWindow.Dispose() }
    [System.Windows.Forms.Clipboard]::SetDataObject($saved, $true)
}
Write-Output "$script:Checks checks passed"
