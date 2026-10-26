using System.Security.Cryptography;
using LocalAIGateway.Core.Installation;
using LocalAIGateway.Core.Update;

namespace LocalAIGateway.Windows.Installation;

public sealed record PackageInstallationResult(
    bool Installed,
    bool AlreadyInstalled,
    string InstallRoot);

public sealed record PackageUninstallationResult(
    bool Removed,
    bool AlreadyAbsent,
    IReadOnlyList<string> PreservedPaths);

public sealed record ValidatedPackage(
    PackageManifest Manifest,
    byte[] CanonicalManifest,
    PackageSignature? Signature,
    byte[]? CanonicalSignature);

public sealed class WindowsPackageInstaller
{
    private readonly Func<string, string, CancellationToken, Task> copyFileAsync;

    public WindowsPackageInstaller()
        : this(CopyFileAsync)
    {
    }

    internal WindowsPackageInstaller(
        Func<string, string, CancellationToken, Task> copyFileAsync)
    {
        ArgumentNullException.ThrowIfNull(copyFileAsync);
        this.copyFileAsync = copyFileAsync;
    }

    public async Task<PackageInstallationResult> InstallAsync(
        string sourceRoot,
        string installRoot,
        CancellationToken cancellationToken = default)
    {
        var source = NormalizeOwnedDirectory(sourceRoot, "source");
        var target = NormalizeOwnedDirectory(installRoot, "install");
        RejectOverlappingRoots(source, target);

        PackageDirectory sourcePackage;
        try
        {
            sourcePackage = await LoadAndValidateExactPackageAsync(source, cancellationToken);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception exception)
        {
            throw new InstallationException(
                "aigw_install_source_invalid",
                "The installation source does not match its package manifest.",
                exception);
        }

        if (File.Exists(target))
        {
            throw VersionConflict();
        }

        if (Directory.Exists(target))
        {
            PackageDirectory existing;
            try
            {
                existing = await LoadAndValidateExactPackageAsync(target, cancellationToken);
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (Exception exception)
            {
                throw new InstallationException(
                    "aigw_install_existing_invalid",
                    "The existing installation is invalid and was not modified.",
                    exception);
            }

            if (!sourcePackage.CanonicalManifest.AsSpan().SequenceEqual(existing.CanonicalManifest))
            {
                throw VersionConflict();
            }

            return new PackageInstallationResult(false, true, target);
        }

        var parent = Path.GetDirectoryName(target)
            ?? throw new InstallationException("aigw_install_path_invalid", "Install root has no parent directory.");
        Directory.CreateDirectory(parent);
        var staging = $"{target}.installing-{Guid.NewGuid():N}";
        var stagingCreated = false;
        try
        {
            Directory.CreateDirectory(staging);
            stagingCreated = true;
            foreach (var file in sourcePackage.Manifest.Files.OrderBy(file => file.Path, StringComparer.Ordinal))
            {
                cancellationToken.ThrowIfCancellationRequested();
                var sourcePath = ResolveManifestPath(source, file.Path);
                var destinationPath = ResolveManifestPath(staging, file.Path);
                Directory.CreateDirectory(Path.GetDirectoryName(destinationPath)!);
                await copyFileAsync(sourcePath, destinationPath, cancellationToken);
            }

            await File.WriteAllBytesAsync(
                Path.Combine(staging, PackageManifest.FileName),
                sourcePackage.CanonicalManifest,
                cancellationToken);
            if (sourcePackage.CanonicalSignature is not null)
            {
                await File.WriteAllBytesAsync(
                    Path.Combine(staging, PackageSignature.FileName),
                    sourcePackage.CanonicalSignature,
                    cancellationToken);
            }
            await LoadAndValidateExactPackageAsync(staging, cancellationToken);
            Directory.Move(staging, target);
            stagingCreated = false;
            return new PackageInstallationResult(true, false, target);
        }
        catch (OperationCanceledException cancellationFailure)
        {
            CleanupStagingOrThrow(staging, stagingCreated, cancellationFailure);
            throw;
        }
        catch (Exception installFailure)
        {
            CleanupStagingOrThrow(staging, stagingCreated, installFailure);
            throw new InstallationException(
                "aigw_install_copy_failed",
                "The package could not be copied into the installation root.",
                installFailure);
        }
    }

    public async Task<PackageUninstallationResult> UninstallAsync(
        string installRoot,
        CancellationToken cancellationToken = default)
    {
        var target = NormalizeOwnedDirectory(installRoot, "install");
        if (!Directory.Exists(target))
        {
            if (File.Exists(target))
            {
                throw new InstallationException(
                    "aigw_uninstall_target_invalid",
                    "The installation root is not a directory.");
            }

            return new PackageUninstallationResult(false, true, []);
        }

        PackageDirectory package;
        DirectorySnapshot snapshot;
        try
        {
            package = await LoadManifestAsync(target, cancellationToken);
            snapshot = EnumerateDirectory(target);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception exception)
        {
            throw new InstallationException(
                "aigw_uninstall_manifest_invalid",
                "The installed package manifest is missing or invalid.",
                exception);
        }

        var expectedFiles = new HashSet<string>(
            package.Manifest.Files.Select(file => file.Path)
                .Append(PackageManifest.FileName)
                .Concat(package.Signature is null ? [] : [PackageSignature.FileName]),
            StringComparer.OrdinalIgnoreCase);
        var expectedDirectories = BuildExpectedDirectories(package.Manifest.Files);
        var preserved = snapshot.Files
            .Where(path => !expectedFiles.Contains(path))
            .Concat(snapshot.Directories.Where(path => !expectedDirectories.Contains(path)))
            .ToHashSet(StringComparer.OrdinalIgnoreCase);

        foreach (var file in package.Manifest.Files)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var path = ResolveManifestPath(target, file.Path);
            if (!File.Exists(path))
            {
                continue;
            }

            if (!await MatchesAsync(path, file, cancellationToken))
            {
                preserved.Add(file.Path);
                continue;
            }

            File.Delete(path);
        }

        foreach (var directory in expectedDirectories.OrderByDescending(path => path.Length))
        {
            var fullPath = ResolveManifestPath(target, directory);
            if (Directory.Exists(fullPath) && !Directory.EnumerateFileSystemEntries(fullPath).Any())
            {
                Directory.Delete(fullPath);
            }
        }

        if (preserved.Count == 0)
        {
            if (package.Signature is not null)
            {
                File.Delete(Path.Combine(target, PackageSignature.FileName));
            }
            File.Delete(Path.Combine(target, PackageManifest.FileName));
            if (!Directory.EnumerateFileSystemEntries(target).Any())
            {
                Directory.Delete(target);
                return new PackageUninstallationResult(true, false, []);
            }
        }

        return new PackageUninstallationResult(
            false,
            false,
            preserved.OrderBy(path => path, StringComparer.Ordinal).ToArray());
    }

    internal async Task ValidateInstalledPackageAsync(
        string installRoot,
        CancellationToken cancellationToken = default)
    {
        var target = NormalizeOwnedDirectory(installRoot, "install");
        await LoadAndValidateExactPackageAsync(target, cancellationToken);
    }

    public async Task<ValidatedPackage> ValidatePackageAsync(
        string packageRoot,
        CancellationToken cancellationToken = default)
    {
        var root = NormalizeOwnedDirectory(packageRoot, "package");
        var package = await LoadAndValidateExactPackageAsync(root, cancellationToken);
        return new ValidatedPackage(
            package.Manifest,
            package.CanonicalManifest.ToArray(),
            package.Signature,
            package.CanonicalSignature?.ToArray());
    }

    internal static async Task CopyFileAsync(
        string sourcePath,
        string destinationPath,
        CancellationToken cancellationToken)
    {
        await using var source = new FileStream(
            sourcePath,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read,
            128 * 1024,
            FileOptions.Asynchronous | FileOptions.SequentialScan);
        await using var destination = new FileStream(
            destinationPath,
            FileMode.CreateNew,
            FileAccess.Write,
            FileShare.None,
            128 * 1024,
            FileOptions.Asynchronous | FileOptions.SequentialScan);
        await source.CopyToAsync(destination, cancellationToken);
        await destination.FlushAsync(cancellationToken);
    }

    private static async Task<PackageDirectory> LoadAndValidateExactPackageAsync(
        string root,
        CancellationToken cancellationToken)
    {
        var package = await LoadManifestAsync(root, cancellationToken);
        var snapshot = EnumerateDirectory(root);
        var expectedFiles = package.Manifest.Files
            .Select(file => file.Path)
            .Append(PackageManifest.FileName)
            .Concat(package.Signature is null ? [] : [PackageSignature.FileName])
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        var expectedDirectories = BuildExpectedDirectories(package.Manifest.Files);
        if (snapshot.Files.Count != expectedFiles.Count ||
            snapshot.Files.Any(path => !expectedFiles.Contains(path)) ||
            snapshot.Directories.Count != expectedDirectories.Count ||
            snapshot.Directories.Any(path => !expectedDirectories.Contains(path)))
        {
            throw new InstallationException(
                "aigw_package_content_mismatch",
                "Package directory contains missing or unexpected files.");
        }

        foreach (var file in package.Manifest.Files)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (!await MatchesAsync(ResolveManifestPath(root, file.Path), file, cancellationToken))
            {
                throw new InstallationException(
                    "aigw_package_content_mismatch",
                    "Package file does not match its declared size or SHA-256.");
            }
        }

        return package;
    }

    private static async Task<PackageDirectory> LoadManifestAsync(
        string root,
        CancellationToken cancellationToken)
    {
        if (!Directory.Exists(root) || IsReparsePoint(root))
        {
            throw new InstallationException(
                "aigw_package_root_invalid",
                "Package root is missing or is a reparse point.");
        }

        var manifestPath = Path.Combine(root, PackageManifest.FileName);
        if (!File.Exists(manifestPath) || IsReparsePoint(manifestPath))
        {
            throw new InstallationException(
                "aigw_package_manifest_missing",
                "Package manifest is missing or is a reparse point.");
        }

        var manifestInfo = new FileInfo(manifestPath);
        if (manifestInfo.Length > PackageManifestJson.MaximumManifestBytes)
        {
            throw new InstallationException(
                "aigw_package_manifest_too_large",
                "Package manifest exceeds the maximum supported size.");
        }

        var bytes = await File.ReadAllBytesAsync(manifestPath, cancellationToken);
        var manifest = PackageManifestJson.Deserialize(bytes);
        var canonical = PackageManifestJson.Serialize(manifest);
        if (!bytes.AsSpan().SequenceEqual(canonical))
        {
            throw new InstallationException(
                "aigw_package_manifest_not_canonical",
                "Package manifest is not in canonical form.");
        }

        PackageSignature? signature = null;
        byte[]? canonicalSignature = null;
        var signaturePath = Path.Combine(root, PackageSignature.FileName);
        if (File.Exists(signaturePath))
        {
            if (IsReparsePoint(signaturePath) || new FileInfo(signaturePath).Length > PackageSignatureJson.MaximumBytes)
            {
                throw new InstallationException(
                    "aigw_package_signature_invalid",
                    "Package signature metadata is unsafe or too large.");
            }

            var signatureBytes = await File.ReadAllBytesAsync(signaturePath, cancellationToken);
            signature = PackageSignatureJson.Deserialize(signatureBytes);
            canonicalSignature = PackageSignatureJson.Serialize(signature);
            if (!signatureBytes.AsSpan().SequenceEqual(canonicalSignature))
            {
                throw new InstallationException(
                    "aigw_package_signature_not_canonical",
                    "Package signature metadata is not in canonical form.");
            }
        }

        return new PackageDirectory(manifest, canonical, signature, canonicalSignature);
    }

    private static DirectorySnapshot EnumerateDirectory(string root)
    {
        var files = new List<string>();
        var directories = new List<string>();
        var pending = new Stack<string>();
        pending.Push(root);
        while (pending.Count > 0)
        {
            var directory = pending.Pop();
            foreach (var entry in Directory.EnumerateFileSystemEntries(directory))
            {
                var attributes = File.GetAttributes(entry);
                if ((attributes & FileAttributes.ReparsePoint) != 0)
                {
                    throw new InstallationException(
                        "aigw_package_reparse_point",
                        "Package directory contains a reparse point.");
                }

                var relative = Path.GetRelativePath(root, entry).Replace('\\', '/');
                if ((attributes & FileAttributes.Directory) != 0)
                {
                    directories.Add(relative);
                    pending.Push(entry);
                }
                else
                {
                    files.Add(relative);
                }
            }
        }

        return new DirectorySnapshot(files, directories);
    }

    private static HashSet<string> BuildExpectedDirectories(IEnumerable<PackageFile> files)
    {
        var directories = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var file in files)
        {
            var current = Path.GetDirectoryName(file.Path.Replace('/', Path.DirectorySeparatorChar));
            while (!string.IsNullOrEmpty(current))
            {
                directories.Add(current.Replace('\\', '/'));
                current = Path.GetDirectoryName(current);
            }
        }

        return directories;
    }

    private static async Task<bool> MatchesAsync(
        string path,
        PackageFile expected,
        CancellationToken cancellationToken)
    {
        if (!File.Exists(path) || IsReparsePoint(path) || new FileInfo(path).Length != expected.Size)
        {
            return false;
        }

        await using var stream = new FileStream(
            path,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read,
            128 * 1024,
            FileOptions.Asynchronous | FileOptions.SequentialScan);
        var hash = Convert.ToHexStringLower(await SHA256.HashDataAsync(stream, cancellationToken));
        return string.Equals(hash, expected.Sha256, StringComparison.Ordinal);
    }

    private static string NormalizeOwnedDirectory(string path, string label)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            throw new InstallationException(
                "aigw_install_path_invalid",
                $"The {label} root must not be empty.");
        }

        var resolvedPath = Path.GetFullPath(path);
        var volumeRoot = Path.GetPathRoot(resolvedPath)?.TrimEnd(
            Path.DirectorySeparatorChar,
            Path.AltDirectorySeparatorChar);
        var fullPath = resolvedPath.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        if (string.IsNullOrEmpty(fullPath) ||
            string.Equals(fullPath, volumeRoot, StringComparison.OrdinalIgnoreCase))
        {
            throw new InstallationException(
                "aigw_install_path_invalid",
                $"The {label} root must not be a volume root.");
        }

        return fullPath;
    }

    private static void RejectOverlappingRoots(string source, string target)
    {
        var sourcePrefix = source + Path.DirectorySeparatorChar;
        var targetPrefix = target + Path.DirectorySeparatorChar;
        if (string.Equals(source, target, StringComparison.OrdinalIgnoreCase) ||
            source.StartsWith(targetPrefix, StringComparison.OrdinalIgnoreCase) ||
            target.StartsWith(sourcePrefix, StringComparison.OrdinalIgnoreCase))
        {
            throw new InstallationException(
                "aigw_install_path_overlap",
                "Source and installation roots must not overlap.");
        }
    }

    private static string ResolveManifestPath(string root, string relativePath)
    {
        var combined = Path.GetFullPath(Path.Combine(
            root,
            relativePath.Replace('/', Path.DirectorySeparatorChar)));
        var prefix = root + Path.DirectorySeparatorChar;
        if (!combined.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
        {
            throw new InstallationException(
                "aigw_package_manifest_unsafe_path",
                "Package path escapes its root.");
        }

        return combined;
    }

    private static bool IsReparsePoint(string path) =>
        (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0;

    private static InstallationException VersionConflict() => new(
        "aigw_install_version_conflict",
        "A different package is already installed at the target path.");

    private static void CleanupStagingOrThrow(
        string staging,
        bool stagingCreated,
        Exception originalFailure)
    {
        if (!stagingCreated || !Directory.Exists(staging))
        {
            return;
        }

        try
        {
            Directory.Delete(staging, recursive: true);
        }
        catch (Exception cleanupFailure)
        {
            throw new InstallationException(
                "aigw_install_cleanup_failed",
                $"Installation failed and staging cleanup was incomplete: {staging}",
                new AggregateException(originalFailure, cleanupFailure));
        }
    }

    private sealed record PackageDirectory(
        PackageManifest Manifest,
        byte[] CanonicalManifest,
        PackageSignature? Signature,
        byte[]? CanonicalSignature);

    private sealed record DirectorySnapshot(
        IReadOnlyList<string> Files,
        IReadOnlyList<string> Directories);
}
