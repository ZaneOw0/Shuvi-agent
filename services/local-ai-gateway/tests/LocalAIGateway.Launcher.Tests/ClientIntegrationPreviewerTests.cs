using System.Text.Json;

namespace LocalAIGateway.Launcher.Tests;

public sealed class ClientIntegrationPreviewerTests : IDisposable
{
    private readonly string testRoot = Path.Combine(
        Path.GetTempPath(),
        $"LocalAIGateway-IntegrationPreview-{Guid.NewGuid():N}");

    [Fact]
    public void Claude_preview_preserves_jsonc_and_redacts_unmanaged_content_from_diff()
    {
        var wrapper = CreateFile("aigw-launcher.exe", "fixture");
        var target = Path.Combine(testRoot, "settings.json");
        const string existing = "{\r\n  // keep this comment\r\n  \"unrelatedSecret\": \"do-not-print\"\r\n}\r\n";

        var preview = new ClientIntegrationPreviewer().Preview(new(
            ClientIntegrationKind.ClaudeVsCode,
            target,
            existing,
            "2.1.257",
            "1.94.0",
            wrapper));

        Assert.Equal(ClientIntegrationAction.Update, preview.Action);
        Assert.Contains("// keep this comment", preview.ProposedContent, StringComparison.Ordinal);
        Assert.Contains("do-not-print", preview.ProposedContent, StringComparison.Ordinal);
        Assert.DoesNotContain("do-not-print", preview.ManagedDiff, StringComparison.Ordinal);
        Assert.Contains(wrapper.Replace("\\", "\\\\", StringComparison.Ordinal), preview.ManagedDiff, StringComparison.Ordinal);
        using var document = ParseJsonc(preview.ProposedContent);
        Assert.Equal(wrapper, document.RootElement.GetProperty("claudeCode.claudeProcessWrapper").GetString());
        Assert.Equal("do-not-print", document.RootElement.GetProperty("unrelatedSecret").GetString());
    }

    [Fact]
    public void Claude_preview_replaces_only_an_owned_block_and_preserves_comma_shape()
    {
        var wrapper = CreateFile("aigw-launcher.exe", "fixture");
        var oldPath = Path.Combine(testRoot, "old-wrapper.exe");
        var existing = $$"""
            {
              // BEGIN Local AI Gateway managed: claude-vscode v1
              "claudeCode.claudeProcessWrapper": "{{oldPath.Replace("\\", "\\\\", StringComparison.Ordinal)}}",
              // END Local AI Gateway managed: claude-vscode v1
              "keep": true
            }
            """;

        var preview = new ClientIntegrationPreviewer().Preview(new(
            ClientIntegrationKind.ClaudeVsCode,
            Path.Combine(testRoot, "settings.json"),
            existing,
            "2.2.0",
            "1.100.0",
            wrapper));

        using var document = ParseJsonc(preview.ProposedContent);
        Assert.True(document.RootElement.GetProperty("keep").GetBoolean());
        Assert.Equal(wrapper, document.RootElement.GetProperty("claudeCode.claudeProcessWrapper").GetString());
        Assert.DoesNotContain(oldPath, preview.ManagedDiff, StringComparison.Ordinal);
    }

    [Fact]
    public void Claude_preview_rejects_an_unowned_existing_property()
    {
        var wrapper = CreateFile("aigw-launcher.exe", "fixture");
        var existing = "{ \"claudeCode.claudeProcessWrapper\": \"C:\\\\other.exe\" }";

        var failure = Assert.Throws<ClientIntegrationException>(() =>
            new ClientIntegrationPreviewer().Preview(new(
                ClientIntegrationKind.ClaudeVsCode,
                Path.Combine(testRoot, "settings.json"),
                existing,
                "2.1.257",
                "1.94.0",
                wrapper)));

        Assert.Equal("aigw_integration_ownership_conflict", failure.ErrorCode);
    }

    [Fact]
    public void Claude_preview_rejects_user_content_inside_owned_markers()
    {
        var wrapper = CreateFile("aigw-launcher.exe", "fixture");
        const string existing = """
            {
              // BEGIN Local AI Gateway managed: claude-vscode v1
              "claudeCode.claudeProcessWrapper": "C:\\old.exe",
              "userSetting": true
              // END Local AI Gateway managed: claude-vscode v1
            }
            """;

        var failure = Assert.Throws<ClientIntegrationException>(() =>
            new ClientIntegrationPreviewer().Preview(new(
                ClientIntegrationKind.ClaudeVsCode,
                Path.Combine(testRoot, "settings.json"),
                existing,
                "2.1.257",
                "1.94.0",
                wrapper)));

        Assert.Equal("aigw_integration_ownership_conflict", failure.ErrorCode);
    }

    [Theory]
    [InlineData("1.9.0", "1.94.0")]
    [InlineData("3.0.0", "1.94.0")]
    [InlineData("2.1.0", "2.0.0")]
    [InlineData("2.1", "1.94.0")]
    public void Claude_preview_rejects_unreviewed_or_malformed_versions(
        string clientVersion,
        string hostVersion)
    {
        var wrapper = CreateFile("aigw-launcher.exe", "fixture");

        var failure = Assert.Throws<ClientIntegrationException>(() =>
            new ClientIntegrationPreviewer().Preview(new(
                ClientIntegrationKind.ClaudeVsCode,
                Path.Combine(testRoot, "settings.json"),
                null,
                clientVersion,
                hostVersion,
                wrapper)));

        Assert.Contains(
            failure.ErrorCode,
            new[] { "aigw_integration_version_unsupported", "aigw_integration_request_invalid" });
    }

    [Fact]
    public void Codex_preview_creates_a_dedicated_responses_profile_without_a_token()
    {
        var preview = new ClientIntegrationPreviewer().Preview(new(
            ClientIntegrationKind.CodexCli,
            Path.Combine(testRoot, "aigw.config.toml"),
            null,
            "0.134.0"));

        Assert.Equal(ClientIntegrationAction.Create, preview.Action);
        Assert.Contains("model_provider = \"aigw\"", preview.ProposedContent, StringComparison.Ordinal);
        Assert.Contains("wire_api = \"responses\"", preview.ProposedContent, StringComparison.Ordinal);
        Assert.Contains("env_key = \"AIGW_CODEX_API_KEY\"", preview.ProposedContent, StringComparison.Ordinal);
        Assert.DoesNotContain("runtime-token", preview.ProposedContent, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("Bearer ", preview.ProposedContent, StringComparison.OrdinalIgnoreCase);
    }

    [Theory]
    [InlineData("\n")]
    [InlineData("\r\n")]
    public void Codex_preview_updates_only_an_owned_profile_and_preserves_external_comments(string newline)
    {
        var existing = """
            # user comment
            # BEGIN Local AI Gateway managed: codex-cli v1
            model = "old"
            model_provider = "old"

            [model_providers.aigw]
            name = "old"
            base_url = "http://127.0.0.1:1/v1"
            env_key = "OLD_KEY"
            wire_api = "responses"
            # END Local AI Gateway managed: codex-cli v1

            """.Replace("\r\n", "\n", StringComparison.Ordinal)
                .Replace("\n", newline, StringComparison.Ordinal);

        var preview = new ClientIntegrationPreviewer().Preview(new(
            ClientIntegrationKind.CodexCli,
            Path.Combine(testRoot, "aigw.config.toml"),
            existing,
            "0.200.1"));

        Assert.Equal(ClientIntegrationAction.Update, preview.Action);
        Assert.StartsWith("# user comment" + newline, preview.ProposedContent, StringComparison.Ordinal);
        Assert.Contains("model = \"aigw/codex/default\"", preview.ProposedContent, StringComparison.Ordinal);
    }

    [Fact]
    public void Codex_preview_reports_unchanged_for_the_exact_owned_profile()
    {
        var previewer = new ClientIntegrationPreviewer();
        var target = Path.Combine(testRoot, "aigw.config.toml");
        var created = previewer.Preview(new(
            ClientIntegrationKind.CodexCli,
            target,
            null,
            "0.134.0"));

        var unchanged = previewer.Preview(new(
            ClientIntegrationKind.CodexCli,
            target,
            created.ProposedContent,
            "0.134.0"));

        Assert.Equal(ClientIntegrationAction.Unchanged, unchanged.Action);
        Assert.Contains("= owned block unchanged", unchanged.ManagedDiff, StringComparison.Ordinal);
        Assert.Equal(unchanged.BeforeSha256, unchanged.AfterSha256);
    }

    [Fact]
    public void Preview_rejects_source_content_over_the_character_limit()
    {
        var failure = Assert.Throws<ClientIntegrationException>(() =>
            new ClientIntegrationPreviewer().Preview(new(
                ClientIntegrationKind.CodexCli,
                Path.Combine(testRoot, "aigw.config.toml"),
                new string('#', ClientIntegrationPreviewer.MaximumSourceCharacters + 1),
                "0.134.0")));

        Assert.Equal("aigw_integration_source_invalid", failure.ErrorCode);
    }

    [Theory]
    [InlineData("model = \"user-value\"\n")]
    [InlineData("# BEGIN Local AI Gateway managed: codex-cli v1\nmodel = \"old\"\n")]
    [InlineData("# BEGIN Local AI Gateway managed: codex-cli v1\nmodel = \"old\"\nuser_setting = true\n# END Local AI Gateway managed: codex-cli v1\n")]
    public void Codex_preview_rejects_unowned_or_malformed_profile_content(string existing)
    {
        var failure = Assert.Throws<ClientIntegrationException>(() =>
            new ClientIntegrationPreviewer().Preview(new(
                ClientIntegrationKind.CodexCli,
                Path.Combine(testRoot, "aigw.config.toml"),
                existing,
                "0.134.0")));

        Assert.Equal("aigw_integration_ownership_conflict", failure.ErrorCode);
    }

    [Theory]
    [InlineData("0.133.9")]
    [InlineData("1.0.0")]
    [InlineData("0.134")]
    public void Codex_preview_rejects_unreviewed_or_malformed_versions(string version)
    {
        var failure = Assert.Throws<ClientIntegrationException>(() =>
            new ClientIntegrationPreviewer().Preview(new(
                ClientIntegrationKind.CodexCli,
                Path.Combine(testRoot, "aigw.config.toml"),
                null,
                version)));

        Assert.Contains(
            failure.ErrorCode,
            new[] { "aigw_integration_version_unsupported", "aigw_integration_request_invalid" });
    }

    public void Dispose()
    {
        if (Directory.Exists(testRoot))
        {
            Directory.Delete(testRoot, recursive: true);
        }
    }

    private string CreateFile(string name, string content)
    {
        Directory.CreateDirectory(testRoot);
        var path = Path.Combine(testRoot, name);
        File.WriteAllText(path, content);
        return path;
    }

    private static JsonDocument ParseJsonc(string content) => JsonDocument.Parse(
        content,
        new JsonDocumentOptions
        {
            AllowTrailingCommas = true,
            CommentHandling = JsonCommentHandling.Skip,
        });
}
