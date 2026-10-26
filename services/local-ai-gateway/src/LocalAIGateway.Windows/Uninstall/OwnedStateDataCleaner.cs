using LocalAIGateway.Core.Installation;

namespace LocalAIGateway.Windows.Uninstall;

public sealed record OwnedStateDataCleanupRequest(
    string StateRoot,
    bool RemoveConfiguration,
    bool RemoveUsage,
    bool RemoveLogs,
    bool RemoveOperationalState = false);

public sealed record OwnedStateDataCategoryResult(
    bool Selected,
    bool Removed,
    bool AlreadyAbsent,
    IReadOnlyList<string> PreservedPaths);

public sealed record OwnedStateDataCleanupResult(
    OwnedStateDataCategoryResult Configuration,
    OwnedStateDataCategoryResult Usage,
    OwnedStateDataCategoryResult Logs,
    OwnedStateDataCategoryResult OperationalState,
    bool StateRootRemoved);

public sealed class OwnedStateDataCleaner
{
    private static readonly string[] ConfigurationNames =
    [
        "config.json",
        "config.json.bak",
        "config.lock",
    ];

    public OwnedStateDataCleanupResult Clean(OwnedStateDataCleanupRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        var stateRoot = NormalizeRoot(request.StateRoot);
        if (TryGetAttributes(stateRoot, out var stateAttributes) &&
            ((stateAttributes & FileAttributes.Directory) == 0 ||
             (stateAttributes & FileAttributes.ReparsePoint) != 0))
        {
            throw UnsafePath("The Local AI Gateway state root is not a regular directory.");
        }

        var usageRoot = Path.Combine(stateRoot, "usage");
        var logsRoot = Path.Combine(stateRoot, "logs");
        var operationalRoots = new[]
        {
            Path.Combine(stateRoot, "runtime"),
            Path.Combine(stateRoot, "update-workers"),
            Path.Combine(stateRoot, "update-receipts"),
        };

        // Complete every traversal check before the first deletion.
        var configurationPaths = request.RemoveConfiguration
            ? InspectConfiguration(stateRoot)
            : Array.Empty<string>();
        var usagePaths = request.RemoveUsage
            ? InspectOwnedDirectory(usageRoot, "usage")
            : Array.Empty<string>();
        var logPaths = request.RemoveLogs
            ? InspectOwnedDirectory(logsRoot, "logs")
            : Array.Empty<string>();
        var operationalPaths = request.RemoveOperationalState
            ? operationalRoots.SelectMany(path => InspectOwnedDirectory(path, "operational state")).ToArray()
            : Array.Empty<string>();

        var configuration = RemoveConfiguration(
            request.RemoveConfiguration,
            stateRoot,
            configurationPaths);
        var usage = RemoveDirectory(request.RemoveUsage, usageRoot, usagePaths);
        var logs = RemoveDirectory(request.RemoveLogs, logsRoot, logPaths);
        var operational = RemoveDirectories(
            request.RemoveOperationalState,
            operationalRoots,
            operationalPaths);

        var stateRootRemoved = false;
        if (Directory.Exists(stateRoot) && !Directory.EnumerateFileSystemEntries(stateRoot).Any())
        {
            Directory.Delete(stateRoot);
            stateRootRemoved = true;
        }

        return new OwnedStateDataCleanupResult(configuration, usage, logs, operational, stateRootRemoved);
    }

    private static string[] InspectConfiguration(string stateRoot)
    {
        if (!Directory.Exists(stateRoot))
        {
            return [];
        }

        var paths = new List<string>();
        foreach (var name in ConfigurationNames)
        {
            var path = Path.Combine(stateRoot, name);
            if (TryGetAttributes(path, out _))
            {
                EnsureRegularFile(path, "configuration");
                paths.Add(path);
            }
        }

        foreach (var path in Directory.EnumerateFiles(stateRoot, "config.*", SearchOption.TopDirectoryOnly))
        {
            var name = Path.GetFileName(path);
            if (ConfigurationNames.Contains(name, StringComparer.OrdinalIgnoreCase) ||
                !IsOwnedConfigurationTemporaryName(name))
            {
                continue;
            }

            EnsureRegularFile(path, "configuration");
            paths.Add(path);
        }

        return paths.Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
    }

    private static string[] InspectOwnedDirectory(string directory, string category)
    {
        if (!TryGetAttributes(directory, out var rootAttributes))
        {
            return [];
        }
        if ((rootAttributes & FileAttributes.Directory) == 0)
        {
            throw UnsafePath($"The {category} path is a file instead of an owned directory.");
        }
        if ((rootAttributes & FileAttributes.ReparsePoint) != 0)
        {
            throw UnsafePath($"The {category} directory contains a reparse point.");
        }

        var pending = new Stack<string>();
        var paths = new List<string>();
        pending.Push(directory);
        while (pending.Count > 0)
        {
            var current = pending.Pop();
            var currentAttributes = File.GetAttributes(current);
            if ((currentAttributes & FileAttributes.Directory) == 0 ||
                (currentAttributes & FileAttributes.ReparsePoint) != 0)
            {
                throw UnsafePath($"The {category} directory contains a reparse point.");
            }

            paths.Add(current);
            foreach (var entry in Directory.EnumerateFileSystemEntries(current))
            {
                var attributes = File.GetAttributes(entry);
                if ((attributes & FileAttributes.ReparsePoint) != 0)
                {
                    throw UnsafePath($"The {category} directory contains a reparse point.");
                }

                if ((attributes & FileAttributes.Directory) != 0)
                {
                    pending.Push(entry);
                }
                else
                {
                    paths.Add(entry);
                }
            }
        }

        return paths.ToArray();
    }

    private static OwnedStateDataCategoryResult RemoveConfiguration(
        bool selected,
        string stateRoot,
        IReadOnlyList<string> paths)
    {
        if (!selected)
        {
            return new(false, false, false, []);
        }
        if (!Directory.Exists(stateRoot) || paths.Count == 0)
        {
            return new(true, false, true, []);
        }

        foreach (var path in paths)
        {
            File.Delete(path);
        }
        return new(true, true, false, []);
    }

    private static OwnedStateDataCategoryResult RemoveDirectory(
        bool selected,
        string directory,
        IReadOnlyList<string> inspectedPaths)
    {
        if (!selected)
        {
            return new(false, false, false, []);
        }
        if (!Directory.Exists(directory))
        {
            return new(true, false, true, []);
        }

        foreach (var path in inspectedPaths.OrderByDescending(path => path.Length))
        {
            if (!TryGetAttributes(path, out var attributes))
            {
                continue;
            }
            if ((attributes & FileAttributes.ReparsePoint) != 0)
            {
                throw UnsafePath("Selected Local AI Gateway data changed to a reparse point during cleanup.");
            }
            if ((attributes & FileAttributes.Directory) != 0)
            {
                Directory.Delete(path);
            }
            else
            {
                File.Delete(path);
            }
        }
        return new(true, true, false, []);
    }

    private static OwnedStateDataCategoryResult RemoveDirectories(
        bool selected,
        IReadOnlyList<string> directories,
        IReadOnlyList<string> inspectedPaths)
    {
        if (!selected)
        {
            return new(false, false, false, []);
        }
        if (!directories.Any(Directory.Exists))
        {
            return new(true, false, true, []);
        }

        foreach (var path in inspectedPaths.OrderByDescending(path => path.Length))
        {
            if (!TryGetAttributes(path, out var attributes))
            {
                continue;
            }
            if ((attributes & FileAttributes.ReparsePoint) != 0)
            {
                throw UnsafePath("Selected Local AI Gateway operational state changed to a reparse point during cleanup.");
            }
            if ((attributes & FileAttributes.Directory) != 0)
            {
                Directory.Delete(path);
            }
            else
            {
                File.Delete(path);
            }
        }
        return new(true, true, false, []);
    }

    private static void EnsureRegularFile(string path, string category)
    {
        var attributes = File.GetAttributes(path);
        if ((attributes & FileAttributes.Directory) != 0 ||
            (attributes & FileAttributes.ReparsePoint) != 0)
        {
            throw UnsafePath($"The {category} data contains a directory or reparse point where a regular file is required.");
        }
    }

    private static bool IsOwnedConfigurationTemporaryName(string name)
    {
        const string prefix = "config.";
        const string temporarySuffix = ".tmp";
        const string backupTemporarySuffix = ".bak.tmp";
        if (!name.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        var suffix = name.EndsWith(backupTemporarySuffix, StringComparison.OrdinalIgnoreCase)
            ? backupTemporarySuffix
            : name.EndsWith(temporarySuffix, StringComparison.OrdinalIgnoreCase)
                ? temporarySuffix
                : null;
        if (suffix is null)
        {
            return false;
        }

        var identifier = name[prefix.Length..^suffix.Length];
        return identifier.Length == 32 && identifier.All(Uri.IsHexDigit);
    }

    private static string NormalizeRoot(string path)
    {
        if (string.IsNullOrWhiteSpace(path) || !Path.IsPathFullyQualified(path))
        {
            throw UnsafePath("The Local AI Gateway state root must be an absolute path.");
        }

        var resolved = Path.GetFullPath(path);
        var normalized = resolved.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var volumeRoot = Path.GetPathRoot(resolved)?.TrimEnd(
            Path.DirectorySeparatorChar,
            Path.AltDirectorySeparatorChar);
        if (normalized.Length == 0 || normalized.Equals(volumeRoot, StringComparison.OrdinalIgnoreCase))
        {
            throw UnsafePath("The Local AI Gateway state root must not be a volume root.");
        }
        return normalized;
    }

    private static bool TryGetAttributes(string path, out FileAttributes attributes)
    {
        try
        {
            attributes = File.GetAttributes(path);
            return true;
        }
        catch (FileNotFoundException)
        {
            attributes = default;
            return false;
        }
        catch (DirectoryNotFoundException)
        {
            attributes = default;
            return false;
        }
    }

    private static InstallationException UnsafePath(string message) => new(
        "aigw_uninstall_state_path_unsafe",
        message);
}
