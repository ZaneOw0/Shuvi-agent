using System.Security.Cryptography;
using LocalAIGateway.Core.Installation;
using LocalAIGateway.Core.Update;
using LocalAIGateway.Windows.Installation;

namespace LocalAIGateway.Windows.Tests;

public sealed class WindowsPackageInstallerTests : IDisposable
{
    private readonly string testRoot = Path.Combine(
        Path.GetTempPath(),
        $"LocalAIGateway-InstallerTests-{Guid.NewGuid():N}");

    [Fact]
    public async Task Install_and_uninstall_preserve_optional_canonical_signature_metadata()
    {
        var source = CreatePackage("signed-metadata");
        var manifestBytes = File.ReadAllBytes(Path.Combine(source, PackageManifest.FileName));
        var signature = new PackageSignature(
            1,
            "none",
            null,
            Convert.ToHexStringLower(SHA256.HashData(manifestBytes)),
            null);
        File.WriteAllBytes(
            Path.Combine(source, PackageSignature.FileName),
            PackageSignatureJson.Serialize(signature));
        var installRoot = Path.Combine(testRoot, "signed-installed");
        var installer = new WindowsPackageInstaller();

        var inspected = await installer.ValidatePackageAsync(source);
        await installer.InstallAsync(source, installRoot);

        Assert.Equal(signature, inspected.Signature);
        Assert.True(File.Exists(Path.Combine(installRoot, PackageSignature.FileName)));
        Assert.True((await installer.UninstallAsync(installRoot)).Removed);
        Assert.False(Directory.Exists(installRoot));
    }

    [Fact]
    public async Task Install_is_atomic_and_repeating_the_same_package_is_idempotent()
    {
        var source = CreatePackage("first");
        var installRoot = Path.Combine(testRoot, "installed path with spaces");
        var installer = new WindowsPackageInstaller();

        var installed = await installer.InstallAsync(source, installRoot);
        var repeated = await installer.InstallAsync(source, installRoot);

        Assert.True(installed.Installed);
        Assert.False(installed.AlreadyInstalled);
        Assert.False(repeated.Installed);
        Assert.True(repeated.AlreadyInstalled);
        Assert.Equal("first", await File.ReadAllTextAsync(Path.Combine(installRoot, "aigw.exe")));
        Assert.Empty(FindStagingDirectories(installRoot));
    }

    [Fact]
    public async Task Corrupt_or_extra_source_content_is_rejected_before_target_mutation()
    {
        var corruptSource = CreatePackage("first");
        await File.WriteAllTextAsync(Path.Combine(corruptSource, "aigw.exe"), "corrupt");
        var extraSource = CreatePackage("second");
        await File.WriteAllTextAsync(Path.Combine(extraSource, "extra.txt"), "unexpected");
        var corruptTarget = Path.Combine(testRoot, "corrupt-target");
        var extraTarget = Path.Combine(testRoot, "extra-target");
        var installer = new WindowsPackageInstaller();

        var corrupt = await Assert.ThrowsAsync<InstallationException>(
            () => installer.InstallAsync(corruptSource, corruptTarget));
        var extra = await Assert.ThrowsAsync<InstallationException>(
            () => installer.InstallAsync(extraSource, extraTarget));

        Assert.Equal("aigw_install_source_invalid", corrupt.ErrorCode);
        Assert.Equal("aigw_install_source_invalid", extra.ErrorCode);
        Assert.False(Directory.Exists(corruptTarget));
        Assert.False(Directory.Exists(extraTarget));
        Assert.Empty(FindStagingDirectories(corruptTarget));
        Assert.Empty(FindStagingDirectories(extraTarget));
    }

    [Fact]
    public async Task Unexpected_empty_source_directory_is_rejected_before_target_mutation()
    {
        var source = CreatePackage("first");
        Directory.CreateDirectory(Path.Combine(source, "unexpected-empty"));
        var installRoot = Path.Combine(testRoot, "empty-directory-target");
        var installer = new WindowsPackageInstaller();

        var failure = await Assert.ThrowsAsync<InstallationException>(
            () => installer.InstallAsync(source, installRoot));

        Assert.Equal("aigw_install_source_invalid", failure.ErrorCode);
        Assert.False(Directory.Exists(installRoot));
        Assert.Empty(FindStagingDirectories(installRoot));
    }

    [Fact]
    public async Task Different_package_conflicts_without_changing_the_existing_installation()
    {
        var firstSource = CreatePackage("first", version: "0.1.0-dev");
        var secondSource = CreatePackage("second", version: "0.2.0-dev");
        var installRoot = Path.Combine(testRoot, "installed");
        var installer = new WindowsPackageInstaller();
        await installer.InstallAsync(firstSource, installRoot);

        var failure = await Assert.ThrowsAsync<InstallationException>(
            () => installer.InstallAsync(secondSource, installRoot));

        Assert.Equal("aigw_install_version_conflict", failure.ErrorCode);
        Assert.Equal("first", await File.ReadAllTextAsync(Path.Combine(installRoot, "aigw.exe")));
        Assert.Empty(FindStagingDirectories(installRoot));
    }

    [Fact]
    public async Task Volume_roots_and_overlapping_source_target_paths_are_rejected()
    {
        var source = CreatePackage("first");
        var volumeRoot = Path.GetPathRoot(testRoot)!;
        var installer = new WindowsPackageInstaller();

        var rootFailure = await Assert.ThrowsAsync<InstallationException>(
            () => installer.InstallAsync(source, volumeRoot));
        var nestedFailure = await Assert.ThrowsAsync<InstallationException>(
            () => installer.InstallAsync(source, Path.Combine(source, "nested-install")));

        Assert.Equal("aigw_install_path_invalid", rootFailure.ErrorCode);
        Assert.Equal("aigw_install_path_overlap", nestedFailure.ErrorCode);
        Assert.False(Directory.Exists(Path.Combine(source, "nested-install")));
    }

    [Fact]
    public async Task Copy_failure_removes_only_the_attempt_staging_directory()
    {
        var source = CreatePackage("first");
        var installRoot = Path.Combine(testRoot, "installed");
        var copyCount = 0;
        var installer = new WindowsPackageInstaller(async (sourcePath, destinationPath, cancellationToken) =>
        {
            copyCount++;
            if (copyCount == 2)
            {
                throw new IOException("Injected copy failure.");
            }

            await WindowsPackageInstaller.CopyFileAsync(
                sourcePath,
                destinationPath,
                cancellationToken);
        });

        var failure = await Assert.ThrowsAsync<InstallationException>(
            () => installer.InstallAsync(source, installRoot));

        Assert.Equal("aigw_install_copy_failed", failure.ErrorCode);
        Assert.False(Directory.Exists(installRoot));
        Assert.True(Directory.Exists(source));
        Assert.Empty(FindStagingDirectories(installRoot));
    }

    [Fact]
    public async Task Uninstall_removes_only_verified_manifest_owned_files()
    {
        var source = CreatePackage("first");
        var installRoot = Path.Combine(testRoot, "installed");
        var installer = new WindowsPackageInstaller();
        await installer.InstallAsync(source, installRoot);
        await File.WriteAllTextAsync(Path.Combine(installRoot, "user-note.txt"), "preserve");

        var partial = await installer.UninstallAsync(installRoot);

        Assert.False(partial.Removed);
        Assert.Contains("user-note.txt", partial.PreservedPaths);
        Assert.False(File.Exists(Path.Combine(installRoot, "aigw.exe")));
        Assert.True(File.Exists(Path.Combine(installRoot, PackageManifest.FileName)));
        Assert.True(File.Exists(Path.Combine(installRoot, "user-note.txt")));
    }

    [Fact]
    public async Task Uninstall_preserves_a_modified_manifest_owned_file()
    {
        var source = CreatePackage("first");
        var installRoot = Path.Combine(testRoot, "installed");
        var installer = new WindowsPackageInstaller();
        await installer.InstallAsync(source, installRoot);
        await File.WriteAllTextAsync(Path.Combine(installRoot, "aigw.exe"), "user-modified");

        var partial = await installer.UninstallAsync(installRoot);

        Assert.False(partial.Removed);
        Assert.Contains("aigw.exe", partial.PreservedPaths);
        Assert.Equal("user-modified", await File.ReadAllTextAsync(Path.Combine(installRoot, "aigw.exe")));
        Assert.True(File.Exists(Path.Combine(installRoot, PackageManifest.FileName)));
    }

    [Fact]
    public async Task Uninstall_removes_a_clean_installation_and_is_idempotent()
    {
        var source = CreatePackage("first");
        var installRoot = Path.Combine(testRoot, "installed");
        var installer = new WindowsPackageInstaller();
        await installer.InstallAsync(source, installRoot);

        var removed = await installer.UninstallAsync(installRoot);
        var repeated = await installer.UninstallAsync(installRoot);

        Assert.True(removed.Removed);
        Assert.False(removed.AlreadyAbsent);
        Assert.False(repeated.Removed);
        Assert.True(repeated.AlreadyAbsent);
        Assert.False(Directory.Exists(installRoot));
    }

    public void Dispose()
    {
        if (Directory.Exists(testRoot))
        {
            Directory.Delete(testRoot, recursive: true);
        }
    }

    private string CreatePackage(string content, string version = "0.1.0-dev")
    {
        var source = Path.Combine(testRoot, $"source-{Guid.NewGuid():N}");
        Directory.CreateDirectory(Path.Combine(source, "runtime", "python"));
        File.WriteAllText(Path.Combine(source, "aigw.exe"), content);
        File.WriteAllText(Path.Combine(source, "runtime", "python", "python.exe"), "python");
        var files = new[]
        {
            CreateFile(source, "aigw.exe"),
            CreateFile(source, "runtime/python/python.exe"),
        };
        var manifest = new PackageManifest(
            PackageManifest.CurrentSchemaVersion,
            PackageManifest.ProductPackageId,
            version,
            PackageManifest.WindowsX64RuntimeIdentifier,
            true,
            files);
        File.WriteAllBytes(
            Path.Combine(source, PackageManifest.FileName),
            PackageManifestJson.Serialize(manifest));
        return source;
    }

    private static PackageFile CreateFile(string root, string relativePath)
    {
        var path = Path.Combine(root, relativePath.Replace('/', Path.DirectorySeparatorChar));
        var bytes = File.ReadAllBytes(path);
        return new PackageFile(
            relativePath,
            bytes.LongLength,
            Convert.ToHexStringLower(SHA256.HashData(bytes)));
    }

    private static string[] FindStagingDirectories(string installRoot)
    {
        var parent = Path.GetDirectoryName(installRoot)!;
        var name = Path.GetFileName(installRoot);
        return Directory.Exists(parent)
            ? Directory.GetDirectories(parent, $"{name}.installing-*")
            : [];
    }
}
