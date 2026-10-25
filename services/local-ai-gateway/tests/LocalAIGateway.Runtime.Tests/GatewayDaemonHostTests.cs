using LocalAIGateway.Core.Backend;
using LocalAIGateway.Core.Configuration;
using LocalAIGateway.Core.Credentials;
using LocalAIGateway.Core.Runtime;

namespace LocalAIGateway.Runtime.Tests;

public sealed class GatewayDaemonHostTests : IDisposable
{
    private const string ClientToken = "daemon-client-token";
    private readonly string temporaryDirectory = Path.Combine(
        Path.GetTempPath(),
        $"LocalAIGateway-DaemonTests-{Guid.NewGuid():N}");
    private readonly string controlPipeName =
        $"LocalAIGateway.Control.DaemonHostTests.{Guid.NewGuid():N}";

    [Fact]
    public async Task Start_reads_the_stable_client_token_target_and_dispose_releases_every_owned_resource_once()
    {
        var backend = new DeterministicBackendHost();
        var credentials = new RecordingCredentialStore(ClientToken);
        var singleInstance = new RecordingSingleInstanceProvider(acquire: true);
        var host = await GatewayDaemonHost.StartAsync(CreateOptions(
            backend,
            credentials,
            singleInstance));

        Assert.Equal([CredentialTargets.RuntimeClientToken], credentials.ReadTargets);
        Assert.Equal(1, backend.PrepareCount);

        await host.DisposeAsync();
        await host.DisposeAsync();

        Assert.Equal(1, backend.DrainCount);
        Assert.Equal(1, backend.StopCount);
        Assert.Equal(1, singleInstance.Lease.DisposeCount);
    }

    [Fact]
    public async Task Existing_instance_is_rejected_before_credentials_or_backend_are_touched()
    {
        var backend = new DeterministicBackendHost();
        var credentials = new RecordingCredentialStore(ClientToken);
        var singleInstance = new RecordingSingleInstanceProvider(acquire: false);

        var exception = await Assert.ThrowsAsync<RuntimeInstanceConflictException>(
            () => GatewayDaemonHost.StartAsync(CreateOptions(
                backend,
                credentials,
                singleInstance)));

        Assert.Equal("aigw_runtime_already_running", exception.ErrorCode);
        Assert.Empty(credentials.ReadTargets);
        Assert.Equal(0, backend.PrepareCount);
        Assert.Equal(0, singleInstance.Lease.DisposeCount);
        await backend.DisposeAsync();
    }

    [Fact]
    public async Task Missing_client_token_is_a_credential_failure_and_releases_the_instance_lease()
    {
        var backend = new DeterministicBackendHost();
        var credentials = new RecordingCredentialStore(secret: null);
        var singleInstance = new RecordingSingleInstanceProvider(acquire: true);

        var exception = await Assert.ThrowsAsync<BackendCredentialException>(
            () => GatewayDaemonHost.StartAsync(CreateOptions(
                backend,
                credentials,
                singleInstance)));

        Assert.Equal("aigw_runtime_client_token_missing", exception.ErrorCode);
        Assert.Equal(0, backend.PrepareCount);
        Assert.Equal(1, singleInstance.Lease.DisposeCount);
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("token\nwith-control")]
    public async Task Malformed_client_token_is_a_credential_failure_and_releases_the_instance_lease(
        string token)
    {
        var backend = new DeterministicBackendHost();
        var singleInstance = new RecordingSingleInstanceProvider(acquire: true);

        var exception = await Assert.ThrowsAsync<BackendCredentialException>(
            () => GatewayDaemonHost.StartAsync(CreateOptions(
                backend,
                new RecordingCredentialStore(token),
                singleInstance)));

        Assert.Equal("aigw_runtime_client_token_invalid", exception.ErrorCode);
        Assert.Equal(0, backend.PrepareCount);
        Assert.Equal(1, singleInstance.Lease.DisposeCount);
    }

    [Fact]
    public async Task Oversized_client_token_is_a_credential_failure_and_releases_the_instance_lease()
    {
        var backend = new DeterministicBackendHost();
        var singleInstance = new RecordingSingleInstanceProvider(acquire: true);

        var exception = await Assert.ThrowsAsync<BackendCredentialException>(
            () => GatewayDaemonHost.StartAsync(CreateOptions(
                backend,
                new RecordingCredentialStore(new string('x', 1025)),
                singleInstance)));

        Assert.Equal("aigw_runtime_client_token_invalid", exception.ErrorCode);
        Assert.Equal(0, backend.PrepareCount);
        Assert.Equal(1, singleInstance.Lease.DisposeCount);
    }

    [Fact]
    public async Task Backend_start_failure_disposes_the_backend_and_releases_the_instance_lease()
    {
        var backend = new FailingDisposableBackendHost();
        var singleInstance = new RecordingSingleInstanceProvider(acquire: true);
        var operationalLog = new RecordingOperationalLog();

        await Assert.ThrowsAsync<BackendUnavailableException>(
            () => GatewayDaemonHost.StartAsync(CreateOptions(
                backend,
                new RecordingCredentialStore(ClientToken),
                singleInstance,
                operationalLog)));

        Assert.Equal(1, backend.PrepareCount);
        Assert.Equal(1, backend.DisposeCount);
        Assert.Equal(1, singleInstance.Lease.DisposeCount);
        Assert.Equal(
            [GatewayOperationalEvent.DaemonStarting, GatewayOperationalEvent.DaemonStartFailed],
            operationalLog.Events);
        Assert.Equal(
            (GatewayOperationalEvent.DaemonStartFailed, 1L, "aigw_test_backend_failed"),
            operationalLog.Entries[^1]);
    }

    [Fact]
    public async Task Backend_dispose_failure_does_not_release_the_single_instance_lease_early()
    {
        var backend = new DisposeFailingStartedBackendHost();
        var singleInstance = new RecordingSingleInstanceProvider(acquire: true);
        var operationalLog = new RecordingOperationalLog();
        var host = await GatewayDaemonHost.StartAsync(CreateOptions(
            backend,
            new RecordingCredentialStore(ClientToken),
            singleInstance,
            operationalLog));

        await Assert.ThrowsAsync<InvalidOperationException>(() => host.DisposeAsync().AsTask());

        Assert.Equal(1, backend.StopCount);
        Assert.Equal(1, backend.DisposeCount);
        Assert.Equal(0, singleInstance.Lease.DisposeCount);
        Assert.Contains(GatewayOperationalEvent.DaemonStopFailed, operationalLog.Events);
        Assert.DoesNotContain(GatewayOperationalEvent.DaemonStopped, operationalLog.Events);
    }

    [Fact]
    public async Task Lifecycle_log_contains_only_fixed_events_and_revision_not_credentials_or_configuration_values()
    {
        const string secretCanary = "runtime-secret-canary-do-not-log";
        var logDirectory = Path.Combine(temporaryDirectory, "operational-logs");
        var log = new BoundedJsonFileOperationalLog(
            new GatewayOperationalLogOptions { DirectoryPath = logDirectory },
            NoOpConfigurationFileSecurity.Instance);
        var host = await GatewayDaemonHost.StartAsync(CreateOptions(
            new DeterministicBackendHost(),
            new RecordingCredentialStore(secretCanary),
            new RecordingSingleInstanceProvider(acquire: true),
            log));

        await host.DisposeAsync();

        var content = File.ReadAllText(Path.Combine(logDirectory, "gateway.log"));
        Assert.DoesNotContain(secretCanary, content, StringComparison.Ordinal);
        Assert.DoesNotContain("offline-placeholder", content, StringComparison.Ordinal);
        Assert.DoesNotContain("http://127.0.0.1:9", content, StringComparison.Ordinal);
        var events = content.Split('\n', StringSplitOptions.RemoveEmptyEntries)
            .Select(line =>
            {
                using var document = System.Text.Json.JsonDocument.Parse(line);
                return document.RootElement.GetProperty("event").GetString()
                    ?? throw new InvalidOperationException("Operational log event was null.");
            })
            .ToArray();
        Assert.Equal(
            ["daemon.starting", "daemon.started", "daemon.stopping", "daemon.stopped"],
            events);
    }

    public void Dispose()
    {
        if (Directory.Exists(temporaryDirectory))
        {
            Directory.Delete(temporaryDirectory, recursive: true);
        }
    }

    private GatewayDaemonOptions CreateOptions(
        IBackendHost backend,
        ICredentialStore credentialStore,
        ISingleInstanceProvider singleInstanceProvider,
        IGatewayOperationalLog? operationalLog = null)
    {
        Directory.CreateDirectory(temporaryDirectory);
        var configurationPath = Path.Combine(temporaryDirectory, "config.json");
        File.WriteAllBytes(configurationPath, ConfigurationJson.Serialize(CreateConfiguration()));
        return new GatewayDaemonOptions
        {
            ConfigurationStore = new ConfigurationStore(
                new ConfigurationPaths(temporaryDirectory),
                NoOpConfigurationFileSecurity.Instance),
            CredentialStore = credentialStore,
            BackendHost = backend,
            SingleInstanceProvider = singleInstanceProvider,
            ControlPipeName = controlPipeName,
            Port = 0,
            OperationalLog = operationalLog ?? NullGatewayOperationalLog.Instance,
        };
    }

    private static GatewayConfiguration CreateConfiguration() => new()
    {
        Revision = 1,
        ActiveProfileId = "daemon",
        Profiles =
        [
            new ProfileConfiguration
            {
                Id = "daemon",
                Name = "Daemon",
                Providers =
                [
                    new ProviderConfiguration
                    {
                        Id = "local",
                        Name = "Local",
                        Type = ProviderType.LocalEndpoint,
                        Endpoint = "http://127.0.0.1:9/v1",
                        CredentialTarget = CredentialTargets.UpstreamApiKey("daemon", "local"),
                    },
                ],
                Models =
                [
                    new ModelConfiguration
                    {
                        Alias = "aigw/default",
                        ProviderId = "local",
                        UpstreamModel = "offline-placeholder",
                        IsDefault = true,
                    },
                ],
            },
        ],
    };

    private sealed class RecordingCredentialStore(string? secret) : ICredentialStore
    {
        public List<string> ReadTargets { get; } = [];

        public ValueTask<string?> GetSecretAsync(
            string target,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            ReadTargets.Add(target);
            return ValueTask.FromResult(secret);
        }

        public ValueTask SetSecretAsync(
            string target,
            string secretValue,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();

        public ValueTask DeleteSecretAsync(
            string target,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();
    }

    private sealed class RecordingSingleInstanceProvider(bool acquire) : ISingleInstanceProvider
    {
        public RecordingSingleInstanceLease Lease { get; } = new();

        public ISingleInstanceLease? TryAcquire() => acquire ? Lease : null;
    }

    private sealed class RecordingSingleInstanceLease : ISingleInstanceLease
    {
        private int disposed;

        public int DisposeCount { get; private set; }

        public void Dispose()
        {
            if (Interlocked.Exchange(ref disposed, 1) == 0)
            {
                DisposeCount++;
            }
        }
    }

    private sealed class FailingDisposableBackendHost : IBackendHost, IAsyncDisposable
    {
        public int PrepareCount { get; private set; }

        public int DisposeCount { get; private set; }

        public Task<BackendInstance> PrepareAsync(
            ProfileConfiguration profile,
            CancellationToken cancellationToken = default)
        {
            PrepareCount++;
            throw new BackendHostException(
                "aigw_test_backend_failed",
                "Test backend failed.",
                BackendFailureCategory.Unavailable);
        }

        public Task<bool> ProbeReadyAsync(
            BackendInstance instance,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();

        public Task DrainAsync(
            BackendInstance instance,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();

        public Task StopAsync(
            BackendInstance instance,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();

        public ValueTask DisposeAsync()
        {
            DisposeCount++;
            return ValueTask.CompletedTask;
        }
    }

    private sealed class DisposeFailingStartedBackendHost : IBackendHost, IAsyncDisposable
    {
        public int StopCount { get; private set; }

        public int DisposeCount { get; private set; }

        public Task<BackendInstance> PrepareAsync(
            ProfileConfiguration profile,
            CancellationToken cancellationToken = default) =>
            Task.FromResult(new BackendInstance(new Uri("http://127.0.0.1:9/"), "internal-token"));

        public Task<bool> ProbeReadyAsync(
            BackendInstance instance,
            CancellationToken cancellationToken = default) =>
            Task.FromResult(true);

        public Task DrainAsync(
            BackendInstance instance,
            CancellationToken cancellationToken = default) =>
            Task.CompletedTask;

        public Task StopAsync(
            BackendInstance instance,
            CancellationToken cancellationToken = default)
        {
            StopCount++;
            return Task.CompletedTask;
        }

        public ValueTask DisposeAsync()
        {
            DisposeCount++;
            return ValueTask.FromException(new InvalidOperationException("backend dispose failed"));
        }
    }

    private sealed class RecordingOperationalLog : IGatewayOperationalLog
    {
        public List<GatewayOperationalEvent> Events { get; } = [];

        public List<(GatewayOperationalEvent Event, long? Revision, string? ErrorCode)> Entries { get; } = [];

        public void Write(
            GatewayOperationalEvent eventType,
            long? configurationRevision = null,
            string? errorCode = null)
        {
            Events.Add(eventType);
            Entries.Add((eventType, configurationRevision, errorCode));
        }
    }
}
