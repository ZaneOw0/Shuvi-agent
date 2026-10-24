using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace LocalAIGateway.LiteLlm;

internal interface IWindowsJobProcessLauncher
{
    IWindowsJobProcess Start(ProcessStartInfo startInfo);
}

internal interface IWindowsJobProcess : IAsyncDisposable
{
    int ProcessId { get; }

    bool HasExited { get; }

    Task TerminateAsync(TimeSpan timeout, CancellationToken cancellationToken = default);
}

internal sealed class WindowsJobProcessLauncher : IWindowsJobProcessLauncher
{
    public static WindowsJobProcessLauncher Instance { get; } = new();

    private WindowsJobProcessLauncher()
    {
    }

    public IWindowsJobProcess Start(ProcessStartInfo startInfo) =>
        WindowsSuspendedJobProcess.Start(startInfo);
}

internal sealed class WindowsSuspendedJobProcess : IWindowsJobProcess
{
    private const uint ProcessTerminationExitCode = 1;
    private readonly SafeKernelHandle processHandle;
    private readonly SafeKernelHandle jobHandle;
    private int disposed;

    private WindowsSuspendedJobProcess(
        SafeKernelHandle processHandle,
        SafeKernelHandle jobHandle,
        int processId)
    {
        this.processHandle = processHandle;
        this.jobHandle = jobHandle;
        ProcessId = processId;
    }

    public int ProcessId { get; }

    public bool HasExited => WaitForExit(milliseconds: 0) == NativeMethods.WaitObject0;

    public static WindowsSuspendedJobProcess Start(ProcessStartInfo startInfo)
    {
        EnsureWindows();
        ValidateStartInfo(startInfo);

        using var nullInput = OpenNullDevice(NativeMethods.GenericRead);
        using var nullOutput = OpenNullDevice(NativeMethods.GenericWrite);
        using var attributes = ProcessThreadAttributeList.Create(
            nullInput.DangerousGetHandle(),
            nullOutput.DangerousGetHandle());
        using var environment = UnicodeEnvironmentBlock.Create(startInfo.Environment);
        var jobHandle = CreateKillOnCloseJob();
        SafeKernelHandle? processHandle = null;
        SafeKernelHandle? threadHandle = null;
        var assignedToJob = false;
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
            var commandLine = new StringBuilder(BuildCommandLine(startInfo));
            var creationFlags = NativeMethods.CreateSuspended |
                NativeMethods.CreateUnicodeEnvironment |
                NativeMethods.CreateNoWindow |
                NativeMethods.ExtendedStartupInfoPresent;
            if (!NativeMethods.CreateProcess(
                    startInfo.FileName,
                    commandLine,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    inheritHandles: true,
                    creationFlags,
                    environment.Pointer,
                    startInfo.WorkingDirectory,
                    ref startupInfo,
                    out var processInformation))
            {
                throw NativeFailure(
                    "aigw_litellm_process_start_failed",
                    "Windows could not create the suspended LiteLLM process.");
            }

            processHandle = new SafeKernelHandle(processInformation.ProcessHandle);
            threadHandle = new SafeKernelHandle(processInformation.ThreadHandle);
            if (!NativeMethods.AssignProcessToJobObject(jobHandle, processHandle))
            {
                throw NativeFailure(
                    "aigw_litellm_job_assignment_failed",
                    "Windows could not assign the suspended LiteLLM process to its Job Object.");
            }
            assignedToJob = true;

            if (NativeMethods.ResumeThread(threadHandle) == uint.MaxValue)
            {
                throw NativeFailure(
                    "aigw_litellm_process_resume_failed",
                    "Windows could not resume the Job Object-managed LiteLLM process.");
            }

            var result = new WindowsSuspendedJobProcess(
                processHandle,
                jobHandle,
                checked((int)processInformation.ProcessId));
            processHandle = null;
            jobHandle = null!;
            return result;
        }
        catch
        {
            if (processHandle is not null && !processHandle.IsInvalid)
            {
                if (assignedToJob)
                {
                    NativeMethods.TerminateJobObject(jobHandle, ProcessTerminationExitCode);
                }
                else
                {
                    NativeMethods.TerminateProcess(processHandle, ProcessTerminationExitCode);
                }
                NativeMethods.WaitForSingleObject(processHandle, 5000);
            }

            throw;
        }
        finally
        {
            threadHandle?.Dispose();
            processHandle?.Dispose();
            jobHandle?.Dispose();
        }
    }

    public async Task TerminateAsync(
        TimeSpan timeout,
        CancellationToken cancellationToken = default)
    {
        if (timeout <= TimeSpan.Zero || timeout > TimeSpan.FromMinutes(5))
        {
            throw new ArgumentOutOfRangeException(nameof(timeout));
        }
        if (Volatile.Read(ref disposed) != 0 || HasExited)
        {
            return;
        }

        if (!NativeMethods.TerminateJobObject(jobHandle, ProcessTerminationExitCode))
        {
            throw NativeFailure(
                "aigw_litellm_process_stop_failed",
                "Windows could not terminate the LiteLLM Job Object.");
        }

        var deadline = DateTime.UtcNow + timeout;
        while (!HasExited)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (DateTime.UtcNow >= deadline)
            {
                throw new LiteLlmException(
                    "aigw_litellm_process_stop_timeout",
                    "The LiteLLM process did not exit before the stop timeout elapsed.");
            }

            await Task.Delay(25, cancellationToken);
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0)
        {
            return;
        }

        try
        {
            if (!HasExited)
            {
                jobHandle.Dispose();
                var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(5);
                while (!HasExited && DateTime.UtcNow < deadline)
                {
                    await Task.Delay(25);
                }
            }
        }
        finally
        {
            jobHandle.Dispose();
            processHandle.Dispose();
        }
    }

    private uint WaitForExit(uint milliseconds)
    {
        var result = NativeMethods.WaitForSingleObject(processHandle, milliseconds);
        if (result == NativeMethods.WaitFailed)
        {
            throw NativeFailure(
                "aigw_litellm_process_wait_failed",
                "Windows could not inspect the LiteLLM process state.");
        }

        return result;
    }

    private static void ValidateStartInfo(ProcessStartInfo startInfo)
    {
        ArgumentNullException.ThrowIfNull(startInfo);
        if (startInfo.UseShellExecute ||
            !startInfo.CreateNoWindow ||
            !startInfo.RedirectStandardOutput ||
            !startInfo.RedirectStandardError ||
            !string.IsNullOrEmpty(startInfo.Arguments) ||
            string.IsNullOrWhiteSpace(startInfo.FileName) ||
            !Path.IsPathFullyQualified(startInfo.FileName) ||
            string.IsNullOrWhiteSpace(startInfo.WorkingDirectory) ||
            !Path.IsPathFullyQualified(startInfo.WorkingDirectory))
        {
            throw new LiteLlmException(
                "aigw_litellm_process_spec_invalid",
                "The suspended LiteLLM process specification is malformed.");
        }
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
            throw NativeFailure(
                "aigw_litellm_process_redirect_failed",
                "Windows could not open the null device for LiteLLM process output.");
        }

        return handle;
    }

    private static SafeKernelHandle CreateKillOnCloseJob()
    {
        var jobHandle = NativeMethods.CreateJobObject(IntPtr.Zero, null);
        if (jobHandle.IsInvalid)
        {
            jobHandle.Dispose();
            throw NativeFailure(
                "aigw_litellm_job_create_failed",
                "Windows could not create the LiteLLM Job Object.");
        }

        var information = new JobObjectExtendedLimitInformation
        {
            BasicLimitInformation = new JobObjectBasicLimitInformation
            {
                LimitFlags = NativeMethods.JobObjectLimitKillOnJobClose,
            },
        };
        var pointer = Marshal.AllocHGlobal(Marshal.SizeOf<JobObjectExtendedLimitInformation>());
        try
        {
            Marshal.StructureToPtr(information, pointer, fDeleteOld: false);
            if (!NativeMethods.SetInformationJobObject(
                    jobHandle,
                    NativeMethods.JobObjectExtendedLimitInformationClass,
                    pointer,
                    checked((uint)Marshal.SizeOf<JobObjectExtendedLimitInformation>())))
            {
                throw NativeFailure(
                    "aigw_litellm_job_configure_failed",
                    "Windows could not configure kill-on-close for the LiteLLM Job Object.");
            }
        }
        catch
        {
            jobHandle.Dispose();
            throw;
        }
        finally
        {
            Marshal.FreeHGlobal(pointer);
        }

        return jobHandle;
    }

    private static string BuildCommandLine(ProcessStartInfo startInfo)
    {
        var builder = new StringBuilder();
        AppendQuotedArgument(builder, startInfo.FileName);
        foreach (var argument in startInfo.ArgumentList)
        {
            builder.Append(' ');
            AppendQuotedArgument(builder, argument);
        }

        return builder.ToString();
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

    private static LiteLlmException NativeFailure(string errorCode, string message) =>
        new(errorCode, message, innerException: new Win32Exception(Marshal.GetLastWin32Error()));

    private static void EnsureWindows()
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("Windows Job Objects require Windows.");
        }
    }

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
                throw NativeFailure(
                    "aigw_litellm_process_attributes_failed",
                    "Windows could not size the LiteLLM process attribute list.");
            }

            var pointer = Marshal.AllocHGlobal(checked((nint)size));
            var handleList = Marshal.AllocHGlobal(checked(IntPtr.Size * inheritedHandles.Length));
            var initialized = false;
            try
            {
                if (!NativeMethods.InitializeProcThreadAttributeList(pointer, 1, 0, ref size))
                {
                    throw NativeFailure(
                        "aigw_litellm_process_attributes_failed",
                        "Windows could not initialize the LiteLLM process attribute list.");
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
                    throw NativeFailure(
                        "aigw_litellm_process_attributes_failed",
                        "Windows could not restrict LiteLLM inherited process handles.");
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

    private sealed class UnicodeEnvironmentBlock : IDisposable
    {
        private int byteLength;

        private UnicodeEnvironmentBlock(IntPtr pointer, int byteLength)
        {
            Pointer = pointer;
            this.byteLength = byteLength;
        }

        public IntPtr Pointer { get; private set; }

        public static UnicodeEnvironmentBlock Create(
            IDictionary<string, string?> environment)
        {
            var builder = new StringBuilder();
            foreach (var pair in environment.OrderBy(
                         pair => pair.Key,
                         StringComparer.OrdinalIgnoreCase))
            {
                if (string.IsNullOrEmpty(pair.Key) ||
                    pair.Key.Contains('=') ||
                    pair.Key.Contains('\0') ||
                    pair.Value is null ||
                    pair.Value.Contains('\0'))
                {
                    throw new LiteLlmException(
                        "aigw_litellm_environment_invalid",
                        "The LiteLLM process environment block is malformed.");
                }

                builder.Append(pair.Key);
                builder.Append('=');
                builder.Append(pair.Value);
                builder.Append('\0');
            }
            if (builder.Length == 0)
            {
                builder.Append('\0');
            }
            builder.Append('\0');

            var characters = builder.ToString().ToCharArray();
            var byteLength = checked(characters.Length * sizeof(char));
            var pointer = Marshal.AllocHGlobal(byteLength);
            Marshal.Copy(characters, 0, pointer, characters.Length);
            return new UnicodeEnvironmentBlock(pointer, byteLength);
        }

        public void Dispose()
        {
            var pointer = Pointer;
            Pointer = IntPtr.Zero;
            if (pointer != IntPtr.Zero)
            {
                for (var offset = 0; offset < byteLength; offset++)
                {
                    Marshal.WriteByte(pointer, offset, 0);
                }
                Marshal.FreeHGlobal(pointer);
                byteLength = 0;
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

    [StructLayout(LayoutKind.Sequential)]
    private struct JobObjectBasicLimitInformation
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IoCounters
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JobObjectExtendedLimitInformation
    {
        public JobObjectBasicLimitInformation BasicLimitInformation;
        public IoCounters IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    private static class NativeMethods
    {
        internal const uint GenericRead = 0x80000000;
        internal const uint GenericWrite = 0x40000000;
        internal const uint FileShareRead = 0x00000001;
        internal const uint FileShareWrite = 0x00000002;
        internal const uint OpenExisting = 3;
        internal const uint FileAttributeNormal = 0x00000080;
        internal const uint CreateSuspended = 0x00000004;
        internal const uint CreateUnicodeEnvironment = 0x00000400;
        internal const uint ExtendedStartupInfoPresent = 0x00080000;
        internal const uint CreateNoWindow = 0x08000000;
        internal const uint StartfUseStdHandles = 0x00000100;
        internal const uint JobObjectLimitKillOnJobClose = 0x00002000;
        internal const int JobObjectExtendedLimitInformationClass = 9;
        internal const nuint ProcThreadAttributeHandleList = 0x00020002;
        internal const uint WaitObject0 = 0x00000000;
        internal const uint WaitFailed = 0xffffffff;

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

        [DllImport("kernel32.dll", EntryPoint = "CreateJobObjectW", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
        internal static extern SafeKernelHandle CreateJobObject(IntPtr jobAttributes, string? name);

        [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool SetInformationJobObject(
            SafeKernelHandle job,
            int informationClass,
            IntPtr information,
            uint informationLength);

        [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool AssignProcessToJobObject(
            SafeKernelHandle job,
            SafeKernelHandle process);

        [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
        internal static extern uint ResumeThread(SafeKernelHandle thread);

        [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool TerminateJobObject(SafeKernelHandle job, uint exitCode);

        [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool TerminateProcess(SafeKernelHandle process, uint exitCode);

        [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
        internal static extern uint WaitForSingleObject(SafeKernelHandle handle, uint milliseconds);

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

        [DllImport("kernel32.dll", ExactSpelling = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool CloseHandle(IntPtr handle);
    }
}
