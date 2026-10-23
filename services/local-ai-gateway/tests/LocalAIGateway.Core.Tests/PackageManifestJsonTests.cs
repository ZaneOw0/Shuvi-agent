using System.Text;
using System.Text.Json;
using LocalAIGateway.Core.Installation;

namespace LocalAIGateway.Core.Tests;

public sealed class PackageManifestJsonTests
{
    private const string HashA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    private const string HashB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

    [Fact]
    public void Serialize_is_canonical_and_round_trips()
    {
        var manifest = new PackageManifest(
            PackageManifest.CurrentSchemaVersion,
            "LocalAIGateway",
            "0.1.0-dev",
            "win-x64",
            true,
            [
                new PackageFile("runtime/python/python.exe", 20, HashB),
                new PackageFile("aigw.exe", 10, HashA),
            ]);

        var first = PackageManifestJson.Serialize(manifest);
        var second = PackageManifestJson.Serialize(PackageManifestJson.Deserialize(first));
        var text = Encoding.UTF8.GetString(first);

        Assert.Equal(first, second);
        Assert.True(text.IndexOf("aigw.exe", StringComparison.Ordinal) <
                    text.IndexOf("runtime/python/python.exe", StringComparison.Ordinal));
        Assert.DoesNotContain("\\", text);
    }

    [Fact]
    public void Unknown_and_duplicate_properties_are_rejected()
    {
        var unknown = ValidJson().Replace(
            "\"unsigned\":true",
            "\"unsigned\":true,\"unexpected\":1",
            StringComparison.Ordinal);
        var duplicate = ValidJson().Replace(
            "\"schemaVersion\":1",
            "\"schemaVersion\":1,\"schemaVersion\":1",
            StringComparison.Ordinal);

        Assert.Throws<JsonException>(() => PackageManifestJson.Deserialize(Encoding.UTF8.GetBytes(unknown)));
        Assert.Throws<JsonException>(() => PackageManifestJson.Deserialize(Encoding.UTF8.GetBytes(duplicate)));
    }

    [Theory]
    [InlineData("/absolute.exe")]
    [InlineData("../escape.exe")]
    [InlineData("runtime\\python.exe")]
    [InlineData("runtime//python.exe")]
    [InlineData("runtime/./python.exe")]
    [InlineData("runtime/NUL")]
    [InlineData("runtime/name:stream")]
    [InlineData("runtime/trailing. ")]
    public void Unsafe_paths_are_rejected(string path)
    {
        var manifest = ValidManifest([new PackageFile(path, 10, HashA)]);

        var failure = Assert.Throws<PackageManifestException>(() => PackageManifestJson.Serialize(manifest));

        Assert.Equal("aigw_package_manifest_unsafe_path", failure.ErrorCode);
    }

    [Fact]
    public void Windows_case_insensitive_duplicate_paths_are_rejected()
    {
        var manifest = ValidManifest([
            new PackageFile("runtime/python.exe", 10, HashA),
            new PackageFile("RUNTIME/PYTHON.EXE", 10, HashB),
        ]);

        var failure = Assert.Throws<PackageManifestException>(() => PackageManifestJson.Serialize(manifest));

        Assert.Equal("aigw_package_manifest_duplicate_path", failure.ErrorCode);
    }

    [Fact]
    public void Manifest_cannot_list_itself_as_package_content()
    {
        var manifest = ValidManifest([
            new PackageFile("package-manifest.json", 10, HashA),
        ]);

        var failure = Assert.Throws<PackageManifestException>(() => PackageManifestJson.Serialize(manifest));

        Assert.Equal("aigw_package_manifest_reserved_path", failure.ErrorCode);
    }

    [Theory]
    [InlineData(-1, HashA)]
    [InlineData(1, "ABC")]
    [InlineData(1, "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")]
    public void Invalid_size_or_hash_is_rejected(long size, string hash)
    {
        var manifest = ValidManifest([new PackageFile("aigw.exe", size, hash)]);

        var failure = Assert.Throws<PackageManifestException>(() => PackageManifestJson.Serialize(manifest));

        Assert.Equal("aigw_package_manifest_invalid_file", failure.ErrorCode);
    }

    [Fact]
    public void Unsupported_schema_is_rejected()
    {
        var manifest = ValidManifest([]) with { SchemaVersion = 2 };

        var failure = Assert.Throws<PackageManifestException>(() => PackageManifestJson.Serialize(manifest));

        Assert.Equal("aigw_package_manifest_unsupported_schema", failure.ErrorCode);
    }

    private static PackageManifest ValidManifest(IReadOnlyList<PackageFile> files) => new(
        PackageManifest.CurrentSchemaVersion,
        "LocalAIGateway",
        "0.1.0-dev",
        "win-x64",
        true,
        files);

    private static string ValidJson() =>
        "{\"schemaVersion\":1,\"packageId\":\"LocalAIGateway\",\"version\":\"0.1.0-dev\"," +
        "\"runtimeIdentifier\":\"win-x64\",\"unsigned\":true,\"files\":[]}";
}
