using System.Text.Json;
using LocalAIGateway.Core.Configuration;
using LocalAIGateway.Core.Credentials;

namespace LocalAIGateway.Cli.Tests;

public sealed class M1ConfigurationCommandTests : IDisposable
{
    private readonly string temporaryDirectory = Path.Combine(
        Path.GetTempPath(),
        $"LocalAIGateway-CliM1Tests-{Guid.NewGuid():N}");
    private readonly InMemoryCredentialStore credentialStore = new();

    [Fact]
    public async Task FullProfileProviderModelFlowActivatesProfile()
    {
        var services = CreateServices();
        Assert.Equal(0, (await RunAsync(services, "profile", "create", "--id", "work", "--name", "Work", "--json")).ExitCode);
        Assert.Equal(0, (await RunAsync(
            services,
            "provider", "add",
            "--profile", "work",
            "--id", "primary",
            "--name", "Primary",
            "--type", "openai-compatible",
            "--endpoint", "https://api.example.com/v1",
            "--json")).ExitCode);
        Assert.Equal(0, (await RunAsync(
            services,
            "model", "add",
            "--profile", "work",
            "--alias", "aigw/default",
            "--provider", "primary",
            "--upstream", "model-1",
            "--json")).ExitCode);

        var use = await RunAsync(services, "profile", "use", "--id", "work", "--json");
        var validate = await RunAsync(services, "config", "validate", "--json");

        Assert.Equal(0, use.ExitCode);
        Assert.Equal(0, validate.ExitCode);
        using var validateJson = JsonDocument.Parse(validate.Output);
        Assert.True(validateJson.RootElement.GetProperty("data").GetProperty("valid").GetBoolean());
        var saved = ConfigurationJson.Deserialize(await File.ReadAllBytesAsync(
            Path.Combine(temporaryDirectory, "config.json")));
        Assert.Equal("work", saved.ActiveProfileId);
        Assert.True(saved.Profiles[0].Models[0].IsDefault);
        Assert.Equal(4, saved.Revision);
    }

    [Fact]
    public async Task RecursiveJsonOptionWorksAfterLeafCommand()
    {
        var services = CreateServices();
        await RunAsync(services, "profile", "create", "--id", "work", "--name", "Work");

        var result = await RunAsync(services, "profile", "list", "--json");

        Assert.Equal(0, result.ExitCode);
        using var json = JsonDocument.Parse(result.Output);
        Assert.Equal("profile.list", json.RootElement.GetProperty("command").GetString());
        Assert.Equal("work", json.RootElement.GetProperty("data")[0].GetProperty("id").GetString());
    }

    [Fact]
    public async Task RemoteHttpProviderReturnsStableConfigurationError()
    {
        var services = CreateServices();
        await RunAsync(services, "profile", "create", "--id", "work", "--name", "Work");

        var result = await RunAsync(
            services,
            "provider", "add",
            "--profile", "work",
            "--id", "unsafe",
            "--name", "Unsafe",
            "--type", "anthropic",
            "--endpoint", "http://api.example.com",
            "--json");

        Assert.Equal(10, result.ExitCode);
        using var json = JsonDocument.Parse(result.Error);
        Assert.Equal(
            "aigw_config_endpoint_https_required",
            json.RootElement.GetProperty("error").GetProperty("code").GetString());
        var loaded = await services.Configuration.LoadAsync();
        Assert.Empty(loaded.Profiles[0].Providers);
    }

    [Fact]
    public async Task SecretStdinNeverAppearsInConfigOrOutput()
    {
        var services = CreateServices();
        await SeedProviderAsync(services);
        const string canary = "M1-CANARY-SECRET-NEVER-PERSIST";

        var result = await RunAsync(
            services,
            ["provider", "set-secret", "--profile", "work", "--id", "primary", "--secret-stdin", "--json"],
            canary + Environment.NewLine);

        Assert.Equal(0, result.ExitCode);
        Assert.DoesNotContain(canary, result.Output);
        Assert.DoesNotContain(canary, result.Error);
        Assert.Equal(canary, credentialStore.Values["LocalAIGateway/work/primary/api-key"]);
        Assert.DoesNotContain(canary, await File.ReadAllTextAsync(Path.Combine(temporaryDirectory, "config.json")));
    }

    [Fact]
    public async Task UnsupportedPlaintextSecretArgumentIsRejectedWithoutEcho()
    {
        var services = CreateServices();
        await SeedProviderAsync(services);
        const string attemptedSecret = "DO-NOT-ECHO-THIS-SECRET";

        var result = await RunAsync(
            services,
            "provider", "set-secret",
            "--profile", "work",
            "--id", "primary",
            "--secret", attemptedSecret,
            "--json", "--verbose");

        Assert.Equal(2, result.ExitCode);
        Assert.DoesNotContain(attemptedSecret, result.Output);
        Assert.DoesNotContain(attemptedSecret, result.Error);
        Assert.Empty(credentialStore.Values);
    }

    [Fact]
    public async Task ConfigPathUsesInjectedTemporaryRoot()
    {
        var services = CreateServices();

        var result = await RunAsync(services, "config", "path", "--json");

        Assert.Equal(0, result.ExitCode);
        using var json = JsonDocument.Parse(result.Output);
        Assert.Equal(
            temporaryDirectory,
            json.RootElement.GetProperty("data").GetProperty("root").GetString());
    }

    [Fact]
    public async Task CorruptConfigurationReturnsExitCodeTen()
    {
        Directory.CreateDirectory(temporaryDirectory);
        await File.WriteAllTextAsync(Path.Combine(temporaryDirectory, "config.json"), "{broken");

        var result = await RunAsync(CreateServices(), "config", "validate", "--json");

        Assert.Equal(10, result.ExitCode);
        using var json = JsonDocument.Parse(result.Error);
        Assert.Equal("aigw_config_corrupt", json.RootElement.GetProperty("error").GetProperty("code").GetString());
    }

    [Fact]
    public async Task UpdateListShowDefaultAndExplicitRemovalCommandsCompleteLifecycle()
    {
        var services = CreateServices();
        await SeedProviderAsync(services);
        Assert.Equal(0, (await RunAsync(
            services,
            "model", "add", "--profile", "work", "--alias", "first", "--provider", "primary", "--upstream", "model-1")).ExitCode);
        Assert.Equal(0, (await RunAsync(
            services,
            "model", "add", "--profile", "work", "--alias", "second", "--provider", "primary", "--upstream", "model-2", "--default")).ExitCode);
        Assert.Equal(0, (await RunAsync(
            services,
            "model", "update", "--profile", "work", "--alias", "second", "--new-alias", "renamed", "--upstream", "model-2b")).ExitCode);
        Assert.Equal(0, (await RunAsync(
            services,
            "model", "set-default", "--profile", "work", "--alias", "first")).ExitCode);
        Assert.Equal(0, (await RunAsync(
            services,
            "provider", "update", "--profile", "work", "--id", "primary", "--name", "Updated", "--endpoint", "https://api.example.com/v2")).ExitCode);

        var providerShow = await RunAsync(services, "provider", "show", "--profile", "work", "--id", "primary", "--json");
        var modelList = await RunAsync(services, "model", "list", "--profile", "work", "--json");
        Assert.Equal(0, providerShow.ExitCode);
        Assert.Equal(0, modelList.ExitCode);
        using (var providerJson = JsonDocument.Parse(providerShow.Output))
        {
            Assert.Equal("Updated", providerJson.RootElement.GetProperty("data").GetProperty("name").GetString());
        }
        using (var modelsJson = JsonDocument.Parse(modelList.Output))
        {
            Assert.Equal(2, modelsJson.RootElement.GetProperty("data").GetArrayLength());
        }

        Assert.Equal(0, (await RunAsync(services, "model", "remove", "--profile", "work", "--alias", "renamed")).ExitCode);
        Assert.Equal(0, (await RunAsync(services, "model", "remove", "--profile", "work", "--alias", "first")).ExitCode);
        Assert.Equal(0, (await RunAsync(
            services,
            "provider", "remove", "--profile", "work", "--id", "primary", "--delete-secret")).ExitCode);
        Assert.Contains("LocalAIGateway/work/primary/api-key", credentialStore.DeletedTargets);
        Assert.Equal(0, (await RunAsync(services, "profile", "delete", "--id", "work")).ExitCode);

        var final = await services.Configuration.LoadAsync();
        Assert.Empty(final.Profiles);
        Assert.Null(final.ActiveProfileId);
    }

    [Fact]
    public async Task ModelTargetCommandsConfigureWeightedRoutingAndRemovalLifecycle()
    {
        var services = CreateServices();
        await SeedProviderAsync(services);
        Assert.Equal(0, (await RunAsync(
            services,
            "provider", "add", "--profile", "work", "--id", "secondary", "--name", "Secondary",
            "--type", "openai-compatible", "--endpoint", "https://secondary.example.com/v1")).ExitCode);
        Assert.Equal(0, (await RunAsync(
            services,
            "model", "add", "--profile", "work", "--alias", "chat", "--provider", "primary", "--upstream", "primary-model")).ExitCode);
        Assert.Equal(0, (await RunAsync(
            services,
            "model", "fallback-add", "--profile", "work", "--alias", "chat", "--provider", "secondary", "--upstream", "fallback-model")).ExitCode);
        Assert.Equal(0, (await RunAsync(
            services,
            "model", "weight-set", "--profile", "work", "--alias", "chat", "--provider", "primary", "--weight", "2")).ExitCode);
        Assert.Equal(0, (await RunAsync(
            services,
            "model", "weight-set", "--profile", "work", "--alias", "chat", "--provider", "secondary", "--weight", "3")).ExitCode);
        Assert.Equal(0, (await RunAsync(
            services,
            "model", "routing-set", "--profile", "work", "--alias", "chat", "--strategy", "weighted-round-robin")).ExitCode);

        var shown = await RunAsync(services, "model", "show", "--profile", "work", "--alias", "chat", "--json");
        using (var json = JsonDocument.Parse(shown.Output))
        {
            var fallback = Assert.Single(json.RootElement.GetProperty("data").GetProperty("fallbacks").EnumerateArray());
            Assert.Equal("secondary", fallback.GetProperty("providerId").GetString());
            Assert.Equal("fallback-model", fallback.GetProperty("upstreamModel").GetString());
            Assert.Equal(3, fallback.GetProperty("weight").GetInt32());
            Assert.Equal("weighted-round-robin", json.RootElement.GetProperty("data").GetProperty("routingStrategy").GetString());
            Assert.Equal(2, json.RootElement.GetProperty("data").GetProperty("weight").GetInt32());
        }

        var inUse = await RunAsync(
            services,
            "provider", "remove", "--profile", "work", "--id", "secondary", "--json");
        Assert.Equal(10, inUse.ExitCode);
        Assert.Contains("aigw_provider_in_use", inUse.Error, StringComparison.Ordinal);

        Assert.Equal(0, (await RunAsync(
            services,
            "model", "routing-set", "--profile", "work", "--alias", "chat", "--strategy", "ordered-fallback")).ExitCode);
        Assert.Equal(0, (await RunAsync(
            services,
            "model", "fallback-remove", "--profile", "work", "--alias", "chat", "--provider", "secondary")).ExitCode);
        Assert.Equal(0, (await RunAsync(
            services,
            "provider", "remove", "--profile", "work", "--id", "secondary")).ExitCode);
    }

    [Fact]
    public async Task LimitCommandsReplaceAndClearAllThreeScopes()
    {
        var services = CreateServices();
        await SeedProviderAsync(services);
        Assert.Equal(0, (await RunAsync(
            services,
            "model", "add", "--profile", "work", "--alias", "chat", "--provider", "primary", "--upstream", "model")).ExitCode);

        Assert.Equal(0, (await RunAsync(
            services,
            "limits", "profile", "set", "--profile", "work", "--concurrency", "2", "--rpm", "20")).ExitCode);
        Assert.Equal(0, (await RunAsync(
            services,
            "limits", "provider", "set", "--profile", "work", "--provider", "primary", "--rpm", "10")).ExitCode);
        Assert.Equal(0, (await RunAsync(
            services,
            "limits", "model", "set", "--profile", "work", "--alias", "chat", "--tpm", "3000")).ExitCode);

        var configured = await services.Configuration.LoadAsync();
        Assert.Equal(2, configured.Profiles[0].Limits!.MaxConcurrentRequests);
        Assert.Equal(20, configured.Profiles[0].Limits!.RequestsPerMinute);
        Assert.Equal(10, configured.Profiles[0].Providers[0].Limits!.RequestsPerMinute);
        Assert.Equal(3000, configured.Profiles[0].Models[0].Limits!.TokensPerMinute);

        var missingValues = await RunAsync(
            services,
            "limits", "model", "set", "--profile", "work", "--alias", "chat", "--json");
        Assert.Equal(10, missingValues.ExitCode);
        Assert.Contains("aigw_limits_values_required", missingValues.Error, StringComparison.Ordinal);

        Assert.Equal(0, (await RunAsync(
            services,
            "limits", "profile", "clear", "--profile", "work")).ExitCode);
        Assert.Equal(0, (await RunAsync(
            services,
            "limits", "provider", "clear", "--profile", "work", "--provider", "primary")).ExitCode);
        Assert.Equal(0, (await RunAsync(
            services,
            "limits", "model", "clear", "--profile", "work", "--alias", "chat")).ExitCode);

        var cleared = await services.Configuration.LoadAsync();
        Assert.Null(cleared.Profiles[0].Limits);
        Assert.Null(cleared.Profiles[0].Providers[0].Limits);
        Assert.Null(cleared.Profiles[0].Models[0].Limits);
    }

    public void Dispose()
    {
        if (Directory.Exists(temporaryDirectory))
        {
            Directory.Delete(temporaryDirectory, recursive: true);
        }
    }

    private CliServices CreateServices() => new(new GatewayConfigurationManager(
        new ConfigurationStore(
            new ConfigurationPaths(temporaryDirectory),
            NoOpConfigurationFileSecurity.Instance),
        credentialStore));

    private static async Task SeedProviderAsync(CliServices services)
    {
        await services.Configuration.CreateProfileAsync("work", "Work");
        await services.Configuration.AddProviderAsync(
            "work",
            new ProviderConfiguration
            {
                Id = "primary",
                Name = "Primary",
                Type = ProviderType.OpenAiCompatible,
                Endpoint = "https://api.example.com/v1",
                CredentialTarget = CredentialTargets.UpstreamApiKey("work", "primary"),
            });
    }

    private static Task<CliRunResult> RunAsync(CliServices services, params string[] args) =>
        RunAsync(services, args, string.Empty);

    private static async Task<CliRunResult> RunAsync(CliServices services, string[] args, string stdin)
    {
        using var input = new StringReader(stdin);
        using var output = new StringWriter();
        using var error = new StringWriter();
        var exitCode = await CliApplication.RunAsync(args, input, output, error, services);
        return new CliRunResult(exitCode, output.ToString(), error.ToString());
    }

    private sealed record CliRunResult(int ExitCode, string Output, string Error);

    private sealed class InMemoryCredentialStore : ICredentialStore
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
