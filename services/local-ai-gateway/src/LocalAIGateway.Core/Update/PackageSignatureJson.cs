using System.Text.Json;
using System.Text.Json.Serialization;

namespace LocalAIGateway.Core.Update;

public static class PackageSignatureJson
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

    public static byte[] Serialize(PackageSignature value)
    {
        Validate(value);
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream))
        {
            writer.WriteStartObject();
            writer.WriteNumber("schemaVersion", value.SchemaVersion);
            writer.WriteString("algorithm", value.Algorithm);
            if (value.KeyId is null) writer.WriteNull("keyId"); else writer.WriteString("keyId", value.KeyId);
            writer.WriteString("manifestSha256", value.ManifestSha256);
            if (value.Signature is null) writer.WriteNull("signature"); else writer.WriteString("signature", value.Signature);
            writer.WriteEndObject();
        }
        return stream.ToArray();
    }

    public static PackageSignature Deserialize(ReadOnlySpan<byte> json)
    {
        if (json.Length == 0 || json.Length > MaximumBytes)
        {
            throw Invalid("Package signature metadata is missing or too large.");
        }
        RejectDuplicateProperties(json);
        try
        {
            var value = JsonSerializer.Deserialize<PackageSignature>(json, Options)
                ?? throw Invalid("Package signature metadata must be an object.");
            Validate(value);
            return value;
        }
        catch (UpdateException)
        {
            throw;
        }
        catch (JsonException exception)
        {
            throw Invalid("Package signature metadata is malformed.", exception);
        }
    }

    private static void Validate(PackageSignature value)
    {
        if (value.SchemaVersion != PackageSignature.CurrentSchemaVersion ||
            !IsHash(value.ManifestSha256))
        {
            throw Invalid("Package signature metadata has an unsupported schema or invalid manifest hash.");
        }

        if (value.Algorithm == PackageSignature.UnsignedAlgorithm)
        {
            if (value.KeyId is not null || value.Signature is not null)
            {
                throw Invalid("Unsigned package metadata must not contain a key or signature.");
            }
            return;
        }

        if (value.Algorithm != PackageSignature.Ed25519Algorithm ||
            !IsIdentifier(value.KeyId) || string.IsNullOrEmpty(value.Signature))
        {
            throw Invalid("Signed package metadata must contain a valid Ed25519 key and signature.");
        }

        try
        {
            if (Convert.FromBase64String(value.Signature).Length != 64)
            {
                throw Invalid("The Ed25519 signature must be exactly 64 bytes.");
            }
        }
        catch (FormatException exception)
        {
            throw Invalid("The Ed25519 signature is not valid base64.", exception);
        }
    }

    public static bool IsIdentifier(string? value) =>
        !string.IsNullOrEmpty(value) && value.Length <= 64 &&
        value.All(character => char.IsAsciiLetterOrDigit(character) || character is '.' or '-' or '_');

    public static bool IsHash(string? value) =>
        value is { Length: 64 } && value.All(character => character is >= '0' and <= '9' or >= 'a' and <= 'f');

    private static void RejectDuplicateProperties(ReadOnlySpan<byte> json)
    {
        try
        {
            var reader = new Utf8JsonReader(json, new JsonReaderOptions
            {
                AllowTrailingCommas = false,
                CommentHandling = JsonCommentHandling.Disallow,
                MaxDepth = 8,
            });
            var objects = new Stack<HashSet<string>>();
            while (reader.Read())
            {
                if (reader.TokenType == JsonTokenType.StartObject)
                {
                    objects.Push(new HashSet<string>(StringComparer.Ordinal));
                }
                else if (reader.TokenType == JsonTokenType.EndObject)
                {
                    objects.Pop();
                }
                else if (reader.TokenType == JsonTokenType.PropertyName &&
                         (objects.Count == 0 || !objects.Peek().Add(reader.GetString() ?? string.Empty)))
                {
                    throw Invalid("Package signature metadata contains a duplicate property.");
                }
            }
        }
        catch (UpdateException)
        {
            throw;
        }
        catch (JsonException exception)
        {
            throw Invalid("Package signature metadata is malformed.", exception);
        }
    }

    private static UpdateException Invalid(string message, Exception? inner = null) =>
        new("aigw_update_signature_metadata_invalid", message, inner);
}
