using System.Text.Json;

namespace LocalAIGateway.Core.Control;

public static class ControlJson
{
    public static byte[] SerializeRequest(ControlRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream))
        {
            writer.WriteStartObject();
            writer.WriteNumber("version", request.Version);
            writer.WriteString("command", request.Command);
            writer.WriteEndObject();
        }

        return stream.ToArray();
    }

    public static ControlRequest DeserializeRequest(ReadOnlySpan<byte> payload)
    {
        using var document = Parse(payload);
        var root = RequireObject(document.RootElement, "aigw_control_invalid_request");
        var properties = ReadProperties(root, ["version", "command"]);
        RequireExactProperties(properties, ["version", "command"], "aigw_control_invalid_request");
        var version = RequireInt32(properties["version"], "aigw_control_invalid_request");
        if (version != ControlProtocol.Version)
        {
            throw new ControlProtocolException(
                "aigw_control_unsupported_version",
                "Control protocol version is not supported.");
        }

        var command = RequireString(properties["command"], "aigw_control_invalid_request");
        if (!ControlCommands.IsSupported(command))
        {
            throw new ControlProtocolException(
                "aigw_control_unsupported_command",
                "Control command is not supported.");
        }

        return new ControlRequest(version, command);
    }

    public static byte[] SerializeResponse(ControlResponse response)
    {
        ArgumentNullException.ThrowIfNull(response);
        ValidateResponse(response);
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream))
        {
            writer.WriteStartObject();
            writer.WriteNumber("version", response.Version);
            writer.WriteBoolean("ok", response.Ok);
            if (response.Status is not null)
            {
                WriteStatus(writer, response.Status);
            }

            if (response.Error is not null)
            {
                writer.WriteStartObject("error");
                writer.WriteString("code", response.Error.Code);
                writer.WriteString("message", response.Error.Message);
                writer.WriteEndObject();
            }

            writer.WriteEndObject();
        }

        return stream.ToArray();
    }

    public static ControlResponse DeserializeResponse(ReadOnlySpan<byte> payload)
    {
        using var document = Parse(payload);
        var root = RequireObject(document.RootElement, "aigw_control_invalid_response");
        var properties = ReadProperties(root, ["version", "ok", "status", "error"]);
        if (!properties.ContainsKey("version") || !properties.ContainsKey("ok"))
        {
            throw InvalidResponse();
        }

        var version = RequireInt32(properties["version"], "aigw_control_invalid_response");
        if (version != ControlProtocol.Version)
        {
            throw new ControlProtocolException(
                "aigw_control_unsupported_version",
                "Control protocol version is not supported.");
        }

        if (properties["ok"].ValueKind is not JsonValueKind.True and not JsonValueKind.False)
        {
            throw InvalidResponse();
        }

        var ok = properties["ok"].GetBoolean();
        var status = properties.TryGetValue("status", out var statusElement)
            ? ReadStatus(statusElement)
            : null;
        var error = properties.TryGetValue("error", out var errorElement)
            ? ReadError(errorElement)
            : null;
        var response = new ControlResponse(version, ok, status, error);
        ValidateResponse(response);
        return response;
    }

    private static JsonDocument Parse(ReadOnlySpan<byte> payload)
    {
        try
        {
            return JsonDocument.Parse(payload.ToArray(), new JsonDocumentOptions
            {
                AllowTrailingCommas = false,
                CommentHandling = JsonCommentHandling.Disallow,
                MaxDepth = 8,
            });
        }
        catch (JsonException exception)
        {
            throw new ControlProtocolException(
                "aigw_control_malformed_json",
                "Control message is not valid JSON.",
                exception);
        }
    }

    private static JsonElement RequireObject(JsonElement element, string errorCode)
    {
        if (element.ValueKind != JsonValueKind.Object)
        {
            throw new ControlProtocolException(errorCode, "Control JSON value must be an object.");
        }

        return element;
    }

    private static Dictionary<string, JsonElement> ReadProperties(
        JsonElement element,
        params string[] allowed)
    {
        var properties = new Dictionary<string, JsonElement>(StringComparer.Ordinal);
        foreach (var property in element.EnumerateObject())
        {
            if (!allowed.Contains(property.Name))
            {
                throw new ControlProtocolException(
                    "aigw_control_unknown_property",
                    "Control message contains an unknown property.");
            }

            if (!properties.TryAdd(property.Name, property.Value))
            {
                throw new ControlProtocolException(
                    "aigw_control_duplicate_property",
                    "Control message contains a duplicate property.");
            }
        }

        return properties;
    }

    private static void RequireExactProperties(
        IReadOnlyDictionary<string, JsonElement> properties,
        string[] required,
        string errorCode)
    {
        if (properties.Count != required.Length || required.Any(name => !properties.ContainsKey(name)))
        {
            throw new ControlProtocolException(errorCode, "Control message is missing a required property.");
        }
    }

    private static int RequireInt32(JsonElement element, string errorCode)
    {
        if (element.ValueKind != JsonValueKind.Number || !element.TryGetInt32(out var value))
        {
            throw new ControlProtocolException(errorCode, "Control property must be an integer.");
        }

        return value;
    }

    private static string RequireString(JsonElement element, string errorCode)
    {
        if (element.ValueKind != JsonValueKind.String || string.IsNullOrEmpty(element.GetString()))
        {
            throw new ControlProtocolException(errorCode, "Control property must be a non-empty string.");
        }

        return element.GetString()!;
    }

    private static ControlStatus ReadStatus(JsonElement element)
    {
        RequireObject(element, "aigw_control_invalid_response");
        var properties = ReadProperties(
            element,
            [
                "running",
                "activeProfileId",
                "activeConfigurationRevision",
                "pendingConfigurationRevision",
                "switching",
                "lastReloadErrorCode",
                "targetCircuits",
            ]);
        RequireExactProperties(
            properties.Where(pair => pair.Key != "lastReloadErrorCode").ToDictionary(),
            ["running", "activeProfileId", "activeConfigurationRevision", "pendingConfigurationRevision", "switching", "targetCircuits"],
            "aigw_control_invalid_response");

        if (properties["running"].ValueKind is not JsonValueKind.True and not JsonValueKind.False ||
            properties["switching"].ValueKind is not JsonValueKind.True and not JsonValueKind.False)
        {
            throw InvalidResponse();
        }

        return new ControlStatus(
            properties["running"].GetBoolean(),
            ReadNullableString(properties["activeProfileId"]),
            ReadNullableInt64(properties["activeConfigurationRevision"]),
            ReadNullableInt64(properties["pendingConfigurationRevision"]),
            properties["switching"].GetBoolean(),
            properties.TryGetValue("lastReloadErrorCode", out var errorCode)
                ? ReadNullableString(errorCode)
                : null,
            ReadTargetCircuits(properties["targetCircuits"]));
    }

    private static IReadOnlyList<TargetCircuitStatus> ReadTargetCircuits(JsonElement element)
    {
        if (element.ValueKind != JsonValueKind.Array)
        {
            throw InvalidResponse();
        }

        var circuits = new List<TargetCircuitStatus>();
        foreach (var item in element.EnumerateArray())
        {
            RequireObject(item, "aigw_control_invalid_response");
            var properties = ReadProperties(
                item,
                ["providerId", "modelAlias", "state", "consecutiveFailures", "openUntilUtc"]);
            RequireExactProperties(
                properties,
                ["providerId", "modelAlias", "state", "consecutiveFailures", "openUntilUtc"],
                "aigw_control_invalid_response");
            circuits.Add(new TargetCircuitStatus(
                RequireString(properties["providerId"], "aigw_control_invalid_response"),
                RequireString(properties["modelAlias"], "aigw_control_invalid_response"),
                RequireString(properties["state"], "aigw_control_invalid_response"),
                RequireInt32(properties["consecutiveFailures"], "aigw_control_invalid_response"),
                ReadNullableDateTimeOffset(properties["openUntilUtc"])));
        }

        return circuits;
    }

    private static ControlError ReadError(JsonElement element)
    {
        RequireObject(element, "aigw_control_invalid_response");
        var properties = ReadProperties(element, ["code", "message"]);
        RequireExactProperties(properties, ["code", "message"], "aigw_control_invalid_response");
        return new ControlError(
            RequireString(properties["code"], "aigw_control_invalid_response"),
            RequireString(properties["message"], "aigw_control_invalid_response"));
    }

    private static string? ReadNullableString(JsonElement element) => element.ValueKind switch
    {
        JsonValueKind.Null => null,
        JsonValueKind.String => element.GetString(),
        _ => throw InvalidResponse(),
    };

    private static long? ReadNullableInt64(JsonElement element) => element.ValueKind switch
    {
        JsonValueKind.Null => null,
        JsonValueKind.Number when element.TryGetInt64(out var value) => value,
        _ => throw InvalidResponse(),
    };

    private static DateTimeOffset? ReadNullableDateTimeOffset(JsonElement element) => element.ValueKind switch
    {
        JsonValueKind.Null => null,
        JsonValueKind.String when element.TryGetDateTimeOffset(out var value) => value,
        _ => throw InvalidResponse(),
    };

    private static void WriteStatus(Utf8JsonWriter writer, ControlStatus status)
    {
        writer.WriteStartObject("status");
        writer.WriteBoolean("running", status.Running);
        WriteNullableString(writer, "activeProfileId", status.ActiveProfileId);
        WriteNullableNumber(writer, "activeConfigurationRevision", status.ActiveConfigurationRevision);
        WriteNullableNumber(writer, "pendingConfigurationRevision", status.PendingConfigurationRevision);
        writer.WriteBoolean("switching", status.Switching);
        if (status.LastReloadErrorCode is not null)
        {
            writer.WriteString("lastReloadErrorCode", status.LastReloadErrorCode);
        }

        writer.WriteStartArray("targetCircuits");
        foreach (var circuit in status.TargetCircuits)
        {
            writer.WriteStartObject();
            writer.WriteString("providerId", circuit.ProviderId);
            writer.WriteString("modelAlias", circuit.ModelAlias);
            writer.WriteString("state", circuit.State);
            writer.WriteNumber("consecutiveFailures", circuit.ConsecutiveFailures);
            if (circuit.OpenUntilUtc is DateTimeOffset openUntilUtc)
            {
                writer.WriteString("openUntilUtc", openUntilUtc);
            }
            else
            {
                writer.WriteNull("openUntilUtc");
            }

            writer.WriteEndObject();
        }

        writer.WriteEndArray();

        writer.WriteEndObject();
    }

    private static void WriteNullableString(Utf8JsonWriter writer, string propertyName, string? value)
    {
        if (value is null)
        {
            writer.WriteNull(propertyName);
        }
        else
        {
            writer.WriteString(propertyName, value);
        }
    }

    private static void WriteNullableNumber(Utf8JsonWriter writer, string propertyName, long? value)
    {
        if (value.HasValue)
        {
            writer.WriteNumber(propertyName, value.Value);
        }
        else
        {
            writer.WriteNull(propertyName);
        }
    }

    private static void ValidateResponse(ControlResponse response)
    {
        if (response.Version != ControlProtocol.Version)
        {
            throw new ControlProtocolException(
                "aigw_control_unsupported_version",
                "Control protocol version is not supported.");
        }

        if (response.Ok != (response.Status is not null) || response.Ok == (response.Error is not null))
        {
            throw InvalidResponse();
        }

        if (response.Status is { Running: true } status &&
            (string.IsNullOrWhiteSpace(status.ActiveProfileId) || status.ActiveConfigurationRevision is null))
        {
            throw InvalidResponse();
        }

        if (response.Status is { } responseStatus)
        {
            if (responseStatus.TargetCircuits is null ||
                (!responseStatus.Running && responseStatus.TargetCircuits.Count != 0) ||
                responseStatus.TargetCircuits.Count > 1024 ||
                responseStatus.TargetCircuits.Any(circuit =>
                    string.IsNullOrWhiteSpace(circuit.ProviderId) ||
                    string.IsNullOrWhiteSpace(circuit.ModelAlias) ||
                    !CircuitStates.IsSupported(circuit.State) ||
                    circuit.ConsecutiveFailures < 0 ||
                    (circuit.State == CircuitStates.Open) != circuit.OpenUntilUtc.HasValue) ||
                responseStatus.TargetCircuits
                    .GroupBy(
                        circuit => (circuit.ProviderId, circuit.ModelAlias),
                        new TargetCircuitIdentityComparer())
                    .Any(group => group.Count() != 1))
            {
                throw InvalidResponse();
            }
        }

        if (response.Error is not null &&
            (!response.Error.Code.StartsWith("aigw_control_", StringComparison.Ordinal) ||
             string.IsNullOrWhiteSpace(response.Error.Message)))
        {
            throw InvalidResponse();
        }
    }

    private static ControlProtocolException InvalidResponse() => new(
        "aigw_control_invalid_response",
        "Control response does not match the protocol contract.");

    private sealed class TargetCircuitIdentityComparer : IEqualityComparer<(string ProviderId, string ModelAlias)>
    {
        public bool Equals(
            (string ProviderId, string ModelAlias) x,
            (string ProviderId, string ModelAlias) y) =>
            StringComparer.OrdinalIgnoreCase.Equals(x.ProviderId, y.ProviderId) &&
            StringComparer.OrdinalIgnoreCase.Equals(x.ModelAlias, y.ModelAlias);

        public int GetHashCode((string ProviderId, string ModelAlias) value) =>
            HashCode.Combine(
                StringComparer.OrdinalIgnoreCase.GetHashCode(value.ProviderId),
                StringComparer.OrdinalIgnoreCase.GetHashCode(value.ModelAlias));
    }
}
