using LocalAIGateway.Core.Backup;
using LocalAIGateway.Core.Configuration;
using LocalAIGateway.Core.Credentials;
using LocalAIGateway.Core.Installation;
using LocalAIGateway.Core.Uninstall;
using LocalAIGateway.Launcher;
using LocalAIGateway.Launcher.Uninstall;
using LocalAIGateway.Windows.Uninstall;

namespace LocalAIGateway.Cli.Tests;

public sealed class DirectUninstallServiceTests : IDisposable
{
    private readonly string root = Path.Combine(
        Path.GetTempPath(),
        $"LocalAIGateway-DirectUninstall-{Guid.NewGuid():N}");

    [Fact]
    public async Task Preflight_blocks_unowned_integration_before_platform_or_backup_deletion()
    {
        var target = Target();
        var backup = await CreateBackupAsync();
        var platform = new FakePlatform();
        var lifecycle = new FakeLifecycle { StatusKind = ClientIntegrationStatusKind.NotIntegrated };
        var service = CreateService(target, root, platform, lifecycle);

        var failure = await Assert.ThrowsAsync<UninstallException>(() =>
            service.UninstallAsync(new(
                Selection(integrations: UninstallChoice.Remove, backups: UninstallChoice.Remove),
                [new("claude-vscode", Path.Combine(root, "settings.json"))],
                [backup],
                Confirmed: true)));

        Assert.Equal("aigw_uninstall_integration_not_owned", failure.ErrorCode);
        Assert.Equal(0, platform.Calls);
        Assert.True(File.Exists(backup));
    }

    [Fact]
    public async Task Owned_integration_platform_state_and_explicit_backup_are_all_processed()
    {
        var target = Target();
        var backup = await CreateBackupAsync();
        var integrationTarget = Path.Combine(root, "settings.json");
        var platform = new FakePlatform();
        var lifecycle = new FakeLifecycle();
        var service = CreateService(target, root, platform, lifecycle);

        var result = await service.UninstallAsync(new(
            Selection(
                program: UninstallChoice.Keep,
                integrations: UninstallChoice.Remove,
                backups: UninstallChoice.Remove),
            [new("claude-vscode", integrationTarget)],
            [backup],
            Confirmed: true));

        Assert.Equal(1, platform.Calls);
        Assert.Equal(1, lifecycle.StatusCalls);
        Assert.Equal(1, lifecycle.UnintegrateCalls);
        Assert.True(result.Integrations.Changed);
        Assert.True(result.Backups.Changed);
        Assert.False(result.CompletionPending);
        Assert.False(File.Exists(backup));
    }

    [Fact]
    public async Task Installed_entrypoint_refuses_program_deletion_before_any_preflight()
    {
        var target = Target();
        var platform = new FakePlatform();
        var lifecycle = new FakeLifecycle();
        var service = CreateService(target, Path.Combine(target.InstallRoot, "tools"), platform, lifecycle);

        var failure = await Assert.ThrowsAsync<UninstallException>(() =>
            service.UninstallAsync(new(
                Selection(program: UninstallChoice.Remove),
                [],
                [],
                Confirmed: true)));

        Assert.Equal("aigw_uninstall_running_from_install_root", failure.ErrorCode);
        Assert.Equal(0, lifecycle.StatusCalls);
        Assert.Equal(0, platform.Calls);
    }

    [Fact]
    public async Task Duplicate_integration_paths_fail_before_mutation()
    {
        var target = Target();
        var platform = new FakePlatform();
        var lifecycle = new FakeLifecycle();
        var path = Path.Combine(root, "settings.json");
        var service = CreateService(target, root, platform, lifecycle);

        var failure = await Assert.ThrowsAsync<UninstallException>(() =>
            service.UninstallAsync(new(
                Selection(integrations: UninstallChoice.Remove),
                [new("claude-vscode", path), new("claude-vscode", path.ToUpperInvariant())],
                [],
                Confirmed: true)));

        Assert.Equal("aigw_uninstall_integration_target_duplicate", failure.ErrorCode);
        Assert.Equal(0, lifecycle.UnintegrateCalls);
        Assert.Equal(0, platform.Calls);
    }

    [Fact]
    public async Task Relative_integration_path_returns_stable_error_before_mutation()
    {
        var target = Target();
        var platform = new FakePlatform();
        var lifecycle = new FakeLifecycle();
        var service = CreateService(target, root, platform, lifecycle);

        var failure = await Assert.ThrowsAsync<UninstallException>(() =>
            service.UninstallAsync(new(
                Selection(integrations: UninstallChoice.Remove),
                [new("codex-cli", "relative\\aigw.config.toml")],
                [],
                Confirmed: true)));

        Assert.Equal("aigw_uninstall_integration_target_invalid", failure.ErrorCode);
        Assert.Equal(0, lifecycle.StatusCalls);
        Assert.Equal(0, platform.Calls);
    }

    private CompleteUninstallExecutor CreateService(
        CurrentUserInstallationTarget target,
        string commandRoot,
        ICurrentUserUninstallCoordinator platform,
        IClientIntegrationLifecycleManager lifecycle) => new(
            target,
            commandRoot,
            platform,
            lifecycle,
            new BackupFileCleaner());

    private CurrentUserInstallationTarget Target()
    {
        Directory.CreateDirectory(root);
        return CurrentUserInstallationPlan.CreateTarget(Path.Combine(root, "local-app-data"));
    }

    private async Task<string> CreateBackupAsync()
    {
        Directory.CreateDirectory(root);
        var state = Path.Combine(root, "backup-state");
        var store = new ConfigurationStore(
            new ConfigurationPaths(state),
            NoOpConfigurationFileSecurity.Instance);
        var path = Path.Combine(root, "backup-" + Guid.NewGuid().ToString("N") + ".json");
        await new BackupCoordinator(
            store,
            new EmptyCredentials(),
            new UnusedCryptography(),
            NoOpConfigurationFileSecurity.Instance).CreateAsync(new(path, false, null));
        return path;
    }

    private static UninstallSelection Selection(
        UninstallChoice program = UninstallChoice.Keep,
        UninstallChoice integrations = UninstallChoice.Keep,
        UninstallChoice backups = UninstallChoice.Keep) => new(
            program,
            UninstallChoice.Keep,
            integrations,
            UninstallChoice.Keep,
            UninstallChoice.Keep,
            UninstallChoice.Keep,
            UninstallChoice.Keep,
            UninstallChoice.Keep,
            backups);

    public void Dispose()
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }

    private sealed class FakePlatform : ICurrentUserUninstallCoordinator
    {
        public int Calls { get; private set; }
        public Task<CurrentUserPlatformUninstallResult> UninstallAsync(
            CurrentUserInstallationTarget target,
            UninstallSelection selection,
            CancellationToken cancellationToken = default)
        {
            Calls++;
            var skipped = new UninstallCategoryResult(false, false, false, []);
            return Task.FromResult(new CurrentUserPlatformUninstallResult(
                skipped, skipped, skipped, skipped, skipped, skipped, skipped));
        }
    }

    private sealed class FakeLifecycle : IClientIntegrationLifecycleManager
    {
        public ClientIntegrationStatusKind StatusKind { get; init; } = ClientIntegrationStatusKind.Owned;
        public int StatusCalls { get; private set; }
        public int UnintegrateCalls { get; private set; }

        public Task<ClientIntegrationStatusResult> GetStatusAsync(
            ClientIntegrationStatusRequest request,
            CancellationToken cancellationToken = default)
        {
            StatusCalls++;
            return Task.FromResult(new ClientIntegrationStatusResult(
                request.Client,
                request.TargetPath,
                StatusKind,
                StatusKind == ClientIntegrationStatusKind.Owned
                    ? ClientIntegrationRemovalAction.Delete
                    : ClientIntegrationRemovalAction.None,
                StatusKind == ClientIntegrationStatusKind.Owned ? new string('a', 64) : null,
                null,
                null,
                null));
        }

        public Task<ClientIntegrationUnintegrateResult> UnintegrateAsync(
            ClientIntegrationUnintegrateRequest request,
            CancellationToken cancellationToken = default)
        {
            UnintegrateCalls++;
            return Task.FromResult(new ClientIntegrationUnintegrateResult(
                request.Client,
                request.TargetPath,
                ClientIntegrationRemovalAction.Delete,
                Applied: true,
                request.TargetPath + ".backup",
                request.ExpectedBeforeSha256,
                null));
        }
    }

    private sealed class EmptyCredentials : ICredentialStore
    {
        public ValueTask SetSecretAsync(string target, string secret, CancellationToken cancellationToken = default) => ValueTask.CompletedTask;
        public ValueTask<string?> GetSecretAsync(string target, CancellationToken cancellationToken = default) => ValueTask.FromResult<string?>(null);
        public ValueTask DeleteSecretAsync(string target, CancellationToken cancellationToken = default) => ValueTask.CompletedTask;
    }

    private sealed class UnusedCryptography : IBackupCryptography
    {
        public Task<byte[]> EncryptAsync(ReadOnlyMemory<byte> plaintext, string passphrase, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<byte[]> DecryptAsync(ReadOnlyMemory<byte> envelope, string passphrase, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    }
}
