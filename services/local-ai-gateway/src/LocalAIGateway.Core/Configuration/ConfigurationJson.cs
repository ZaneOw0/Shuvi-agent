using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace LocalAIGateway.Core.Configuration;

public static class ConfigurationJson
{
    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        AllowTrailingCommas = false,
        DefaultIgnoreCondition = JsonIgnoreCondition.Never,
        MaxDepth = 64,
        PropertyNameCaseInsensitive = false,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        ReadCommentHandling = JsonCommentHandling.Disallow,
        RespectNullableAnnotations = true,
        RespectRequiredConstructorParameters = true,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
        WriteIndented = true,
    };

    public static byte[] Serialize(GatewayConfiguration configuration) =>
        JsonSerializer.SerializeToUtf8Bytes(configuration, SerializerOptions);

    public static GatewayConfiguration Deserialize(ReadOnlySpan<byte> utf8Json)
    {
        if (utf8Json.Length >= 3 &&
            utf8Json[0] == 0xef &&
            utf8Json[1] == 0xbb &&
            utf8Json[2] == 0xbf)
        {
            utf8Json = utf8Json[3..];
        }

        RejectDuplicateProperties(utf8Json);
        var configuration = JsonSerializer.Deserialize<GatewayConfiguration>(utf8Json, SerializerOptions)
            ?? throw new JsonException("Configuration JSON must contain an object.");
        RejectNullCollectionElements(configuration);
        return configuration;
    }

    private static void RejectNullCollectionElements(GatewayConfiguration configuration)
    {
        for (var profileIndex = 0; profileIndex < configuration.Profiles.Count; profileIndex++)
        {
            var profile = configuration.Profiles[profileIndex];
            if (profile is null)
            {
                throw new JsonException($"Configuration profile at index {profileIndex} must not be null.");
            }

            for (var providerIndex = 0; providerIndex < profile.Providers.Count; providerIndex++)
            {
                if (profile.Providers[providerIndex] is null)
                {
                    throw new JsonException(
                        $"Configuration provider at profile {profileIndex}, index {providerIndex} must not be null.");
                }
            }

            for (var modelIndex = 0; modelIndex < profile.Models.Count; modelIndex++)
            {
                var model = profile.Models[modelIndex];
                if (model is null)
                {
                    throw new JsonException(
                        $"Configuration model at profile {profileIndex}, index {modelIndex} must not be null.");
                }

                if (model.Fallbacks is null)
                {
                    throw new JsonException(
                        $"Configuration fallbacks at profile {profileIndex}, model {modelIndex} must not be null.");
                }

                for (var fallbackIndex = 0; fallbackIndex < model.Fallbacks.Count; fallbackIndex++)
                {
                    if (model.Fallbacks[fallbackIndex] is null)
                    {
                        throw new JsonException(
                            $"Configuration fallback at profile {profileIndex}, model {modelIndex}, index {fallbackIndex} must not be null.");
                    }
                }
            }
        }
    }

    private static void RejectDuplicateProperties(ReadOnlySpan<byte> utf8Json)
    {
        var reader = new Utf8JsonReader(
            utf8Json,
            new JsonReaderOptions
            {
                AllowTrailingCommas = false,
                CommentHandling = JsonCommentHandling.Disallow,
                MaxDepth = 64,
            });
        var propertySets = new Stack<HashSet<string>>();

        while (reader.Read())
        {
            switch (reader.TokenType)
            {
                case JsonTokenType.StartObject:
                    propertySets.Push(new HashSet<string>(StringComparer.Ordinal));
                    break;
                case JsonTokenType.EndObject:
                    propertySets.Pop();
                    break;
                case JsonTokenType.PropertyName:
                    var propertyName = reader.GetString() ?? string.Empty;
                    if (propertySets.Count == 0 || !propertySets.Peek().Add(propertyName))
                    {
                        throw new JsonException($"Duplicate JSON property '{propertyName}'.");
                    }
                    break;
            }
        }
    }
}
