using LocalAIGateway.Core.Credentials;
using LocalAIGateway.Core.Installation;
using LocalAIGateway.Core.Runtime;
using LocalAIGateway.Core.Uninstall;
using LocalAIGateway.Windows.Installation;
using LocalAIGateway.Windows.Runtime;

namespace LocalAIGateway.Windows.Uninstall;

public sealed record CurrentUserPlatformUninstallResult(
    UninstallCategoryResult Program,
    UninstallCategoryResult Autostart,
    UninstallCategoryResult RuntimeCredential,
    UninstallCategoryResult ProviderCredentials,
    UninstallCategoryResult Configuration,
    UninstallCategoryResult Usage,
    UninstallCategoryResult Logs);

public interface ICurrentUserUninstallCoordinator
{
    Task<CurrentUserPlatformUninstallResult> UninstallAsync(
        CurrentUserInstallationTarget target,
        UninstallSelection selection,
        CancellationToken cancellationToken = default);
}

public sealed class CurrentUserUninstallCoordinator : ICurrentUserUninstallCoordinator
{
    private readonly WindowsPackageInstaller packageInstaller;
    private readonly IGatewayDaemonController daemon;
    private readonly ICurrentUserAutostartStore autostartStore;
    private readonly ICurrentUserShellIntegrationStore shellIntegrationStore;
    private readonly OwnedCredentialCleaner credentialCleaner;
    private readonly OwnedStateDataCleaner stateCleaner;
    private readonly ISingleInstanceProvider installationLock;

    public CurrentUserUninstallCoordinator(
        WindowsPackageInstaller packageInstaller,
        IGatewayDaemonController daemon,
        ICredentialStore credentialStore,
        ICredentialTargetCatalog credentialCatalog)
        : this(
            packageInstaller,
            daemon,
            new WindowsTaskSchedulerAutostartStore(),
            new WindowsCurrentUserShellIntegrationStore(),
            new OwnedCredentialCleaner(credentialStore, credentialCatalog),
            new OwnedStateDataCleaner(),
            new WindowsCurrentUserSingleInstanceProvider("install"))
    {
    }

    internal CurrentUserUninstallCoordinator(
        WindowsPackageInstaller packageInstaller,
        IGatewayDaemonController daemon,
        ICurrentUserAutostartStore autostartStore,
        OwnedCredentialCleaner credentialCleaner,
        OwnedStateDataCleaner stateCleaner,
        ISingleInstanceProvider installationLock)
        : this(
            packageInstaller,
            daemon,
            autostartStore,
            AbsentShellIntegrationStore.Instance,
            credentialCleaner,
            stateCleaner,
            installationLock)
    {
    }

    internal CurrentUserUninstallCoordinator(
        WindowsPackageInstaller packageInstaller,
        IGatewayDaemonController daemon,
        ICurrentUserAutostartStore autostartStore,
        ICurrentUserShellIntegrationStore shellIntegrationStore,
        OwnedCredentialCleaner credentialCleaner,
        OwnedStateDataCleaner stateCleaner,
        ISingleInstanceProvider installationLock)
    {
        this.packageInstaller = packageInstaller ?? throw new ArgumentNullException(nameof(packageInstaller));
        this.daemon = daemon ?? throw new ArgumentNullException(nameof(daemon));
        this.autostartStore = autostartStore ?? throw new ArgumentNullException(nameof(autostartStore));
        this.shellIntegrationStore = shellIntegrationStore ?? throw new ArgumentNullException(nameof(shellIntegrationStore));
        this.credentialCleaner = credentialCleaner ?? throw new ArgumentNullException(nameof(credentialCleaner));
        this.stateCleaner = stateCleaner ?? throw new ArgumentNullException(nameof(stateCleaner));
        this.installationLock = installationLock ?? throw new ArgumentNullException(nameof(installationLock));
    }

    public async Task<CurrentUserPlatformUninstallResult> UninstallAsync(
        CurrentUserInstallationTarget target,
        UninstallSelection selection,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(target);
        ArgumentNullException.ThrowIfNull(selection);
        using var lease = installationLock.TryAcquire()
            ?? throw new InstallationException(
                "aigw_install_busy",
                "Another Local AI Gateway installation, update, or uninstall is already in progress.");

        var autostartState = selection.Autostart == UninstallChoice.Remove
            ? await autostartStore.InspectAsync(target, cancellationToken)
            : new CurrentUserAutostartTaskSnapshot(
                CurrentUserAutostartTaskState.Absent,
                CurrentUserAutostartTaskState.Absent);
        if (autostartState.HasConflict)
        {
            throw new InstallationException(
                "aigw_autostart_conflict",
                "One or more fixed login tasks have a different definition and were preserved.");
        }
        var shellIntegrationState = selection.Program == UninstallChoice.Remove
            ? await shellIntegrationStore.InspectAsync(target, cancellationToken)
            : null;
        if (shellIntegrationState?.HasConflict == true)
        {
            throw new InstallationException(
                "aigw_shell_integration_conflict",
                "The current-user PATH or Start Menu entry is not owned; all uninstall targets were preserved.");
        }

        cancellationToken.ThrowIfCancellationRequested();
        if (HasPlatformMutation(selection))
        {
            await daemon.StopAsync(cancellationToken);
        }

        var autostart = await RemoveAutostartAsync(target, selection.Autostart, autostartState);
        var program = await RemoveProgramAsync(
            target,
            selection.Program,
            shellIntegrationState,
            cancellationToken);
        var credentials = selection.RuntimeCredential == UninstallChoice.Remove ||
                          selection.ProviderCredentials == UninstallChoice.Remove
            ? await credentialCleaner.CleanAsync(new(
                selection.RuntimeCredential == UninstallChoice.Remove,
                selection.ProviderCredentials == UninstallChoice.Remove), cancellationToken)
            : new OwnedCredentialCleanupResult(false, false, false, false, [], []);
        var state = selection.Configuration == UninstallChoice.Remove ||
                    selection.Usage == UninstallChoice.Remove ||
                    selection.Logs == UninstallChoice.Remove ||
                    selection.Program == UninstallChoice.Remove
            ? stateCleaner.Clean(new OwnedStateDataCleanupRequest(
                target.StateRoot,
                selection.Configuration == UninstallChoice.Remove,
                selection.Usage == UninstallChoice.Remove,
                selection.Logs == UninstallChoice.Remove,
                RemoveOperationalState: selection.Program == UninstallChoice.Remove))
            : SkippedState();

        return new CurrentUserPlatformUninstallResult(
            MergeProgramAndOperationalState(program, state.OperationalState),
            autostart,
            new UninstallCategoryResult(
                credentials.RuntimeSelected,
                credentials.RuntimeDeleted,
                credentials.RuntimeAlreadyAbsent,
                []),
            new UninstallCategoryResult(
                credentials.ProvidersSelected,
                credentials.DeletedProviderTargets.Count != 0,
                credentials.ProvidersSelected && credentials.DeletedProviderTargets.Count == 0,
                credentials.PreservedTargets),
            ToCategory(state.Configuration),
            ToCategory(state.Usage),
            ToCategory(state.Logs));
    }

    private async Task<UninstallCategoryResult> RemoveAutostartAsync(
        CurrentUserInstallationTarget target,
        UninstallChoice choice,
        CurrentUserAutostartTaskSnapshot state)
    {
        if (choice == UninstallChoice.Keep)
        {
            return Skipped();
        }
        if (state.IsAbsent)
        {
            return Absent();
        }

        await autostartStore.DeleteAsync(target, CancellationToken.None);
        if (!(await autostartStore.InspectAsync(target, CancellationToken.None)).IsAbsent)
        {
            throw new InstallationException(
                "aigw_autostart_removal_failed",
                "One or more owned current-user login autostart tasks still exist after removal.");
        }
        return Changed();
    }

    private async Task<UninstallCategoryResult> RemoveProgramAsync(
        CurrentUserInstallationTarget target,
        UninstallChoice choice,
        CurrentUserShellIntegrationSnapshot? shellIntegrationState,
        CancellationToken cancellationToken)
    {
        if (choice == UninstallChoice.Keep)
        {
            return Skipped();
        }

        var result = await packageInstaller.UninstallAsync(target.InstallRoot, cancellationToken);
        if (!result.Removed && !result.AlreadyAbsent)
        {
            throw new InstallationException(
                "aigw_uninstall_incomplete",
                $"Uninstall preserved {result.PreservedPaths.Count} unknown or modified program path(s).");
        }
        var shellIntegrationRemoved = false;
        if (shellIntegrationState is not null && !shellIntegrationState.IsAbsent)
        {
            await shellIntegrationStore.DeleteAsync(target, cancellationToken);
            var afterDelete = await shellIntegrationStore.InspectAsync(target, cancellationToken);
            if (!afterDelete.IsAbsent)
            {
                throw new InstallationException(
                    "aigw_shell_integration_removal_failed",
                    "Owned current-user PATH or Start Menu integration remains after program removal.");
            }
            shellIntegrationRemoved = true;
        }
        return new UninstallCategoryResult(
            true,
            result.Removed || shellIntegrationRemoved,
            result.AlreadyAbsent && !shellIntegrationRemoved,
            result.PreservedPaths);
    }

    private static UninstallCategoryResult MergeProgramAndOperationalState(
        UninstallCategoryResult program,
        OwnedStateDataCategoryResult operational)
    {
        if (!program.Selected)
        {
            return program;
        }
        return program with
        {
            Changed = program.Changed || operational.Removed,
            AlreadyAbsent = program.AlreadyAbsent && operational.AlreadyAbsent,
        };
    }

    private static bool HasPlatformMutation(UninstallSelection selection) =>
        selection.Program == UninstallChoice.Remove ||
        selection.Autostart == UninstallChoice.Remove ||
        selection.RuntimeCredential == UninstallChoice.Remove ||
        selection.ProviderCredentials == UninstallChoice.Remove ||
        selection.Configuration == UninstallChoice.Remove ||
        selection.Usage == UninstallChoice.Remove ||
        selection.Logs == UninstallChoice.Remove;

    private static UninstallCategoryResult ToCategory(OwnedStateDataCategoryResult result) => new(
        result.Selected,
        result.Removed,
        result.AlreadyAbsent,
        result.PreservedPaths);

    private static UninstallCategoryResult Skipped() => new(false, false, false, []);
    private static UninstallCategoryResult Absent() => new(true, false, true, []);
    private static UninstallCategoryResult Changed() => new(true, true, false, []);

    private static OwnedStateDataCleanupResult SkippedState()
    {
        var skipped = new OwnedStateDataCategoryResult(false, false, false, []);
        return new OwnedStateDataCleanupResult(skipped, skipped, skipped, skipped, false);
    }

    private sealed class AbsentShellIntegrationStore : ICurrentUserShellIntegrationStore
    {
        public static AbsentShellIntegrationStore Instance { get; } = new();

        public ValueTask<CurrentUserShellIntegrationSnapshot> InspectAsync(
            CurrentUserInstallationTarget target,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return ValueTask.FromResult(new CurrentUserShellIntegrationSnapshot(
                CurrentUserShellIntegrationSpec.Create(
                    target,
                    Path.Combine(Path.GetTempPath(), "LocalAIGateway-Test-AppData")),
                false,
                CurrentUserShellIntegrationComponentState.Absent,
                CurrentUserShellIntegrationComponentState.Absent));
        }

        public ValueTask CreateAsync(
            CurrentUserInstallationTarget target,
            CancellationToken cancellationToken = default) =>
            ValueTask.FromException(new InvalidOperationException("The uninstall shell-integration store cannot create entries."));

        public ValueTask DeleteAsync(
            CurrentUserInstallationTarget target,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return ValueTask.CompletedTask;
        }
    }
}
