using System.Text.Json;
using LocalAIGateway.Core.Configuration;
using LocalAIGateway.Core.Credentials;
using LocalAIGateway.Launcher;

namespace LocalAIGateway.Cli.Tests;

public sealed class M4cIntegrationPreviewCommandTests : IDisposable
{
    private readonly string testRoot = Path.Combine(
        Path.GetTempPath(),
        $"LocalAIGateway-CliIntegration-{Guid.NewGuid():N}");

    [Fact]
    public async Task Claude_preview_reads_only_the_fixture_and_does_not_emit_unmanaged_values()
    {
        var wrapper = CreateFile("aigw-launcher.exe", "fixture");
        const string fixture = "{\n  // keep\n  \"unmanagedSecret\": \"never-emit-this\"\n}\n";
        var source = CreateFile("claude-settings.fixture.json", fixture);
        var target = Path.Combine(testRoot, "represented-target", "settings.json");

        var result = await RunAsync(
            "--json", "integrate", "preview",
            "--client", "claude-vscode",
            "--source", source,
            "--target", target,
            "--client-version", "2.1.257",
            "--host-version", "1.94.0",
            "--wrapper", wrapper);

        Assert.Equal(0, result.ExitCode);
        Assert.Equal(string.Empty, result.Error);
        Assert.DoesNotContain("never-emit-this", result.Output, StringComparison.Ordinal);
        using var document = JsonDocument.Parse(result.Output);
        var data = document.RootElement.GetProperty("data");
        Assert.Equal("update", data.GetProperty("action").GetString());
        Assert.False(data.GetProperty("applyPerformed").GetBoolean());
        Assert.True(data.GetProperty("confirmationRequiredForApply").GetBoolean());
        Assert.Equal(fixture, File.ReadAllText(source));
        Assert.False(File.Exists(target));
    }

    [Fact]
    public async Task Ownership_conflict_returns_exit_14_without_writing_the_target()
    {
        var wrapper = CreateFile("aigw-launcher.exe", "fixture");
        var source = CreateFile(
            "conflicting-settings.fixture.json",
            "{ \"claudeCode.claudeProcessWrapper\": \"C:\\\\other.exe\" }");
        var target = Path.Combine(testRoot, "represented-target", "settings.json");

        var result = await RunAsync(
            "--json", "integrate", "preview",
            "--client", "claude-vscode",
            "--source", source,
            "--target", target,
            "--client-version", "2.1.257",
            "--host-version", "1.94.0",
            "--wrapper", wrapper);

        Assert.Equal(14, result.ExitCode);
        Assert.Equal(string.Empty, result.Output);
        Assert.Equal("aigw_integration_ownership_conflict", ErrorCode(result.Error));
        Assert.False(File.Exists(target));
    }

    [Fact]
    public async Task Codex_preview_represents_a_new_dedicated_profile_without_creating_it()
    {
        var target = Path.Combine(testRoot, "represented-codex-home", "aigw.config.toml");

        var result = await RunAsync(
            "--json", "integrate", "preview",
            "--client", "codex-cli",
            "--target", target,
            "--client-version", "0.134.0");

        Assert.Equal(0, result.ExitCode);
        Assert.Equal(string.Empty, result.Error);
        Assert.Contains("AIGW_CODEX_API_KEY", result.Output, StringComparison.Ordinal);
        Assert.DoesNotContain("runtime-token", result.Output, StringComparison.OrdinalIgnoreCase);
        using var document = JsonDocument.Parse(result.Output);
        Assert.Equal("create", document.RootElement.GetProperty("data").GetProperty("action").GetString());
        Assert.False(File.Exists(target));
    }

    [Fact]
    public async Task Unsupported_client_contract_returns_exit_14()
    {
        var target = Path.Combine(testRoot, "represented-codex-home", "aigw.config.toml");

        var result = await RunAsync(
            "--json", "integrate", "preview",
            "--client", "codex-cli",
            "--target", target,
            "--client-version", "1.0.0");

        Assert.Equal(14, result.ExitCode);
        Assert.Equal("aigw_integration_version_unsupported", ErrorCode(result.Error));
        Assert.False(File.Exists(target));
    }

    [Fact]
    public async Task Preview_rejects_non_utf8_fixture_content()
    {
        Directory.CreateDirectory(testRoot);
        var source = Path.Combine(testRoot, "invalid-utf8.toml");
        File.WriteAllBytes(source, [0xC3, 0x28]);
        var target = Path.Combine(testRoot, "aigw.config.toml");

        var result = await RunAsync(
            CreateServices(),
            "--json", "integrate", "preview",
            "--client", "codex-cli",
            "--source", source,
            "--target", target,
            "--client-version", "0.134.0");

        Assert.Equal(14, result.ExitCode);
        Assert.Equal("aigw_integration_source_invalid", ErrorCode(result.Error));
        Assert.False(File.Exists(target));
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
        Directory.CreateDirectory(testRoot);
        return await RunAsync(CreateServices(), args);
    }

    private CliServices CreateServices()
    {
        var configuration = new GatewayConfigurationManager(
            new ConfigurationStore(
                new ConfigurationPaths(Path.Combine(testRoot, "configuration")),
                NoOpConfigurationFileSecurity.Instance),
            new MemoryCredentialStore());
        return new CliServices(
            configuration,
            Integrations: new CliIntegrationServices(new ClientIntegrationPreviewer()));
    }

    private static async Task<CliRunResult> RunAsync(CliServices services, params string[] args)
    {
        using var input = new StringReader(string.Empty);
        using var output = new StringWriter();
        using var error = new StringWriter();
        var exitCode = await CliApplication.RunAsync(args, input, output, error, services);
        return new CliRunResult(exitCode, output.ToString(), error.ToString());
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
