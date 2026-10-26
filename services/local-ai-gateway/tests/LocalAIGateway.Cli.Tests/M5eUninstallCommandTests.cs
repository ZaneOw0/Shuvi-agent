using System.Text.Json;
using LocalAIGateway.Core.Configuration;
using LocalAIGateway.Core.Credentials;
using LocalAIGateway.Core.Uninstall;

namespace LocalAIGateway.Cli.Tests;

public sealed class M5eUninstallCommandTests : IDisposable
{
    private readonly string root = Path.Combine(
        Path.GetTempPath(),
        $"LocalAIGateway-CliUninstall-{Guid.NewGuid():N}");

    [Fact]
    public async Task Non_interactive_command_forwards_every_selection_and_explicit_target()
    {
        var service = new FakeUninstallService();
        var backup = Path.Combine(root, "backup.aigw.json");
        var claude = Path.Combine(root, "settings.json");

        var result = await RunAsync(
            CreateServices(service),
            string.Empty,
            "--json", "uninstall", "--non-interactive", "--confirm", "UNINSTALL",
            "--program", "remove",
            "--autostart", "remove",
            "--integrations", "remove",
            "--runtime-credential", "remove",
            "--provider-credentials", "remove",
            "--configuration", "keep",
            "--usage", "remove",
            "--logs", "keep",
            "--backups", "remove",
            "--claude-vscode-target", claude,
            "--backup-path", backup);

        Assert.Equal(0, result.ExitCode);
        Assert.NotNull(service.Request);
        Assert.Equal(UninstallChoice.Remove, service.Request.Selection.Program);
        Assert.Equal(UninstallChoice.Keep, service.Request.Selection.Configuration);
        Assert.Equal(claude, Assert.Single(service.Request.IntegrationTargets).TargetPath);
        Assert.Equal(backup, Assert.Single(service.Request.BackupPaths));
        using var json = JsonDocument.Parse(result.Output);
        Assert.True(json.RootElement.GetProperty("data").GetProperty("completionPending").GetBoolean());
        Assert.DoesNotContain("secret", result.Output, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task Non_interactive_omission_fails_before_service_call()
    {
        var service = new FakeUninstallService();

        var result = await RunAsync(
            CreateServices(service),
            string.Empty,
            "--json", "uninstall", "--non-interactive", "--confirm", "UNINSTALL",
            "--program", "remove");

        Assert.Equal(CliApplication.FileOrPermissionErrorExitCode, result.ExitCode);
        Assert.Null(service.Request);
        Assert.Equal("aigw_uninstall_selection_incomplete", ErrorCode(result.Error));
    }

    [Fact]
    public async Task Interactive_command_prompts_all_categories_and_forwards_answers()
    {
        var service = new FakeUninstallService();
        var result = await RunAsync(
            CreateServices(service),
            "n\nn\nn\ny\ny\ny\ny\ny\nn\n",
            "--json", "uninstall");

        Assert.Equal(0, result.ExitCode);
        Assert.NotNull(service.Request);
        Assert.Equal(UninstallChoice.Keep, service.Request.Selection.Program);
        Assert.Equal(UninstallChoice.Remove, service.Request.Selection.RuntimeCredential);
        Assert.Equal(UninstallChoice.Remove, service.Request.Selection.Configuration);
        Assert.Equal(UninstallChoice.Keep, service.Request.Selection.Backups);
        Assert.Contains("Remove program?", result.Error, StringComparison.Ordinal);
        Assert.Contains("Remove backups?", result.Error, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Removing_integrations_without_explicit_targets_fails_closed()
    {
        var service = new FakeUninstallService();
        var arguments = CompleteArguments();
        Replace(arguments, "--integrations", "remove");

        var result = await RunAsync(CreateServices(service), string.Empty, arguments.ToArray());

        Assert.Equal(CliApplication.FileOrPermissionErrorExitCode, result.ExitCode);
        Assert.Equal("aigw_uninstall_integration_targets_required", ErrorCode(result.Error));
        Assert.Null(service.Request);
    }

    private CliServices CreateServices(IUninstallService service)
    {
        var store = new ConfigurationStore(
            new ConfigurationPaths(Path.Combine(root, "state")),
            NoOpConfigurationFileSecurity.Instance);
        return new CliServices(
            new GatewayConfigurationManager(store, new EmptyCredentialStore()),
            Uninstall: new CliUninstallServices(service));
    }

    private static List<string> CompleteArguments() =>
    [
        "--json", "uninstall", "--non-interactive", "--confirm", "UNINSTALL",
        "--program", "keep",
        "--autostart", "keep",
        "--integrations", "keep",
        "--runtime-credential", "keep",
        "--provider-credentials", "keep",
        "--configuration", "keep",
        "--usage", "keep",
        "--logs", "keep",
        "--backups", "keep",
    ];

    private static void Replace(List<string> arguments, string option, string value)
    {
        arguments[arguments.IndexOf(option) + 1] = value;
    }

    private static async Task<CliResult> RunAsync(
        CliServices services,
        string input,
        params string[] arguments)
    {
        using var stdout = new StringWriter();
        using var stderr = new StringWriter();
        var exitCode = await CliApplication.RunAsync(
            arguments,
            new StringReader(input),
            stdout,
            stderr,
            services);
        return new CliResult(exitCode, stdout.ToString(), stderr.ToString());
    }

    private static string? ErrorCode(string json)
    {
        using var document = JsonDocument.Parse(json);
        return document.RootElement.GetProperty("error").GetProperty("code").GetString();
    }

    public void Dispose()
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }

    private sealed record CliResult(int ExitCode, string Output, string Error);

    private sealed class FakeUninstallService : IUninstallService
    {
        public UninstallRequest? Request { get; private set; }

        public Task<UninstallResult> UninstallAsync(
            UninstallRequest request,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            Request = request;
            var skipped = new UninstallCategoryResult(false, false, false, []);
            return Task.FromResult(new UninstallResult(
                skipped, skipped, skipped, skipped, skipped, skipped, skipped, skipped, skipped,
                CompletionPending: true,
                OperationId: "fixture-operation",
                ReceiptPath: "C:\\fixture\\receipt.json"));
        }
    }

    private sealed class EmptyCredentialStore : ICredentialStore
    {
        public ValueTask SetSecretAsync(string target, string secret, CancellationToken cancellationToken = default) =>
            ValueTask.CompletedTask;
        public ValueTask<string?> GetSecretAsync(string target, CancellationToken cancellationToken = default) =>
            ValueTask.FromResult<string?>(null);
        public ValueTask DeleteSecretAsync(string target, CancellationToken cancellationToken = default) =>
            ValueTask.CompletedTask;
    }
}
