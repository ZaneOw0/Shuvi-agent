using System.Security.Cryptography;
using System.Text;

namespace LocalAIGateway.Launcher;

public sealed class ClientIntegrationApplier : IClientIntegrationApplier
{
    private const long MaximumSourceBytes = ClientIntegrationPreviewer.MaximumSourceCharacters * 4L + 3;
    private static readonly UTF8Encoding StrictUtf8 = new(
        encoderShouldEmitUTF8Identifier: false,
        throwOnInvalidBytes: true);
    private static readonly byte[] Utf8Preamble = [0xEF, 0xBB, 0xBF];

    private readonly IClientIntegrationPreviewer previewer;
    private readonly Action<string, string, string> replaceFile;
    private readonly Action<string, string> moveFile;

    public ClientIntegrationApplier(IClientIntegrationPreviewer previewer)
        : this(
            previewer,
            static (source, destination, backup) =>
                File.Replace(source, destination, backup, ignoreMetadataErrors: false),
            static (source, destination) => File.Move(source, destination))
    {
    }

    internal ClientIntegrationApplier(
        IClientIntegrationPreviewer previewer,
        Action<string, string, string> replaceFile,
        Action<string, string> moveFile)
    {
        ArgumentNullException.ThrowIfNull(previewer);
        ArgumentNullException.ThrowIfNull(replaceFile);
        ArgumentNullException.ThrowIfNull(moveFile);
        this.previewer = previewer;
        this.replaceFile = replaceFile;
        this.moveFile = moveFile;
    }

    public async Task<ClientIntegrationApplyResult> ApplyAsync(
        ClientIntegrationApplyRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        ValidateRequest(request);
        var targetPath = NormalizeTarget(request.TargetPath);
        ValidatePathBoundary(targetPath);
        cancellationToken.ThrowIfCancellationRequested();

        var existed = File.Exists(targetPath);
        if (request.ExpectAbsent == existed)
        {
            throw Stale(existed
                ? "The integration target now exists but the preview expected it to be absent."
                : "The integration target is now absent but the preview expected existing content.");
        }

        var loaded = existed
            ? await ReadTargetAsync(targetPath, cancellationToken)
            : null;
        var beforeSha256 = loaded is null ? null : Sha256(loaded.Content);
        if (!request.ExpectAbsent &&
            !string.Equals(beforeSha256, request.ExpectedBeforeSha256, StringComparison.OrdinalIgnoreCase))
        {
            throw Stale("The integration target changed after preview; no files were modified.");
        }

        var preview = previewer.Preview(new ClientIntegrationPreviewRequest(
            request.Client,
            targetPath,
            loaded?.Content,
            request.ClientVersion,
            request.HostVersion,
            request.WrapperExecutablePath));
        if (!string.Equals(preview.AfterSha256, request.ExpectedAfterSha256, StringComparison.OrdinalIgnoreCase))
        {
            throw Stale("The proposed integration no longer matches the confirmed preview; no files were modified.");
        }

        if (preview.Action == ClientIntegrationAction.Unchanged)
        {
            return Result(preview, applied: false, backupPath: null);
        }

        var directory = Path.GetDirectoryName(targetPath)!;
        var temporaryPath = Path.Combine(directory, $".{Path.GetFileName(targetPath)}.aigw-write-{Guid.NewGuid():N}.tmp");
        string? backupPath = null;
        try
        {
            await WriteTemporaryAsync(
                temporaryPath,
                preview.ProposedContent,
                loaded?.HasUtf8Bom == true,
                cancellationToken);

            // Cancellation is observed before mutation. Once replacement starts, complete the transaction.
            cancellationToken.ThrowIfCancellationRequested();
            ValidatePathBoundary(targetPath);
            await AssertStillCurrentAsync(targetPath, request, CancellationToken.None);

            if (existed)
            {
                backupPath = UniqueBackupPath(targetPath);
                replaceFile(temporaryPath, targetPath, backupPath);
                await ValidateAtomicBackupAsync(
                    targetPath,
                    backupPath,
                    request.ExpectedBeforeSha256!,
                    preview.AfterSha256);
            }
            else
            {
                moveFile(temporaryPath, targetPath);
            }

            var written = await ReadTargetAsync(targetPath, CancellationToken.None);
            if (!string.Equals(Sha256(written.Content), preview.AfterSha256, StringComparison.OrdinalIgnoreCase))
            {
                throw FileFailure(
                    "The integration target could not be verified after the atomic write. The backup was preserved.");
            }

            return Result(preview, applied: true, backupPath);
        }
        catch (ClientIntegrationException)
        {
            throw;
        }
        catch (ClientIntegrationFileException)
        {
            throw;
        }
        catch (Exception exception) when (exception is
            IOException or UnauthorizedAccessException or NotSupportedException)
        {
            throw FileFailure(
                backupPath is null || !File.Exists(backupPath)
                    ? "The integration file transaction failed before a verified backup was created."
                    : $"The integration file transaction failed. Recovery backup: {backupPath}",
                exception);
        }
        finally
        {
            DeleteTemporaryOrThrow(temporaryPath);
        }
    }

    private static ClientIntegrationApplyResult Result(
        ClientIntegrationPreviewResult preview,
        bool applied,
        string? backupPath) => new(
            preview.Client,
            preview.TargetPath,
            preview.Action,
            applied,
            backupPath,
            preview.BeforeSha256,
            preview.AfterSha256);

    private static void ValidateRequest(ClientIntegrationApplyRequest request)
    {
        if (!request.Confirmed)
        {
            throw new ClientIntegrationException(
                "aigw_integration_confirmation_required",
                "Integration apply requires the exact confirmation value APPLY before any target is read.");
        }
        if (!IsSha256(request.ExpectedAfterSha256) ||
            (request.ExpectAbsent && request.ExpectedBeforeSha256 is not null) ||
            (!request.ExpectAbsent && !IsSha256(request.ExpectedBeforeSha256)))
        {
            throw new ClientIntegrationException(
                "aigw_integration_request_invalid",
                "Apply requires an expected after SHA-256 and exactly one existing-content hash or absent expectation.");
        }
    }

    internal static string NormalizeTarget(string targetPath)
    {
        try
        {
            if (string.IsNullOrWhiteSpace(targetPath) ||
                !Path.IsPathFullyQualified(targetPath) ||
                targetPath.Any(char.IsControl))
            {
                throw new ArgumentException("Target path is not fully qualified.");
            }
            return Path.GetFullPath(targetPath);
        }
        catch (Exception exception) when (exception is ArgumentException or NotSupportedException)
        {
            throw new ClientIntegrationException(
                "aigw_integration_request_invalid",
                "The integration target must be a valid fully qualified path.",
                exception);
        }
    }

    internal static void ValidatePathBoundary(string targetPath)
    {
        try
        {
            var directoryPath = Path.GetDirectoryName(targetPath);
            if (string.IsNullOrWhiteSpace(directoryPath) || !Directory.Exists(directoryPath))
            {
                throw FileFailure("The integration target directory must already exist.");
            }

            for (var directory = new DirectoryInfo(directoryPath); directory is not null; directory = directory.Parent)
            {
                if ((directory.Attributes & FileAttributes.ReparsePoint) != 0)
                {
                    throw new ClientIntegrationException(
                        "aigw_integration_path_unsafe",
                        "The integration target path must not traverse a reparse point.");
                }
            }

            if (File.Exists(targetPath) &&
                (File.GetAttributes(targetPath) & FileAttributes.ReparsePoint) != 0)
            {
                throw new ClientIntegrationException(
                    "aigw_integration_path_unsafe",
                    "The integration target must not be a reparse point.");
            }
        }
        catch (ClientIntegrationException)
        {
            throw;
        }
        catch (ClientIntegrationFileException)
        {
            throw;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            throw FileFailure("The integration target path could not be safely inspected.", exception);
        }
    }

    internal static async Task<LoadedText> ReadTargetAsync(
        string path,
        CancellationToken cancellationToken)
    {
        try
        {
            var bytes = await ReadBoundedBytesAsync(path, cancellationToken);
            var hasBom = bytes.AsSpan().StartsWith(Utf8Preamble);
            var content = StrictUtf8.GetString(bytes.AsSpan(hasBom ? Utf8Preamble.Length : 0));
            if (content.Length > ClientIntegrationPreviewer.MaximumSourceCharacters)
            {
                throw new ClientIntegrationException(
                    "aigw_integration_source_invalid",
                    "The integration target exceeds the supported text size limit.");
            }
            return new LoadedText(content, hasBom);
        }
        catch (ClientIntegrationException)
        {
            throw;
        }
        catch (DecoderFallbackException exception)
        {
            throw new ClientIntegrationException(
                "aigw_integration_source_invalid",
                "The integration target must be valid UTF-8 text.",
                exception);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            throw FileFailure("The integration target could not be read safely.", exception);
        }
    }

    private static async Task<byte[]> ReadBoundedBytesAsync(
        string path,
        CancellationToken cancellationToken)
    {
        await using var input = new FileStream(
            path,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read,
            4096,
            FileOptions.Asynchronous | FileOptions.SequentialScan);
        var length = input.Length;
        if (length > MaximumSourceBytes)
        {
            throw new ClientIntegrationException(
                "aigw_integration_source_invalid",
                "The integration target exceeds the supported text size limit.");
        }

        var bytes = new byte[checked((int)length)];
        await input.ReadExactlyAsync(bytes, cancellationToken);
        if (input.Length != length)
        {
            throw Stale("The integration target changed while it was being read; no files were modified.");
        }
        return bytes;
    }

    internal static async Task WriteTemporaryAsync(
        string path,
        string content,
        bool includeUtf8Bom,
        CancellationToken cancellationToken)
    {
        var contentBytes = StrictUtf8.GetBytes(content);
        await using var output = new FileStream(
            path,
            FileMode.CreateNew,
            FileAccess.Write,
            FileShare.None,
            4096,
            FileOptions.Asynchronous | FileOptions.WriteThrough);
        if (includeUtf8Bom)
        {
            await output.WriteAsync(Utf8Preamble, cancellationToken);
        }
        await output.WriteAsync(contentBytes, cancellationToken);
        await output.FlushAsync(cancellationToken);
        output.Flush(flushToDisk: true);
    }

    private static async Task AssertStillCurrentAsync(
        string targetPath,
        ClientIntegrationApplyRequest request,
        CancellationToken cancellationToken)
    {
        var exists = File.Exists(targetPath);
        if (request.ExpectAbsent)
        {
            if (exists)
            {
                throw Stale("The integration target appeared during apply; no files were modified.");
            }
            return;
        }

        if (!exists)
        {
            throw Stale("The integration target disappeared during apply; no files were modified.");
        }
        var current = await ReadTargetAsync(targetPath, cancellationToken);
        if (!string.Equals(Sha256(current.Content), request.ExpectedBeforeSha256, StringComparison.OrdinalIgnoreCase))
        {
            throw Stale("The integration target changed during apply; no files were modified.");
        }
    }

    internal static async Task ValidateAtomicBackupAsync(
        string targetPath,
        string backupPath,
        string expectedBeforeSha256,
        string expectedAfterSha256)
    {
        var backup = await ReadTargetAsync(backupPath, CancellationToken.None);
        if (string.Equals(Sha256(backup.Content), expectedBeforeSha256, StringComparison.OrdinalIgnoreCase))
        {
            return;
        }

        var rejectedPath = targetPath + $".aigw-rejected-{Guid.NewGuid():N}.tmp";
        try
        {
            File.Replace(backupPath, targetPath, rejectedPath, ignoreMetadataErrors: false);
            var restored = await ReadTargetAsync(targetPath, CancellationToken.None);
            if (!string.Equals(Sha256(restored.Content), Sha256(backup.Content), StringComparison.OrdinalIgnoreCase))
            {
                throw FileFailure("The target changed during replacement and automatic rollback could not be verified.");
            }
            if (File.Exists(rejectedPath))
            {
                var rejected = await ReadTargetAsync(rejectedPath, CancellationToken.None);
                if (!string.Equals(Sha256(rejected.Content), expectedAfterSha256, StringComparison.OrdinalIgnoreCase))
                {
                    throw FileFailure($"Automatic rollback preserved an unexpected file at {rejectedPath}.");
                }
                File.Delete(rejectedPath);
            }
        }
        catch (ClientIntegrationFileException)
        {
            throw;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            throw FileFailure(
                $"The target changed during replacement and automatic rollback failed. Recovery file: {backupPath}",
                exception);
        }

        throw Stale("The integration target changed during atomic replacement and was restored; retry from preview.");
    }

    internal static string UniqueBackupPath(string targetPath)
    {
        for (var attempt = 0; attempt < 8; attempt++)
        {
            var candidate = targetPath + $".aigw-backup-{Guid.NewGuid():N}.bak";
            if (!File.Exists(candidate) && !Directory.Exists(candidate))
            {
                return candidate;
            }
        }
        throw FileFailure("A unique integration backup path could not be allocated.");
    }

    internal static void DeleteTemporaryOrThrow(string temporaryPath)
    {
        if (!File.Exists(temporaryPath))
        {
            return;
        }
        try
        {
            File.Delete(temporaryPath);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            throw FileFailure($"Integration temporary-file cleanup failed: {temporaryPath}", exception);
        }
    }

    internal static bool IsSha256(string? value) =>
        value?.Length == 64 && value.All(Uri.IsHexDigit);

    internal static string Sha256(string content) =>
        Convert.ToHexString(SHA256.HashData(StrictUtf8.GetBytes(content))).ToLowerInvariant();

    internal static ClientIntegrationException Stale(string message) => new(
        "aigw_integration_stale_preview",
        message);

    internal static ClientIntegrationFileException FileFailure(
        string message,
        Exception? innerException = null) => new(
            "aigw_integration_file_failed",
            message,
            innerException);

    internal sealed record LoadedText(string Content, bool HasUtf8Bom);
}
