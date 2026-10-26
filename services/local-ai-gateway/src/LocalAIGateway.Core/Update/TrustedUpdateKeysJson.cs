using System.Text.Json;
using System.Text.Json.Serialization;

namespace LocalAIGateway.Core.Update;

public static class TrustedUpdateKeysJson
{
    public const int MaximumBytes = 64 * 1024;
    private static readonly JsonSerializerOptions Options = new()
    {
        AllowTrailingCommas = false,
        MaxDepth = 8,
        PropertyNameCaseInsensitive = false,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        ReadCommentHandling = JsonCommentHandling.Disallow,
        RespectNullableAnnotations = true,
        RespectRequiredConstructorParameters = true,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
    };

    public static byte[] Serialize(TrustedUpdateKeys value)
    {
        var keys = Validate(value);
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream))
        {
            writer.WriteStartObject();
            writer.WriteNumber("schemaVersion", value.SchemaVersion);
            writer.WriteStartArray("keys");
            foreach (var key in keys)
            {
                writer.WriteStartObject();
                writer.WriteString("keyId", key.KeyId);
                writer.WriteString("algorithm", key.Algorithm);
                writer.WriteString("publicKey", key.PublicKey);
                writer.WriteEndObject();
            }
            writer.WriteEndArray();
            writer.WriteEndObject();
        }
        return stream.ToArray();
    }

    public static TrustedUpdateKeys Deserialize(ReadOnlySpan<byte> json)
    {
        if (json.Length == 0 || json.Length > MaximumBytes)
        {
            throw Invalid("Trusted update key metadata is missing or too large.");
        }
        RejectDuplicateProperties(json);
        try
        {
            var value = JsonSerializer.Deserialize<TrustedUpdateKeys>(json, Options)
                ?? throw Invalid("Trusted update key metadata must be an object.");
            Validate(value);
            return value;
        }
        catch (UpdateException)
        {
            throw;
        }
        catch (JsonException exception)
        {
            throw Invalid("Trusted update key metadata is malformed.", exception);
        }
    }

    private static TrustedUpdateKey[] Validate(TrustedUpdateKeys value)
    {
        if (value.SchemaVersion != TrustedUpdateKeys.CurrentSchemaVersion || value.Keys is null || value.Keys.Count > 32)
        {
            throw Invalid("Trusted update key metadata has an unsupported schema or key count.");
        }
        var ids = new HashSet<string>(StringComparer.Ordinal);
        var keys = value.Keys.OrderBy(key => key.KeyId, StringComparer.Ordinal).ToArray();
        foreach (var key in keys)
        {
            if (!PackageSignatureJson.IsIdentifier(key.KeyId) ||
                key.Algorithm != PackageSignature.Ed25519Algorithm || !ids.Add(key.KeyId))
            {
                throw Invalid("Trusted update key metadata contains an invalid or duplicate key.");
            }
            try
            {
                if (Convert.FromBase64String(key.PublicKey).Length != 32)
                {
                    throw Invalid("An Ed25519 public key must be exactly 32 bytes.");
                }
            }
            catch (FormatException exception)
            {
                throw Invalid("An Ed25519 public key is not valid base64.", exception);
            }
        }
        return keys;
    }

    private static void RejectDuplicateProperties(ReadOnlySpan<byte> json)
    {
        try
        {
            var reader = new Utf8JsonReader(json, new JsonReaderOptions { MaxDepth = 8 });
            var objects = new Stack<HashSet<string>>();
            while (reader.Read())
            {
                if (reader.TokenType == JsonTokenType.StartObject) objects.Push(new(StringComparer.Ordinal));
                else if (reader.TokenType == JsonTokenType.EndObject) objects.Pop();
                else if (reader.TokenType == JsonTokenType.PropertyName &&
                         (objects.Count == 0 || !objects.Peek().Add(reader.GetString() ?? string.Empty)))
                    throw Invalid("Trusted update key metadata contains a duplicate property.");
            }
        }
        catch (UpdateException) { throw; }
        catch (JsonException exception) { throw Invalid("Trusted update key metadata is malformed.", exception); }
    }

    private static UpdateException Invalid(string message, Exception? inner = null) =>
        new("aigw_update_trust_store_invalid", message, inner);
}
