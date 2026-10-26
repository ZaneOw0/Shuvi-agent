using System.Text;
using System.Text.Json;
using LocalAIGateway.Core.Backend;
using LocalAIGateway.Core.Configuration;
using LocalAIGateway.Core.Credentials;

namespace LocalAIGateway.LiteLlm;

public sealed class LiteLlmConfigurationCompiler(ICredentialStore credentialStore)
{
    private static readonly StringComparer IdComparer = StringComparer.OrdinalIgnoreCase;
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
    };

    public async Task<LiteLlmConfigurationPlan> CompileAsync(
        ProfileConfiguration profile,
        string internalToken,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(profile);
        ValidateInternalToken(internalToken);
        ValidateProfile(profile);

        var environment = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["AIGW_LITELLM_MASTER_KEY"] = internalToken,
        };
        var providerIndexes = profile.Providers
            .Select((provider, index) => (provider.Id, index))
            .ToDictionary(item => item.Id, item => item.index, IdComparer);
        var credentialReferences = new Dictionary<string, string>(IdComparer);
        var models = new List<object>(profile.Models.Count);

        foreach (var model in profile.Models)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var provider = profile.Providers.Single(candidate =>
                IdComparer.Equals(candidate.Id, model.ProviderId));
            var apiKey = await ResolveApiKeyAsync(
                provider,
                providerIndexes[provider.Id],
                credentialReferences,
                environment,
                cancellationToken);
            var parameters = new Dictionary<string, object?>(StringComparer.Ordinal)
            {
                ["model"] = $"{ProviderPrefix(provider.Type)}/{model.UpstreamModel}",
                ["api_base"] = NormalizeApiBase(provider),
                ["api_key"] = apiKey,
                ["num_retries"] = 0,
            };
            if (provider.Type == ProviderType.AzureOpenAi)
            {
                parameters["api_version"] = "v1";
            }
            models.Add(new Dictionary<string, object?>(StringComparer.Ordinal)
            {
                ["model_name"] = model.Alias,
                ["litellm_params"] = parameters,
            });
        }

        var configuration = new Dictionary<string, object?>(StringComparer.Ordinal)
        {
            ["model_list"] = models,
            ["litellm_settings"] = new Dictionary<string, object?>(StringComparer.Ordinal)
            {
                ["num_retries"] = 0,
                ["telemetry"] = false,
                ["success_callback"] = Array.Empty<string>(),
                ["failure_callback"] = Array.Empty<string>(),
                ["callbacks"] = new[] { LiteLlmUsageCallbackAssets.CallbackReference },
                ["turn_off_message_logging"] = true,
                ["redact_user_api_key_info"] = true,
            },
            ["general_settings"] = new Dictionary<string, object?>(StringComparer.Ordinal)
            {
                ["master_key"] = "os.environ/AIGW_LITELLM_MASTER_KEY",
            },
        };
        var usageMetadata = new Dictionary<string, object?>(StringComparer.Ordinal)
        {
            ["version"] = 1,
            ["profileId"] = profile.Id,
            ["models"] = profile.Models.ToDictionary(
                model => model.Alias,
                model => model.ProviderId,
                StringComparer.Ordinal),
        };
        return new LiteLlmConfigurationPlan(
            JsonSerializer.SerializeToUtf8Bytes(configuration, JsonOptions),
            environment,
            LiteLlmUsageCallbackAssets.ModuleUtf8,
            JsonSerializer.SerializeToUtf8Bytes(usageMetadata, JsonOptions));
    }

    private async Task<string> ResolveApiKeyAsync(
        ProviderConfiguration provider,
        int providerIndex,
        IDictionary<string, string> credentialReferences,
        IDictionary<string, string> environment,
        CancellationToken cancellationToken)
    {
        if (credentialReferences.TryGetValue(provider.Id, out var existingReference))
        {
            return existingReference;
        }

        string? secret;
        try
        {
            secret = await credentialStore.GetSecretAsync(provider.CredentialTarget, cancellationToken);
        }
        catch (CredentialException exception)
        {
            throw new LiteLlmException(
                exception.ErrorCode,
                exception.Message,
                BackendFailureCategory.Credential,
                exception);
        }
        if (string.IsNullOrEmpty(secret))
        {
            if (provider.Type == ProviderType.LocalEndpoint)
            {
                credentialReferences[provider.Id] = "none";
                return "none";
            }

            throw new LiteLlmException(
                "aigw_litellm_credential_missing",
                $"Provider '{provider.Id}' does not have an upstream credential.",
                BackendFailureCategory.Credential);
        }

        if (string.IsNullOrWhiteSpace(secret) ||
            secret.Any(char.IsControl) ||
            Encoding.UTF8.GetByteCount(secret) > 2560)
        {
            throw new LiteLlmException(
                "aigw_litellm_credential_invalid",
                $"Provider '{provider.Id}' has a malformed upstream credential.",
                BackendFailureCategory.Credential);
        }

        var variableName = $"AIGW_UPSTREAM_{providerIndex:D3}_API_KEY";
        environment[variableName] = secret;
        var reference = $"os.environ/{variableName}";
        credentialReferences[provider.Id] = reference;
        return reference;
    }

    private static string ProviderPrefix(ProviderType providerType) => providerType switch
    {
        ProviderType.OpenAiCompatible => "openai",
        ProviderType.Anthropic => "anthropic",
        ProviderType.AzureOpenAi => "azure",
        ProviderType.LocalEndpoint => "openai",
        _ => throw new LiteLlmException(
            "aigw_litellm_provider_unsupported",
            "Provider type is not supported by the LiteLLM compiler.",
            BackendFailureCategory.Configuration),
    };

    private static string NormalizeApiBase(ProviderConfiguration provider)
    {
        if (provider.Type != ProviderType.AzureOpenAi)
        {
            return provider.Endpoint;
        }

        const string v1Suffix = "/openai/v1";
        var endpoint = provider.Endpoint.TrimEnd('/');
        return endpoint.EndsWith(v1Suffix, StringComparison.OrdinalIgnoreCase)
            ? endpoint[..^v1Suffix.Length]
            : endpoint;
    }

    private static void ValidateProfile(ProfileConfiguration profile)
    {
        var configuration = new GatewayConfiguration
        {
            ActiveProfileId = profile.Id,
            Profiles = [profile],
        };
        var validation = ConfigurationValidator.Validate(configuration);
        if (!validation.IsValid)
        {
            throw new LiteLlmException(
                "aigw_litellm_profile_invalid",
                "The active profile cannot be compiled for LiteLLM.",
                BackendFailureCategory.Configuration);
        }
    }

    private static void ValidateInternalToken(string internalToken)
    {
        if (string.IsNullOrWhiteSpace(internalToken) ||
            internalToken.Length > 1024 ||
            internalToken.Any(char.IsControl))
        {
            throw new LiteLlmException(
                "aigw_litellm_internal_token_invalid",
                "The LiteLLM internal token is missing or malformed.");
        }
    }
}
