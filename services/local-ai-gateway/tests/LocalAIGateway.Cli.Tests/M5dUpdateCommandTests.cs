using System.Text.Json;
using LocalAIGateway.Core.Configuration;
using LocalAIGateway.Core.Credentials;
using LocalAIGateway.Core.Update;

namespace LocalAIGateway.Cli.Tests;

public sealed class M5dUpdateCommandTests : IDisposable
{
    private readonly string root = Path.Combine(Path.GetTempPath(), $"LocalAIGateway-M5d-Cli-{Guid.NewGuid():N}");
    private readonly FakeUpdateService update = new();
    private readonly CliServices services;

    public M5dUpdateCommandTests()
    {
        Directory.CreateDirectory(root);
        services = new CliServices(
            new GatewayConfigurationManager(
                new ConfigurationStore(new ConfigurationPaths(root), NoOpConfigurationFileSecurity.Instance),
                new EmptyCredentialStore()),
            Update: new CliUpdateServices(update));
    }

    [Fact]
    public async Task Inspect_is_read_only_and_emits_hash_trust_and_version()
    {
        var result = await RunAsync(
            "--json", "update", "inspect", "--package", Path.Combine(root, "candidate"),
            "--allow-unsigned-development");

        Assert.Equal(0, result.ExitCode);
        Assert.True(update.AllowUnsigned);
        using var json = JsonDocument.Parse(result.Output);
        var data = json.RootElement.GetProperty("data");
        Assert.Equal("0.2.0-dev", data.GetProperty("version").GetString());
        Assert.Equal(new string('a', 64), data.GetProperty("manifestSha256").GetString());
        Assert.False(data.GetProperty("applyPerformed").GetBoolean());
    }

    [Fact]
    public async Task Apply_binds_hash_confirmation_and_unsigned_authorization()
    {
        var result = await RunAsync(
            "--json", "update", "apply", "--package", Path.Combine(root, "candidate"),
            "--expected-manifest-sha256", new string('a', 64), "--confirm", "UPDATE",
            "--allow-unsigned-development");

        Assert.Equal(0, result.ExitCode);
        Assert.True(update.Request!.Confirmed);
        Assert.True(update.Request.AllowUnsignedDevelopment);
        using var json = JsonDocument.Parse(result.Output);
        Assert.Equal("0.2.0-dev", json.RootElement.GetProperty("data").GetProperty("currentVersion").GetString());
    }

    [Fact]
    public async Task Wrong_confirmation_returns_stable_update_exit_code()
    {
        update.RejectUnconfirmed = true;
        var result = await RunAsync(
            "--json", "update", "apply", "--package", Path.Combine(root, "candidate"),
            "--expected-manifest-sha256", new string('a', 64), "--confirm", "update");

        Assert.Equal(18, result.ExitCode);
        using var json = JsonDocument.Parse(result.Error);
        Assert.Equal("aigw_update_confirmation_required", json.RootElement.GetProperty("error").GetProperty("code").GetString());
    }

    [Fact]
    public async Task Scheduled_apply_reports_operation_and_receipt_without_claiming_completion()
    {
        update.Schedule = true;
        var result = await RunAsync(
            "--json", "update", "apply", "--package", Path.Combine(root, "candidate"),
            "--expected-manifest-sha256", new string('a', 64), "--confirm", "UPDATE",
            "--allow-unsigned-development");

        Assert.Equal(0, result.ExitCode);
        using var json = JsonDocument.Parse(result.Output);
        var data = json.RootElement.GetProperty("data");
        Assert.True(data.GetProperty("completionPending").GetBoolean());
        Assert.Equal("fixture-operation", data.GetProperty("operationId").GetString());
        Assert.Equal("0.2.0-dev", data.GetProperty("candidateVersion").GetString());
        Assert.False(data.TryGetProperty("daemonRunning", out _));
    }

    private async Task<Result> RunAsync(params string[] args)
    {
        using var stdout = new StringWriter();
        using var stderr = new StringWriter();
        var exit = await CliApplication.RunAsync(args, new StringReader(string.Empty), stdout, stderr, services);
        return new(exit, stdout.ToString(), stderr.ToString());
    }

    public void Dispose()
    {
        if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
    }

    private sealed record Result(int ExitCode, string Output, string Error);

    private sealed class FakeUpdateService : IPackageUpdateService
    {
        public bool AllowUnsigned { get; private set; }
        public bool RejectUnconfirmed { get; set; }
        public bool Schedule { get; set; }
        public PackageUpdateRequest? Request { get; private set; }
        public Task<PackageUpdateInspection> InspectAsync(string packageRoot, bool allowUnsignedDevelopment, CancellationToken cancellationToken = default)
        {
            AllowUnsigned = allowUnsignedDevelopment;
            return Task.FromResult(new PackageUpdateInspection(
                packageRoot, "0.2.0-dev", new string('a', 64), PackageTrustKind.UnsignedDevelopment, null, 123));
        }
        public Task<PackageUpdateResult> ApplyAsync(PackageUpdateRequest request, CancellationToken cancellationToken = default)
        {
            Request = request;
            if (RejectUnconfirmed && !request.Confirmed)
                throw new UpdateException("aigw_update_confirmation_required", "confirmation required");
            if (Schedule)
                return Task.FromResult(new PackageUpdateResult(
                    "0.1.0-dev", "0.2.0-dev", request.ExpectedManifestSha256,
                    PackageTrustKind.UnsignedDevelopment, null, false, false, false, null,
                    true, "fixture-operation", "C:\\fixture-receipt.json"));
            return Task.FromResult(new PackageUpdateResult(
                "0.1.0-dev", "0.2.0-dev", request.ExpectedManifestSha256,
                PackageTrustKind.UnsignedDevelopment, null, false, false, false, null));
        }
    }

    private sealed class EmptyCredentialStore : ICredentialStore
    {
        public ValueTask SetSecretAsync(string target, string secret, CancellationToken cancellationToken = default) => ValueTask.CompletedTask;
        public ValueTask<string?> GetSecretAsync(string target, CancellationToken cancellationToken = default) => ValueTask.FromResult<string?>(null);
        public ValueTask DeleteSecretAsync(string target, CancellationToken cancellationToken = default) => ValueTask.CompletedTask;
    }
}
