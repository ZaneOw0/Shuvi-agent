using System.Text;

namespace LocalAIGateway.Launcher.Tests;

public sealed class ClientIntegrationApplierTests : IDisposable
{
    private readonly string testRoot = Path.Combine(
        Path.GetTempPath(),
        $"LocalAIGateway-IntegrationApply-{Guid.NewGuid():N}");
    private readonly ClientIntegrationPreviewer previewer = new();

    [Fact]
    public async Task Apply_creates_a_new_codex_profile_without_a_backup()
    {
        Directory.CreateDirectory(testRoot);
        var target = Path.Combine(testRoot, "aigw.config.toml");
        var preview = PreviewCodex(target, existing: null);

        var result = await Applier().ApplyAsync(new(
            ClientIntegrationKind.CodexCli,
            target,
            "0.134.0",
            ExpectedBeforeSha256: null,
            ExpectAbsent: true,
            preview.AfterSha256,
            Confirmed: true));

        Assert.True(result.Applied);
        Assert.Equal(ClientIntegrationAction.Create, result.Action);
        Assert.Null(result.BackupPath);
        Assert.Equal(preview.ProposedContent, File.ReadAllText(target));
        AssertNoTemporaryFiles();
    }

    [Fact]
    public async Task Apply_atomically_updates_claude_and_preserves_bom_and_exact_backup()
    {
        Directory.CreateDirectory(testRoot);
        var wrapper = CreateFile("aigw-launcher.exe", "fixture");
        var target = Path.Combine(testRoot, "settings.json");
        const string existing = "{\r\n  // keep\r\n  \"unmanagedSecret\": \"never-emit\"\r\n}\r\n";
        var originalBytes = WithBom(existing);
        File.WriteAllBytes(target, originalBytes);
        var preview = PreviewClaude(target, existing, wrapper);

        var result = await Applier().ApplyAsync(new(
            ClientIntegrationKind.ClaudeVsCode,
            target,
            "2.1.257",
            preview.BeforeSha256,
            ExpectAbsent: false,
            preview.AfterSha256,
            Confirmed: true,
            HostVersion: "1.94.0",
            WrapperExecutablePath: wrapper));

        Assert.True(result.Applied);
        Assert.Equal(ClientIntegrationAction.Update, result.Action);
        Assert.NotNull(result.BackupPath);
        Assert.Equal(originalBytes, File.ReadAllBytes(result.BackupPath));
        Assert.True(File.ReadAllBytes(target).AsSpan().StartsWith(new byte[] { 0xEF, 0xBB, 0xBF }));
        Assert.Contains("never-emit", File.ReadAllText(target), StringComparison.Ordinal);
        AssertNoTemporaryFiles();
    }

    [Fact]
    public async Task Apply_rejects_a_stale_target_without_backup_or_write()
    {
        Directory.CreateDirectory(testRoot);
        var target = Path.Combine(testRoot, "aigw.config.toml");
        var initial = PreviewCodex(target, existing: null);
        File.WriteAllText(target, initial.ProposedContent);
        var confirmed = PreviewCodex(target, initial.ProposedContent);
        var changed = initial.ProposedContent + "# changed after preview\n";
        File.WriteAllText(target, changed);

        var failure = await Assert.ThrowsAsync<ClientIntegrationException>(() =>
            Applier().ApplyAsync(new(
                ClientIntegrationKind.CodexCli,
                target,
                "0.134.0",
                confirmed.BeforeSha256,
                ExpectAbsent: false,
                confirmed.AfterSha256,
                Confirmed: true)));

        Assert.Equal("aigw_integration_stale_preview", failure.ErrorCode);
        Assert.Equal(changed, File.ReadAllText(target));
        Assert.Empty(Backups());
        AssertNoTemporaryFiles();
    }

    [Fact]
    public async Task Apply_rejects_a_changed_expected_output_hash_before_creating_files()
    {
        Directory.CreateDirectory(testRoot);
        var target = Path.Combine(testRoot, "aigw.config.toml");
        var preview = PreviewCodex(target, existing: null);

        var failure = await Assert.ThrowsAsync<ClientIntegrationException>(() =>
            Applier().ApplyAsync(new(
                ClientIntegrationKind.CodexCli,
                target,
                "0.200.0",
                ExpectedBeforeSha256: null,
                ExpectAbsent: true,
                ExpectedAfterSha256: new string('0', 64),
                Confirmed: true)));

        Assert.Equal("aigw_integration_stale_preview", failure.ErrorCode);
        Assert.False(File.Exists(target));
        Assert.Empty(Backups());
        AssertNoTemporaryFiles();
        Assert.NotEqual(new string('0', 64), preview.AfterSha256);
    }

    [Fact]
    public async Task Apply_requires_exact_confirmation_before_reading_the_target()
    {
        var target = Path.Combine(testRoot, "missing-parent", "aigw.config.toml");

        var failure = await Assert.ThrowsAsync<ClientIntegrationException>(() =>
            Applier().ApplyAsync(new(
                ClientIntegrationKind.CodexCli,
                target,
                "0.134.0",
                ExpectedBeforeSha256: null,
                ExpectAbsent: true,
                ExpectedAfterSha256: new string('0', 64),
                Confirmed: false)));

        Assert.Equal("aigw_integration_confirmation_required", failure.ErrorCode);
        Assert.False(Directory.Exists(Path.GetDirectoryName(target)));
    }

    [Fact]
    public async Task Apply_is_a_no_op_when_the_confirmed_content_is_unchanged()
    {
        Directory.CreateDirectory(testRoot);
        var target = Path.Combine(testRoot, "aigw.config.toml");
        var created = PreviewCodex(target, existing: null);
        File.WriteAllText(target, created.ProposedContent);
        var unchanged = PreviewCodex(target, created.ProposedContent);

        var result = await Applier().ApplyAsync(new(
            ClientIntegrationKind.CodexCli,
            target,
            "0.134.0",
            unchanged.BeforeSha256,
            ExpectAbsent: false,
            unchanged.AfterSha256,
            Confirmed: true));

        Assert.False(result.Applied);
        Assert.Equal(ClientIntegrationAction.Unchanged, result.Action);
        Assert.Null(result.BackupPath);
        Assert.Empty(Backups());
        AssertNoTemporaryFiles();
    }

    [Fact]
    public async Task Replace_failure_preserves_the_target_and_cleans_the_temporary_file()
    {
        Directory.CreateDirectory(testRoot);
        var wrapper = CreateFile("aigw-launcher.exe", "fixture");
        var target = CreateFile("settings.json", "{}\n");
        var preview = PreviewClaude(target, "{}\n", wrapper);
        var applier = new ClientIntegrationApplier(
            previewer,
            static (_, _, _) => throw new IOException("simulated replace failure"),
            static (source, destination) => File.Move(source, destination));

        var failure = await Assert.ThrowsAsync<ClientIntegrationFileException>(() =>
            applier.ApplyAsync(new(
                ClientIntegrationKind.ClaudeVsCode,
                target,
                "2.1.257",
                preview.BeforeSha256,
                ExpectAbsent: false,
                preview.AfterSha256,
                Confirmed: true,
                HostVersion: "1.94.0",
                WrapperExecutablePath: wrapper)));

        Assert.Equal("aigw_integration_file_failed", failure.ErrorCode);
        Assert.Equal("{}\n", File.ReadAllText(target));
        Assert.Empty(Backups());
        AssertNoTemporaryFiles();
    }

    [Fact]
    public async Task Create_move_failure_leaves_no_target_or_temporary_file()
    {
        Directory.CreateDirectory(testRoot);
        var target = Path.Combine(testRoot, "aigw.config.toml");
        var preview = PreviewCodex(target, existing: null);
        var applier = new ClientIntegrationApplier(
            previewer,
            static (source, destination, backup) => File.Replace(source, destination, backup),
            static (_, _) => throw new IOException("simulated move failure"));

        var failure = await Assert.ThrowsAsync<ClientIntegrationFileException>(() =>
            applier.ApplyAsync(new(
                ClientIntegrationKind.CodexCli,
                target,
                "0.134.0",
                ExpectedBeforeSha256: null,
                ExpectAbsent: true,
                preview.AfterSha256,
                Confirmed: true)));

        Assert.Equal("aigw_integration_file_failed", failure.ErrorCode);
        Assert.False(File.Exists(target));
        Assert.Empty(Backups());
        AssertNoTemporaryFiles();
    }

    [Fact]
    public async Task Atomic_backup_mismatch_restores_the_intervening_content()
    {
        Directory.CreateDirectory(testRoot);
        var target = Path.Combine(testRoot, "aigw.config.toml");
        var generated = PreviewCodex(target, existing: null).ProposedContent;
        var existing = generated.Replace(
            "model = \"aigw/codex/default\"",
            "model = \"old\"",
            StringComparison.Ordinal);
        File.WriteAllText(target, existing);
        var preview = PreviewCodex(target, existing);
        const string intervening = "# concurrent edit\n";
        var applier = new ClientIntegrationApplier(
            previewer,
            static (source, destination, backup) =>
            {
                File.Replace(source, destination, backup, ignoreMetadataErrors: false);
                File.AppendAllText(backup, intervening);
            },
            static (source, destination) => File.Move(source, destination));

        var failure = await Assert.ThrowsAsync<ClientIntegrationException>(() =>
            applier.ApplyAsync(new(
                ClientIntegrationKind.CodexCli,
                target,
                "0.134.0",
                preview.BeforeSha256,
                ExpectAbsent: false,
                preview.AfterSha256,
                Confirmed: true)));

        Assert.Equal("aigw_integration_stale_preview", failure.ErrorCode);
        Assert.Equal(existing + intervening, File.ReadAllText(target));
        Assert.Empty(Backups());
        Assert.Empty(Directory.GetFiles(testRoot, "*.aigw-rejected-*.tmp"));
        AssertNoTemporaryFiles();
    }

    public void Dispose()
    {
        if (Directory.Exists(testRoot))
        {
            Directory.Delete(testRoot, recursive: true);
        }
    }

    private ClientIntegrationApplier Applier() => new(previewer);

    private ClientIntegrationPreviewResult PreviewCodex(string target, string? existing) =>
        previewer.Preview(new(
            ClientIntegrationKind.CodexCli,
            target,
            existing,
            "0.134.0"));

    private ClientIntegrationPreviewResult PreviewClaude(
        string target,
        string existing,
        string wrapper) => previewer.Preview(new(
            ClientIntegrationKind.ClaudeVsCode,
            target,
            existing,
            "2.1.257",
            "1.94.0",
            wrapper));

    private string CreateFile(string name, string content)
    {
        Directory.CreateDirectory(testRoot);
        var path = Path.Combine(testRoot, name);
        File.WriteAllText(path, content);
        return path;
    }

    private static byte[] WithBom(string content) =>
        [0xEF, 0xBB, 0xBF, .. Encoding.UTF8.GetBytes(content)];

    private string[] Backups() => Directory.Exists(testRoot)
        ? Directory.GetFiles(testRoot, "*.aigw-backup-*.bak", SearchOption.AllDirectories)
        : [];

    private void AssertNoTemporaryFiles() => Assert.Empty(
        Directory.GetFiles(testRoot, "*.aigw-write-*.tmp", SearchOption.AllDirectories));
}
