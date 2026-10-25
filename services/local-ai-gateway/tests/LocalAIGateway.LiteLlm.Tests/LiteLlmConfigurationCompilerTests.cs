using System.Text;
using System.Text.Json;
using LocalAIGateway.Core.Backend;
using LocalAIGateway.Core.Configuration;
using LocalAIGateway.Core.Credentials;

namespace LocalAIGateway.LiteLlm.Tests;

public sealed class LiteLlmConfigurationCompilerTests
{
    [Fact]
    public async Task CompileAsync_emits_deterministic_config_without_secret_material()
    {
        const string secret = "compiler-secret-canary";
        var profile = CreateProfile(
            ProviderType.OpenAiCompatible,
            "https://api.example.com/v1",
            "remote-model");
        var credentials = new InMemoryCredentialStore(
            ("LocalAIGateway/profile/provider/api-key", secret));
        var compiler = new LiteLlmConfigurationCompiler(credentials);

        var first = await compiler.CompileAsync(profile, "internal-token-canary");
        var second = await compiler.CompileAsync(profile, "internal-token-canary");
        var text = Encoding.UTF8.GetString(first.ConfigurationUtf8.Span);

        Assert.Equal(first.ConfigurationUtf8.ToArray(), second.ConfigurationUtf8.ToArray());
        Assert.DoesNotContain(secret, text, StringComparison.Ordinal);
        Assert.DoesNotContain("internal-token-canary", text, StringComparison.Ordinal);
        Assert.DoesNotContain("LocalAIGateway/profile/provider/api-key", text, StringComparison.Ordinal);
        Assert.Equal(secret, first.Environment["AIGW_UPSTREAM_000_API_KEY"]);
        Assert.Equal("internal-token-canary", first.Environment["AIGW_LITELLM_MASTER_KEY"]);

        using var document = JsonDocument.Parse(first.ConfigurationUtf8);
        var root = document.RootElement;
        var model = Assert.Single(root.GetProperty("model_list").EnumerateArray());
        Assert.Equal("public-model", model.GetProperty("model_name").GetString());
        var parameters = model.GetProperty("litellm_params");
        Assert.Equal("openai/remote-model", parameters.GetProperty("model").GetString());
        Assert.Equal("https://api.example.com/v1", parameters.GetProperty("api_base").GetString());
        Assert.Equal("os.environ/AIGW_UPSTREAM_000_API_KEY", parameters.GetProperty("api_key").GetString());
        Assert.Equal(0, parameters.GetProperty("num_retries").GetInt32());

        var settings = root.GetProperty("litellm_settings");
        Assert.Equal(0, settings.GetProperty("num_retries").GetInt32());
        Assert.False(settings.GetProperty("telemetry").GetBoolean());
        Assert.Empty(settings.GetProperty("success_callback").EnumerateArray());
        Assert.Empty(settings.GetProperty("failure_callback").EnumerateArray());
        Assert.Equal(
            "aigw_usage_callback.usage_logger",
            Assert.Single(settings.GetProperty("callbacks").EnumerateArray()).GetString());
        Assert.True(settings.GetProperty("turn_off_message_logging").GetBoolean());
        Assert.True(settings.GetProperty("redact_user_api_key_info").GetBoolean());
        Assert.Equal(
            "os.environ/AIGW_LITELLM_MASTER_KEY",
            root.GetProperty("general_settings").GetProperty("master_key").GetString());

        Assert.False(first.CallbackModuleUtf8.IsEmpty);
        var callbackText = Encoding.UTF8.GetString(first.CallbackModuleUtf8.Span);
        Assert.DoesNotContain(secret, callbackText, StringComparison.Ordinal);
        Assert.DoesNotContain("response_cost", callbackText, StringComparison.Ordinal);
        Assert.DoesNotContain("proxy_server_request", callbackText, StringComparison.Ordinal);
        using var usageMetadata = JsonDocument.Parse(first.UsageMetadataUtf8);
        Assert.Equal(1, usageMetadata.RootElement.GetProperty("version").GetInt32());
        Assert.Equal("profile", usageMetadata.RootElement.GetProperty("profileId").GetString());
        Assert.Equal(
            "provider",
            usageMetadata.RootElement.GetProperty("models").GetProperty("public-model").GetString());
        Assert.DoesNotContain(secret, Encoding.UTF8.GetString(first.UsageMetadataUtf8.Span), StringComparison.Ordinal);
    }

    [Theory]
    [InlineData(ProviderType.OpenAiCompatible, "openai/remote-model", null)]
    [InlineData(ProviderType.Anthropic, "anthropic/remote-model", null)]
    [InlineData(ProviderType.LocalEndpoint, "openai/remote-model", null)]
    [InlineData(ProviderType.AzureOpenAi, "azure/remote-model", "v1")]
    public async Task CompileAsync_maps_each_supported_provider_to_fixed_litellm_parameters(
        ProviderType providerType,
        string expectedModel,
        string? expectedApiVersion)
    {
        var endpoint = providerType switch
        {
            ProviderType.LocalEndpoint => "http://127.0.0.1:11434/v1",
            ProviderType.AzureOpenAi => "https://example.openai.azure.com/openai/v1",
            _ => "https://api.example.com/v1",
        };
        var profile = CreateProfile(providerType, endpoint, "remote-model");
        var compiler = new LiteLlmConfigurationCompiler(new InMemoryCredentialStore(
            ("LocalAIGateway/profile/provider/api-key", "provider-secret")));

        var plan = await compiler.CompileAsync(profile, "internal-token");
        using var document = JsonDocument.Parse(plan.ConfigurationUtf8);
        var parameters = document.RootElement
            .GetProperty("model_list")[0]
            .GetProperty("litellm_params");

        Assert.Equal(expectedModel, parameters.GetProperty("model").GetString());
        Assert.Equal(
            providerType == ProviderType.AzureOpenAi
                ? "https://example.openai.azure.com"
                : endpoint,
            parameters.GetProperty("api_base").GetString());
        if (expectedApiVersion is null)
        {
            Assert.False(parameters.TryGetProperty("api_version", out _));
        }
        else
        {
            Assert.Equal(expectedApiVersion, parameters.GetProperty("api_version").GetString());
        }
    }

    [Fact]
    public async Task CompileAsync_normalizes_Azure_v1_resource_endpoint()
    {
        var profile = CreateProfile(
            ProviderType.AzureOpenAi,
            "https://example.openai.azure.com/openai/v1",
            "deployment-name");
        var compiler = new LiteLlmConfigurationCompiler(new InMemoryCredentialStore(
            ("LocalAIGateway/profile/provider/api-key", "provider-secret")));

        var plan = await compiler.CompileAsync(profile, "internal-token");
        using var document = JsonDocument.Parse(plan.ConfigurationUtf8);
        var parameters = document.RootElement
            .GetProperty("model_list")[0]
            .GetProperty("litellm_params");

        Assert.Equal("azure/deployment-name", parameters.GetProperty("model").GetString());
        Assert.Equal("https://example.openai.azure.com", parameters.GetProperty("api_base").GetString());
        Assert.Equal("v1", parameters.GetProperty("api_version").GetString());
    }

    [Fact]
    public async Task CompileAsync_rejects_missing_remote_credential_with_stable_error()
    {
        var profile = CreateProfile(
            ProviderType.OpenAiCompatible,
            "https://api.example.com/v1",
            "remote-model");
        var compiler = new LiteLlmConfigurationCompiler(new InMemoryCredentialStore());

        var exception = await Assert.ThrowsAsync<LiteLlmException>(
            () => compiler.CompileAsync(profile, "internal-token"));

        Assert.Equal("aigw_litellm_credential_missing", exception.ErrorCode);
    }

    [Fact]
    public async Task CompileAsync_allows_credential_free_local_endpoint_without_creating_secret_environment()
    {
        var profile = CreateProfile(
            ProviderType.LocalEndpoint,
            "http://127.0.0.1:11434/v1",
            "remote-model");
        var compiler = new LiteLlmConfigurationCompiler(new InMemoryCredentialStore());

        var plan = await compiler.CompileAsync(profile, "internal-token");
        using var document = JsonDocument.Parse(plan.ConfigurationUtf8);
        var parameters = document.RootElement
            .GetProperty("model_list")[0]
            .GetProperty("litellm_params");

        Assert.Equal("none", parameters.GetProperty("api_key").GetString());
        Assert.DoesNotContain(plan.Environment.Keys, key => key.StartsWith("AIGW_UPSTREAM_", StringComparison.Ordinal));
    }

    [Fact]
    public async Task CompileAsync_rejects_control_characters_in_credential_before_building_process_environment()
    {
        var profile = CreateProfile(
            ProviderType.OpenAiCompatible,
            "https://api.example.com/v1",
            "remote-model");
        var compiler = new LiteLlmConfigurationCompiler(new InMemoryCredentialStore(
            ("LocalAIGateway/profile/provider/api-key", "secret\r\ninjected=value")));

        var exception = await Assert.ThrowsAsync<LiteLlmException>(
            () => compiler.CompileAsync(profile, "internal-token"));

        Assert.Equal("aigw_litellm_credential_invalid", exception.ErrorCode);
    }

    [Fact]
    public async Task CompileAsync_preserves_credential_store_read_failure_category_and_error_code()
    {
        var profile = CreateProfile(
            ProviderType.OpenAiCompatible,
            "https://api.example.com/v1",
            "remote-model");
        var compiler = new LiteLlmConfigurationCompiler(new ThrowingCredentialStore());

        var exception = await Assert.ThrowsAsync<LiteLlmException>(
            () => compiler.CompileAsync(profile, "internal-token"));

        Assert.Equal("aigw_credential_read_failed", exception.ErrorCode);
        Assert.Equal(BackendFailureCategory.Credential, exception.Category);
        Assert.IsType<CredentialException>(exception.InnerException);
    }

    private static ProfileConfiguration CreateProfile(
        ProviderType type,
        string endpoint,
        string upstreamModel) => new()
    {
        Id = "profile",
        Name = "Profile",
        Providers =
        [
            new ProviderConfiguration
            {
                Id = "provider",
                Name = "Provider",
                Type = type,
                Endpoint = endpoint,
                CredentialTarget = "LocalAIGateway/profile/provider/api-key",
            },
        ],
        Models =
        [
            new ModelConfiguration
            {
                Alias = "public-model",
                ProviderId = "provider",
                UpstreamModel = upstreamModel,
                IsDefault = true,
            },
        ],
    };

    private sealed class InMemoryCredentialStore(params (string Target, string Secret)[] credentials)
        : ICredentialStore
    {
        private readonly IReadOnlyDictionary<string, string> secrets = credentials.ToDictionary(
            credential => credential.Target,
            credential => credential.Secret,
            StringComparer.Ordinal);

        public ValueTask<string?> GetSecretAsync(
            string target,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return ValueTask.FromResult(secrets.GetValueOrDefault(target));
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

    private sealed class ThrowingCredentialStore : ICredentialStore
    {
        public ValueTask<string?> GetSecretAsync(
            string target,
            CancellationToken cancellationToken = default) =>
            ValueTask.FromException<string?>(new CredentialException(
                "aigw_credential_read_failed",
                "Credential read failed."));

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
