using System.Runtime.ExceptionServices;
using LocalAIGateway.Core.Backend;
using LocalAIGateway.Core.Configuration;
using LocalAIGateway.Core.Control;
using LocalAIGateway.Core.Credentials;
using LocalAIGateway.Core.Runtime;
using LocalAIGateway.Windows.Control;

namespace LocalAIGateway.Runtime;

public sealed record GatewayDaemonOptions
{
    public required ConfigurationStore ConfigurationStore { get; init; }

    public required ICredentialStore CredentialStore { get; init; }

    public required IBackendHost BackendHost { get; init; }

    public required ISingleInstanceProvider SingleInstanceProvider { get; init; }

    public int Port { get; init; } = GatewayRuntimeOptions.ProductionPort;

    public string? ControlPipeName { get; init; }

    public TimeSpan ControlRequestTimeout { get; init; } = TimeSpan.FromSeconds(65);

    internal IGatewayOperationalLog OperationalLog { get; init; } = NullGatewayOperationalLog.Instance;
}

public sealed class GatewayDaemonHost : IAsyncDisposable
{
    private readonly GatewayRuntimeHost runtimeHost;
    private readonly ConfigurationStore configurationStore;
    private readonly IBackendHost backendHost;
    private readonly ISingleInstanceLease singleInstanceLease;
    private readonly IGatewayOperationalLog operationalLog;
    private readonly TaskCompletionSource shutdownRequested =
        new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly object disposeLock = new();
    private GatewayControlServer? controlServer;
    private Task? disposeTask;

    private GatewayDaemonHost(
        GatewayRuntimeHost runtimeHost,
        ConfigurationStore configurationStore,
        IBackendHost backendHost,
        ISingleInstanceLease singleInstanceLease,
        IGatewayOperationalLog operationalLog)
    {
        this.runtimeHost = runtimeHost;
        this.configurationStore = configurationStore;
        this.backendHost = backendHost;
        this.singleInstanceLease = singleInstanceLease;
        this.operationalLog = operationalLog;
    }

    public Uri BaseAddress => runtimeHost.BaseAddress;

    public static async Task<GatewayDaemonHost> StartAsync(
        GatewayDaemonOptions options,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(options);
        ArgumentNullException.ThrowIfNull(options.ConfigurationStore);
        ArgumentNullException.ThrowIfNull(options.CredentialStore);
        ArgumentNullException.ThrowIfNull(options.BackendHost);
        ArgumentNullException.ThrowIfNull(options.SingleInstanceProvider);
        ArgumentNullException.ThrowIfNull(options.OperationalLog);

        var lease = options.SingleInstanceProvider.TryAcquire()
            ?? throw new RuntimeInstanceConflictException();
        options.OperationalLog.Write(GatewayOperationalEvent.DaemonStarting);
        GatewayDaemonHost? daemon = null;
        GatewayConfiguration? configuration = null;
        try
        {
            configuration = await options.ConfigurationStore.LoadAsync(cancellationToken);
            var clientToken = await ReadClientTokenAsync(options.CredentialStore, cancellationToken);
            var runtime = await GatewayRuntimeHost.StartAsync(new GatewayRuntimeOptions
            {
                Configuration = configuration,
                ClientToken = clientToken,
                BackendHost = options.BackendHost,
                Port = options.Port,
            }, cancellationToken);
            daemon = new GatewayDaemonHost(
                runtime,
                options.ConfigurationStore,
                options.BackendHost,
                lease,
                options.OperationalLog);
            daemon.controlServer = GatewayControlServer.Start(
                options.ControlPipeName ?? WindowsControlPipeName.ForCurrentUser(),
                daemon.HandleControlRequestAsync,
                options.ControlRequestTimeout);
            options.OperationalLog.Write(
                GatewayOperationalEvent.DaemonStarted,
                configuration.Revision);
            return daemon;
        }
        catch (Exception startupFailure)
        {
            options.OperationalLog.Write(
                GatewayOperationalEvent.DaemonStartFailed,
                configuration?.Revision,
                errorCode: ErrorCodeFor(startupFailure));
            var cleanupFailures = new List<Exception>();
            if (daemon is not null)
            {
                try
                {
                    await daemon.DisposeAsync();
                }
                catch (Exception cleanupFailure)
                {
                    cleanupFailures.Add(cleanupFailure);
                }
            }
            else
            {
                await TryDisposeBackendAsync(options.BackendHost, cleanupFailures);
                if (cleanupFailures.Count == 0)
                {
                    try
                    {
                        lease.Dispose();
                    }
                    catch (Exception cleanupFailure)
                    {
                        cleanupFailures.Add(cleanupFailure);
                    }
                }
            }

            ThrowPreservingCategory(startupFailure, cleanupFailures);
            throw new InvalidOperationException("Unreachable startup failure path.");
        }
    }

    public ValueTask DisposeAsync()
    {
        lock (disposeLock)
        {
            disposeTask ??= DisposeCoreAsync();
            return new ValueTask(disposeTask);
        }
    }

    public Task WaitForShutdownAsync(CancellationToken cancellationToken = default) =>
        shutdownRequested.Task.WaitAsync(cancellationToken);

    private async Task DisposeCoreAsync()
    {
        operationalLog.Write(GatewayOperationalEvent.DaemonStopping);
        var failures = new List<Exception>();
        if (controlServer is not null)
        {
            try
            {
                await controlServer.DisposeAsync();
            }
            catch (Exception failure)
            {
                failures.Add(failure);
            }
        }

        try
        {
            await runtimeHost.DisposeAsync();
        }
        catch (Exception failure)
        {
            failures.Add(failure);
        }

        await TryDisposeBackendAsync(backendHost, failures);
        if (failures.Count == 0)
        {
            try
            {
                singleInstanceLease.Dispose();
            }
            catch (Exception failure)
            {
                failures.Add(failure);
            }
        }

        if (failures.Count == 1)
        {
            operationalLog.Write(GatewayOperationalEvent.DaemonStopFailed);
            ExceptionDispatchInfo.Capture(failures[0]).Throw();
        }

        if (failures.Count > 1)
        {
            operationalLog.Write(GatewayOperationalEvent.DaemonStopFailed);
            throw new AggregateException("The gateway daemon could not release every owned resource.", failures);
        }

        operationalLog.Write(GatewayOperationalEvent.DaemonStopped);
    }

    private async Task<GatewayControlCommandOutcome> HandleControlRequestAsync(
        ControlRequest request,
        CancellationToken cancellationToken)
    {
        switch (request.Command)
        {
            case ControlCommands.Status:
                return Success(runtimeHost.GetStatus());

            case ControlCommands.Reload:
                GatewayConfiguration configuration;
                try
                {
                    configuration = await configurationStore.LoadAsync(cancellationToken);
                }
                catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
                {
                    throw;
                }
                catch
                {
                    operationalLog.Write(GatewayOperationalEvent.ConfigurationReloadFailed);
                    await runtimeHost.RecordReloadFailureAsync(
                        "aigw_control_configuration_load_failed",
                        CancellationToken.None);
                    return new GatewayControlCommandOutcome(new ControlResponse(
                        ControlProtocol.Version,
                        false,
                        null,
                        new ControlError(
                            "aigw_control_reload_failed",
                            "The gateway configuration could not be reloaded.")));
                }

                try
                {
                    var result = await runtimeHost.ReloadAsync(configuration, cancellationToken);
                    operationalLog.Write(
                        GatewayOperationalEvent.ConfigurationReloadSucceeded,
                        result.Status.ActiveConfigurationRevision);
                    return Success(result.Status);
                }
                catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
                {
                    throw;
                }
                catch
                {
                    operationalLog.Write(GatewayOperationalEvent.ConfigurationReloadFailed);
                    return new GatewayControlCommandOutcome(new ControlResponse(
                        ControlProtocol.Version,
                        false,
                        null,
                        new ControlError(
                            "aigw_control_reload_failed",
                            "The gateway configuration could not be reloaded.")));
                }

            case ControlCommands.Stop:
                return Success(
                    runtimeHost.GetStatus(),
                    () =>
                    {
                        shutdownRequested.TrySetResult();
                        return Task.CompletedTask;
                    });

            default:
                return new GatewayControlCommandOutcome(new ControlResponse(
                    ControlProtocol.Version,
                    false,
                    null,
                    new ControlError(
                        "aigw_control_unsupported_command",
                        "The control command is not supported.")));
        }
    }

    private static GatewayControlCommandOutcome Success(
        GatewayRuntimeStatus status,
        Func<Task>? afterResponse = null) => new(
        new ControlResponse(
            ControlProtocol.Version,
            true,
            new ControlStatus(
                status.Running,
                status.ActiveProfileId,
                status.ActiveConfigurationRevision,
                status.PendingConfigurationRevision,
                status.Switching,
                status.LastReloadErrorCode,
                status.TargetCircuits),
            null),
        afterResponse);

    private static async Task<string> ReadClientTokenAsync(
        ICredentialStore credentialStore,
        CancellationToken cancellationToken)
    {
        string? token;
        try
        {
            token = await credentialStore.GetSecretAsync(
                CredentialTargets.RuntimeClientToken,
                cancellationToken);
        }
        catch (CredentialException exception)
        {
            throw new BackendCredentialException(exception.ErrorCode, exception.Message, exception);
        }

        if (token is null)
        {
            throw new BackendCredentialException(
                "aigw_runtime_client_token_missing",
                "The Local AI Gateway client token is not installed.");
        }

        if (string.IsNullOrWhiteSpace(token) || token.Length > 1024 || token.Any(char.IsControl))
        {
            throw new BackendCredentialException(
                "aigw_runtime_client_token_invalid",
                "The Local AI Gateway client token is malformed.");
        }

        return token;
    }

    private static async Task TryDisposeBackendAsync(
        IBackendHost backend,
        ICollection<Exception> failures)
    {
        try
        {
            if (backend is IAsyncDisposable asyncDisposable)
            {
                await asyncDisposable.DisposeAsync();
            }
            else if (backend is IDisposable disposable)
            {
                disposable.Dispose();
            }
        }
        catch (Exception failure)
        {
            failures.Add(failure);
        }
    }

    private static string ErrorCodeFor(Exception exception) => exception switch
    {
        RuntimeGatewayException runtime => runtime.ErrorCode,
        ConfigurationException configuration => configuration.ErrorCode,
        _ => "aigw_runtime_start_unexpected",
    };

    private static void ThrowPreservingCategory(
        Exception startupFailure,
        IReadOnlyCollection<Exception> cleanupFailures)
    {
        if (cleanupFailures.Count == 0)
        {
            ExceptionDispatchInfo.Capture(startupFailure).Throw();
        }

        var aggregate = new AggregateException(
            "Gateway startup failed and cleanup was incomplete.",
            [startupFailure, .. cleanupFailures]);
        throw startupFailure switch
        {
            BackendCredentialException exception => new BackendCredentialException(
                exception.ErrorCode,
                exception.Message,
                aggregate),
            BackendUnavailableException exception => new BackendUnavailableException(
                exception.Message,
                aggregate,
                exception.ErrorCode),
            RuntimeGatewayException exception => new RuntimeGatewayException(
                exception.ErrorCode,
                exception.Message,
                aggregate),
            _ => new RuntimeGatewayException(
                "aigw_runtime_start_cleanup_failed",
                "Gateway startup failed and cleanup was incomplete.",
                aggregate),
        };
    }
}
