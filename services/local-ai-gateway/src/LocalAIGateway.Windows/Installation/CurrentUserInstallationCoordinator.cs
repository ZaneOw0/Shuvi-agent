using LocalAIGateway.Core.Credentials;
using LocalAIGateway.Core.Installation;
using LocalAIGateway.Core.Runtime;

namespace LocalAIGateway.Windows.Installation;

public sealed record CurrentUserInstallationResult(
    PackageInstallationResult Package,
    bool RuntimeCredentialCreated);

public sealed record CurrentUserInstallExperienceResult(
    CurrentUserInstallationResult Installation,
    CurrentUserAutostartOperationResult Autostart,
    CurrentUserShellIntegrationOperationResult ShellIntegration);

public sealed record CurrentUserUninstallationResult(
    PackageUninstallationResult Package,
    bool RuntimeCredentialDeleted,
    bool AutostartRemoved,
    bool ShellIntegrationRemoved);

public interface ICurrentUserInstallationCoordinator
{
    Task<CurrentUserInstallationResult> InstallAsync(
        CurrentUserInstallationPlan plan,
        CancellationToken cancellationToken = default);

    Task<CurrentUserInstallExperienceResult> InstallAsync(
        CurrentUserInstallationPlan plan,
        bool enableAutostart,
        CancellationToken cancellationToken = default);

    Task<CurrentUserUninstallationResult> UninstallAsync(
        CurrentUserInstallationTarget target,
        CancellationToken cancellationToken = default);

    Task<CurrentUserAutostartStatus> GetAutostartStatusAsync(
        CurrentUserInstallationTarget target,
        CancellationToken cancellationToken = default);

    Task<CurrentUserAutostartOperationResult> EnableAutostartAsync(
        CurrentUserInstallationTarget target,
        CancellationToken cancellationToken = default);

    Task<CurrentUserAutostartOperationResult> DisableAutostartAsync(
        CurrentUserInstallationTarget target,
        CancellationToken cancellationToken = default);
}

public sealed class CurrentUserInstallationCoordinator : ICurrentUserInstallationCoordinator
{
    private readonly WindowsPackageInstaller packageInstaller;
    private readonly ICredentialStore credentialStore;
    private readonly ICurrentUserAutostartStore autostartStore;
    private readonly ICurrentUserShellIntegrationStore shellIntegrationStore;
    private readonly ISingleInstanceProvider installationLock;
    private readonly Func<string> tokenFactory;

    public CurrentUserInstallationCoordinator(
        WindowsPackageInstaller packageInstaller,
        ICredentialStore credentialStore)
        : this(
            packageInstaller,
            credentialStore,
            new WindowsTaskSchedulerAutostartStore(),
            new WindowsCurrentUserShellIntegrationStore(),
            new WindowsCurrentUserSingleInstanceProvider("install"),
            RuntimeClientTokenGenerator.Generate)
    {
    }

    internal CurrentUserInstallationCoordinator(
        WindowsPackageInstaller packageInstaller,
        ICredentialStore credentialStore,
        ISingleInstanceProvider installationLock,
        Func<string> tokenFactory)
        : this(
            packageInstaller,
            credentialStore,
            AbsentCurrentUserAutostartStore.Instance,
            new InMemoryCurrentUserShellIntegrationStore(),
            installationLock,
            tokenFactory)
    {
    }

    internal CurrentUserInstallationCoordinator(
        WindowsPackageInstaller packageInstaller,
        ICredentialStore credentialStore,
        ICurrentUserAutostartStore autostartStore,
        ISingleInstanceProvider installationLock,
        Func<string> tokenFactory)
        : this(
            packageInstaller,
            credentialStore,
            autostartStore,
            new InMemoryCurrentUserShellIntegrationStore(),
            installationLock,
            tokenFactory)
    {
    }

    internal CurrentUserInstallationCoordinator(
        WindowsPackageInstaller packageInstaller,
        ICredentialStore credentialStore,
        ICurrentUserAutostartStore autostartStore,
        ICurrentUserShellIntegrationStore shellIntegrationStore,
        ISingleInstanceProvider installationLock,
        Func<string> tokenFactory)
    {
        ArgumentNullException.ThrowIfNull(packageInstaller);
        ArgumentNullException.ThrowIfNull(credentialStore);
        ArgumentNullException.ThrowIfNull(autostartStore);
        ArgumentNullException.ThrowIfNull(shellIntegrationStore);
        ArgumentNullException.ThrowIfNull(installationLock);
        ArgumentNullException.ThrowIfNull(tokenFactory);
        this.packageInstaller = packageInstaller;
        this.credentialStore = credentialStore;
        this.autostartStore = autostartStore;
        this.shellIntegrationStore = shellIntegrationStore;
        this.installationLock = installationLock;
        this.tokenFactory = tokenFactory;
    }

    public async Task<CurrentUserInstallationResult> InstallAsync(
        CurrentUserInstallationPlan plan,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(plan);
        using var installationLease = AcquireInstallationLease();
        return await InstallUnderLeaseAsync(plan, cancellationToken);
    }

    public async Task<CurrentUserInstallExperienceResult> InstallAsync(
        CurrentUserInstallationPlan plan,
        bool enableAutostart,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(plan);
        using var installationLease = AcquireInstallationLease();
        var initialAutostart = await autostartStore.InspectAsync(plan.Target, cancellationToken);
        if (initialAutostart.HasConflict)
        {
            throw AutostartConflict();
        }
        var initialShellIntegration = await shellIntegrationStore.InspectAsync(plan.Target, cancellationToken);
        if (initialShellIntegration.HasConflict)
        {
            throw ShellIntegrationConflict();
        }

        var installation = await InstallUnderLeaseAsync(plan, cancellationToken);
        try
        {
            var shellIntegration = await EnableShellIntegrationUnderLeaseAsync(plan.Target, cancellationToken);
            var autostart = enableAutostart
                ? await EnableAutostartUnderLeaseAsync(plan.Target, cancellationToken)
                : await DisableAutostartUnderLeaseAsync(plan.Target, cancellationToken);
            return new CurrentUserInstallExperienceResult(installation, autostart, shellIntegration);
        }
        catch (Exception exception)
        {
            await RollBackInstallExperienceAsync(
                plan.Target,
                installation,
                initialAutostart,
                initialShellIntegration,
                exception);
            throw;
        }
    }

    private async Task<CurrentUserInstallationResult> InstallUnderLeaseAsync(
        CurrentUserInstallationPlan plan,
        CancellationToken cancellationToken)
    {
        var existingToken = await credentialStore.GetSecretAsync(
            plan.RuntimeCredentialTarget,
            cancellationToken);
        if (existingToken is not null && !RuntimeClientTokenGenerator.IsGeneratedFormat(existingToken))
        {
            throw new InstallationException(
                "aigw_install_runtime_credential_invalid",
                "An existing runtime client credential is not in the supported generated format.");
        }

        var package = await packageInstaller.InstallAsync(
            plan.PackageSourceRoot,
            plan.InstallRoot,
            cancellationToken);
        if (existingToken is not null)
        {
            return new CurrentUserInstallationResult(package, false);
        }

        Exception? credentialFailure = null;
        try
        {
            var token = tokenFactory();
            if (!RuntimeClientTokenGenerator.IsGeneratedFormat(token))
            {
                throw new InstallationException(
                    "aigw_install_runtime_credential_generation_failed",
                    "Runtime client token generation returned an invalid value.");
            }

            await credentialStore.SetSecretAsync(
                plan.RuntimeCredentialTarget,
                token,
                cancellationToken);
            return new CurrentUserInstallationResult(package, true);
        }
        catch (Exception exception)
        {
            credentialFailure = exception;
        }

        var rollbackFailures = new List<Exception>();
        try
        {
            await credentialStore.DeleteSecretAsync(
                plan.RuntimeCredentialTarget,
                CancellationToken.None);
        }
        catch (Exception rollbackFailure)
        {
            rollbackFailures.Add(rollbackFailure);
        }

        if (package.Installed)
        {
            try
            {
                var rollback = await packageInstaller.UninstallAsync(
                    plan.InstallRoot,
                    CancellationToken.None);
                if (!rollback.Removed)
                {
                    rollbackFailures.Add(new InstallationException(
                        "aigw_install_rollback_incomplete",
                        "New package files could not be completely removed after credential failure."));
                }
            }
            catch (Exception rollbackFailure)
            {
                rollbackFailures.Add(rollbackFailure);
            }
        }

        var failures = new[] { credentialFailure }.Concat(rollbackFailures).ToArray();
        throw new InstallationException(
            rollbackFailures.Count == 0
                ? "aigw_install_runtime_credential_failed"
                : "aigw_install_rollback_failed",
            rollbackFailures.Count == 0
                ? package.Installed
                    ? "The runtime client credential could not be installed; new package files were rolled back."
                    : "The runtime client credential could not be installed; the existing package was preserved."
                : "The runtime client credential failed and rollback was incomplete.",
            new AggregateException(failures));
    }

    public async Task<CurrentUserUninstallationResult> UninstallAsync(
        CurrentUserInstallationPlan plan,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(plan);
        return await UninstallAsync(plan.Target, cancellationToken);
    }

    public async Task<CurrentUserUninstallationResult> UninstallAsync(
        CurrentUserInstallationTarget target,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(target);
        using var installationLease = AcquireInstallationLease();
        var autostartState = await autostartStore.InspectAsync(target, cancellationToken);
        if (autostartState.HasConflict)
        {
            throw AutostartConflict();
        }
        var shellIntegrationState = await shellIntegrationStore.InspectAsync(target, cancellationToken);
        if (shellIntegrationState.HasConflict)
        {
            throw ShellIntegrationConflict();
        }

        var autostartRemoved = false;
        if (!autostartState.IsAbsent)
        {
            await autostartStore.DeleteAsync(target, cancellationToken);
            var stateAfterDelete = await autostartStore.InspectAsync(target, cancellationToken);
            if (!stateAfterDelete.IsAbsent)
            {
                throw new InstallationException(
                    "aigw_autostart_removal_failed",
                    "The owned current-user login autostart task still exists after removal.");
            }

            autostartRemoved = true;
        }

        var package = await packageInstaller.UninstallAsync(target.InstallRoot, cancellationToken);
        if (!package.Removed && !package.AlreadyAbsent)
        {
            return new CurrentUserUninstallationResult(package, false, autostartRemoved, false);
        }

        var shellIntegrationRemoved = false;
        if (!shellIntegrationState.IsAbsent)
        {
            await shellIntegrationStore.DeleteAsync(target, cancellationToken);
            var shellAfterDelete = await shellIntegrationStore.InspectAsync(target, cancellationToken);
            if (!shellAfterDelete.IsAbsent)
            {
                throw new InstallationException(
                    "aigw_shell_integration_removal_failed",
                    "Owned current-user PATH or Start Menu integration remains after removal.");
            }
            shellIntegrationRemoved = true;
        }

        try
        {
            await credentialStore.DeleteSecretAsync(
                target.RuntimeCredentialTarget,
                cancellationToken);
        }
        catch (Exception exception)
        {
            throw new InstallationException(
                "aigw_uninstall_runtime_credential_failed",
                "Package files were removed, but the runtime client credential could not be deleted.",
                exception);
        }

        return new CurrentUserUninstallationResult(package, true, autostartRemoved, shellIntegrationRemoved);
    }

    public async Task<CurrentUserAutostartStatus> GetAutostartStatusAsync(
        CurrentUserInstallationTarget target,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(target);
        var state = await autostartStore.InspectAsync(target, cancellationToken);
        return ToStatus(state);
    }

    public async Task<CurrentUserAutostartOperationResult> EnableAutostartAsync(
        CurrentUserInstallationTarget target,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(target);
        using var installationLease = AcquireInstallationLease();
        return await EnableAutostartUnderLeaseAsync(target, cancellationToken);
    }

    private async Task<CurrentUserAutostartOperationResult> EnableAutostartUnderLeaseAsync(
        CurrentUserInstallationTarget target,
        CancellationToken cancellationToken)
    {
        await EnsureValidInstalledPackageAsync(target, cancellationToken);
        var state = await autostartStore.InspectAsync(target, cancellationToken);
        if (state.HasConflict)
        {
            throw AutostartConflict();
        }

        if (state.IsOwned)
        {
            return new CurrentUserAutostartOperationResult(false, ToStatus(state));
        }

        await autostartStore.CreateAsync(target, cancellationToken);
        var stateAfterCreate = await autostartStore.InspectAsync(target, cancellationToken);
        if (!stateAfterCreate.IsOwned)
        {
            throw stateAfterCreate.HasConflict
                ? AutostartConflict()
                : new InstallationException(
                    "aigw_autostart_registration_failed",
                    "The current-user login autostart task was not present after registration.");
        }

        return new CurrentUserAutostartOperationResult(true, ToStatus(stateAfterCreate));
    }

    public async Task<CurrentUserAutostartOperationResult> DisableAutostartAsync(
        CurrentUserInstallationTarget target,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(target);
        using var installationLease = AcquireInstallationLease();
        return await DisableAutostartUnderLeaseAsync(target, cancellationToken);
    }

    private async Task<CurrentUserAutostartOperationResult> DisableAutostartUnderLeaseAsync(
        CurrentUserInstallationTarget target,
        CancellationToken cancellationToken)
    {
        var state = await autostartStore.InspectAsync(target, cancellationToken);
        if (state.HasConflict)
        {
            throw AutostartConflict();
        }

        if (state.IsAbsent)
        {
            return new CurrentUserAutostartOperationResult(false, ToStatus(state));
        }

        await autostartStore.DeleteAsync(target, cancellationToken);
        var stateAfterDelete = await autostartStore.InspectAsync(target, cancellationToken);
        if (!stateAfterDelete.IsAbsent)
        {
            throw new InstallationException(
                "aigw_autostart_removal_failed",
                "The owned current-user login autostart task still exists after removal.");
        }

        return new CurrentUserAutostartOperationResult(true, ToStatus(stateAfterDelete));
    }

    private async Task EnsureValidInstalledPackageAsync(
        CurrentUserInstallationTarget target,
        CancellationToken cancellationToken)
    {
        try
        {
            await packageInstaller.ValidateInstalledPackageAsync(target.InstallRoot, cancellationToken);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception exception)
        {
            throw new InstallationException(
                "aigw_autostart_install_invalid",
                "Login autostart requires an intact installed Local AI Gateway package.",
                exception);
        }

        if (!IsSafeExecutable(target.RuntimeExecutablePath) ||
            !IsSafeExecutable(target.TrayExecutablePath))
        {
            throw new InstallationException(
                "aigw_autostart_install_invalid",
                "The installed gateway runtime or tray executable is missing or is a reparse point.");
        }
    }

    private async Task<CurrentUserShellIntegrationOperationResult> EnableShellIntegrationUnderLeaseAsync(
        CurrentUserInstallationTarget target,
        CancellationToken cancellationToken)
    {
        await EnsureValidInstalledPackageAsync(target, cancellationToken);
        var state = await shellIntegrationStore.InspectAsync(target, cancellationToken);
        if (state.HasConflict)
        {
            throw ShellIntegrationConflict();
        }
        if (state.IsOwned)
        {
            return new CurrentUserShellIntegrationOperationResult(false, ToStatus(state));
        }

        await shellIntegrationStore.CreateAsync(target, cancellationToken);
        var afterCreate = await shellIntegrationStore.InspectAsync(target, cancellationToken);
        if (!afterCreate.IsOwned)
        {
            throw afterCreate.HasConflict
                ? ShellIntegrationConflict()
                : new InstallationException(
                    "aigw_shell_integration_registration_failed",
                    "The current-user PATH and Start Menu integration was not complete after registration.");
        }
        return new CurrentUserShellIntegrationOperationResult(true, ToStatus(afterCreate));
    }

    private async Task RollBackInstallExperienceAsync(
        CurrentUserInstallationTarget target,
        CurrentUserInstallationResult installation,
        CurrentUserAutostartTaskSnapshot initialAutostart,
        CurrentUserShellIntegrationSnapshot initialShellIntegration,
        Exception originalFailure)
    {
        var rollbackFailures = new List<Exception>();
        if (initialAutostart.IsAbsent)
        {
            try
            {
                var current = await autostartStore.InspectAsync(target, CancellationToken.None);
                if (!current.HasConflict && !current.IsAbsent)
                {
                    await autostartStore.DeleteAsync(target, CancellationToken.None);
                }
            }
            catch (Exception rollbackFailure)
            {
                rollbackFailures.Add(rollbackFailure);
            }
        }

        if (initialShellIntegration.IsAbsent)
        {
            try
            {
                var current = await shellIntegrationStore.InspectAsync(target, CancellationToken.None);
                if (!current.HasConflict && !current.IsAbsent)
                {
                    await shellIntegrationStore.DeleteAsync(target, CancellationToken.None);
                }
            }
            catch (Exception rollbackFailure)
            {
                rollbackFailures.Add(rollbackFailure);
            }
        }

        if (installation.RuntimeCredentialCreated)
        {
            try
            {
                await credentialStore.DeleteSecretAsync(
                    target.RuntimeCredentialTarget,
                    CancellationToken.None);
            }
            catch (Exception rollbackFailure)
            {
                rollbackFailures.Add(rollbackFailure);
            }
        }

        if (installation.Package.Installed)
        {
            try
            {
                var rollback = await packageInstaller.UninstallAsync(
                    target.InstallRoot,
                    CancellationToken.None);
                if (!rollback.Removed)
                {
                    rollbackFailures.Add(new InstallationException(
                        "aigw_install_rollback_incomplete",
                        "New package files could not be completely removed after installation-experience failure."));
                }
            }
            catch (Exception rollbackFailure)
            {
                rollbackFailures.Add(rollbackFailure);
            }
        }

        if (rollbackFailures.Count != 0)
        {
            throw new InstallationException(
                "aigw_install_rollback_failed",
                "Installation-experience configuration failed and rollback was incomplete.",
                new AggregateException(new[] { originalFailure }.Concat(rollbackFailures)));
        }
    }

    private static bool IsSafeExecutable(string path) =>
        File.Exists(path) &&
        (File.GetAttributes(path) & FileAttributes.ReparsePoint) == 0;

    private static CurrentUserAutostartStatus ToStatus(CurrentUserAutostartTaskSnapshot state) => new(
        ToComponentStatus(CurrentUserAutostartTaskXml.TaskPath, state.Runtime),
        ToComponentStatus(CurrentUserAutostartTaskXml.TrayTaskPath, state.Tray));

    private static CurrentUserAutostartComponentStatus ToComponentStatus(
        string taskPath,
        CurrentUserAutostartTaskState state) => new(
        taskPath,
        state != CurrentUserAutostartTaskState.Absent,
        state == CurrentUserAutostartTaskState.Owned,
        state == CurrentUserAutostartTaskState.Conflict);

    private static CurrentUserShellIntegrationStatus ToStatus(CurrentUserShellIntegrationSnapshot state) => new(
        new CurrentUserShellIntegrationComponentStatus(
            CurrentUserShellIntegrationSpec.RegistryTarget,
            state.UserPath != CurrentUserShellIntegrationComponentState.Absent,
            state.ReceiptPresent && state.UserPath == CurrentUserShellIntegrationComponentState.Owned,
            state.UserPath == CurrentUserShellIntegrationComponentState.Conflict),
        new CurrentUserShellIntegrationComponentStatus(
            state.Spec.ShortcutPath,
            state.StartMenu != CurrentUserShellIntegrationComponentState.Absent,
            state.ReceiptPresent && state.StartMenu == CurrentUserShellIntegrationComponentState.Owned,
            state.StartMenu == CurrentUserShellIntegrationComponentState.Conflict));

    private static InstallationException AutostartConflict() => new(
        "aigw_autostart_conflict",
        "One or more fixed Local AI Gateway login task names contain a different definition; all tasks were preserved.");

    private static InstallationException ShellIntegrationConflict() => new(
        "aigw_shell_integration_conflict",
        "The current-user PATH or Local AI Gateway Start Menu entry is not owned; all existing values were preserved.");

    private ISingleInstanceLease AcquireInstallationLease() =>
        installationLock.TryAcquire()
        ?? throw new InstallationException(
            "aigw_install_busy",
            "Another Local AI Gateway installation or uninstallation is already in progress.");

    private sealed class AbsentCurrentUserAutostartStore : ICurrentUserAutostartStore
    {
        public static AbsentCurrentUserAutostartStore Instance { get; } = new();

        public ValueTask<CurrentUserAutostartTaskSnapshot> InspectAsync(
            CurrentUserInstallationTarget target,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return ValueTask.FromResult(new CurrentUserAutostartTaskSnapshot(
                CurrentUserAutostartTaskState.Absent,
                CurrentUserAutostartTaskState.Absent));
        }

        public ValueTask CreateAsync(
            CurrentUserInstallationTarget target,
            CancellationToken cancellationToken = default) =>
            ValueTask.FromException(new InvalidOperationException("The test autostart store cannot create tasks."));

        public ValueTask DeleteAsync(
            CurrentUserInstallationTarget target,
            CancellationToken cancellationToken = default) =>
            ValueTask.FromException(new InvalidOperationException("The test autostart store cannot delete tasks."));
    }

    private sealed class InMemoryCurrentUserShellIntegrationStore : ICurrentUserShellIntegrationStore
    {
        private bool owned;

        public ValueTask<CurrentUserShellIntegrationSnapshot> InspectAsync(
            CurrentUserInstallationTarget target,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var spec = CurrentUserShellIntegrationSpec.Create(
                target,
                Path.Combine(Path.GetTempPath(), "LocalAIGateway-Test-AppData"));
            return ValueTask.FromResult(new CurrentUserShellIntegrationSnapshot(
                spec,
                owned,
                owned
                    ? CurrentUserShellIntegrationComponentState.Owned
                    : CurrentUserShellIntegrationComponentState.Absent,
                owned
                    ? CurrentUserShellIntegrationComponentState.Owned
                    : CurrentUserShellIntegrationComponentState.Absent));
        }

        public ValueTask CreateAsync(
            CurrentUserInstallationTarget target,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            owned = true;
            return ValueTask.CompletedTask;
        }

        public ValueTask DeleteAsync(
            CurrentUserInstallationTarget target,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            owned = false;
            return ValueTask.CompletedTask;
        }
    }
}
