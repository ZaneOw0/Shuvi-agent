using LocalAIGateway.Core.Configuration;
using LocalAIGateway.Core.Installation;

namespace LocalAIGateway.Core.Tests;

public sealed class CurrentUserInstallationPlanTests
{
    [Fact]
    public void Create_derives_the_locked_current_user_paths()
    {
        var localAppData = Path.Combine(Path.GetTempPath(), "Local AppData With Spaces");
        var packageRoot = Path.Combine(Path.GetTempPath(), "Package Source With Spaces");

        var plan = CurrentUserInstallationPlan.Create(packageRoot, localAppData);

        Assert.Equal(Path.GetFullPath(packageRoot), plan.PackageSourceRoot);
        Assert.Equal(
            Path.Combine(Path.GetFullPath(localAppData), "Programs", "LocalAIGateway"),
            plan.InstallRoot);
        Assert.Equal(
            Path.Combine(Path.GetFullPath(localAppData), "LocalAIGateway"),
            plan.StateRoot);
        Assert.Equal(Path.Combine(plan.StateRoot, "runtime"), plan.RuntimeStateRoot);
        Assert.Equal(Path.Combine(plan.InstallRoot, "aigw-runtime.exe"), plan.RuntimeExecutablePath);
        Assert.Equal(CredentialTargets.RuntimeClientToken, plan.RuntimeCredentialTarget);
        Assert.Equal(plan.InstallRoot, plan.Target.InstallRoot);
        Assert.Equal(plan.RuntimeExecutablePath, plan.Target.RuntimeExecutablePath);
        Assert.Equal(Path.Combine(plan.InstallRoot, "tray"), plan.Target.TrayDirectory);
        Assert.Equal(Path.Combine(plan.InstallRoot, "tray", "aigw-tray.exe"), plan.Target.TrayExecutablePath);
    }

    [Fact]
    public void CreateTarget_derives_uninstall_and_daemon_paths_without_a_package_source()
    {
        var localAppData = Path.Combine(Path.GetTempPath(), "Target Local AppData With Spaces");

        var target = CurrentUserInstallationPlan.CreateTarget(localAppData);

        Assert.Equal(
            Path.Combine(Path.GetFullPath(localAppData), "Programs", "LocalAIGateway"),
            target.InstallRoot);
        Assert.Equal(
            Path.Combine(Path.GetFullPath(localAppData), "LocalAIGateway"),
            target.StateRoot);
        Assert.Equal(Path.Combine(target.StateRoot, "runtime"), target.RuntimeStateRoot);
        Assert.Equal(Path.Combine(target.InstallRoot, "aigw-runtime.exe"), target.RuntimeExecutablePath);
        Assert.Equal(Path.Combine(target.InstallRoot, "tray"), target.TrayDirectory);
        Assert.Equal(Path.Combine(target.TrayDirectory, "aigw-tray.exe"), target.TrayExecutablePath);
        Assert.Equal(CredentialTargets.RuntimeClientToken, target.RuntimeCredentialTarget);
    }

    [Theory]
    [InlineData("relative-package", "C:\\Users\\test\\AppData\\Local")]
    [InlineData("C:\\package", "relative-local-appdata")]
    [InlineData("C:\\", "C:\\Users\\test\\AppData\\Local")]
    [InlineData("C:\\package", "C:\\")]
    public void Create_rejects_relative_paths_and_volume_roots(string packageRoot, string localAppData)
    {
        var failure = Assert.Throws<InstallationException>(
            () => CurrentUserInstallationPlan.Create(packageRoot, localAppData));

        Assert.Equal("aigw_install_path_invalid", failure.ErrorCode);
    }

    [Fact]
    public void Create_rejects_a_package_source_inside_the_install_or_state_roots()
    {
        var localAppData = Path.Combine(Path.GetTempPath(), $"aigw-plan-{Guid.NewGuid():N}");
        var installSource = Path.Combine(localAppData, "Programs", "LocalAIGateway", "source");
        var stateSource = Path.Combine(localAppData, "LocalAIGateway", "downloads", "source");

        var installFailure = Assert.Throws<InstallationException>(
            () => CurrentUserInstallationPlan.Create(installSource, localAppData));
        var stateFailure = Assert.Throws<InstallationException>(
            () => CurrentUserInstallationPlan.Create(stateSource, localAppData));

        Assert.Equal("aigw_install_path_overlap", installFailure.ErrorCode);
        Assert.Equal("aigw_install_path_overlap", stateFailure.ErrorCode);
    }
}
