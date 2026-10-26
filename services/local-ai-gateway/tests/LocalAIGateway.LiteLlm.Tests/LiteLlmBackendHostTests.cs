using LocalAIGateway.Core.Backend;
using LocalAIGateway.Core.Configuration;
using LocalAIGateway.Core.Credentials;

namespace LocalAIGateway.LiteLlm.Tests;

public sealed class LiteLlmBackendHostTests
{
    [Fact]
    public async Task Prepare_probe_drain_and_concurrent_stop_share_one_managed_process_lifecycle()
    {
        var profile = CreateProfile();
        var credentials = new SingleCredentialStore(
            "LocalAIGateway/profile/provider/api-key",
            "upstream-secret");
        var process = new FakeManagedProcess();
        var factory = new FakeProcessFactory(process);
        var host = new LiteLlmBackendHost(
            new LiteLlmConfigurationCompiler(credentials),
            factory);

        var instance = await host.PrepareAsync(profile);
        var ready = await host.ProbeReadyAsync(instance);
        await host.DrainAsync(instance);
        await Task.WhenAll(Enumerable.Range(0, 16).Select(_ => host.StopAsync(instance)));

        Assert.True(ready);
        Assert.Equal(instance, process.Instance);
        Assert.Equal(1, factory.StartCount);
        Assert.Equal(1, process.ProbeCount);
        Assert.Equal(1, process.DrainCount);
        Assert.Equal(1, process.StopCount);
        Assert.Equal(1, process.DisposeCount);
        Assert.NotNull(factory.Plan);
        Assert.Equal(
            instance.InternalToken,
            factory.Plan.Environment["AIGW_LITELLM_MASTER_KEY"]);
        Assert.DoesNotContain(
            "upstream-secret",
            System.Text.Encoding.UTF8.GetString(factory.Plan.ConfigurationUtf8.Span),
            StringComparison.Ordinal);
    }

    [Fact]
    public async Task Prepare_preserves_invalid_instance_error_when_failed_startup_cleanup_also_throws()
    {
        var process = new FakeManagedProcess
        {
            ThrowOnStop = true,
        };
        var factory = new FakeProcessFactory(process, synchronizeInternalToken: false);
        var host = new LiteLlmBackendHost(
            new LiteLlmConfigurationCompiler(new SingleCredentialStore(
                "LocalAIGateway/profile/provider/api-key",
                "upstream-secret")),
            factory);

        var exception = await Assert.ThrowsAsync<LiteLlmException>(
            () => host.PrepareAsync(CreateProfile()));

        Assert.Equal("aigw_litellm_instance_invalid", exception.ErrorCode);
        Assert.IsType<AggregateException>(exception.InnerException);
        Assert.Equal(1, process.StopCount);
        Assert.Equal(1, process.DisposeCount);

        process.ThrowOnStop = false;
        await host.DisposeAsync();
        Assert.Equal(2, process.StopCount);
        Assert.Equal(2, process.DisposeCount);
    }

    [Fact]
    public async Task Stop_waits_for_an_in_flight_probe_before_stopping_the_process()
    {
        var process = new FakeManagedProcess { BlockProbe = true };
        var host = CreateHost(process);
        var instance = await host.PrepareAsync(CreateProfile());

        var probe = host.ProbeReadyAsync(instance);
        await process.ProbeEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var stop = host.StopAsync(instance);

        Assert.False(process.StopEntered.Task.IsCompleted);
        process.ReleaseProbe.TrySetResult();
        await Task.WhenAll(probe, stop);

        Assert.Equal(1, process.ProbeCount);
        Assert.Equal(1, process.StopCount);
        Assert.Equal(1, process.DisposeCount);
    }

    [Fact]
    public async Task Stop_preserves_tracking_and_both_failures_until_a_retry_succeeds()
    {
        var process = new FakeManagedProcess
        {
            ThrowOnStop = true,
            ThrowOnDispose = true,
        };
        var host = CreateHost(process);
        var instance = await host.PrepareAsync(CreateProfile());

        var failure = await Assert.ThrowsAsync<AggregateException>(() => host.StopAsync(instance));

        Assert.Equal(2, failure.InnerExceptions.Count);
        var stateFailure = await Assert.ThrowsAsync<LiteLlmException>(
            () => host.ProbeReadyAsync(instance));
        Assert.Equal("aigw_litellm_instance_stop_failed", stateFailure.ErrorCode);

        process.ThrowOnStop = false;
        process.ThrowOnDispose = false;
        await host.StopAsync(instance);
        await host.StopAsync(instance);
        Assert.Equal(2, process.StopCount);
        Assert.Equal(2, process.DisposeCount);
    }

    [Fact]
    public async Task Failed_drain_returns_the_instance_to_active_state()
    {
        var process = new FakeManagedProcess { ThrowOnDrain = true };
        var host = CreateHost(process);
        var instance = await host.PrepareAsync(CreateProfile());

        await Assert.ThrowsAsync<InvalidOperationException>(() => host.DrainAsync(instance));
        process.ThrowOnDrain = false;

        Assert.True(await host.ProbeReadyAsync(instance));
        await host.StopAsync(instance);
    }

    private static LiteLlmBackendHost CreateHost(FakeManagedProcess process) => new(
        new LiteLlmConfigurationCompiler(new SingleCredentialStore(
            "LocalAIGateway/profile/provider/api-key",
            "upstream-secret")),
        new FakeProcessFactory(process));

    private static ProfileConfiguration CreateProfile() => new()
    {
        Id = "profile",
        Name = "Profile",
        Providers =
        [
            new ProviderConfiguration
            {
                Id = "provider",
                Name = "Provider",
                Type = ProviderType.OpenAiCompatible,
                Endpoint = "https://api.example.com/v1",
                CredentialTarget = "LocalAIGateway/profile/provider/api-key",
            },
        ],
        Models =
        [
            new ModelConfiguration
            {
                Alias = "public-model",
                ProviderId = "provider",
                UpstreamModel = "remote-model",
                IsDefault = true,
            },
        ],
    };

    private sealed class FakeProcessFactory(
        FakeManagedProcess process,
        bool synchronizeInternalToken = true) : ILiteLlmProcessFactory
    {
        public int StartCount { get; private set; }

        public LiteLlmConfigurationPlan? Plan { get; private set; }

        public Task<ILiteLlmManagedProcess> StartAsync(
            ProfileConfiguration profile,
            LiteLlmConfigurationPlan plan,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            StartCount++;
            Plan = plan;
            if (synchronizeInternalToken)
            {
                process.SetInternalToken(plan.Environment["AIGW_LITELLM_MASTER_KEY"]);
            }

            return Task.FromResult<ILiteLlmManagedProcess>(process);
        }
    }

    private sealed class FakeManagedProcess : ILiteLlmManagedProcess
    {
        public BackendInstance Instance { get; private set; } =
            new(new Uri("http://127.0.0.1:43123/"), "not-initialized");

        public int ProbeCount { get; private set; }

        public int DrainCount { get; private set; }

        public int StopCount { get; private set; }

        public int DisposeCount { get; private set; }

        public bool ThrowOnStop { get; set; }

        public bool ThrowOnDispose { get; set; }

        public bool ThrowOnDrain { get; set; }

        public bool BlockProbe { get; init; }

        public TaskCompletionSource ProbeEntered { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        public TaskCompletionSource ReleaseProbe { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        public TaskCompletionSource StopEntered { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        public void SetInternalToken(string token) =>
            Instance = new BackendInstance(Instance.BaseAddress, token);

        public async Task<bool> ProbeReadyAsync(CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            ProbeCount++;
            ProbeEntered.TrySetResult();
            if (BlockProbe)
            {
                await ReleaseProbe.Task.WaitAsync(cancellationToken);
            }

            return true;
        }

        public Task DrainAsync(CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            DrainCount++;
            if (ThrowOnDrain)
            {
                throw new InvalidOperationException("drain failure");
            }

            return Task.CompletedTask;
        }

        public Task StopAsync(CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            StopCount++;
            StopEntered.TrySetResult();
            if (ThrowOnStop)
            {
                throw new InvalidOperationException("cleanup failure");
            }

            return Task.CompletedTask;
        }

        public ValueTask DisposeAsync()
        {
            DisposeCount++;
            if (ThrowOnDispose)
            {
                throw new InvalidOperationException("dispose failure");
            }

            return ValueTask.CompletedTask;
        }
    }

    private sealed class SingleCredentialStore(string target, string secret) : ICredentialStore
    {
        public ValueTask<string?> GetSecretAsync(
            string requestedTarget,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return ValueTask.FromResult<string?>(requestedTarget == target ? secret : null);
        }

        public ValueTask SetSecretAsync(
            string requestedTarget,
            string requestedSecret,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();

        public ValueTask DeleteSecretAsync(
            string requestedTarget,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();
    }
}
