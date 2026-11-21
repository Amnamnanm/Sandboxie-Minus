using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;

namespace ACM
{
    public class LaunchOptions
    {
        public string Exe, CommandLine, WorkDir, ContainerName, Desktop;
        public string[] CapabilitySids, Env;
        public bool Lpac, ChildRestrict, NewConsole, KillOnClose, Wait, WaitTree, IsolateDesktop, AllowSharedDesktop, AllowMic;
        public ulong Mitigation, Mitigation2, ProcessMemMb, JobMemMb;
        public uint JobUiFlags, MaxProcesses, CpuRatePct;
        public uint Pid, ExitCode;
        public List<string> Warnings = new List<string>();
    }

    public static class Native
    {
        const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
        const uint CREATE_SUSPENDED = 0x00000004;
        const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
        const uint CREATE_NEW_CONSOLE = 0x00000010;
        const uint CREATE_NO_WINDOW = 0x08000000;
        const uint SE_GROUP_ENABLED = 0x00000004; // Required on capability SIDs in SECURITY_CAPABILITIES
        // Win32 PROC_THREAD_ATTRIBUTE_* constants (ProcThreadAttributeValue macro in winbase.h)
        const int ATTR_SECURITY_CAPABILITIES = 0x00020009;   // PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES
        const int ATTR_MITIGATION_POLICY = 0x00020007;       // PROC_THREAD_ATTRIBUTE_MITIGATION_POLICY
        const int ATTR_CHILD_PROCESS_POLICY = 0x0002000E;    // PROC_THREAD_ATTRIBUTE_CHILD_PROCESS_POLICY
        const int ATTR_ALL_APP_PACKAGES_POLICY = 0x0002000F; // PROC_THREAD_ATTRIBUTE_ALL_APPLICATION_PACKAGES_POLICY (LPAC)
        static readonly IntPtr INVALID_HANDLE_VALUE = new IntPtr(-1);

        [StructLayout(LayoutKind.Sequential)] struct SID_AND_ATTRIBUTES { public IntPtr Sid; public uint Attributes; }
        [StructLayout(LayoutKind.Sequential)] struct SECURITY_CAPABILITIES { public IntPtr AppContainerSid; public IntPtr Capabilities; public uint CapabilityCount; public uint Reserved; }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct STARTUPINFO
        {
            public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
            public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
            public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
        }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct STARTUPINFOEX { public STARTUPINFO StartupInfo; public IntPtr lpAttributeList; }
        [StructLayout(LayoutKind.Sequential)] struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public uint dwProcessId, dwThreadId; }
        [StructLayout(LayoutKind.Sequential)]
        struct JOBOBJECT_BASIC_LIMIT_INFORMATION
        {
            public long PerProcessUserTimeLimit, PerJobUserTimeLimit; public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize; public uint ActiveProcessLimit;
            public UIntPtr Affinity; public uint PriorityClass, SchedulingClass;
        }
        [StructLayout(LayoutKind.Sequential)] struct IO_COUNTERS { public ulong a, b, c, d, e, f; }
        [StructLayout(LayoutKind.Sequential)]
        struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
        {
            public JOBOBJECT_BASIC_LIMIT_INFORMATION Basic; public IO_COUNTERS Io;
            public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
        }

        [DllImport("userenv.dll", CharSet = CharSet.Unicode)] static extern int CreateAppContainerProfile(string name, string display, string desc, IntPtr caps, uint capCount, out IntPtr sid);
        [DllImport("userenv.dll", CharSet = CharSet.Unicode)] static extern int DeriveAppContainerSidFromAppContainerName(string name, out IntPtr sid);
        [DllImport("userenv.dll", CharSet = CharSet.Unicode)] static extern int DeleteAppContainerProfile(string name);
        [DllImport("userenv.dll", CharSet = CharSet.Unicode)] static extern int GetAppContainerFolderPath(string sid, out IntPtr path);
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool ConvertSidToStringSid(IntPtr sid, out IntPtr str);
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool ConvertStringSidToSid(string str, out IntPtr sid);
        [DllImport("advapi32.dll")] static extern IntPtr FreeSid(IntPtr sid);
        [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr p);
        [DllImport("kernelbase.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool DeriveCapabilitySidsFromName(string name, out IntPtr groupSids, out uint groupCount, out IntPtr capSids, out uint capCount);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attr, IntPtr value, IntPtr size, IntPtr prev, IntPtr ret);
        [DllImport("kernel32.dll")] static extern void DeleteProcThreadAttributeList(IntPtr list);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool CreateProcessW(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string cwd, ref STARTUPINFOEX si, out PROCESS_INFORMATION pi);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr CreateJobObjectW(IntPtr attrs, string name);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetInformationJobObject(IntPtr job, int cls, IntPtr info, uint len);
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct OSVERSIONINFOEX
        {
            public int dwOSVersionInfoSize, dwMajorVersion, dwMinorVersion, dwBuildNumber, dwPlatformId;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string szCSDVersion;
            public ushort wServicePackMajor, wServicePackMinor, wSuiteMask;
            public byte wProductType, wReserved;
        }
        [StructLayout(LayoutKind.Sequential)] struct JOBOBJECT_ASSOCIATE_COMPLETION_PORT { public IntPtr CompletionKey, CompletionPort; }
        [StructLayout(LayoutKind.Sequential)]
        struct JOBOBJECT_BASIC_ACCOUNTING_INFORMATION
        {
            public long TotalUserTime, TotalKernelTime, ThisPeriodTotalUserTime, ThisPeriodTotalKernelTime;
            public uint TotalPageFaultCount, TotalProcesses, ActiveProcesses, TotalTerminatedProcesses;
        }
        [StructLayout(LayoutKind.Sequential)] struct JOBOBJECT_CPU_RATE_CONTROL_INFORMATION { public uint ControlFlags, CpuRate; }

        [DllImport("ntdll.dll")] static extern int RtlGetVersion(ref OSVERSIONINFOEX osvi);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr proc);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool QueryInformationJobObject(IntPtr job, int cls, IntPtr info, uint len, IntPtr retLen);
        [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr CreateIoCompletionPort(IntPtr fileHandle, IntPtr existingPort, UIntPtr completionKey, uint threads);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetQueuedCompletionStatus(IntPtr port, out uint bytes, out IntPtr key, out IntPtr overlapped, uint ms);
        [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
        [DllImport("kernel32.dll", SetLastError = true)] static extern uint ResumeThread(IntPtr t);
        [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr p, uint code);
        [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h, uint ms);
        [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr h, out uint code);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
        [StructLayout(LayoutKind.Sequential)] struct SECURITY_ATTRIBUTES { public int nLength; public IntPtr lpSecurityDescriptor; public bool bInheritHandle; }
        delegate bool EnumDesktopProc([MarshalAs(UnmanagedType.LPWStr)] string lpszDesktop, IntPtr lParam);
        delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
        [DllImport("user32.dll", SetLastError = true)] static extern IntPtr GetProcessWindowStation();
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool GetUserObjectInformationW(IntPtr hObj, int nIndex, IntPtr pvInfo, uint nLength, out uint lpnLengthNeeded);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr CreateDesktopW(string lpszDesktop, string lpszDevice, IntPtr pDevmode, uint dwFlags, uint dwDesiredAccess, ref SECURITY_ATTRIBUTES lpsa);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr OpenDesktopW(string lpszDesktop, uint dwFlags, bool fInherit, uint dwDesiredAccess);
        [DllImport("user32.dll", SetLastError = true)] static extern bool CloseDesktop(IntPtr hDesktop);
        [DllImport("user32.dll", SetLastError = true)] static extern bool SwitchDesktop(IntPtr hDesktop);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool EnumDesktopsW(IntPtr hwinsta, EnumDesktopProc lpEnumFunc, IntPtr lParam);
        [DllImport("user32.dll", SetLastError = true)] static extern bool EnumDesktopWindows(IntPtr hDesktop, EnumWindowsProc lpfn, IntPtr lParam);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
        [DllImport("user32.dll", SetLastError = true)] static extern bool GetUserObjectSecurity(IntPtr hObj, ref uint pSIRequested, byte[] pSID, uint nLength, out uint lpnLengthNeeded);
        [DllImport("user32.dll", SetLastError = true)] static extern bool SetUserObjectSecurity(IntPtr hObj, ref uint pSIRequested, byte[] pSID);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool CreateProcessW(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string cwd, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
        [DllImport("user32.dll")] static extern uint WaitForInputIdle(IntPtr hProcess, uint dwMilliseconds);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);
        [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextW(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
        [DllImport("user32.dll")] static extern int GetWindowLongW(IntPtr hWnd, int nIndex);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr SendMessageTimeoutW(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam, uint fuFlags, uint uTimeout, out IntPtr lpdwResult);
        [DllImport("user32.dll", EntryPoint = "GetClassLongW")] static extern uint GetClassLong32(IntPtr hWnd, int nIndex);
        [DllImport("user32.dll", EntryPoint = "GetClassLongPtrW")] static extern IntPtr GetClassLongPtr64(IntPtr hWnd, int nIndex);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool QueryFullProcessImageNameW(IntPtr hProcess, uint dwFlags, StringBuilder lpExeName, ref uint lpdwSize);
        [DllImport("user32.dll")] static extern bool IsIconic(IntPtr hWnd);
        [DllImport("user32.dll")] static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
        [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hWnd);
        [DllImport("user32.dll")] static extern void SwitchToThisWindow(IntPtr hWnd, bool fAltTab);
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool PostMessageW(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vKey);
        [DllImport("wtsapi32.dll", SetLastError = true)] static extern bool WTSRegisterSessionNotification(IntPtr hWnd, uint dwFlags);
        [DllImport("wtsapi32.dll", SetLastError = true)] static extern bool WTSUnRegisterSessionNotification(IntPtr hWnd);
        [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr CreateEventW(ref SECURITY_ATTRIBUTES lpEventAttributes, bool bManualReset, bool bInitialState, string lpName);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetEvent(IntPtr hEvent);
        [StructLayout(LayoutKind.Sequential)] struct RAWINPUTDEVICE { public ushort usUsagePage, usUsage; public uint dwFlags; public IntPtr hwndTarget; }
        [StructLayout(LayoutKind.Sequential)] struct RAWINPUTHEADER { public uint dwType, dwSize; public IntPtr hDevice, wParam; }
        [StructLayout(LayoutKind.Sequential)] struct RAWKEYBOARD { public ushort MakeCode, Flags, Reserved, VKey; public uint Message, ExtraInformation; }
        [StructLayout(LayoutKind.Sequential)] struct RAWINPUT_KB { public RAWINPUTHEADER header; public RAWKEYBOARD keyboard; }
        [DllImport("user32.dll", SetLastError = true)] static extern bool RegisterRawInputDevices(RAWINPUTDEVICE[] pRawInputDevices, uint uiNumDevices, uint cbSize);
        [DllImport("user32.dll", SetLastError = true)] static extern uint GetRawInputData(IntPtr hRawInput, uint uiCommand, out RAWINPUT_KB pData, ref uint pcbSize, uint cbSizeHeader);
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool ConvertSecurityDescriptorToStringSecurityDescriptor(byte[] SecurityDescriptor, uint RequestedStringSDRevision, uint SecurityInformation, out IntPtr StringSecurityDescriptor, out uint StringSecurityDescriptorLen);
        [StructLayout(LayoutKind.Sequential)] struct GENERIC_MAPPING { public uint GenericRead, GenericWrite, GenericExecute, GenericAll; }
        [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);
        [DllImport("advapi32.dll", SetLastError = true)] static extern bool GetTokenInformation(IntPtr TokenHandle, int TokenInformationClass, IntPtr TokenInformation, int TokenInformationLength, out int ReturnLength);
        [DllImport("advapi32.dll", SetLastError = true)] static extern bool DuplicateToken(IntPtr ExistingTokenHandle, int ImpersonationLevel, out IntPtr DuplicateTokenHandle);
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(string StringSecurityDescriptor, uint StringSDRevision, out IntPtr SecurityDescriptor, out uint SecurityDescriptorSize);
        [DllImport("advapi32.dll", SetLastError = true)] static extern bool AccessCheck(IntPtr pSecurityDescriptor, IntPtr ClientToken, uint DesiredAccess, ref GENERIC_MAPPING GenericMapping, IntPtr PrivilegeSet, ref uint PrivilegeSetLength, out uint GrantedAccess, out bool AccessStatus);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr CreateFileW(string lpFileName, uint dwDesiredAccess, uint dwShareMode, IntPtr lpSecurityAttributes, uint dwCreationDisposition, uint dwFlagsAndAttributes, IntPtr hTemplateFile);
        [DllImport("advapi32.dll", SetLastError = true)] static extern bool GetKernelObjectSecurity(IntPtr Handle, uint RequestedInformation, byte[] pSecurityDescriptor, uint nLength, out uint lpnLengthNeeded);
        [DllImport("advapi32.dll", SetLastError = true)] static extern bool SetKernelObjectSecurity(IntPtr Handle, uint SecurityInformation, byte[] pSecurityDescriptor);
        [StructLayout(LayoutKind.Sequential)] struct SP_DEVINFO_DATA { public uint cbSize; public Guid ClassGuid; public uint DevInst; public IntPtr Reserved; }
        [StructLayout(LayoutKind.Sequential)] struct SP_DEVICE_INTERFACE_DATA { public uint cbSize; public Guid InterfaceClassGuid; public uint Flags; public IntPtr Reserved; }
        [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr SetupDiGetClassDevsW(ref Guid ClassGuid, IntPtr Enumerator, IntPtr hwndParent, uint Flags);
        [DllImport("setupapi.dll", SetLastError = true)] static extern bool SetupDiEnumDeviceInterfaces(IntPtr DeviceInfoSet, IntPtr DeviceInfoData, ref Guid InterfaceClassGuid, uint MemberIndex, ref SP_DEVICE_INTERFACE_DATA DeviceInterfaceData);
        [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool SetupDiGetDeviceInterfaceDetailW(IntPtr DeviceInfoSet, ref SP_DEVICE_INTERFACE_DATA DeviceInterfaceData, IntPtr DeviceInterfaceDetailData, uint DeviceInterfaceDetailDataSize, out uint RequiredSize, ref SP_DEVINFO_DATA DeviceInfoData);
        [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool SetupDiGetDeviceRegistryPropertyW(IntPtr DeviceInfoSet, ref SP_DEVINFO_DATA DeviceInfoData, uint Property, out uint PropertyRegDataType, byte[] PropertyBuffer, uint PropertyBufferSize, out uint RequiredSize);
        [DllImport("setupapi.dll", SetLastError = true)] static extern bool SetupDiDestroyDeviceInfoList(IntPtr DeviceInfoSet);

        static void Hr(int hr, string what) { if (hr < 0) throw new Exception(what + " failed: 0x" + hr.ToString("X8")); }
        static string SidToString(IntPtr sid)
        {
            IntPtr s;
            if (!ConvertSidToStringSid(sid, out s)) throw new Win32Exception(Marshal.GetLastWin32Error());
            string r = Marshal.PtrToStringUni(s); LocalFree(s); return r;
        }
        public static string GetSidString(string name)
        {
            IntPtr sid; Hr(DeriveAppContainerSidFromAppContainerName(name, out sid), "DeriveAppContainerSid");
            try { return SidToString(sid); } finally { FreeSid(sid); }
        }
        public static int GetWindowsBuild()
        {
            OSVERSIONINFOEX osvi = new OSVERSIONINFOEX();
            osvi.dwOSVersionInfoSize = Marshal.SizeOf(typeof(OSVERSIONINFOEX));
            if (RtlGetVersion(ref osvi) != 0) return 0;
            if (osvi.dwMajorVersion > 10) return 999999;
            if (osvi.dwMajorVersion == 10) return osvi.dwBuildNumber;
            return 0;
        }
        public static bool Is32BitExe(string exePath)
        {
            try
            {
                using (System.IO.FileStream fs = new System.IO.FileStream(exePath, System.IO.FileMode.Open, System.IO.FileAccess.Read, System.IO.FileShare.ReadWrite))
                using (System.IO.BinaryReader br = new System.IO.BinaryReader(fs))
                {
                    if (fs.Length < 64 || br.ReadUInt16() != 0x5A4D) return false;
                    fs.Position = 0x3C;
                    int peOff = br.ReadInt32();
                    if (peOff <= 0 || peOff + 6 > fs.Length) return false;
                    fs.Position = peOff;
                    if (br.ReadUInt32() != 0x00004550) return false;
                    return br.ReadUInt16() == 0x014C;
                }
            }
            catch { return false; }
        }
        public static string EnsureProfile(string name, string display, string desc) { return EnsureProfile(name, display, desc, null); }
        public static string EnsureProfile(string name, string display, string desc, string[] capSids)
        {
            IntPtr sid = IntPtr.Zero, caps = IntPtr.Zero;
            List<IntPtr> sids = new List<IntPtr>();
            try
            {
                int n = capSids == null ? 0 : capSids.Length;
                int sa = Marshal.SizeOf(typeof(SID_AND_ATTRIBUTES));
                if (n > 0) caps = Marshal.AllocHGlobal(sa * n);
                for (int i = 0; i < n; i++)
                {
                    IntPtr cs;
                    if (!ConvertStringSidToSid(capSids[i], out cs)) throw new Exception("Bad capability SID: " + capSids[i]);
                    sids.Add(cs);
                    SID_AND_ATTRIBUTES x = new SID_AND_ATTRIBUTES(); x.Sid = cs; x.Attributes = SE_GROUP_ENABLED;
                    Marshal.StructureToPtr(x, IntPtr.Add(caps, i * sa), false);
                }
                int hr = CreateAppContainerProfile(name, display, desc, caps, (uint)n, out sid);
                if (hr == unchecked((int)0x800700B7)) hr = DeriveAppContainerSidFromAppContainerName(name, out sid);
                Hr(hr, "CreateAppContainerProfile");
                return SidToString(sid);
            }
            finally
            {
                if (sid != IntPtr.Zero) FreeSid(sid);
                if (caps != IntPtr.Zero) Marshal.FreeHGlobal(caps);
                foreach (IntPtr cs in sids) LocalFree(cs);
            }
        }
        public static int DeleteProfile(string name) { return DeleteAppContainerProfile(name); }
        public static void DeleteProfileChecked(string name)
        {
            int hr = DeleteAppContainerProfile(name);
            if (hr < 0 && hr != unchecked((int)0x80070002))
                throw new Exception("DeleteAppContainerProfile failed (open handles or active container processes?): 0x" + hr.ToString("X8"));
        }
        public static string GetFolder(string sid)
        {
            IntPtr p; Hr(GetAppContainerFolderPath(sid, out p), "GetAppContainerFolderPath");
            string s = Marshal.PtrToStringUni(p); Marshal.FreeCoTaskMem(p); return s;
        }
        public static string[] DeriveCapability(string name)
        {
            IntPtr g = IntPtr.Zero, c = IntPtr.Zero; uint gc = 0, cc = 0;
            if (!DeriveCapabilitySidsFromName(name, out g, out gc, out c, out cc)) throw new Win32Exception(Marshal.GetLastWin32Error());
            try
            {
                List<string> res = new List<string>();
                for (int i = 0; i < cc; i++)
                {
                    IntPtr s = Marshal.ReadIntPtr(c, i * IntPtr.Size);
                    if (s != IntPtr.Zero) res.Add(SidToString(s));
                }
                return res.ToArray();
            }
            finally
            {
                if (c != IntPtr.Zero)
                {
                    for (int i = 0; i < cc; i++) { IntPtr s = Marshal.ReadIntPtr(c, i * IntPtr.Size); if (s != IntPtr.Zero) LocalFree(s); }
                    LocalFree(c);
                }
                if (g != IntPtr.Zero)
                {
                    for (int i = 0; i < gc; i++) { IntPtr s = Marshal.ReadIntPtr(g, i * IntPtr.Size); if (s != IntPtr.Zero) LocalFree(s); }
                    LocalFree(g);
                }
            }
        }
        static string GetDevRegProp(IntPtr hDevInfo, ref SP_DEVINFO_DATA devInfo, uint prop)
        {
            uint regType = 0, req = 0;
            SetupDiGetDeviceRegistryPropertyW(hDevInfo, ref devInfo, prop, out regType, null, 0, out req);
            if (req == 0) return "";
            byte[] buf = new byte[req];
            if (!SetupDiGetDeviceRegistryPropertyW(hDevInfo, ref devInfo, prop, out regType, buf, req, out req)) return "";
            return Encoding.Unicode.GetString(buf).TrimEnd('\0');
        }
        static void EnumDevClass(string kind, Guid guid, List<string> output, HashSet<string> seen)
        {
            IntPtr h = SetupDiGetClassDevsW(ref guid, IntPtr.Zero, IntPtr.Zero, 0x12 /* DIGCF_PRESENT | DIGCF_DEVICEINTERFACE */);
            if (h == INVALID_HANDLE_VALUE) return;
            try
            {
                for (uint i = 0; ; i++)
                {
                    SP_DEVICE_INTERFACE_DATA did = new SP_DEVICE_INTERFACE_DATA();
                    did.cbSize = (uint)Marshal.SizeOf(typeof(SP_DEVICE_INTERFACE_DATA));
                    if (!SetupDiEnumDeviceInterfaces(h, IntPtr.Zero, ref guid, i, ref did)) break;
                    uint req = 0;
                    SP_DEVINFO_DATA devInfo = new SP_DEVINFO_DATA();
                    devInfo.cbSize = (uint)Marshal.SizeOf(typeof(SP_DEVINFO_DATA));
                    SetupDiGetDeviceInterfaceDetailW(h, ref did, IntPtr.Zero, 0, out req, ref devInfo);
                    if (req < 8) continue;
                    IntPtr buf = Marshal.AllocHGlobal((int)req);
                    try
                    {
// SP_DEVICE_INTERFACE_DETAIL_DATA_W is: DWORD cbSize (4 bytes) + WCHAR DevicePath[1].
// Because of 64-bit struct alignment padding, cbSize must be written as 8 on x64 and 6 on x86,
// even though the Unicode DevicePath string always begins immediately at byte offset 4.
                        Marshal.WriteInt32(buf, IntPtr.Size == 8 ? 8 : 6);
                        if (!SetupDiGetDeviceInterfaceDetailW(h, ref did, buf, req, out req, ref devInfo)) continue;
                        string path = Marshal.PtrToStringUni(IntPtr.Add(buf, 4));
                        if (string.IsNullOrEmpty(path) || !seen.Add(path)) continue;
                        string name = GetDevRegProp(h, ref devInfo, 0x0C /* SPDRP_FRIENDLYNAME */);
                        if (string.IsNullOrEmpty(name)) name = GetDevRegProp(h, ref devInfo, 0x00 /* SPDRP_DEVICEDESC */);
                        if (string.IsNullOrEmpty(name)) name = kind + " Device";
                        string mfg = GetDevRegProp(h, ref devInfo, 0x0B /* SPDRP_MFG */);
                        output.Add(kind + "|" + name.Replace("|", " ") + "|" + mfg.Replace("|", " ") + "|" + path.Replace("|", " "));
                    }
                    finally { Marshal.FreeHGlobal(buf); }
                }
            }
            finally { SetupDiDestroyDeviceInfoList(h); }
        }
        public static string[] EnumerateUsbHidDevices()
        {
            List<string> list = new List<string>();
            HashSet<string> seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            EnumDevClass("USB", new Guid("A5DCBF10-6530-11D2-901F-00C04FB951ED"), list, seen);
            EnumDevClass("HID", new Guid("4D1E55B2-F16F-11CF-88CB-001111000030"), list, seen);
            list.Sort(StringComparer.OrdinalIgnoreCase);
            return list.ToArray();
        }
        public static void SetDeviceInterfaceSidAccess(string devicePath, string sidString, bool grant)
        {
            IntPtr h = CreateFileW(devicePath, 0x00060000 /* READ_CONTROL | WRITE_DAC */, 0x00000003 /* FILE_SHARE_READ | FILE_SHARE_WRITE */, IntPtr.Zero, 3 /* OPEN_EXISTING */, 0, IntPtr.Zero);
            if (h == INVALID_HANDLE_VALUE) throw new Win32Exception(Marshal.GetLastWin32Error());
            try
            {
                uint needed = 0;
                GetKernelObjectSecurity(h, 4 /* DACL_SECURITY_INFORMATION */, null, 0, out needed);
                int err = Marshal.GetLastWin32Error();
                if (needed == 0) throw new Win32Exception(err);
                byte[] sdBytes = new byte[needed];
                if (!GetKernelObjectSecurity(h, 4, sdBytes, needed, out needed))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                RawSecurityDescriptor sd = new RawSecurityDescriptor(sdBytes, 0);
// A null DACL in Windows grants unrestricted access to everyone. Use RawAcl
// containing only the container SID would lock SYSTEM, Admins, and normal users out of the device
// Seed standard baseline ACEs before prepending the AppContainer SID
                if (sd.DiscretionaryAcl == null)
                {
                    if (!grant) return;
                    sd.DiscretionaryAcl = new RawAcl(2, 4);
                    sd.DiscretionaryAcl.InsertAce(0, new CommonAce(AceFlags.None, AceQualifier.AccessAllowed, 0x001F01FF /* FILE_ALL_ACCESS */, new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null), false, null));
                    sd.DiscretionaryAcl.InsertAce(1, new CommonAce(AceFlags.None, AceQualifier.AccessAllowed, 0x001F01FF /* FILE_ALL_ACCESS */, new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null), false, null));
                    // 0x0012019F = FILE_GENERIC_READ (0x120089) | FILE_GENERIC_WRITE (0x120116)
                    sd.DiscretionaryAcl.InsertAce(2, new CommonAce(AceFlags.None, AceQualifier.AccessAllowed, 0x0012019F /* FILE_GENERIC_READ | FILE_GENERIC_WRITE */, new SecurityIdentifier(WellKnownSidType.AuthenticatedUserSid, null), false, null));
                }
                SecurityIdentifier targetSid = new SecurityIdentifier(sidString);
                for (int i = sd.DiscretionaryAcl.Count - 1; i >= 0; i--)
                {
                    KnownAce ka = sd.DiscretionaryAcl[i] as KnownAce;
                    if (ka != null && ka.SecurityIdentifier.Equals(targetSid))
                        sd.DiscretionaryAcl.RemoveAce(i);
                }
// Prepend explicit container Allow ACE at index 0 (caller/device paths do not use explicit Deny ACEs here)
                if (grant)
                {
                    CommonAce ace = new CommonAce(AceFlags.None, AceQualifier.AccessAllowed, 0x0012019F /* FILE_GENERIC_READ | FILE_GENERIC_WRITE */, targetSid, false, null);
                    sd.DiscretionaryAcl.InsertAce(0, ace);
                }
                byte[] outBytes = new byte[sd.BinaryLength];
                sd.GetBinaryForm(outBytes, 0);
                if (!SetKernelObjectSecurity(h, 4, outBytes))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            finally { CloseHandle(h); }
        }
        public static string[] GetContainerPids(string targetSid)
        {
            List<string> list = new List<string>();
            System.Diagnostics.Process[] procs = System.Diagnostics.Process.GetProcesses();
            for (int i = 0; i < procs.Length; i++)
            {
                System.Diagnostics.Process p = procs[i];
                try
                {
                    IntPtr hp = OpenProcess(0x1000 /* PROCESS_QUERY_LIMITED_INFORMATION */, false, (uint)p.Id);
                    if (hp == IntPtr.Zero) continue;
                    try
                    {
                        IntPtr ht;
                        if (!OpenProcessToken(hp, 0x0008 /* TOKEN_QUERY */, out ht)) continue;
                        try
                        {
                            int len = 0;
                            GetTokenInformation(ht, 31 /* TokenAppContainerSid */, IntPtr.Zero, 0, out len);
                            if (len <= 0) continue;
                            IntPtr buf = Marshal.AllocHGlobal(len);
                            try
                            {
                                int retLen;
                                if (GetTokenInformation(ht, 31, buf, len, out retLen))
                                {
                                    IntPtr psid = Marshal.ReadIntPtr(buf);
                                    if (psid != IntPtr.Zero && string.Equals(SidToString(psid), targetSid, StringComparison.OrdinalIgnoreCase))
                                        list.Add(p.Id + "|" + p.ProcessName);
                                }
                            }
                            finally { Marshal.FreeHGlobal(buf); }
                        }
                        finally { CloseHandle(ht); }
                    }
                    finally { CloseHandle(hp); }
                }
                catch { }
                finally { p.Dispose(); }
            }
            return list.ToArray();
        }
        public static int TerminateContainerPids(string targetSid)
        {
            int killed = 0;
            foreach (string entry in GetContainerPids(targetSid))
            {
                int sep = entry.IndexOf('|');
                uint pid;
                if (sep > 0 && uint.TryParse(entry.Substring(0, sep), out pid))
                {
                    IntPtr hp = OpenProcess(0x0001 /* PROCESS_TERMINATE */, false, pid);
                    if (hp != IntPtr.Zero)
                    {
                        try { if (TerminateProcess(hp, 1)) killed++; }
                        finally { CloseHandle(hp); }
                    }
                }
            }
            return killed;
        }

        static void SetAttr(IntPtr list, int attr, IntPtr value, int size)
        {
            if (!UpdateProcThreadAttribute(list, 0, (IntPtr)attr, value, (IntPtr)size, IntPtr.Zero, IntPtr.Zero))
                throw new Win32Exception(Marshal.GetLastWin32Error());
        }

        const uint DESK_MANAGE = 0x000E01FF; // READ_CONTROL | WRITE_DAC | WRITE_OWNER | 0x01FF
        static string GetObjName(IntPtr h)
        {
            uint n = 0; GetUserObjectInformationW(h, 2, IntPtr.Zero, 0, out n);
            if (n == 0) return "";
            IntPtr b = Marshal.AllocHGlobal((int)n);
            try { return GetUserObjectInformationW(h, 2, b, n, out n) ? (Marshal.PtrToStringUni(b) ?? "") : ""; }
            finally { Marshal.FreeHGlobal(b); }
        }
        static byte[] GetObjSd(IntPtr h, uint si)
        {
            uint n = 0, req = si; GetUserObjectSecurity(h, ref req, null, 0, out n);
            if (n == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
            byte[] b = new byte[n]; req = si;
            if (!GetUserObjectSecurity(h, ref req, b, n, out n)) throw new Win32Exception(Marshal.GetLastWin32Error());
            return b;
        }
        static byte[] SddlBytes(string sddl)
        {
            IntPtr p; uint sz;
            if (!ConvertStringSecurityDescriptorToSecurityDescriptor(sddl, 1, out p, out sz)) throw new Win32Exception(Marshal.GetLastWin32Error());
            try { byte[] b = new byte[sz]; Marshal.Copy(p, b, 0, (int)sz); return b; } finally { LocalFree(p); }
        }
        static List<string> GetDeskContainerSids(IntPtr hDesk)
        {
            List<string> res = new List<string>();
            RawSecurityDescriptor sd = new RawSecurityDescriptor(GetObjSd(hDesk, 4), 0);
            if (sd.DiscretionaryAcl == null) return res;
            foreach (GenericAce ga in sd.DiscretionaryAcl)
            {
                CommonAce ace = ga as CommonAce;
                if (ace == null || ace.AceQualifier != AceQualifier.AccessAllowed) continue;
                string s = ace.SecurityIdentifier.Value;
                if (s.StartsWith("S-1-15-2-", StringComparison.Ordinal) && s.Length > 14 && !res.Contains(s)) res.Add(s);
            }
            return res;
        }
        static string BuildDeskSddl(string[] acSids, bool withOwner, bool withLabel)
        {
            string u = WindowsIdentity.GetCurrent().User.Value, logon = null;
            using (WindowsIdentity wi = WindowsIdentity.GetCurrent())
                foreach (IdentityReference ir in wi.Groups) if (ir.Value.StartsWith("S-1-5-5-", StringComparison.Ordinal)) { logon = ir.Value; break; }
            StringBuilder d = new StringBuilder("D:P(A;;0x000F01FF;;;SY)(A;;0x000F01FF;;;BA)(A;;0x000F01FF;;;S-1-5-90-0)(A;;0x000F01FF;;;" + u + ")");
            if (logon != null && !string.Equals(logon, u, StringComparison.OrdinalIgnoreCase)) d.Append("(A;;0x000F01FF;;;" + logon + ")");
            foreach (string s in acSids) d.Append("(A;;0x000200CF;;;" + new SecurityIdentifier(s).Value + ")");
            return (withOwner ? "O:" + u + "G:" + u : "") + d.ToString() + (withLabel ? "S:(ML;;NW;;;LW)" : "");
        }
        static void ApplyDeskSec(IntPtr hDesk, string[] acSids)
        {
            uint dSi = 0x80000004U, lSi = 0x00000010U;
            if (!SetUserObjectSecurity(hDesk, ref dSi, SddlBytes(BuildDeskSddl(acSids, false, false)))) throw new Win32Exception(Marshal.GetLastWin32Error());
            if (!SetUserObjectSecurity(hDesk, ref lSi, SddlBytes("S:(ML;;NW;;;LW)"))) throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        static string CheckDeskSec(IntPtr hDesk, string expAcSid, bool allowMulti)
        {
            RawSecurityDescriptor sd = new RawSecurityDescriptor(GetObjSd(hDesk, 4), 0);
            if (sd.DiscretionaryAcl == null || sd.DiscretionaryAcl.Count == 0) return "Empty/NULL DACL";
            bool hasTarget = false, seenExp = string.IsNullOrEmpty(expAcSid); int acCount = 0;
            foreach (GenericAce ga in sd.DiscretionaryAcl)
            {
                CommonAce ace = ga as CommonAce;
                if (ace == null) return "Unsupported ACE type";
                if (ace.AceQualifier != AceQualifier.AccessAllowed) continue;
                string s = ace.SecurityIdentifier.Value;
                if (s == "S-1-1-0" || s == "S-1-5-32-545" || s == "S-1-5-11" || s == "S-1-5-4" || s == "S-1-2-0" || s == "S-1-15-2-1" || s == "S-1-15-2-2" || s.StartsWith("S-1-15-3-", StringComparison.Ordinal))
                    return "Unsafe Allow ACE: " + s;
                if (s.StartsWith("S-1-15-2-", StringComparison.Ordinal))
                {
                    acCount++;
                    if (!allowMulti && !string.IsNullOrEmpty(expAcSid) && !string.Equals(s, expAcSid, StringComparison.OrdinalIgnoreCase)) return "Foreign container SID: " + s;
                    if (!allowMulti && acCount > 1) return "Multiple container SIDs";
                    if (!string.IsNullOrEmpty(expAcSid) && string.Equals(s, expAcSid, StringComparison.OrdinalIgnoreCase)) seenExp = true;
                    uint m = unchecked((uint)ace.AccessMask);
                    if ((m & 0xC3U) != 0xC3U || (m & 0x000D0130U) != 0) return "Invalid container mask 0x" + m.ToString("X");
                    hasTarget = true;
                }
            }
            if (!hasTarget || !seenExp) return "Missing container ACE";
            IntPtr pLbl; uint lLen;
            if (!ConvertSecurityDescriptorToStringSecurityDescriptor(GetObjSd(hDesk, 0x10), 1, 0x10, out pLbl, out lLen)) return "Missing integrity label";
            string lbl = Marshal.PtrToStringUni(pLbl) ?? ""; LocalFree(pLbl);
            return (lbl.IndexOf("LW", StringComparison.OrdinalIgnoreCase) >= 0 && lbl.IndexOf("NW", StringComparison.OrdinalIgnoreCase) >= 0) ? null : ("Bad label: " + lbl);
        }
        static IntPtr EnsureIsolatedDesktop(string shortName, string acSid, bool allowShared)
        {
            if (string.IsNullOrEmpty(shortName) || !shortName.StartsWith("acm.desk.", StringComparison.OrdinalIgnoreCase))
                throw new Exception("Isolated desktop name must start with 'acm.desk.'.");
            string ws = GetObjName(GetProcessWindowStation());
            if (!string.Equals(ws, "WinSta0", StringComparison.OrdinalIgnoreCase)) throw new Exception("Isolated desktops require WinSta0 (current: '" + ws + "').");
            IntPtr hDesk = OpenDesktopW(shortName, 0, false, DESK_MANAGE);
            if (hDesk != IntPtr.Zero)
            {
                try
                {
                    List<string> sids = new List<string>();
                    if (allowShared)
                    {
                        string preErr = CheckDeskSec(hDesk, null, true);
                        if (preErr != null) throw new Exception("Existing shared desktop isolation check failed: " + preErr);
                        sids.AddRange(GetDeskContainerSids(hDesk));
                    }
                    if (!sids.Contains(acSid)) sids.Add(acSid);
                    try { ApplyDeskSec(hDesk, sids.ToArray()); } catch { }
                    string e = CheckDeskSec(hDesk, acSid, allowShared);
                    if (e != null) throw new Exception("Existing desktop isolation check failed: " + e);
                    return hDesk;
                }
                catch { CloseDesktop(hDesk); throw; }
            }
            int oe = Marshal.GetLastWin32Error();
            if (oe == 5) throw new Exception("Desktop '" + shortName + "' already exists and denies access.");
            if (oe != 2 && oe != 1168) throw new Win32Exception(oe);
            int ce = 0; string[] oneSid = new[] { acSid };
            foreach (string sddl in new[] { BuildDeskSddl(oneSid, true, true), BuildDeskSddl(oneSid, false, true), BuildDeskSddl(oneSid, false, false) })
            {
                IntPtr pSd; uint sz;
                if (!ConvertStringSecurityDescriptorToSecurityDescriptor(sddl, 1, out pSd, out sz)) { ce = Marshal.GetLastWin32Error(); continue; }
                try
                {
                    SECURITY_ATTRIBUTES sa = new SECURITY_ATTRIBUTES { nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES)), lpSecurityDescriptor = pSd };
                    hDesk = CreateDesktopW(shortName, null, IntPtr.Zero, 0, DESK_MANAGE, ref sa);
                    if (hDesk != IntPtr.Zero) break;
                    ce = Marshal.GetLastWin32Error();
                    if (ce != 1307 && ce != 1314 && ce != 5 && ce != 87) break;
                }
                finally { LocalFree(pSd); }
            }
            if (hDesk == IntPtr.Zero)
            {
                if (ce == 8 || ce == 14) throw new Exception("CreateDesktopW failed (session desktop heap exhausted; close unused desktops in Desktop Manager).");
                throw new Win32Exception(ce);
            }
            try { ApplyDeskSec(hDesk, oneSid); string e = CheckDeskSec(hDesk, acSid, allowShared); if (e != null) throw new Exception("Desktop integrity check failed: " + e); return hDesk; }
            catch { CloseDesktop(hDesk); throw; }
        }
        public static string FindFirstActiveIsolatedDesktop(string fallbackContainerName)
        {
            foreach (string d in EnumerateManagedDesktops("acm.desk."))
            {
                IntPtr h = OpenDesktopW(d, 0, false, 0x00020081U);
                if (h == IntPtr.Zero) continue;
                try
                {
                    if (CheckDeskSec(h, null, true) != null) continue;
                    bool alive = GetDesktopProcessPids(d).Length > 0;
                    if (!alive)
                    {
                        foreach (string s in GetDeskContainerSids(h))
                            if (GetContainerPids(s).Length > 0) { alive = true; break; }
                    }
                    if (alive) return "WinSta0\\" + d;
                }
                catch { }
                finally { CloseDesktop(h); }
            }
            string clean = System.Text.RegularExpressions.Regex.Replace(fallbackContainerName ?? "app", "[^A-Za-z0-9._-]", "_").Trim('.', '_', '-');
            return "WinSta0\\acm.desk." + (clean.Length > 0 ? clean : "app");
        }
        static uint DeskAccessCheck(byte[] sdBytes, IntPtr hImp, uint desired)
        {
            GENERIC_MAPPING gm = new GENERIC_MAPPING { GenericRead = 0x20041U, GenericWrite = 0x2009EU, GenericExecute = 0x20100U, GenericAll = 0xF01FFU };
            IntPtr pSd = Marshal.AllocHGlobal(sdBytes.Length), pPriv = Marshal.AllocHGlobal(1024);
            try
            {
                Marshal.Copy(sdBytes, 0, pSd, sdBytes.Length);
                uint plen = 1024, granted = 0; bool ok = false;
                return (AccessCheck(pSd, hImp, desired, ref gm, pPriv, ref plen, out granted, out ok) && ok) ? granted : 0U;
            }
            finally { Marshal.FreeHGlobal(pPriv); Marshal.FreeHGlobal(pSd); }
        }
        static void VerifyLaunchDesktop(IntPtr hDesk, IntPtr hTok, IntPtr hImp, string acSid, bool allowShared)
        {
            int tl = 0; GetTokenInformation(hTok, 31, IntPtr.Zero, 0, out tl);
            if (tl <= 0) throw new Exception("Missing TokenAppContainerSid.");
            IntPtr tb = Marshal.AllocHGlobal(tl);
            try { int rl; if (!GetTokenInformation(hTok, 31, tb, tl, out rl) || !string.Equals(SidToString(Marshal.ReadIntPtr(tb)), acSid, StringComparison.OrdinalIgnoreCase)) throw new Exception("Child AppContainer SID mismatch."); }
            finally { Marshal.FreeHGlobal(tb); }
            string secErr = CheckDeskSec(hDesk, acSid, allowShared);
            if (secErr != null) throw new Exception("Desktop integrity check failed: " + secErr);
            byte[] sd = GetObjSd(hDesk, 0x17);
            uint g = DeskAccessCheck(sd, hImp, 0x02000000U);
            if ((g & 0xC3U) != 0xC3U || (g & 0x00040100U) != 0) throw new Exception("Isolated desktop token AccessCheck failed (granted=0x" + g.ToString("X") + ").");
        }
        public static string[] EnumerateManagedDesktops(string prefix)
        {
            List<string> res = new List<string>();
            EnumDesktopProc cb = delegate(string n, IntPtr lp) { if (!string.IsNullOrEmpty(n) && (string.IsNullOrEmpty(prefix) || n.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))) res.Add(n); return true; };
            if (!EnumDesktopsW(GetProcessWindowStation(), cb, IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error());
            GC.KeepAlive(cb); res.Sort(StringComparer.OrdinalIgnoreCase); return res.ToArray();
        }
        public static string[] GetDesktopProcessPids(string shortName)
        {
            HashSet<uint> pids = new HashSet<uint>();
            IntPtr h = OpenDesktopW(shortName, 0, false, 0x41U);
            if (h == IntPtr.Zero) return new string[0];
            try { EnumWindowsProc cb = delegate(IntPtr w, IntPtr lp) { uint p; GetWindowThreadProcessId(w, out p); if (p != 0) pids.Add(p); return true; }; EnumDesktopWindows(h, cb, IntPtr.Zero); GC.KeepAlive(cb); }
            finally { CloseDesktop(h); }
            List<string> list = new List<string>();
            foreach (uint p in pids) { string nm = "pid"; try { using (var pr = System.Diagnostics.Process.GetProcessById((int)p)) nm = pr.ProcessName; } catch { } list.Add(p + "|" + nm); }
            return list.ToArray();
        }
        public static string InspectDesktopSecurity(string shortName, string expAcSid)
        {
            IntPtr h = OpenDesktopW(shortName, 0, false, 0x00020081U);
            if (h == IntPtr.Zero) { int e = Marshal.GetLastWin32Error(); return e == 5 ? "ACCESS_DENIED|Denies inspection" : "WARN|Error " + e; }
            try { string err = CheckDeskSec(h, expAcSid, true); return err == null ? "OK|Isolated (Low/NW, strict container DACL)" : ("WARN|" + err); }
            catch (Exception ex) { return "WARN|" + ex.Message; } finally { CloseDesktop(h); }
        }
        public static void ReSecureDesktop(string shortName, string containerName)
        {
            string acSid = GetSidString(containerName);
            IntPtr h = OpenDesktopW(shortName, 0, false, DESK_MANAGE);
            if (h == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            try { string[] one = new[] { acSid }; ApplyDeskSec(h, one); string e = CheckDeskSec(h, acSid, false); if (e != null) throw new Exception(e); } finally { CloseDesktop(h); }
        }
        public static IntPtr CreateInheritableEvent()
        {
            SECURITY_ATTRIBUTES sa = new SECURITY_ATTRIBUTES { nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES)), bInheritHandle = true };
            IntPtr h = CreateEventW(ref sa, false, false, null);
            if (h == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            return h;
        }
        public static void SignalEvent(IntPtr h) { if (h != IntPtr.Zero) SetEvent(h); }
        public static bool WaitEvent(IntPtr h, int ms) { return h != IntPtr.Zero && WaitForSingleObject(h, unchecked((uint)ms)) == 0U; }
        public static IntPtr OpenProcessWait(int pid) { return OpenProcess(0x00100000U, false, (uint)pid); }
        public static void CloseKernelHandle(IntPtr h) { if (h != IntPtr.Zero) CloseHandle(h); }
        public static int StartHiddenOnDesktop(string exe, string cmdLine, string shortDesktop, bool inheritHandles)
        {
            STARTUPINFO si = new STARTUPINFO(); si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
            if (!string.IsNullOrEmpty(shortDesktop)) si.lpDesktop = "WinSta0\\" + shortDesktop;
            string fullCmd = "\"" + exe + "\" " + cmdLine;
            StringBuilder cmd = new StringBuilder(fullCmd, Math.Max(fullCmd.Length + 1, 1024));
            PROCESS_INFORMATION pi;
            if (!CreateProcessW(exe, cmd, IntPtr.Zero, IntPtr.Zero, inheritHandles, CREATE_NO_WINDOW, IntPtr.Zero, null, ref si, out pi))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
            return (int)pi.dwProcessId;
        }
        public static void RegisterSessionUnlock(IntPtr hwnd, bool enable)
        {
            if (enable) WTSRegisterSessionNotification(hwnd, 0); else WTSUnRegisterSessionNotification(hwnd);
        }
        public static void RegisterKeyboardRawInput(IntPtr hwnd)
        {
            RAWINPUTDEVICE[] rid = new RAWINPUTDEVICE[1];
            rid[0] = new RAWINPUTDEVICE { usUsagePage = 1, usUsage = 6, dwFlags = 0x100U, hwndTarget = hwnd };
            RegisterRawInputDevices(rid, 1, (uint)Marshal.SizeOf(typeof(RAWINPUTDEVICE)));
        }
        public static int GetRawKeyAction(IntPtr lParam)
        {
            RAWINPUT_KB kb; uint sz = (uint)Marshal.SizeOf(typeof(RAWINPUT_KB));
            if (GetRawInputData(lParam, 0x10000003U, out kb, ref sz, (uint)Marshal.SizeOf(typeof(RAWINPUTHEADER))) == unchecked((uint)-1)) return 0;
            if (kb.header.dwType != 1U) return 0;
            bool down = (kb.keyboard.Flags & 1) == 0, e0 = (kb.keyboard.Flags & 2) != 0;
            if (kb.keyboard.VKey == 0x11 && down && e0) return 1; // Right Ctrl
            if ((kb.keyboard.VKey == 0x12 || kb.keyboard.VKey == 0xA4 || kb.keyboard.VKey == 0xA5) && !down) return 7; // Alt up
            if (kb.keyboard.VKey == 0x1B && down) return 8; // Esc
            if (kb.keyboard.VKey == 0x09 && down && (GetAsyncKeyState(0x12) & 0x8000) != 0)
                return ((GetAsyncKeyState(0x10) & 0x8000) != 0) ? 6 : 2; // Alt+Shift+Tab : Alt+Tab
            if (kb.keyboard.VKey == 0x5B || kb.keyboard.VKey == 0x5C) return down ? 3 : 4; // Win down/up
            return down ? 5 : 0;
        }
        [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
        public static void EnableDpiAware() { try { SetProcessDPIAware(); } catch { } }
        public static bool IsRightCtrlDownAsync() { return (GetAsyncKeyState(0xA3) & 0x8000) != 0; }
        public static bool IsAltDownAsync() { return (GetAsyncKeyState(0x12) & 0x8000) != 0; }
        public static bool IsRightMouseDownAsync() { return (GetAsyncKeyState(0x02) & 0x8000) != 0; }
        public static IntPtr GetActiveWindowHandle() { return GetForegroundWindow(); }
        public static IntPtr GetWindowIconHandle(IntPtr hwnd)
        {
            IntPtr hIcon = IntPtr.Zero;
            if (SendMessageTimeoutW(hwnd, 0x007FU, new IntPtr(2), IntPtr.Zero, 0x0002U, 80, out hIcon) != IntPtr.Zero && hIcon != IntPtr.Zero) return hIcon;
            if (SendMessageTimeoutW(hwnd, 0x007FU, IntPtr.Zero, IntPtr.Zero, 0x0002U, 80, out hIcon) != IntPtr.Zero && hIcon != IntPtr.Zero) return hIcon;
            if (SendMessageTimeoutW(hwnd, 0x007FU, new IntPtr(1), IntPtr.Zero, 0x0002U, 80, out hIcon) != IntPtr.Zero && hIcon != IntPtr.Zero) return hIcon;
            hIcon = (IntPtr.Size == 8) ? GetClassLongPtr64(hwnd, -34) : new IntPtr(GetClassLong32(hwnd, -34));
            if (hIcon != IntPtr.Zero) return hIcon;
            return (IntPtr.Size == 8) ? GetClassLongPtr64(hwnd, -14) : new IntPtr(GetClassLong32(hwnd, -14));
        }
        public static string GetProcessImagePath(uint pid)
        {
            IntPtr hp = OpenProcess(0x1000U, false, pid);
            if (hp == IntPtr.Zero) return "";
            try
            {
                StringBuilder sb = new StringBuilder(1024); uint sz = (uint)sb.Capacity;
                return QueryFullProcessImageNameW(hp, 0, sb, ref sz) ? sb.ToString() : "";
            }
            finally { CloseHandle(hp); }
        }
        public static string[] GetDesktopAppWindows(string shortName, uint excludePid)
        {
            List<string> res = new List<string>();
            IntPtr h = OpenDesktopW(shortName, 0, false, 0x41U);
            if (h == IntPtr.Zero) return res.ToArray();
            try
            {
                EnumWindowsProc cb = delegate(IntPtr w, IntPtr lp)
                {
                    if (!IsWindowVisible(w) || GetWindow(w, 4) != IntPtr.Zero || (GetWindowLongW(w, -20) & 0x80) != 0) return true;
                    uint pid; GetWindowThreadProcessId(w, out pid);
                    if (pid == 0 || pid == excludePid) return true;
                    StringBuilder sb = new StringBuilder(128);
                    if (GetWindowTextW(w, sb, sb.Capacity) <= 0) return true;
                    res.Add(w.ToInt64().ToString() + "|" + pid.ToString() + "|" + sb.ToString().Replace("|", " "));
                    return true;
                };
                EnumDesktopWindows(h, cb, IntPtr.Zero); GC.KeepAlive(cb);
            }
            finally { CloseDesktop(h); }
            return res.ToArray();
        }
        public static string[] GetDesktopContainerPids(string shortName)
        {
            List<string> res = new List<string>();
            IntPtr h = OpenDesktopW(shortName, 0, false, 0x00020001U);
            if (h == IntPtr.Zero) return res.ToArray();
            try { foreach (string cs in GetDeskContainerSids(h)) res.AddRange(GetContainerPids(cs)); }
            catch { }
            finally { CloseDesktop(h); }
            return res.ToArray();
        }
        public static bool IsDesktopInUse(string shortName, uint excludePid)
        {
            foreach (string s in GetDesktopProcessPids(shortName))
            {
                int i = s.IndexOf('|'); uint p;
                if (i > 0 && uint.TryParse(s.Substring(0, i), out p) && p != excludePid) return true;
            }
            IntPtr h = OpenDesktopW(shortName, 0, false, 0x00020001U);
            if (h != IntPtr.Zero)
            {
                try
                {
                    foreach (string cs in GetDeskContainerSids(h))
                        if (GetContainerPids(cs).Length > 0) return true;
                }
                catch { }
                finally { CloseDesktop(h); }
            }
            return false;
        }
        public static void ActivateAppWindow(IntPtr hwnd) { if (IsIconic(hwnd)) ShowWindowAsync(hwnd, 9); SwitchToThisWindow(hwnd, true); SetForegroundWindow(hwnd); }
        public static void MinimizeAppWindow(IntPtr hwnd) { ShowWindowAsync(hwnd, 6); }
        public static void CloseAppWindow(IntPtr hwnd) { PostMessageW(hwnd, 0x0010U, IntPtr.Zero, IntPtr.Zero); }
        public static void SetWindowZ(IntPtr hwnd, bool topMost) { SetWindowPos(hwnd, topMost ? new IntPtr(-1) : new IntPtr(1), 0, 0, 0, 0, 0x0013U); }
        public static void SwitchToDesktopByName(string shortName)
        {
            IntPtr h = OpenDesktopW(shortName, 0, false, 0x0100U);
            if (h == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            try { if (!SwitchDesktop(h)) throw new Win32Exception(Marshal.GetLastWin32Error()); } finally { CloseDesktop(h); }
        }
        public static int TerminateDesktopProcesses(string shortName, string optSid)
        {
            HashSet<uint> pids = new HashSet<uint>(); uint self = (uint)System.Diagnostics.Process.GetCurrentProcess().Id;
            List<string> entries = new List<string>(GetDesktopProcessPids(shortName));
            if (!string.IsNullOrEmpty(optSid)) entries.AddRange(GetContainerPids(optSid));
            IntPtr h = OpenDesktopW(shortName, 0, false, 0x00020001U);
            if (h != IntPtr.Zero)
            {
                try { foreach (string cs in GetDeskContainerSids(h)) entries.AddRange(GetContainerPids(cs)); }
                catch { }
                finally { CloseDesktop(h); }
            }
            foreach (string s in entries) { int i = s.IndexOf('|'); uint p; if (i > 0 && uint.TryParse(s.Substring(0, i), out p) && p != self) pids.Add(p); }
            int k = 0; foreach (uint p in pids) { IntPtr hp = OpenProcess(1, false, p); if (hp != IntPtr.Zero) { try { if (TerminateProcess(hp, 1)) k++; } finally { CloseHandle(hp); } } }
            return k;
        }
        public static bool DesktopExists(string shortName) { IntPtr h = OpenDesktopW(shortName, 0, false, 0x41U); if (h != IntPtr.Zero) { CloseDesktop(h); return true; } return Marshal.GetLastWin32Error() == 5; }

        public static void Launch(LaunchOptions o)
        {
            IntPtr acSid = IntPtr.Zero, caps = IntPtr.Zero, sc = IntPtr.Zero, attr = IntPtr.Zero;
            IntPtr pAap = IntPtr.Zero, pMit = IntPtr.Zero, pChild = IntPtr.Zero, env = IntPtr.Zero, job = IntPtr.Zero, iocp = IntPtr.Zero, hDesk = IntPtr.Zero;
            List<IntPtr> sids = new List<IntPtr>();
            PROCESS_INFORMATION pi = new PROCESS_INFORMATION();
            string acSidStr = null, shortDesk = null;
            bool created = false, attrInit = false, success = false;
            try
            {
                int winBuild = GetWindowsBuild();
                if (o.Lpac && winBuild > 0 && winBuild < 15063)
                    throw new Exception("LPAC requires Windows 10 version 1703 (build 15063) or newer (detected build " + winBuild + ").");
                Hr(DeriveAppContainerSidFromAppContainerName(o.ContainerName, out acSid), "DeriveAppContainerSid");
                int n = o.CapabilitySids == null ? 0 : o.CapabilitySids.Length;
                int sa = Marshal.SizeOf(typeof(SID_AND_ATTRIBUTES));
                if (n > 0) caps = Marshal.AllocHGlobal(sa * n);
                for (int i = 0; i < n; i++)
                {
                    IntPtr s;
                    if (!ConvertStringSidToSid(o.CapabilitySids[i], out s)) throw new Exception("Bad capability SID: " + o.CapabilitySids[i]);
                    sids.Add(s);
                    SID_AND_ATTRIBUTES x = new SID_AND_ATTRIBUTES(); x.Sid = s; x.Attributes = SE_GROUP_ENABLED;
                    Marshal.StructureToPtr(x, IntPtr.Add(caps, i * sa), false);
                }
                SECURITY_CAPABILITIES secCaps = new SECURITY_CAPABILITIES();
                secCaps.AppContainerSid = acSid; secCaps.Capabilities = caps; secCaps.CapabilityCount = (uint)n;
                sc = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(SECURITY_CAPABILITIES)));
                Marshal.StructureToPtr(secCaps, sc, false);

                ulong m1 = o.Mitigation, m2 = o.Mitigation2;
// Bits 0..2 = DEP_ENABLE | DEP_ATL_THUNK_ENABLE | SEHOP_ENABLE (32-bit only).
// Hardware DEP is always enforced on x64. passing these bits for a 64-bit EXE fails CreateProcessW.
                if ((m1 & 0x7UL) != 0 && !Is32BitExe(o.Exe)) m1 &= ~0x7UL;
                if (winBuild > 0)
                {
                    if (winBuild < 10240 && (m1 & (1UL << 48)) != 0)
                    {
                        m1 &= ~(1UL << 48);
                        o.Warnings.Add("NoFonts mitigation skipped: requires Windows 10 build 10240+.");
                    }
                    if (winBuild < 10586 && (m1 & ((1UL << 52) | (1UL << 56))) != 0)
                    {
                        m1 &= ~((1UL << 52) | (1UL << 56));
                        o.Warnings.Add("ImgNoRemote/ImgNoLowLabel mitigations skipped: requires Windows 10 build 10586+.");
                    }
                    if (winBuild < 14393 && (m1 & (1UL << 60)) != 0)
                    {
                        m1 &= ~(1UL << 60);
                        o.Warnings.Add("ImgPreferSys32 mitigation skipped: requires Windows 10 build 14393+.");
                    }
                    if (winBuild < 15063)
                    {
                        if (m2 != 0) o.Warnings.Add("POLICY2 mitigations skipped: requires Windows 10 1703+ (build 15063+).");
                        m2 = 0;
                    }
                    else
                    {
                        if (winBuild < 17763 && (m2 & ((1UL << 16) | (1UL << 24))) != 0)
                        {
                            m2 &= ~((1UL << 16) | (1UL << 24));
                            o.Warnings.Add("RestrictIbp/Ssbd mitigations skipped: requires Windows 10 1809 (build 17763+); current build " + winBuild + ".");
                        }
                        if (winBuild < 19041 && (m2 & (1UL << 28)) != 0)
                        {
                            m2 &= ~(1UL << 28);
                            o.Warnings.Add("CET Shadow Stack mitigation skipped: requires Windows 10 2004 (build 19041+); current build " + winBuild + ".");
                        }
                        if (winBuild < 25295 && (m2 & (1UL << 56)) != 0)
                        {
                            m2 &= ~(1UL << 56);
                            o.Warnings.Add("FSCTL disable mitigation skipped: requires Windows 11 build 25295+ / 24H2 (current build " + winBuild + ").");
                        }
                    }
                }
                bool useMit = (m1 != 0 || m2 != 0);
                int count = 1 + (o.Lpac ? 1 : 0) + (useMit ? 1 : 0) + (o.ChildRestrict ? 1 : 0);
                IntPtr size = IntPtr.Zero;
                InitializeProcThreadAttributeList(IntPtr.Zero, count, 0, ref size);
                attr = Marshal.AllocHGlobal(size);
                if (!InitializeProcThreadAttributeList(attr, count, 0, ref size)) throw new Win32Exception(Marshal.GetLastWin32Error());
                attrInit = true;
                SetAttr(attr, ATTR_SECURITY_CAPABILITIES, sc, Marshal.SizeOf(typeof(SECURITY_CAPABILITIES)));
// 1 = PROCESS_CREATION_ALL_APPLICATION_PACKAGES_OPT_OUT (LPAC: drop S-1-15-2-1). Keep pAap alive until DeleteProcThreadAttributeList
                if (o.Lpac) { pAap = Marshal.AllocHGlobal(4); Marshal.WriteInt32(pAap, 1); SetAttr(attr, ATTR_ALL_APP_PACKAGES_POLICY, pAap, 4); }
                if (useMit)
                {
                    if (m2 != 0)
                    {
                        pMit = Marshal.AllocHGlobal(16);
                        Marshal.WriteInt64(pMit, 0, unchecked((long)m1));
                        Marshal.WriteInt64(pMit, 8, unchecked((long)m2));
                        SetAttr(attr, ATTR_MITIGATION_POLICY, pMit, 16);
                    }
                    else
                    {
                        pMit = Marshal.AllocHGlobal(8);
                        Marshal.WriteInt64(pMit, unchecked((long)m1));
                        SetAttr(attr, ATTR_MITIGATION_POLICY, pMit, 8);
                    }
                }
// 1 = PROCESS_CREATION_CHILD_PROCESS_RESTRICTED (prevent child process creation)
                if (o.ChildRestrict) { pChild = Marshal.AllocHGlobal(4); Marshal.WriteInt32(pChild, 1); SetAttr(attr, ATTR_CHILD_PROCESS_POLICY, pChild, 4); }

                acSidStr = SidToString(acSid);
                if (o.IsolateDesktop)
                {
                    if ((o.JobUiFlags & 0x61U) != 0x61U) throw new Exception("Security error: IsolateDesktop requires JOB_OBJECT_UILIMIT_HANDLES | GLOBALATOMS | DESKTOP.");
                    if (o.CapabilitySids != null)
                    {
                        try { foreach (string gs in DeriveCapability("graphicsCapture")) if (Array.Exists(o.CapabilitySids, delegate(string x) { return string.Equals(x, gs, StringComparison.OrdinalIgnoreCase); })) throw new Exception("Security error: graphicsCapture blocked with IsolateDesktop."); } catch (Win32Exception) { }
                        if (!o.AllowMic && Array.Exists(o.CapabilitySids, delegate(string x) { return string.Equals(x, "S-1-15-3-787448254-1207972858-3558633622-1059886964", StringComparison.OrdinalIgnoreCase); }))
                            throw new Exception("Security error: audio capture SID present while Dev.Mic is off.");
                    }
                    int sl = o.Desktop == null ? -1 : o.Desktop.IndexOf('\\');
                    if (sl <= 0 || !string.Equals(o.Desktop.Substring(0, sl), "WinSta0", StringComparison.OrdinalIgnoreCase)) throw new Exception("Isolated desktop must be WinSta0\\<name>.");
                    shortDesk = o.Desktop.Substring(sl + 1);
                    hDesk = EnsureIsolatedDesktop(shortDesk, acSidStr, o.AllowSharedDesktop);
                }

                STARTUPINFOEX si = new STARTUPINFOEX();
                si.StartupInfo.cb = Marshal.SizeOf(typeof(STARTUPINFOEX));
                if (!string.IsNullOrEmpty(o.Desktop)) si.StartupInfo.lpDesktop = o.Desktop;
                si.lpAttributeList = attr;
                // Start suspended so no target/DLL code executes before we verify the AppContainer/LPAC token
                // and assign the process to the Job Object
                uint flags = EXTENDED_STARTUPINFO_PRESENT | CREATE_SUSPENDED;
                // CREATE_UNICODE_ENVIRONMENT requires a null-separated block ending with an extra null terminator (\0\0)
                if (o.Env != null) { env = Marshal.StringToHGlobalUni(string.Join("\0", o.Env) + "\0\0"); flags |= CREATE_UNICODE_ENVIRONMENT; }
                if (o.NewConsole) flags |= CREATE_NEW_CONSOLE;
                else flags |= CREATE_NO_WINDOW;
                // CreateProcessW may mutate lpCommandLine in place, so pass a writable StringBuilder buffer
                StringBuilder cmd = new StringBuilder(o.CommandLine, Math.Max(o.CommandLine.Length + 1, 1024));
                if (!CreateProcessW(o.Exe, cmd, IntPtr.Zero, IntPtr.Zero, false, flags, env, o.WorkDir, ref si, out pi))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                created = true;

                IntPtr hTok;
                if (!OpenProcessToken(pi.hProcess, 0x000A /* TOKEN_QUERY | TOKEN_DUPLICATE */, out hTok))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                try
                {
                    IntPtr buf = Marshal.AllocHGlobal(4);
                    try
                    {
                        int retLen;
                        if (!GetTokenInformation(hTok, 29 /* TokenIsAppContainer */, buf, 4, out retLen) || Marshal.ReadInt32(buf) == 0)
                            throw new Exception("Security error: child process is NOT running inside an AppContainer.");
                    }
                    finally { Marshal.FreeHGlobal(buf); }
                    if (o.Lpac)
                    {
                        IntPtr hImp = IntPtr.Zero, pSd = IntPtr.Zero, pPriv = Marshal.AllocHGlobal(1024);
                        try
                        {
                            if (!DuplicateToken(hTok, 2 /* SecurityImpersonation */, out hImp))
                                throw new Win32Exception(Marshal.GetLastWin32Error());
                            uint sdSize = 0, privLen = 1024, granted = 0; bool allowed = false;
// Verify LPAC enforcement via AccessCheck against a synthetic DACL
// Windows AppContainer AccessCheck requires BOTH a user/WD match and a package-SID match:
//   - WD (Everyone) = 0x3 (Read|Write): satisfies the user-SID gate for both bits
//   - AC (S-1-15-2-1, ALL APPLICATION PACKAGES) = 0x1: granted ONLY if LPAC failed to strip S-1-15-2-1
//   - S-1-15-2-2 (ALL RESTRICTED APPLICATION PACKAGES) = 0x2: granted when LPAC is active
// Expected result under LPAC: bit 0x1 clear and bit 0x2 set
                            if (!ConvertStringSecurityDescriptorToSecurityDescriptor("O:SYG:SYD:(A;;0x3;;;WD)(A;;0x1;;;AC)(A;;0x2;;;S-1-15-2-2)", 1, out pSd, out sdSize))
                                throw new Win32Exception(Marshal.GetLastWin32Error());
                            GENERIC_MAPPING gm = new GENERIC_MAPPING { GenericRead = 1, GenericWrite = 2, GenericExecute = 1, GenericAll = 3 };
                            if (!AccessCheck(pSd, hImp, 0x02000000 /* MAXIMUM_ALLOWED */, ref gm, pPriv, ref privLen, out granted, out allowed))
                                throw new Win32Exception(Marshal.GetLastWin32Error());
                            if (!allowed || (granted & 0x1) != 0 || (granted & 0x2) == 0)
                                throw new Exception("Security error: LPAC policy was not applied (ALL APPLICATION PACKAGES S-1-15-2-1 is still active).");
                        }
                        finally
                        {
                            Marshal.FreeHGlobal(pPriv);
                            if (pSd != IntPtr.Zero) LocalFree(pSd);
                            if (hImp != IntPtr.Zero) CloseHandle(hImp);
                        }
                    }
                    if (o.IsolateDesktop)
                    {
                        IntPtr hImpDesk = IntPtr.Zero;
                        try
                        {
                            if (!DuplicateToken(hTok, 2, out hImpDesk)) throw new Win32Exception(Marshal.GetLastWin32Error());
                            VerifyLaunchDesktop(hDesk, hTok, hImpDesk, acSidStr, o.AllowSharedDesktop);
                        }
                        finally { if (hImpDesk != IntPtr.Zero) CloseHandle(hImpDesk); }
                    }
                }
                finally { CloseHandle(hTok); }

                if (o.KillOnClose) o.Wait = true;
                job = CreateJobObjectW(IntPtr.Zero, null);
                if (job == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
                JOBOBJECT_EXTENDED_LIMIT_INFORMATION li = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
                // LimitFlags: 0x2000=KILL_ON_JOB_CLOSE, 0x0008=ACTIVE_PROCESS, 0x0100=PROCESS_MEMORY, 0x0200=JOB_MEMORY
                if (o.KillOnClose) li.Basic.LimitFlags |= 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
                if (o.MaxProcesses > 0) { li.Basic.LimitFlags |= 0x0008; li.Basic.ActiveProcessLimit = o.MaxProcesses; }
                if (o.ProcessMemMb > 0)
                {
                    ulong bytes = checked(o.ProcessMemMb * 1024UL * 1024UL);
                    // Clamp >4 GB memory limits when running under 32-bit PowerShell so UIntPtr doesn't overflow
                    if (IntPtr.Size == 4 && bytes > uint.MaxValue) bytes = uint.MaxValue;
                    li.Basic.LimitFlags |= 0x0100; li.ProcessMemoryLimit = new UIntPtr(bytes);
                }
                if (o.JobMemMb > 0)
                {
                    ulong bytes = checked(o.JobMemMb * 1024UL * 1024UL);
                    if (IntPtr.Size == 4 && bytes > uint.MaxValue) bytes = uint.MaxValue;
                    li.Basic.LimitFlags |= 0x0200; li.JobMemoryLimit = new UIntPtr(bytes);
                }
                if (li.Basic.LimitFlags != 0)
                {
                    int len = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
                    IntPtr pli = Marshal.AllocHGlobal(len); Marshal.StructureToPtr(li, pli, false);
                    // Info class 9 = JobObjectExtendedLimitInformation
                    bool ok = SetInformationJobObject(job, 9, pli, (uint)len); int err = Marshal.GetLastWin32Error();
                    Marshal.FreeHGlobal(pli); if (!ok) throw new Win32Exception(err);
                }
                if (o.CpuRatePct > 0 && o.CpuRatePct <= 100)
                {
                    JOBOBJECT_CPU_RATE_CONTROL_INFORMATION cpu = new JOBOBJECT_CPU_RATE_CONTROL_INFORMATION();
                    cpu.ControlFlags = 0x5; // JOB_OBJECT_CPU_RATE_CONTROL_ENABLE | HARD_CAP
                    cpu.CpuRate = o.CpuRatePct * 100U;
                    int clen = Marshal.SizeOf(typeof(JOBOBJECT_CPU_RATE_CONTROL_INFORMATION));
                    IntPtr pcpu = Marshal.AllocHGlobal(clen); Marshal.StructureToPtr(cpu, pcpu, false);
                    bool ok = SetInformationJobObject(job, 15, pcpu, (uint)clen); int err = Marshal.GetLastWin32Error();
                    Marshal.FreeHGlobal(pcpu);
                    if (!ok)
                    {
                        if (err == 50) o.Warnings.Add("CPU hard cap unsupported on this host (DFSS enabled or older Windows); launched without CPU cap.");
                        else throw new Win32Exception(err);
                    }
                }
                if (o.JobUiFlags != 0)
                {
                    IntPtr pui = Marshal.AllocHGlobal(4); Marshal.WriteInt32(pui, unchecked((int)o.JobUiFlags));
                    bool ok = SetInformationJobObject(job, 4, pui, 4); int err = Marshal.GetLastWin32Error();
                    if (ok && o.IsolateDesktop)
                    {
                        Marshal.WriteInt32(pui, 0);
                        if (!QueryInformationJobObject(job, 4, pui, 4, IntPtr.Zero) || (Marshal.ReadInt32(pui) & 0x61) != 0x61)
                            { Marshal.FreeHGlobal(pui); throw new Exception("Security error: Job UI desktop/atom/handle limits were not applied."); }
                    }
                    Marshal.FreeHGlobal(pui); if (!ok) throw new Win32Exception(err);
                }
                if (o.Wait && o.WaitTree)
                {
                    iocp = CreateIoCompletionPort(INVALID_HANDLE_VALUE, IntPtr.Zero, UIntPtr.Zero, 1);
                    if (iocp != IntPtr.Zero)
                    {
                        JOBOBJECT_ASSOCIATE_COMPLETION_PORT acp = new JOBOBJECT_ASSOCIATE_COMPLETION_PORT();
                        acp.CompletionKey = job; acp.CompletionPort = iocp;
                        int alen = Marshal.SizeOf(typeof(JOBOBJECT_ASSOCIATE_COMPLETION_PORT));
                        IntPtr pacp = Marshal.AllocHGlobal(alen); Marshal.StructureToPtr(acp, pacp, false);
                        bool ok = SetInformationJobObject(job, 7, pacp, (uint)alen);
                        Marshal.FreeHGlobal(pacp);
                        if (!ok) { CloseHandle(iocp); iocp = IntPtr.Zero; }
                    }
                }
                if (!AssignProcessToJobObject(job, pi.hProcess)) throw new Win32Exception(Marshal.GetLastWin32Error());
                if (ResumeThread(pi.hThread) == 0xFFFFFFFF) throw new Win32Exception(Marshal.GetLastWin32Error());
                o.Pid = pi.dwProcessId;
                if (!o.Wait && hDesk != IntPtr.Zero && WaitForInputIdle(pi.hProcess, 2000) == 0xFFFFFFFFU) System.Threading.Thread.Sleep(200);
                if (o.Wait)
                {
                    WaitForSingleObject(pi.hProcess, 0xFFFFFFFF);
                    uint ec; GetExitCodeProcess(pi.hProcess, out ec); o.ExitCode = ec;
                    if (o.WaitTree && iocp != IntPtr.Zero)
                    {
                        int acctLen = Marshal.SizeOf(typeof(JOBOBJECT_BASIC_ACCOUNTING_INFORMATION));
                        IntPtr pacct = Marshal.AllocHGlobal(acctLen);
                        try
                        {
                            while (true)
                            {
                                uint msg; IntPtr key, ov;
                                bool qok = GetQueuedCompletionStatus(iocp, out msg, out key, out ov, 500);
                                if (qok && key == job && msg == 4 /* JOB_OBJECT_MSG_ACTIVE_PROCESS_ZERO */) break;
                                int qerr = qok ? 0 : Marshal.GetLastWin32Error();
                                if (!qok && qerr != 258 /* WAIT_TIMEOUT */) break;
                                if (QueryInformationJobObject(job, 1, pacct, (uint)acctLen, IntPtr.Zero))
                                {
                                    JOBOBJECT_BASIC_ACCOUNTING_INFORMATION acct = (JOBOBJECT_BASIC_ACCOUNTING_INFORMATION)Marshal.PtrToStructure(pacct, typeof(JOBOBJECT_BASIC_ACCOUNTING_INFORMATION));
                                    if (acct.ActiveProcesses == 0) break;
                                }
                            }
                        }
                        finally { Marshal.FreeHGlobal(pacct); }
                    }
                }
                success = true;
            }
            finally
            {
                if (!success && created) { TerminateProcess(pi.hProcess, 1); WaitForSingleObject(pi.hProcess, 2000); }
                if (created) { CloseHandle(pi.hThread); CloseHandle(pi.hProcess); }
                if (hDesk != IntPtr.Zero) CloseDesktop(hDesk);
                if (iocp != IntPtr.Zero) CloseHandle(iocp);
                if (job != IntPtr.Zero) CloseHandle(job);
                if (attrInit) DeleteProcThreadAttributeList(attr);
                if (attr != IntPtr.Zero) Marshal.FreeHGlobal(attr);
                if (sc != IntPtr.Zero) Marshal.FreeHGlobal(sc);
                if (caps != IntPtr.Zero) Marshal.FreeHGlobal(caps);
                if (pAap != IntPtr.Zero) Marshal.FreeHGlobal(pAap);
                if (pMit != IntPtr.Zero) Marshal.FreeHGlobal(pMit);
                if (pChild != IntPtr.Zero) Marshal.FreeHGlobal(pChild);
                if (env != IntPtr.Zero) Marshal.FreeHGlobal(env);
                foreach (IntPtr s in sids) LocalFree(s);
                if (acSid != IntPtr.Zero) FreeSid(acSid);
            }
        }
    }
}