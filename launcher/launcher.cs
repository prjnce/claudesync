// claude-sync launcher (SPEC §17.2). Built at install time:
//   csc.exe /target:winexe /out:launcher.exe launcher.cs
// launcher.exe <command line...>   runs the command line without a window, inside a Job Object that kills the
//                                  whole process tree when the launcher goes away, waits, and returns the
//                                  child's exit code (so the Task Scheduler's IgnoreNew and ExecutionTimeLimit work).
// launcher.exe realpath <path>     prints the real path on disk (GetFinalPathNameByHandle).
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

static class Launcher
{
    const uint CREATE_NO_WINDOW = 0x08000000;
    const uint CREATE_SUSPENDED = 0x00000004;
    const uint CREATE_BREAKAWAY_FROM_JOB = 0x01000000;
    const uint INFINITE = 0xFFFFFFFF;
    const int JobObjectExtendedLimitInformation = 9;
    const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;

    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct IO_COUNTERS { public ulong a, b, c, d, e, f; }

    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO
    {
        public int cb;
        public string lpReserved, lpDesktop, lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2;
        public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateJobObject(IntPtr attrs, string name);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetInformationJobObject(IntPtr job, int cls, ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION info, int len);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CreateProcess(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags,
        IntPtr env, string cwd, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll")] static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr h, out uint code);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr h, uint code);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateFile(string name, uint access, uint share, IntPtr sa, uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern uint GetFinalPathNameByHandle(IntPtr h, StringBuilder path, uint len, uint flags);

    // Everything after the program name in the raw command line (quoting is left as the caller wrote it).
    static string Tail()
    {
        string cl = Environment.CommandLine;
        int i = 0;
        if (cl.Length > 0 && cl[0] == '"')
        {
            i = cl.IndexOf('"', 1);
            i = i < 0 ? cl.Length : i + 1;
        }
        else
        {
            while (i < cl.Length && cl[i] != ' ') i++;
        }
        return cl.Substring(i).TrimStart();
    }

    static int RealPath(string p)
    {
        // FILE_FLAG_BACKUP_SEMANTICS (0x02000000) so that directories open too
        IntPtr h = CreateFile(p, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero);
        if (h == (IntPtr)(-1)) return 1;
        var sb = new StringBuilder(1024);
        uint n = GetFinalPathNameByHandle(h, sb, 1024, 0);
        CloseHandle(h);
        if (n == 0 || n >= 1024) return 1;
        string r = sb.ToString();
        if (r.StartsWith(@"\\?\UNC\")) r = @"\\" + r.Substring(8);
        else if (r.StartsWith(@"\\?\")) r = r.Substring(4);
        using (Stream o = Console.OpenStandardOutput())
        {
            byte[] b = new UTF8Encoding(false).GetBytes(r + "\n");
            o.Write(b, 0, b.Length);
        }
        return 0;
    }

    static int Main(string[] args)
    {
        string tail = Tail();
        if (tail.Length == 0) return 2;
        if (args.Length == 2 && args[0] == "realpath") return RealPath(args[1]);

        IntPtr job = CreateJobObject(IntPtr.Zero, null);
        var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
        info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        bool jobOk = SetInformationJobObject(job, JobObjectExtendedLimitInformation, ref info, Marshal.SizeOf(info));
        int jobErr = Marshal.GetLastWin32Error();

        var si = new STARTUPINFO();
        si.cb = Marshal.SizeOf(si);
        PROCESS_INFORMATION pi;
        var cmd = new StringBuilder(tail);
        // Suspended, so that the child is in the job before it can start anything of its own.
        if (!CreateProcess(null, cmd, IntPtr.Zero, IntPtr.Zero, false,
                CREATE_NO_WINDOW | CREATE_SUSPENDED | CREATE_BREAKAWAY_FROM_JOB, IntPtr.Zero, null, ref si, out pi))
        {
            // Not allowed to break away from the scheduler's own job: try without.
            if (!CreateProcess(null, cmd, IntPtr.Zero, IntPtr.Zero, false,
                    CREATE_NO_WINDOW | CREATE_SUSPENDED, IntPtr.Zero, null, ref si, out pi))
                return 127;
        }
        if (!AssignProcessToJobObject(job, pi.hProcess))
        {
            TerminateProcess(pi.hProcess, 126);
            return 126;
        }
        uint rt = ResumeThread(pi.hThread);
        if (Environment.GetEnvironmentVariable("CS_LAUNCHER_DEBUG") != null)
            File.AppendAllText(Environment.GetEnvironmentVariable("CS_LAUNCHER_DEBUG"), "pid=" + pi.dwProcessId + " resume=" + rt + " jobok=" + jobOk + " err=" + jobErr + " size=" + Marshal.SizeOf(info) + "\r\n");
        WaitForSingleObject(pi.hProcess, INFINITE);
        uint code;
        GetExitCodeProcess(pi.hProcess, out code);
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
        CloseHandle(job); // KILL_ON_JOB_CLOSE: anything the child left behind goes with it
        return unchecked((int)code);
    }
}
