using System.Security.Cryptography;

namespace LocalAIGateway.Core.Backup;

public sealed record BackupFileInspection(string Path, string Sha256, bool Encrypted);

public sealed record DeletedBackupFile(string Path, string Sha256, bool Encrypted);

public sealed record BackupFileCleanupResult(
    IReadOnlyList<DeletedBackupFile> DeletedFiles,
    bool AlreadyAbsent);

public sealed class BackupFileCleaner
{
    public async Task<BackupFileCleanupResult> DeleteAsync(
        IReadOnlyList<string> paths,
        CancellationToken cancellationToken = default)
    {
        var inspected = await InspectAsync(paths, cancellationToken);
        return await DeleteInspectedAsync(inspected, cancellationToken);
    }

    public async Task<IReadOnlyList<BackupFileInspection>> InspectAsync(
        IReadOnlyList<string> paths,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(paths);
        if (paths.Count == 0)
        {
            return [];
        }

        var normalized = paths.Select(ValidatePath).ToArray();
        if (normalized.Distinct(StringComparer.OrdinalIgnoreCase).Count() != normalized.Length)
        {
            throw new BackupException(
                "aigw_backup_path_duplicate",
                "The uninstall backup list contains a duplicate path.");
        }

        var inspected = new List<BackupFileInspection>();
        foreach (var path in normalized)
        {
            var loaded = await LoadAsync(path, cancellationToken);
            inspected.Add(new BackupFileInspection(loaded.Path, loaded.Sha256, loaded.Encrypted));
        }
        return inspected;
    }

    public async Task<BackupFileCleanupResult> DeleteInspectedAsync(
        IReadOnlyList<BackupFileInspection> inspected,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(inspected);
        if (inspected.Count == 0)
        {
            return new BackupFileCleanupResult([], true);
        }
        cancellationToken.ThrowIfCancellationRequested();
        var deleted = new List<DeletedBackupFile>();
        foreach (var expected in inspected)
        {
            var current = await LoadAsync(expected.Path, CancellationToken.None);
            if (!current.Sha256.Equals(expected.Sha256, StringComparison.Ordinal))
            {
                throw new BackupException(
                    "aigw_backup_changed",
                    "A selected backup changed after uninstall preflight; it was preserved.");
            }

            File.Delete(expected.Path);
            deleted.Add(new DeletedBackupFile(expected.Path, expected.Sha256, expected.Encrypted));
        }

        return new BackupFileCleanupResult(deleted, false);
    }

    private static async Task<LoadedBackupFile> LoadAsync(
        string path,
        CancellationToken cancellationToken)
    {
        byte[] bytes;
        try
        {
            var info = new FileInfo(path);
            if (!info.Exists || info.Length == 0 || info.Length > BackupJson.MaximumDocumentBytes)
            {
                throw new BackupException(
                    "aigw_backup_input_invalid",
                    "A selected backup must be an existing bounded regular file.");
            }
            bytes = await File.ReadAllBytesAsync(path, cancellationToken);
        }
        catch (BackupException)
        {
            throw;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            throw new BackupException(
                "aigw_backup_read_failed",
                "A selected backup could not be read during uninstall preflight.",
                exception);
        }

        var encrypted = BackupJson.IsEncryptedEnvelope(bytes);
        if (encrypted)
        {
            BackupJson.ValidateEncryptedEnvelope(bytes);
        }
        else
        {
            BackupJson.DeserializePayload(bytes);
        }
        return new LoadedBackupFile(
            path,
            Convert.ToHexStringLower(SHA256.HashData(bytes)),
            encrypted);
    }

    private static string ValidatePath(string path)
    {
        if (string.IsNullOrWhiteSpace(path) || !Path.IsPathFullyQualified(path))
        {
            throw new BackupException(
                "aigw_backup_path_invalid",
                "Every uninstall backup path must be fully qualified.");
        }
        var normalized = Path.GetFullPath(path);
        if (!File.Exists(normalized) || Directory.Exists(normalized) ||
            (File.GetAttributes(normalized) & FileAttributes.ReparsePoint) != 0)
        {
            throw new BackupException(
                "aigw_backup_input_invalid",
                "Every selected backup must be an existing regular file.");
        }

        for (var parent = Directory.GetParent(normalized); parent is not null; parent = parent.Parent)
        {
            if ((parent.Attributes & FileAttributes.ReparsePoint) != 0)
            {
                throw new BackupException(
                    "aigw_backup_path_unsafe",
                    "A selected backup path traverses a reparse point.");
            }
        }
        return normalized;
    }

    private sealed record LoadedBackupFile(string Path, string Sha256, bool Encrypted);
}
