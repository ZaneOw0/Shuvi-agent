using System.Text.Json;
using System.Text.Json.Serialization;

namespace LocalAIGateway.Core.Configuration;

[JsonConverter(typeof(ProviderTypeJsonConverter))]
public enum ProviderType
{
    OpenAiCompatible,
    Anthropic,
    AzureOpenAi,
    LocalEndpoint,
}

public static class ProviderTypes
{
    public static string ToContractValue(this ProviderType value) => value switch
    {
        ProviderType.OpenAiCompatible => "openai-compatible",
        ProviderType.Anthropic => "anthropic",
        ProviderType.AzureOpenAi => "azure-openai",
        ProviderType.LocalEndpoint => "local-endpoint",
        _ => throw new ArgumentOutOfRangeException(nameof(value), value, "Unknown provider type."),
    };

    public static bool TryParse(string? value, out ProviderType providerType)
    {
        switch (value?.Trim().ToLowerInvariant())
        {
            case "openai-compatible":
                providerType = ProviderType.OpenAiCompatible;
                return true;
            case "anthropic":
                providerType = ProviderType.Anthropic;
                return true;
            case "azure-openai":
                providerType = ProviderType.AzureOpenAi;
                return true;
            case "local-endpoint":
                providerType = ProviderType.LocalEndpoint;
                return true;
            default:
                providerType = default;
                return false;
        }
    }
}

public sealed class ProviderTypeJsonConverter : JsonConverter<ProviderType>
{
    public override ProviderType Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType != JsonTokenType.String ||
            !ProviderTypes.TryParse(reader.GetString(), out var value))
        {
            throw new JsonException("Unknown provider type.");
        }

        return value;
    }

    public override void Write(Utf8JsonWriter writer, ProviderType value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value.ToContractValue());
}
