using LocalAIGateway.Core.Configuration;
using LocalAIGateway.Core.Control;
using LocalAIGateway.Core.Installation;
using LocalAIGateway.Core.Usage;
using LocalAIGateway.Windows.Runtime;

namespace LocalAIGateway.Tray;

public sealed class TrayCoordinator : IDisposable
{
    private readonly ITrayProfileStore profiles;
    private readonly IGatewayDaemonController daemon;
    private readonly IUsageSummaryReader usageReader;
    private readonly CurrentUserInstallationTarget target;
    private readonly TimeProvider timeProvider;
    private readonly SemaphoreSlim operationGate = new(1, 1);
    private readonly CancellationTokenSource shutdown = new();
    private readonly object stateLock = new();
    private TrayState state = TrayState.Initial;
    private int disposed;

    public TrayCoordinator(
        ITrayProfileStore profiles,
        IGatewayDaemonController daemon,
        IUsageSummaryReader usageReader,
        CurrentUserInstallationTarget target,
        TimeProvider? timeProvider = null)
    {
        this.profiles = profiles ?? throw new ArgumentNullException(nameof(profiles));
        this.daemon = daemon ?? throw new ArgumentNullException(nameof(daemon));
        this.usageReader = usageReader ?? throw new ArgumentNullException(nameof(usageReader));
        this.target = target ?? throw new ArgumentNullException(nameof(target));
        this.timeProvider = timeProvider ?? TimeProvider.System;
    }

    public event Action<TrayState>? StateChanged;

    public TrayState State
    {
        get
        {
            lock (stateLock)
            {
                return state;
            }
        }
    }

    public Task<TrayState> RefreshAsync(CancellationToken cancellationToken = default) =>
        ExecuteAsync(TrayActivity.Refreshing, null, cancellationToken);

    public Task<TrayState> StartAsync(CancellationToken cancellationToken = default) =>
        ExecuteAsync(
            TrayActivity.Starting,
            async token => SetDaemon((await daemon.StartAsync(target, token)).Status),
            cancellationToken);

    public Task<TrayState> StopAsync(CancellationToken cancellationToken = default) =>
        ExecuteAsync(
            TrayActivity.Stopping,
            async token => SetDaemon((await daemon.StopAsync(token)).Status),
            cancellationToken);

    public Task<TrayState> RestartAsync(CancellationToken cancellationToken = default) =>
        ExecuteAsync(
            TrayActivity.Restarting,
            async token => SetDaemon((await daemon.RestartAsync(target, token)).Status),
            cancellationToken);

    public Task<TrayState> SwitchProfileAsync(
        string profileId,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(profileId);
        return ExecuteAsync(
            TrayActivity.SwitchingProfile,
            async token =>
            {
                var before = await daemon.GetStatusAsync(token);
                SetDaemon(before);
                var selected = await profiles.SelectAsync(profileId, token);
                SetConfiguration(selected);
                if (before.Running)
                {
                    SetDaemon((await daemon.ReloadAsync(token)).Status);
                }
            },
            cancellationToken);
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0)
        {
            return;
        }

        shutdown.Cancel();
        shutdown.Dispose();
    }

    private async Task<TrayState> ExecuteAsync(
        TrayActivity activity,
        Func<CancellationToken, Task>? operation,
        CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(Volatile.Read(ref disposed) != 0, this);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken,
            shutdown.Token);
        await operationGate.WaitAsync(linked.Token);
        try
        {
            Publish(State with { Activity = activity, Error = null });
            try
            {
                if (operation is not null)
                {
                    await operation(linked.Token);
                }

                await RefreshCoreAsync(linked.Token);
                Publish(State with { Activity = TrayActivity.Idle, Error = null });
            }
            catch (OperationCanceledException) when (linked.IsCancellationRequested)
            {
                Publish(State with { Activity = TrayActivity.Idle });
                throw;
            }
            catch (Exception exception)
            {
                Publish(State with
                {
                    Activity = TrayActivity.Idle,
                    Error = ToError(exception),
                });
            }

            return State;
        }
        finally
        {
            operationGate.Release();
        }
    }

    private async Task RefreshCoreAsync(CancellationToken cancellationToken)
    {
        var now = timeProvider.GetUtcNow();
        var zone = timeProvider.LocalTimeZone;
        var localNow = TimeZoneInfo.ConvertTime(now, zone);
        var localMidnight = new DateTime(
            localNow.Year,
            localNow.Month,
            localNow.Day,
            0,
            0,
            0,
            DateTimeKind.Unspecified);
        var startUtc = new DateTimeOffset(TimeZoneInfo.ConvertTimeToUtc(localMidnight, zone));

        var configurationTask = profiles.LoadAsync(cancellationToken);
        var daemonTask = daemon.GetStatusAsync(cancellationToken);
        var usageTask = usageReader.ReadAsync(startUtc, now, cancellationToken);

        TrayConfigurationSnapshot? configuration = null;
        GatewayDaemonStatus? daemonStatus = null;
        UsageSummary? usage = null;
        Exception? failure = null;
        try
        {
            configuration = await configurationTask;
        }
        catch (Exception exception)
        {
            failure = exception;
        }

        try
        {
            daemonStatus = await daemonTask;
        }
        catch (Exception exception)
        {
            failure ??= exception;
        }

        try
        {
            usage = await usageTask;
        }
        catch (Exception exception)
        {
            failure ??= exception;
        }

        cancellationToken.ThrowIfCancellationRequested();

        Publish(State with
        {
            Daemon = daemonStatus ?? State.Daemon,
            Configuration = configuration ?? State.Configuration,
            Usage = usage ?? State.Usage,
            RefreshedAtUtc = now,
        });

        if (failure is not null)
        {
            throw failure;
        }
    }

    private void SetDaemon(GatewayDaemonStatus status) =>
        Publish(State with { Daemon = status });

    private void SetConfiguration(TrayConfigurationSnapshot configuration) =>
        Publish(State with { Configuration = configuration });

    private void Publish(TrayState next)
    {
        lock (stateLock)
        {
            state = next;
        }

        StateChanged?.Invoke(next);
    }

    private static TrayError ToError(Exception exception) => exception switch
    {
        ConfigurationException value => new TrayError(value.ErrorCode, value.Message),
        UsageException value => new TrayError(value.ErrorCode, value.Message),
        GatewayDaemonException value => new TrayError(value.ErrorCode, value.Message),
        InstallationException value => new TrayError(value.ErrorCode, value.Message),
        ControlProtocolException value => new TrayError(value.ErrorCode, value.Message),
        _ => new TrayError("aigw_tray_unexpected", "An unexpected tray operation error occurred."),
    };
}
