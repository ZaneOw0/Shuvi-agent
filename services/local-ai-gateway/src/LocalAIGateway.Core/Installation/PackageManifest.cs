namespace LocalAIGateway.Core.Installation;

public sealed record PackageManifest(
    int SchemaVersion,
    string PackageId,
    string Version,
    string RuntimeIdentifier,
    bool Unsigned,
    IReadOnlyList<PackageFile> Files)
{
    public const int CurrentSchemaVersion = 1;

    public const string FileName = "PACKAGE-MANIFEST.json";

    public const string ProductPackageId = "LocalAIGateway";

    public const string WindowsX64RuntimeIdentifier = "win-x64";
}

public sealed record PackageFile(string Path, long Size, string Sha256);
