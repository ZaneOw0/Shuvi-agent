using LocalAIGateway.Core.Configuration;

namespace LocalAIGateway.Core.Backup;

public interface IBackupCryptography
{
    Task<byte[]> EncryptAsync(
        ReadOnlyMemory<byte> plaintext,
        string passphrase,
        CancellationToken cancellationToken = default);

    Task<byte[]> DecryptAsync(
        ReadOnlyMemory<byte> envelope,
        string passphrase,
        CancellationToken cancellationToken = default);
}

public sealed record BackupCreateRequest(
    string OutputPath,
    bool IncludeSecrets,
    string? Passphrase);

public sealed record BackupInspectRequest(
    string InputPath,
    string? Passphrase);

public sealed record BackupRestoreRequest(
    string InputPath,
    string ExpectedSha256,
    long ExpectedCurrentRevision,
    bool Confirmed,
    string? Passphrase);

public sealed record BackupSummary(
    string Path,
    string Sha256,
    bool Encrypted,
    DateTimeOffset CreatedUtc,
    long SourceRevision,
    int ProfileCount,
    int ProviderCount,
    int ModelCount,
    int SecretCount);

public sealed record BackupRestoreResult(
    BackupSummary Backup,
    long PreviousRevision,
    long CurrentRevision,
    int SecretsRestored);

public sealed class BackupException : Exception
{
    public BackupException(string errorCode, string message, Exception? innerException = null)
        : base(message, innerException)
    {
        ErrorCode = errorCode;
    }

    public string ErrorCode { get; }
}

internal sealed record BackupPayloadDocument
{
    public int SchemaVersion { get; init; }
    public required string Kind { get; init; }
    public required DateTimeOffset CreatedUtc { get; init; }
    public required GatewayConfiguration Configuration { get; init; }
    public IReadOnlyList<BackupSecretDocument>? Secrets { get; init; }
}

internal sealed record BackupSecretDocument
{
    public required string Target { get; init; }
    public required string Value { get; init; }
}
