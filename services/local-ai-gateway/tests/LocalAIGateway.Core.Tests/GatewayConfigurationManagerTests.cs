using LocalAIGateway.Core.Configuration;
using LocalAIGateway.Core.Credentials;

namespace LocalAIGateway.Core.Tests;

public sealed class GatewayConfigurationManagerTests : IDisposable
{
    private readonly string temporaryDirectory = Path.Combine(
        Path.GetTempPath(),
        $"LocalAIGateway-ManagerTests-{Guid.NewGuid():N}");
    private readonly RecordingCredentialStore credentials = new();

    [Fact]
    public async Task CreateAddAndActivateProfileMaintainsValidConfiguration()
    {
        var manager = CreateManager();
        await manager.CreateProfileAsync("work", "Work");
        await manager.AddProviderAsync(
            "work",
            new ProviderConfiguration
            {
                Id = "primary",
                Name = "Primary",
                Type = ProviderType.OpenAiCompatible,
                Endpoint = "https://api.example.com/v1",
                CredentialTarget = CredentialTargets.UpstreamApiKey("work", "primary"),
            });
        await manager.AddModelAsync(
            "work",
            new ModelConfiguration
            {
                Alias = "aigw/default",
                ProviderId = "primary",
                UpstreamModel = "model-1",
            },
            makeDefault: false);

        var active = await manager.UseProfileAsync("work");

        Assert.Equal("work", active.ActiveProfileId);
        Assert.True(active.Profiles[0].Models[0].IsDefault);
        Assert.True(ConfigurationValidator.Validate(active).IsValid);
    }

    [Fact]
    public async Task RemovingReferencedProviderFailsWithoutMutation()
    {
        var manager = CreateManager();
        await SeedCompleteAsync(manager);
        var before = await manager.LoadAsync();

        var exception = await Assert.ThrowsAsync<ConfigurationException>(() =>
            manager.RemoveProviderAsync("work", "primary", deleteSecret: false));

        Assert.Equal("aigw_provider_in_use", exception.ErrorCode);
        Assert.Equal(before.Revision, (await manager.LoadAsync()).Revision);
    }

    [Fact]
    public async Task SecretIsStoredOnlyUnderDeterministicTarget()
    {
        var manager = CreateManager();
        await SeedCompleteAsync(manager);

        await manager.SetProviderSecretAsync("work", "primary", "canary-secret");

        Assert.Equal(
            "canary-secret",
            credentials.Values["LocalAIGateway/work/primary/api-key"]);
        var configText = await File.ReadAllTextAsync(manager.Paths.ConfigurationFile);
        Assert.DoesNotContain("canary-secret", configText);
    }

    [Fact]
    public async Task ExplicitProfileSecretDeletionUsesEveryProviderTarget()
    {
        var manager = CreateManager();
        await SeedCompleteAsync(manager);

        await manager.DeleteProfileAsync("work", deleteSecrets: true);

        Assert.Contains("LocalAIGateway/work/primary/api-key", credentials.DeletedTargets);
    }

    [Fact]
    public async Task FirstModelBecomesDefaultEvenWithoutFlag()
    {
        var manager = CreateManager();
        await manager.CreateProfileAsync("draft", "Draft");
        await manager.AddProviderAsync(
            "draft",
            new ProviderConfiguration
            {
                Id = "local",
                Name = "Local",
                Type = ProviderType.LocalEndpoint,
                Endpoint = "http://127.0.0.1:11434/v1",
                CredentialTarget = CredentialTargets.UpstreamApiKey("draft", "local"),
            });

        var saved = await manager.AddModelAsync(
            "draft",
            new ModelConfiguration
            {
                Alias = "local/model",
                ProviderId = "local",
                UpstreamModel = "model",
            },
            makeDefault: false);

        Assert.True(saved.Profiles[0].Models[0].IsDefault);
    }

    [Fact]
    public async Task ProviderCredentialTargetUsesCanonicalStoredProfileCasing()
    {
        var manager = CreateManager();
        await manager.CreateProfileAsync("work", "Work");

        var saved = await manager.AddProviderAsync(
            "WORK",
            new ProviderConfiguration
            {
                Id = "primary",
                Name = "Primary",
                Type = ProviderType.OpenAiCompatible,
                Endpoint = "https://api.example.com/v1",
                CredentialTarget = "LocalAIGateway/untrusted/value/api-key",
            });

        Assert.Equal(
            "LocalAIGateway/work/primary/api-key",
            saved.Profiles[0].Providers[0].CredentialTarget);
    }

    public void Dispose()
    {
        if (Directory.Exists(temporaryDirectory))
        {
            Directory.Delete(temporaryDirectory, recursive: true);
        }
    }

    private GatewayConfigurationManager CreateManager() => new(
        new ConfigurationStore(
            new ConfigurationPaths(temporaryDirectory),
            NoOpConfigurationFileSecurity.Instance),
        credentials);

    private static async Task SeedCompleteAsync(GatewayConfigurationManager manager)
    {
        await manager.CreateProfileAsync("work", "Work");
        await manager.AddProviderAsync(
            "work",
            new ProviderConfiguration
            {
                Id = "primary",
                Name = "Primary",
                Type = ProviderType.OpenAiCompatible,
                Endpoint = "https://api.example.com/v1",
                CredentialTarget = CredentialTargets.UpstreamApiKey("work", "primary"),
            });
        await manager.AddModelAsync(
            "work",
            new ModelConfiguration
            {
                Alias = "aigw/default",
                ProviderId = "primary",
                UpstreamModel = "model-1",
            },
            makeDefault: false);
    }

    private sealed class RecordingCredentialStore : ICredentialStore
    {
        public Dictionary<string, string> Values { get; } = new(StringComparer.Ordinal);

        public List<string> DeletedTargets { get; } = [];

        public ValueTask SetSecretAsync(string target, string secret, CancellationToken cancellationToken = default)
        {
            Values[target] = secret;
            return ValueTask.CompletedTask;
        }

        public ValueTask<string?> GetSecretAsync(string target, CancellationToken cancellationToken = default) =>
            ValueTask.FromResult(Values.GetValueOrDefault(target));

        public ValueTask DeleteSecretAsync(string target, CancellationToken cancellationToken = default)
        {
            Values.Remove(target);
            DeletedTargets.Add(target);
            return ValueTask.CompletedTask;
        }
    }
}
