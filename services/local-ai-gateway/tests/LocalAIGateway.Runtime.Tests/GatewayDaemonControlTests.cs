using System.Collections.Concurrent;
using System.Text;
using LocalAIGateway.Core.Backend;
using LocalAIGateway.Core.Configuration;
using LocalAIGateway.Core.Control;
using LocalAIGateway.Core.Credentials;
using LocalAIGateway.Core.Runtime;
using LocalAIGateway.Windows.Control;

namespace LocalAIGateway.Runtime.Tests;

public sealed class GatewayDaemonControlTests : IDisposable
{
    private const string ClientToken = "daemon-control-client-token";
    private readonly string testRoot = Path.Combine(
        Path.GetTempPath(),
        $"LocalAIGateway-DaemonControl-{Guid.NewGuid():N}");

    [Fact]
    public async Task Status_and_stop_use_the_private_control_pipe_without_exposing_runtime_secrets()
    {
        var pipeName = $"LocalAIGateway.Control.DaemonTests.{Guid.NewGuid():N}";
        await using var backend = new MultiBackendHost();
        await using var daemon = await GatewayDaemonHost.StartAsync(CreateOptions(backend, pipeName));
        var client = new WindowsNamedPipeControlClient(pipeName);

        var status = await client.SendAsync(ControlCommands.Status);

        Assert.True(status.Ok);
        Assert.Equal("profile-1", status.Status?.ActiveProfileId);
        Assert.Equal(1, status.Status?.ActiveConfigurationRevision);
        var circuit = Assert.Single(status.Status?.TargetCircuits ?? []);
        Assert.Equal("local", circuit.ProviderId);
        Assert.Equal("aigw/default", circuit.ModelAlias);
        Assert.Equal(CircuitStates.Closed, circuit.State);
        var statusJson = Encoding.UTF8.GetString(ControlJson.SerializeResponse(status));
        Assert.DoesNotContain(ClientToken, statusJson, StringComparison.Ordinal);
        Assert.DoesNotContain(backend.Tokens.Single(), statusJson, StringComparison.Ordinal);

        var stop = await client.SendAsync(ControlCommands.Stop);
        Assert.True(stop.Ok);
        await daemon.WaitForShutdownAsync().WaitAsync(TimeSpan.FromSeconds(2));
    }

    [Fact]
    public async Task Reload_rereads_the_configuration_source_and_never_accepts_configuration_from_the_client()
    {
        var pipeName = $"LocalAIGateway.Control.DaemonTests.{Guid.NewGuid():N}";
        await using var backend = new MultiBackendHost();
        var operationalLog = new RecordingOperationalLog();
        await using var daemon = await GatewayDaemonHost.StartAsync(
            CreateOptions(backend, pipeName, operationalLog));
        File.WriteAllBytes(
            Path.Combine(testRoot, "config.json"),
            ConfigurationJson.Serialize(CreateConfiguration(2)));
        var client = new WindowsNamedPipeControlClient(pipeName);

        var reload = await client.SendAsync(ControlCommands.Reload);

        Assert.True(reload.Ok);
        Assert.Equal(2, reload.Status?.ActiveConfigurationRevision);
        Assert.Equal("profile-2", reload.Status?.ActiveProfileId);
        Assert.Equal(CircuitStates.Closed, Assert.Single(reload.Status?.TargetCircuits ?? []).State);
        Assert.Equal(2, backend.PreparedProfiles.Count);
        Assert.Contains(
            (GatewayOperationalEvent.ConfigurationReloadSucceeded, 2L),
            operationalLog.Entries);
        await WaitUntilAsync(() => backend.StoppedProfiles.Contains("profile-1"));
    }

    [Fact]
    public async Task Failed_reload_returns_a_generic_control_error_and_status_keeps_the_pending_revision()
    {
        var pipeName = $"LocalAIGateway.Control.DaemonTests.{Guid.NewGuid():N}";
        await using var backend = new MultiBackendHost();
        backend.FailingProfiles.Add("profile-2");
        var operationalLog = new RecordingOperationalLog();
        await using var daemon = await GatewayDaemonHost.StartAsync(
            CreateOptions(backend, pipeName, operationalLog));
        File.WriteAllBytes(
            Path.Combine(testRoot, "config.json"),
            ConfigurationJson.Serialize(CreateConfiguration(2)));
        var client = new WindowsNamedPipeControlClient(pipeName);

        var reload = await client.SendAsync(ControlCommands.Reload);
        var status = await client.SendAsync(ControlCommands.Status);

        Assert.False(reload.Ok);
        Assert.Equal("aigw_control_reload_failed", reload.Error?.Code);
        Assert.DoesNotContain("profile-2", reload.Error?.Message, StringComparison.Ordinal);
        Assert.Equal(1, status.Status?.ActiveConfigurationRevision);
        Assert.Equal(2, status.Status?.PendingConfigurationRevision);
        Assert.Equal("aigw_test_candidate_failed", status.Status?.LastReloadErrorCode);
        Assert.Contains(
            (GatewayOperationalEvent.ConfigurationReloadFailed, (long?)null),
            operationalLog.Entries);
    }

    [Fact]
    public async Task Unreadable_configuration_records_a_stable_reload_status_error()
    {
        var pipeName = $"LocalAIGateway.Control.DaemonTests.{Guid.NewGuid():N}";
        await using var backend = new MultiBackendHost();
        await using var daemon = await GatewayDaemonHost.StartAsync(CreateOptions(backend, pipeName));
        File.WriteAllText(Path.Combine(testRoot, "config.json"), "not-json");
        var client = new WindowsNamedPipeControlClient(pipeName);

        var reload = await client.SendAsync(ControlCommands.Reload);
        var status = await client.SendAsync(ControlCommands.Status);

        Assert.False(reload.Ok);
        Assert.Equal("aigw_control_reload_failed", reload.Error?.Code);
        Assert.Equal(1, status.Status?.ActiveConfigurationRevision);
        Assert.Equal("aigw_control_configuration_load_failed", status.Status?.LastReloadErrorCode);
    }

    [Fact]
    public async Task Status_observes_active_and_pending_revisions_while_reload_prepares_the_candidate()
    {
        var pipeName = $"LocalAIGateway.Control.DaemonTests.{Guid.NewGuid():N}";
        await using var backend = new MultiBackendHost();
        var gate = backend.BlockPreparation("profile-2");
        await using var daemon = await GatewayDaemonHost.StartAsync(CreateOptions(backend, pipeName));
        File.WriteAllBytes(
            Path.Combine(testRoot, "config.json"),
            ConfigurationJson.Serialize(CreateConfiguration(2)));
        var reloadClient = new WindowsNamedPipeControlClient(pipeName);
        var statusClient = new WindowsNamedPipeControlClient(pipeName);

        var reloadTask = reloadClient.SendAsync(ControlCommands.Reload);
        await gate.Entered.Task.WaitAsync(TimeSpan.FromSeconds(2));
        var status = await statusClient.SendAsync(ControlCommands.Status);

        Assert.True(status.Status?.Switching);
        Assert.Equal(1, status.Status?.ActiveConfigurationRevision);
        Assert.Equal(2, status.Status?.PendingConfigurationRevision);
        gate.Release.TrySetResult();
        Assert.True((await reloadTask).Ok);
    }

    public void Dispose()
    {
        if (Directory.Exists(testRoot))
        {
            Directory.Delete(testRoot, recursive: true);
        }
    }

    private GatewayDaemonOptions CreateOptions(
        IBackendHost backend,
        string pipeName,
        IGatewayOperationalLog? operationalLog = null)
    {
        Directory.CreateDirectory(testRoot);
        File.WriteAllBytes(
            Path.Combine(testRoot, "config.json"),
            ConfigurationJson.Serialize(CreateConfiguration(1)));
        return new GatewayDaemonOptions
        {
            ConfigurationStore = new ConfigurationStore(
                new ConfigurationPaths(testRoot),
                NoOpConfigurationFileSecurity.Instance),
            CredentialStore = new ClientCredentialStore(),
            BackendHost = backend,
            SingleInstanceProvider = new SingleInstanceProvider(),
            ControlPipeName = pipeName,
            ControlRequestTimeout = TimeSpan.FromSeconds(2),
            Port = 0,
            OperationalLog = operationalLog ?? NullGatewayOperationalLog.Instance,
        };
    }

    private static GatewayConfiguration CreateConfiguration(long revision) => new()
    {
        Revision = revision,
        ActiveProfileId = $"profile-{revision}",
        Profiles =
        [
            new ProfileConfiguration
            {
                Id = $"profile-{revision}",
                Name = $"Profile {revision}",
                Providers =
                [
                    new ProviderConfiguration
                    {
                        Id = "local",
                        Name = "Local",
                        Type = ProviderType.LocalEndpoint,
                        Endpoint = "http://127.0.0.1:9/v1",
                        CredentialTarget = $"LocalAIGateway/profile-{revision}/local/api-key",
                    },
                ],
                Models =
                [
                    new ModelConfiguration
                    {
                        Alias = "aigw/default",
                        ProviderId = "local",
                        UpstreamModel = $"upstream-{revision}",
                        IsDefault = true,
                    },
                ],
            },
        ],
    };

    private static async Task WaitUntilAsync(Func<bool> predicate)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(2));
        while (!predicate())
        {
            await Task.Delay(20, timeout.Token);
        }
    }

    private sealed class ClientCredentialStore : ICredentialStore
    {
        public ValueTask<string?> GetSecretAsync(string target, CancellationToken cancellationToken = default) =>
            ValueTask.FromResult<string?>(target == CredentialTargets.RuntimeClientToken ? ClientToken : null);

        public ValueTask SetSecretAsync(string target, string secret, CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();

        public ValueTask DeleteSecretAsync(string target, CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();
    }

    private sealed class SingleInstanceProvider : ISingleInstanceProvider
    {
        public ISingleInstanceLease? TryAcquire() => new Lease();

        private sealed class Lease : ISingleInstanceLease
        {
            public void Dispose()
            {
            }
        }
    }

    private sealed class MultiBackendHost : IBackendHost, IAsyncDisposable
    {
        private readonly ConcurrentDictionary<BackendInstance, string> instances = new();

        public ConcurrentBag<string> PreparedProfiles { get; } = [];

        public ConcurrentBag<string> StoppedProfiles { get; } = [];

        public ConcurrentBag<string> Tokens { get; } = [];

        public HashSet<string> FailingProfiles { get; } = [];

        public ConcurrentDictionary<string, PreparationGate> PreparationGates { get; } = new();

        public PreparationGate BlockPreparation(string profileId)
        {
            var gate = new PreparationGate();
            Assert.True(PreparationGates.TryAdd(profileId, gate));
            return gate;
        }

        public async Task<BackendInstance> PrepareAsync(
            ProfileConfiguration profile,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (PreparationGates.TryGetValue(profile.Id, out var gate))
            {
                gate.Entered.TrySetResult();
                await gate.Release.Task.WaitAsync(cancellationToken);
            }

            if (FailingProfiles.Contains(profile.Id))
            {
                throw new BackendHostException(
                    "aigw_test_candidate_failed",
                    "Candidate failed with test-only details.",
                    BackendFailureCategory.Unavailable);
            }

            var token = $"internal-token-{Guid.NewGuid():N}";
            var instance = new BackendInstance(new Uri("http://127.0.0.1:9/"), token);
            instances[instance] = profile.Id;
            PreparedProfiles.Add(profile.Id);
            Tokens.Add(token);
            return instance;
        }

        public Task<bool> ProbeReadyAsync(BackendInstance instance, CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return Task.FromResult(true);
        }

        public Task DrainAsync(BackendInstance instance, CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return Task.CompletedTask;
        }

        public Task StopAsync(BackendInstance instance, CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (instances.TryRemove(instance, out var profile))
            {
                StoppedProfiles.Add(profile);
            }

            return Task.CompletedTask;
        }

        public async ValueTask DisposeAsync()
        {
            foreach (var instance in instances.Keys.ToArray())
            {
                await StopAsync(instance);
            }
        }
    }

    private sealed class PreparationGate
    {
        public TaskCompletionSource Entered { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        public TaskCompletionSource Release { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
    }

    private sealed class RecordingOperationalLog : IGatewayOperationalLog
    {
        public ConcurrentBag<(GatewayOperationalEvent Event, long? Revision)> Entries { get; } = [];

        public void Write(
            GatewayOperationalEvent eventType,
            long? configurationRevision = null,
            string? errorCode = null) =>
            Entries.Add((eventType, configurationRevision));
    }
}
