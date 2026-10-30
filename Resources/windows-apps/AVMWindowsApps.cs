// AVMWindowsApps.cs
// AVM — Accessible Virtual Machine
//
// Runs in the signed-in user's Windows session (2026-10-29), started by
// the scheduled task \AVM\Windows Apps at sign-in. AVM's guest agent runs
// as SYSTEM in session 0, where no window or Start menu of the user's can
// be seen or brought forward, so this does both for it:
//
//   - About once a second, the apps with a window open, one line each,
//     written to running.txt when the list changes: key TAB name. The key
//     is the app's AppUserModelID when it has one (Store apps, and desktop
//     apps that set one), else its program's path.
//   - request-ID.txt, written by AVM (as SYSTEM, through the agent), one
//     file per request (2026-10-30 audit: one shared request.txt let a
//     second request overwrite the first): id TAB launch TAB key TAB unix
//     time. The app's front window is restored and brought forward, the
//     app started first when no window of it is open, then waited for, up
//     to 90 seconds, while other requests go on; reply-ID.txt gets id TAB
//     ok or failed TAB what happened. Written while Windows is still at
//     its sign-in screen, a request waits here for this helper, which
//     starts at sign-in; one older than ten minutes is dropped, so an app
//     never opens at some later sign-in nobody asked for. (A focus
//     request, without the start, went with AVM's enter-app.)
//   - Replies older than fifteen minutes are deleted; AVM has its answer.
//
// It never shows a window, so it takes no focus and no screen reader
// speaks for it. One copy per session (a named mutex).

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

static class AVMWindowsApps
{
    static readonly string Folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), @"AVM\apps");
    static readonly string RunningFile = Path.Combine(Folder, "running.txt");

    sealed class Pending { public string Id, Key; public DateTime Until; }
    /// Apps started for a launch, whose window hasn't opened yet.
    static readonly List<Pending> Waiting = new List<Pending>();

    [STAThread]
    static void Main()
    {
        bool first;
        using (var only = new Mutex(true, @"Local\AVMWindowsApps", out first))
        {
            if (!first) return;
            Directory.CreateDirectory(Folder);
            string last = null;
            int ticks = 0;
            while (true)
            {
                string[] requests;
                try { requests = Directory.GetFiles(Folder, "request-*.txt"); } catch { requests = new string[0]; }
                foreach (string file in requests)
                {
                    try { Handle(file); }
                    catch (Exception e)
                    {
                        try { File.Delete(file); } catch { }
                        try { Reply(IdOf(file), "failed\t" + e.Message); } catch { }
                    }
                }
                try { CheckWaiting(); } catch { }
                if (ticks % 240 == 0) { try { DeleteOldReplies(); } catch { } }
                if (ticks++ % 4 == 0)
                {
                    try
                    {
                        string now = RunningList();
                        if (now != last) { Write(RunningFile, now); last = now; }
                    }
                    catch { }
                }
                Thread.Sleep(250);
            }
        }
    }

    // MARK: Requests

    static void Handle(string file)
    {
        string request = File.ReadAllText(file);
        // AVM writes the line and its newline at once; without the newline
        // it's still being written, unless it's been ten seconds.
        if (!request.EndsWith("\n") && DateTime.UtcNow - File.GetLastWriteTimeUtc(file) < TimeSpan.FromSeconds(10)) return;
        File.Delete(file);
        string id = IdOf(file);
        string[] parts = request.Trim().Split('\t');
        if (parts.Length < 3 || parts[1] != "launch") { Reply(id, "failed\tnot understood"); return; }
        string key = parts[2];
        IntPtr window = WindowOf(key, AppWindows(false));
        if (window != IntPtr.Zero) { Forward(id, window); return; }
        long asked;
        long now = (long)(DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalSeconds;
        if (parts.Length < 4 || !long.TryParse(parts[3], out asked) || now - asked > 600) { Reply(id, "failed\tthe request was too old"); return; }
        Start(key);
        // A cold start in a virtual machine can be slow: up to 90 seconds,
        // checked with every pass, so other requests aren't held up.
        Waiting.Add(new Pending { Id = id, Key = key, Until = DateTime.UtcNow.AddSeconds(90) });
    }

    static void CheckWaiting()
    {
        if (Waiting.Count == 0) return;
        // One look at the windows for every app waited for, without their
        // names, which read each program's file.
        var windows = AppWindows(false);
        for (int i = Waiting.Count - 1; i >= 0; i--)
        {
            var p = Waiting[i];
            IntPtr window = WindowOf(p.Key, windows);
            if (window != IntPtr.Zero) { Waiting.RemoveAt(i); Forward(p.Id, window); }
            else if (DateTime.UtcNow > p.Until) { Waiting.RemoveAt(i); Reply(p.Id, "failed\tit didn't open a window within 90 seconds"); }
        }
    }

    static void Forward(string id, IntPtr window)
    {
        bool front = BringForward(window);
        Reply(id, (front ? "ok\t" : "failed\twindows kept another window in front: ") + Title(window));
    }

    /// The id in request-ID.txt: letters, digits and dashes only.
    static string IdOf(string file)
    {
        string name = Path.GetFileNameWithoutExtension(file);
        string id = name.StartsWith("request-") ? name.Substring(8) : "0";
        foreach (char c in id) if (!char.IsLetterOrDigit(c) && c != '-') return "0";
        return id.Length == 0 ? "0" : id;
    }

    static void Reply(string id, string text)
    {
        Write(Path.Combine(Folder, "reply-" + id + ".txt"), id + "\t" + text + "\n");
    }

    static void DeleteOldReplies()
    {
        foreach (string file in Directory.GetFiles(Folder, "reply-*.txt"))
            if (DateTime.UtcNow - File.GetLastWriteTimeUtc(file) > TimeSpan.FromMinutes(15)) File.Delete(file);
    }

    static IntPtr WindowOf(string key, List<AppWindow> windows)
    {
        foreach (var w in windows) if (w.Key == key) return w.Handle;
        return IntPtr.Zero;
    }

    /// A program path as it is; anything else is an AppUserModelID, which
    /// the Start menu's own folder starts (Store apps, and desktop apps
    /// that have one).
    static void Start(string key)
    {
        if (key.Contains("\\")) Process.Start(new ProcessStartInfo(key) { UseShellExecute = true });
        else Process.Start(new ProcessStartInfo("explorer.exe", "shell:AppsFolder\\" + key) { UseShellExecute = true });
    }

    static bool BringForward(IntPtr window)
    {
        if (IsIconic(window)) ShowWindow(window, 9);             // SW_RESTORE
        IntPtr front = GetForegroundWindow();
        uint frontThread = GetWindowThreadProcessId(front, IntPtr.Zero);
        uint mine = GetCurrentThreadId();
        // Joined to the front window's input, Windows lets this process
        // give the foreground away, as the front app could itself.
        bool joined = frontThread != 0 && frontThread != mine && AttachThreadInput(mine, frontThread, true);
        BringWindowToTop(window);
        SetForegroundWindow(window);
        if (joined) AttachThreadInput(mine, frontThread, false);
        for (int i = 0; i < 10 && GetForegroundWindow() != window; i++) Thread.Sleep(30);
        if (GetForegroundWindow() != window)
        {
            SwitchToThisWindow(window, true);
            for (int i = 0; i < 10 && GetForegroundWindow() != window; i++) Thread.Sleep(30);
        }
        return GetForegroundWindow() == window;
    }

    // MARK: The apps with windows open

    struct AppWindow { public IntPtr Handle; public string Key; public string Name; }

    static string RunningList()
    {
        var seen = new HashSet<string>();
        var text = new StringBuilder();
        foreach (var w in AppWindows())
        {
            if (!seen.Add(w.Key)) continue;
            text.Append(w.Key).Append('\t').Append(w.Name.Replace('\t', ' ').Replace('\n', ' ')).Append('\n');
        }
        return text.ToString();
    }

    static readonly HashSet<string> NotApps = new HashSet<string>(StringComparer.OrdinalIgnoreCase) {
        "Progman", "WorkerW", "Shell_TrayWnd", "Shell_SecondaryTrayWnd", "Windows.UI.Core.CoreWindow",
        "TopLevelWindowForOverflowXamlIsland", "XamlExplorerHostIslandWindow",
    };
    static readonly HashSet<string> NotAppPrograms = new HashSet<string>(StringComparer.OrdinalIgnoreCase) {
        "AVMWindowsApps", "TextInputHost", "ShellExperienceHost", "StartMenuExperienceHost", "SearchHost",
        "LockApp", "SystemSettingsAdminFlows",
    };

    /// Top-level windows a person switches to, front first; their apps'
    /// names only when asked, as finding one reads the program's file.
    static List<AppWindow> AppWindows(bool named = true)
    {
        var found = new List<AppWindow>();
        EnumWindows((h, _) =>
        {
            if (!IsWindowVisible(h) || GetWindow(h, 4) != IntPtr.Zero) return true;     // GW_OWNER
            if ((GetWindowLong(h, -20) & 0x80) != 0) return true;                        // WS_EX_TOOLWINDOW
            int cloaked;
            if (DwmGetWindowAttribute(h, 14, out cloaked, 4) == 0 && cloaked != 0) return true;
            string title = Title(h);
            if (title.Length == 0) return true;
            var cls = new StringBuilder(256);
            GetClassName(h, cls, cls.Capacity);
            if (NotApps.Contains(cls.ToString())) return true;
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            string program = ProgramPath(pid);
            string programName = Path.GetFileNameWithoutExtension(program ?? "");
            if (NotAppPrograms.Contains(programName)) return true;
            string aumid = AppUserModelID(h);
            if (aumid == null && cls.ToString() == "ApplicationFrameWindow") aumid = FrameChildAppID(h);
            string key = aumid ?? (program ?? "").ToLowerInvariant();
            if (key.Length == 0) return true;
            found.Add(new AppWindow { Handle = h, Key = key, Name = named ? AppName(aumid, program, title) : null });
            return true;
        }, IntPtr.Zero);
        return found;
    }

    static readonly Dictionary<string, string> StartNames = new Dictionary<string, string>();

    static string AppName(string aumid, string program, string title)
    {
        if (aumid != null)
        {
            if (StartNames.Count == 0) LoadStartNames();
            string name;
            if (StartNames.TryGetValue(aumid, out name)) return name;
        }
        if (program != null)
        {
            try
            {
                var info = FileVersionInfo.GetVersionInfo(program);
                if (!string.IsNullOrWhiteSpace(info.FileDescription)) return info.FileDescription.Trim();
                if (!string.IsNullOrWhiteSpace(info.ProductName)) return info.ProductName.Trim();
            }
            catch { }
            return Path.GetFileNameWithoutExtension(program);
        }
        return title;
    }

    /// The Start menu's names, by AppUserModelID (shell:AppsFolder).
    static void LoadStartNames()
    {
        try
        {
            Type shellType = Type.GetTypeFromProgID("Shell.Application");
            object shell = Activator.CreateInstance(shellType);
            object folder = shellType.InvokeMember("NameSpace", System.Reflection.BindingFlags.InvokeMethod, null, shell, new object[] { "shell:AppsFolder" });
            object items = folder.GetType().InvokeMember("Items", System.Reflection.BindingFlags.InvokeMethod, null, folder, null);
            int count = (int)items.GetType().InvokeMember("Count", System.Reflection.BindingFlags.GetProperty, null, items, null);
            for (int i = 0; i < count; i++)
            {
                object item = items.GetType().InvokeMember("Item", System.Reflection.BindingFlags.InvokeMethod, null, items, new object[] { i });
                string path = (string)item.GetType().InvokeMember("Path", System.Reflection.BindingFlags.GetProperty, null, item, null);
                string name = (string)item.GetType().InvokeMember("Name", System.Reflection.BindingFlags.GetProperty, null, item, null);
                if (!string.IsNullOrEmpty(path) && !StartNames.ContainsKey(path)) StartNames[path] = name;
            }
        }
        catch { StartNames["\0"] = ""; }
    }

    // MARK: Window and process details

    static string Title(IntPtr h)
    {
        var text = new StringBuilder(512);
        GetWindowText(h, text, text.Capacity);
        return text.ToString();
    }

    static string ProgramPath(uint pid)
    {
        IntPtr process = OpenProcess(0x1000, false, pid);        // PROCESS_QUERY_LIMITED_INFORMATION
        if (process == IntPtr.Zero) return null;
        try
        {
            var path = new StringBuilder(1024);
            int size = path.Capacity;
            return QueryFullProcessImageName(process, 0, path, ref size) ? path.ToString() : null;
        }
        finally { CloseHandle(process); }
    }

    /// A Store app's frame holds its app's window as a child; the child's
    /// process has the app's identity.
    static string FrameChildAppID(IntPtr frame)
    {
        string found = null;
        EnumChildWindows(frame, (child, _) =>
        {
            string id = AppUserModelID(child);
            if (id != null) { found = id; return false; }
            uint pid;
            GetWindowThreadProcessId(child, out pid);
            uint framePid;
            GetWindowThreadProcessId(frame, out framePid);
            if (pid != framePid)
            {
                IntPtr process = OpenProcess(0x1000, false, pid);
                if (process != IntPtr.Zero)
                {
                    var name = new StringBuilder(1024);
                    int size = name.Capacity;
                    if (GetApplicationUserModelId(process, ref size, name) == 0) found = name.ToString();
                    CloseHandle(process);
                    if (found != null) return false;
                }
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    static string AppUserModelID(IntPtr h)
    {
        IPropertyStore store;
        var iid = new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
        if (SHGetPropertyStoreForWindow(h, ref iid, out store) != 0 || store == null) return null;
        try
        {
            var key = new PropertyKey { fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), pid = 5 };
            PropVariant value;
            if (store.GetValue(ref key, out value) != 0) return null;
            string id = value.vt == 31 ? Marshal.PtrToStringUni(value.p) : null;   // VT_LPWSTR
            PropVariantClear(ref value);
            return string.IsNullOrEmpty(id) ? null : id;
        }
        finally { Marshal.ReleaseComObject(store); }
    }

    static void Write(string path, string text)
    {
        string temp = path + ".new";
        File.WriteAllText(temp, text, new UTF8Encoding(false));
        if (File.Exists(path)) File.Replace(temp, path, null); else File.Move(temp, path);
    }

    // MARK: Windows

    delegate bool EnumProc(IntPtr h, IntPtr param);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc proc, IntPtr param);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent, EnumProc proc, IntPtr param);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int index);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder text, int max);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder text, int max);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern void SwitchToThisWindow(IntPtr h, bool altTab);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint from, uint to, bool attach);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool QueryFullProcessImageName(IntPtr process, int flags, StringBuilder path, ref int size);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern int GetApplicationUserModelId(IntPtr process, ref int length, StringBuilder id);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int attribute, out int value, int size);
    [DllImport("shell32.dll")] static extern int SHGetPropertyStoreForWindow(IntPtr h, ref Guid iid, out IPropertyStore store);
    [DllImport("ole32.dll")] static extern int PropVariantClear(ref PropVariant value);

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    struct PropertyKey { public Guid fmtid; public uint pid; }

    [StructLayout(LayoutKind.Sequential)]
    struct PropVariant { public ushort vt; public ushort r1, r2, r3; public IntPtr p; public IntPtr p2; }

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore
    {
        int GetCount(out uint count);
        int GetAt(uint index, out PropertyKey key);
        int GetValue(ref PropertyKey key, out PropVariant value);
        int SetValue(ref PropertyKey key, ref PropVariant value);
        int Commit();
    }
}
