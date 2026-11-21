// The listener: one STA thread that owns the hotkeys, the clipboard listener and the Ctrl+Shift+C hook, and handles
// each event in turn. Ctrl+C in Teams: the copy is replaced with the full one when it matches messages. Ctrl+Shift+C:
// plain copy in native Teams; Shift + Copy also bypasses enrichment. Ctrl+Alt+C: selected messages, or the message
// under the mouse if nothing is selected. Ctrl+Alt+Shift+C: every message loaded in the open chat.
using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Threading;
using System.Windows.Forms;

namespace TeamsSupercopy
{
    public static class Listener
    {
        static Thread thread;
        static uint lastClipSeq;

        public static string LogPath
        {
            get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"TeamsSupercopy\teams-supercopy.log"); }
        }

        public static void Log(string line)
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(LogPath));
                File.AppendAllText(LogPath, DateTime.Now.ToString("s") + " " + line + Environment.NewLine);
            }
            catch { }
        }

        public static bool Running { get { return thread != null && thread.IsAlive; } }

        // stopped is called on the listener thread when it ends on its own (not after Stop), with the reason
        public static void Start(Action<string> stopped)
        {
            if (Running) return;
            thread = new Thread(delegate() { Run(stopped); });
            thread.SetApartmentState(ApartmentState.STA);
            thread.IsBackground = true;
            thread.Start();
        }

        public static void Stop()
        {
            Thread t = thread;
            if (t == null) return;
            Native.RequestStop();
            if (!t.Join(5000)) Log("listener did not stop within 5 s");
            thread = null;
        }

        static void Run(Action<string> stopped)
        {
            string reason = null;
            Copy.Log = Log;
            Copy.Notice = ShowNotice;
            try
            {
                const uint MOD_ALT = 1, MOD_CTRL = 2, MOD_SHIFT = 4, VK_C = 0x43;
                if (!Native.Register(1, MOD_CTRL | MOD_ALT, VK_C)) throw new InvalidOperationException("Ctrl+Alt+C is already registered by another program");
                if (!Native.Register(2, MOD_CTRL | MOD_ALT | MOD_SHIFT, VK_C)) throw new InvalidOperationException("Ctrl+Alt+Shift+C is already registered by another program");
                if (!Native.WatchClipboard()) throw new InvalidOperationException("cannot listen to clipboard changes");
                lastClipSeq = Native.GetClipboardSequenceNumber();
                Copy.PlainClipSeq = 0;
                WarmUp();
                if (!Native.WatchPlainCopy()) throw new InvalidOperationException("cannot listen for plain-copy shortcut");
                Log("listener ready v" + App.Version + ": native Teams scope, Shift bypass and Ctrl+Shift+C; pid=" + Process.GetCurrentProcess().Id);
                reason = Loop();
            }
            catch (Exception e) { reason = e.Message; }
            finally { Native.Shutdown(); }
            if (reason != null)
            {
                Log("listener stopped: " + reason);
                stopped(reason);
            }
            else Log("listener stopped: turned off");
        }

        // the first UI Automation read and formatting pass are about a second slower than
        // the following ones; do them once now so the first real copy is not the slow one
        static void WarmUp()
        {
            try
            {
                var warm = Copy.ReadMessages();
                Copy.SelectByClipboardText(warm, "warm up", 0);
                if (warm.Count > 0) Copy.CfHtml(Copy.Format(warm.GetRange(warm.Count - 1, 1)).Html);
                Copy.CachedImage("0-weu-d00-00000000000000000000000000000000");
                new DataObject();
                new Form().Dispose();
            }
            catch { }
        }

        // null when stopped on request, otherwise why the loop ended
        static string Loop()
        {
            while (true)
            {
                int hk = Native.WaitHotkey();
                if (hk == Native.Stopped) return null;
                if (hk == -1) return "WM_QUIT received";
                if (hk < 0) return "GetMessage failed";
                Copy.HotkeyClock = Stopwatch.StartNew();
                Copy.Marks.Clear();
                try { Handle(hk); }
                catch (Exception e)
                {
                    Log("error: " + e.Message);
                    System.Media.SystemSounds.Hand.Play();
                    try { ShowNotice("Teams Supercopy: error, see the log (tray menu, Open log)", false); } catch { }
                }
            }
        }

        static void Handle(int hk)
        {
            if (hk == Native.ClipboardChanged)
            {
                // several updates can queue up for one copy; handle each clipboard state once
                uint seqNow = Native.GetClipboardSequenceNumber();
                if (Native.EventSequence != seqNow) return;
                if (seqNow == lastClipSeq) return;
                lastClipSeq = seqNow;
                if (Copy.IsPlainCopyEvent(seqNow)) { Log("Auto bypassed: plain copy"); return; }
                Copy.AutoSequence = seqNow;
                if (Copy.IsTeamsClipboard()) Copy.Invoke("Auto");
                return;
            }
            if (!Copy.TeamsForeground())
            {
                Log("hotkey ignored: Teams is not the active window");
                System.Media.SystemSounds.Asterisk.Play();
                ShowNotice("Teams Supercopy: click into Teams first, it is not the active window", false);
                return;
            }
            if (hk == Native.PlainCopy)
            {
                if (!WaitModifiersUp()) { Log("plain copy ignored: keys held for more than 2 seconds"); return; }
                if (!Copy.TeamsForeground()) return;
                uint seq = Native.GetClipboardSequenceNumber();
                Native.SendCtrlC();
                WaitClipboardChange(seq, 800);
                Copy.PlainClipSeq = Native.GetClipboardSequenceNumber();
                Log("plain Ctrl+Shift+C copied without enrichment");
                return;
            }
            if (hk == 2) { Copy.Invoke("All"); return; }
            if (!WaitModifiersUp())
            {
                Log("hotkey ignored: keys held for more than 2 seconds");
                ShowNotice("Teams Supercopy: release the keys and press again", false);
                return;
            }
            uint before = Native.GetClipboardSequenceNumber();
            Native.SendCtrlC();
            WaitClipboardChange(before, 400);
            // with a selection, Teams' copy reaches the clipboard listener, which enriches it;
            // without one the clipboard does not change and the hovered message is copied
            if (Native.GetClipboardSequenceNumber() == before) Copy.Invoke("Hover");
        }

        static void WaitClipboardChange(uint seq, int ms)
        {
            var sw = Stopwatch.StartNew();
            while (Native.GetClipboardSequenceNumber() == seq && sw.ElapsedMilliseconds < ms) { Application.DoEvents(); Thread.Sleep(20); }
        }

        // Ctrl, Alt, Shift: a synthetic Ctrl+C sent while Shift is still down would reach
        // Teams as Ctrl+Shift+C, which starts an audio call.
        static bool WaitModifiersUp()
        {
            var sw = Stopwatch.StartNew();
            while (sw.ElapsedMilliseconds < 2000)
            {
                Application.DoEvents();
                if ((Native.GetAsyncKeyState(0x10) & 0x8000) == 0 && (Native.GetAsyncKeyState(0x11) & 0x8000) == 0 && (Native.GetAsyncKeyState(0x12) & 0x8000) == 0) return true;
                Thread.Sleep(20);
            }
            return false;
        }

        // Small notice next to the mouse, so a copy that did not happen is visible
        // before the paste. It never takes focus.
        static void ShowNotice(string text, bool ok)
        {
            using (var f = new Form())
            {
                f.FormBorderStyle = FormBorderStyle.None; f.ShowInTaskbar = false; f.StartPosition = FormStartPosition.Manual; f.TopMost = true;
                f.BackColor = ok ? Color.FromArgb(36, 36, 36) : Color.FromArgb(150, 30, 30);
                var l = new Label { Text = text, AutoSize = true, ForeColor = Color.White, Font = new Font("Segoe UI", 10), Padding = new Padding(10, 6, 10, 6) };
                f.Controls.Add(l);
                f.AutoSize = true; f.AutoSizeMode = AutoSizeMode.GrowAndShrink;
                Point p = Cursor.Position;
                f.Location = new Point(p.X + 16, p.Y + 16);
                Native.ShowNoActivate(f.Handle);
                var sw = Stopwatch.StartNew();
                while (sw.ElapsedMilliseconds < 1600) { Application.DoEvents(); Thread.Sleep(30); }
                f.Close();
            }
        }
    }
}
