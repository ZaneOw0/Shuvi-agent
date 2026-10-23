using LocalAIGateway.Core.Configuration;

namespace LocalAIGateway.Core.Installation;

public sealed record CurrentUserInstallationTarget(
    string InstallRoot,
    string StateRoot,
    string RuntimeStateRoot,
    string RuntimeExecutablePath,
    string RuntimeCredentialTarget)
{
    public string TrayDirectory => Path.Combine(InstallRoot, "tray");

    public string TrayExecutablePath => Path.Combine(TrayDirectory, "aigw-tray.exe");
}

public sealed record CurrentUserInstallationPlan(
    string PackageSourceRoot,
    string InstallRoot,
    string StateRoot,
    string RuntimeStateRoot,
    string RuntimeExecutablePath,
    string RuntimeCredentialTarget)
{
    public CurrentUserInstallationTarget Target => new(
        InstallRoot,
        StateRoot,
        RuntimeStateRoot,
        RuntimeExecutablePath,
        RuntimeCredentialTarget);

    public static CurrentUserInstallationPlan CreateForCurrentUser(string packageSourceRoot)
    {
        return Create(packageSourceRoot, ResolveCurrentUserLocalAppData());
    }

    public static CurrentUserInstallationTarget CreateTargetForCurrentUser() =>
        CreateTarget(ResolveCurrentUserLocalAppData());

    public static CurrentUserInstallationPlan Create(string packageSourceRoot, string localAppDataRoot)
    {
        var packageSource = NormalizeNonRoot(packageSourceRoot, "package source");
        var target = CreateTarget(localAppDataRoot);
        if (Overlaps(packageSource, target.InstallRoot) || Overlaps(packageSource, target.StateRoot))
        {
            throw new InstallationException(
                "aigw_install_path_overlap",
                "Package source must not overlap the current-user program or state roots.");
        }

        return new CurrentUserInstallationPlan(
            packageSource,
            target.InstallRoot,
            target.StateRoot,
            target.RuntimeStateRoot,
            target.RuntimeExecutablePath,
            target.RuntimeCredentialTarget);
    }

    public static CurrentUserInstallationTarget CreateTarget(string localAppDataRoot)
    {
        var localAppData = NormalizeNonRoot(localAppDataRoot, "local application data");
        var installRoot = Path.Combine(localAppData, "Programs", "LocalAIGateway");
        var stateRoot = Path.Combine(localAppData, "LocalAIGateway");
        return new CurrentUserInstallationTarget(
            installRoot,
            stateRoot,
            Path.Combine(stateRoot, "runtime"),
            Path.Combine(installRoot, "aigw-runtime.exe"),
            CredentialTargets.RuntimeClientToken);
    }

    private static string ResolveCurrentUserLocalAppData()
    {
        var localAppData = Environment.GetEnvironmentVariable("LOCALAPPDATA");
        if (string.IsNullOrWhiteSpace(localAppData))
        {
            localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        }

        return localAppData;
    }

    private static string NormalizeNonRoot(string path, string label)
    {
        if (string.IsNullOrWhiteSpace(path) || !Path.IsPathFullyQualified(path))
        {
            throw InvalidPath(label);
        }

        var resolved = Path.GetFullPath(path);
        var normalized = resolved.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var volumeRoot = Path.GetPathRoot(resolved)?.TrimEnd(
            Path.DirectorySeparatorChar,
            Path.AltDirectorySeparatorChar);
        if (string.IsNullOrEmpty(normalized) ||
            string.Equals(normalized, volumeRoot, StringComparison.OrdinalIgnoreCase))
        {
            throw InvalidPath(label);
        }

        return normalized;
    }

    private static bool Overlaps(string first, string second)
    {
        var firstPrefix = first + Path.DirectorySeparatorChar;
        var secondPrefix = second + Path.DirectorySeparatorChar;
        return string.Equals(first, second, StringComparison.OrdinalIgnoreCase) ||
               first.StartsWith(secondPrefix, StringComparison.OrdinalIgnoreCase) ||
               second.StartsWith(firstPrefix, StringComparison.OrdinalIgnoreCase);
    }

    private static InstallationException InvalidPath(string label) => new(
        "aigw_install_path_invalid",
        $"The {label} root must be a fully qualified non-volume-root path.");
}
