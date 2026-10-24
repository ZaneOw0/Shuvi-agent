namespace LocalAIGateway.Launcher;

public sealed class ClientIntegrationLifecycleManager : IClientIntegrationLifecycleManager
{
    private readonly Action<string, string, string> replaceFile;
    private readonly Action<string, string> moveFile;

    public ClientIntegrationLifecycleManager()
        : this(
            static (source, destination, backup) =>
                File.Replace(source, destination, backup, ignoreMetadataErrors: false),
            static (source, destination) => File.Move(source, destination))
    {
    }

    internal ClientIntegrationLifecycleManager(
        Action<string, string, string> replaceFile,
        Action<string, string> moveFile)
    {
        ArgumentNullException.ThrowIfNull(replaceFile);
        ArgumentNullException.ThrowIfNull(moveFile);
        this.replaceFile = replaceFile;
        this.moveFile = moveFile;
    }

    public async Task<ClientIntegrationStatusResult> GetStatusAsync(
        ClientIntegrationStatusRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        var targetPath = ClientIntegrationApplier.NormalizeTarget(request.TargetPath);
        ClientIntegrationPreviewer.ValidateTargetFileName(request.Client, targetPath);
        ClientIntegrationApplier.ValidatePathBoundary(targetPath);
        cancellationToken.ThrowIfCancellationRequested();
        return (await ReadStatusAsync(request.Client, targetPath, cancellationToken)).Status;
    }

    public async Task<ClientIntegrationUnintegrateResult> UnintegrateAsync(
        ClientIntegrationUnintegrateRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        ValidateRequest(request);
        var targetPath = ClientIntegrationApplier.NormalizeTarget(request.TargetPath);
        ClientIntegrationPreviewer.ValidateTargetFileName(request.Client, targetPath);
        ClientIntegrationApplier.ValidatePathBoundary(targetPath);
        cancellationToken.ThrowIfCancellationRequested();

        var initial = await ReadStatusAsync(request.Client, targetPath, cancellationToken);
        var status = initial.Status;
        ValidateConfirmedPlan(request, status);

        var temporaryPath = status.Action == ClientIntegrationRemovalAction.Update
            ? Path.Combine(
                Path.GetDirectoryName(targetPath)!,
                $".{Path.GetFileName(targetPath)}.aigw-write-{Guid.NewGuid():N}.tmp")
            : null;
        string? backupPath = null;
        try
        {
            if (status.Action == ClientIntegrationRemovalAction.Update)
            {
                await ClientIntegrationApplier.WriteTemporaryAsync(
                    temporaryPath!,
                    status.ProposedContent!,
                    initial.Loaded!.HasUtf8Bom,
                    cancellationToken);
            }

            // Cancellation is observed before mutation. Once mutation starts, finish or preserve recovery state.
            cancellationToken.ThrowIfCancellationRequested();
            ClientIntegrationApplier.ValidatePathBoundary(targetPath);
            var current = await ReadStatusAsync(request.Client, targetPath, CancellationToken.None);
            ValidateConfirmedPlan(request, current.Status);

            backupPath = ClientIntegrationApplier.UniqueBackupPath(targetPath);
            if (status.Action == ClientIntegrationRemovalAction.Update)
            {
                replaceFile(temporaryPath!, targetPath, backupPath);
                await ClientIntegrationApplier.ValidateAtomicBackupAsync(
                    targetPath,
                    backupPath,
                    request.ExpectedBeforeSha256,
                    request.ExpectedAfterSha256!);
                var written = await ClientIntegrationApplier.ReadTargetAsync(
                    targetPath,
                    CancellationToken.None);
                if (!string.Equals(
                        ClientIntegrationApplier.Sha256(written.Content),
                        request.ExpectedAfterSha256,
                        StringComparison.OrdinalIgnoreCase))
                {
                    throw ClientIntegrationApplier.FileFailure(
                        "The unintegrated target could not be verified after the atomic write. The backup was preserved.");
                }
            }
            else
            {
                moveFile(targetPath, backupPath);
                await ValidateDeletedBackupAsync(
                    targetPath,
                    backupPath,
                    request.ExpectedBeforeSha256);
            }

            return new ClientIntegrationUnintegrateResult(
                request.Client,
                targetPath,
                status.Action,
                Applied: true,
                backupPath,
                request.ExpectedBeforeSha256.ToLowerInvariant(),
                request.ExpectDelete ? null : request.ExpectedAfterSha256!.ToLowerInvariant());
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
            throw ClientIntegrationApplier.FileFailure(
                backupPath is null || !File.Exists(backupPath)
                    ? "The unintegration file transaction failed before a verified backup was created."
                    : $"The unintegration file transaction failed. Recovery backup: {backupPath}",
                exception);
        }
        finally
        {
            if (temporaryPath is not null)
            {
                ClientIntegrationApplier.DeleteTemporaryOrThrow(temporaryPath);
            }
        }
    }

    private static async Task<(ClientIntegrationStatusResult Status, ClientIntegrationApplier.LoadedText? Loaded)>
        ReadStatusAsync(
            ClientIntegrationKind client,
            string targetPath,
            CancellationToken cancellationToken)
    {
        if (Directory.Exists(targetPath))
        {
            throw ClientIntegrationApplier.FileFailure("The integration target is a directory, not a file.");
        }
        if (!File.Exists(targetPath))
        {
            return (new ClientIntegrationStatusResult(
                client,
                targetPath,
                ClientIntegrationStatusKind.Absent,
                ClientIntegrationRemovalAction.None,
                null,
                null,
                null,
                null), null);
        }

        var loaded = await ClientIntegrationApplier.ReadTargetAsync(targetPath, cancellationToken);
        return (ClientIntegrationPreviewer.PlanUnintegration(client, targetPath, loaded.Content), loaded);
    }

    private static void ValidateRequest(ClientIntegrationUnintegrateRequest request)
    {
        if (!request.Confirmed)
        {
            throw new ClientIntegrationException(
                "aigw_integration_confirmation_required",
                "Unintegration requires the exact confirmation value UNINTEGRATE before any target is read.");
        }
        if (!ClientIntegrationApplier.IsSha256(request.ExpectedBeforeSha256) ||
            (request.ExpectDelete && request.ExpectedAfterSha256 is not null) ||
            (!request.ExpectDelete && !ClientIntegrationApplier.IsSha256(request.ExpectedAfterSha256)))
        {
            throw new ClientIntegrationException(
                "aigw_integration_request_invalid",
                "Unintegration requires the status before SHA-256 and exactly one after SHA-256 or delete expectation.");
        }
    }

    private static void ValidateConfirmedPlan(
        ClientIntegrationUnintegrateRequest request,
        ClientIntegrationStatusResult status)
    {
        if (status.Status != ClientIntegrationStatusKind.Owned)
        {
            throw new ClientIntegrationException(
                "aigw_integration_not_owned",
                "The integration target is absent or is not owned by Local AI Gateway; no files were modified.");
        }
        if (!string.Equals(
                status.BeforeSha256,
                request.ExpectedBeforeSha256,
                StringComparison.OrdinalIgnoreCase) ||
            (request.ExpectDelete && status.Action != ClientIntegrationRemovalAction.Delete) ||
            (!request.ExpectDelete && status.Action != ClientIntegrationRemovalAction.Update) ||
            (!request.ExpectDelete && !string.Equals(
                status.AfterSha256,
                request.ExpectedAfterSha256,
                StringComparison.OrdinalIgnoreCase)))
        {
            throw ClientIntegrationApplier.Stale(
                "The unintegration target or removal plan changed after status; no files were modified.");
        }
    }

    private void RestoreMovedTarget(string targetPath, string backupPath)
    {
        if (File.Exists(targetPath) || Directory.Exists(targetPath))
        {
            throw ClientIntegrationApplier.FileFailure(
                $"The target changed during deletion and automatic rollback was blocked. Recovery backup: {backupPath}");
        }
        moveFile(backupPath, targetPath);
    }

    private async Task ValidateDeletedBackupAsync(
        string targetPath,
        string backupPath,
        string expectedBeforeSha256)
    {
        try
        {
            var backup = await ClientIntegrationApplier.ReadTargetAsync(
                backupPath,
                CancellationToken.None);
            if (!string.Equals(
                    ClientIntegrationApplier.Sha256(backup.Content),
                    expectedBeforeSha256,
                    StringComparison.OrdinalIgnoreCase))
            {
                RestoreMovedTarget(targetPath, backupPath);
                var restored = await ClientIntegrationApplier.ReadTargetAsync(
                    targetPath,
                    CancellationToken.None);
                if (!string.Equals(
                        ClientIntegrationApplier.Sha256(restored.Content),
                        ClientIntegrationApplier.Sha256(backup.Content),
                        StringComparison.OrdinalIgnoreCase))
                {
                    throw ClientIntegrationApplier.FileFailure(
                        "The target changed during deletion and automatic rollback could not be verified.");
                }
                throw ClientIntegrationApplier.Stale(
                    "The integration target changed during atomic deletion and was restored; retry from status.");
            }
            if (File.Exists(targetPath) || Directory.Exists(targetPath))
            {
                throw ClientIntegrationApplier.FileFailure(
                    $"The integration target reappeared after deletion. Recovery backup: {backupPath}");
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
            throw ClientIntegrationApplier.FileFailure(
                $"The deleted integration target could not be verified. Recovery backup: {backupPath}",
                exception);
        }
    }
}
