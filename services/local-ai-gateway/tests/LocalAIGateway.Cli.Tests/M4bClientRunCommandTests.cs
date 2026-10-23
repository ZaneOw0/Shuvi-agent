using System.Text.Json;
using LocalAIGateway.Core.Configuration;
using LocalAIGateway.Core.Credentials;
using LocalAIGateway.Launcher;

namespace LocalAIGateway.Cli.Tests;

public sealed class M4bClientRunCommandTests : IDisposable
{
    private readonly string testRoot = Path.Combine(
        Path.GetTempPath(),
        $"LocalAIGateway-CliClient-{Guid.NewGuid():N}");

    [Fact]
    public async Task Claude_run_passes_arguments_verbatim_and_returns_the_child_exit_without_cli_output()
    {
        var executable = CreateExecutable("claude.exe");
        var launcher = new TestLauncher { ExitCode = 37 };
        var services = CreateServices(launcher, new TestResolver(ClientKind.Claude, executable));

        var result = await RunAsync(
            services,
            "run", "claude", "--", "--print", "value with spaces", "& whoami");

        Assert.Equal(37, result.ExitCode);
        Assert.Equal(string.Empty, result.Output);
        Assert.Equal(string.Empty, result.Error);
        Assert.NotNull(launcher.Request);
        Assert.Equal(
            ["--model", "aigw/default", "--print", "value with spaces", "& whoami"],
            launcher.Request.Arguments);
    }

    [Fact]
    public async Task Custom_run_requires_explicit_environment_names_and_preserves_arguments()
    {
        var executable = CreateExecutable("fixture.exe");
        var launcher = new TestLauncher { ExitCode = 0 };
        var services = CreateServices(launcher, new FailingResolver());

        var result = await RunAsync(
            services,
            "run",
            "--client", executable,
            "--base-url-env", "FIXTURE_BASE",
            "--token-env", "FIXTURE_TOKEN",
            "--working-directory", testRoot,
            "--", "", "quote\"inside", "$(ignored)");

        Assert.Equal(0, result.ExitCode);
        Assert.Equal(string.Empty, result.Output);
        Assert.Equal(string.Empty, result.Error);
        Assert.Equal(executable, launcher.Request!.ExecutablePath);
        Assert.Equal(["", "quote\"inside", "$(ignored)"], launcher.Request.Arguments);
        Assert.Equal("FIXTURE_BASE", launcher.Request.BaseUrlEnvironmentVariable);
        Assert.Equal("FIXTURE_TOKEN", launcher.Request.TokenEnvironmentVariable);
    }

    [Fact]
    public async Task Known_client_conflict_fails_before_launch_with_a_stable_error()
    {
        var executable = CreateExecutable("codex.exe");
        var launcher = new TestLauncher();
        var services = CreateServices(launcher, new TestResolver(ClientKind.Codex, executable));

        var result = await RunAsync(
            services,
            "--json", "run", "codex", "--", "--config", "model_provider=\"other\"");

        Assert.Equal(12, result.ExitCode);
        Assert.Equal(string.Empty, result.Output);
        Assert.Equal("aigw_launcher_option_conflict", ErrorCode(result.Error));
        Assert.Null(launcher.Request);
    }

    [Fact]
    public async Task Custom_run_missing_required_contract_is_a_parse_error_before_launch()
    {
        var launcher = new TestLauncher();
        var services = CreateServices(launcher, new FailingResolver());

        var result = await RunAsync(services, "--json", "run", "--client", "C:\\fixture.exe", "--");

        Assert.Equal(2, result.ExitCode);
        Assert.Equal("aigw_invalid_arguments", ErrorCode(result.Error));
        Assert.Null(launcher.Request);
    }

    [Fact]
    public async Task Client_json_argument_does_not_change_gateway_error_framing()
    {
        var executable = CreateExecutable("codex.exe");
        var launcher = new TestLauncher();
        var services = CreateServices(launcher, new TestResolver(ClientKind.Codex, executable));

        var result = await RunAsync(
            services,
            "--lang", "en", "run", "codex", "--", "--json", "--model", "other");

        Assert.Equal(12, result.ExitCode);
        Assert.StartsWith("Gateway runtime operation failed", result.Error, StringComparison.Ordinal);
        Assert.DoesNotContain("\"error\"", result.Error, StringComparison.Ordinal);
        Assert.Null(launcher.Request);
    }

    public void Dispose()
    {
        if (Directory.Exists(testRoot))
        {
            Directory.Delete(testRoot, recursive: true);
        }
    }

    private CliServices CreateServices(
        TestLauncher launcher,
        IClientExecutableResolver resolver)
    {
        Directory.CreateDirectory(testRoot);
        var configuration = new GatewayConfigurationManager(
            new ConfigurationStore(
                new ConfigurationPaths(Path.Combine(testRoot, "configuration")),
                NoOpConfigurationFileSecurity.Instance),
            new MemoryCredentialStore());
        return new CliServices(
            configuration,
            Clients: new CliClientServices(
                launcher,
                new ClientLaunchRequestFactory(resolver)));
    }

    private string CreateExecutable(string fileName)
    {
        Directory.CreateDirectory(testRoot);
        var path = Path.Combine(testRoot, fileName);
        File.WriteAllText(path, "fixture");
        return path;
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

    private sealed class TestLauncher : IClientLaunchService
    {
        public int ExitCode { get; init; }

        public ClientLaunchRequest? Request { get; private set; }

        public Task<int> LaunchAsync(
            ClientLaunchRequest request,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            Request = request;
            return Task.FromResult(ExitCode);
        }
    }

    private sealed class TestResolver(ClientKind expectedClient, string executablePath)
        : IClientExecutableResolver
    {
        public string Resolve(ClientKind client)
        {
            Assert.Equal(expectedClient, client);
            return executablePath;
        }
    }

    private sealed class FailingResolver : IClientExecutableResolver
    {
        public string Resolve(ClientKind client) => throw new InvalidOperationException(
            "Custom launch must not resolve a known client.");
    }

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
