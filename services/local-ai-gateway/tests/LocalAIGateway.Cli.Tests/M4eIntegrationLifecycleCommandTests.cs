using System.Text.Json;
using LocalAIGateway.Core.Configuration;
using LocalAIGateway.Core.Credentials;
using LocalAIGateway.Launcher;

namespace LocalAIGateway.Cli.Tests;

public sealed class M4eIntegrationLifecycleCommandTests : IDisposable
{
    private readonly string testRoot = Path.Combine(
        Path.GetTempPath(),
        $"LocalAIGateway-CliIntegrationLifecycle-{Guid.NewGuid():N}");

    [Fact]
    public async Task Status_reports_owned_claude_fixture_without_unmanaged_output()
    {
        var wrapper = CreateFile("aigw-launcher.exe", "fixture");
        var target = Path.Combine(testRoot, "settings.json");
        var integrated = new ClientIntegrationPreviewer().Preview(new(
            ClientIntegrationKind.ClaudeVsCode,
            target,
            "{ \"privateValue\": \"never-emit\" }\n",
            "2.1.257",
            "1.94.0",
            wrapper));
        CreateFile("settings.json", integrated.ProposedContent);

        var result = await RunAsync(
            "--json", "integrate", "status",
            "--client", "claude-vscode",
            "--target", target);

        Assert.Equal(0, result.ExitCode);
        Assert.Equal(string.Empty, result.Error);
        Assert.DoesNotContain("never-emit", result.Output, StringComparison.Ordinal);
        var data = Data(result.Output);
        Assert.Equal("owned", data.GetProperty("state").GetString());
        Assert.Equal("update", data.GetProperty("action").GetString());
        Assert.True(data.GetProperty("canUnintegrate").GetBoolean());
        Assert.False(data.GetProperty("applyPerformed").GetBoolean());
    }

    [Fact]
    public async Task Unintegrate_updates_claude_and_preserves_recovery_backup()
    {
        var wrapper = CreateFile("aigw-launcher.exe", "fixture");
        var target = Path.Combine(testRoot, "settings.json");
        var integrated = new ClientIntegrationPreviewer().Preview(new(
            ClientIntegrationKind.ClaudeVsCode,
            target,
            "{ \"keep\": true }\n",
            "2.1.257",
            "1.94.0",
            wrapper));
        CreateFile("settings.json", integrated.ProposedContent);
        var status = Data((await RunAsync(
            "--json", "integrate", "status",
            "--client", "claude-vscode",
            "--target", target)).Output);

        var result = await RunAsync(
            "--json", "integrate", "unintegrate",
            "--client", "claude-vscode",
            "--target", target,
            "--expected-before-sha256", status.GetProperty("beforeSha256").GetString()!,
            "--expected-after-sha256", status.GetProperty("afterSha256").GetString()!,
            "--confirm", "UNINTEGRATE");

        Assert.Equal(0, result.ExitCode);
        var data = Data(result.Output);
        Assert.True(data.GetProperty("applied").GetBoolean());
        Assert.True(data.GetProperty("confirmationConsumed").GetBoolean());
        var backup = data.GetProperty("backupPath").GetString();
        Assert.NotNull(backup);
        Assert.Contains("BEGIN Local AI Gateway", File.ReadAllText(backup), StringComparison.Ordinal);
        Assert.DoesNotContain("BEGIN Local AI Gateway", File.ReadAllText(target), StringComparison.Ordinal);
        Assert.Contains("\"keep\": true", File.ReadAllText(target), StringComparison.Ordinal);
        AssertNoTemporaryFiles();
    }

    [Fact]
    public async Task Unintegrate_deletes_owned_codex_fixture_to_recovery_backup()
    {
        var target = Path.Combine(testRoot, "aigw.config.toml");
        var integrated = new ClientIntegrationPreviewer().Preview(new(
            ClientIntegrationKind.CodexCli,
            target,
            null,
            "0.134.0"));
        CreateFile("aigw.config.toml", integrated.ProposedContent);
        var status = Data((await RunAsync(
            "--json", "integrate", "status",
            "--client", "codex-cli",
            "--target", target)).Output);

        var result = await RunAsync(
            "--json", "integrate", "unintegrate",
            "--client", "codex-cli",
            "--target", target,
            "--expected-before-sha256", status.GetProperty("beforeSha256").GetString()!,
            "--expect-delete",
            "--confirm", "UNINTEGRATE");

        Assert.Equal(0, result.ExitCode);
        var data = Data(result.Output);
        Assert.Equal("delete", data.GetProperty("action").GetString());
        Assert.False(File.Exists(target));
        Assert.Contains("wire_api = \"responses\"", File.ReadAllText(
            data.GetProperty("backupPath").GetString()!), StringComparison.Ordinal);
    }

    [Fact]
    public async Task Status_reports_absent_target_without_creating_it()
    {
        Directory.CreateDirectory(testRoot);
        var target = Path.Combine(testRoot, "aigw.config.toml");

        var result = await RunAsync(
            "--json", "integrate", "status",
            "--client", "codex-cli",
            "--target", target);

        Assert.Equal(0, result.ExitCode);
        var data = Data(result.Output);
        Assert.Equal("absent", data.GetProperty("state").GetString());
        Assert.False(data.GetProperty("exists").GetBoolean());
        Assert.False(data.GetProperty("canUnintegrate").GetBoolean());
        Assert.False(File.Exists(target));
    }

    [Fact]
    public async Task Wrong_unintegrate_confirmation_is_rejected_before_target_access()
    {
        var target = Path.Combine(testRoot, "missing-parent", "aigw.config.toml");

        var result = await RunAsync(
            "--json", "integrate", "unintegrate",
            "--client", "codex-cli",
            "--target", target,
            "--expected-before-sha256", new string('0', 64),
            "--expect-delete",
            "--confirm", "unintegrate");

        Assert.Equal(14, result.ExitCode);
        Assert.Equal("aigw_integration_confirmation_required", ErrorCode(result.Error));
        Assert.False(Directory.Exists(Path.GetDirectoryName(target)));
    }

    public void Dispose()
    {
        if (Directory.Exists(testRoot))
        {
            Directory.Delete(testRoot, recursive: true);
        }
    }

    private async Task<CliRunResult> RunAsync(params string[] args)
    {
        var previewer = new ClientIntegrationPreviewer();
        var services = new CliServices(
            new GatewayConfigurationManager(
                new ConfigurationStore(
                    new ConfigurationPaths(Path.Combine(testRoot, "configuration")),
                    NoOpConfigurationFileSecurity.Instance),
                new MemoryCredentialStore()),
            Integrations: new CliIntegrationServices(
                previewer,
                new ClientIntegrationApplier(previewer),
                new ClientIntegrationLifecycleManager()));
        using var input = new StringReader(string.Empty);
        using var output = new StringWriter();
        using var error = new StringWriter();
        var exitCode = await CliApplication.RunAsync(args, input, output, error, services);
        return new CliRunResult(exitCode, output.ToString(), error.ToString());
    }

    private string CreateFile(string relativePath, string content)
    {
        var path = Path.Combine(testRoot, relativePath);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, content);
        return path;
    }

    private void AssertNoTemporaryFiles() => Assert.Empty(
        Directory.GetFiles(testRoot, "*.aigw-write-*.tmp", SearchOption.AllDirectories));

    private static JsonElement Data(string json)
    {
        using var document = JsonDocument.Parse(json);
        return document.RootElement.GetProperty("data").Clone();
    }

    private static string? ErrorCode(string json)
    {
        using var document = JsonDocument.Parse(json);
        return document.RootElement.GetProperty("error").GetProperty("code").GetString();
    }

    private sealed record CliRunResult(int ExitCode, string Output, string Error);

    private sealed class MemoryCredentialStore : ICredentialStore
    {
        public ValueTask<string?> GetSecretAsync(
            string target,
            CancellationToken cancellationToken = default) => ValueTask.FromResult<string?>(null);

        public ValueTask SetSecretAsync(
            string target,
            string secret,
            CancellationToken cancellationToken = default) => ValueTask.CompletedTask;

        public ValueTask DeleteSecretAsync(
            string target,
            CancellationToken cancellationToken = default) => ValueTask.CompletedTask;
    }
}
