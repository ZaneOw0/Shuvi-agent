using System.Text.Json;
using System.Text.Json.Serialization;
using LocalAIGateway.Core.Configuration;

namespace LocalAIGateway.Core.Backup;

internal static class BackupJson
{
    public const int CurrentSchemaVersion = 1;
    public const string ConfigurationKind = "configuration";
    public const string EncryptedKind = "configuration-with-secrets";
    public const int MaximumDocumentBytes = 4 * 1024 * 1024;

    private static readonly JsonSerializerOptions Options = new()
    {
        AllowTrailingCommas = false,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        MaxDepth = 64,
        PropertyNameCaseInsensitive = false,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        ReadCommentHandling = JsonCommentHandling.Disallow,
        RespectNullableAnnotations = true,
        RespectRequiredConstructorParameters = true,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
        WriteIndented = true,
    };

    public static byte[] Serialize(BackupPayloadDocument document) =>
        JsonSerializer.SerializeToUtf8Bytes(document, Options);

    public static BackupPayloadDocument DeserializePayload(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length == 0 || bytes.Length > MaximumDocumentBytes)
        {
            throw InvalidFormat();
        }

        try
        {
            RejectDuplicateProperties(bytes);
            var document = JsonSerializer.Deserialize<BackupPayloadDocument>(bytes, Options)
                ?? throw InvalidFormat();
            ValidatePayload(document);
            return document;
        }
        catch (BackupException)
        {
            throw;
        }
        catch (JsonException exception)
        {
            throw new BackupException(
                "aigw_backup_format_invalid",
                "The backup document is malformed or outside the supported contract.",
                exception);
        }
    }

    public static bool IsEncryptedEnvelope(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length == 0 || bytes.Length > MaximumDocumentBytes)
        {
            throw InvalidFormat();
        }

        try
        {
            RejectDuplicateProperties(bytes);
            using var document = JsonDocument.Parse(bytes.ToArray(), new JsonDocumentOptions
            {
                AllowTrailingCommas = false,
                CommentHandling = JsonCommentHandling.Disallow,
                MaxDepth = 16,
            });
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object ||
                !root.TryGetProperty("kind", out var kind) ||
                kind.ValueKind != JsonValueKind.String)
            {
                throw InvalidFormat();
            }

            return string.Equals(kind.GetString(), "encrypted", StringComparison.Ordinal);
        }
        catch (BackupException)
        {
            throw;
        }
        catch (JsonException exception)
        {
            throw new BackupException(
                "aigw_backup_format_invalid",
                "The backup document is malformed or outside the supported contract.",
                exception);
        }
    }

    public static void ValidateEncryptedEnvelope(ReadOnlySpan<byte> bytes)
    {
        if (!IsEncryptedEnvelope(bytes))
        {
            throw InvalidFormat();
        }

        try
        {
            using var document = JsonDocument.Parse(bytes.ToArray(), new JsonDocumentOptions
            {
                AllowTrailingCommas = false,
                CommentHandling = JsonCommentHandling.Disallow,
                MaxDepth = 16,
            });
            var root = document.RootElement;
            RequireExactProperties(root, "schemaVersion", "kind", "kdf", "cipher");
            if (root.GetProperty("schemaVersion").GetInt32() != CurrentSchemaVersion ||
                root.GetProperty("kind").GetString() != "encrypted")
            {
                throw InvalidFormat();
            }

            var kdf = root.GetProperty("kdf");
            RequireExactProperties(kdf, "algorithm", "salt", "length", "iterations", "lanes", "memoryKiB");
            if (kdf.GetProperty("algorithm").GetString() != "argon2id" ||
                kdf.GetProperty("length").GetInt32() != 32 ||
                kdf.GetProperty("iterations").GetInt32() != 3 ||
                kdf.GetProperty("lanes").GetInt32() != 4 ||
                kdf.GetProperty("memoryKiB").GetInt32() != 65_536 ||
                Decode(kdf.GetProperty("salt"), 16).Length != 16)
            {
                throw InvalidFormat();
            }

            var cipher = root.GetProperty("cipher");
            RequireExactProperties(cipher, "algorithm", "nonce", "ciphertext");
            var ciphertext = Decode(cipher.GetProperty("ciphertext"));
            if (cipher.GetProperty("algorithm").GetString() != "aes-256-gcm" ||
                Decode(cipher.GetProperty("nonce"), 12).Length != 12 ||
                ciphertext.Length < 16 ||
                ciphertext.Length > MaximumDocumentBytes + 16)
            {
                throw InvalidFormat();
            }
        }
        catch (BackupException)
        {
            throw;
        }
        catch (Exception exception) when (exception is JsonException or FormatException or InvalidOperationException)
        {
            throw new BackupException(
                "aigw_backup_format_invalid",
                "The encrypted backup envelope is malformed or outside the supported contract.",
                exception);
        }
    }

    private static void RequireExactProperties(JsonElement value, params string[] expected)
    {
        if (value.ValueKind != JsonValueKind.Object ||
            !value.EnumerateObject().Select(property => property.Name)
                .ToHashSet(StringComparer.Ordinal)
                .SetEquals(expected))
        {
            throw InvalidFormat();
        }
    }

    private static byte[] Decode(JsonElement value, int? expectedLength = null)
    {
        if (value.ValueKind != JsonValueKind.String)
        {
            throw InvalidFormat();
        }
        var decoded = Convert.FromBase64String(value.GetString()!);
        if (expectedLength is not null && decoded.Length != expectedLength.Value)
        {
            throw InvalidFormat();
        }
        return decoded;
    }

    private static void ValidatePayload(BackupPayloadDocument document)
    {
        if (document.SchemaVersion != CurrentSchemaVersion ||
            document.CreatedUtc.Offset != TimeSpan.Zero)
        {
            throw InvalidFormat();
        }

        var encrypted = string.Equals(document.Kind, EncryptedKind, StringComparison.Ordinal);
        if (!encrypted && !string.Equals(document.Kind, ConfigurationKind, StringComparison.Ordinal))
        {
            throw InvalidFormat();
        }
        if ((!encrypted && document.Secrets is not null) || (encrypted && document.Secrets is null))
        {
            throw InvalidFormat();
        }

        var validation = ConfigurationValidator.Validate(document.Configuration);
        if (!validation.IsValid)
        {
            throw new BackupException(
                "aigw_backup_configuration_invalid",
                "The backup contains an invalid Local AI Gateway configuration.");
        }

        if (document.Configuration.Profiles.Count > 1_000 ||
            document.Configuration.Profiles.Sum(profile => profile.Providers.Count) > 10_000 ||
            document.Configuration.Profiles.Sum(profile => profile.Models.Count) > 20_000)
        {
            throw InvalidFormat();
        }

        if (document.Secrets is null)
        {
            return;
        }

        if (document.Secrets.Count > 10_000)
        {
            throw InvalidFormat();
        }
        var allowedTargets = document.Configuration.Profiles
            .SelectMany(profile => profile.Providers)
            .Select(provider => provider.CredentialTarget)
            .ToHashSet(StringComparer.Ordinal);
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var secret in document.Secrets)
        {
            if (secret is null ||
                string.IsNullOrEmpty(secret.Value) ||
                System.Text.Encoding.UTF8.GetByteCount(secret.Value) > 2_560 ||
                !allowedTargets.Contains(secret.Target) ||
                !seen.Add(secret.Target))
            {
                throw InvalidFormat();
            }
        }
    }

    private static void RejectDuplicateProperties(ReadOnlySpan<byte> bytes)
    {
        var reader = new Utf8JsonReader(bytes, new JsonReaderOptions
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
                    var name = reader.GetString() ?? string.Empty;
                    if (propertySets.Count == 0 || !propertySets.Peek().Add(name))
                    {
                        throw InvalidFormat();
                    }
                    break;
            }
        }
    }

    private static BackupException InvalidFormat() => new(
        "aigw_backup_format_invalid",
        "The backup document is malformed or outside the supported contract.");
}
