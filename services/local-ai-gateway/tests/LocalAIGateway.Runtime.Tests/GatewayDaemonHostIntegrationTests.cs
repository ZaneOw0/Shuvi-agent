using System.Net;
using System.Net.Http.Headers;
using LocalAIGateway.Core.Configuration;
using LocalAIGateway.Core.Control;
using LocalAIGateway.Core.Credentials;
using LocalAIGateway.LiteLlm;
using LocalAIGateway.Windows;
using LocalAIGateway.Windows.Control;

namespace LocalAIGateway.Runtime.Tests;

public sealed class GatewayDaemonHostIntegrationTests
{
    private const string ClientToken = "m3d-local-client-token";

    [Fact]
    public async Task Real_private_runtime_is_composed_behind_the_edge_and_leaves_no_instance_state()
    {
        var applicationRoot = Environment.GetEnvironmentVariable("AIGW_M3D_APPLICATION_ROOT");
        var testRoot = Environment.GetEnvironmentVariable("AIGW_M3D_TEST_ROOT");
        if (string.IsNullOrWhiteSpace(applicationRoot) || string.IsNullOrWhiteSpace(testRoot))
        {
            return;
        }

        Assert.True(Path.IsPathFullyQualified(applicationRoot));
        Assert.True(Path.IsPathFullyQualified(testRoot));
        Assert.False(Directory.Exists(testRoot));
        var configurationRoot = Path.Combine(testRoot, "configuration");
        var runtimeRoot = Path.Combine(testRoot, "runtime state with spaces");
        var logRoot = Path.Combine(testRoot, "logs");
        var configurationPath = Path.Combine(configurationRoot, "config.json");
        var controlPipeName = $"LocalAIGateway.Control.M3eIntegration.{Guid.NewGuid():N}";
        Directory.CreateDirectory(configurationRoot);
        File.WriteAllBytes(
            configurationPath,
            ConfigurationJson.Serialize(CreateConfiguration(1)));

        GatewayDaemonHost? daemon = null;
        try
        {
            var credentialStore = new IntegrationCredentialStore();
            var backend = new LiteLlmBackendHost(
                new LiteLlmConfigurationCompiler(credentialStore),
                new WindowsLiteLlmProcessFactory(
                    applicationRoot,
                    runtimeRoot,
                    NoOpConfigurationFileSecurity.Instance,
                    TimeSpan.FromSeconds(10)));
            daemon = await GatewayDaemonHost.StartAsync(new GatewayDaemonOptions
            {
                ConfigurationStore = new ConfigurationStore(
                    new ConfigurationPaths(configurationRoot),
                    NoOpConfigurationFileSecurity.Instance),
                CredentialStore = credentialStore,
                BackendHost = backend,
                SingleInstanceProvider = new WindowsCurrentUserSingleInstanceProvider(
                    $"m3d-test-{Guid.NewGuid():N}"),
                OperationalLog = new BoundedJsonFileOperationalLog(
                    new GatewayOperationalLogOptions { DirectoryPath = logRoot },
                    new WindowsConfigurationFileSecurity()),
                ControlPipeName = controlPipeName,
                Port = 0,
            });

            var control = new WindowsNamedPipeControlClient(
                controlPipeName,
                TimeSpan.FromSeconds(5),
                TimeSpan.FromSeconds(70));
            var initialStatus = await control.SendAsync(ControlCommands.Status);
            Assert.True(initialStatus.Ok);
            Assert.Equal(1, initialStatus.Status?.ActiveConfigurationRevision);

            File.WriteAllBytes(
                configurationPath,
                ConfigurationJson.Serialize(CreateConfiguration(2)));
            var reload = await control.SendAsync(ControlCommands.Reload);
            Assert.True(reload.Ok);
            Assert.Equal(2, reload.Status?.ActiveConfigurationRevision);
            Assert.False(reload.Status?.Switching);

            using var client = new HttpClient(new SocketsHttpHandler
            {
                UseProxy = false,
                AllowAutoRedirect = false,
            })
            {
                BaseAddress = daemon.BaseAddress,
                Timeout = TimeSpan.FromSeconds(10),
            };
            using var request = new HttpRequestMessage(HttpMethod.Get, "/ready");
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", ClientToken);
            using var response = await client.SendAsync(request);

            Assert.Equal(HttpStatusCode.OK, response.StatusCode);

            var stop = await control.SendAsync(ControlCommands.Stop);
            Assert.True(stop.Ok);
            await daemon.WaitForShutdownAsync().WaitAsync(TimeSpan.FromSeconds(5));
            await daemon.DisposeAsync();
            daemon = null;

            var instancesRoot = Path.Combine(runtimeRoot, "instances");
            Assert.Empty(Directory.Exists(instancesRoot)
                ? Directory.EnumerateFileSystemEntries(instancesRoot)
                : []);
            var logContent = File.ReadAllText(Path.Combine(logRoot, "gateway.log"));
            Assert.Contains("\"event\":\"daemon.started\"", logContent, StringComparison.Ordinal);
            Assert.Contains(
                "\"event\":\"configuration.reload_succeeded\"",
                logContent,
                StringComparison.Ordinal);
            Assert.Contains("\"event\":\"daemon.stopped\"", logContent, StringComparison.Ordinal);
            Assert.DoesNotContain(ClientToken, logContent, StringComparison.Ordinal);
            Assert.DoesNotContain("offline-placeholder", logContent, StringComparison.Ordinal);
        }
        finally
        {
            if (daemon is not null)
            {
                await daemon.DisposeAsync();
            }

            if (Directory.Exists(testRoot))
            {
                Directory.Delete(testRoot, recursive: true);
            }
        }
    }

    private static GatewayConfiguration CreateConfiguration(long revision) => new()
    {
        Revision = revision,
        ActiveProfileId = "m3d-integration",
        Profiles =
        [
            new ProfileConfiguration
            {
                Id = "m3d-integration",
                Name = "M3d Integration",
                Providers =
                [
                    new ProviderConfiguration
                    {
                        Id = "local",
                        Name = "Local",
                        Type = ProviderType.LocalEndpoint,
                        Endpoint = "http://127.0.0.1:9/v1",
                        CredentialTarget = CredentialTargets.UpstreamApiKey("m3d-integration", "local"),
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
            },
        ],
    };

    private sealed class IntegrationCredentialStore : ICredentialStore
    {
        public ValueTask<string?> GetSecretAsync(
            string target,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return ValueTask.FromResult<string?>(
                target == CredentialTargets.RuntimeClientToken ? ClientToken : null);
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
