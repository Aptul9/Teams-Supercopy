<#
Copy Microsoft Teams (new client) messages with author, time, quoted messages and images.

Teams' own copy keeps only the message text. Author, time and quotes are read from
the UI Automation tree of the Teams window, raw view (elements author-<id>,
content-<id>, message-body-<id>; <id> is the message arrival time in epoch ms).
Images are read from the Teams WebView2 HTTP cache. The clipboard gets plain text
and HTML with the images embedded.

Listener mode, the default:
  Ctrl+C in Teams   the copy is replaced with the full one when it matches messages
  Ctrl+Shift+C      plain copy in native Teams; Shift + Copy also bypasses enrichment
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

# the one version of the native listener: the download package and its JSON read it from here
$SupercopyVersion = '1.0.0'

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
    [DllImport("user32.dll")] static extern IntPtr GetClipboardOwner();
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr h, uint flags);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr p, EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr h, int i, int v);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    delegate bool EnumProc(IntPtr h, IntPtr l);

    // Shows a window as a topmost tool window without taking focus from Teams.
    public static void ShowNoActivate(IntPtr h) {
        SetWindowLong(h, -20, GetWindowLong(h, -20) | 0x08000000 | 0x00000080 | 0x00000008);
        ShowWindow(h, 4);
        SetWindowPos(h, new IntPtr(-1), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010);
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct WNDCLASS { public uint style; public IntPtr lpfnWndProc; public int cbClsExtra; public int cbWndExtra; public IntPtr hInstance; public IntPtr hIcon; public IntPtr hCursor; public IntPtr hbrBackground; public string lpszMenuName; public string lpszClassName; }
    delegate IntPtr WndProc(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern ushort RegisterClassW(ref WNDCLASS wc);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateWindowExW(int ex, string cls, string name, int style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
    [DllImport("user32.dll")] static extern IntPtr DefWindowProcW(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern bool TranslateMessage(ref MSG m);
    [DllImport("user32.dll")] static extern IntPtr DispatchMessageW(ref MSG m);
    [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandleW(IntPtr name);

    // Hotkeys go to a hidden window, not to the thread queue: COM calls
    // (UI Automation, clipboard) and DoEvents pump messages, and a WM_HOTKEY posted
    // to the thread with no window is dropped there. Sent to a window it reaches
    // HotkeyProc whoever pumps, and waits in the queue until the listener is free.
    static readonly Queue<int> pending = new Queue<int>();
    static WndProc proc;
    static IntPtr hotkeyWindow;
    [DllImport("user32.dll")] static extern bool AddClipboardFormatListener(IntPtr h);
    [DllImport("user32.dll")] static extern bool PostMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct PROCESSENTRY32 { public uint size, usage, pid; public UIntPtr heap; public uint module, threads, parent; public int priority; public uint flags; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string name; }
    [DllImport("kernel32.dll")] static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32FirstW(IntPtr snapshot, ref PROCESSENTRY32 entry);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32NextW(IntPtr snapshot, ref PROCESSENTRY32 entry);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    public static bool OwnerBelongsToWindow(IntPtr owner, IntPtr window) {
        uint source, target;
        GetWindowThreadProcessId(owner, out source); GetWindowThreadProcessId(window, out target);
        if (source == 0 || target == 0) return false;
        if (source == target) return true;
        // WebView2 owns the clipboard through a hidden top-level window. Its
        // process ancestry, rather than its window ancestry, leads back to Teams.
        var snapshot = CreateToolhelp32Snapshot(2, 0);
        if (snapshot == new IntPtr(-1)) return false;
        try {
            var parents = new Dictionary<uint, uint>();
            var e = new PROCESSENTRY32 { size = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32)) };
            if (Process32FirstW(snapshot, ref e)) do { parents[e.pid] = e.parent; } while (Process32NextW(snapshot, ref e));
            for (int depth = 0; depth < 16 && parents.TryGetValue(source, out source); depth++) {
                if (source == target) return true;
                if (source == 0) break;
            }
            return false;
        } finally { CloseHandle(snapshot); }
    }
    public const int ClipboardChanged = 100;
    public const int PlainCopy = 3;
    public static uint EventSequence { get; private set; }
    public static IntPtr EventForeground { get; private set; }
    public static IntPtr EventOwnerRoot { get; private set; }
    public static bool EventShift { get; private set; }
    struct ClipboardEvent { public uint Sequence; public IntPtr Foreground; public IntPtr OwnerRoot; public bool Shift; }
    static readonly Queue<ClipboardEvent> clipboardEvents = new Queue<ClipboardEvent>();
    static IntPtr HotkeyProc(IntPtr h, uint msg, IntPtr w, IntPtr l) {
        if (msg == 0x0312) { lock (pending) pending.Enqueue((int)w); return IntPtr.Zero; }
        if (msg == 0x031D) {
            lock (pending) {
                clipboardEvents.Enqueue(new ClipboardEvent { Sequence = GetClipboardSequenceNumber(), Foreground = GetForegroundWindow(), OwnerRoot = GetAncestor(GetClipboardOwner(), 2), Shift = (GetAsyncKeyState(0x10) & 0x8000) != 0 });
                pending.Enqueue(ClipboardChanged);
            }
            return IntPtr.Zero;
        }
        return DefWindowProcW(h, msg, w, l);
    }
    delegate IntPtr KeyboardProc(int code, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern IntPtr SetWindowsHookExW(int id, KeyboardProc callback, IntPtr module, uint thread);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr w, IntPtr l);
    static KeyboardProc keyboardProc;
    static IntPtr keyboardHook;
    static readonly System.Threading.ManualResetEvent hookReady = new System.Threading.ManualResetEvent(false);
    static bool plainKeyDown;
    static bool IsNativeTeamsForeground() {
        uint pid;
        GetWindowThreadProcessId(GetForegroundWindow(), out pid);
        try { using (var p = System.Diagnostics.Process.GetProcessById((int)pid)) return p.ProcessName == "ms-teams"; }
        catch { return false; }
    }
    static IntPtr OnKeyboard(int code, IntPtr w, IntPtr l) {
        if (code >= 0 && Marshal.ReadInt32(l) == 0x43) {
            int msg = (int)w;
            if (plainKeyDown) {
                if (msg == 0x101 || msg == 0x105) plainKeyDown = false;
                return new IntPtr(1);
            }
            if ((msg == 0x100 || msg == 0x104) &&
                (GetAsyncKeyState(0x11) & 0x8000) != 0 && (GetAsyncKeyState(0x10) & 0x8000) != 0 && (GetAsyncKeyState(0x12) & 0x8000) == 0 && IsNativeTeamsForeground()) {
                plainKeyDown = true;
                lock (pending) pending.Enqueue(PlainCopy);
                // Low-level hooks run inside GetMessage without making it return.
                PostMessageW(hotkeyWindow, 0x8001, IntPtr.Zero, IntPtr.Zero);
                return new IntPtr(1);
            }
        }
        return CallNextHookEx(keyboardHook, code, w, l);
    }
    public static bool WatchPlainCopy() {
        // UI Automation and image reads must not stall the hook: Windows silently
        // removes a low-level hook when its installing thread stops pumping.
        var thread = new System.Threading.Thread(() => {
            keyboardProc = OnKeyboard;
            keyboardHook = SetWindowsHookExW(13, keyboardProc, GetModuleHandleW(IntPtr.Zero), 0);
            hookReady.Set();
            if (keyboardHook != IntPtr.Zero) { MSG m; while (GetMessage(out m, IntPtr.Zero, 0, 0) > 0) {} }
        });
        thread.IsBackground = true;
        thread.Start();
        hookReady.WaitOne();
        return keyboardHook != IntPtr.Zero;
    }
    // WM_CLIPBOARDUPDATE arrives through the same queue as the hotkeys.
    public static bool WatchClipboard() { return hotkeyWindow != IntPtr.Zero && AddClipboardFormatListener(hotkeyWindow); }
    public static bool Register(int id, uint mod, uint vk) {
        if (hotkeyWindow == IntPtr.Zero) {
            proc = HotkeyProc;
            var wc = new WNDCLASS { lpfnWndProc = Marshal.GetFunctionPointerForDelegate(proc), hInstance = GetModuleHandleW(IntPtr.Zero), lpszClassName = "TeamsSupercopyHotkeys" };
            RegisterClassW(ref wc);
            // a top-level window that is never shown: a message-only window (HWND_MESSAGE)
            // gets the hotkeys but not WM_CLIPBOARDUPDATE
            hotkeyWindow = CreateWindowExW(0x00000080, "TeamsSupercopyHotkeys", "", 0, 0, 0, 0, 0, IntPtr.Zero, IntPtr.Zero, wc.hInstance, IntPtr.Zero);
            if (hotkeyWindow == IntPtr.Zero) return false;
        }
        return RegisterHotKey(hotkeyWindow, id, mod | 0x4000, vk);
    }

    // Blocks until a hotkey press is queued; returns its id.
    public static int WaitHotkey() {
        while (true) {
            lock (pending) {
                if (pending.Count > 0) {
                    int id = pending.Dequeue();
                    if (id == ClipboardChanged) {
                        var e = clipboardEvents.Dequeue();
                        EventSequence = e.Sequence; EventForeground = e.Foreground; EventOwnerRoot = e.OwnerRoot; EventShift = e.Shift;
                    }
                    return id;
                }
            }
            MSG m;
            if (GetMessage(out m, IntPtr.Zero, 0, 0) <= 0) return -1;
            TranslateMessage(ref m);
            DispatchMessageW(ref m);
        }
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
$script:HotkeyClock = [Diagnostics.Stopwatch]::StartNew()

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

# UIA names a hyperlink "Link <url>"; the clipboard has the bare url, so the label
# is dropped or a message with a link never matches its own copy.
function Remove-LinkLabel([string]$s) { $s -replace '(?i)\blink\s+(?=https?://)', '' }

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
        $content = Remove-LinkLabel $content

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
    if ($bestScore -eq 0) { return @() }
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
$script:CacheDirs = $null
function Get-CachedImage([string]$objectId) {
    # resolving the wildcard costs ~150 ms, so the folders are looked up once
    if (-not $script:CacheDirs) {
        $script:CacheDirs = @(Get-Item (Join-Path $TeamsCache '*\Cache\Cache_Data') -ErrorAction SilentlyContinue |
            Where-Object { [IO.File]::Exists((Join-Path $_.FullName 'data_1')) })
    }
    foreach ($dir in $script:CacheDirs) {
        $idx = Join-Path $dir.FullName 'data_1'
        if (-not [IO.File]::Exists($idx)) { $script:CacheDirs = $null; continue }
        $d1 = Read-Shared $idx
        $s = [Text.Encoding]::ASCII.GetString($d1)
        $hits = @()
        $i = 0
        while (($i = $s.IndexOf("objects/$objectId/views/", $i, [StringComparison]::Ordinal)) -ge 0) { $hits += $i; $i++ }
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
                    # block files run to several MB; read only the entry's bytes
                    $blockSize = @{ 2 = 256; 3 = 1024; 4 = 4096 }[[int]$type]
                    $fs = [IO.File]::Open((Join-Path $dir.FullName ('data_{0}' -f (($addr -shr 16) -band 0xFF))), 'Open', 'Read', 'ReadWrite, Delete')
                    try {
                        [void]$fs.Seek(8192 + [long]($addr -band 0xFFFF) * $blockSize, 'Begin')
                        $b = [byte[]]::new($size); $got = 0
                        while ($got -lt $size) { $r = $fs.Read($b, $got, $size - $got); if ($r -le 0) { break }; $got += $r }
                    } finally { $fs.Close() }
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
    [pscustomobject]@{ Text = $txt.ToString().TrimEnd() + [Environment]::NewLine; Html = $html.ToString(); Count = $msgs.Count; Images = $n }
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

function Write-Log([string]$line) {
    Add-Content -Path (Join-Path $PSScriptRoot 'teams-supercopy.log') -Value ('{0:s} {1}' -f (Get-Date), $line)
}

# Small notice next to the mouse, so a copy that did not happen is visible
# before the paste. It never takes focus.
function Show-Notice([string]$text, [bool]$ok) {
    if ($Stdout) { return }
    $f = New-Object System.Windows.Forms.Form
    $f.FormBorderStyle = 'None'; $f.ShowInTaskbar = $false; $f.StartPosition = 'Manual'; $f.TopMost = $true
    $f.BackColor = if ($ok) { [System.Drawing.Color]::FromArgb(36, 36, 36) } else { [System.Drawing.Color]::FromArgb(150, 30, 30) }
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.AutoSize = $true; $l.ForeColor = [System.Drawing.Color]::White
    $l.Font = New-Object System.Drawing.Font('Segoe UI', 10); $l.Padding = New-Object System.Windows.Forms.Padding(10, 6, 10, 6)
    $f.Controls.Add($l)
    $f.AutoSize = $true; $f.AutoSizeMode = 'GrowAndShrink'
    $p = [System.Windows.Forms.Cursor]::Position
    $f.Location = New-Object System.Drawing.Point(($p.X + 16), ($p.Y + 16))
    [TeamsCopyNative]::ShowNoActivate($f.Handle)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 1600) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 30 }
    $f.Close(); $f.Dispose()
}

function Out-Result($r, [string]$mode) {
    if (-not $r) {
        Write-Log "$mode -> no matching message"
        # an automatic pass on a copy that is not messages (text from the compose box,
        # a link, an image) leaves Teams' copy alone without complaining
        if ($Stdout -or $mode -eq 'Auto') { return }
        [System.Media.SystemSounds]::Asterisk.Play()
        Show-Notice $(if ($mode -eq 'Hover') { 'Teams Supercopy: no message under the mouse' } else { 'Teams Supercopy: selection not matched, clipboard left as Teams copied it' }) $false
        return
    }
    $what = '{0} message{1}' -f $r.Count, $(if ($r.Count -ne 1) { 's' })
    if ($r.Images) { $what += ', {0} image{1}' -f $r.Images, $(if ($r.Images -ne 1) { 's' }) }
    if ($Stdout) { Write-Log "$mode -> $what"; return $r.Text }
    $d = New-Object System.Windows.Forms.DataObject
    $d.SetData([System.Windows.Forms.DataFormats]::UnicodeText, $r.Text)
    $d.SetData([System.Windows.Forms.DataFormats]::Html, (New-Object IO.MemoryStream (, (ConvertTo-CfHtml $r.Html))))
    if ($mode -eq 'Auto' -and ($script:AutoSequence -ne [TeamsCopyNative]::GetClipboardSequenceNumber() -or -not (Test-TeamsForeground) -or [TeamsCopyNative]::GetAsyncKeyState(0x10) -band 0x8000)) {
        Write-Log 'Auto skipped: clipboard, foreground or Shift changed'
        return
    }
    [System.Windows.Forms.Clipboard]::SetDataObject($d, $true)
    Write-Log ('{0} -> {1} ({2} ms from hotkey to clipboard; {3})' -f $mode, $what, $script:HotkeyClock.ElapsedMilliseconds, ($script:Marks -join ', '))
    Show-Notice "Teams Supercopy: $what copied" $true
}

function Invoke-Copy([string]$mode) {
    switch ($mode) {
        'All' { Out-Result (Format-Messages (Get-TeamsMessages)) $mode }
        'Hover' { Out-Result (Format-Messages (Select-Hovered (Get-TeamsMessages))) $mode }
        { $_ -in 'Selection', 'Auto' } {
            $clip = [System.Windows.Forms.Clipboard]::GetText()
            $script:Marks += 'text read {0}' -f $script:HotkeyClock.ElapsedMilliseconds
            $msgs = Get-TeamsMessages
            $script:Marks += 'chat read {0}' -f $script:HotkeyClock.ElapsedMilliseconds
            Out-Result (Format-Messages (Select-ByClipboardText $msgs $clip)) $mode
        }
    }
}

# A copy made inside Teams carries the page URL in a Chromium clipboard format;
# the special copy written by this script does not, so it never re-triggers itself.
function Test-TeamsClipboard {
    try {
        if (-not (Test-TeamsForeground)) { return $false }
        $window = (Get-TeamsWindow).MainWindowHandle
        if ([TeamsCopyNative]::EventForeground -ne $window -or -not [TeamsCopyNative]::OwnerBelongsToWindow([TeamsCopyNative]::EventOwnerRoot, $window)) {
            Write-Log "Auto ignored: source window mismatch (foreground=$([TeamsCopyNative]::EventForeground), owner=$([TeamsCopyNative]::EventOwnerRoot), Teams=$window)"
            return $false
        }
        # EverTranscript writes plain text. Only native rich message copies qualify.
        if (-not [System.Windows.Forms.Clipboard]::ContainsData('HTML Format')) { return $false }
        $u = [System.Windows.Forms.Clipboard]::GetData('Chromium internal source URL')
        if ($u -is [IO.MemoryStream]) { $u = [Text.Encoding]::UTF8.GetString($u.ToArray()).Trim([char]0) }
        "$u" -match '^https://teams\.(microsoft\.com|cloud\.microsoft|live\.com)/'
    } catch { $false }
}

function Test-TeamsForeground {
    $pid_ = [uint32]0
    [void][TeamsCopyNative]::GetWindowThreadProcessId([TeamsCopyNative]::GetForegroundWindow(), [ref]$pid_)
    (Get-Process -Id $pid_ -ErrorAction SilentlyContinue).ProcessName -eq 'ms-teams'
}

function Test-PlainCopyEvent([uint32]$sequence) {
    $sequence -eq $script:PlainClipSeq -or [TeamsCopyNative]::EventShift -or ([TeamsCopyNative]::GetAsyncKeyState(0x10) -band 0x8000)
}

function Wait-ModifiersUp {
    # Ctrl, Alt, Shift: a synthetic Ctrl+C sent while Shift is still down would reach
    # Teams as Ctrl+Shift+C, which starts an audio call.
    $deadline = (Get-Date).AddSeconds(2)
    while ((Get-Date) -lt $deadline) {
        [System.Windows.Forms.Application]::DoEvents()
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
if (-not [TeamsCopyNative]::WatchClipboard()) { throw 'cannot listen to clipboard changes' }
$script:LastClipSeq = [TeamsCopyNative]::GetClipboardSequenceNumber()
$script:PlainClipSeq = [uint32]0

# the first UI Automation read and formatting pass are about a second slower than
# the following ones; do them once now so the first real copy is not the slow one
try {
    $warm = @(Get-TeamsMessages)
    $null = Select-ByClipboardText $warm 'warm up'
    $null = ConvertTo-CfHtml (Format-Messages ($warm | Select-Object -Last 1)).Html
    $null = Get-CachedImage '0-weu-d00-00000000000000000000000000000000'
    $null = New-Object System.Windows.Forms.DataObject
    (New-Object System.Windows.Forms.Form).Dispose()
} catch {}

if (-not [TeamsCopyNative]::WatchPlainCopy()) { throw 'cannot listen for plain-copy shortcut' }
Write-Log "listener ready v${SupercopyVersion}: native Teams scope, Shift bypass and Ctrl+Shift+C; pid=$PID"
while ($true) {
    $hk = [TeamsCopyNative]::WaitHotkey()
    if ($hk -lt 0) { break }
    $script:HotkeyClock = [Diagnostics.Stopwatch]::StartNew()
    $script:Marks = @()
    try {
        if ($hk -eq [TeamsCopyNative]::ClipboardChanged) {
            # several updates can queue up for one copy; handle each clipboard state once
            $seqNow = [TeamsCopyNative]::GetClipboardSequenceNumber()
            if ([TeamsCopyNative]::EventSequence -ne $seqNow) { continue }
            if ($seqNow -eq $script:LastClipSeq) { continue }
            $script:LastClipSeq = $seqNow
            if (Test-PlainCopyEvent $seqNow) {
                Write-Log 'Auto bypassed: plain copy'
                continue
            }
            $script:AutoSequence = $seqNow
            if (Test-TeamsClipboard) { Invoke-Copy 'Auto' }
            continue
        }
        if (-not (Test-TeamsForeground)) {
            Write-Log 'hotkey ignored: Teams is not the active window'
            [System.Media.SystemSounds]::Asterisk.Play()
            Show-Notice 'Teams Supercopy: click into Teams first, it is not the active window' $false
            continue
        }
        if ($hk -eq [TeamsCopyNative]::PlainCopy) {
            if (-not (Wait-ModifiersUp)) { Write-Log 'plain copy ignored: keys held for more than 2 seconds'; continue }
            if (-not (Test-TeamsForeground)) { continue }
            $seq = [TeamsCopyNative]::GetClipboardSequenceNumber()
            [TeamsCopyNative]::SendCtrlC()
            $deadline = (Get-Date).AddMilliseconds(800)
            while ([TeamsCopyNative]::GetClipboardSequenceNumber() -eq $seq -and (Get-Date) -lt $deadline) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 20 }
            $script:PlainClipSeq = [TeamsCopyNative]::GetClipboardSequenceNumber()
            Write-Log 'plain Ctrl+Shift+C copied without enrichment'
            continue
        }
        if ($hk -eq 2) { Invoke-Copy 'All'; continue }
        if (-not (Wait-ModifiersUp)) {
            Write-Log 'hotkey ignored: keys held for more than 2 seconds'
            Show-Notice 'Teams Supercopy: release the keys and press again' $false
            continue
        }
        $seq = [TeamsCopyNative]::GetClipboardSequenceNumber()
        [TeamsCopyNative]::SendCtrlC()
        $deadline = (Get-Date).AddMilliseconds(400)
        while ([TeamsCopyNative]::GetClipboardSequenceNumber() -eq $seq -and (Get-Date) -lt $deadline) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 20 }
        # with a selection, Teams' copy reaches the clipboard listener, which enriches it;
        # without one the clipboard does not change and the hovered message is copied
        if ([TeamsCopyNative]::GetClipboardSequenceNumber() -eq $seq) { Invoke-Copy 'Hover' }
    } catch {
        Write-Log "error: $_"
        [System.Media.SystemSounds]::Hand.Play()
        try { Show-Notice "Teams Supercopy: error, see teams-supercopy.log" $false } catch {}
    }
}
