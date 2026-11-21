// Teams Supercopy: one exe, tray icon plus the listener. Left or right click opens the menu, which stays open until
// the icon is clicked again (or Esc). Command line, used by the installer:
//   --close-running                     closes a running copy (and the old PowerShell version); exit 1 if one is still running
//   --install-settings --startup on|off writes Start with Windows for this exe and removes the old version
//   --uninstall-cleanup                 removes Start with Windows (when it starts this exe) and the settings
//   --startup                           started by Windows at sign-in: no welcome notice
using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Management;
using System.Reflection;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

[assembly: AssemblyTitle("Teams Supercopy")]
[assembly: AssemblyProduct("Teams Supercopy")]
[assembly: AssemblyDescription("Copies Microsoft Teams messages with author, time, quotes and images")]
[assembly: AssemblyCompany("Everbright")]
[assembly: AssemblyVersion("1.1.0")]
[assembly: AssemblyFileVersion("1.1.0")]

namespace TeamsSupercopy
{
    public static class App
    {
        const string SettingsKey = @"Software\TeamsSupercopy";
        const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
        const string RunValue = "TeamsSupercopy";
        const string CloseEventName = @"Local\TeamsSupercopyClose";
        const string ShowEventName = @"Local\TeamsSupercopyShow";

        static NotifyIcon tray;
        static ContextMenuStrip menu;
        static Control ui;
        static bool allowClose, exiting;
        static int restarts;
        static DateTime firstRestart;

        public static string Version { get { return Assembly.GetExecutingAssembly().GetName().Version.ToString(3); } }
        static string ExePath { get { return Assembly.GetExecutingAssembly().Location; } }

        [STAThread]
        public static int Main(string[] args)
        {
            if (args.Contains("--close-running")) return CloseRunning() ? 0 : 1;
            if (args.Contains("--install-settings"))
            {
                int i = Array.IndexOf(args, "--startup");
                SetStartup(i >= 0 && i + 1 < args.Length && args[i + 1] == "on");
                RemoveOldVersion();
                return 0;
            }
            if (args.Contains("--uninstall-cleanup"))
            {
                if (StartupEnabled()) SetStartup(false);
                Registry.CurrentUser.DeleteSubKeyTree(SettingsKey, false);
                return 0;
            }

            bool created;
            using (var mutex = new Mutex(true, @"Local\TeamsSupercopy", out created))
            {
                if (!created)
                {
                    // already running: the running copy shows where it is
                    EventWaitHandle show;
                    if (EventWaitHandle.TryOpenExisting(ShowEventName, out show)) { show.Set(); show.Dispose(); }
                    return 0;
                }
                RemoveOldVersion();
                Application.EnableVisualStyles();
                RunTray(!args.Contains("--startup"));
            }
            return 0;
        }

        static void RunTray(bool welcome)
        {
            ui = new Control();
            IntPtr handle = ui.Handle;

            // the menu opens with either mouse button and stays open, through item clicks and clicks
            // elsewhere, until the icon is clicked again (or Esc, or Exit)
            menu = new ContextMenuStrip();
            menu.AutoClose = false;
            menu.Closing += delegate(object sender, ToolStripDropDownClosingEventArgs e)
            {
                if (!allowClose && e.CloseReason != ToolStripDropDownCloseReason.Keyboard) e.Cancel = true;
            };
            menu.Items.Add("Teams Supercopy " + Version).Enabled = false;
            menu.Items.Add(new ToolStripSeparator());
            var enabledItem = new ToolStripMenuItem("Enabled");
            enabledItem.Click += delegate { SetEnabled(IsDisabled()); enabledItem.Checked = !IsDisabled(); };
            menu.Items.Add(enabledItem);
            var startupItem = new ToolStripMenuItem("Start with Windows");
            startupItem.Click += delegate { SetStartup(!StartupEnabled()); startupItem.Checked = StartupEnabled(); };
            menu.Items.Add(startupItem);
            menu.Opening += delegate { enabledItem.Checked = !IsDisabled(); startupItem.Checked = StartupEnabled(); };
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Open log", null, delegate { if (File.Exists(Listener.LogPath)) Process.Start(Listener.LogPath); });
            menu.Items.Add("Restart", null, delegate { restarts = 0; Listener.Stop(); if (!IsDisabled()) StartListener(); });
            menu.Items.Add("Exit", null, delegate { Exit(); });

            tray = new NotifyIcon();
            tray.Icon = Icon.ExtractAssociatedIcon(ExePath);
            tray.MouseUp += delegate(object sender, MouseEventArgs e)
            {
                if (e.Button != MouseButtons.Left && e.Button != MouseButtons.Right) return;
                if (menu.Visible) { CloseMenu(); return; }
                menu.Show(Cursor.Position, ToolStripDropDownDirection.AboveLeft);
            };
            UpdateText();
            tray.Visible = true;

            // a second launch, or the installer, reaches this copy through named events
            var close = new EventWaitHandle(false, EventResetMode.AutoReset, CloseEventName);
            var show = new EventWaitHandle(false, EventResetMode.AutoReset, ShowEventName);
            var watcher = new Thread(delegate()
            {
                var handles = new WaitHandle[] { close, show };
                while (true)
                {
                    int which = WaitHandle.WaitAny(handles);
                    if (which == 0) { ui.BeginInvoke((MethodInvoker)Exit); return; }
                    ui.BeginInvoke((MethodInvoker)delegate { ShowWhere(); });
                }
            });
            watcher.IsBackground = true;
            watcher.Start();

            if (!IsDisabled()) StartListener();
            if (welcome) ShowWhere();
            Application.Run();
            tray.Dispose();
        }

        static void ShowWhere()
        {
            tray.ShowBalloonTip(8000, "Teams Supercopy " + Version + (IsDisabled() ? " (disabled)" : ""),
                "Ctrl+C in Teams copies messages with author, time, quotes and images. The menu is on this icon, by the clock.", ToolTipIcon.Info);
        }

        static void StartListener()
        {
            Listener.Start(delegate(string reason)
            {
                // the listener ended on its own: start it again, five times a minute at most
                ui.BeginInvoke((MethodInvoker)delegate
                {
                    if (exiting || IsDisabled()) return;
                    if (restarts == 0 || DateTime.Now - firstRestart > TimeSpan.FromMinutes(1)) { firstRestart = DateTime.Now; restarts = 0; }
                    if (++restarts > 5)
                    {
                        tray.ShowBalloonTip(10000, "Teams Supercopy", "The listener keeps stopping: " + reason + ". See the log, then Restart from this menu.", ToolTipIcon.Warning);
                        return;
                    }
                    var t = new System.Windows.Forms.Timer { Interval = 2000 };
                    t.Tick += delegate { t.Dispose(); if (!exiting && !IsDisabled()) StartListener(); };
                    t.Start();
                });
            });
        }

        static void CloseMenu()
        {
            allowClose = true;
            menu.Close();
            allowClose = false;
        }

        static void Exit()
        {
            exiting = true;
            CloseMenu();
            Listener.Stop();
            tray.Visible = false;
            Application.Exit();
        }

        // Enabled: kept per user, so a disabled Supercopy stays off after a restart or a sign-in
        public static bool IsDisabled()
        {
            using (RegistryKey k = Registry.CurrentUser.OpenSubKey(SettingsKey))
                return k != null && Convert.ToInt32(k.GetValue("Disabled", 0)) == 1;
        }

        static void SetEnabled(bool on)
        {
            using (RegistryKey k = Registry.CurrentUser.CreateSubKey(SettingsKey))
                k.SetValue("Disabled", on ? 0 : 1, RegistryValueKind.DWord);
            restarts = 0;
            if (on) StartListener(); else Listener.Stop();
            UpdateText();
        }

        static void UpdateText()
        {
            tray.Text = "Teams Supercopy " + Version + (IsDisabled() ? " (disabled)" : "");
        }

        // Start with Windows: the Run value of the current user, pointing at this exe
        public static bool StartupEnabled()
        {
            using (RegistryKey k = Registry.CurrentUser.OpenSubKey(RunKey))
            {
                string v = k == null ? null : k.GetValue(RunValue) as string;
                return v != null && v.IndexOf(ExePath, StringComparison.OrdinalIgnoreCase) >= 0;
            }
        }

        public static void SetStartup(bool on)
        {
            using (RegistryKey k = Registry.CurrentUser.CreateSubKey(RunKey))
            {
                if (on) k.SetValue(RunValue, "\"" + ExePath + "\" --startup");
                else if (k.GetValue(RunValue) != null) k.DeleteValue(RunValue);
            }
        }

        // asks the running copy to exit, then waits for it; false if one is still running after 10 s
        static bool CloseRunning()
        {
            EventWaitHandle close;
            if (EventWaitHandle.TryOpenExisting(CloseEventName, out close)) { close.Set(); close.Dispose(); }
            RemoveOldVersion();
            var sw = Stopwatch.StartNew();
            while (sw.ElapsedMilliseconds < 10000)
            {
                Mutex m;
                if (!Mutex.TryOpenExisting(@"Local\TeamsSupercopy", out m)) return true;
                m.Dispose();
                Thread.Sleep(200);
            }
            return false;
        }

        // Versions up to 1.0.5 ran teams-supercopy.ps1 through pwsh, from %LOCALAPPDATA%\Programs\TeamsSupercopy with a
        // Startup shortcut. Left running, it holds the hotkeys; left in Startup, it comes back at sign-in.
        static void RemoveOldVersion()
        {
            string oldDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"Programs\TeamsSupercopy");
            try
            {
                using (var q = new ManagementObjectSearcher("SELECT ProcessId, Name, CommandLine, ExecutablePath FROM Win32_Process WHERE Name='pwsh.exe' OR Name='powershell.exe' OR Name='TeamsSupercopy.exe'"))
                    foreach (ManagementObject p in q.Get())
                    {
                        int pid = Convert.ToInt32(p["ProcessId"]);
                        string cmd = (p["CommandLine"] as string) ?? "", exe = (p["ExecutablePath"] as string) ?? "";
                        bool old = cmd.IndexOf("teams-supercopy.ps1", StringComparison.OrdinalIgnoreCase) >= 0
                            || (exe.StartsWith(oldDir + "\\", StringComparison.OrdinalIgnoreCase) && pid != Process.GetCurrentProcess().Id);
                        if (!old) continue;
                        try { using (var proc = Process.GetProcessById(pid)) { proc.Kill(); proc.WaitForExit(5000); } } catch { }
                    }
            }
            catch { }
            try
            {
                string lnk = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Startup), "Teams Supercopy.lnk");
                if (File.Exists(lnk)) File.Delete(lnk);
                if (File.Exists(Path.Combine(oldDir, "teams-supercopy.ps1")) && !ExePath.StartsWith(oldDir + "\\", StringComparison.OrdinalIgnoreCase))
                    Directory.Delete(oldDir, true);
            }
            catch { }
        }
    }
}
