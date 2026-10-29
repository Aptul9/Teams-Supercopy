<#
Copy Microsoft Teams (new client) messages with author, time, quoted messages and images.

Teams' own copy keeps only the message text. Author, time and quotes are read from
the UI Automation tree of the Teams window, raw view (elements author-<id>,
content-<id>, message-body-<id>; <id> is the message arrival time in epoch ms).
Images are read from the Teams WebView2 HTTP cache. The clipboard gets plain text
and HTML with the images embedded.

Hotkeys (listener mode, the default):
  Ctrl+Alt+C        selected messages, or the message under the mouse if nothing is selected
  Ctrl+Alt+Shift+C  every message loaded in the open chat

One-shot modes, for testing or for calling from another tool:
  -Once Selection   uses the text already on the clipboard as the selection
  -Once All         every loaded message
  -Once Hover       the message under the mouse
  -Stdout           print instead of writing the clipboard
#>
[CmdletBinding()]
param(
    [ValidateSet('Selection', 'All', 'Hover')][string]$Once,
    [switch]$Stdout
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms

Add-Type @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class TeamsCopyNative {
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
    [StructLayout(LayoutKind.Sequential)] struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public POINT pt; }
    [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Explicit, Size = 40)] struct INPUT { [FieldOffset(0)] public uint type; [FieldOffset(8)] public KEYBDINPUT ki; }

    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr hWnd, int id, uint mod, uint vk);
    [DllImport("user32.dll")] static extern int GetMessage(out MSG m, IntPtr hWnd, uint min, uint max);
    [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vk);
    [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr p, EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    delegate bool EnumProc(IntPtr h, IntPtr l);

    public static bool Register(int id, uint mod, uint vk) { return RegisterHotKey(IntPtr.Zero, id, mod | 0x4000, vk); }

    // Blocks on the thread message queue until a registered hotkey fires; returns its id.
    public static int WaitHotkey() {
        MSG m;
        while (GetMessage(out m, IntPtr.Zero, 0, 0) > 0) { if (m.message == 0x0312) return (int)m.wParam; }
        return -1;
    }

    public static void SendCtrlC() {
        var i = new INPUT[4];
        ushort[] vk = { 0x11, 0x43, 0x43, 0x11 };
        uint[] fl = { 0, 0, 2, 2 };
        for (int k = 0; k < 4; k++) { i[k].type = 1; i[k].ki.wVk = vk[k]; i[k].ki.dwFlags = fl[k]; }
        SendInput(4, i, Marshal.SizeOf(typeof(INPUT)));
    }

    public static List<IntPtr> RenderWindows(IntPtr top) {
        var r = new List<IntPtr>();
        EnumChildWindows(top, (h, l) => {
            var s = new StringBuilder(64); GetClassName(h, s, 64);
            if (s.ToString() == "Chrome_RenderWidgetHostHWND" && IsWindowVisible(h)) r.Add(h);
            return true;
        }, IntPtr.Zero);
        return r;
    }
}
'@

$UIA = [System.Windows.Automation.AutomationElement]

function Get-TeamsWindow {
    $p = Get-Process ms-teams -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if (-not $p) { throw 'Teams window not found' }
    $p
}

function Get-ChatTitle([string]$windowTitle) {
    # "Chat | <chat name> | <tenant> | <account> | Microsoft Teams"
    $parts = $windowTitle -split ' \| '
    if ($parts.Count -ge 3) { return $parts[1] }
    $windowTitle
}

function ConvertTo-Norm([string]$s) {
    (($s.ToLowerInvariant() -replace '[^\p{L}\p{N}]+', ' ').Trim())
}

# A message can quote several messages anywhere in its text; each quote reads
# "Inizio citazione, <author>, <date>, <text>, fine citazione", optionally followed by
# the "not verified" notice Teams adds to quotes it cannot link back.
$QuoteRx = [regex]'(?s)(?:Inizio citazione|Begin quote|Start of quote), (.+?), (\d{1,2}/\d{1,2}/\d{2,4},? \d{1,2}[:.]\d{2}(?:\s?[AP]M)?), (.*?), (?:fine citazione|end quote|end of quote)(?:, (?:Questo messaggio citato non è verificato da Teams|This quoted message (?:is not|isn''t) verified by Teams)\.?)?\s*'
$ImageIdRx = [regex]'^x_(\d-[a-z]+-d\d+-[0-9a-f]{32})$'
$TeamsCache = Join-Path $env:LOCALAPPDATA 'Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView'
$ImageDir = Join-Path $env:TEMP 'teams-supercopy'

# Splits message text into an ordered list of text, quote and image parts.
function Split-MessageParts([string]$content, $images) {
    $parts = [System.Collections.Generic.List[object]]::new()
    $pos = 0
    foreach ($q in $QuoteRx.Matches($content)) {
        if ($q.Index -gt $pos) { $parts.Add([pscustomobject]@{ Kind = 'text'; Text = $content.Substring($pos, $q.Index - $pos).Trim() }) }
        $parts.Add([pscustomobject]@{ Kind = 'quote'; Author = $q.Groups[1].Value; Time = $q.Groups[2].Value; Text = $q.Groups[3].Value.Trim() })
        $pos = $q.Index + $q.Length
    }
    if ($pos -lt $content.Length) { $parts.Add([pscustomobject]@{ Kind = 'text'; Text = $content.Substring($pos).Trim() }) }

    # the image alt text is part of the content name; put the image where its alt text is
    foreach ($img in $images) {
        $placed = $false
        for ($i = 0; $i -lt $parts.Count -and -not $placed; $i++) {
            $p = $parts[$i]
            if ($p.Kind -ne 'text' -or -not $img.Alt) { continue }
            $at = $p.Text.IndexOf($img.Alt)
            if ($at -lt 0) { continue }
            $before = $p.Text.Substring(0, $at).Trim(); $after = $p.Text.Substring($at + $img.Alt.Length).Trim()
            $parts.RemoveAt($i)
            $new = @()
            if ($before) { $new += [pscustomobject]@{ Kind = 'text'; Text = $before } }
            $new += [pscustomobject]@{ Kind = 'image'; Image = $img }
            if ($after) { $new += [pscustomobject]@{ Kind = 'text'; Text = $after } }
            $parts.InsertRange($i, [object[]]$new)
            $placed = $true
        }
        if (-not $placed) { $parts.Insert(0, [pscustomobject]@{ Kind = 'image'; Image = $img }) }
    }
    @($parts | Where-Object { $_.Kind -ne 'text' -or $_.Text })
}

# Reads every message currently rendered in the chat pane, in display order.
function Get-TeamsMessages {
    $proc = Get-TeamsWindow
    $cache = New-Object System.Windows.Automation.CacheRequest
    $cache.TreeFilter = [System.Windows.Automation.Automation]::RawViewCondition
    $cache.Add($UIA::AutomationIdProperty)
    $cache.Add($UIA::NameProperty)
    $cache.Add($UIA::BoundingRectangleProperty)
    $listCond = New-Object System.Windows.Automation.PropertyCondition($UIA::AutomationIdProperty, 'chat-pane-list')
    $nodes = @()
    # the raw view is needed: author-<id> and chat-pane-list are not in the control view
    $scope = $cache.Activate()
    try {
        foreach ($h in [TeamsCopyNative]::RenderWindows($proc.MainWindowHandle)) {
            $list = $UIA::FromHandle($h).FindFirst([System.Windows.Automation.TreeScope]::Descendants, $listCond)
            if ($list) { $nodes += @($list.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) }
        }
    } finally { $scope.Dispose() }
    if (-not $nodes) { throw 'No open chat found in the Teams window' }

    $byId = [ordered]@{}
    $current = $null
    for ($i = 0; $i -lt $nodes.Count; $i++) {
        $aid = $nodes[$i].Cached.AutomationId
        # images sit inside content-<id>, so in document order they follow it
        $im = $ImageIdRx.Match($aid)
        if ($im.Success -and $current) {
            $byId[$current].Images += [pscustomobject]@{ ObjectId = $im.Groups[1].Value; Alt = ($nodes[$i].Cached.Name -replace '\s+', ' ').Trim(); Rect = $nodes[$i].Cached.BoundingRectangle }
            continue
        }
        if ($aid -notmatch '^(content|message-body|author-trust-label|author|timestamp)-(\d{10,})$') { continue }
        $kind, $id = $Matches[1], $Matches[2]
        if (-not $byId.Contains($id)) { $byId[$id] = @{ Labels = @(); Images = @() } }
        if ($kind -eq 'content') { $current = $id }
        $name = ($nodes[$i].Cached.Name -replace '\s+', ' ').Trim()
        switch ($kind) {
            'author-trust-label' { $byId[$id].Labels += $name }
            # the author group has no name of its own; its first child is the name text
            'author' { if ($i + 1 -lt $nodes.Count) { $byId[$id]['author'] = ($nodes[$i + 1].Cached.Name -replace '\s+', ' ').Trim() } }
            'message-body' { $byId[$id][$kind] = $name; $byId[$id]['rect'] = $nodes[$i].Cached.BoundingRectangle }
            default { $byId[$id][$kind] = $name }
        }
    }

    $title = Get-ChatTitle $proc.MainWindowTitle
    foreach ($id in $byId.Keys) {
        $m = $byId[$id]
        if (-not $m.Contains('message-body')) { continue }
        $content = if ($m.Contains('content')) { $m['content'] } else { '' }

        $author = $m['author']
        if (-not $author) {
            # fallback: message-body = content + author + trust labels + timestamp (+ read
            # receipt and reactions), so removing the known parts mostly leaves the author
            $author = $m['message-body']
            foreach ($part in @($content, $m['timestamp']) + $m.Labels) {
                if ($part) { $author = $author.Replace($part, ' ') }
            }
            $author = ($author -replace '\s+', ' ').Trim(' ', '.', ',')
        }

        [pscustomobject]@{
            Id     = $id
            Time   = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$id).LocalDateTime
            Author = $author
            Parts  = Split-MessageParts $content $m.Images
            Norm   = ConvertTo-Norm $content
            Chat   = $title
            Rect   = $m['rect']
        }
    }
}

# Maps the lines Teams put on the clipboard back to the messages they came from.
# Lines are matched in order; the starting message with the most matched lines wins,
# so short lines like "ok" do not pull in a match from elsewhere in the chat. On a tie
# the earliest start wins: a quoting message also contains the quoted text, and the
# original is the one the selection started from.
function Select-ByClipboardText($messages, [string]$clip) {
    $lines = @($clip -split '\r?\n' | ForEach-Object { ConvertTo-Norm $_ } | Where-Object { $_.Length -ge 2 })
    if (-not $lines -or -not $messages) { return @() }
    $msgs = @($messages)
    $best = $null; $bestScore = 0
    for ($s = 0; $s -lt $msgs.Count; $s++) {
        if (-not $msgs[$s].Norm.Contains($lines[0])) { continue }
        $hit = [System.Collections.Generic.List[int]]::new()
        $j = $s; $score = 0
        foreach ($l in $lines) {
            for ($k = $j; $k -lt [Math]::Min($msgs.Count, $j + 4); $k++) {
                if ($msgs[$k].Norm.Contains($l)) { $score++; $j = $k; if (-not $hit.Contains($k)) { $hit.Add($k) }; break }
            }
        }
        if ($score -gt $bestScore) { $best = $hit; $bestScore = $score }
    }
    if (-not $best) { return @() }
    foreach ($k in $best) { $msgs[$k] }
}

# UIA FromPoint on the Teams webview returns the whole message pane, not the bubble,
# so the hovered message is found by geometry: the bubble that contains the cursor,
# or else the one nearest to it vertically (cursor in the margin beside a bubble).
function Select-Hovered($messages) {
    $p = New-Object TeamsCopyNative+POINT
    [void][TeamsCopyNative]::GetCursorPos([ref]$p)
    $visible = @($messages | Where-Object { $_.Rect -and -not $_.Rect.IsEmpty -and $_.Rect.Height -gt 0 })
    $inside = $visible | Where-Object { $_.Rect.Contains($p.X, $p.Y) } | Select-Object -First 1
    if ($inside) { return $inside }
    $near = $visible | Where-Object { $p.Y -ge $_.Rect.Top -and $p.Y -le $_.Rect.Bottom } | Select-Object -First 1
    $near
}

function Read-Shared([string]$path) {
    $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite, Delete')
    try { $ms = New-Object IO.MemoryStream; $fs.CopyTo($ms); , $ms.ToArray() } finally { $fs.Close() }
}

function Get-ImageType([byte[]]$b) {
    if ($b.Length -lt 12) { return $null }
    if ($b[0] -eq 0xFF -and $b[1] -eq 0xD8) { return @{ Ext = 'jpg'; Mime = 'image/jpeg' } }
    if ($b[0] -eq 0x89 -and $b[1] -eq 0x50 -and $b[2] -eq 0x4E -and $b[3] -eq 0x47) { return @{ Ext = 'png'; Mime = 'image/png' } }
    if ($b[0] -eq 0x47 -and $b[1] -eq 0x49 -and $b[2] -eq 0x46) { return @{ Ext = 'gif'; Mime = 'image/gif' } }
    if ($b[8] -eq 0x57 -and $b[9] -eq 0x45 -and $b[10] -eq 0x42 -and $b[11] -eq 0x50) { return @{ Ext = 'webp'; Mime = 'image/webp' } }
    $null
}

# Teams downloads images through its WebView2, so the full image is in the Chromium
# HTTP cache (blockfile format) under a key ending in objects/<objectId>/views/<view>.
# Entries are 256-byte blocks in data_1: key_len at +32, data_size[4] at +40,
# data_addr[4] at +56, key at +96; stream 1 is the body.
function Get-CachedImage([string]$objectId) {
    foreach ($dir in Get-Item (Join-Path $TeamsCache '*\Cache\Cache_Data') -ErrorAction SilentlyContinue) {
        $idx = Join-Path $dir.FullName 'data_1'
        if (-not (Test-Path $idx)) { continue }
        $d1 = Read-Shared $idx
        $s = [Text.Encoding]::ASCII.GetString($d1)
        $hits = @()
        $i = 0
        while (($i = $s.IndexOf("objects/$objectId/views/", $i)) -ge 0) { $hits += $i; $i++ }
        # original first, then the largest previews
        $hits = $hits | Sort-Object { $v = $s.Substring($_ + 18 + $objectId.Length, 20); if ($v -like 'imgo*') { 0 } elseif ($v -like 'imgpsh_fullsize*') { 1 } else { 2 } }
        foreach ($hit in $hits) {
            $entry = 8192 + [Math]::Floor(($hit - 8192) / 256) * 256
            while ($entry -gt 8192 -and $s.Substring($entry + 96, 4) -notmatch '^(1/0/|http|_dk_)') { $entry -= 256 }
            $size = [BitConverter]::ToInt32($d1, $entry + 44)
            $addr = [BitConverter]::ToUInt32($d1, $entry + 60)
            if ($size -le 0 -or -not ($addr -band 0x80000000)) { continue }
            $type = ($addr -shr 28) -band 7
            try {
                if ($type -eq 0) {
                    $b = Read-Shared (Join-Path $dir.FullName ('f_{0:x6}' -f ($addr -band 0x0FFFFFFF)))
                } else {
                    $blockSize = @{ 2 = 256; 3 = 1024; 4 = 4096 }[[int]$type]
                    $file = Read-Shared (Join-Path $dir.FullName ('data_{0}' -f (($addr -shr 16) -band 0xFF)))
                    $off = 8192 + ($addr -band 0xFFFF) * $blockSize
                    $b = [byte[]]::new($size); [Array]::Copy($file, $off, $b, 0, $size)
                }
            } catch { continue }
            if ($b.Length -gt $size) { $b = $b[0..($size - 1)] }
            if (Get-ImageType $b) { return , [byte[]]$b }
        }
    }
    $null
}

# Fallback for an image that is not in the cache: grab what is on screen, which is
# the thumbnail size Teams shows in the chat.
function Get-ScreenImage($rect) {
    if (-not $rect -or $rect.IsEmpty -or $rect.Width -lt 8 -or $rect.Height -lt 8) { return $null }
    Add-Type -AssemblyName System.Drawing
    $bmp = New-Object System.Drawing.Bitmap ([int]$rect.Width), ([int]$rect.Height)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.CopyFromScreen([int]$rect.X, [int]$rect.Y, 0, 0, $bmp.Size)
        $ms = New-Object IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        , $ms.ToArray()
    } finally { $g.Dispose(); $bmp.Dispose() }
}

function Save-Image($img) {
    $bytes = Get-CachedImage $img.ObjectId
    $source = 'original'
    if (-not $bytes) { $bytes = Get-ScreenImage $img.Rect; $source = 'screen thumbnail' }
    if (-not $bytes) { return $null }
    $t = Get-ImageType $bytes
    New-Item -ItemType Directory -Force $ImageDir | Out-Null
    $path = Join-Path $ImageDir ('{0}.{1}' -f $img.ObjectId, $t.Ext)
    [IO.File]::WriteAllBytes($path, $bytes)
    [pscustomobject]@{ Path = $path; Mime = $t.Mime; Bytes = $bytes; Source = $source }
}

# Builds the same content twice: plain text (images as [image N] plus the saved
# file path) and HTML with the images embedded, which chat apps such as claude.ai
# paste as text plus image attachments in one go.
function Format-Messages($msgs) {
    $msgs = @($msgs)
    if (-not $msgs) { return $null }
    Get-ChildItem $ImageDir -File -ErrorAction SilentlyContinue | Where-Object LastWriteTime -lt (Get-Date).AddDays(-1) | Remove-Item -ErrorAction SilentlyContinue
    $enc = { param($s) [System.Net.WebUtility]::HtmlEncode($s) }
    $txt = [System.Text.StringBuilder]::new()
    $html = [System.Text.StringBuilder]::new()
    $n = 0
    [void]$txt.AppendLine("Teams chat: $($msgs[0].Chat)").AppendLine()
    [void]$html.Append("<p><b>Teams chat: $(& $enc $msgs[0].Chat)</b></p>")
    foreach ($m in $msgs) {
        $head = '[{0:yyyy-MM-dd HH:mm}] {1}' -f $m.Time, $m.Author
        [void]$txt.AppendLine($head)
        [void]$html.Append("<p><b>$(& $enc $head)</b>")
        if (-not $m.Parts) {
            [void]$txt.AppendLine('(no text: attachment or card)')
            [void]$html.Append('<br>(no text: attachment or card)')
        }
        foreach ($p in $m.Parts) {
            switch ($p.Kind) {
                'text' {
                    [void]$txt.AppendLine($p.Text)
                    [void]$html.Append("<br>$(& $enc $p.Text)")
                }
                'quote' {
                    $q = '> in reply to {0} ({1}): {2}' -f $p.Author, $p.Time, $p.Text
                    [void]$txt.AppendLine($q)
                    [void]$html.Append("<br>$(& $enc $q)")
                }
                'image' {
                    $n++
                    $saved = Save-Image $p.Image
                    if ($saved) {
                        [void]$txt.AppendLine(('[image {0}: {1}, {2}]' -f $n, $saved.Source, $saved.Path))
                        [void]$html.Append(('<br>[image {0}]<br><img alt="" src="data:{1};base64,{2}">' -f $n, $saved.Mime, [Convert]::ToBase64String($saved.Bytes)))
                    } else {
                        [void]$txt.AppendLine("[image ${n}: not available, scroll it into view and copy again]")
                        [void]$html.Append("<br>[image ${n}: not available]")
                    }
                }
            }
        }
        [void]$txt.AppendLine()
        [void]$html.Append('</p>')
    }
    [pscustomobject]@{ Text = $txt.ToString().TrimEnd() + [Environment]::NewLine; Html = $html.ToString() }
}

function ConvertTo-CfHtml([string]$fragment) {
    $pre = "Version:0.9`r`nStartHTML:{0:D10}`r`nEndHTML:{1:D10}`r`nStartFragment:{2:D10}`r`nEndFragment:{3:D10}`r`n"
    $head = '<html><body><!--StartFragment-->'; $tail = '<!--EndFragment--></body></html>'
    $u = [Text.Encoding]::UTF8
    $sh = $u.GetByteCount(($pre -f 0, 0, 0, 0))
    $sf = $sh + $u.GetByteCount($head)
    $ef = $sf + $u.GetByteCount($fragment)
    $eh = $ef + $u.GetByteCount($tail)
    , $u.GetBytes(($pre -f $sh, $eh, $sf, $ef) + $head + $fragment + $tail)
}

function Out-Result($r) {
    if (-not $r) { [System.Media.SystemSounds]::Asterisk.Play(); return }
    if ($Stdout) { return $r.Text }
    $d = New-Object System.Windows.Forms.DataObject
    $d.SetData([System.Windows.Forms.DataFormats]::UnicodeText, $r.Text)
    $d.SetData([System.Windows.Forms.DataFormats]::Html, (New-Object IO.MemoryStream (, (ConvertTo-CfHtml $r.Html))))
    [System.Windows.Forms.Clipboard]::SetDataObject($d, $true)
}

function Invoke-Copy([string]$mode) {
    switch ($mode) {
        'All' { Out-Result (Format-Messages (Get-TeamsMessages)) }
        'Hover' { Out-Result (Format-Messages (Select-Hovered (Get-TeamsMessages))) }
        'Selection' {
            $clip = [System.Windows.Forms.Clipboard]::GetText()
            Out-Result (Format-Messages (Select-ByClipboardText (Get-TeamsMessages) $clip))
        }
    }
}

function Test-TeamsForeground {
    $pid_ = [uint32]0
    [void][TeamsCopyNative]::GetWindowThreadProcessId([TeamsCopyNative]::GetForegroundWindow(), [ref]$pid_)
    (Get-Process -Id $pid_ -ErrorAction SilentlyContinue).ProcessName -eq 'ms-teams'
}

function Wait-ModifiersUp {
    # Ctrl, Alt, Shift: a synthetic Ctrl+C sent while Shift is still down would reach
    # Teams as Ctrl+Shift+C, which starts an audio call.
    $deadline = (Get-Date).AddSeconds(2)
    while ((Get-Date) -lt $deadline) {
        $down = (0x10, 0x11, 0x12) | Where-Object { [TeamsCopyNative]::GetAsyncKeyState($_) -band 0x8000 }
        if (-not $down) { return $true }
        Start-Sleep -Milliseconds 20
    }
    $false
}

if ($Once) { Invoke-Copy $Once; return }

$mutex = New-Object System.Threading.Mutex($false, 'Local\TeamsCopyHotkeys')
if (-not $mutex.WaitOne(0)) { return }

$MOD_ALT = 1; $MOD_CTRL = 2; $MOD_SHIFT = 4; $VK_C = 0x43
if (-not [TeamsCopyNative]::Register(1, $MOD_CTRL -bor $MOD_ALT, $VK_C)) { throw 'Ctrl+Alt+C is already registered by another program' }
if (-not [TeamsCopyNative]::Register(2, $MOD_CTRL -bor $MOD_ALT -bor $MOD_SHIFT, $VK_C)) { throw 'Ctrl+Alt+Shift+C is already registered by another program' }

while ($true) {
    $hk = [TeamsCopyNative]::WaitHotkey()
    if ($hk -lt 0) { break }
    try {
        if (-not (Test-TeamsForeground)) { [System.Media.SystemSounds]::Asterisk.Play(); continue }
        if ($hk -eq 2) { Invoke-Copy 'All'; continue }
        if (-not (Wait-ModifiersUp)) { continue }
        $seq = [TeamsCopyNative]::GetClipboardSequenceNumber()
        [TeamsCopyNative]::SendCtrlC()
        $deadline = (Get-Date).AddMilliseconds(400)
        while ([TeamsCopyNative]::GetClipboardSequenceNumber() -eq $seq -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 20 }
        if ([TeamsCopyNative]::GetClipboardSequenceNumber() -ne $seq) { Invoke-Copy 'Selection' } else { Invoke-Copy 'Hover' }
    } catch {
        [System.Media.SystemSounds]::Hand.Play()
        Add-Content -Path (Join-Path $PSScriptRoot 'teams-supercopy.log') -Value ("{0:s} {1}" -f (Get-Date), $_)
    }
}
