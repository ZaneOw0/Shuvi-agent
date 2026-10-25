using System.Security.Cryptography;
using LocalAIGateway.Core.Installation;
using LocalAIGateway.Core.Runtime;
using LocalAIGateway.Core.Update;
using LocalAIGateway.Windows.Installation;
using LocalAIGateway.Windows.Runtime;

namespace LocalAIGateway.Windows.Update;

public interface IUpdateHealthChecker
{
    Task CheckAsync(string packageRoot, CancellationToken cancellationToken = default);
}

public sealed class WindowsPackageUpdateService : IPackageUpdateService
{
    private readonly CurrentUserInstallationTarget target;
    private readonly WindowsPackageInstaller installer;
    private readonly IGatewayDaemonController daemon;
    private readonly ISingleInstanceProvider installationLock;
    private readonly IUpdateHealthChecker healthChecker;
    private readonly Func<string, IEd25519Verifier> verifierFactory;

    public WindowsPackageUpdateService(
        CurrentUserInstallationTarget target,
        IGatewayDaemonController daemon)
        : this(
            target,
            new WindowsPackageInstaller(),
            daemon,
            new WindowsCurrentUserSingleInstanceProvider("install"),
            new ProcessUpdateHealthChecker(),
            static root => new PrivatePythonEd25519Verifier(root))
    {
    }

    internal WindowsPackageUpdateService(
        CurrentUserInstallationTarget target,
        WindowsPackageInstaller installer,
        IGatewayDaemonController daemon,
        ISingleInstanceProvider installationLock,
        IUpdateHealthChecker healthChecker,
        Func<string, IEd25519Verifier> verifierFactory)
    {
        this.target = target ?? throw new ArgumentNullException(nameof(target));
        this.installer = installer ?? throw new ArgumentNullException(nameof(installer));
        this.daemon = daemon ?? throw new ArgumentNullException(nameof(daemon));
        this.installationLock = installationLock ?? throw new ArgumentNullException(nameof(installationLock));
        this.healthChecker = healthChecker ?? throw new ArgumentNullException(nameof(healthChecker));
        this.verifierFactory = verifierFactory ?? throw new ArgumentNullException(nameof(verifierFactory));
    }

    public async Task<PackageUpdateInspection> InspectAsync(
        string packageRoot,
        bool allowUnsignedDevelopment,
        CancellationToken cancellationToken = default)
    {
        var candidateRoot = NormalizeCandidateRoot(packageRoot);
        var inspected = await InspectCoreAsync(candidateRoot, allowUnsignedDevelopment, cancellationToken);
        return inspected.Inspection;
    }

    public async Task<PackageUpdateResult> ApplyAsync(
        PackageUpdateRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (!request.Confirmed)
        {
            throw new UpdateException("aigw_update_confirmation_required", "Type UPDATE exactly before the candidate package is read.");
        }
        if (!PackageSignatureJson.IsHash(request.ExpectedManifestSha256))
        {
            throw new UpdateException("aigw_update_expected_hash_invalid", "The expected candidate manifest SHA-256 is malformed.");
        }

        using var lease = installationLock.TryAcquire()
            ?? throw new UpdateException("aigw_install_busy", "Another installation, uninstallation, or update is already in progress.");
        var candidateRoot = NormalizeCandidateRoot(request.PackageRoot);
        var candidate = await InspectCoreAsync(candidateRoot, request.AllowUnsignedDevelopment, cancellationToken);
        if (!string.Equals(candidate.Inspection.ManifestSha256, request.ExpectedManifestSha256, StringComparison.Ordinal))
        {
            throw new UpdateException("aigw_update_stale_inspection", "The candidate manifest changed after inspection.");
        }

        var current = await installer.ValidatePackageAsync(target.InstallRoot, cancellationToken);
        var currentHash = Convert.ToHexStringLower(SHA256.HashData(current.CanonicalManifest));
        if (string.Equals(currentHash, candidate.Inspection.ManifestSha256, StringComparison.Ordinal))
        {
            throw new UpdateException("aigw_update_same_package", "The candidate package is already installed.");
        }
        if (PackageVersionComparer.Compare(candidate.Inspection.Version, current.Manifest.Version) <= 0)
        {
            throw new UpdateException(
                "aigw_update_version_not_newer",
                "The candidate package version must be newer than the installed version.");
        }

        var staging = target.InstallRoot + $".updating-{Guid.NewGuid():N}";
        var rollback = target.InstallRoot + $".rollback-{Guid.NewGuid():N}";
        var failedCandidate = target.InstallRoot + $".failed-{Guid.NewGuid():N}";
        var stagingExists = false;
        var oldMoved = false;
        var newPublished = false;
        var daemonWasRunning = false;
        var phase = UpdatePhase.Staging;
        try
        {
            await installer.InstallAsync(candidateRoot, staging, cancellationToken);
            stagingExists = true;
            phase = UpdatePhase.PreSwitchHealth;
            await healthChecker.CheckAsync(staging, cancellationToken);
            cancellationToken.ThrowIfCancellationRequested();

            phase = UpdatePhase.DaemonStatus;
            daemonWasRunning = (await daemon.GetStatusAsync(cancellationToken)).Running;
            if (daemonWasRunning)
            {
                phase = UpdatePhase.DaemonStop;
                await daemon.StopAsync(cancellationToken);
            }

            // From this point the transaction must either publish the candidate or restore the old tree.
            phase = UpdatePhase.AtomicSwitch;
            Directory.Move(target.InstallRoot, rollback);
            oldMoved = true;
            Directory.Move(staging, target.InstallRoot);
            stagingExists = false;
            newPublished = true;
            phase = UpdatePhase.PostSwitchHealth;
            await healthChecker.CheckAsync(target.InstallRoot, CancellationToken.None);
            var daemonRunning = false;
            if (daemonWasRunning)
            {
                phase = UpdatePhase.DaemonStart;
                daemonRunning = (await daemon.StartAsync(target, CancellationToken.None)).Status.Running;
                if (!daemonRunning)
                {
                    throw new UpdateException("aigw_update_daemon_health_failed", "The updated daemon did not report a running state.");
                }
            }

            string? deferredCleanup = null;
            if (request.DeferRollbackCleanup)
            {
                deferredCleanup = rollback;
            }
            else
            {
                DeleteOwnedTransactionDirectory(rollback, ".rollback-");
                oldMoved = false;
            }
            return new PackageUpdateResult(
                current.Manifest.Version,
                candidate.Inspection.Version,
                candidate.Inspection.ManifestSha256,
                candidate.Inspection.TrustKind,
                candidate.Inspection.KeyId,
                daemonWasRunning,
                daemonRunning,
                false,
                deferredCleanup);
        }
        catch (Exception updateFailure) when (oldMoved)
        {
            var rollbackFailures = new List<Exception>();
            try { await daemon.StopAsync(CancellationToken.None); } catch (Exception failure) { rollbackFailures.Add(failure); }
            try
            {
                if (newPublished && Directory.Exists(target.InstallRoot))
                {
                    Directory.Move(target.InstallRoot, failedCandidate);
                    newPublished = false;
                }
                Directory.Move(rollback, target.InstallRoot);
                oldMoved = false;
            }
            catch (Exception failure) { rollbackFailures.Add(failure); }
            if (!oldMoved && daemonWasRunning)
            {
                try { await daemon.StartAsync(target, CancellationToken.None); }
                catch (Exception failure) { rollbackFailures.Add(failure); }
            }
            if (Directory.Exists(failedCandidate))
            {
                try { DeleteOwnedTransactionDirectory(failedCandidate, ".failed-"); }
                catch (Exception failure) { rollbackFailures.Add(failure); }
            }
            if (rollbackFailures.Count != 0)
            {
                throw new UpdateException(
                    "aigw_update_rollback_failed",
                    "The update failed and the previous installation could not be completely restored.",
                    new AggregateException(new[] { updateFailure }.Concat(rollbackFailures)));
            }
            throw new UpdateException(
                "aigw_update_rolled_back",
                "The candidate failed its post-switch health check; the previous installation was restored.",
                updateFailure);
        }
        catch (UpdateException)
        {
            throw;
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception exception)
        {
            throw PhaseFailure(phase, exception);
        }
        finally
        {
            if (stagingExists && Directory.Exists(staging))
            {
                try { DeleteOwnedTransactionDirectory(staging, ".updating-"); }
                catch when (oldMoved || newPublished) { }
            }
        }
    }

    public static void CleanupDeferredRollback(string installRoot, string cleanupPath)
    {
        var normalizedInstall = NormalizeNonRoot(installRoot, "install root");
        var normalizedCleanup = NormalizeNonRoot(cleanupPath, "cleanup path");
        var expectedPrefix = normalizedInstall + ".rollback-";
        if (!normalizedCleanup.StartsWith(expectedPrefix, StringComparison.OrdinalIgnoreCase) ||
            normalizedCleanup.Length != expectedPrefix.Length + 32 ||
            !Guid.TryParseExact(normalizedCleanup[^32..], "N", out _))
        {
            throw new UpdateException("aigw_update_cleanup_path_invalid", "The deferred rollback path is not owned by this update transaction.");
        }
        DeleteOwnedTransactionDirectory(normalizedCleanup, ".rollback-");
    }

    private async Task<(PackageUpdateInspection Inspection, ValidatedPackage Package)> InspectCoreAsync(
        string candidateRoot,
        bool allowUnsignedDevelopment,
        CancellationToken cancellationToken)
    {
        var current = await installer.ValidatePackageAsync(target.InstallRoot, cancellationToken);
        var candidate = await installer.ValidatePackageAsync(candidateRoot, cancellationToken);
        if (PackageVersionComparer.Compare(candidate.Manifest.Version, current.Manifest.Version) <= 0)
        {
            throw new UpdateException(
                "aigw_update_version_not_newer",
                "The candidate package version must be newer than the installed version.");
        }
        var signature = candidate.Signature
            ?? throw new UpdateException("aigw_update_signature_missing", "The candidate package has no signature metadata.");
        var trustPath = Path.Combine(target.InstallRoot, TrustedUpdateKeys.FileName);
        if (!File.Exists(trustPath) || IsReparse(trustPath) || new FileInfo(trustPath).Length > TrustedUpdateKeysJson.MaximumBytes)
        {
            throw new UpdateException("aigw_update_trust_store_invalid", "The installed trusted update key store is missing or unsafe.");
        }
        var trustBytes = await File.ReadAllBytesAsync(trustPath, cancellationToken);
        var trustedKeys = TrustedUpdateKeysJson.Deserialize(trustBytes);
        if (!trustBytes.AsSpan().SequenceEqual(TrustedUpdateKeysJson.Serialize(trustedKeys)))
        {
            throw new UpdateException("aigw_update_trust_store_invalid", "The installed trusted update key store is not canonical.");
        }
        var policy = new PackageSignaturePolicy(verifierFactory(target.InstallRoot));
        var trust = await policy.VerifyAsync(
            candidate.Manifest,
            candidate.CanonicalManifest,
            signature,
            trustedKeys,
            allowUnsignedDevelopment,
            cancellationToken);
        var hash = Convert.ToHexStringLower(SHA256.HashData(candidate.CanonicalManifest));
        return (new PackageUpdateInspection(
            candidateRoot,
            candidate.Manifest.Version,
            hash,
            trust.TrustKind,
            trust.KeyId,
            candidate.Manifest.Files.Count,
            current.Manifest.Version), candidate);
    }

    private string NormalizeCandidateRoot(string path)
    {
        var candidate = NormalizeNonRoot(path, "candidate package");
        if (Overlaps(candidate, target.InstallRoot) || Overlaps(candidate, target.StateRoot))
        {
            throw new UpdateException("aigw_update_path_overlap", "The candidate package must not overlap program or state roots.");
        }
        return candidate;
    }

    private static void DeleteOwnedTransactionDirectory(string path, string marker)
    {
        var name = Path.GetFileName(path);
        var markerIndex = name.LastIndexOf(marker, StringComparison.OrdinalIgnoreCase);
        if (markerIndex <= 0 || name.Length != markerIndex + marker.Length + 32 ||
            !Guid.TryParseExact(name[^32..], "N", out _))
        {
            throw new UpdateException("aigw_update_cleanup_path_invalid", "Refusing to delete a directory not owned by an update transaction.");
        }
        if (Directory.Exists(path)) Directory.Delete(path, recursive: true);
    }

    private static string NormalizeNonRoot(string path, string label)
    {
        if (string.IsNullOrWhiteSpace(path) || !Path.IsPathFullyQualified(path))
            throw new UpdateException("aigw_update_path_invalid", $"The {label} must be an absolute path.");
        var resolved = Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var root = Path.GetPathRoot(resolved)?.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        if (string.IsNullOrEmpty(resolved) || string.Equals(resolved, root, StringComparison.OrdinalIgnoreCase))
            throw new UpdateException("aigw_update_path_invalid", $"The {label} must not be a volume root.");
        return resolved;
    }

    private static bool Overlaps(string left, string right) =>
        string.Equals(left, right, StringComparison.OrdinalIgnoreCase) ||
        left.StartsWith(right + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) ||
        right.StartsWith(left + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);

    private static bool IsReparse(string path) =>
        (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0;

    private static UpdateException PhaseFailure(UpdatePhase phase, Exception inner) => phase switch
    {
        UpdatePhase.Staging => new(
            "aigw_update_staging_failed", "The candidate package could not be staged.", inner),
        UpdatePhase.PreSwitchHealth => new(
            "aigw_update_health_failed", "The candidate side-load health check failed.", inner),
        UpdatePhase.DaemonStatus => new(
            "aigw_update_daemon_status_failed", "The daemon state could not be read before update.", inner),
        UpdatePhase.DaemonStop => new(
            "aigw_update_daemon_stop_failed", "The daemon could not be stopped before update.", inner),
        UpdatePhase.AtomicSwitch => new(
            "aigw_update_switch_failed", "Windows could not begin the atomic installation switch.", inner),
        UpdatePhase.PostSwitchHealth or UpdatePhase.DaemonStart => new(
            "aigw_update_rollback_failed", "The update failed after the switch and rollback did not complete.", inner),
        _ => new("aigw_update_failed", "The update failed.", inner),
    };

    private enum UpdatePhase
    {
        Staging,
        PreSwitchHealth,
        DaemonStatus,
        DaemonStop,
        AtomicSwitch,
        PostSwitchHealth,
        DaemonStart,
    }
}
