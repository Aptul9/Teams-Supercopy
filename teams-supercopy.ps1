<#
Copy Microsoft Teams (new client) messages with author, time and the quoted reply.

Teams' own copy keeps only the message text. Author, time and quotes are read from
the UI Automation tree of the Teams window, raw view (elements author-<id>,
content-<id>, message-body-<id>; <id> is the message arrival time in epoch ms).

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

$QuoteRx = [regex]'(?s)^(?:Inizio citazione|Begin quote|Start of quote|Quote), (.+?), (\d{1,2}/\d{1,2}/\d{2,4},? \d{1,2}[:.]\d{2}(?:\s?[AP]M)?), (.*?), (?:fine citazione|end quote|end of quote)\s*'

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
    for ($i = 0; $i -lt $nodes.Count; $i++) {
        $aid = $nodes[$i].Cached.AutomationId
        if ($aid -notmatch '^(content|message-body|author-trust-label|author|timestamp)-(\d{10,})$') { continue }
        $kind, $id = $Matches[1], $Matches[2]
        if (-not $byId.Contains($id)) { $byId[$id] = @{ Labels = @() } }
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

        $quote = $null
        $text = $content
        $q = $QuoteRx.Match($content)
        if ($q.Success) {
            $quote = [pscustomobject]@{ Author = $q.Groups[1].Value; Time = $q.Groups[2].Value; Text = $q.Groups[3].Value }
            $text = $content.Substring($q.Length)
        }

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
            Text   = $text.Trim()
            Quote  = $quote
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

function Format-Messages($msgs) {
    $msgs = @($msgs)
    if (-not $msgs) { return $null }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("Teams chat: $($msgs[0].Chat)")
    [void]$sb.AppendLine()
    foreach ($m in $msgs) {
        [void]$sb.AppendLine(('[{0:yyyy-MM-dd HH:mm}] {1}' -f $m.Time, $m.Author))
        if ($m.Quote) {
            [void]$sb.AppendLine(('> in reply to {0} ({1}): {2}' -f $m.Quote.Author, $m.Quote.Time, $m.Quote.Text))
        }
        [void]$sb.AppendLine($(if ($m.Text) { $m.Text } else { '(no text: attachment, image or card)' }))
        [void]$sb.AppendLine()
    }
    $sb.ToString().TrimEnd() + [Environment]::NewLine
}

function Out-Result([string]$text) {
    if (-not $text) { [System.Media.SystemSounds]::Asterisk.Play(); return }
    if ($Stdout) { $text } else { [System.Windows.Forms.Clipboard]::SetText($text) }
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
