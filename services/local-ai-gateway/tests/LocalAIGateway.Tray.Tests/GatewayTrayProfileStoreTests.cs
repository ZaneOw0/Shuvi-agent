using LocalAIGateway.Core.Configuration;
using LocalAIGateway.Core.Credentials;
using LocalAIGateway.Tray;

namespace LocalAIGateway.Tray.Tests;

public sealed class GatewayTrayProfileStoreTests
{
    [Fact]
    public async Task Select_uses_the_atomic_configuration_manager_and_reports_activatable_profiles()
    {
        var testRoot = Path.Combine(
            Path.GetTempPath(),
            $"LocalAIGateway-TrayProfile-{Guid.NewGuid():N}");
        try
        {
            var store = new ConfigurationStore(
                new ConfigurationPaths(testRoot),
                NoOpSecurity.Instance);
            await store.SaveAsync(new GatewayConfiguration
            {
                Profiles =
                [
                    new ProfileConfiguration
                    {
                        Id = "ready",
                        Name = "Ready",
                        Providers =
                        [
                            new ProviderConfiguration
                            {
                                Id = "provider",
                                Name = "Provider",
                                Type = ProviderType.LocalEndpoint,
                                Endpoint = "http://127.0.0.1:1234",
                                CredentialTarget = CredentialTargets.UpstreamApiKey("ready", "provider"),
                            },
                        ],
                        Models =
                        [
                            new ModelConfiguration
                            {
                                Alias = "aigw/default",
                                ProviderId = "provider",
                                UpstreamModel = "fixture",
                                IsDefault = true,
                            },
                        ],
                    },
                    new ProfileConfiguration { Id = "draft", Name = "Draft" },
                ],
            }, 0);
            var profileStore = new GatewayTrayProfileStore(
                new GatewayConfigurationManager(store, new MemoryCredentialStore()));

            var selected = await profileStore.SelectAsync("ready");

            Assert.Equal("ready", selected.SelectedProfileId);
            Assert.Equal(2, selected.Revision);
            Assert.True(selected.Profiles.Single(profile => profile.Id == "ready").CanActivate);
            Assert.False(selected.Profiles.Single(profile => profile.Id == "draft").CanActivate);
            Assert.Equal("ready", (await store.LoadAsync()).ActiveProfileId);
        }
        finally
        {
            if (Directory.Exists(testRoot))
            {
                Directory.Delete(testRoot, recursive: true);
            }
        }
    }

    private sealed class NoOpSecurity : IConfigurationFileSecurity
    {
        public static NoOpSecurity Instance { get; } = new();

        public void ProtectDirectory(string path)
        {
        }

        public void ProtectFile(string path)
        {
        }
    }

    private sealed class MemoryCredentialStore : ICredentialStore
    {
        public ValueTask SetSecretAsync(
            string target,
            string secret,
            CancellationToken cancellationToken = default) =>
            ValueTask.CompletedTask;

        public ValueTask<string?> GetSecretAsync(
            string target,
            CancellationToken cancellationToken = default) =>
            ValueTask.FromResult<string?>(null);

        public ValueTask DeleteSecretAsync(
            string target,
            CancellationToken cancellationToken = default) =>
            ValueTask.CompletedTask;
    }
}
