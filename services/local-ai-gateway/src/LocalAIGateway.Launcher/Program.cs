using System.Reflection;
using LocalAIGateway.Core.Installation;
using LocalAIGateway.Core.Credentials;
using LocalAIGateway.Windows;
using LocalAIGateway.Windows.Control;
using LocalAIGateway.Windows.Runtime;

namespace LocalAIGateway.Launcher;

internal static class Program
{
    private static async Task<int> Main(string[] args)
    {
        try
        {
            if (args.Length == 1 && args[0] == "--version")
            {
                var assembly = typeof(Program).Assembly;
                var version = assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion
                    ?? assembly.GetName().Version?.ToString()
                    ?? "unknown";
                await Console.Out.WriteLineAsync($"Local AI Gateway Launcher {version}");
                return 0;
            }
            var parsed = LauncherArguments.Parse(args);
            var target = CurrentUserInstallationPlan.CreateTargetForCurrentUser();
            var control = new WindowsNamedPipeControlClient(
                WindowsControlPipeName.ForCurrentUser(),
                TimeSpan.FromMilliseconds(250),
                TimeSpan.FromSeconds(70));
            var launcher = new GatewayClientLauncher(
                new GatewayDaemonController(control),
                new WindowsCredentialStore(),
                target);
            return await launcher.LaunchAsync(parsed.Request);
        }
        catch (ClientLaunchException exception)
        {
            await Console.Error.WriteLineAsync(exception.ErrorCode);
            return 12;
        }
        catch (CredentialException exception)
        {
            await Console.Error.WriteLineAsync(exception.ErrorCode);
            return 11;
        }
        catch (InstallationException exception)
        {
            await Console.Error.WriteLineAsync(exception.ErrorCode);
            return 15;
        }
        catch (GatewayDaemonException exception)
        {
            await Console.Error.WriteLineAsync(exception.ErrorCode);
            return 12;
        }
        catch (Exception)
        {
            await Console.Error.WriteLineAsync("aigw_launcher_failed");
            return 70;
        }
    }
}
