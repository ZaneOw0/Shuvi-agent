using System.Security.Cryptography;
using LocalAIGateway.Core.Installation;
using LocalAIGateway.Core.Runtime;
using LocalAIGateway.Core.Update;
using LocalAIGateway.Windows.Installation;
using LocalAIGateway.Windows.Runtime;
using LocalAIGateway.Windows.Update;

namespace LocalAIGateway.Windows.Tests;

public sealed class WindowsPackageUpdateServiceTests : IDisposable
{
    private readonly string root = Path.Combine(Path.GetTempPath(), $"LocalAIGateway-M5d-Update-{Guid.NewGuid():N}");
    private readonly CurrentUserInstallationTarget target;

    public WindowsPackageUpdateServiceTests()
    {
        Directory.CreateDirectory(root);
        target = CurrentUserInstallationPlan.CreateTarget(Path.Combine(root, "local-app-data"));
    }

    [Fact]
    public async Task Confirmation_is_required_before_candidate_access()
    {
        var service = await CreateServiceAsync(new RecordingHealthChecker(), new FakeDaemon(false));
        var exception = await Assert.ThrowsAsync<UpdateException>(() => service.ApplyAsync(new PackageUpdateRequest(
            Path.Combine(root, "does-not-exist"), new string('0', 64), false, true)));
        Assert.Equal("aigw_update_confirmation_required", exception.ErrorCode);
    }

    [Fact]
    public async Task Inspect_requires_explicit_unsigned_development_authorization()
    {
        var service = await CreateServiceAsync(new RecordingHealthChecker(), new FakeDaemon(false));
        var candidate = CreatePackage("candidate", "0.2.0-dev");

        var denied = await Assert.ThrowsAsync<UpdateException>(() => service.InspectAsync(candidate, false));
        Assert.Equal("aigw_update_unsigned_not_allowed", denied.ErrorCode);
        var accepted = await service.InspectAsync(candidate, true);
        Assert.Equal("0.2.0-dev", accepted.Version);
        Assert.Equal(PackageTrustKind.UnsignedDevelopment, accepted.TrustKind);
    }

    [Fact]
    public async Task Apply_atomically_switches_a_stopped_install_and_cleans_transaction_directories()
    {
        var health = new RecordingHealthChecker();
        var daemon = new FakeDaemon(false);
        var service = await CreateServiceAsync(health, daemon);
        var candidate = CreatePackage("candidate", "0.2.0-dev");
        var inspection = await service.InspectAsync(candidate, true);

        var result = await service.ApplyAsync(new PackageUpdateRequest(
            candidate, inspection.ManifestSha256, true, true));

        Assert.Equal("0.1.0-dev", result.PreviousVersion);
        Assert.Equal("0.2.0-dev", result.CurrentVersion);
        Assert.False(result.DaemonWasRunning);
        Assert.False(result.RolledBack);
        Assert.Equal("candidate", File.ReadAllText(Path.Combine(target.InstallRoot, "aigw.exe")));
        Assert.Equal(2, health.Roots.Count);
        Assert.Empty(TransactionDirectories());
    }

    [Fact]
    public async Task Running_daemon_is_stopped_and_restarted_after_switch()
    {
        var daemon = new FakeDaemon(true);
        var service = await CreateServiceAsync(new RecordingHealthChecker(), daemon);
        var candidate = CreatePackage("candidate", "0.2.0-dev");
        var inspection = await service.InspectAsync(candidate, true);

        var result = await service.ApplyAsync(new PackageUpdateRequest(
            candidate, inspection.ManifestSha256, true, true));

        Assert.True(result.DaemonWasRunning);
        Assert.True(result.DaemonRunning);
        Assert.Equal(new[] { "status", "stop", "start" }, daemon.Calls);
    }

    [Fact]
    public async Task Post_switch_health_failure_restores_old_tree_and_running_state()
    {
        var health = new RecordingHealthChecker(failCall: 2);
        var daemon = new FakeDaemon(true);
        var service = await CreateServiceAsync(health, daemon);
        var candidate = CreatePackage("candidate", "0.2.0-dev");
        var inspection = await service.InspectAsync(candidate, true);

        var exception = await Assert.ThrowsAsync<UpdateException>(() => service.ApplyAsync(new PackageUpdateRequest(
            candidate, inspection.ManifestSha256, true, true)));

        Assert.Equal("aigw_update_rolled_back", exception.ErrorCode);
        Assert.Equal("current", File.ReadAllText(Path.Combine(target.InstallRoot, "aigw.exe")));
        Assert.True(daemon.Running);
        Assert.Empty(TransactionDirectories());
    }

    [Fact]
    public async Task Pre_switch_health_failure_leaves_old_tree_and_daemon_untouched()
    {
        var daemon = new FakeDaemon(true);
        var service = await CreateServiceAsync(new RecordingHealthChecker(failCall: 1), daemon);
        var candidate = CreatePackage("candidate", "0.2.0-dev");
        var inspection = await service.InspectAsync(candidate, true);

        await Assert.ThrowsAsync<UpdateException>(() => service.ApplyAsync(new PackageUpdateRequest(
            candidate, inspection.ManifestSha256, true, true)));

        Assert.Equal("current", File.ReadAllText(Path.Combine(target.InstallRoot, "aigw.exe")));
        Assert.Empty(daemon.Calls);
        Assert.Empty(TransactionDirectories());
    }

    [Fact]
    public async Task Stale_hash_and_busy_lock_fail_before_staging()
    {
        var candidate = CreatePackage("candidate", "0.2.0-dev");
        var service = await CreateServiceAsync(new RecordingHealthChecker(), new FakeDaemon(false));
        var stale = await Assert.ThrowsAsync<UpdateException>(() => service.ApplyAsync(new PackageUpdateRequest(
            candidate, new string('f', 64), true, true)));
        Assert.Equal("aigw_update_stale_inspection", stale.ErrorCode);

        var busy = new WindowsPackageUpdateService(
            target,
            new WindowsPackageInstaller(),
            new FakeDaemon(false),
            new BusyLock(),
            new RecordingHealthChecker(),
            _ => new AlwaysValidVerifier());
        var failure = await Assert.ThrowsAsync<UpdateException>(() => busy.ApplyAsync(new PackageUpdateRequest(
            candidate, new string('0', 64), true, true)));
        Assert.Equal("aigw_install_busy", failure.ErrorCode);
        Assert.Empty(TransactionDirectories());
    }

    [Theory]
    [InlineData("0.1.0-dev")]
    [InlineData("0.0.9")]
    public async Task Inspect_rejects_a_different_package_that_is_not_newer(string version)
    {
        var service = await CreateServiceAsync(new RecordingHealthChecker(), new FakeDaemon(false));
        var candidate = CreatePackage("different", version);
        var exception = await Assert.ThrowsAsync<UpdateException>(() => service.InspectAsync(candidate, true));

        Assert.Equal("aigw_update_version_not_newer", exception.ErrorCode);
        Assert.Equal("current", File.ReadAllText(Path.Combine(target.InstallRoot, "aigw.exe")));
        Assert.Empty(TransactionDirectories());
    }

    [Fact]
    public async Task Deferred_cleanup_requires_exact_owned_rollback_path()
    {
        var service = await CreateServiceAsync(new RecordingHealthChecker(), new FakeDaemon(false));
        var candidate = CreatePackage("candidate", "0.2.0-dev");
        var inspection = await service.InspectAsync(candidate, true);
        var result = await service.ApplyAsync(new PackageUpdateRequest(
            candidate, inspection.ManifestSha256, true, true, DeferRollbackCleanup: true));

        Assert.NotNull(result.DeferredCleanupPath);
        Assert.True(Directory.Exists(result.DeferredCleanupPath));
        WindowsPackageUpdateService.CleanupDeferredRollback(target.InstallRoot, result.DeferredCleanupPath!);
        Assert.False(Directory.Exists(result.DeferredCleanupPath));
        Assert.Equal(
            "aigw_update_cleanup_path_invalid",
            Assert.Throws<UpdateException>(() => WindowsPackageUpdateService.CleanupDeferredRollback(
                target.InstallRoot, root)).ErrorCode);
    }

    private async Task<WindowsPackageUpdateService> CreateServiceAsync(IUpdateHealthChecker health, FakeDaemon daemon)
    {
        var installer = new WindowsPackageInstaller();
        await installer.InstallAsync(CreatePackage("current", "0.1.0-dev"), target.InstallRoot);
        return new WindowsPackageUpdateService(
            target,
            installer,
            daemon,
            new AvailableLock(),
            health,
            _ => new AlwaysValidVerifier());
    }

    private string CreatePackage(string payload, string version)
    {
        var package = Path.Combine(root, $"package-{Guid.NewGuid():N}");
        Directory.CreateDirectory(package);
        File.WriteAllText(Path.Combine(package, "aigw.exe"), payload);
        File.WriteAllBytes(
            Path.Combine(package, TrustedUpdateKeys.FileName),
            TrustedUpdateKeysJson.Serialize(new TrustedUpdateKeys(1, [])));
        var files = new[]
        {
            Entry(package, "aigw.exe"),
            Entry(package, TrustedUpdateKeys.FileName),
        };
        var manifestBytes = PackageManifestJson.Serialize(new PackageManifest(
            1, "LocalAIGateway", version, "win-x64", true, files));
        File.WriteAllBytes(Path.Combine(package, PackageManifest.FileName), manifestBytes);
        File.WriteAllBytes(
            Path.Combine(package, PackageSignature.FileName),
            PackageSignatureJson.Serialize(new PackageSignature(
                1, "none", null,
                Convert.ToHexStringLower(SHA256.HashData(manifestBytes)), null)));
        return package;
    }

    private string[] TransactionDirectories()
    {
        var parent = Path.GetDirectoryName(target.InstallRoot)!;
        return Directory.Exists(parent)
            ? Directory.GetDirectories(parent).Where(path =>
                Path.GetFileName(path).Contains(".updating-", StringComparison.Ordinal) ||
                Path.GetFileName(path).Contains(".rollback-", StringComparison.Ordinal) ||
                Path.GetFileName(path).Contains(".failed-", StringComparison.Ordinal)).ToArray()
            : [];
    }

    private static PackageFile Entry(string root, string relative)
    {
        var bytes = File.ReadAllBytes(Path.Combine(root, relative));
        return new(relative.Replace('\\', '/'), bytes.Length, Convert.ToHexStringLower(SHA256.HashData(bytes)));
    }

    public void Dispose()
    {
        if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
    }

    private sealed class RecordingHealthChecker(int? failCall = null) : IUpdateHealthChecker
    {
        public List<string> Roots { get; } = [];
        public Task CheckAsync(string packageRoot, CancellationToken cancellationToken = default)
        {
            Roots.Add(packageRoot);
            if (Roots.Count == failCall) throw new UpdateException("fixture_health_failed", "fixture");
            return Task.CompletedTask;
        }
    }

    private sealed class FakeDaemon(bool running) : IGatewayDaemonController
    {
        public bool Running { get; private set; } = running;
        public List<string> Calls { get; } = [];
        public Task<GatewayDaemonStatus> GetStatusAsync(CancellationToken cancellationToken = default)
        {
            Calls.Add("status");
            return Task.FromResult(Status());
        }
        public Task<GatewayDaemonOperationResult> StartAsync(CurrentUserInstallationTarget target, CancellationToken cancellationToken = default)
        {
            Calls.Add("start"); Running = true; return Task.FromResult(new GatewayDaemonOperationResult(true, Status()));
        }
        public Task<GatewayDaemonOperationResult> StopAsync(CancellationToken cancellationToken = default)
        {
            Calls.Add("stop"); var changed = Running; Running = false; return Task.FromResult(new GatewayDaemonOperationResult(changed, Status()));
        }
        public async Task<GatewayDaemonOperationResult> RestartAsync(CurrentUserInstallationTarget target, CancellationToken cancellationToken = default)
        { await StopAsync(cancellationToken); return await StartAsync(target, cancellationToken); }
        public Task<GatewayDaemonOperationResult> ReloadAsync(CancellationToken cancellationToken = default) =>
            Task.FromResult(new GatewayDaemonOperationResult(false, Status()));
        private GatewayDaemonStatus Status() => new(Running, null, null, null, false, null, []);
    }

    private sealed class AlwaysValidVerifier : IEd25519Verifier
    {
        public Task<bool> VerifyAsync(ReadOnlyMemory<byte> publicKey, ReadOnlyMemory<byte> message, ReadOnlyMemory<byte> signature, CancellationToken cancellationToken = default) => Task.FromResult(true);
    }
    private sealed class AvailableLock : ISingleInstanceProvider
    {
        public ISingleInstanceLease? TryAcquire() => new Lease();
        private sealed class Lease : ISingleInstanceLease { public void Dispose() { } }
    }
    private sealed class BusyLock : ISingleInstanceProvider { public ISingleInstanceLease? TryAcquire() => null; }
}
