using System.IO;

namespace LocalAIGateway.Tray;

public static class TrayApplicationLayout
{
    public static string ResolvePackageRoot(string applicationBaseDirectory)
    {
        if (string.IsNullOrWhiteSpace(applicationBaseDirectory) ||
            !Path.IsPathFullyQualified(applicationBaseDirectory))
        {
            throw new ArgumentException(
                "The Tray application base directory must be fully qualified.",
                nameof(applicationBaseDirectory));
        }

        var baseDirectory = Path.GetFullPath(applicationBaseDirectory)
            .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var parent = Directory.GetParent(baseDirectory)?.FullName;
        if (parent is not null &&
            Path.GetFileName(baseDirectory).Equals("tray", StringComparison.OrdinalIgnoreCase) &&
            File.Exists(Path.Combine(parent, "PACKAGE-MANIFEST.json")) &&
            File.Exists(Path.Combine(parent, "runtime", "python", "python.exe")) &&
            File.Exists(Path.Combine(parent, "runtime-tools", "aigw_usage_query.py")))
        {
            return Path.GetFullPath(parent);
        }

        return baseDirectory;
    }
}
