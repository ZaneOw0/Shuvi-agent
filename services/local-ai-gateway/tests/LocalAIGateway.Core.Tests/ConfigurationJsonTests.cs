using System.Text;
using System.Text.Json;
using LocalAIGateway.Core.Configuration;

namespace LocalAIGateway.Core.Tests;

public sealed class ConfigurationJsonTests
{
    [Fact]
    public void RoundTripUsesStableProviderTypeValue()
    {
        var bytes = ConfigurationJson.Serialize(TestConfiguration.CreateComplete());
        var json = Encoding.UTF8.GetString(bytes);

        Assert.Contains("\"type\": \"openai-compatible\"", json);
        Assert.DoesNotContain("api-key-value", json);
        var roundTripped = ConfigurationJson.Deserialize(bytes);
        Assert.Equal("default", roundTripped.ActiveProfileId);
        Assert.Single(roundTripped.Profiles);
        Assert.Equal(ProviderType.OpenAiCompatible, roundTripped.Profiles[0].Providers[0].Type);
        Assert.Equal("aigw/default", roundTripped.Profiles[0].Models[0].Alias);
        Assert.Equal(ModelRoutingStrategy.OrderedFallback, roundTripped.Profiles[0].Models[0].RoutingStrategy);
        Assert.Equal(1, roundTripped.Profiles[0].Models[0].Weight);
        Assert.Null(roundTripped.Profiles[0].Limits);
        Assert.Null(roundTripped.Profiles[0].Providers[0].Limits);
        Assert.Null(roundTripped.Profiles[0].Models[0].Limits);
    }

    [Fact]
    public void DuplicatePropertyIsRejected()
    {
        const string json = """
            {
              "schemaVersion": 1,
              "schemaVersion": 1,
              "revision": 0,
              "activeProfileId": null,
              "profiles": []
            }
            """;

        Assert.Throws<JsonException>(() => ConfigurationJson.Deserialize(Encoding.UTF8.GetBytes(json)));
    }

    [Fact]
    public void UnknownPropertyIsRejected()
    {
        const string json = """
            {
              "schemaVersion": 1,
              "revision": 0,
              "activeProfileId": null,
              "profiles": [],
              "unexpected": true
            }
            """;

        Assert.Throws<JsonException>(() => ConfigurationJson.Deserialize(Encoding.UTF8.GetBytes(json)));
    }

    [Fact]
    public void LegacySingleTargetModelWithoutFallbacksRemainsCompatible()
    {
        const string json = """
            {
              "schemaVersion": 1,
              "revision": 1,
              "activeProfileId": "p",
              "profiles": [{
                "id": "p",
                "name": "P",
                "providers": [{
                  "id": "provider",
                  "name": "Provider",
                  "type": "local-endpoint",
                  "endpoint": "http://127.0.0.1:1234",
                  "credentialTarget": "LocalAIGateway/p/provider/api-key"
                }],
                "models": [{
                  "alias": "public-chat",
                  "providerId": "provider",
                  "upstreamModel": "private-chat",
                  "isDefault": true
                }]
              }]
            }
            """;

        var configuration = ConfigurationJson.Deserialize(Encoding.UTF8.GetBytes(json));

        Assert.Empty(configuration.Profiles[0].Models[0].Fallbacks);
        Assert.Equal(ModelRoutingStrategy.OrderedFallback, configuration.Profiles[0].Models[0].RoutingStrategy);
        Assert.Equal(1, configuration.Profiles[0].Models[0].Weight);
        Assert.True(ConfigurationValidator.Validate(configuration).IsValid);
    }

    [Fact]
    public void WeightedRoutingUsesStableContractValues()
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
                            RoutingStrategy = ModelRoutingStrategy.WeightedRoundRobin,
                            Weight = 2,
                            Fallbacks =
                            [
                                new ModelFallbackConfiguration
                                {
                                    ProviderId = "secondary",
                                    UpstreamModel = "fallback",
                                    Weight = 1,
                                },
                            ],
                        },
                    ],
                },
            ],
        };

        var json = Encoding.UTF8.GetString(ConfigurationJson.Serialize(configuration));
        var roundTripped = ConfigurationJson.Deserialize(Encoding.UTF8.GetBytes(json));
        var roundTrippedModel = roundTripped.Profiles[0].Models[0];

        Assert.Contains("\"routingStrategy\": \"weighted-round-robin\"", json, StringComparison.Ordinal);
        Assert.Contains("\"weight\": 2", json, StringComparison.Ordinal);
        Assert.Equal(ModelRoutingStrategy.WeightedRoundRobin, roundTrippedModel.RoutingStrategy);
        Assert.Equal(2, roundTrippedModel.Weight);
        Assert.Equal(1, Assert.Single(roundTrippedModel.Fallbacks).Weight);
    }

    [Fact]
    public void RequestLimitsRoundTripAtAllSupportedScopes()
    {
        var configuration = TestConfiguration.CreateComplete();
        var profile = configuration.Profiles[0];
        configuration = configuration with
        {
            Profiles =
            [
                profile with
                {
                    Limits = new RequestLimitConfiguration { MaxConcurrentRequests = 4 },
                    Providers =
                    [
                        profile.Providers[0] with
                        {
                            Limits = new RequestLimitConfiguration { RequestsPerMinute = 60 },
                        },
                    ],
                    Models =
                    [
                        profile.Models[0] with
                        {
                            Limits = new RequestLimitConfiguration { TokensPerMinute = 12_345 },
                        },
                    ],
                },
            ],
        };

        var json = Encoding.UTF8.GetString(ConfigurationJson.Serialize(configuration));
        var roundTripped = ConfigurationJson.Deserialize(Encoding.UTF8.GetBytes(json));

        Assert.Contains("\"maxConcurrentRequests\": 4", json, StringComparison.Ordinal);
        Assert.Equal(4, roundTripped.Profiles[0].Limits!.MaxConcurrentRequests);
        Assert.Equal(60, roundTripped.Profiles[0].Providers[0].Limits!.RequestsPerMinute);
        Assert.Equal(12_345, roundTripped.Profiles[0].Models[0].Limits!.TokensPerMinute);
        Assert.True(ConfigurationValidator.Validate(roundTripped).IsValid);
    }

    [Theory]
    [InlineData("profiles")]
    [InlineData("profileElement")]
    [InlineData("providers")]
    [InlineData("providerElement")]
    [InlineData("models")]
    [InlineData("modelElement")]
    [InlineData("fallbacks")]
    [InlineData("fallbackElement")]
    public void NullRequiredConfigurationMembersAreRejected(string scenario)
    {
        var json = scenario switch
        {
            "profiles" => """
                { "schemaVersion": 1, "revision": 0, "activeProfileId": null, "profiles": null }
                """,
            "profileElement" => """
                { "schemaVersion": 1, "revision": 0, "activeProfileId": null, "profiles": [null] }
                """,
            "providers" => """
                { "schemaVersion": 1, "revision": 0, "activeProfileId": null, "profiles": [{ "id": "p", "name": "P", "providers": null, "models": [] }] }
                """,
            "providerElement" => """
                { "schemaVersion": 1, "revision": 0, "activeProfileId": null, "profiles": [{ "id": "p", "name": "P", "providers": [null], "models": [] }] }
                """,
            "models" => """
                { "schemaVersion": 1, "revision": 0, "activeProfileId": null, "profiles": [{ "id": "p", "name": "P", "providers": [], "models": null }] }
                """,
            "modelElement" => """
                { "schemaVersion": 1, "revision": 0, "activeProfileId": null, "profiles": [{ "id": "p", "name": "P", "providers": [], "models": [null] }] }
                """,
            "fallbacks" => """
                { "schemaVersion": 1, "revision": 0, "activeProfileId": null, "profiles": [{ "id": "p", "name": "P", "providers": [], "models": [{ "alias": "a", "providerId": "p", "upstreamModel": "u", "isDefault": true, "fallbacks": null }] }] }
                """,
            "fallbackElement" => """
                { "schemaVersion": 1, "revision": 0, "activeProfileId": null, "profiles": [{ "id": "p", "name": "P", "providers": [], "models": [{ "alias": "a", "providerId": "p", "upstreamModel": "u", "isDefault": true, "fallbacks": [null] }] }] }
                """,
            _ => throw new ArgumentOutOfRangeException(nameof(scenario)),
        };

        Assert.Throws<JsonException>(() => ConfigurationJson.Deserialize(Encoding.UTF8.GetBytes(json)));
    }
}
