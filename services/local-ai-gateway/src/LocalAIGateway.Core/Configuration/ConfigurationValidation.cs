using System.Net;
using System.Net.Sockets;
using System.Numerics;
using System.Text.RegularExpressions;

namespace LocalAIGateway.Core.Configuration;

public sealed record ConfigurationValidationError(string Code, string Path, string Message);

public sealed record ConfigurationValidationResult(IReadOnlyList<ConfigurationValidationError> Errors)
{
    public bool IsValid => Errors.Count == 0;
}

public static partial class ConfigurationValidator
{
    private const int MaximumFallbackTargets = 8;
    private const int MaximumTargetWeight = 100;
    private const int MaximumConcurrentRequests = 10_000;
    private const int MaximumRequestsPerMinute = 1_000_000;
    private const long MaximumTokensPerMinute = 1_000_000_000_000;
    private static readonly StringComparer IdComparer = StringComparer.OrdinalIgnoreCase;

    public static ConfigurationValidationResult Validate(GatewayConfiguration configuration)
    {
        ArgumentNullException.ThrowIfNull(configuration);

        var errors = new List<ConfigurationValidationError>();
        if (configuration.SchemaVersion != GatewayConfiguration.CurrentSchemaVersion)
        {
            errors.Add(new(
                configuration.SchemaVersion > GatewayConfiguration.CurrentSchemaVersion
                    ? "aigw_config_future_schema"
                    : "aigw_config_schema_unsupported",
                "$.schemaVersion",
                $"Schema version {configuration.SchemaVersion} is not supported."));
        }

        if (configuration.Revision < 0)
        {
            errors.Add(new("aigw_config_revision_invalid", "$.revision", "Revision must not be negative."));
        }

        ValidateProfiles(configuration, errors);
        return new ConfigurationValidationResult(errors);
    }

    public static bool IsActivatable(ProfileConfiguration profile) =>
        profile.Providers.Count > 0 &&
        profile.Models.Count > 0 &&
        profile.Models.Count(model => model.IsDefault) == 1;

    private static void ValidateProfiles(
        GatewayConfiguration configuration,
        List<ConfigurationValidationError> errors)
    {
        if (configuration.Profiles is null)
        {
            errors.Add(new("aigw_config_profiles_null", "$.profiles", "Profiles must be an array."));
            return;
        }

        var profileIds = new HashSet<string>(IdComparer);
        for (var profileIndex = 0; profileIndex < configuration.Profiles.Count; profileIndex++)
        {
            var profile = configuration.Profiles[profileIndex];
            var path = $"$.profiles[{profileIndex}]";
            if (profile is null)
            {
                errors.Add(new("aigw_config_profile_null", path, "Profile must be an object."));
                continue;
            }

            ValidateIdentifier(profile.Id, $"{path}.id", "profile", errors);
            if (!profileIds.Add(profile.Id))
            {
                errors.Add(new("aigw_config_duplicate_profile", $"{path}.id", "Profile IDs must be unique."));
            }

            ValidateDisplayName(profile.Name, $"{path}.name", errors);
            ValidateRequestLimits(profile.Limits, $"{path}.limits", errors);
            ValidateProviders(profile, path, errors);
            ValidateModels(profile, path, errors);
        }

        if (configuration.ActiveProfileId is null)
        {
            return;
        }

        var active = configuration.Profiles.FirstOrDefault(profile =>
            profile is not null && IdComparer.Equals(profile.Id, configuration.ActiveProfileId));
        if (active is null)
        {
            errors.Add(new(
                "aigw_config_active_profile_missing",
                "$.activeProfileId",
                "The active profile does not exist."));
        }
        else if (!IsActivatable(active))
        {
            errors.Add(new(
                "aigw_config_active_profile_incomplete",
                "$.activeProfileId",
                "The active profile must contain a provider and exactly one default model."));
        }
    }

    private static void ValidateProviders(
        ProfileConfiguration profile,
        string profilePath,
        List<ConfigurationValidationError> errors)
    {
        if (profile.Providers is null)
        {
            errors.Add(new("aigw_config_providers_null", $"{profilePath}.providers", "Providers must be an array."));
            return;
        }

        var providerIds = new HashSet<string>(IdComparer);
        for (var providerIndex = 0; providerIndex < profile.Providers.Count; providerIndex++)
        {
            var provider = profile.Providers[providerIndex];
            var path = $"{profilePath}.providers[{providerIndex}]";
            if (provider is null)
            {
                errors.Add(new("aigw_config_provider_null", path, "Provider must be an object."));
                continue;
            }

            ValidateIdentifier(provider.Id, $"{path}.id", "provider", errors);
            if (!providerIds.Add(provider.Id))
            {
                errors.Add(new("aigw_config_duplicate_provider", $"{path}.id", "Provider IDs must be unique within a profile."));
            }

            ValidateDisplayName(provider.Name, $"{path}.name", errors);
            ValidateEndpoint(provider, $"{path}.endpoint", errors);
            ValidateRequestLimits(provider.Limits, $"{path}.limits", errors);

            var expectedTarget = CredentialTargets.UpstreamApiKey(profile.Id, provider.Id);
            if (!string.Equals(provider.CredentialTarget, expectedTarget, StringComparison.Ordinal))
            {
                errors.Add(new(
                    "aigw_config_credential_target_invalid",
                    $"{path}.credentialTarget",
                    "Credential target does not match the profile and provider IDs."));
            }
        }
    }

    private static void ValidateModels(
        ProfileConfiguration profile,
        string profilePath,
        List<ConfigurationValidationError> errors)
    {
        if (profile.Models is null)
        {
            errors.Add(new("aigw_config_models_null", $"{profilePath}.models", "Models must be an array."));
            return;
        }

        var aliases = new HashSet<string>(IdComparer);
        var providerIds = (profile.Providers ?? [])
            .Where(provider => provider is not null)
            .Select(provider => provider.Id)
            .ToHashSet(IdComparer);
        var defaultCount = 0;

        for (var modelIndex = 0; modelIndex < profile.Models.Count; modelIndex++)
        {
            var model = profile.Models[modelIndex];
            var path = $"{profilePath}.models[{modelIndex}]";
            if (model is null)
            {
                errors.Add(new("aigw_config_model_null", path, "Model must be an object."));
                continue;
            }

            ValidateModelAlias(model.Alias, $"{path}.alias", errors);
            if (!aliases.Add(model.Alias))
            {
                errors.Add(new("aigw_config_duplicate_model_alias", $"{path}.alias", "Model aliases must be unique within a profile."));
            }

            if (!providerIds.Contains(model.ProviderId))
            {
                errors.Add(new(
                    "aigw_config_model_provider_missing",
                    $"{path}.providerId",
                    "The model references a provider that does not exist in its profile."));
            }

            if (string.IsNullOrWhiteSpace(model.UpstreamModel) || model.UpstreamModel.Length > 256)
            {
                errors.Add(new(
                    "aigw_config_upstream_model_invalid",
                    $"{path}.upstreamModel",
                    "Upstream model must contain 1 to 256 characters."));
            }

            if (!Enum.IsDefined(model.RoutingStrategy))
            {
                errors.Add(new(
                    "aigw_config_model_routing_strategy_invalid",
                    $"{path}.routingStrategy",
                    "Model routing strategy is not supported."));
            }

            ValidateTargetWeight(model.Weight, $"{path}.weight", errors);
            ValidateRequestLimits(model.Limits, $"{path}.limits", errors);

            ValidateFallbacks(model, path, providerIds, errors);

            if (model.IsDefault)
            {
                defaultCount++;
            }
        }

        if (profile.Models.Count > 0 && defaultCount != 1)
        {
            errors.Add(new(
                "aigw_config_default_model_invalid",
                $"{profilePath}.models",
                "A profile with models must have exactly one default model."));
        }
    }

    private static void ValidateFallbacks(
        ModelConfiguration model,
        string modelPath,
        IReadOnlySet<string> providerIds,
        List<ConfigurationValidationError> errors)
    {
        if (model.Fallbacks is null)
        {
            errors.Add(new(
                "aigw_config_model_fallbacks_null",
                $"{modelPath}.fallbacks",
                "Model fallbacks must be an array."));
            return;
        }

        if (model.Fallbacks.Count > MaximumFallbackTargets)
        {
            errors.Add(new(
                "aigw_config_model_fallbacks_too_many",
                $"{modelPath}.fallbacks",
                $"A model may define at most {MaximumFallbackTargets} fallback targets."));
        }

        if (model.RoutingStrategy == ModelRoutingStrategy.WeightedRoundRobin && model.Fallbacks.Count == 0)
        {
            errors.Add(new(
                "aigw_config_weighted_routing_requires_multiple_targets",
                $"{modelPath}.fallbacks",
                "Weighted round robin requires at least two targets."));
        }

        var targetProviders = new HashSet<string>(IdComparer) { model.ProviderId };
        for (var fallbackIndex = 0; fallbackIndex < model.Fallbacks.Count; fallbackIndex++)
        {
            var fallback = model.Fallbacks[fallbackIndex];
            var path = $"{modelPath}.fallbacks[{fallbackIndex}]";
            if (fallback is null)
            {
                errors.Add(new("aigw_config_model_fallback_null", path, "Model fallback must be an object."));
                continue;
            }

            if (!providerIds.Contains(fallback.ProviderId))
            {
                errors.Add(new(
                    "aigw_config_model_fallback_provider_missing",
                    $"{path}.providerId",
                    "The fallback references a provider that does not exist in its profile."));
            }

            if (!targetProviders.Add(fallback.ProviderId))
            {
                errors.Add(new(
                    "aigw_config_model_fallback_provider_duplicate",
                    $"{path}.providerId",
                    "Each ordered target for a public model must use a distinct provider."));
            }

            if (string.IsNullOrWhiteSpace(fallback.UpstreamModel) || fallback.UpstreamModel.Length > 256)
            {
                errors.Add(new(
                    "aigw_config_model_fallback_upstream_invalid",
                    $"{path}.upstreamModel",
                    "Fallback upstream model must contain 1 to 256 characters."));
            }

            ValidateTargetWeight(fallback.Weight, $"{path}.weight", errors);
        }
    }

    private static void ValidateTargetWeight(
        int weight,
        string path,
        List<ConfigurationValidationError> errors)
    {
        if (weight < 1 || weight > MaximumTargetWeight)
        {
            errors.Add(new(
                "aigw_config_model_target_weight_invalid",
                path,
                $"Model target weight must be between 1 and {MaximumTargetWeight}."));
        }
    }

    private static void ValidateRequestLimits(
        RequestLimitConfiguration? limits,
        string path,
        List<ConfigurationValidationError> errors)
    {
        if (limits is null)
        {
            return;
        }

        ValidateOptionalLimit(
            limits.MaxConcurrentRequests,
            MaximumConcurrentRequests,
            $"{path}.maxConcurrentRequests",
            "aigw_config_concurrency_limit_invalid",
            "Concurrent request limit",
            errors);
        ValidateOptionalLimit(
            limits.RequestsPerMinute,
            MaximumRequestsPerMinute,
            $"{path}.requestsPerMinute",
            "aigw_config_rpm_limit_invalid",
            "Requests-per-minute limit",
            errors);
        ValidateOptionalLimit(
            limits.TokensPerMinute,
            MaximumTokensPerMinute,
            $"{path}.tokensPerMinute",
            "aigw_config_tpm_limit_invalid",
            "Tokens-per-minute limit",
            errors);
    }

    private static void ValidateOptionalLimit<T>(
        T? value,
        T maximum,
        string path,
        string errorCode,
        string label,
        List<ConfigurationValidationError> errors)
        where T : struct, INumber<T>
    {
        if (value is T configured && (configured < T.One || configured > maximum))
        {
            errors.Add(new(
                errorCode,
                path,
                $"{label} must be between 1 and {maximum}."));
        }
    }

    private static void ValidateIdentifier(
        string value,
        string path,
        string kind,
        List<ConfigurationValidationError> errors)
    {
        if (string.IsNullOrWhiteSpace(value) || !IdentifierRegex().IsMatch(value))
        {
            errors.Add(new(
                $"aigw_config_{kind}_id_invalid",
                path,
                $"{char.ToUpperInvariant(kind[0])}{kind[1..]} ID must match {IdentifierRegex()}."));
        }
    }

    private static void ValidateModelAlias(
        string value,
        string path,
        List<ConfigurationValidationError> errors)
    {
        if (string.IsNullOrWhiteSpace(value) || !ModelAliasRegex().IsMatch(value))
        {
            errors.Add(new(
                "aigw_config_model_alias_invalid",
                path,
                "Model alias must contain only letters, digits, dots, underscores, hyphens, or slashes."));
        }
    }

    private static void ValidateDisplayName(
        string value,
        string path,
        List<ConfigurationValidationError> errors)
    {
        if (string.IsNullOrWhiteSpace(value) || value.Length > 128 || value.Any(char.IsControl))
        {
            errors.Add(new("aigw_config_name_invalid", path, "Name must contain 1 to 128 printable characters."));
        }
    }

    private static void ValidateEndpoint(
        ProviderConfiguration provider,
        string path,
        List<ConfigurationValidationError> errors)
    {
        if (!Uri.TryCreate(provider.Endpoint, UriKind.Absolute, out var uri) ||
            !string.IsNullOrEmpty(uri.UserInfo) ||
            !string.IsNullOrEmpty(uri.Query) ||
            !string.IsNullOrEmpty(uri.Fragment))
        {
            errors.Add(new("aigw_config_endpoint_invalid", path, "Endpoint must be an absolute URI without credentials, query, or fragment."));
            return;
        }

        if (provider.Type != ProviderType.LocalEndpoint)
        {
            if (!uri.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase))
            {
                errors.Add(new("aigw_config_endpoint_https_required", path, "Remote provider endpoints must use HTTPS."));
            }

            return;
        }

        if (!uri.Scheme.Equals(Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase) &&
            !uri.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase))
        {
            errors.Add(new("aigw_config_local_endpoint_scheme_invalid", path, "Local endpoints must use HTTP or HTTPS."));
            return;
        }

        if (!IsPrivateOrLoopbackHost(uri.Host))
        {
            errors.Add(new("aigw_config_local_endpoint_host_invalid", path, "Local endpoints must use localhost, loopback, or a private IP address."));
        }
    }

    private static bool IsPrivateOrLoopbackHost(string host)
    {
        if (host.Equals("localhost", StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        if (!IPAddress.TryParse(host, out var address))
        {
            return false;
        }

        if (IPAddress.IsLoopback(address))
        {
            return true;
        }

        var bytes = address.GetAddressBytes();
        if (address.AddressFamily == AddressFamily.InterNetwork)
        {
            return bytes[0] == 10 ||
                (bytes[0] == 172 && bytes[1] is >= 16 and <= 31) ||
                (bytes[0] == 192 && bytes[1] == 168) ||
                (bytes[0] == 169 && bytes[1] == 254);
        }

        return address.AddressFamily == AddressFamily.InterNetworkV6 &&
            ((bytes[0] & 0xfe) == 0xfc || (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80));
    }

    [GeneratedRegex("^[a-z0-9][a-z0-9._-]{0,63}$", RegexOptions.CultureInvariant)]
    private static partial Regex IdentifierRegex();

    [GeneratedRegex("^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$", RegexOptions.CultureInvariant)]
    private static partial Regex ModelAliasRegex();
}
