using LocalAIGateway.Core.Configuration;

namespace LocalAIGateway.Core.Tests;

public sealed class ConfigurationValidatorTests
{
    [Fact]
    public void ValidCompleteConfigurationPasses()
    {
        var configuration = TestConfiguration.CreateComplete();

        var result = ConfigurationValidator.Validate(configuration);

        Assert.True(result.IsValid);
        Assert.Empty(result.Errors);
    }

    [Fact]
    public void RemoteProviderRequiresHttps()
    {
        var configuration = TestConfiguration.CreateComplete(providerEndpoint: "http://api.example.com/v1");

        var result = ConfigurationValidator.Validate(configuration);

        Assert.Contains(result.Errors, error => error.Code == "aigw_config_endpoint_https_required");
    }

    [Theory]
    [InlineData("http://127.0.0.1:11434/v1")]
    [InlineData("http://localhost:11434/v1")]
    [InlineData("http://10.10.0.5:8080/v1")]
    [InlineData("http://192.168.1.9:8080/v1")]
    [InlineData("http://[::1]:8080/v1")]
    public void LocalProviderAllowsPrivateHttp(string endpoint)
    {
        var configuration = TestConfiguration.CreateComplete(
            providerType: ProviderType.LocalEndpoint,
            providerEndpoint: endpoint);

        Assert.True(ConfigurationValidator.Validate(configuration).IsValid);
    }

    [Fact]
    public void LocalProviderRejectsPublicHttp()
    {
        var configuration = TestConfiguration.CreateComplete(
            providerType: ProviderType.LocalEndpoint,
            providerEndpoint: "http://example.com/v1");

        var result = ConfigurationValidator.Validate(configuration);

        Assert.Contains(result.Errors, error => error.Code == "aigw_config_local_endpoint_host_invalid");
    }

    [Fact]
    public void DanglingModelProviderFails()
    {
        var configuration = TestConfiguration.CreateComplete();
        configuration = configuration with
        {
            Profiles =
            [
                configuration.Profiles[0] with
                {
                    Models = [configuration.Profiles[0].Models[0] with { ProviderId = "missing" }],
                },
            ],
        };

        var result = ConfigurationValidator.Validate(configuration);

        Assert.Contains(result.Errors, error => error.Code == "aigw_config_model_provider_missing");
    }

    [Fact]
    public void OrderedFallbackTargetsMustReferenceDistinctExistingProviders()
    {
        var configuration = TestConfiguration.CreateComplete();
        var profile = configuration.Profiles[0];
        configuration = configuration with
        {
            Profiles =
            [
                profile with
                {
                    Models =
                    [
                        profile.Models[0] with
                        {
                            Fallbacks =
                            [
                                new ModelFallbackConfiguration
                                {
                                    ProviderId = profile.Models[0].ProviderId,
                                    UpstreamModel = "duplicate-provider",
                                },
                                new ModelFallbackConfiguration
                                {
                                    ProviderId = "missing",
                                    UpstreamModel = "missing-provider",
                                },
                            ],
                        },
                    ],
                },
            ],
        };

        var errors = ConfigurationValidator.Validate(configuration).Errors;

        Assert.Contains(errors, error => error.Code == "aigw_config_model_fallback_provider_duplicate");
        Assert.Contains(errors, error => error.Code == "aigw_config_model_fallback_provider_missing");
    }

    [Fact]
    public void ValidOrderedFallbackConfigurationPasses()
    {
        var configuration = TestConfiguration.CreateComplete();
        var profile = configuration.Profiles[0];
        var fallbackProvider = profile.Providers[0] with
        {
            Id = "secondary",
            Name = "Secondary",
            CredentialTarget = CredentialTargets.UpstreamApiKey(profile.Id, "secondary"),
        };
        configuration = configuration with
        {
            Profiles =
            [
                profile with
                {
                    Providers = [.. profile.Providers, fallbackProvider],
                    Models =
                    [
                        profile.Models[0] with
                        {
                            Fallbacks =
                            [
                                new ModelFallbackConfiguration
                                {
                                    ProviderId = fallbackProvider.Id,
                                    UpstreamModel = "fallback-model",
                                },
                            ],
                        },
                    ],
                },
            ],
        };

        Assert.True(ConfigurationValidator.Validate(configuration).IsValid);
    }

    [Fact]
    public void WeightedRoundRobinRequiresMultipleTargetsAndBoundedWeights()
    {
        var configuration = TestConfiguration.CreateComplete();
        var profile = configuration.Profiles[0];
        var singleTarget = configuration with
        {
            Profiles =
            [
                profile with
                {
                    Models =
                    [
                        profile.Models[0] with
                        {
                            RoutingStrategy = ModelRoutingStrategy.WeightedRoundRobin,
                            Weight = 0,
                        },
                    ],
                },
            ],
        };

        var errors = ConfigurationValidator.Validate(singleTarget).Errors;

        Assert.Contains(errors, error => error.Code == "aigw_config_weighted_routing_requires_multiple_targets");
        Assert.Contains(errors, error => error.Code == "aigw_config_model_target_weight_invalid");
    }

    [Fact]
    public void RequestLimitsMustBePositiveAndBoundedAtEveryScope()
    {
        var configuration = TestConfiguration.CreateComplete();
        var profile = configuration.Profiles[0];
        configuration = configuration with
        {
            Profiles =
            [
                profile with
                {
                    Limits = new RequestLimitConfiguration { MaxConcurrentRequests = 0 },
                    Providers =
                    [
                        profile.Providers[0] with
                        {
                            Limits = new RequestLimitConfiguration { RequestsPerMinute = 1_000_001 },
                        },
                    ],
                    Models =
                    [
                        profile.Models[0] with
                        {
                            Limits = new RequestLimitConfiguration { TokensPerMinute = -1 },
                        },
                    ],
                },
            ],
        };

        var errors = ConfigurationValidator.Validate(configuration).Errors;

        Assert.Contains(errors, error => error.Code == "aigw_config_concurrency_limit_invalid");
        Assert.Contains(errors, error => error.Code == "aigw_config_rpm_limit_invalid");
        Assert.Contains(errors, error => error.Code == "aigw_config_tpm_limit_invalid");
    }

    [Fact]
    public void MultipleDefaultModelsFail()
    {
        var configuration = TestConfiguration.CreateComplete();
        var profile = configuration.Profiles[0];
        configuration = configuration with
        {
            Profiles =
            [
                profile with
                {
                    Models =
                    [
                        profile.Models[0],
                        profile.Models[0] with { Alias = "second", IsDefault = true },
                    ],
                },
            ],
        };

        var result = ConfigurationValidator.Validate(configuration);

        Assert.Contains(result.Errors, error => error.Code == "aigw_config_default_model_invalid");
    }

    [Fact]
    public void EmptyDraftProfileIsValidButCannotBeActivated()
    {
        var profile = new ProfileConfiguration { Id = "draft", Name = "Draft" };
        var configuration = GatewayConfiguration.Empty with { Profiles = [profile] };

        Assert.True(ConfigurationValidator.Validate(configuration).IsValid);
        Assert.False(ConfigurationValidator.IsActivatable(profile));

        var activeResult = ConfigurationValidator.Validate(configuration with { ActiveProfileId = "draft" });
        Assert.Contains(activeResult.Errors, error => error.Code == "aigw_config_active_profile_incomplete");
    }

    [Fact]
    public void CredentialTargetMustMatchProfileAndProvider()
    {
        var configuration = TestConfiguration.CreateComplete();
        var profile = configuration.Profiles[0];
        configuration = configuration with
        {
            Profiles =
            [
                profile with
                {
                    Providers = [profile.Providers[0] with { CredentialTarget = "wrong" }],
                },
            ],
        };

        var result = ConfigurationValidator.Validate(configuration);

        Assert.Contains(result.Errors, error => error.Code == "aigw_config_credential_target_invalid");
    }

    [Fact]
    public void NullCollectionsAndElementsProduceValidationErrorsInsteadOfExceptions()
    {
        var nullProfiles = GatewayConfiguration.Empty with { Profiles = null! };
        var nullProfileElement = GatewayConfiguration.Empty with { Profiles = [null!] };
        var activeNullProfileElement = GatewayConfiguration.Empty with
        {
            ActiveProfileId = "missing",
            Profiles = [null!],
        };
        var nullNestedCollections = GatewayConfiguration.Empty with
        {
            Profiles =
            [
                new ProfileConfiguration
                {
                    Id = "draft",
                    Name = "Draft",
                    Providers = null!,
                    Models = null!,
                },
            ],
        };

        Assert.Contains(
            ConfigurationValidator.Validate(nullProfiles).Errors,
            error => error.Code == "aigw_config_profiles_null");
        Assert.Contains(
            ConfigurationValidator.Validate(nullProfileElement).Errors,
            error => error.Code == "aigw_config_profile_null");
        var activeNullErrors = ConfigurationValidator.Validate(activeNullProfileElement).Errors;
        Assert.Contains(activeNullErrors, error => error.Code == "aigw_config_profile_null");
        Assert.Contains(activeNullErrors, error => error.Code == "aigw_config_active_profile_missing");
        var nestedErrors = ConfigurationValidator.Validate(nullNestedCollections).Errors;
        Assert.Contains(nestedErrors, error => error.Code == "aigw_config_providers_null");
        Assert.Contains(nestedErrors, error => error.Code == "aigw_config_models_null");
    }
}

internal static class TestConfiguration
{
    public static GatewayConfiguration CreateComplete(
        ProviderType providerType = ProviderType.OpenAiCompatible,
        string providerEndpoint = "https://api.example.com/v1")
    {
        var profileId = "default";
        var providerId = "primary";
        return new GatewayConfiguration
        {
            ActiveProfileId = profileId,
            Profiles =
            [
                new ProfileConfiguration
                {
                    Id = profileId,
                    Name = "Default",
                    Providers =
                    [
                        new ProviderConfiguration
                        {
                            Id = providerId,
                            Name = "Primary",
                            Type = providerType,
                            Endpoint = providerEndpoint,
                            CredentialTarget = CredentialTargets.UpstreamApiKey(profileId, providerId),
                        },
                    ],
                    Models =
                    [
                        new ModelConfiguration
                        {
                            Alias = "aigw/default",
                            ProviderId = providerId,
                            UpstreamModel = "upstream-model",
                            IsDefault = true,
                        },
                    ],
                },
            ],
        };
    }
}
