using LocalAIGateway.Core.Credentials;

namespace LocalAIGateway.Core.Configuration;

public sealed class GatewayConfigurationManager
{
    private static readonly StringComparer IdComparer = StringComparer.OrdinalIgnoreCase;
    private readonly ConfigurationStore store;
    private readonly ICredentialStore credentialStore;

    public GatewayConfigurationManager(ConfigurationStore store, ICredentialStore credentialStore)
    {
        this.store = store ?? throw new ArgumentNullException(nameof(store));
        this.credentialStore = credentialStore ?? throw new ArgumentNullException(nameof(credentialStore));
    }

    public ConfigurationPaths Paths => store.Paths;

    public Task<GatewayConfiguration> LoadAsync(CancellationToken cancellationToken = default) =>
        store.LoadAsync(cancellationToken);

    public async Task<GatewayConfiguration> CreateProfileAsync(
        string id,
        string name,
        CancellationToken cancellationToken = default)
    {
        var current = await store.LoadAsync(cancellationToken);
        EnsureMissing(current.Profiles, profile => profile.Id, id, "aigw_profile_exists", "Profile already exists.");
        var candidate = current with
        {
            Profiles =
            [
                .. current.Profiles,
                new ProfileConfiguration { Id = id, Name = name },
            ],
        };
        return await store.SaveAsync(candidate, current.Revision, cancellationToken);
    }

    public async Task<GatewayConfiguration> UseProfileAsync(
        string id,
        CancellationToken cancellationToken = default)
    {
        var current = await store.LoadAsync(cancellationToken);
        var profile = FindProfile(current, id);
        if (!ConfigurationValidator.IsActivatable(profile))
        {
            throw new ConfigurationException(
                "aigw_profile_incomplete",
                "Profile must contain a provider and exactly one default model before activation.");
        }

        return await store.SaveAsync(current with { ActiveProfileId = profile.Id }, current.Revision, cancellationToken);
    }

    public async Task<GatewayConfiguration> DeleteProfileAsync(
        string id,
        bool deleteSecrets,
        CancellationToken cancellationToken = default)
    {
        var current = await store.LoadAsync(cancellationToken);
        var profile = FindProfile(current, id);
        var candidate = current with
        {
            ActiveProfileId = IdComparer.Equals(current.ActiveProfileId, profile.Id)
                ? null
                : current.ActiveProfileId,
            Profiles = current.Profiles.Where(item => !IdComparer.Equals(item.Id, profile.Id)).ToArray(),
        };
        var saved = await store.SaveAsync(candidate, current.Revision, cancellationToken);

        if (deleteSecrets)
        {
            foreach (var provider in profile.Providers)
            {
                await credentialStore.DeleteSecretAsync(provider.CredentialTarget, cancellationToken);
            }
        }

        return saved;
    }

    public async Task<GatewayConfiguration> AddProviderAsync(
        string profileId,
        ProviderConfiguration provider,
        CancellationToken cancellationToken = default)
    {
        var current = await store.LoadAsync(cancellationToken);
        var profile = FindProfile(current, profileId);
        EnsureMissing(profile.Providers, item => item.Id, provider.Id, "aigw_provider_exists", "Provider already exists in the profile.");
        var canonicalProvider = provider with
        {
            CredentialTarget = CredentialTargets.UpstreamApiKey(profile.Id, provider.Id),
        };
        var updatedProfile = profile with { Providers = [.. profile.Providers, canonicalProvider] };
        return await SaveProfileAsync(current, updatedProfile, cancellationToken);
    }

    public async Task<GatewayConfiguration> UpdateProviderAsync(
        string profileId,
        string providerId,
        string? name,
        ProviderType? type,
        string? endpoint,
        CancellationToken cancellationToken = default)
    {
        if (name is null && type is null && endpoint is null)
        {
            throw new ConfigurationException("aigw_provider_update_empty", "Provider update did not specify any changes.");
        }

        var current = await store.LoadAsync(cancellationToken);
        var profile = FindProfile(current, profileId);
        var provider = FindProvider(profile, providerId);
        var updatedProvider = provider with
        {
            Name = name ?? provider.Name,
            Type = type ?? provider.Type,
            Endpoint = endpoint ?? provider.Endpoint,
        };
        var updatedProfile = profile with
        {
            Providers = profile.Providers.Select(item =>
                IdComparer.Equals(item.Id, provider.Id) ? updatedProvider : item).ToArray(),
        };
        return await SaveProfileAsync(current, updatedProfile, cancellationToken);
    }

    public async Task<GatewayConfiguration> RemoveProviderAsync(
        string profileId,
        string providerId,
        bool deleteSecret,
        CancellationToken cancellationToken = default)
    {
        var current = await store.LoadAsync(cancellationToken);
        var profile = FindProfile(current, profileId);
        var provider = FindProvider(profile, providerId);
        if (profile.Models.Any(model =>
                IdComparer.Equals(model.ProviderId, provider.Id) ||
                model.Fallbacks.Any(fallback => IdComparer.Equals(fallback.ProviderId, provider.Id))))
        {
            throw new ConfigurationException(
                "aigw_provider_in_use",
                "Provider cannot be removed while models reference it.");
        }

        var updatedProfile = profile with
        {
            Providers = profile.Providers.Where(item => !IdComparer.Equals(item.Id, provider.Id)).ToArray(),
        };
        var saved = await SaveProfileAsync(current, updatedProfile, cancellationToken);
        if (deleteSecret)
        {
            await credentialStore.DeleteSecretAsync(provider.CredentialTarget, cancellationToken);
        }

        return saved;
    }

    public async Task SetProviderSecretAsync(
        string profileId,
        string providerId,
        string secret,
        CancellationToken cancellationToken = default)
    {
        var configuration = await store.LoadAsync(cancellationToken);
        var provider = FindProvider(FindProfile(configuration, profileId), providerId);
        await credentialStore.SetSecretAsync(provider.CredentialTarget, secret, cancellationToken);
    }

    public async Task<GatewayConfiguration> AddModelAsync(
        string profileId,
        ModelConfiguration model,
        bool makeDefault,
        CancellationToken cancellationToken = default)
    {
        var current = await store.LoadAsync(cancellationToken);
        var profile = FindProfile(current, profileId);
        EnsureMissing(profile.Models, item => item.Alias, model.Alias, "aigw_model_exists", "Model alias already exists in the profile.");

        var shouldBeDefault = makeDefault || profile.Models.Count == 0;
        var models = profile.Models
            .Select(item => shouldBeDefault ? item with { IsDefault = false } : item)
            .Append(model with { IsDefault = shouldBeDefault })
            .ToArray();
        return await SaveProfileAsync(current, profile with { Models = models }, cancellationToken);
    }

    public async Task<GatewayConfiguration> UpdateModelAsync(
        string profileId,
        string alias,
        string? newAlias,
        string? providerId,
        string? upstreamModel,
        CancellationToken cancellationToken = default)
    {
        if (newAlias is null && providerId is null && upstreamModel is null)
        {
            throw new ConfigurationException("aigw_model_update_empty", "Model update did not specify any changes.");
        }

        var current = await store.LoadAsync(cancellationToken);
        var profile = FindProfile(current, profileId);
        var model = FindModel(profile, alias);
        if (newAlias is not null &&
            !IdComparer.Equals(newAlias, model.Alias) &&
            profile.Models.Any(item => IdComparer.Equals(item.Alias, newAlias)))
        {
            throw new ConfigurationException("aigw_model_exists", "New model alias already exists in the profile.");
        }

        var updatedModel = model with
        {
            Alias = newAlias ?? model.Alias,
            ProviderId = providerId ?? model.ProviderId,
            UpstreamModel = upstreamModel ?? model.UpstreamModel,
        };
        var updatedProfile = profile with
        {
            Models = profile.Models.Select(item =>
                IdComparer.Equals(item.Alias, model.Alias) ? updatedModel : item).ToArray(),
        };
        return await SaveProfileAsync(current, updatedProfile, cancellationToken);
    }

    public async Task<GatewayConfiguration> RemoveModelAsync(
        string profileId,
        string alias,
        CancellationToken cancellationToken = default)
    {
        var current = await store.LoadAsync(cancellationToken);
        var profile = FindProfile(current, profileId);
        var model = FindModel(profile, alias);
        if (model.IsDefault && profile.Models.Count > 1)
        {
            throw new ConfigurationException(
                "aigw_model_default_remove_blocked",
                "Set another default model before removing the current default.");
        }

        var updatedProfile = profile with
        {
            Models = profile.Models.Where(item => !IdComparer.Equals(item.Alias, model.Alias)).ToArray(),
        };
        var candidate = current with
        {
            ActiveProfileId = IdComparer.Equals(current.ActiveProfileId, profile.Id) &&
                !ConfigurationValidator.IsActivatable(updatedProfile)
                ? null
                : current.ActiveProfileId,
        };
        return await SaveProfileAsync(candidate, updatedProfile, cancellationToken);
    }

    public async Task<GatewayConfiguration> AddModelFallbackAsync(
        string profileId,
        string alias,
        ModelFallbackConfiguration fallback,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(fallback);
        var current = await store.LoadAsync(cancellationToken);
        var profile = FindProfile(current, profileId);
        var model = FindModel(profile, alias);
        var updatedModel = model with { Fallbacks = [.. model.Fallbacks, fallback] };
        var updatedProfile = profile with
        {
            Models = profile.Models.Select(item =>
                IdComparer.Equals(item.Alias, model.Alias) ? updatedModel : item).ToArray(),
        };
        return await SaveProfileAsync(current, updatedProfile, cancellationToken);
    }

    public async Task<GatewayConfiguration> RemoveModelFallbackAsync(
        string profileId,
        string alias,
        string providerId,
        CancellationToken cancellationToken = default)
    {
        var current = await store.LoadAsync(cancellationToken);
        var profile = FindProfile(current, profileId);
        var model = FindModel(profile, alias);
        if (!model.Fallbacks.Any(fallback => IdComparer.Equals(fallback.ProviderId, providerId)))
        {
            throw new ConfigurationException(
                "aigw_model_fallback_not_found",
                "The ordered fallback target was not found.");
        }

        var updatedModel = model with
        {
            Fallbacks = model.Fallbacks
                .Where(fallback => !IdComparer.Equals(fallback.ProviderId, providerId))
                .ToArray(),
        };
        var updatedProfile = profile with
        {
            Models = profile.Models.Select(item =>
                IdComparer.Equals(item.Alias, model.Alias) ? updatedModel : item).ToArray(),
        };
        return await SaveProfileAsync(current, updatedProfile, cancellationToken);
    }

    public async Task<GatewayConfiguration> SetModelRoutingStrategyAsync(
        string profileId,
        string alias,
        ModelRoutingStrategy strategy,
        CancellationToken cancellationToken = default)
    {
        var current = await store.LoadAsync(cancellationToken);
        var profile = FindProfile(current, profileId);
        var model = FindModel(profile, alias);
        var updatedProfile = profile with
        {
            Models = profile.Models.Select(item =>
                IdComparer.Equals(item.Alias, model.Alias)
                    ? model with { RoutingStrategy = strategy }
                    : item).ToArray(),
        };
        return await SaveProfileAsync(current, updatedProfile, cancellationToken);
    }

    public async Task<GatewayConfiguration> SetModelTargetWeightAsync(
        string profileId,
        string alias,
        string providerId,
        int weight,
        CancellationToken cancellationToken = default)
    {
        var current = await store.LoadAsync(cancellationToken);
        var profile = FindProfile(current, profileId);
        var model = FindModel(profile, alias);
        ModelConfiguration updatedModel;
        if (IdComparer.Equals(model.ProviderId, providerId))
        {
            updatedModel = model with { Weight = weight };
        }
        else if (model.Fallbacks.Any(fallback => IdComparer.Equals(fallback.ProviderId, providerId)))
        {
            updatedModel = model with
            {
                Fallbacks = model.Fallbacks.Select(fallback =>
                    IdComparer.Equals(fallback.ProviderId, providerId)
                        ? fallback with { Weight = weight }
                        : fallback).ToArray(),
            };
        }
        else
        {
            throw new ConfigurationException(
                "aigw_model_target_not_found",
                "The model target provider was not found.");
        }

        var updatedProfile = profile with
        {
            Models = profile.Models.Select(item =>
                IdComparer.Equals(item.Alias, model.Alias) ? updatedModel : item).ToArray(),
        };
        return await SaveProfileAsync(current, updatedProfile, cancellationToken);
    }

    public async Task<GatewayConfiguration> SetDefaultModelAsync(
        string profileId,
        string alias,
        CancellationToken cancellationToken = default)
    {
        var current = await store.LoadAsync(cancellationToken);
        var profile = FindProfile(current, profileId);
        var model = FindModel(profile, alias);
        var updatedProfile = profile with
        {
            Models = profile.Models.Select(item =>
                item with { IsDefault = IdComparer.Equals(item.Alias, model.Alias) }).ToArray(),
        };
        return await SaveProfileAsync(current, updatedProfile, cancellationToken);
    }

    public async Task<GatewayConfiguration> SetProfileLimitsAsync(
        string profileId,
        RequestLimitConfiguration? limits,
        CancellationToken cancellationToken = default)
    {
        var current = await store.LoadAsync(cancellationToken);
        var profile = FindProfile(current, profileId);
        return await SaveProfileAsync(current, profile with { Limits = limits }, cancellationToken);
    }

    public async Task<GatewayConfiguration> SetProviderLimitsAsync(
        string profileId,
        string providerId,
        RequestLimitConfiguration? limits,
        CancellationToken cancellationToken = default)
    {
        var current = await store.LoadAsync(cancellationToken);
        var profile = FindProfile(current, profileId);
        var provider = FindProvider(profile, providerId);
        var updatedProfile = profile with
        {
            Providers = profile.Providers.Select(item =>
                IdComparer.Equals(item.Id, provider.Id) ? provider with { Limits = limits } : item).ToArray(),
        };
        return await SaveProfileAsync(current, updatedProfile, cancellationToken);
    }

    public async Task<GatewayConfiguration> SetModelLimitsAsync(
        string profileId,
        string alias,
        RequestLimitConfiguration? limits,
        CancellationToken cancellationToken = default)
    {
        var current = await store.LoadAsync(cancellationToken);
        var profile = FindProfile(current, profileId);
        var model = FindModel(profile, alias);
        var updatedProfile = profile with
        {
            Models = profile.Models.Select(item =>
                IdComparer.Equals(item.Alias, model.Alias) ? model with { Limits = limits } : item).ToArray(),
        };
        return await SaveProfileAsync(current, updatedProfile, cancellationToken);
    }

    public static ProfileConfiguration FindProfile(GatewayConfiguration configuration, string profileId) =>
        configuration.Profiles.FirstOrDefault(profile =>
            profile is not null && IdComparer.Equals(profile.Id, profileId))
        ?? throw new ConfigurationException("aigw_profile_not_found", "Profile was not found.");

    public static ProviderConfiguration FindProvider(ProfileConfiguration profile, string providerId) =>
        profile.Providers.FirstOrDefault(provider => IdComparer.Equals(provider.Id, providerId))
        ?? throw new ConfigurationException("aigw_provider_not_found", "Provider was not found in the profile.");

    public static ModelConfiguration FindModel(ProfileConfiguration profile, string alias) =>
        profile.Models.FirstOrDefault(model => IdComparer.Equals(model.Alias, alias))
        ?? throw new ConfigurationException("aigw_model_not_found", "Model alias was not found in the profile.");

    private async Task<GatewayConfiguration> SaveProfileAsync(
        GatewayConfiguration current,
        ProfileConfiguration updatedProfile,
        CancellationToken cancellationToken)
    {
        var candidate = current with
        {
            Profiles = current.Profiles.Select(profile =>
                IdComparer.Equals(profile.Id, updatedProfile.Id) ? updatedProfile : profile).ToArray(),
        };
        return await store.SaveAsync(candidate, current.Revision, cancellationToken);
    }

    private static void EnsureMissing<T>(
        IEnumerable<T> items,
        Func<T, string> idSelector,
        string id,
        string errorCode,
        string message)
    {
        if (items.Any(item => IdComparer.Equals(idSelector(item), id)))
        {
            throw new ConfigurationException(errorCode, message);
        }
    }
}
