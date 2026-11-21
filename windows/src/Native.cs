// Win32 side of the listener: hotkeys, clipboard updates and the Ctrl+Shift+C hook all arrive at one hidden window,
// whose queue the listener thread drains with WaitHotkey. C# 5 (csc of .NET Framework 4): no newer syntax.
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace TeamsSupercopy
{
    public static class Native
    {
        [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
        [StructLayout(LayoutKind.Sequential)] struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public POINT pt; }
        [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
        [StructLayout(LayoutKind.Explicit, Size = 40)] struct INPUT { [FieldOffset(0)] public uint type; [FieldOffset(8)] public KEYBDINPUT ki; }

        [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr hWnd, int id, uint mod, uint vk);
        [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hWnd, int id);
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
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
        [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr h, int i, int v);
        [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
        [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
        delegate bool EnumProc(IntPtr h, IntPtr l);

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct WNDCLASS { public uint style; public IntPtr lpfnWndProc; public int cbClsExtra; public int cbWndExtra; public IntPtr hInstance; public IntPtr hIcon; public IntPtr hCursor; public IntPtr hbrBackground; public string lpszMenuName; public string lpszClassName; }
        delegate IntPtr WndProc(IntPtr h, uint msg, IntPtr w, IntPtr l);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern ushort RegisterClassW(ref WNDCLASS wc);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateWindowExW(int ex, string cls, string name, int style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
        [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr h);
        [DllImport("user32.dll")] static extern IntPtr DefWindowProcW(IntPtr h, uint msg, IntPtr w, IntPtr l);
        [DllImport("user32.dll")] static extern bool TranslateMessage(ref MSG m);
        [DllImport("user32.dll")] static extern IntPtr DispatchMessageW(ref MSG m);
        [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandleW(IntPtr name);
        [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
        [DllImport("user32.dll")] static extern bool PostThreadMessageW(uint thread, uint msg, IntPtr w, IntPtr l);
        [DllImport("user32.dll")] static extern bool AddClipboardFormatListener(IntPtr h);
        [DllImport("user32.dll")] static extern bool RemoveClipboardFormatListener(IntPtr h);
        [DllImport("user32.dll")] static extern bool PostMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);

        // Shows a window as a topmost tool window without taking focus from Teams.
        public static void ShowNoActivate(IntPtr h)
        {
            SetWindowLong(h, -20, GetWindowLong(h, -20) | 0x08000000 | 0x00000080 | 0x00000008);
            ShowWindow(h, 4);
            SetWindowPos(h, new IntPtr(-1), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010);
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct PROCESSENTRY32 { public uint size, usage, pid; public UIntPtr heap; public uint module, threads, parent; public int priority; public uint flags; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string name; }
        [DllImport("kernel32.dll")] static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32FirstW(IntPtr snapshot, ref PROCESSENTRY32 entry);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32NextW(IntPtr snapshot, ref PROCESSENTRY32 entry);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);

        public static bool OwnerBelongsToWindow(IntPtr owner, IntPtr window)
        {
            uint source, target;
            GetWindowThreadProcessId(owner, out source); GetWindowThreadProcessId(window, out target);
            if (source == 0 || target == 0) return false;
            if (source == target) return true;
            // WebView2 owns the clipboard through a hidden top-level window. Its
            // process ancestry, rather than its window ancestry, leads back to Teams.
            IntPtr snapshot = CreateToolhelp32Snapshot(2, 0);
            if (snapshot == new IntPtr(-1)) return false;
            try
            {
                var parents = new Dictionary<uint, uint>();
                var e = new PROCESSENTRY32 { size = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32)) };
                if (Process32FirstW(snapshot, ref e)) do { parents[e.pid] = e.parent; } while (Process32NextW(snapshot, ref e));
                for (int depth = 0; depth < 16 && parents.TryGetValue(source, out source); depth++)
                {
                    if (source == target) return true;
                    if (source == 0) break;
                }
                return false;
            }
            finally { CloseHandle(snapshot); }
        }

        public const int ClipboardChanged = 100;
        public const int PlainCopy = 3;
        public const int Stopped = -3;
        public static uint EventSequence { get; set; }
        public static IntPtr EventForeground { get; set; }
        public static IntPtr EventOwnerRoot { get; set; }
        public static bool EventShift { get; set; }
        struct ClipboardEvent { public uint Sequence; public IntPtr Foreground; public IntPtr OwnerRoot; public bool Shift; }

        // Hotkeys go to a hidden window, not to the thread queue: COM calls
        // (UI Automation, clipboard) and DoEvents pump messages, and a WM_HOTKEY posted
        // to the thread with no window is dropped there. Sent to a window it reaches
        // HotkeyProc whoever pumps, and waits in the queue until the listener is free.
        static readonly Queue<int> pending = new Queue<int>();
        static readonly Queue<ClipboardEvent> clipboardEvents = new Queue<ClipboardEvent>();
        static WndProc proc;
        static IntPtr hotkeyWindow;
        static bool classRegistered;
        static volatile bool stopRequested;

        static IntPtr HotkeyProc(IntPtr h, uint msg, IntPtr w, IntPtr l)
        {
            if (msg == 0x0312) { lock (pending) pending.Enqueue((int)w); return IntPtr.Zero; }
            if (msg == 0x031D)
            {
                lock (pending)
                {
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
        [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr hook);
        static KeyboardProc keyboardProc;
        static IntPtr keyboardHook;
        static uint hookThreadId;
        static Thread hookThread;
        static bool plainKeyDown;

        public static bool IsNativeTeamsForeground()
        {
            uint pid;
            GetWindowThreadProcessId(GetForegroundWindow(), out pid);
            try { using (var p = System.Diagnostics.Process.GetProcessById((int)pid)) return p.ProcessName == "ms-teams"; }
            catch { return false; }
        }

        static IntPtr OnKeyboard(int code, IntPtr w, IntPtr l)
        {
            if (code >= 0 && Marshal.ReadInt32(l) == 0x43)
            {
                int msg = (int)w;
                if (plainKeyDown)
                {
                    if (msg == 0x101 || msg == 0x105) plainKeyDown = false;
                    return new IntPtr(1);
                }
                if ((msg == 0x100 || msg == 0x104) &&
                    (GetAsyncKeyState(0x11) & 0x8000) != 0 && (GetAsyncKeyState(0x10) & 0x8000) != 0 && (GetAsyncKeyState(0x12) & 0x8000) == 0 && IsNativeTeamsForeground())
                {
                    plainKeyDown = true;
                    lock (pending) pending.Enqueue(PlainCopy);
                    // Low-level hooks run inside GetMessage without making it return.
                    PostMessageW(hotkeyWindow, 0x8001, IntPtr.Zero, IntPtr.Zero);
                    return new IntPtr(1);
                }
            }
            return CallNextHookEx(keyboardHook, code, w, l);
        }

        public static bool WatchPlainCopy()
        {
            // UI Automation and image reads must not stall the hook: Windows silently
            // removes a low-level hook when its installing thread stops pumping.
            var ready = new ManualResetEvent(false);
            hookThread = new Thread(delegate()
            {
                hookThreadId = GetCurrentThreadId();
                keyboardProc = OnKeyboard;
                keyboardHook = SetWindowsHookExW(13, keyboardProc, GetModuleHandleW(IntPtr.Zero), 0);
                ready.Set();
                if (keyboardHook == IntPtr.Zero) return;
                MSG m;
                while (GetMessage(out m, IntPtr.Zero, 0, 0) > 0) { }
                UnhookWindowsHookEx(keyboardHook);
                keyboardHook = IntPtr.Zero;
            });
            hookThread.IsBackground = true;
            hookThread.Start();
            ready.WaitOne();
            return keyboardHook != IntPtr.Zero;
        }

        // WM_CLIPBOARDUPDATE arrives through the same queue as the hotkeys.
        public static bool WatchClipboard() { return hotkeyWindow != IntPtr.Zero && AddClipboardFormatListener(hotkeyWindow); }

        public static bool Register(int id, uint mod, uint vk)
        {
            if (hotkeyWindow == IntPtr.Zero)
            {
                proc = HotkeyProc;
                var wc = new WNDCLASS { lpfnWndProc = Marshal.GetFunctionPointerForDelegate(proc), hInstance = GetModuleHandleW(IntPtr.Zero), lpszClassName = "TeamsSupercopyHotkeys" };
                if (!classRegistered) classRegistered = RegisterClassW(ref wc) != 0;
                // a top-level window that is never shown: a message-only window (HWND_MESSAGE)
                // gets the hotkeys but not WM_CLIPBOARDUPDATE
                hotkeyWindow = CreateWindowExW(0x00000080, "TeamsSupercopyHotkeys", "", 0, 0, 0, 0, 0, IntPtr.Zero, IntPtr.Zero, wc.hInstance, IntPtr.Zero);
                if (hotkeyWindow == IntPtr.Zero) return false;
            }
            return RegisterHotKey(hotkeyWindow, id, mod | 0x4000, vk);
        }

        // Blocks until a hotkey press is queued; returns its id. -1 WM_QUIT, -2 GetMessage failed, Stopped after RequestStop.
        public static int WaitHotkey()
        {
            while (true)
            {
                if (stopRequested) return Stopped;
                lock (pending)
                {
                    if (pending.Count > 0)
                    {
                        int id = pending.Dequeue();
                        if (id == ClipboardChanged)
                        {
                            var e = clipboardEvents.Dequeue();
                            EventSequence = e.Sequence; EventForeground = e.Foreground; EventOwnerRoot = e.OwnerRoot; EventShift = e.Shift;
                        }
                        return id;
                    }
                }
                MSG m;
                int r = GetMessage(out m, IntPtr.Zero, 0, 0);
                if (r <= 0) return r == 0 ? -1 : -2;
                TranslateMessage(ref m);
                DispatchMessageW(ref m);
            }
        }

        // Called from another thread: the listener returns Stopped from WaitHotkey at its next wake-up.
        public static void RequestStop()
        {
            stopRequested = true;
            if (hotkeyWindow != IntPtr.Zero) PostMessageW(hotkeyWindow, 0x8002, IntPtr.Zero, IntPtr.Zero);
        }

        // Called on the listener thread when it ends: everything it registered goes, so a new listener can register again
        // and, while Supercopy is off, Ctrl+Shift+C and the Ctrl+Alt hotkeys reach Teams and other apps untouched.
        public static void Shutdown()
        {
            if (hookThread != null)
            {
                PostThreadMessageW(hookThreadId, 0x0012, IntPtr.Zero, IntPtr.Zero);
                hookThread.Join(2000);
                hookThread = null;
            }
            if (hotkeyWindow != IntPtr.Zero)
            {
                UnregisterHotKey(hotkeyWindow, 1);
                UnregisterHotKey(hotkeyWindow, 2);
                RemoveClipboardFormatListener(hotkeyWindow);
                DestroyWindow(hotkeyWindow);
                hotkeyWindow = IntPtr.Zero;
            }
            lock (pending) { pending.Clear(); clipboardEvents.Clear(); }
            plainKeyDown = false;
            stopRequested = false;
        }

        public static void SendCtrlC()
        {
            var i = new INPUT[4];
            ushort[] vk = { 0x11, 0x43, 0x43, 0x11 };
            uint[] fl = { 0, 0, 2, 2 };
            for (int k = 0; k < 4; k++) { i[k].type = 1; i[k].ki.wVk = vk[k]; i[k].ki.dwFlags = fl[k]; }
            SendInput(4, i, Marshal.SizeOf(typeof(INPUT)));
        }

        public static string WindowTitle(IntPtr h) { var s = new StringBuilder(512); GetWindowTextW(h, s, 512); return s.ToString(); }

        static string ClassName(IntPtr h) { var s = new StringBuilder(64); GetClassNameW(h, s, 64); return s.ToString(); }

        // Teams has several top-level windows (main, pop-out chats, toasts); every
        // visible TeamsWebView window of ms-teams can hold a chat.
        public static bool IsTeamsWindow(IntPtr h)
        {
            if (h == IntPtr.Zero || !IsWindowVisible(h)) return false;
            if (ClassName(h) != "TeamsWebView") return false;
            uint pid; GetWindowThreadProcessId(h, out pid);
            try { using (var p = System.Diagnostics.Process.GetProcessById((int)pid)) return p.ProcessName == "ms-teams"; }
            catch { return false; }
        }

        // Visible Teams windows, topmost first.
        public static List<IntPtr> TeamsWindows()
        {
            var r = new List<IntPtr>();
            EnumWindows(delegate(IntPtr h, IntPtr l) { if (IsTeamsWindow(h)) r.Add(h); return true; }, IntPtr.Zero);
            return r;
        }

        public static List<IntPtr> RenderWindows(IntPtr top)
        {
            var r = new List<IntPtr>();
            EnumChildWindows(top, delegate(IntPtr h, IntPtr l)
            {
                if (ClassName(h) == "Chrome_RenderWidgetHostHWND" && IsWindowVisible(h)) r.Add(h);
                return true;
            }, IntPtr.Zero);
            return r;
        }
    }
}
