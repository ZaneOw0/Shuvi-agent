using System.Text.Json;
using LocalAIGateway.Core.Configuration;
using LocalAIGateway.Core.Credentials;
using LocalAIGateway.Launcher;

namespace LocalAIGateway.Cli.Tests;

public sealed class M4dIntegrationApplyCommandTests : IDisposable
{
    private readonly string testRoot = Path.Combine(
        Path.GetTempPath(),
        $"LocalAIGateway-CliIntegrationApply-{Guid.NewGuid():N}");

    [Fact]
    public async Task Apply_creates_only_the_confirmed_codex_fixture()
    {
        Directory.CreateDirectory(testRoot);
        var target = Path.Combine(testRoot, "aigw.config.toml");
        var preview = await RunAsync(
            "--json", "integrate", "preview",
            "--client", "codex-cli",
            "--target", target,
            "--client-version", "0.134.0");
        var after = Data(preview.Output).GetProperty("afterSha256").GetString()!;

        var apply = await RunAsync(
            "--json", "integrate", "apply",
            "--client", "codex-cli",
            "--target", target,
            "--client-version", "0.134.0",
            "--expect-absent",
            "--expected-after-sha256", after,
            "--confirm", "APPLY");

        Assert.Equal(0, apply.ExitCode);
        Assert.Equal(string.Empty, apply.Error);
        var data = Data(apply.Output);
        Assert.True(data.GetProperty("applied").GetBoolean());
        Assert.Equal(JsonValueKind.Null, data.GetProperty("backupPath").ValueKind);
        Assert.True(data.GetProperty("confirmationConsumed").GetBoolean());
        Assert.True(File.Exists(target));
        Assert.Contains("wire_api = \"responses\"", File.ReadAllText(target), StringComparison.Ordinal);
        AssertNoTemporaryFiles();
    }

    [Fact]
    public async Task Apply_updates_claude_with_a_backup_without_emitting_unmanaged_values()
    {
        Directory.CreateDirectory(testRoot);
        var wrapper = CreateFile("aigw-launcher.exe", "fixture");
        const string existing = "{\n  \"unmanagedSecret\": \"do-not-emit\"\n}\n";
        var target = CreateFile("settings.json", existing);
        var preview = await RunAsync(
            "--json", "integrate", "preview",
            "--client", "claude-vscode",
            "--source", target,
            "--target", target,
            "--client-version", "2.1.257",
            "--host-version", "1.94.0",
            "--wrapper", wrapper);
        var previewData = Data(preview.Output);

        var apply = await RunAsync(
            "--json", "integrate", "apply",
            "--client", "claude-vscode",
            "--target", target,
            "--client-version", "2.1.257",
            "--host-version", "1.94.0",
            "--wrapper", wrapper,
            "--expected-before-sha256", previewData.GetProperty("beforeSha256").GetString()!,
            "--expected-after-sha256", previewData.GetProperty("afterSha256").GetString()!,
            "--confirm", "APPLY");

        Assert.Equal(0, apply.ExitCode);
        Assert.DoesNotContain("do-not-emit", apply.Output, StringComparison.Ordinal);
        var backup = Data(apply.Output).GetProperty("backupPath").GetString();
        Assert.NotNull(backup);
        Assert.Equal(existing, File.ReadAllText(backup));
        Assert.Contains("do-not-emit", File.ReadAllText(target), StringComparison.Ordinal);
        AssertNoTemporaryFiles();
    }

    [Fact]
    public async Task Apply_rejects_wrong_confirmation_before_target_access()
    {
        var target = Path.Combine(testRoot, "missing-parent", "aigw.config.toml");

        var apply = await RunAsync(
            "--json", "integrate", "apply",
            "--client", "codex-cli",
            "--target", target,
            "--client-version", "0.134.0",
            "--expect-absent",
            "--expected-after-sha256", new string('0', 64),
            "--confirm", "apply");

        Assert.Equal(14, apply.ExitCode);
        Assert.Equal("aigw_integration_confirmation_required", ErrorCode(apply.Error));
        Assert.False(Directory.Exists(Path.GetDirectoryName(target)));
    }

    [Fact]
    public async Task Apply_maps_missing_target_directory_to_file_exit_15()
    {
        var target = Path.Combine(testRoot, "missing-parent", "aigw.config.toml");
        var preview = await RunAsync(
            "--json", "integrate", "preview",
            "--client", "codex-cli",
            "--target", target,
            "--client-version", "0.134.0");

        var apply = await RunAsync(
            "--json", "integrate", "apply",
            "--client", "codex-cli",
            "--target", target,
            "--client-version", "0.134.0",
            "--expect-absent",
            "--expected-after-sha256", Data(preview.Output).GetProperty("afterSha256").GetString()!,
            "--confirm", "APPLY");

        Assert.Equal(15, apply.ExitCode);
        Assert.Equal("aigw_integration_file_failed", ErrorCode(apply.Error));
        Assert.False(Directory.Exists(Path.GetDirectoryName(target)));
    }

    public void Dispose()
    {
        if (Directory.Exists(testRoot))
        {
            Directory.Delete(testRoot, recursive: true);
        }
    }

    private string CreateFile(string relativePath, string content)
    {
        var path = Path.Combine(testRoot, relativePath);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, content);
        return path;
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
                new ClientIntegrationApplier(previewer)));
        using var input = new StringReader(string.Empty);
        using var output = new StringWriter();
        using var error = new StringWriter();
        var exitCode = await CliApplication.RunAsync(args, input, output, error, services);
        return new CliRunResult(exitCode, output.ToString(), error.ToString());
    }

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

    private void AssertNoTemporaryFiles() => Assert.Empty(
        Directory.GetFiles(testRoot, "*.aigw-write-*.tmp", SearchOption.AllDirectories));

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
