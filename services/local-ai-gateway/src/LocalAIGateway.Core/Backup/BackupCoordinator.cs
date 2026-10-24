using System.Security.Cryptography;
using LocalAIGateway.Core.Configuration;
using LocalAIGateway.Core.Credentials;

namespace LocalAIGateway.Core.Backup;

public sealed class BackupCoordinator
{
    private readonly ConfigurationStore configurationStore;
    private readonly ICredentialStore credentialStore;
    private readonly IBackupCryptography cryptography;
    private readonly IConfigurationFileSecurity fileSecurity;
    private readonly TimeProvider timeProvider;

    public BackupCoordinator(
        ConfigurationStore configurationStore,
        ICredentialStore credentialStore,
        IBackupCryptography cryptography,
        IConfigurationFileSecurity fileSecurity,
        TimeProvider? timeProvider = null)
    {
        this.configurationStore = configurationStore ?? throw new ArgumentNullException(nameof(configurationStore));
        this.credentialStore = credentialStore ?? throw new ArgumentNullException(nameof(credentialStore));
        this.cryptography = cryptography ?? throw new ArgumentNullException(nameof(cryptography));
        this.fileSecurity = fileSecurity ?? throw new ArgumentNullException(nameof(fileSecurity));
        this.timeProvider = timeProvider ?? TimeProvider.System;
    }

    public async Task<BackupSummary> CreateAsync(
        BackupCreateRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        var outputPath = ValidateOutputPath(request.OutputPath);
        ValidatePassphrase(request.IncludeSecrets, request.Passphrase);
        var configuration = await configurationStore.LoadAsync(cancellationToken);
        IReadOnlyList<BackupSecretDocument>? secrets = null;
        if (request.IncludeSecrets)
        {
            var collected = new List<BackupSecretDocument>();
            foreach (var target in ProviderTargets(configuration))
            {
                var value = await credentialStore.GetSecretAsync(target, cancellationToken);
                if (value is not null)
                {
                    collected.Add(new BackupSecretDocument { Target = target, Value = value });
                }
            }
            secrets = collected;
        }

        var payload = new BackupPayloadDocument
        {
            SchemaVersion = BackupJson.CurrentSchemaVersion,
            Kind = request.IncludeSecrets ? BackupJson.EncryptedKind : BackupJson.ConfigurationKind,
            CreatedUtc = timeProvider.GetUtcNow().ToUniversalTime(),
            Configuration = configuration,
            Secrets = secrets,
        };
        var payloadBytes = BackupJson.Serialize(payload);
        byte[] outputBytes;
        try
        {
            outputBytes = request.IncludeSecrets
                ? await cryptography.EncryptAsync(payloadBytes, request.Passphrase!, cancellationToken)
                : payloadBytes;
        }
        finally
        {
            if (request.IncludeSecrets)
            {
                CryptographicOperations.ZeroMemory(payloadBytes);
            }
        }
        try
        {
            if (outputBytes.Length == 0 || outputBytes.Length > BackupJson.MaximumDocumentBytes)
            {
                throw new BackupException("aigw_backup_too_large", "The backup exceeds the supported size limit.");
            }
            var sha256 = Sha256(outputBytes);
            await WriteNewFileAtomicallyAsync(outputPath, outputBytes, cancellationToken);
            return Summary(outputPath, sha256, request.IncludeSecrets, payload);
        }
        finally
        {
            if (request.IncludeSecrets)
            {
                CryptographicOperations.ZeroMemory(outputBytes);
            }
        }
    }

    public async Task<BackupSummary> InspectAsync(
        BackupInspectRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        var loaded = await LoadAsync(request.InputPath, request.Passphrase, cancellationToken);
        return Summary(loaded.Path, loaded.Sha256, loaded.Encrypted, loaded.Payload);
    }

    public async Task<BackupRestoreResult> RestoreAsync(
        BackupRestoreRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (!request.Confirmed)
        {
            throw new BackupException(
                "aigw_backup_confirmation_required",
                "Restore requires the exact confirmation token RESTORE.");
        }
        ValidateSha256(request.ExpectedSha256);
        if (request.ExpectedCurrentRevision < 0)
        {
            throw new BackupException(
                "aigw_backup_revision_invalid",
                "The expected current configuration revision must not be negative.");
        }

        var loaded = await LoadAsync(request.InputPath, request.Passphrase, cancellationToken);
        if (!loaded.Sha256.Equals(request.ExpectedSha256, StringComparison.OrdinalIgnoreCase))
        {
            throw new BackupException(
                "aigw_backup_changed",
                "The backup file no longer matches the inspected SHA-256.");
        }
        var current = await configurationStore.LoadAsync(cancellationToken);
        if (current.Revision != request.ExpectedCurrentRevision)
        {
            throw new BackupException(
                "aigw_backup_current_revision_changed",
                "The current configuration revision changed after restore was planned.");
        }

        var changedSecrets = new List<PreviousSecret>();
        try
        {
            foreach (var secret in loaded.Payload.Secrets ?? [])
            {
                var previous = await credentialStore.GetSecretAsync(secret.Target, cancellationToken);
                if (string.Equals(previous, secret.Value, StringComparison.Ordinal))
                {
                    continue;
                }
                changedSecrets.Add(new PreviousSecret(secret.Target, previous));
                await credentialStore.SetSecretAsync(secret.Target, secret.Value, cancellationToken);
            }

            var saved = await configurationStore.SaveAsync(
                loaded.Payload.Configuration,
                request.ExpectedCurrentRevision,
                cancellationToken);
            return new BackupRestoreResult(
                Summary(loaded.Path, loaded.Sha256, loaded.Encrypted, loaded.Payload),
                current.Revision,
                saved.Revision,
                changedSecrets.Count);
        }
        catch (Exception restoreFailure)
        {
            var rollbackFailures = await RollbackSecretsAsync(changedSecrets);
            if (rollbackFailures.Count > 0)
            {
                throw new BackupException(
                    "aigw_backup_restore_rollback_failed",
                    "Restore failed and one or more provider credentials could not be rolled back.",
                    new AggregateException([restoreFailure, .. rollbackFailures]));
            }
            throw;
        }
    }

    private async Task<LoadedBackup> LoadAsync(
        string inputPath,
        string? passphrase,
        CancellationToken cancellationToken)
    {
        var normalized = ValidateInputPath(inputPath);
        byte[] bytes;
        try
        {
            var info = new FileInfo(normalized);
            if (info.Length <= 0 || info.Length > BackupJson.MaximumDocumentBytes)
            {
                throw new BackupException("aigw_backup_too_large", "The backup exceeds the supported size limit.");
            }
            bytes = await File.ReadAllBytesAsync(normalized, cancellationToken);
        }
        catch (BackupException)
        {
            throw;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            throw new BackupException("aigw_backup_read_failed", "The backup file could not be read.", exception);
        }

        var sha256 = Sha256(bytes);
        var encrypted = BackupJson.IsEncryptedEnvelope(bytes);
        BackupPayloadDocument payload;
        if (encrypted)
        {
            ValidatePassphrase(includeSecrets: true, passphrase);
            var plaintext = await cryptography.DecryptAsync(bytes, passphrase!, cancellationToken);
            try
            {
                payload = BackupJson.DeserializePayload(plaintext);
            }
            finally
            {
                CryptographicOperations.ZeroMemory(plaintext);
            }
            if (!string.Equals(payload.Kind, BackupJson.EncryptedKind, StringComparison.Ordinal))
            {
                throw new BackupException("aigw_backup_format_invalid", "The encrypted backup payload kind is invalid.");
            }
        }
        else
        {
            if (passphrase is not null)
            {
                throw new BackupException(
                    "aigw_backup_passphrase_unexpected",
                    "A passphrase must not be supplied for an unencrypted backup.");
            }
            payload = BackupJson.DeserializePayload(bytes);
            if (!string.Equals(payload.Kind, BackupJson.ConfigurationKind, StringComparison.Ordinal))
            {
                throw new BackupException("aigw_backup_format_invalid", "The backup payload kind is invalid.");
            }
        }
        return new LoadedBackup(normalized, sha256, encrypted, payload);
    }

    private async Task<IReadOnlyList<Exception>> RollbackSecretsAsync(IReadOnlyList<PreviousSecret> changed)
    {
        var failures = new List<Exception>();
        for (var index = changed.Count - 1; index >= 0; index--)
        {
            try
            {
                var item = changed[index];
                if (item.Value is null)
                {
                    await credentialStore.DeleteSecretAsync(item.Target, CancellationToken.None);
                }
                else
                {
                    await credentialStore.SetSecretAsync(item.Target, item.Value, CancellationToken.None);
                }
            }
            catch (Exception exception)
            {
                failures.Add(exception);
            }
        }
        return failures;
    }

    private async Task WriteNewFileAtomicallyAsync(
        string outputPath,
        ReadOnlyMemory<byte> bytes,
        CancellationToken cancellationToken)
    {
        var temporaryPath = outputPath + $".aigw-{Guid.NewGuid():N}.tmp";
        try
        {
            await using (var stream = new FileStream(
                temporaryPath,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None,
                4096,
                FileOptions.Asynchronous | FileOptions.WriteThrough))
            {
                await stream.WriteAsync(bytes, cancellationToken);
                await stream.FlushAsync(cancellationToken);
                stream.Flush(flushToDisk: true);
            }
            fileSecurity.ProtectFile(temporaryPath);
            File.Move(temporaryPath, outputPath, overwrite: false);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            throw new BackupException(
                "aigw_backup_write_failed",
                "The backup could not be created atomically without overwriting existing content.",
                exception);
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
        }
    }

    private static BackupSummary Summary(
        string path,
        string sha256,
        bool encrypted,
        BackupPayloadDocument payload) => new(
            path,
            sha256,
            encrypted,
            payload.CreatedUtc,
            payload.Configuration.Revision,
            payload.Configuration.Profiles.Count,
            payload.Configuration.Profiles.Sum(profile => profile.Providers.Count),
            payload.Configuration.Profiles.Sum(profile => profile.Models.Count),
            payload.Secrets?.Count ?? 0);

    private static IEnumerable<string> ProviderTargets(GatewayConfiguration configuration) =>
        configuration.Profiles
            .SelectMany(profile => profile.Providers)
            .Select(provider => provider.CredentialTarget)
            .Distinct(StringComparer.Ordinal)
            .Order(StringComparer.Ordinal);

    private static void ValidatePassphrase(bool includeSecrets, string? passphrase)
    {
        if (!includeSecrets)
        {
            if (passphrase is not null)
            {
                throw new BackupException(
                    "aigw_backup_passphrase_unexpected",
                    "A passphrase is accepted only for an encrypted secrets backup.");
            }
            return;
        }
        if (passphrase is null)
        {
            throw new BackupException(
                "aigw_backup_passphrase_required",
                "The encrypted backup requires a passphrase.");
        }
        if (passphrase.Length < 12 || passphrase.Length > 1_024 ||
            System.Text.Encoding.UTF8.GetByteCount(passphrase) > 4_096)
        {
            throw new BackupException(
                "aigw_backup_passphrase_invalid",
                "The backup passphrase must contain 12 to 1024 characters and at most 4096 UTF-8 bytes.");
        }
    }

    private static void ValidateSha256(string value)
    {
        if (value.Length != 64 || value.Any(character => !Uri.IsHexDigit(character)))
        {
            throw new BackupException("aigw_backup_sha256_invalid", "The expected backup SHA-256 is malformed.");
        }
    }

    private static string ValidateOutputPath(string path)
    {
        var normalized = NormalizePath(path);
        if (File.Exists(normalized) || Directory.Exists(normalized))
        {
            throw new BackupException("aigw_backup_output_exists", "The backup output path already exists.");
        }
        ValidateParent(normalized);
        return normalized;
    }

    private static string ValidateInputPath(string path)
    {
        var normalized = NormalizePath(path);
        if (!File.Exists(normalized) ||
            (File.GetAttributes(normalized) & FileAttributes.ReparsePoint) != 0)
        {
            throw new BackupException("aigw_backup_input_invalid", "The backup input must be an existing regular file.");
        }
        ValidateParent(normalized);
        return normalized;
    }

    private static string NormalizePath(string path)
    {
        if (string.IsNullOrWhiteSpace(path) || !Path.IsPathFullyQualified(path))
        {
            throw new BackupException("aigw_backup_path_invalid", "The backup path must be fully qualified.");
        }
        var normalized = Path.GetFullPath(path);
        if (string.Equals(
            normalized.TrimEnd(Path.DirectorySeparatorChar),
            Path.GetPathRoot(normalized)?.TrimEnd(Path.DirectorySeparatorChar),
            StringComparison.OrdinalIgnoreCase))
        {
            throw new BackupException("aigw_backup_path_invalid", "The backup path must not be a volume root.");
        }
        return normalized;
    }

    private static void ValidateParent(string path)
    {
        var parent = Directory.GetParent(path) ?? throw new BackupException(
            "aigw_backup_path_invalid",
            "The backup path has no parent directory.");
        if (!parent.Exists)
        {
            throw new BackupException(
                "aigw_backup_parent_missing",
                "The backup parent directory must already exist.");
        }
        for (var current = parent; current.Parent is not null; current = current.Parent)
        {
            if ((current.Attributes & FileAttributes.ReparsePoint) != 0)
            {
                throw new BackupException(
                    "aigw_backup_path_unsafe",
                    "The backup path traverses a reparse point.");
            }
        }
    }

    private static string Sha256(ReadOnlySpan<byte> bytes) =>
        Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();

    private sealed record PreviousSecret(string Target, string? Value);
    private sealed record LoadedBackup(
        string Path,
        string Sha256,
        bool Encrypted,
        BackupPayloadDocument Payload);
}
