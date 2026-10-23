using System.Text.Json;
using System.Text.Json.Serialization;
using LocalAIGateway.Core.Update;

namespace LocalAIGateway.Core.Installation;

public static class PackageManifestJson
{
    public const int MaximumManifestBytes = 8 * 1024 * 1024;
    public const int MaximumFileCount = 100_000;
    public const int MaximumRelativePathLength = 1024;

    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        AllowTrailingCommas = false,
        DefaultIgnoreCondition = JsonIgnoreCondition.Never,
        MaxDepth = 16,
        PropertyNameCaseInsensitive = false,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        ReadCommentHandling = JsonCommentHandling.Disallow,
        RespectNullableAnnotations = true,
        RespectRequiredConstructorParameters = true,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
    };

    private static readonly HashSet<string> ReservedDeviceNames = new(
        [
            "CON", "PRN", "AUX", "NUL",
            "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
            "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
        ],
        StringComparer.OrdinalIgnoreCase);

    public static byte[] Serialize(PackageManifest manifest)
    {
        ArgumentNullException.ThrowIfNull(manifest);
        var files = ValidateAndSort(manifest);
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream))
        {
            writer.WriteStartObject();
            writer.WriteNumber("schemaVersion", manifest.SchemaVersion);
            writer.WriteString("packageId", manifest.PackageId);
            writer.WriteString("version", manifest.Version);
            writer.WriteString("runtimeIdentifier", manifest.RuntimeIdentifier);
            writer.WriteBoolean("unsigned", manifest.Unsigned);
            writer.WriteStartArray("files");
            foreach (var file in files)
            {
                writer.WriteStartObject();
                writer.WriteString("path", file.Path);
                writer.WriteNumber("size", file.Size);
                writer.WriteString("sha256", file.Sha256);
                writer.WriteEndObject();
            }

            writer.WriteEndArray();
            writer.WriteEndObject();
        }

        return stream.ToArray();
    }

    public static PackageManifest Deserialize(ReadOnlySpan<byte> utf8Json)
    {
        if (utf8Json.Length > MaximumManifestBytes)
        {
            throw new PackageManifestException(
                "aigw_package_manifest_too_large",
                "Package manifest exceeds the maximum supported size.");
        }

        if (utf8Json.Length >= 3 &&
            utf8Json[0] == 0xef &&
            utf8Json[1] == 0xbb &&
            utf8Json[2] == 0xbf)
        {
            utf8Json = utf8Json[3..];
        }

        RejectDuplicateProperties(utf8Json);
        var manifest = JsonSerializer.Deserialize<PackageManifest>(utf8Json, SerializerOptions)
            ?? throw new JsonException("Package manifest JSON must contain an object.");
        ValidateAndSort(manifest);
        return manifest;
    }

    private static PackageFile[] ValidateAndSort(PackageManifest manifest)
    {
        if (manifest.SchemaVersion != PackageManifest.CurrentSchemaVersion)
        {
            throw new PackageManifestException(
                "aigw_package_manifest_unsupported_schema",
                "Package manifest schema version is not supported.");
        }

        if (!string.Equals(
                manifest.PackageId,
                PackageManifest.ProductPackageId,
                StringComparison.Ordinal) ||
            !string.Equals(
                manifest.RuntimeIdentifier,
                PackageManifest.WindowsX64RuntimeIdentifier,
                StringComparison.Ordinal) ||
            string.IsNullOrWhiteSpace(manifest.Version) ||
            manifest.Version.Length > 64 ||
            manifest.Version.Any(character =>
                !char.IsAsciiLetterOrDigit(character) && character is not '.' and not '-'))
        {
            throw new PackageManifestException(
                "aigw_package_manifest_invalid_identity",
                "Package manifest identity is invalid.");
        }

        if (manifest.Files is null || manifest.Files.Count > MaximumFileCount)
        {
            throw new PackageManifestException(
                "aigw_package_manifest_invalid_files",
                "Package manifest file collection is invalid.");
        }

        var paths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var files = new PackageFile[manifest.Files.Count];
        for (var index = 0; index < manifest.Files.Count; index++)
        {
            var file = manifest.Files[index] ?? throw new PackageManifestException(
                "aigw_package_manifest_invalid_file",
                "Package manifest file entry must not be null.");
            ValidatePath(file.Path);
            if (string.Equals(file.Path, PackageManifest.FileName, StringComparison.OrdinalIgnoreCase) ||
                string.Equals(file.Path, PackageSignature.FileName, StringComparison.OrdinalIgnoreCase))
            {
                throw new PackageManifestException(
                    "aigw_package_manifest_reserved_path",
                    "Package manifest cannot list its own reserved path as package content.");
            }

            if (!paths.Add(file.Path))
            {
                throw new PackageManifestException(
                    "aigw_package_manifest_duplicate_path",
                    "Package manifest contains duplicate Windows paths.");
            }

            if (file.Size < 0 ||
                file.Sha256.Length != 64 ||
                file.Sha256.Any(character => character is not (>= '0' and <= '9') and not (>= 'a' and <= 'f')))
            {
                throw new PackageManifestException(
                    "aigw_package_manifest_invalid_file",
                    "Package manifest file size or SHA-256 is invalid.");
            }

            files[index] = file;
        }

        Array.Sort(files, static (left, right) => StringComparer.Ordinal.Compare(left.Path, right.Path));
        return files;
    }

    private static void ValidatePath(string path)
    {
        if (string.IsNullOrEmpty(path) ||
            path.Length > MaximumRelativePathLength ||
            path[0] == '/' ||
            path.Contains('\\', StringComparison.Ordinal) ||
            path.Contains(':', StringComparison.Ordinal) ||
            path.Any(character => char.IsControl(character) || character is '<' or '>' or '"' or '|' or '?' or '*'))
        {
            throw UnsafePath();
        }

        var segments = path.Split('/');
        foreach (var segment in segments)
        {
            if (segment.Length == 0 ||
                segment is "." or ".." ||
                segment.EndsWith(' ') ||
                segment.EndsWith('.') ||
                ReservedDeviceNames.Contains(segment.Split('.')[0]))
            {
                throw UnsafePath();
            }
        }
    }

    private static PackageManifestException UnsafePath() => new(
        "aigw_package_manifest_unsafe_path",
        "Package manifest contains an unsafe Windows path.");

    private static void RejectDuplicateProperties(ReadOnlySpan<byte> utf8Json)
    {
        var reader = new Utf8JsonReader(
            utf8Json,
            new JsonReaderOptions
            {
                AllowTrailingCommas = false,
                CommentHandling = JsonCommentHandling.Disallow,
                MaxDepth = 16,
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
