using System.Reflection;
using System.Windows;
using LocalAIGateway.Core.Configuration;
using LocalAIGateway.Core.Credentials;
using LocalAIGateway.Core.Installation;
using LocalAIGateway.Windows;
using LocalAIGateway.Windows.Control;
using LocalAIGateway.Windows.Runtime;
using LocalAIGateway.Windows.Usage;

namespace LocalAIGateway.Tray;

public static class Program
{
    public const int SuccessExitCode = 0;
    public const int InvalidArgumentsExitCode = 2;
    public const int RuntimeConflictExitCode = 12;
    public const int UnexpectedErrorExitCode = 70;

    [STAThread]
    public static int Main(string[] args)
    {
        if (args.Length == 1 && args[0].Equals("--version", StringComparison.OrdinalIgnoreCase))
        {
            Console.Out.WriteLine($"Local AI Gateway Tray {GetVersion()}");
            return SuccessExitCode;
        }

        if (args.Length != 0)
        {
            return InvalidArgumentsExitCode;
        }

        try
        {
            using var lifetime = TrayApplicationLifetime.TryCreate(
                new WindowsCurrentUserSingleInstanceProvider("tray"));
            if (lifetime is null)
            {
                return RuntimeConflictExitCode;
            }

            var credentialStore = new WindowsCredentialStore();
            var paths = ConfigurationPaths.ForCurrentUser();
            var configuration = new GatewayConfigurationManager(
                new ConfigurationStore(paths, new WindowsConfigurationFileSecurity()),
                credentialStore);
            var target = CurrentUserInstallationPlan.CreateTargetForCurrentUser();
            var control = new WindowsNamedPipeControlClient(
                WindowsControlPipeName.ForCurrentUser(),
                TimeSpan.FromMilliseconds(250),
                TimeSpan.FromSeconds(70));
            var packageRoot = TrayApplicationLayout.ResolvePackageRoot(AppContext.BaseDirectory);
            using var coordinator = new TrayCoordinator(
                new GatewayTrayProfileStore(configuration),
                new GatewayDaemonController(control),
                new PrivatePythonUsageSummaryReader(packageRoot, target.StateRoot),
                target);

            var application = new System.Windows.Application
            {
                ShutdownMode = ShutdownMode.OnExplicitShutdown,
            };
            using var shell = new TrayShell(application, lifetime, coordinator);
            application.Startup += (_, _) => shell.Start();
            return application.Run();
        }
        catch
        {
            return UnexpectedErrorExitCode;
        }
    }

    private static string GetVersion()
    {
        var assembly = typeof(Program).Assembly;
        return assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion
            ?? assembly.GetName().Version?.ToString()
            ?? "unknown";
    }
}
