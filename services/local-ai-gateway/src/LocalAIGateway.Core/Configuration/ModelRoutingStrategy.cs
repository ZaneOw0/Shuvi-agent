using System.Text.Json;
using System.Text.Json.Serialization;

namespace LocalAIGateway.Core.Configuration;

[JsonConverter(typeof(ModelRoutingStrategyJsonConverter))]
public enum ModelRoutingStrategy
{
    OrderedFallback,
    WeightedRoundRobin,
}

public static class ModelRoutingStrategies
{
    public static string ToContractValue(this ModelRoutingStrategy value) => value switch
    {
        ModelRoutingStrategy.OrderedFallback => "ordered-fallback",
        ModelRoutingStrategy.WeightedRoundRobin => "weighted-round-robin",
        _ => throw new ArgumentOutOfRangeException(nameof(value), value, "Unknown model routing strategy."),
    };

    public static bool TryParse(string? value, out ModelRoutingStrategy strategy)
    {
        switch (value?.Trim().ToLowerInvariant())
        {
            case "ordered-fallback":
                strategy = ModelRoutingStrategy.OrderedFallback;
                return true;
            case "weighted-round-robin":
                strategy = ModelRoutingStrategy.WeightedRoundRobin;
                return true;
            default:
                strategy = default;
                return false;
        }
    }
}

public sealed class ModelRoutingStrategyJsonConverter : JsonConverter<ModelRoutingStrategy>
{
    public override ModelRoutingStrategy Read(
        ref Utf8JsonReader reader,
        Type typeToConvert,
        JsonSerializerOptions options)
    {
        if (reader.TokenType != JsonTokenType.String ||
            !ModelRoutingStrategies.TryParse(reader.GetString(), out var value))
        {
            throw new JsonException("Unknown model routing strategy.");
        }

        return value;
    }

    public override void Write(
        Utf8JsonWriter writer,
        ModelRoutingStrategy value,
        JsonSerializerOptions options) => writer.WriteStringValue(value.ToContractValue());
}
