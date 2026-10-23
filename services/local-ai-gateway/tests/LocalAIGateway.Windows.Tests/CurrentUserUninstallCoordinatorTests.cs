using System.Security.Cryptography;
using LocalAIGateway.Core.Configuration;
using LocalAIGateway.Core.Control;
using LocalAIGateway.Core.Credentials;
using LocalAIGateway.Core.Installation;
using LocalAIGateway.Core.Runtime;
using LocalAIGateway.Core.Uninstall;
using LocalAIGateway.Windows.Installation;
using LocalAIGateway.Windows.Runtime;
using LocalAIGateway.Windows.Uninstall;

namespace LocalAIGateway.Windows.Tests;

public sealed class CurrentUserUninstallCoordinatorTests : IDisposable
{
    private readonly string root = Path.Combine(
        Path.GetTempPath(),
        $"LocalAIGateway-CompleteUninstall-{Guid.NewGuid():N}");

    [Fact]
    public async Task Selected_platform_categories_stop_daemon_and_remove_owned_state()
    {
        var target = CurrentUserInstallationPlan.CreateTarget(Path.Combine(root, "local-app-data"));
        await InstallPackageAsync(target.InstallRoot);
        Directory.CreateDirectory(target.StateRoot);
        Directory.CreateDirectory(Path.Combine(target.StateRoot, "usage"));
        Directory.CreateDirectory(Path.Combine(target.StateRoot, "logs"));
        Directory.CreateDirectory(target.RuntimeStateRoot);
        File.WriteAllText(Path.Combine(target.StateRoot, "config.json"), "{}");
        File.WriteAllText(Path.Combine(target.StateRoot, "usage", "usage.db"), "fixture");
        File.WriteAllText(Path.Combine(target.StateRoot, "logs", "gateway.log"), "fixture");
        File.WriteAllText(Path.Combine(target.RuntimeStateRoot, "instance"), "fixture");
        var credentials = new MemoryCredentials(
        [
            CredentialTargets.RuntimeClientToken,
            "LocalAIGateway/work/openai/api-key",
        ]);
        var daemon = new TestDaemon();
        var autostart = new TestAutostart { State = CurrentUserAutostartTaskState.Owned };
        var coordinator = CreateCoordinator(credentials, daemon, autostart, new TestLock(true));

        var result = await coordinator.UninstallAsync(target, All(UninstallChoice.Remove));

        Assert.Equal(1, daemon.StopCount);
        Assert.Equal(1, autostart.DeleteCount);
        Assert.True(result.Program.Changed);
        Assert.True(result.Autostart.Changed);
        Assert.True(result.RuntimeCredential.Changed);
        Assert.True(result.ProviderCredentials.Changed);
        Assert.True(result.Configuration.Changed);
        Assert.True(result.Usage.Changed);
        Assert.True(result.Logs.Changed);
        Assert.False(Directory.Exists(target.InstallRoot));
        Assert.False(Directory.Exists(target.StateRoot));
        Assert.Empty(credentials.Targets);
    }

    [Fact]
    public async Task Keep_everything_is_read_only_and_does_not_stop_daemon()
    {
        var target = CurrentUserInstallationPlan.CreateTarget(Path.Combine(root, "local-app-data"));
        await InstallPackageAsync(target.InstallRoot);
        Directory.CreateDirectory(target.StateRoot);
        var credentials = new MemoryCredentials([CredentialTargets.RuntimeClientToken]);
        var daemon = new TestDaemon();
        var autostart = new TestAutostart { State = CurrentUserAutostartTaskState.Owned };

        var result = await CreateCoordinator(
            credentials, daemon, autostart, new TestLock(true)).UninstallAsync(
                target,
                All(UninstallChoice.Keep));

        Assert.Equal(0, daemon.StopCount);
        Assert.Equal(0, autostart.InspectCount);
        Assert.Equal(0, autostart.DeleteCount);
        Assert.Equal(0, credentials.ListCount);
        Assert.False(result.Program.Selected);
        Assert.True(Directory.Exists(target.InstallRoot));
        Assert.True(Directory.Exists(target.StateRoot));
        Assert.Equal([CredentialTargets.RuntimeClientToken], credentials.Targets);
    }

    [Fact]
    public async Task Modified_program_blocks_credential_and_state_deletion()
    {
        var target = CurrentUserInstallationPlan.CreateTarget(Path.Combine(root, "local-app-data"));
        await InstallPackageAsync(target.InstallRoot);
        File.WriteAllText(Path.Combine(target.InstallRoot, "user-note.txt"), "preserve");
        Directory.CreateDirectory(target.StateRoot);
        File.WriteAllText(Path.Combine(target.StateRoot, "config.json"), "{}");
        var credentials = new MemoryCredentials([CredentialTargets.RuntimeClientToken]);

        var failure = await Assert.ThrowsAsync<InstallationException>(() =>
            CreateCoordinator(credentials, new TestDaemon(), new TestAutostart(), new TestLock(true))
                .UninstallAsync(target, All(UninstallChoice.Remove)));

        Assert.Equal("aigw_uninstall_incomplete", failure.ErrorCode);
        Assert.Equal([CredentialTargets.RuntimeClientToken], credentials.Targets);
        Assert.True(File.Exists(Path.Combine(target.StateRoot, "config.json")));
        Assert.True(File.Exists(Path.Combine(target.InstallRoot, "user-note.txt")));
    }

    [Fact]
    public async Task Autostart_conflict_fails_before_daemon_or_file_mutation()
    {
        var target = CurrentUserInstallationPlan.CreateTarget(Path.Combine(root, "local-app-data"));
        await InstallPackageAsync(target.InstallRoot);
        var daemon = new TestDaemon();
        var autostart = new TestAutostart { State = CurrentUserAutostartTaskState.Conflict };

        var failure = await Assert.ThrowsAsync<InstallationException>(() =>
            CreateCoordinator(new MemoryCredentials([]), daemon, autostart, new TestLock(true))
                .UninstallAsync(target, All(UninstallChoice.Remove)));

        Assert.Equal("aigw_autostart_conflict", failure.ErrorCode);
        Assert.Equal(0, daemon.StopCount);
        Assert.True(Directory.Exists(target.InstallRoot));
    }

    [Fact]
    public async Task Shell_integration_conflict_fails_before_daemon_or_file_mutation()
    {
        var target = CurrentUserInstallationPlan.CreateTarget(Path.Combine(root, "local-app-data"));
        await InstallPackageAsync(target.InstallRoot);
        var daemon = new TestDaemon();
        var shell = new TestShellIntegration(target)
        {
            State = CurrentUserShellIntegrationComponentState.Conflict,
        };

        var failure = await Assert.ThrowsAsync<InstallationException>(() =>
            CreateCoordinator(
                new MemoryCredentials([]),
                daemon,
                new TestAutostart(),
                new TestLock(true),
                shell).UninstallAsync(target, All(UninstallChoice.Remove)));

        Assert.Equal("aigw_shell_integration_conflict", failure.ErrorCode);
        Assert.Equal(0, daemon.StopCount);
        Assert.Equal(0, shell.DeleteCount);
        Assert.True(Directory.Exists(target.InstallRoot));
    }

    [Fact]
    public async Task Program_removal_also_removes_owned_path_and_start_menu_integration()
    {
        var target = CurrentUserInstallationPlan.CreateTarget(Path.Combine(root, "local-app-data"));
        await InstallPackageAsync(target.InstallRoot);
        var shell = new TestShellIntegration(target)
        {
            State = CurrentUserShellIntegrationComponentState.Owned,
        };

        var result = await CreateCoordinator(
            new MemoryCredentials([]),
            new TestDaemon(),
            new TestAutostart(),
            new TestLock(true),
            shell).UninstallAsync(target, All(UninstallChoice.Remove));

        Assert.True(result.Program.Changed);
        Assert.Equal(1, shell.DeleteCount);
        Assert.Equal(CurrentUserShellIntegrationComponentState.Absent, shell.State);
        Assert.False(Directory.Exists(target.InstallRoot));
    }

    [Fact]
    public async Task Busy_install_mutex_fails_before_inspection_or_daemon_stop()
    {
        var target = CurrentUserInstallationPlan.CreateTarget(Path.Combine(root, "local-app-data"));
        var daemon = new TestDaemon();
        var autostart = new TestAutostart();

        var failure = await Assert.ThrowsAsync<InstallationException>(() =>
            CreateCoordinator(new MemoryCredentials([]), daemon, autostart, new TestLock(false))
                .UninstallAsync(target, All(UninstallChoice.Remove)));

        Assert.Equal("aigw_install_busy", failure.ErrorCode);
        Assert.Equal(0, daemon.StopCount);
        Assert.Equal(0, autostart.InspectCount);
    }

    private CurrentUserUninstallCoordinator CreateCoordinator(
        MemoryCredentials credentials,
        TestDaemon daemon,
        TestAutostart autostart,
        ISingleInstanceProvider installationLock,
        ICurrentUserShellIntegrationStore? shell = null) => shell is null
            ? new CurrentUserUninstallCoordinator(
                new WindowsPackageInstaller(),
                daemon,
                autostart,
                new OwnedCredentialCleaner(credentials, credentials),
                new OwnedStateDataCleaner(),
                installationLock)
            : new CurrentUserUninstallCoordinator(
                new WindowsPackageInstaller(),
                daemon,
                autostart,
                shell,
                new OwnedCredentialCleaner(credentials, credentials),
                new OwnedStateDataCleaner(),
                installationLock);

    private static UninstallSelection All(UninstallChoice choice) => new(
        choice, choice, choice, choice, choice, choice, choice, choice, choice);

    private async Task InstallPackageAsync(string installRoot)
    {
        var package = Path.Combine(root, "package-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(package);
        File.WriteAllText(Path.Combine(package, "aigw.exe"), "fixture");
        var bytes = File.ReadAllBytes(Path.Combine(package, "aigw.exe"));
        var manifest = new PackageManifest(
            PackageManifest.CurrentSchemaVersion,
            PackageManifest.ProductPackageId,
            "0.1.0-dev",
            PackageManifest.WindowsX64RuntimeIdentifier,
            true,
            [new PackageFile("aigw.exe", bytes.LongLength, Convert.ToHexStringLower(SHA256.HashData(bytes)))]);
        File.WriteAllBytes(Path.Combine(package, PackageManifest.FileName), PackageManifestJson.Serialize(manifest));
        await new WindowsPackageInstaller().InstallAsync(package, installRoot);
    }

    public void Dispose()
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }

    private sealed class MemoryCredentials(IEnumerable<string> targets)
        : ICredentialStore, ICredentialTargetCatalog
    {
        public List<string> Targets { get; } = targets.ToList();
        public int ListCount { get; private set; }
        public ValueTask<IReadOnlyList<string>> ListTargetsAsync(string ownedPrefix, CancellationToken cancellationToken = default)
        {
            ListCount++;
            return ValueTask.FromResult<IReadOnlyList<string>>(Targets.ToArray());
        }
        public ValueTask SetSecretAsync(string target, string secret, CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();
        public ValueTask<string?> GetSecretAsync(string target, CancellationToken cancellationToken = default) =>
            throw new InvalidOperationException("Uninstall must not read secrets.");
        public ValueTask DeleteSecretAsync(string target, CancellationToken cancellationToken = default)
        {
            Targets.Remove(target);
            return ValueTask.CompletedTask;
        }
    }

    private sealed class TestDaemon : IGatewayDaemonController
    {
        public int StopCount { get; private set; }
        public Task<GatewayDaemonOperationResult> StopAsync(CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            StopCount++;
            return Task.FromResult(new GatewayDaemonOperationResult(false, new(false, null, null, null, false, null, [])));
        }
        public Task<GatewayDaemonStatus> GetStatusAsync(CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<GatewayDaemonOperationResult> StartAsync(CurrentUserInstallationTarget target, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<GatewayDaemonOperationResult> RestartAsync(CurrentUserInstallationTarget target, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<GatewayDaemonOperationResult> ReloadAsync(CancellationToken cancellationToken = default) => throw new NotSupportedException();
    }

    private sealed class TestAutostart : ICurrentUserAutostartStore
    {
        public CurrentUserAutostartTaskState State { get; set; }
        public int InspectCount { get; private set; }
        public int DeleteCount { get; private set; }
        public ValueTask<CurrentUserAutostartTaskSnapshot> InspectAsync(CurrentUserInstallationTarget target, CancellationToken cancellationToken = default)
        {
            InspectCount++;
            return ValueTask.FromResult(new CurrentUserAutostartTaskSnapshot(State, State));
        }
        public ValueTask CreateAsync(CurrentUserInstallationTarget target, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public ValueTask DeleteAsync(CurrentUserInstallationTarget target, CancellationToken cancellationToken = default)
        {
            DeleteCount++;
            State = CurrentUserAutostartTaskState.Absent;
            return ValueTask.CompletedTask;
        }
    }

    private sealed class TestShellIntegration(CurrentUserInstallationTarget target)
        : ICurrentUserShellIntegrationStore
    {
        private readonly CurrentUserShellIntegrationSpec spec = CurrentUserShellIntegrationSpec.Create(
            target,
            Path.Combine(Path.GetTempPath(), "LocalAIGateway-Test-AppData"));

        public CurrentUserShellIntegrationComponentState State { get; set; }

        public int DeleteCount { get; private set; }

        public ValueTask<CurrentUserShellIntegrationSnapshot> InspectAsync(
            CurrentUserInstallationTarget installationTarget,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return ValueTask.FromResult(new CurrentUserShellIntegrationSnapshot(
                spec,
                State != CurrentUserShellIntegrationComponentState.Absent,
                State,
                State));
        }

        public ValueTask CreateAsync(
            CurrentUserInstallationTarget installationTarget,
            CancellationToken cancellationToken = default) =>
            ValueTask.FromException(new NotSupportedException());

        public ValueTask DeleteAsync(
            CurrentUserInstallationTarget installationTarget,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            DeleteCount++;
            State = CurrentUserShellIntegrationComponentState.Absent;
            return ValueTask.CompletedTask;
        }
    }

    private sealed class TestLock(bool available) : ISingleInstanceProvider
    {
        public ISingleInstanceLease? TryAcquire() => available ? new Lease() : null;
        private sealed class Lease : ISingleInstanceLease { public void Dispose() { } }
    }
}
