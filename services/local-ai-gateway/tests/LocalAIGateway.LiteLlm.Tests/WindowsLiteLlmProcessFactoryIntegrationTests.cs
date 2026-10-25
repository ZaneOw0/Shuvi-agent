using LocalAIGateway.Core.Backend;
using LocalAIGateway.Core.Configuration;
using LocalAIGateway.Core.Credentials;

namespace LocalAIGateway.LiteLlm.Tests;

public sealed class WindowsLiteLlmProcessFactoryIntegrationTests
{
    [Fact]
    public async Task Private_runtime_starts_suspended_in_a_job_becomes_ready_and_leaves_no_instance_state()
    {
        var applicationRoot = Environment.GetEnvironmentVariable("AIGW_M3C_APPLICATION_ROOT");
        var testRoot = Environment.GetEnvironmentVariable("AIGW_M3C_TEST_ROOT");
        if (string.IsNullOrWhiteSpace(applicationRoot) || string.IsNullOrWhiteSpace(testRoot))
        {
            return;
        }

        Assert.True(Path.IsPathFullyQualified(applicationRoot));
        Assert.True(Path.IsPathFullyQualified(testRoot));
        Assert.False(Directory.Exists(testRoot));
        Directory.CreateDirectory(testRoot);
        BackendInstance? instance = null;
        await using var host = new LiteLlmBackendHost(
            new LiteLlmConfigurationCompiler(NullCredentialStore.Instance),
            new WindowsLiteLlmProcessFactory(
                applicationRoot,
                Path.Combine(testRoot, "runtime state with spaces"),
                NoOpConfigurationFileSecurity.Instance,
                TimeSpan.FromSeconds(10)));
        try
        {
            instance = await host.PrepareAsync(CreateProfile());
            var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(60);
            var ready = false;
            while (DateTime.UtcNow < deadline)
            {
                if (await host.ProbeReadyAsync(instance))
                {
                    ready = true;
                    break;
                }

                await Task.Delay(100);
            }

            Assert.True(ready, "The private LiteLLM process did not become ready within 60 seconds.");
            await host.DrainAsync(instance);
            await host.StopAsync(instance);
            instance = null;

            var instanceRoot = Path.Combine(testRoot, "runtime state with spaces", "instances");
            Assert.Empty(Directory.Exists(instanceRoot)
                ? Directory.EnumerateFileSystemEntries(instanceRoot)
                : []);
        }
        finally
        {
            if (instance is not null)
            {
                await host.StopAsync(instance);
            }
            if (Directory.Exists(testRoot))
            {
                Directory.Delete(testRoot, recursive: true);
            }
        }
    }

    private static ProfileConfiguration CreateProfile() => new()
    {
        Id = "m3c-integration",
        Name = "M3c Integration",
        Providers =
        [
            new ProviderConfiguration
            {
                Id = "local",
                Name = "Local",
                Type = ProviderType.LocalEndpoint,
                Endpoint = "http://127.0.0.1:9/v1",
                CredentialTarget = "LocalAIGateway/m3c-integration/local/api-key",
            },
        ],
        Models =
        [
            new ModelConfiguration
            {
                Alias = "aigw/local",
                ProviderId = "local",
                UpstreamModel = "offline-placeholder",
                IsDefault = true,
            },
        ],
    };

    private sealed class NullCredentialStore : ICredentialStore
    {
        public static NullCredentialStore Instance { get; } = new();

        public ValueTask<string?> GetSecretAsync(
            string target,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return ValueTask.FromResult<string?>(null);
        }

        public ValueTask SetSecretAsync(
            string target,
            string secret,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();

        public ValueTask DeleteSecretAsync(
            string target,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();
    }
}
