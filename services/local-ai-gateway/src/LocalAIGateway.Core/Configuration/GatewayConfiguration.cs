namespace LocalAIGateway.Core.Configuration;

public sealed record GatewayConfiguration
{
    public const int CurrentSchemaVersion = 1;

    public int SchemaVersion { get; init; } = CurrentSchemaVersion;

    public long Revision { get; init; }

    public string? ActiveProfileId { get; init; }

    public IReadOnlyList<ProfileConfiguration> Profiles { get; init; } = [];

    public static GatewayConfiguration Empty { get; } = new();
}

public sealed record ProfileConfiguration
{
    public required string Id { get; init; }

    public required string Name { get; init; }

    public RequestLimitConfiguration? Limits { get; init; }

    public IReadOnlyList<ProviderConfiguration> Providers { get; init; } = [];

    public IReadOnlyList<ModelConfiguration> Models { get; init; } = [];
}

public sealed record ProviderConfiguration
{
    public required string Id { get; init; }

    public required string Name { get; init; }

    public required ProviderType Type { get; init; }

    public required string Endpoint { get; init; }

    public required string CredentialTarget { get; init; }

    public RequestLimitConfiguration? Limits { get; init; }
}

public sealed record ModelConfiguration
{
    public required string Alias { get; init; }

    public required string ProviderId { get; init; }

    public required string UpstreamModel { get; init; }

    public bool IsDefault { get; init; }

    public ModelRoutingStrategy RoutingStrategy { get; init; } = ModelRoutingStrategy.OrderedFallback;

    public int Weight { get; init; } = 1;

    public RequestLimitConfiguration? Limits { get; init; }

    public IReadOnlyList<ModelFallbackConfiguration> Fallbacks { get; init; } = [];
}

public sealed record ModelFallbackConfiguration
{
    public required string ProviderId { get; init; }

    public required string UpstreamModel { get; init; }

    public int Weight { get; init; } = 1;
}

public sealed record RequestLimitConfiguration
{
    public int? MaxConcurrentRequests { get; init; }

    public int? RequestsPerMinute { get; init; }

    public long? TokensPerMinute { get; init; }
}
