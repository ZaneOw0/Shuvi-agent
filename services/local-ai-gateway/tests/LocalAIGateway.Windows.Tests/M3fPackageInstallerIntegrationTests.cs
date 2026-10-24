using LocalAIGateway.Windows.Installation;

namespace LocalAIGateway.Windows.Tests;

public sealed class M3fPackageInstallerIntegrationTests
{
    [Fact]
    public async Task Package_installation_action_from_environment()
    {
        var packageRoot = Environment.GetEnvironmentVariable("AIGW_M3F_PACKAGE_ROOT");
        var installRoot = Environment.GetEnvironmentVariable("AIGW_M3F_INSTALL_ROOT");
        var action = Environment.GetEnvironmentVariable("AIGW_M3F_INSTALL_ACTION");
        if (string.IsNullOrWhiteSpace(packageRoot) ||
            string.IsNullOrWhiteSpace(installRoot) ||
            string.IsNullOrWhiteSpace(action))
        {
            return;
        }

        Assert.True(Path.IsPathFullyQualified(packageRoot));
        Assert.True(Path.IsPathFullyQualified(installRoot));
        var installer = new WindowsPackageInstaller();
        switch (action)
        {
            case "install":
                Assert.True(Directory.Exists(packageRoot));
                Assert.False(Directory.Exists(installRoot));
                var installed = await installer.InstallAsync(packageRoot, installRoot);
                Assert.True(installed.Installed);
                Assert.False(installed.AlreadyInstalled);
                Assert.True(File.Exists(Path.Combine(installRoot, "aigw.exe")));
                Assert.True(File.Exists(Path.Combine(installRoot, "runtime", "python", "python.exe")));
                break;
            case "uninstall":
                Assert.True(Directory.Exists(installRoot));
                var removed = await installer.UninstallAsync(installRoot);
                Assert.True(removed.Removed);
                Assert.False(removed.AlreadyAbsent);
                Assert.Empty(removed.PreservedPaths);
                Assert.False(Directory.Exists(installRoot));
                break;
            default:
                throw new InvalidOperationException($"Unsupported M3f install action: {action}");
        }
    }
}
