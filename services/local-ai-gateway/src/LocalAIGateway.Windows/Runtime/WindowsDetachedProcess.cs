using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace LocalAIGateway.Windows.Runtime;

internal static class WindowsDetachedProcess
{
    public static Process Start(string executablePath, string workingDirectory)
        => Start(executablePath, workingDirectory, ["--serve"], environment: null);

    public static Process Start(
        string executablePath,
        string workingDirectory,
        IReadOnlyList<string> arguments,
        IReadOnlyDictionary<string, string>? environment)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("Detached daemon processes require Windows.");
        }
        if (!Path.IsPathFullyQualified(executablePath) ||
            !Path.IsPathFullyQualified(workingDirectory))
        {
            throw new GatewayDaemonException(
                "aigw_daemon_start_failed",
                "The daemon executable and working directory must be fully qualified.");
        }

        using var nullInput = OpenNullDevice(NativeMethods.GenericRead);
        using var nullOutput = OpenNullDevice(NativeMethods.GenericWrite);
        using var attributes = ProcessThreadAttributeList.Create(
            nullInput.DangerousGetHandle(),
            nullOutput.DangerousGetHandle());
        SafeKernelHandle? processHandle = null;
        SafeKernelHandle? threadHandle = null;
        IntPtr environmentBlock = IntPtr.Zero;
        try
        {
            var startupInfo = new StartupInfoEx
            {
                StartupInfo = new StartupInfo
                {
                    Size = checked((uint)Marshal.SizeOf<StartupInfoEx>()),
                    Flags = NativeMethods.StartfUseStdHandles,
                    StandardInput = nullInput.DangerousGetHandle(),
                    StandardOutput = nullOutput.DangerousGetHandle(),
                    StandardError = nullOutput.DangerousGetHandle(),
                },
                AttributeList = attributes.Pointer,
            };
            var commandLine = new StringBuilder();
            AppendQuotedArgument(commandLine, executablePath);
            foreach (var argument in arguments)
            {
                commandLine.Append(' ');
                AppendQuotedArgument(commandLine, argument);
            }
            var creationFlags = NativeMethods.CreateNoWindow |
                NativeMethods.ExtendedStartupInfoPresent;
            if (environment is not null)
            {
                environmentBlock = CreateEnvironmentBlock(environment);
                creationFlags |= NativeMethods.CreateUnicodeEnvironment;
            }
            if (!NativeMethods.CreateProcess(
                    executablePath,
                    commandLine,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    inheritHandles: true,
                    creationFlags,
                    environmentBlock,
                    workingDirectory,
                    ref startupInfo,
                    out var processInformation))
            {
                throw NativeFailure(
                    "Windows could not create the detached Local AI Gateway runtime process.");
            }

            processHandle = new SafeKernelHandle(processInformation.ProcessHandle);
            threadHandle = new SafeKernelHandle(processInformation.ThreadHandle);
            try
            {
                return Process.GetProcessById(checked((int)processInformation.ProcessId));
            }
            catch
            {
                NativeMethods.TerminateProcess(processHandle, exitCode: 1);
                NativeMethods.WaitForSingleObject(processHandle, milliseconds: 5000);
                throw;
            }
        }
        catch (GatewayDaemonException)
        {
            throw;
        }
        catch (Exception exception)
        {
            throw new GatewayDaemonException(
                "aigw_daemon_start_failed",
                "The detached Local AI Gateway runtime process could not be created.",
                exception);
        }
        finally
        {
            threadHandle?.Dispose();
            processHandle?.Dispose();
            if (environmentBlock != IntPtr.Zero) Marshal.FreeHGlobal(environmentBlock);
        }
    }

    private static IntPtr CreateEnvironmentBlock(IReadOnlyDictionary<string, string> environment)
    {
        var entries = new List<string>(environment.Count);
        foreach (var pair in environment)
        {
            if (string.IsNullOrEmpty(pair.Key) || pair.Key.Contains('=') || pair.Key.Contains('\0') ||
                pair.Value is null || pair.Value.Contains('\0'))
            {
                throw new ArgumentException("The restricted process environment is invalid.", nameof(environment));
            }
            entries.Add(pair.Key + "=" + pair.Value);
        }
        entries.Sort(StringComparer.OrdinalIgnoreCase);
        return Marshal.StringToHGlobalUni(string.Join('\0', entries) + "\0\0");
    }

    private static SafeKernelHandle OpenNullDevice(uint desiredAccess)
    {
        var securityAttributes = new SecurityAttributes
        {
            Length = checked((uint)Marshal.SizeOf<SecurityAttributes>()),
            InheritHandle = 1,
        };
        var handle = NativeMethods.CreateFile(
            "NUL",
            desiredAccess,
            NativeMethods.FileShareRead | NativeMethods.FileShareWrite,
            ref securityAttributes,
            NativeMethods.OpenExisting,
            NativeMethods.FileAttributeNormal,
            IntPtr.Zero);
        if (handle.IsInvalid)
        {
            handle.Dispose();
            throw NativeFailure("Windows could not open NUL for daemon standard handles.");
        }

        return handle;
    }

    private static void AppendQuotedArgument(StringBuilder builder, string argument)
    {
        if (argument.Length > 0 &&
            argument.IndexOfAny([' ', '\t', '\n', '\v', '"']) < 0)
        {
            builder.Append(argument);
            return;
        }

        builder.Append('"');
        var backslashes = 0;
        foreach (var character in argument)
        {
            if (character == '\\')
            {
                backslashes++;
                continue;
            }
            if (character == '"')
            {
                builder.Append('\\', backslashes * 2 + 1);
                builder.Append('"');
                backslashes = 0;
                continue;
            }

            builder.Append('\\', backslashes);
            backslashes = 0;
            builder.Append(character);
        }
        builder.Append('\\', backslashes * 2);
        builder.Append('"');
    }

    private static GatewayDaemonException NativeFailure(string message) => new(
        "aigw_daemon_start_failed",
        message,
        new Win32Exception(Marshal.GetLastWin32Error()));

    private sealed class ProcessThreadAttributeList : IDisposable
    {
        private IntPtr handleList;

        private ProcessThreadAttributeList(IntPtr pointer, IntPtr handleList)
        {
            Pointer = pointer;
            this.handleList = handleList;
        }

        public IntPtr Pointer { get; private set; }

        public static ProcessThreadAttributeList Create(params IntPtr[] inheritedHandles)
        {
            nuint size = 0;
            NativeMethods.InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
            if (size == 0)
            {
                throw NativeFailure("Windows could not size the daemon process attribute list.");
            }

            var pointer = Marshal.AllocHGlobal(checked((nint)size));
            var handleList = Marshal.AllocHGlobal(checked(IntPtr.Size * inheritedHandles.Length));
            var initialized = false;
            try
            {
                if (!NativeMethods.InitializeProcThreadAttributeList(pointer, 1, 0, ref size))
                {
                    throw NativeFailure("Windows could not initialize the daemon process attribute list.");
                }
                initialized = true;
                Marshal.Copy(inheritedHandles, 0, handleList, inheritedHandles.Length);
                if (!NativeMethods.UpdateProcThreadAttribute(
                        pointer,
                        0,
                        NativeMethods.ProcThreadAttributeHandleList,
                        handleList,
                        checked((nuint)(IntPtr.Size * inheritedHandles.Length)),
                        IntPtr.Zero,
                        IntPtr.Zero))
                {
                    throw NativeFailure("Windows could not restrict inherited daemon process handles.");
                }

                return new ProcessThreadAttributeList(pointer, handleList);
            }
            catch
            {
                if (initialized)
                {
                    NativeMethods.DeleteProcThreadAttributeList(pointer);
                }
                Marshal.FreeHGlobal(pointer);
                Marshal.FreeHGlobal(handleList);
                throw;
            }
        }

        public void Dispose()
        {
            var pointer = Pointer;
            Pointer = IntPtr.Zero;
            if (pointer != IntPtr.Zero)
            {
                NativeMethods.DeleteProcThreadAttributeList(pointer);
                Marshal.FreeHGlobal(pointer);
            }
            if (handleList != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(handleList);
                handleList = IntPtr.Zero;
            }
        }
    }

    private sealed class SafeKernelHandle : SafeHandleZeroOrMinusOneIsInvalid
    {
        public SafeKernelHandle()
            : base(ownsHandle: true)
        {
        }

        public SafeKernelHandle(IntPtr handle)
            : this()
        {
            SetHandle(handle);
        }

        protected override bool ReleaseHandle() => NativeMethods.CloseHandle(handle);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SecurityAttributes
    {
        public uint Length;
        public IntPtr SecurityDescriptor;
        public int InheritHandle;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct StartupInfo
    {
        public uint Size;
        public string? Reserved;
        public string? Desktop;
        public string? Title;
        public uint X;
        public uint Y;
        public uint XSize;
        public uint YSize;
        public uint XCountChars;
        public uint YCountChars;
        public uint FillAttribute;
        public uint Flags;
        public ushort ShowWindow;
        public ushort Reserved2Size;
        public IntPtr Reserved2;
        public IntPtr StandardInput;
        public IntPtr StandardOutput;
        public IntPtr StandardError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct StartupInfoEx
    {
        public StartupInfo StartupInfo;
        public IntPtr AttributeList;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessInformation
    {
        public IntPtr ProcessHandle;
        public IntPtr ThreadHandle;
        public uint ProcessId;
        public uint ThreadId;
    }

    private static class NativeMethods
    {
        internal const uint GenericRead = 0x80000000;
        internal const uint GenericWrite = 0x40000000;
        internal const uint FileShareRead = 0x00000001;
        internal const uint FileShareWrite = 0x00000002;
        internal const uint OpenExisting = 3;
        internal const uint FileAttributeNormal = 0x00000080;
        internal const uint ExtendedStartupInfoPresent = 0x00080000;
        internal const uint CreateUnicodeEnvironment = 0x00000400;
        internal const uint CreateNoWindow = 0x08000000;
        internal const uint StartfUseStdHandles = 0x00000100;
        internal const nuint ProcThreadAttributeHandleList = 0x00020002;

        [DllImport("kernel32.dll", EntryPoint = "CreateFileW", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
        internal static extern SafeKernelHandle CreateFile(
            string fileName,
            uint desiredAccess,
            uint shareMode,
            ref SecurityAttributes securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        [DllImport("kernel32.dll", EntryPoint = "CreateProcessW", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool CreateProcess(
            string applicationName,
            StringBuilder commandLine,
            IntPtr processAttributes,
            IntPtr threadAttributes,
            [MarshalAs(UnmanagedType.Bool)] bool inheritHandles,
            uint creationFlags,
            IntPtr environment,
            string currentDirectory,
            ref StartupInfoEx startupInfo,
            out ProcessInformation processInformation);

        [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool InitializeProcThreadAttributeList(
            IntPtr attributeList,
            int attributeCount,
            uint flags,
            ref nuint size);

        [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool UpdateProcThreadAttribute(
            IntPtr attributeList,
            uint flags,
            nuint attribute,
            IntPtr value,
            nuint size,
            IntPtr previousValue,
            IntPtr returnSize);

        [DllImport("kernel32.dll", ExactSpelling = true)]
        internal static extern void DeleteProcThreadAttributeList(IntPtr attributeList);

        [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool TerminateProcess(SafeKernelHandle process, uint exitCode);

        [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
        internal static extern uint WaitForSingleObject(SafeKernelHandle handle, uint milliseconds);

        [DllImport("kernel32.dll", ExactSpelling = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool CloseHandle(IntPtr handle);
    }
}
