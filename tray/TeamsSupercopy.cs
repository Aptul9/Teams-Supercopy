// Tray host for teams-supercopy.ps1: runs the listener through pwsh without a console window,
// restarts it when it stops and ends it when the tray app exits. Built by tools/package-windows.ps1
// with the C# 5 compiler that ships with .NET Framework, so no newer syntax here.
using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;

[assembly: System.Reflection.AssemblyTitle("Teams Supercopy")]
[assembly: System.Reflection.AssemblyProduct("Teams Supercopy")]

static class TeamsSupercopy
{
    [DllImport("kernel32.dll")] static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll")] static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref ExtendedLimits info, int length);
    [DllImport("kernel32.dll")] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [StructLayout(LayoutKind.Sequential)]
    struct ExtendedLimits
    {
        public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount, ReadTransferCount, WriteTransferCount, OtherTransferCount;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }

    static string dir, script, log, pwsh, version;
    static IntPtr job;
    static Process listener;
    static NotifyIcon tray;
    static Control ui; // owns the UI thread for events raised on other threads
    static bool exiting;
    static DateTime[] recentStarts = new DateTime[5];
    static int startCount;

    [STAThread]
    static void Main()
    {
        bool created;
        using (new Mutex(true, @"Local\TeamsSupercopyTray", out created))
        {
            if (!created) return;
            dir = Path.GetDirectoryName(Application.ExecutablePath);
            script = Path.Combine(dir, "teams-supercopy.ps1");
            log = Path.Combine(dir, "teams-supercopy.log");
            pwsh = FindPwsh();
            if (pwsh == null || !File.Exists(script))
            {
                MessageBox.Show(pwsh == null
                    ? "PowerShell 7 (pwsh) is required: winget install Microsoft.PowerShell"
                    : "teams-supercopy.ps1 is missing next to TeamsSupercopy.exe", "Teams Supercopy");
                return;
            }
            Match m = Regex.Match(File.ReadAllText(script), @"(?m)^\$SupercopyVersion = '([^']+)'");
            version = m.Success ? m.Groups[1].Value : "?";

            // the listener dies with this process, however it ends
            job = CreateJobObject(IntPtr.Zero, null);
            ExtendedLimits limits = new ExtendedLimits();
            limits.LimitFlags = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            SetInformationJobObject(job, 9, ref limits, Marshal.SizeOf(typeof(ExtendedLimits)));

            ui = new Control();
            IntPtr uiHandle = ui.Handle;
            ContextMenuStrip menu = new ContextMenuStrip();
            menu.Items.Add("Teams Supercopy " + version).Enabled = false;
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Open log", null, delegate { if (File.Exists(log)) Process.Start(log); });
            menu.Items.Add("Restart", null, delegate { startCount = 0; Restart(); });
            menu.Items.Add("Exit", null, delegate { exiting = true; Stop(); tray.Visible = false; Application.Exit(); });

            tray = new NotifyIcon();
            tray.Icon = File.Exists(Path.Combine(dir, "icon.ico")) ? new Icon(Path.Combine(dir, "icon.ico")) : Icon.ExtractAssociatedIcon(Application.ExecutablePath);
            tray.Text = "Teams Supercopy " + version;
            tray.ContextMenuStrip = menu;
            tray.Visible = true;

            Start();
            Application.Run();
            tray.Dispose();
        }
    }

    static string FindPwsh()
    {
        string pf = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), @"PowerShell\7\pwsh.exe");
        if (File.Exists(pf)) return pf;
        foreach (string p in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';'))
        {
            try { string c = Path.Combine(p.Trim(), "pwsh.exe"); if (File.Exists(c)) return c; } catch { }
        }
        return null;
    }

    static void Start()
    {
        // more than five starts in a minute: the listener cannot run, stop retrying
        DateTime now = DateTime.Now;
        if (startCount >= recentStarts.Length && now - recentStarts[startCount % recentStarts.Length] < TimeSpan.FromMinutes(1))
        {
            tray.ShowBalloonTip(10000, "Teams Supercopy", "The listener keeps stopping. See the log, then Restart from this menu.", ToolTipIcon.Warning);
            return;
        }
        recentStarts[startCount % recentStarts.Length] = now;
        startCount++;

        ProcessStartInfo psi = new ProcessStartInfo(pwsh,
            string.Format("-NoProfile -ExecutionPolicy Bypass -File \"{0}\"", script));
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.WorkingDirectory = dir;
        Process p = Process.Start(psi);
        AssignProcessToJobObject(job, p.Handle);
        p.EnableRaisingEvents = true;
        p.Exited += delegate
        {
            if (exiting || p != listener) return;
            System.Windows.Forms.Timer t = new System.Windows.Forms.Timer();
            t.Interval = 2000;
            t.Tick += delegate { t.Dispose(); if (!exiting && p == listener) Start(); };
            ui.BeginInvoke((MethodInvoker)delegate { t.Start(); });
        };
        listener = p;
    }

    static void Stop()
    {
        Process p = listener;
        listener = null;
        if (p == null) return;
        try { if (!p.HasExited) { p.Kill(); p.WaitForExit(5000); } } catch { }
    }

    static void Restart() { Stop(); Start(); }
}
