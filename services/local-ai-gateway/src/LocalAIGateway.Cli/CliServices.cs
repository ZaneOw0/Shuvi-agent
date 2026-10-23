using LocalAIGateway.Core.Backup;
using LocalAIGateway.Core.Configuration;
using LocalAIGateway.Core.Credentials;
using LocalAIGateway.Core.Installation;
using LocalAIGateway.Core.Usage;
using LocalAIGateway.Core.Update;
using LocalAIGateway.Core.Uninstall;
using LocalAIGateway.Launcher;
using LocalAIGateway.Launcher.Uninstall;
using LocalAIGateway.Windows;
using LocalAIGateway.Windows.Backup;
using LocalAIGateway.Windows.Control;
using LocalAIGateway.Windows.Installation;
using LocalAIGateway.Windows.Runtime;
using LocalAIGateway.Windows.Usage;
using LocalAIGateway.Windows.Update;
using LocalAIGateway.Windows.Uninstall;

namespace LocalAIGateway.Cli;

public sealed record CliOperationalServices(
    ICurrentUserInstallationCoordinator Installation,
    IGatewayDaemonController Daemon,
    CurrentUserInstallationTarget Target,
    Func<CurrentUserInstallationPlan> CreateInstallPlan,
    string CommandBaseDirectory);

public sealed record CliClientServices(
    IClientLaunchService Launcher,
    ClientLaunchRequestFactory RequestFactory);

public sealed record CliIntegrationServices(
    IClientIntegrationPreviewer Previewer,
    IClientIntegrationApplier? Applier = null,
    IClientIntegrationLifecycleManager? Lifecycle = null);

public sealed record CliUsageServices(
    IUsageSummaryReader Reader,
    TimeProvider TimeProvider);

public sealed record CliBackupServices(BackupCoordinator Coordinator);

public sealed record CliUpdateServices(IPackageUpdateService Service);

public sealed record CliUninstallServices(IUninstallService Service);

public sealed record CliServices(
    GatewayConfigurationManager Configuration,
    CliOperationalServices? Operations = null,
    CliClientServices? Clients = null,
    CliIntegrationServices? Integrations = null,
    CliUsageServices? Usage = null,
    CliBackupServices? Backup = null,
    CliUpdateServices? Update = null,
    CliUninstallServices? Uninstall = null)
{
    public static CliServices CreateDefault()
    {
        ICredentialStore credentialStore = new WindowsCredentialStore();
        var configurationStore = new ConfigurationStore(
            ConfigurationPaths.ForCurrentUser(),
            new WindowsConfigurationFileSecurity());
        var installation = new CurrentUserInstallationCoordinator(
            new WindowsPackageInstaller(),
            credentialStore);
        var control = new WindowsNamedPipeControlClient(
            WindowsControlPipeName.ForCurrentUser(),
            TimeSpan.FromMilliseconds(250),
            TimeSpan.FromSeconds(70));
        var target = CurrentUserInstallationPlan.CreateTargetForCurrentUser();
        var daemon = new GatewayDaemonController(control);
        var integrationPreviewer = new ClientIntegrationPreviewer();
        var commandBaseDirectory = Path.GetFullPath(AppContext.BaseDirectory);
        IUninstallService uninstallService = IsSameDirectory(commandBaseDirectory, target.InstallRoot)
            ? new UninstallerProcessClient(target, commandBaseDirectory)
            : new CompleteUninstallExecutor(
                target,
                commandBaseDirectory,
                new CurrentUserUninstallCoordinator(
                    new WindowsPackageInstaller(),
                    daemon,
                    credentialStore,
                    (ICredentialTargetCatalog)credentialStore),
                new ClientIntegrationLifecycleManager(),
                new BackupFileCleaner());
        return new CliServices(
            new GatewayConfigurationManager(configurationStore, credentialStore),
            new CliOperationalServices(
                installation,
                daemon,
                target,
                () => CurrentUserInstallationPlan.CreateForCurrentUser(AppContext.BaseDirectory),
                commandBaseDirectory),
            new CliClientServices(
                new GatewayClientLauncher(daemon, credentialStore, target),
                new ClientLaunchRequestFactory(new WindowsClientExecutableResolver())),
            new CliIntegrationServices(
                integrationPreviewer,
                new ClientIntegrationApplier(integrationPreviewer),
                new ClientIntegrationLifecycleManager()),
            new CliUsageServices(
                new PrivatePythonUsageSummaryReader(AppContext.BaseDirectory, target.StateRoot),
                TimeProvider.System),
            new CliBackupServices(new BackupCoordinator(
                configurationStore,
                credentialStore,
                new PrivatePythonBackupCryptography(AppContext.BaseDirectory),
                new WindowsConfigurationFileSecurity())),
            new CliUpdateServices(new UpdaterProcessClient(target, AppContext.BaseDirectory)),
            new CliUninstallServices(uninstallService));
    }

    private static bool IsSameDirectory(string first, string second) =>
        first.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar).Equals(
            Path.GetFullPath(second).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
            StringComparison.OrdinalIgnoreCase);
}
