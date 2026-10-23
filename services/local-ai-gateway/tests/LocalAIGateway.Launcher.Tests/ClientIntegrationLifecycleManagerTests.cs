using System.Text;
using System.Text.Json;

namespace LocalAIGateway.Launcher.Tests;

public sealed class ClientIntegrationLifecycleManagerTests : IDisposable
{
    private readonly string testRoot = Path.Combine(
        Path.GetTempPath(),
        $"LocalAIGateway-IntegrationLifecycle-{Guid.NewGuid():N}");

    [Fact]
    public async Task Status_reports_an_absent_explicit_target_without_creating_it()
    {
        Directory.CreateDirectory(testRoot);
        var target = Path.Combine(testRoot, "aigw.config.toml");

        var status = await Manager().GetStatusAsync(new(
            ClientIntegrationKind.CodexCli,
            target));

        Assert.Equal(ClientIntegrationStatusKind.Absent, status.Status);
        Assert.Equal(ClientIntegrationRemovalAction.None, status.Action);
        Assert.Null(status.BeforeSha256);
        Assert.False(File.Exists(target));
    }

    [Fact]
    public async Task Status_reports_unmanaged_claude_settings_as_not_integrated()
    {
        var target = CreateFile("settings.json", "{ \"keep\": true }\n");

        var status = await Manager().GetStatusAsync(new(
            ClientIntegrationKind.ClaudeVsCode,
            target));

        Assert.Equal(ClientIntegrationStatusKind.NotIntegrated, status.Status);
        Assert.Equal(ClientIntegrationRemovalAction.None, status.Action);
        Assert.NotNull(status.BeforeSha256);
        Assert.Null(status.ManagedDiff);
    }

    [Fact]
    public async Task Status_plans_only_owned_claude_removal_without_emitting_unmanaged_content()
    {
        var wrapper = CreateFile("aigw-launcher.exe", "fixture");
        const string unmanaged = "do-not-emit-this";
        var target = Path.Combine(testRoot, "settings.json");
        var integrated = PreviewClaude(target, $"{{\n  \"secret\": \"{unmanaged}\"\n}}\n", wrapper);
        CreateFile("settings.json", integrated.ProposedContent);

        var status = await Manager().GetStatusAsync(new(
            ClientIntegrationKind.ClaudeVsCode,
            target));

        Assert.Equal(ClientIntegrationStatusKind.Owned, status.Status);
        Assert.Equal(ClientIntegrationRemovalAction.Update, status.Action);
        Assert.DoesNotContain(unmanaged, status.ManagedDiff, StringComparison.Ordinal);
        Assert.Contains(unmanaged, status.ProposedContent, StringComparison.Ordinal);
        using var document = ParseJsonc(status.ProposedContent!);
        Assert.Equal(unmanaged, document.RootElement.GetProperty("secret").GetString());
        Assert.False(document.RootElement.TryGetProperty(
            "claudeCode.claudeProcessWrapper",
            out _));
    }

    [Fact]
    public async Task Status_plans_delete_for_a_fully_owned_codex_profile()
    {
        var target = Path.Combine(testRoot, "aigw.config.toml");
        var integrated = PreviewCodex(target, existing: null);
        CreateFile("aigw.config.toml", integrated.ProposedContent);

        var status = await Manager().GetStatusAsync(new(
            ClientIntegrationKind.CodexCli,
            target));

        Assert.Equal(ClientIntegrationStatusKind.Owned, status.Status);
        Assert.Equal(ClientIntegrationRemovalAction.Delete, status.Action);
        Assert.Null(status.AfterSha256);
        Assert.Null(status.ProposedContent);
        Assert.Contains("+++ /dev/null", status.ManagedDiff, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Status_preserves_external_codex_comments_in_an_update_plan()
    {
        var target = Path.Combine(testRoot, "aigw.config.toml");
        var generated = PreviewCodex(target, existing: null).ProposedContent;
        CreateFile("aigw.config.toml", "# keep this comment\n" + generated);

        var status = await Manager().GetStatusAsync(new(
            ClientIntegrationKind.CodexCli,
            target));

        Assert.Equal(ClientIntegrationRemovalAction.Update, status.Action);
        Assert.Equal("# keep this comment\n", status.ProposedContent);
    }

    [Fact]
    public async Task Status_rejects_malformed_ownership_markers()
    {
        var target = CreateFile(
            "aigw.config.toml",
            "# BEGIN Local AI Gateway managed: codex-cli v1\nmodel = \"changed\"\n");

        var failure = await Assert.ThrowsAsync<ClientIntegrationException>(() =>
            Manager().GetStatusAsync(new(ClientIntegrationKind.CodexCli, target)));

        Assert.Equal("aigw_integration_ownership_conflict", failure.ErrorCode);
    }

    [Fact]
    public async Task Unintegrate_updates_claude_with_exact_backup_and_preserved_bom()
    {
        var wrapper = CreateFile("aigw-launcher.exe", "fixture");
        var target = Path.Combine(testRoot, "settings.json");
        var integrated = PreviewClaude(target, "{\r\n  \"keep\": true\r\n}\r\n", wrapper).ProposedContent;
        Directory.CreateDirectory(testRoot);
        File.WriteAllText(target, integrated, new UTF8Encoding(encoderShouldEmitUTF8Identifier: true));
        var status = await Manager().GetStatusAsync(new(ClientIntegrationKind.ClaudeVsCode, target));

        var removed = await Manager().UnintegrateAsync(new(
            ClientIntegrationKind.ClaudeVsCode,
            target,
            status.BeforeSha256!,
            status.AfterSha256,
            ExpectDelete: false,
            Confirmed: true));

        Assert.True(removed.Applied);
        Assert.NotNull(removed.BackupPath);
        Assert.Equal(File.ReadAllBytes(removed.BackupPath!),
            Encoding.UTF8.GetPreamble().Concat(Encoding.UTF8.GetBytes(integrated)).ToArray());
        Assert.True(File.ReadAllBytes(target).AsSpan().StartsWith(Encoding.UTF8.GetPreamble()));
        using var document = ParseJsonc(File.ReadAllText(target));
        Assert.True(document.RootElement.GetProperty("keep").GetBoolean());
        Assert.False(document.RootElement.TryGetProperty("claudeCode.claudeProcessWrapper", out _));
        AssertNoTemporaryFiles();
    }

    [Fact]
    public async Task Unintegrate_moves_a_fully_owned_codex_profile_to_recovery_backup()
    {
        var target = Path.Combine(testRoot, "aigw.config.toml");
        var integrated = PreviewCodex(target, existing: null).ProposedContent;
        CreateFile("aigw.config.toml", integrated);
        var status = await Manager().GetStatusAsync(new(ClientIntegrationKind.CodexCli, target));

        var removed = await Manager().UnintegrateAsync(new(
            ClientIntegrationKind.CodexCli,
            target,
            status.BeforeSha256!,
            ExpectedAfterSha256: null,
            ExpectDelete: true,
            Confirmed: true));

        Assert.True(removed.Applied);
        Assert.Equal(ClientIntegrationRemovalAction.Delete, removed.Action);
        Assert.False(File.Exists(target));
        Assert.Equal(integrated, File.ReadAllText(removed.BackupPath!));
        AssertNoTemporaryFiles();
    }

    [Fact]
    public async Task Unintegrate_requires_exact_confirmation_before_target_access()
    {
        var target = Path.Combine(testRoot, "missing", "aigw.config.toml");

        var failure = await Assert.ThrowsAsync<ClientIntegrationException>(() =>
            Manager().UnintegrateAsync(new(
                ClientIntegrationKind.CodexCli,
                target,
                new string('0', 64),
                ExpectedAfterSha256: null,
                ExpectDelete: true,
                Confirmed: false)));

        Assert.Equal("aigw_integration_confirmation_required", failure.ErrorCode);
        Assert.False(Directory.Exists(Path.GetDirectoryName(target)));
    }

    [Fact]
    public async Task Unintegrate_rejects_stale_status_without_backup_or_write()
    {
        var target = Path.Combine(testRoot, "aigw.config.toml");
        var integrated = PreviewCodex(target, existing: null).ProposedContent;
        CreateFile("aigw.config.toml", integrated);
        var status = await Manager().GetStatusAsync(new(ClientIntegrationKind.CodexCli, target));
        File.AppendAllText(target, "# intervening change\n");

        var failure = await Assert.ThrowsAsync<ClientIntegrationException>(() =>
            Manager().UnintegrateAsync(new(
                ClientIntegrationKind.CodexCli,
                target,
                status.BeforeSha256!,
                ExpectedAfterSha256: null,
                ExpectDelete: true,
                Confirmed: true)));

        Assert.Equal("aigw_integration_stale_preview", failure.ErrorCode);
        Assert.True(File.Exists(target));
        Assert.Empty(Directory.GetFiles(testRoot, "*.aigw-backup-*.bak"));
    }

    [Fact]
    public async Task Unintegrate_rejects_an_unowned_target_without_write()
    {
        var target = CreateFile("aigw.config.toml", "user_setting = true\n");
        var status = await Manager().GetStatusAsync(new(ClientIntegrationKind.CodexCli, target));

        var failure = await Assert.ThrowsAsync<ClientIntegrationException>(() =>
            Manager().UnintegrateAsync(new(
                ClientIntegrationKind.CodexCli,
                target,
                status.BeforeSha256!,
                new string('0', 64),
                ExpectDelete: false,
                Confirmed: true)));

        Assert.Equal("aigw_integration_not_owned", failure.ErrorCode);
        Assert.Equal("user_setting = true\n", File.ReadAllText(target));
        Assert.Empty(Directory.GetFiles(testRoot, "*.aigw-backup-*.bak"));
    }

    [Fact]
    public async Task Update_replace_failure_preserves_target_and_cleans_temporary_file()
    {
        var wrapper = CreateFile("aigw-launcher.exe", "fixture");
        var target = Path.Combine(testRoot, "settings.json");
        var integrated = PreviewClaude(target, "{ \"keep\": true }\n", wrapper).ProposedContent;
        CreateFile("settings.json", integrated);
        var status = await Manager().GetStatusAsync(new(ClientIntegrationKind.ClaudeVsCode, target));
        var manager = new ClientIntegrationLifecycleManager(
            static (_, _, _) => throw new IOException("injected replace failure"),
            static (source, destination) => File.Move(source, destination));

        var failure = await Assert.ThrowsAsync<ClientIntegrationFileException>(() =>
            manager.UnintegrateAsync(new(
                ClientIntegrationKind.ClaudeVsCode,
                target,
                status.BeforeSha256!,
                status.AfterSha256,
                ExpectDelete: false,
                Confirmed: true)));

        Assert.Equal("aigw_integration_file_failed", failure.ErrorCode);
        Assert.Equal(integrated, File.ReadAllText(target));
        Assert.Empty(Directory.GetFiles(testRoot, "*.aigw-backup-*.bak"));
        AssertNoTemporaryFiles();
    }

    [Fact]
    public async Task Delete_backup_mismatch_restores_the_intervening_owned_file()
    {
        var target = Path.Combine(testRoot, "aigw.config.toml");
        var original = PreviewCodex(target, existing: null).ProposedContent;
        CreateFile("aigw.config.toml", original);
        var status = await Manager().GetStatusAsync(new(ClientIntegrationKind.CodexCli, target));
        var intervening = original.Replace("aigw/codex/default", "aigw/codex/intervening", StringComparison.Ordinal);
        var moveCount = 0;
        var manager = new ClientIntegrationLifecycleManager(
            static (source, destination, backup) => File.Replace(source, destination, backup),
            (source, destination) =>
            {
                if (moveCount++ == 0)
                {
                    File.WriteAllText(source, intervening);
                }
                File.Move(source, destination);
            });

        var failure = await Assert.ThrowsAsync<ClientIntegrationException>(() =>
            manager.UnintegrateAsync(new(
                ClientIntegrationKind.CodexCli,
                target,
                status.BeforeSha256!,
                ExpectedAfterSha256: null,
                ExpectDelete: true,
                Confirmed: true)));

        Assert.Equal("aigw_integration_stale_preview", failure.ErrorCode);
        Assert.Equal(intervening, File.ReadAllText(target));
        Assert.Empty(Directory.GetFiles(testRoot, "*.aigw-backup-*.bak"));
    }

    public void Dispose()
    {
        if (Directory.Exists(testRoot))
        {
            Directory.Delete(testRoot, recursive: true);
        }
    }

    private ClientIntegrationLifecycleManager Manager() => new();

    private ClientIntegrationPreviewResult PreviewCodex(string target, string? existing) =>
        new ClientIntegrationPreviewer().Preview(new(
            ClientIntegrationKind.CodexCli,
            target,
            existing,
            "0.134.0"));

    private ClientIntegrationPreviewResult PreviewClaude(
        string target,
        string existing,
        string wrapper) => new ClientIntegrationPreviewer().Preview(new(
            ClientIntegrationKind.ClaudeVsCode,
            target,
            existing,
            "2.1.257",
            "1.94.0",
            wrapper));

    private string CreateFile(string relativePath, string content)
    {
        var path = Path.Combine(testRoot, relativePath);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, content);
        return path;
    }

    private void AssertNoTemporaryFiles() => Assert.Empty(
        Directory.GetFiles(testRoot, "*.aigw-write-*.tmp", SearchOption.AllDirectories));

    private static JsonDocument ParseJsonc(string content) => JsonDocument.Parse(
        content,
        new JsonDocumentOptions
        {
            AllowTrailingCommas = true,
            CommentHandling = JsonCommentHandling.Skip,
        });
}
