using System.Security.Cryptography;
using LocalAIGateway.Core.Configuration;
using LocalAIGateway.Core.Credentials;
using LocalAIGateway.Core.Installation;
using LocalAIGateway.Core.Runtime;
using LocalAIGateway.Windows.Installation;

namespace LocalAIGateway.Windows.Tests;

public sealed class CurrentUserInstallationCoordinatorTests : IDisposable
{
    private readonly string testRoot = Path.Combine(
        Path.GetTempPath(),
        $"LocalAIGateway-InstallCoordinator-{Guid.NewGuid():N}");

    [Fact]
    public async Task Install_creates_a_generated_runtime_credential_without_exposing_it_in_the_result()
    {
        var plan = CreatePlan();
        var credentials = new MemoryCredentialStore();
        var coordinator = CreateCoordinator(credentials);

        var result = await coordinator.InstallAsync(plan);

        Assert.True(result.Package.Installed);
        Assert.True(result.RuntimeCredentialCreated);
        Assert.True(RuntimeClientTokenGenerator.IsGeneratedFormat(
            credentials.Secrets[CredentialTargets.RuntimeClientToken]));
        Assert.DoesNotContain(
            credentials.Secrets[CredentialTargets.RuntimeClientToken],
            result.ToString(),
            StringComparison.Ordinal);
    }

    [Fact]
    public async Task Repeated_install_preserves_the_existing_generated_credential()
    {
        var plan = CreatePlan();
        var credentials = new MemoryCredentialStore();
        var existingToken = RuntimeClientTokenGenerator.Generate();
        credentials.Secrets[CredentialTargets.RuntimeClientToken] = existingToken;
        var coordinator = CreateCoordinator(credentials);

        var first = await coordinator.InstallAsync(plan);
        var repeated = await coordinator.InstallAsync(plan);

        Assert.True(first.Package.Installed);
        Assert.False(first.RuntimeCredentialCreated);
        Assert.True(repeated.Package.AlreadyInstalled);
        Assert.False(repeated.RuntimeCredentialCreated);
        Assert.Equal(existingToken, credentials.Secrets[CredentialTargets.RuntimeClientToken]);
        Assert.Equal(0, credentials.SetCount);
    }

    [Fact]
    public async Task Invalid_existing_runtime_credential_blocks_install_before_file_mutation()
    {
        var plan = CreatePlan();
        var credentials = new MemoryCredentialStore();
        credentials.Secrets[CredentialTargets.RuntimeClientToken] = "legacy-or-corrupt-token";
        var coordinator = CreateCoordinator(credentials);

        var failure = await Assert.ThrowsAsync<InstallationException>(
            () => coordinator.InstallAsync(plan));

        Assert.Equal("aigw_install_runtime_credential_invalid", failure.ErrorCode);
        Assert.False(Directory.Exists(plan.InstallRoot));
        Assert.Equal("legacy-or-corrupt-token", credentials.Secrets[CredentialTargets.RuntimeClientToken]);
    }

    [Fact]
    public async Task Credential_failure_rolls_back_only_a_new_package_installation()
    {
        var plan = CreatePlan();
        var credentials = new MemoryCredentialStore { FailSet = true };
        var coordinator = CreateCoordinator(credentials);

        var failure = await Assert.ThrowsAsync<InstallationException>(
            () => coordinator.InstallAsync(plan));

        Assert.Equal("aigw_install_runtime_credential_failed", failure.ErrorCode);
        Assert.False(Directory.Exists(plan.InstallRoot));
        Assert.False(credentials.Secrets.ContainsKey(CredentialTargets.RuntimeClientToken));
    }

    [Fact]
    public async Task Credential_failure_does_not_remove_a_preexisting_identical_package()
    {
        var plan = CreatePlan();
        await new WindowsPackageInstaller().InstallAsync(plan.PackageSourceRoot, plan.InstallRoot);
        var credentials = new MemoryCredentialStore { FailSet = true };
        var coordinator = CreateCoordinator(credentials);

        var failure = await Assert.ThrowsAsync<InstallationException>(
            () => coordinator.InstallAsync(plan));

        Assert.Equal("aigw_install_runtime_credential_failed", failure.ErrorCode);
        Assert.True(Directory.Exists(plan.InstallRoot));
        Assert.True(File.Exists(Path.Combine(plan.InstallRoot, "aigw.exe")));
    }

    [Fact]
    public async Task Partial_uninstall_preserves_the_runtime_credential()
    {
        var plan = CreatePlan();
        var credentials = new MemoryCredentialStore();
        var coordinator = CreateCoordinator(credentials);
        await coordinator.InstallAsync(plan);
        await File.WriteAllTextAsync(Path.Combine(plan.InstallRoot, "user-file.txt"), "preserve");

        var result = await coordinator.UninstallAsync(plan);

        Assert.False(result.Package.Removed);
        Assert.False(result.RuntimeCredentialDeleted);
        Assert.True(credentials.Secrets.ContainsKey(CredentialTargets.RuntimeClientToken));
        Assert.True(File.Exists(Path.Combine(plan.InstallRoot, "user-file.txt")));
    }

    [Fact]
    public async Task Clean_uninstall_removes_the_runtime_credential_after_package_removal()
    {
        var plan = CreatePlan();
        var credentials = new MemoryCredentialStore();
        var coordinator = CreateCoordinator(credentials);
        await coordinator.InstallAsync(plan);

        var result = await coordinator.UninstallAsync(plan);

        Assert.True(result.Package.Removed);
        Assert.True(result.RuntimeCredentialDeleted);
        Assert.False(Directory.Exists(plan.InstallRoot));
        Assert.False(credentials.Secrets.ContainsKey(CredentialTargets.RuntimeClientToken));
    }

    [Fact]
    public async Task Busy_installation_lock_blocks_before_credentials_or_files_are_touched()
    {
        var plan = CreatePlan();
        var credentials = new MemoryCredentialStore();
        var coordinator = new CurrentUserInstallationCoordinator(
            new WindowsPackageInstaller(),
            credentials,
            new TestSingleInstanceProvider(acquire: false),
            RuntimeClientTokenGenerator.Generate);

        var failure = await Assert.ThrowsAsync<InstallationException>(
            () => coordinator.InstallAsync(plan));

        Assert.Equal("aigw_install_busy", failure.ErrorCode);
        Assert.Equal(0, credentials.GetCount);
        Assert.False(Directory.Exists(plan.InstallRoot));
    }

    [Fact]
    public async Task Installation_lock_is_released_after_success_and_failure()
    {
        var plan = CreatePlan();
        var successfulLock = new TestSingleInstanceProvider(acquire: true);
        var successful = new CurrentUserInstallationCoordinator(
            new WindowsPackageInstaller(),
            new MemoryCredentialStore(),
            successfulLock,
            RuntimeClientTokenGenerator.Generate);

        await successful.InstallAsync(plan);

        Assert.Equal(1, successfulLock.DisposeCount);

        var failingLock = new TestSingleInstanceProvider(acquire: true);
        var failing = new CurrentUserInstallationCoordinator(
            new WindowsPackageInstaller(),
            new MemoryCredentialStore { FailSet = true },
            failingLock,
            RuntimeClientTokenGenerator.Generate);

        await Assert.ThrowsAsync<InstallationException>(() => failing.InstallAsync(plan));

        Assert.Equal(1, failingLock.DisposeCount);
    }

    [Fact]
    public async Task Autostart_enable_and_disable_are_idempotent_under_the_installation_lock()
    {
        var plan = CreatePlan();
        var credentials = new MemoryCredentialStore();
        var store = new TestAutostartStore();
        var installationLock = new TestSingleInstanceProvider(acquire: true);
        var coordinator = new CurrentUserInstallationCoordinator(
            new WindowsPackageInstaller(),
            credentials,
            store,
            installationLock,
            RuntimeClientTokenGenerator.Generate);
        await coordinator.InstallAsync(plan);

        var enabled = await coordinator.EnableAutostartAsync(plan.Target);
        var repeatedEnable = await coordinator.EnableAutostartAsync(plan.Target);
        var disabled = await coordinator.DisableAutostartAsync(plan.Target);
        var repeatedDisable = await coordinator.DisableAutostartAsync(plan.Target);

        Assert.True(enabled.Changed);
        Assert.True(enabled.Status.Owned);
        Assert.False(repeatedEnable.Changed);
        Assert.True(disabled.Changed);
        Assert.False(disabled.Status.Registered);
        Assert.False(repeatedDisable.Changed);
        Assert.Equal(1, store.CreateCount);
        Assert.Equal(1, store.DeleteCount);
        Assert.Equal(5, installationLock.DisposeCount);
    }

    [Fact]
    public async Task Autostart_enable_completes_a_legacy_runtime_only_registration()
    {
        var plan = CreatePlan();
        var store = new TestAutostartStore();
        var coordinator = new CurrentUserInstallationCoordinator(
            new WindowsPackageInstaller(),
            new MemoryCredentialStore(),
            store,
            new TestSingleInstanceProvider(acquire: true),
            RuntimeClientTokenGenerator.Generate);
        await coordinator.InstallAsync(plan);
        store.RuntimeState = CurrentUserAutostartTaskState.Owned;
        store.TrayState = CurrentUserAutostartTaskState.Absent;

        var before = await coordinator.GetAutostartStatusAsync(plan.Target);
        var enabled = await coordinator.EnableAutostartAsync(plan.Target);

        Assert.True(before.Registered);
        Assert.False(before.Owned);
        Assert.True(before.Incomplete);
        Assert.True(before.Runtime.Owned);
        Assert.False(before.Tray.Registered);
        Assert.True(enabled.Changed);
        Assert.True(enabled.Status.Owned);
        Assert.False(enabled.Status.Incomplete);
        Assert.Equal(1, store.CreateCount);
    }

    [Fact]
    public async Task Autostart_enable_requires_the_installed_tray_executable()
    {
        var plan = CreatePlan();
        var store = new TestAutostartStore();
        var coordinator = new CurrentUserInstallationCoordinator(
            new WindowsPackageInstaller(),
            new MemoryCredentialStore(),
            store,
            new TestSingleInstanceProvider(acquire: true),
            RuntimeClientTokenGenerator.Generate);
        await coordinator.InstallAsync(plan);
        File.Delete(plan.Target.TrayExecutablePath);

        var failure = await Assert.ThrowsAsync<InstallationException>(
            () => coordinator.EnableAutostartAsync(plan.Target));

        Assert.Equal("aigw_autostart_install_invalid", failure.ErrorCode);
        Assert.Equal(0, store.InspectCount);
        Assert.Equal(0, store.CreateCount);
    }

    [Fact]
    public async Task Install_experience_preflights_task_conflict_before_files_or_credentials()
    {
        var plan = CreatePlan();
        var credentials = new MemoryCredentialStore();
        var store = new TestAutostartStore
        {
            TrayState = CurrentUserAutostartTaskState.Conflict,
        };
        var coordinator = new CurrentUserInstallationCoordinator(
            new WindowsPackageInstaller(),
            credentials,
            store,
            new TestSingleInstanceProvider(acquire: true),
            RuntimeClientTokenGenerator.Generate);

        var failure = await Assert.ThrowsAsync<InstallationException>(
            () => coordinator.InstallAsync(plan, enableAutostart: true));

        Assert.Equal("aigw_autostart_conflict", failure.ErrorCode);
        Assert.False(Directory.Exists(plan.InstallRoot));
        Assert.Equal(0, credentials.SetCount);
        Assert.Equal(0, store.CreateCount);
    }

    [Fact]
    public async Task Install_experience_preflights_shell_conflict_before_files_credentials_or_tasks()
    {
        var plan = CreatePlan();
        var credentials = new MemoryCredentialStore();
        var autostart = new TestAutostartStore();
        var shell = new TestShellIntegrationStore(plan.Target)
        {
            State = CurrentUserShellIntegrationComponentState.Conflict,
        };
        var coordinator = new CurrentUserInstallationCoordinator(
            new WindowsPackageInstaller(),
            credentials,
            autostart,
            shell,
            new TestSingleInstanceProvider(acquire: true),
            RuntimeClientTokenGenerator.Generate);

        var failure = await Assert.ThrowsAsync<InstallationException>(
            () => coordinator.InstallAsync(plan, enableAutostart: true));

        Assert.Equal("aigw_shell_integration_conflict", failure.ErrorCode);
        Assert.False(Directory.Exists(plan.InstallRoot));
        Assert.Equal(0, credentials.SetCount);
        Assert.Equal(0, autostart.CreateCount);
        Assert.Equal(0, shell.CreateCount);
    }

    [Fact]
    public async Task Install_experience_enables_shell_integration_once_and_returns_owned_status()
    {
        var plan = CreatePlan();
        var shell = new TestShellIntegrationStore(plan.Target);
        var coordinator = new CurrentUserInstallationCoordinator(
            new WindowsPackageInstaller(),
            new MemoryCredentialStore(),
            new TestAutostartStore(),
            shell,
            new TestSingleInstanceProvider(acquire: true),
            RuntimeClientTokenGenerator.Generate);

        var first = await coordinator.InstallAsync(plan, enableAutostart: false);
        var repeated = await coordinator.InstallAsync(plan, enableAutostart: false);

        Assert.True(first.ShellIntegration.Changed);
        Assert.True(first.ShellIntegration.Status.Owned);
        Assert.False(repeated.ShellIntegration.Changed);
        Assert.Equal(1, shell.CreateCount);
    }

    [Fact]
    public async Task Shell_failure_rolls_back_new_package_and_credential_before_autostart_mutation()
    {
        var plan = CreatePlan();
        var credentials = new MemoryCredentialStore();
        var autostart = new TestAutostartStore();
        var shell = new TestShellIntegrationStore(plan.Target)
        {
            CreateFailure = new InstallationException("fixture_shell_failed", "Injected shell failure."),
        };
        var coordinator = new CurrentUserInstallationCoordinator(
            new WindowsPackageInstaller(),
            credentials,
            autostart,
            shell,
            new TestSingleInstanceProvider(acquire: true),
            RuntimeClientTokenGenerator.Generate);

        var failure = await Assert.ThrowsAsync<InstallationException>(
            () => coordinator.InstallAsync(plan, enableAutostart: true));

        Assert.Equal("fixture_shell_failed", failure.ErrorCode);
        Assert.False(Directory.Exists(plan.InstallRoot));
        Assert.DoesNotContain(CredentialTargets.RuntimeClientToken, credentials.Secrets.Keys);
        Assert.Equal(0, autostart.CreateCount);
        Assert.Equal(1, shell.CreateCount);
    }

    [Fact]
    public async Task Install_experience_rolls_back_new_files_and_credential_when_autostart_fails()
    {
        var plan = CreatePlan();
        var credentials = new MemoryCredentialStore();
        var store = new TestAutostartStore
        {
            CreateFailure = new InstallationException("fixture_autostart_failed", "Injected autostart failure."),
        };
        var coordinator = new CurrentUserInstallationCoordinator(
            new WindowsPackageInstaller(),
            credentials,
            store,
            new TestSingleInstanceProvider(acquire: true),
            RuntimeClientTokenGenerator.Generate);

        var failure = await Assert.ThrowsAsync<InstallationException>(
            () => coordinator.InstallAsync(plan, enableAutostart: true));

        Assert.Equal("fixture_autostart_failed", failure.ErrorCode);
        Assert.False(Directory.Exists(plan.InstallRoot));
        Assert.DoesNotContain(CredentialTargets.RuntimeClientToken, credentials.Secrets.Keys);
        Assert.Equal(1, store.CreateCount);
        Assert.Equal(3, store.InspectCount);
    }

    [Fact]
    public async Task Autostart_failure_rolls_back_shell_integration_created_by_the_same_install()
    {
        var plan = CreatePlan();
        var autostart = new TestAutostartStore
        {
            CreateFailure = new InstallationException("fixture_autostart_failed", "Injected autostart failure."),
        };
        var shell = new TestShellIntegrationStore(plan.Target);
        var coordinator = new CurrentUserInstallationCoordinator(
            new WindowsPackageInstaller(),
            new MemoryCredentialStore(),
            autostart,
            shell,
            new TestSingleInstanceProvider(acquire: true),
            RuntimeClientTokenGenerator.Generate);

        await Assert.ThrowsAsync<InstallationException>(
            () => coordinator.InstallAsync(plan, enableAutostart: true));

        Assert.Equal(1, shell.CreateCount);
        Assert.Equal(1, shell.DeleteCount);
        Assert.Equal(CurrentUserShellIntegrationComponentState.Absent, shell.State);
    }

    [Fact]
    public async Task Install_experience_preserves_preexisting_package_and_credential_when_autostart_fails()
    {
        var plan = CreatePlan();
        var credentials = new MemoryCredentialStore();
        var store = new TestAutostartStore();
        var coordinator = new CurrentUserInstallationCoordinator(
            new WindowsPackageInstaller(),
            credentials,
            store,
            new TestSingleInstanceProvider(acquire: true),
            RuntimeClientTokenGenerator.Generate);
        await coordinator.InstallAsync(plan);
        var originalToken = credentials.Secrets[CredentialTargets.RuntimeClientToken];
        store.CreateFailure = new InstallationException("fixture_autostart_failed", "Injected autostart failure.");

        var failure = await Assert.ThrowsAsync<InstallationException>(
            () => coordinator.InstallAsync(plan, enableAutostart: true));

        Assert.Equal("fixture_autostart_failed", failure.ErrorCode);
        Assert.True(Directory.Exists(plan.InstallRoot));
        Assert.Equal(originalToken, credentials.Secrets[CredentialTargets.RuntimeClientToken]);
    }

    [Fact]
    public async Task Autostart_enable_validates_the_complete_installed_package_before_scheduler_access()
    {
        var plan = CreatePlan();
        var store = new TestAutostartStore();
        var coordinator = new CurrentUserInstallationCoordinator(
            new WindowsPackageInstaller(),
            new MemoryCredentialStore(),
            store,
            new TestSingleInstanceProvider(acquire: true),
            RuntimeClientTokenGenerator.Generate);

        var failure = await Assert.ThrowsAsync<InstallationException>(
            () => coordinator.EnableAutostartAsync(plan.Target));

        Assert.Equal("aigw_autostart_install_invalid", failure.ErrorCode);
        Assert.Equal(0, store.InspectCount);
        Assert.Equal(0, store.CreateCount);
    }

    [Fact]
    public async Task Conflicting_task_is_never_overwritten_or_deleted_and_blocks_uninstall_before_mutation()
    {
        var plan = CreatePlan();
        var credentials = new MemoryCredentialStore();
        var store = new TestAutostartStore();
        var coordinator = new CurrentUserInstallationCoordinator(
            new WindowsPackageInstaller(),
            credentials,
            store,
            new TestSingleInstanceProvider(acquire: true),
            RuntimeClientTokenGenerator.Generate);
        await coordinator.InstallAsync(plan);
        store.State = CurrentUserAutostartTaskState.Conflict;

        var enableFailure = await Assert.ThrowsAsync<InstallationException>(
            () => coordinator.EnableAutostartAsync(plan.Target));
        var uninstallFailure = await Assert.ThrowsAsync<InstallationException>(
            () => coordinator.UninstallAsync(plan.Target));

        Assert.Equal("aigw_autostart_conflict", enableFailure.ErrorCode);
        Assert.Equal("aigw_autostart_conflict", uninstallFailure.ErrorCode);
        Assert.Equal(0, store.CreateCount);
        Assert.Equal(0, store.DeleteCount);
        Assert.True(Directory.Exists(plan.InstallRoot));
        Assert.True(credentials.Secrets.ContainsKey(CredentialTargets.RuntimeClientToken));
    }

    [Fact]
    public async Task Uninstall_removes_an_owned_task_before_removing_package_and_credential()
    {
        var plan = CreatePlan();
        var credentials = new MemoryCredentialStore();
        var store = new TestAutostartStore();
        var coordinator = new CurrentUserInstallationCoordinator(
            new WindowsPackageInstaller(),
            credentials,
            store,
            new TestSingleInstanceProvider(acquire: true),
            RuntimeClientTokenGenerator.Generate);
        await coordinator.InstallAsync(plan);
        store.State = CurrentUserAutostartTaskState.Owned;

        var result = await coordinator.UninstallAsync(plan.Target);

        Assert.True(result.AutostartRemoved);
        Assert.True(result.Package.Removed);
        Assert.True(result.RuntimeCredentialDeleted);
        Assert.Equal(1, store.DeleteCount);
        Assert.Equal(CurrentUserAutostartTaskState.Absent, store.State);
        Assert.False(Directory.Exists(plan.InstallRoot));
    }

    [Fact]
    public async Task Busy_installation_lock_blocks_autostart_before_package_or_scheduler_access()
    {
        var plan = CreatePlan();
        var store = new TestAutostartStore();
        var coordinator = new CurrentUserInstallationCoordinator(
            new WindowsPackageInstaller(),
            new MemoryCredentialStore(),
            store,
            new TestSingleInstanceProvider(acquire: false),
            RuntimeClientTokenGenerator.Generate);

        var failure = await Assert.ThrowsAsync<InstallationException>(
            () => coordinator.EnableAutostartAsync(plan.Target));

        Assert.Equal("aigw_install_busy", failure.ErrorCode);
        Assert.Equal(0, store.InspectCount);
    }

    public void Dispose()
    {
        if (Directory.Exists(testRoot))
        {
            Directory.Delete(testRoot, recursive: true);
        }
    }

    private static CurrentUserInstallationCoordinator CreateCoordinator(
        MemoryCredentialStore credentials) => new(
            new WindowsPackageInstaller(),
            credentials,
            new TestAutostartStore(),
            new TestSingleInstanceProvider(acquire: true),
            RuntimeClientTokenGenerator.Generate);

    private CurrentUserInstallationPlan CreatePlan()
    {
        var packageRoot = Path.Combine(testRoot, "package source");
        if (!Directory.Exists(packageRoot))
        {
            Directory.CreateDirectory(packageRoot);
            File.WriteAllText(Path.Combine(packageRoot, "aigw.exe"), "cli");
            File.WriteAllText(Path.Combine(packageRoot, "aigw-runtime.exe"), "runtime");
            Directory.CreateDirectory(Path.Combine(packageRoot, "tray"));
            File.WriteAllText(Path.Combine(packageRoot, "tray", "aigw-tray.exe"), "tray");
            var files = new[]
            {
                CreateFile(packageRoot, "aigw-runtime.exe"),
                CreateFile(packageRoot, "aigw.exe"),
                CreateFile(packageRoot, "tray/aigw-tray.exe"),
            };
            File.WriteAllBytes(
                Path.Combine(packageRoot, PackageManifest.FileName),
                PackageManifestJson.Serialize(new PackageManifest(
                    PackageManifest.CurrentSchemaVersion,
                    PackageManifest.ProductPackageId,
                    "0.1.0-dev",
                    PackageManifest.WindowsX64RuntimeIdentifier,
                    true,
                    files)));
        }

        return CurrentUserInstallationPlan.Create(
            packageRoot,
            Path.Combine(testRoot, "isolated local appdata"));
    }

    private static PackageFile CreateFile(string root, string relativePath)
    {
        var bytes = File.ReadAllBytes(Path.Combine(root, relativePath));
        return new PackageFile(
            relativePath,
            bytes.LongLength,
            Convert.ToHexStringLower(SHA256.HashData(bytes)));
    }

    private sealed class MemoryCredentialStore : ICredentialStore
    {
        public Dictionary<string, string> Secrets { get; } = new(StringComparer.Ordinal);

        public bool FailSet { get; init; }

        public int SetCount { get; private set; }

        public int GetCount { get; private set; }

        public ValueTask SetSecretAsync(
            string target,
            string secret,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            SetCount++;
            if (FailSet)
            {
                throw new CredentialException("test_write_failed", "Injected credential failure.");
            }

            Secrets[target] = secret;
            return ValueTask.CompletedTask;
        }

        public ValueTask<string?> GetSecretAsync(
            string target,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            GetCount++;
            return ValueTask.FromResult(Secrets.GetValueOrDefault(target));
        }

        public ValueTask DeleteSecretAsync(
            string target,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            Secrets.Remove(target);
            return ValueTask.CompletedTask;
        }
    }

    private sealed class TestSingleInstanceProvider(bool acquire) : ISingleInstanceProvider
    {
        public int DisposeCount { get; private set; }

        public ISingleInstanceLease? TryAcquire() =>
            acquire ? new TestLease(() => DisposeCount++) : null;

        private sealed class TestLease(Action dispose) : ISingleInstanceLease
        {
            private Action? dispose = dispose;

            public void Dispose() => Interlocked.Exchange(ref dispose, null)?.Invoke();
        }
    }

    private sealed class TestAutostartStore : ICurrentUserAutostartStore
    {
        private CurrentUserAutostartTaskSnapshot state = new(
            CurrentUserAutostartTaskState.Absent,
            CurrentUserAutostartTaskState.Absent);

        public CurrentUserAutostartTaskState State
        {
            get => state.Runtime == state.Tray ? state.Runtime : CurrentUserAutostartTaskState.Conflict;
            set => state = new CurrentUserAutostartTaskSnapshot(value, value);
        }

        public CurrentUserAutostartTaskState RuntimeState
        {
            get => state.Runtime;
            set => state = state with { Runtime = value };
        }

        public CurrentUserAutostartTaskState TrayState
        {
            get => state.Tray;
            set => state = state with { Tray = value };
        }

        public CurrentUserAutostartTaskState StateAfterCreate { get; set; } = CurrentUserAutostartTaskState.Owned;

        public Exception? CreateFailure { get; set; }

        public int InspectCount { get; private set; }

        public int CreateCount { get; private set; }

        public int DeleteCount { get; private set; }

        public ValueTask<CurrentUserAutostartTaskSnapshot> InspectAsync(
            CurrentUserInstallationTarget target,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            InspectCount++;
            return ValueTask.FromResult(state);
        }

        public ValueTask CreateAsync(
            CurrentUserInstallationTarget target,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            CreateCount++;
            if (CreateFailure is not null)
            {
                throw CreateFailure;
            }
            state = new CurrentUserAutostartTaskSnapshot(StateAfterCreate, StateAfterCreate);
            return ValueTask.CompletedTask;
        }

        public ValueTask DeleteAsync(
            CurrentUserInstallationTarget target,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            DeleteCount++;
            state = new CurrentUserAutostartTaskSnapshot(
                CurrentUserAutostartTaskState.Absent,
                CurrentUserAutostartTaskState.Absent);
            return ValueTask.CompletedTask;
        }
    }

    private sealed class TestShellIntegrationStore(CurrentUserInstallationTarget target)
        : ICurrentUserShellIntegrationStore
    {
        private readonly CurrentUserShellIntegrationSpec spec = CurrentUserShellIntegrationSpec.Create(
            target,
            Path.Combine(Path.GetTempPath(), "LocalAIGateway-Test-AppData"));

        public CurrentUserShellIntegrationComponentState State { get; set; } =
            CurrentUserShellIntegrationComponentState.Absent;

        public Exception? CreateFailure { get; set; }

        public int InspectCount { get; private set; }

        public int CreateCount { get; private set; }

        public int DeleteCount { get; private set; }

        public ValueTask<CurrentUserShellIntegrationSnapshot> InspectAsync(
            CurrentUserInstallationTarget installationTarget,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            InspectCount++;
            return ValueTask.FromResult(new CurrentUserShellIntegrationSnapshot(
                spec,
                State != CurrentUserShellIntegrationComponentState.Absent,
                State,
                State));
        }

        public ValueTask CreateAsync(
            CurrentUserInstallationTarget installationTarget,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            CreateCount++;
            if (CreateFailure is not null)
            {
                throw CreateFailure;
            }
            State = CurrentUserShellIntegrationComponentState.Owned;
            return ValueTask.CompletedTask;
        }

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
}
