namespace LocalAIGateway.Core.Update;

public sealed record PackageSignature(
    int SchemaVersion,
    string Algorithm,
    string? KeyId,
    string ManifestSha256,
    string? Signature)
{
    public const int CurrentSchemaVersion = 1;
    public const string FileName = "PACKAGE-SIGNATURE.json";
    public const string UnsignedAlgorithm = "none";
    public const string Ed25519Algorithm = "Ed25519";
}

public sealed record TrustedUpdateKey(
    string KeyId,
    string Algorithm,
    string PublicKey);

public sealed record TrustedUpdateKeys(
    int SchemaVersion,
    IReadOnlyList<TrustedUpdateKey> Keys)
{
    public const int CurrentSchemaVersion = 1;
    public const string FileName = "TRUSTED-UPDATE-KEYS.json";
}

public enum PackageTrustKind
{
    UnsignedDevelopment,
    Signed,
}

public sealed record PackageUpdateInspection(
    string PackageRoot,
    string Version,
    string ManifestSha256,
    PackageTrustKind TrustKind,
    string? KeyId,
    int FileCount,
    string? InstalledVersion = null);

public sealed record PackageUpdateRequest(
    string PackageRoot,
    string ExpectedManifestSha256,
    bool Confirmed,
    bool AllowUnsignedDevelopment,
    bool DeferRollbackCleanup = false);

public sealed record PackageUpdateResult(
    string PreviousVersion,
    string CurrentVersion,
    string ManifestSha256,
    PackageTrustKind TrustKind,
    string? KeyId,
    bool DaemonWasRunning,
    bool DaemonRunning,
    bool RolledBack,
    string? DeferredCleanupPath,
    bool CompletionPending = false,
    string? OperationId = null,
    string? ReceiptPath = null);

public interface IPackageUpdateService
{
    Task<PackageUpdateInspection> InspectAsync(
        string packageRoot,
        bool allowUnsignedDevelopment,
        CancellationToken cancellationToken = default);

    Task<PackageUpdateResult> ApplyAsync(
        PackageUpdateRequest request,
        CancellationToken cancellationToken = default);
}
