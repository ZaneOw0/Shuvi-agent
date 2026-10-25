using System.Diagnostics;
using LocalAIGateway.Core.Control;
using LocalAIGateway.Core.Installation;

namespace LocalAIGateway.Windows.Runtime;

public sealed record GatewayDaemonStatus(
    bool Running,
    string? ActiveProfileId,
    long? ActiveConfigurationRevision,
    long? PendingConfigurationRevision,
    bool Switching,
    string? LastReloadErrorCode,
    IReadOnlyList<TargetCircuitStatus> TargetCircuits);

public sealed record GatewayDaemonOperationResult(
    bool Changed,
    GatewayDaemonStatus Status);

public interface IGatewayDaemonController
{
    Task<GatewayDaemonStatus> GetStatusAsync(CancellationToken cancellationToken = default);

    Task<GatewayDaemonOperationResult> StartAsync(
        CurrentUserInstallationTarget target,
        CancellationToken cancellationToken = default);

    Task<GatewayDaemonOperationResult> StopAsync(CancellationToken cancellationToken = default);

    Task<GatewayDaemonOperationResult> RestartAsync(
        CurrentUserInstallationTarget target,
        CancellationToken cancellationToken = default);

    Task<GatewayDaemonOperationResult> ReloadAsync(CancellationToken cancellationToken = default);
}

public sealed class GatewayDaemonException : Exception
{
    public GatewayDaemonException(string errorCode, string message, Exception? innerException = null)
        : base(message, innerException)
    {
        ErrorCode = errorCode;
    }

    public string ErrorCode { get; }
}

public sealed class GatewayDaemonController : IGatewayDaemonController
{
    private static readonly TimeSpan DefaultStartTimeout = TimeSpan.FromSeconds(75);
    private static readonly TimeSpan DefaultStopTimeout = TimeSpan.FromSeconds(15);
    private static readonly TimeSpan DefaultPollInterval = TimeSpan.FromMilliseconds(100);

    private readonly IControlClient controlClient;
    private readonly IGatewayDaemonProcessLauncher processLauncher;
    private readonly TimeSpan startTimeout;
    private readonly TimeSpan stopTimeout;
    private readonly TimeSpan pollInterval;
    private readonly Func<TimeSpan, CancellationToken, Task> delayAsync;
    private readonly Func<DateTime> utcNow;

    public GatewayDaemonController(IControlClient controlClient)
        : this(
            controlClient,
            new WindowsGatewayDaemonProcessLauncher(),
            DefaultStartTimeout,
            DefaultStopTimeout,
            DefaultPollInterval,
            Task.Delay,
            static () => DateTime.UtcNow)
    {
    }

    internal GatewayDaemonController(
        IControlClient controlClient,
        IGatewayDaemonProcessLauncher processLauncher,
        TimeSpan startTimeout,
        TimeSpan stopTimeout,
        TimeSpan pollInterval,
        Func<TimeSpan, CancellationToken, Task> delayAsync,
        Func<DateTime> utcNow)
    {
        ArgumentNullException.ThrowIfNull(controlClient);
        ArgumentNullException.ThrowIfNull(processLauncher);
        ArgumentNullException.ThrowIfNull(delayAsync);
        ArgumentNullException.ThrowIfNull(utcNow);
        ValidateTimeout(startTimeout, nameof(startTimeout));
        ValidateTimeout(stopTimeout, nameof(stopTimeout));
        ValidateTimeout(pollInterval, nameof(pollInterval));
        this.controlClient = controlClient;
        this.processLauncher = processLauncher;
        this.startTimeout = startTimeout;
        this.stopTimeout = stopTimeout;
        this.pollInterval = pollInterval;
        this.delayAsync = delayAsync;
        this.utcNow = utcNow;
    }

    public async Task<GatewayDaemonStatus> GetStatusAsync(
        CancellationToken cancellationToken = default)
    {
        var response = await TrySendAsync(ControlCommands.Status, cancellationToken);
        return response is null ? StoppedStatus() : ReadStatus(response);
    }

    public async Task<GatewayDaemonOperationResult> StartAsync(
        CurrentUserInstallationTarget target,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(target);
        var current = await GetStatusAsync(cancellationToken);
        if (current.Running)
        {
            return new GatewayDaemonOperationResult(false, current);
        }

        ValidateRuntimeExecutable(target.RuntimeExecutablePath);
        IGatewayDaemonProcess process;
        try
        {
            process = processLauncher.Start(
                target.RuntimeExecutablePath,
                target.InstallRoot);
        }
        catch (GatewayDaemonException)
        {
            throw;
        }
        catch (Exception exception)
        {
            throw new GatewayDaemonException(
                "aigw_daemon_start_failed",
                "The Local AI Gateway runtime process could not be created.",
                exception);
        }

        using (process)
        {
        var deadline = utcNow() + startTimeout;
        try
        {
            while (utcNow() < deadline)
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (process.HasExited)
                {
                    throw new GatewayDaemonException(
                        "aigw_daemon_start_failed",
                        $"The Local AI Gateway runtime exited before becoming ready (exit code {process.ExitCode}).");
                }

                var status = await GetStatusAsync(cancellationToken);
                if (status.Running)
                {
                    return new GatewayDaemonOperationResult(true, status);
                }

                await delayAsync(pollInterval, cancellationToken);
            }

            throw new GatewayDaemonException(
                "aigw_daemon_start_timeout",
                "Timed out waiting for the Local AI Gateway runtime control pipe.");
        }
        catch (Exception startupFailure)
        {
            if (!process.HasExited)
            {
                try
                {
                    process.KillTree();
                }
                catch (Exception cleanupFailure)
                {
                    throw new GatewayDaemonException(
                        "aigw_daemon_start_cleanup_failed",
                        "Runtime startup failed and the new process tree could not be terminated.",
                        new AggregateException(startupFailure, cleanupFailure));
                }
            }

            throw;
        }
        }
    }

    public async Task<GatewayDaemonOperationResult> StopAsync(
        CancellationToken cancellationToken = default)
    {
        var current = await GetStatusAsync(cancellationToken);
        if (!current.Running)
        {
            return new GatewayDaemonOperationResult(false, current);
        }

        var response = await TrySendAsync(ControlCommands.Stop, cancellationToken)
            ?? throw new GatewayDaemonException(
                "aigw_daemon_stop_failed",
                "The runtime control pipe disappeared before the stop request was accepted.");
        ReadStatus(response);

        var deadline = utcNow() + stopTimeout;
        while (utcNow() < deadline)
        {
            cancellationToken.ThrowIfCancellationRequested();
            await delayAsync(pollInterval, cancellationToken);
            var status = await GetStatusAsync(cancellationToken);
            if (!status.Running)
            {
                return new GatewayDaemonOperationResult(true, status);
            }
        }

        throw new GatewayDaemonException(
            "aigw_daemon_stop_timeout",
            "Timed out waiting for the Local AI Gateway runtime to stop.");
    }

    public async Task<GatewayDaemonOperationResult> RestartAsync(
        CurrentUserInstallationTarget target,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(target);
        await StopAsync(cancellationToken);
        var started = await StartAsync(target, cancellationToken);
        return new GatewayDaemonOperationResult(true, started.Status);
    }

    public async Task<GatewayDaemonOperationResult> ReloadAsync(
        CancellationToken cancellationToken = default)
    {
        var current = await GetStatusAsync(cancellationToken);
        if (!current.Running)
        {
            return new GatewayDaemonOperationResult(false, current);
        }

        var response = await TrySendAsync(ControlCommands.Reload, cancellationToken)
            ?? throw new GatewayDaemonException(
                "aigw_daemon_reload_failed",
                "The runtime control pipe disappeared before the reload request was accepted.");
        var updated = ReadStatus(response);
        var changed = current.ActiveConfigurationRevision != updated.ActiveConfigurationRevision ||
            !string.Equals(current.ActiveProfileId, updated.ActiveProfileId, StringComparison.OrdinalIgnoreCase) ||
            current.PendingConfigurationRevision != updated.PendingConfigurationRevision ||
            current.Switching != updated.Switching ||
            !string.Equals(current.LastReloadErrorCode, updated.LastReloadErrorCode, StringComparison.Ordinal);
        return new GatewayDaemonOperationResult(changed, updated);
    }

    private async Task<ControlResponse?> TrySendAsync(
        string command,
        CancellationToken cancellationToken)
    {
        try
        {
            return await controlClient.SendAsync(command, cancellationToken);
        }
        catch (ControlProtocolException exception) when (
            exception.ErrorCode is "aigw_control_connect_timeout" or "aigw_control_unavailable")
        {
            return null;
        }
    }

    private static GatewayDaemonStatus ReadStatus(ControlResponse response)
    {
        if (response.Version != ControlProtocol.Version)
        {
            throw new GatewayDaemonException(
                "aigw_daemon_control_version_invalid",
                "The runtime control response version is not supported.");
        }

        if (!response.Ok)
        {
            throw new GatewayDaemonException(
                response.Error?.Code ?? "aigw_daemon_control_failed",
                response.Error?.Message ?? "The runtime control request failed.");
        }

        var status = response.Status
            ?? throw new GatewayDaemonException(
                "aigw_daemon_control_response_invalid",
                "The runtime control response did not include status.");
        return new GatewayDaemonStatus(
            status.Running,
            status.ActiveProfileId,
            status.ActiveConfigurationRevision,
            status.PendingConfigurationRevision,
            status.Switching,
            status.LastReloadErrorCode,
            status.TargetCircuits);
    }

    private static void ValidateRuntimeExecutable(string path)
    {
        if (!Path.IsPathFullyQualified(path) || !File.Exists(path))
        {
            throw new InstallationException(
                "aigw_install_runtime_missing",
                "The installed runtime executable is missing.");
        }

        if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
        {
            throw new InstallationException(
                "aigw_install_runtime_reparse_point",
                "The installed runtime executable must not be a reparse point.");
        }
    }

    private static GatewayDaemonStatus StoppedStatus() =>
        new(false, null, null, null, false, null, []);

    private static void ValidateTimeout(TimeSpan value, string parameterName)
    {
        if (value <= TimeSpan.Zero || value > TimeSpan.FromMinutes(5))
        {
            throw new ArgumentOutOfRangeException(
                parameterName,
                "Daemon lifecycle timeout must be positive and no greater than five minutes.");
        }
    }
}

internal interface IGatewayDaemonProcessLauncher
{
    IGatewayDaemonProcess Start(string executablePath, string workingDirectory);
}

internal interface IGatewayDaemonProcess : IDisposable
{
    bool HasExited { get; }

    int ExitCode { get; }

    void KillTree();
}

internal sealed class WindowsGatewayDaemonProcessLauncher : IGatewayDaemonProcessLauncher
{
    public IGatewayDaemonProcess Start(string executablePath, string workingDirectory)
    {
        return new WindowsGatewayDaemonProcess(
            WindowsDetachedProcess.Start(executablePath, workingDirectory));
    }
}

internal sealed class WindowsGatewayDaemonProcess(Process process) : IGatewayDaemonProcess
{
    public bool HasExited => process.HasExited;

    public int ExitCode => process.ExitCode;

    public void KillTree()
    {
        try
        {
            process.Kill(entireProcessTree: true);
            process.WaitForExit();
        }
        catch (InvalidOperationException)
        {
            // The process exited between the HasExited check and cleanup.
        }
    }

    public void Dispose() => process.Dispose();
}
