using System.Text;
using System.Text.Json;
using LocalAIGateway.Core.Backup;
using LocalAIGateway.Core.Configuration;
using LocalAIGateway.Core.Credentials;

namespace LocalAIGateway.Cli.Tests;

public sealed class M5cBackupCommandTests : IDisposable
{
    private readonly string root = Path.Combine(
        Path.GetTempPath(),
        $"LocalAIGateway-M5c-Cli-{Guid.NewGuid():N}");
    private readonly MemoryCredentialStore credentials = new();
    private readonly ConfigurationStore store;
    private readonly CliServices services;

    public M5cBackupCommandTests()
    {
        Directory.CreateDirectory(root);
        store = new ConfigurationStore(
            new ConfigurationPaths(Path.Combine(root, "state")),
            NoOpConfigurationFileSecurity.Instance);
        var crypto = new FakeCryptography();
        services = new CliServices(
            new GatewayConfigurationManager(store, credentials),
            Backup: new CliBackupServices(new BackupCoordinator(
                store,
                credentials,
                crypto,
                NoOpConfigurationFileSecurity.Instance,
                new FixedTimeProvider(new DateTimeOffset(2026, 9, 10, 12, 0, 0, TimeSpan.Zero)))));
    }

    [Fact]
    public async Task Plain_create_and_inspect_return_stable_secret_free_json()
    {
        await SeedAsync();
        credentials.Values[CredentialTargets.UpstreamApiKey("work", "primary")] = "plain-provider-secret-canary";
        credentials.Values[CredentialTargets.RuntimeClientToken] = "plain-runtime-secret-canary";
        var outputPath = Path.Combine(root, "plain.json");

        var created = await RunAsync(string.Empty,
            "--json", "backup", "create", "--output", outputPath);
        var inspected = await RunAsync(string.Empty,
            "--json", "backup", "inspect", "--input", outputPath);

        Assert.Equal(0, created.ExitCode);
        Assert.Equal(0, inspected.ExitCode);
        using var createJson = JsonDocument.Parse(created.Output);
        var data = createJson.RootElement.GetProperty("data");
        Assert.False(data.GetProperty("encrypted").GetBoolean());
        Assert.False(data.GetProperty("runtimeCredentialIncluded").GetBoolean());
        Assert.Equal(1, data.GetProperty("profileCount").GetInt32());
        Assert.DoesNotContain("plain-provider-secret-canary", created.Output);
        Assert.DoesNotContain("plain-runtime-secret-canary", created.Output);
        Assert.DoesNotContain("plain-provider-secret-canary", await File.ReadAllTextAsync(outputPath));
        Assert.DoesNotContain("plain-runtime-secret-canary", await File.ReadAllTextAsync(outputPath));
        Assert.Equal(string.Empty, created.Error);
    }

    [Fact]
    public async Task Encrypted_create_reads_one_passphrase_line_and_never_outputs_secrets()
    {
        await SeedAsync();
        var target = CredentialTargets.UpstreamApiKey("work", "primary");
        credentials.Values[target] = "provider-secret-canary";
        var outputPath = Path.Combine(root, "encrypted.json");

        var result = await RunAsync("correct horse battery staple\n",
            "--json", "backup", "create", "--output", outputPath,
            "--include-secrets", "--passphrase-stdin");

        Assert.Equal(0, result.ExitCode);
        Assert.DoesNotContain("provider-secret-canary", result.Output);
        Assert.DoesNotContain("correct horse battery staple", result.Output);
        using var document = JsonDocument.Parse(result.Output);
        Assert.True(document.RootElement.GetProperty("data").GetProperty("encrypted").GetBoolean());
        Assert.Equal(1, document.RootElement.GetProperty("data").GetProperty("secretCount").GetInt32());
    }

    [Fact]
    public async Task Restore_rejects_wrong_confirmation_before_reading_file()
    {
        var result = await RunAsync(string.Empty,
            "--json", "backup", "restore",
            "--input", Path.Combine(root, "missing.json"),
            "--expected-sha256", new string('0', 64),
            "--expected-current-revision", "0",
            "--confirm", "NO");

        Assert.Equal(CliApplication.BackupErrorExitCode, result.ExitCode);
        using var document = JsonDocument.Parse(result.Error);
        Assert.Equal(
            "aigw_backup_confirmation_required",
            document.RootElement.GetProperty("error").GetProperty("code").GetString());
    }

    [Fact]
    public async Task Restore_uses_inspected_hash_and_revision_and_reports_only_counts()
    {
        var original = await SeedAsync();
        var outputPath = Path.Combine(root, "plain.json");
        var created = await RunAsync(string.Empty,
            "--json", "backup", "create", "--output", outputPath);
        using var createdJson = JsonDocument.Parse(created.Output);
        var hash = createdJson.RootElement.GetProperty("data").GetProperty("sha256").GetString()!;
        var changed = await store.SaveAsync(original with { ActiveProfileId = null }, original.Revision);

        var restored = await RunAsync(string.Empty,
            "--json", "backup", "restore",
            "--input", outputPath,
            "--expected-sha256", hash,
            "--expected-current-revision", changed.Revision.ToString(System.Globalization.CultureInfo.InvariantCulture),
            "--confirm", "RESTORE");

        Assert.Equal(0, restored.ExitCode);
        using var restoredJson = JsonDocument.Parse(restored.Output);
        var data = restoredJson.RootElement.GetProperty("data");
        Assert.Equal(changed.Revision + 1, data.GetProperty("currentRevision").GetInt64());
        Assert.Equal(0, data.GetProperty("secretsRestored").GetInt32());
        Assert.Equal("work", (await store.LoadAsync()).ActiveProfileId);
    }

    public void Dispose()
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }

    private async Task<GatewayConfiguration> SeedAsync() => await store.SaveAsync(new GatewayConfiguration
    {
        ActiveProfileId = "work",
        Profiles =
        [
            new ProfileConfiguration
            {
                Id = "work",
                Name = "Work",
                Providers =
                [
                    new ProviderConfiguration
                    {
                        Id = "primary",
                        Name = "Primary",
                        Type = ProviderType.OpenAiCompatible,
                        Endpoint = "https://api.example.com/v1",
                        CredentialTarget = CredentialTargets.UpstreamApiKey("work", "primary"),
                    },
                ],
                Models =
                [
                    new ModelConfiguration
                    {
                        Alias = "aigw/default",
                        ProviderId = "primary",
                        UpstreamModel = "model",
                        IsDefault = true,
                    },
                ],
            },
        ],
    }, 0);

    private async Task<CliRunResult> RunAsync(string input, params string[] args)
    {
        using var stdin = new StringReader(input);
        using var stdout = new StringWriter();
        using var stderr = new StringWriter();
        var exitCode = await CliApplication.RunAsync(args, stdin, stdout, stderr, services);
        return new CliRunResult(exitCode, stdout.ToString(), stderr.ToString());
    }

    private sealed record CliRunResult(int ExitCode, string Output, string Error);

    private sealed class MemoryCredentialStore : ICredentialStore
    {
        public Dictionary<string, string> Values { get; } = new(StringComparer.Ordinal);
        public ValueTask SetSecretAsync(string target, string secret, CancellationToken cancellationToken = default)
        {
            Values[target] = secret;
            return ValueTask.CompletedTask;
        }
        public ValueTask<string?> GetSecretAsync(string target, CancellationToken cancellationToken = default) =>
            ValueTask.FromResult(Values.GetValueOrDefault(target));
        public ValueTask DeleteSecretAsync(string target, CancellationToken cancellationToken = default)
        {
            Values.Remove(target);
            return ValueTask.CompletedTask;
        }
    }

    private sealed class FakeCryptography : IBackupCryptography
    {
        public Task<byte[]> EncryptAsync(ReadOnlyMemory<byte> plaintext, string passphrase, CancellationToken cancellationToken = default) =>
            Task.FromResult(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new
            {
                schemaVersion = 1,
                kind = "encrypted",
                payload = Convert.ToBase64String(plaintext.Span),
            })));

        public Task<byte[]> DecryptAsync(ReadOnlyMemory<byte> envelope, string passphrase, CancellationToken cancellationToken = default)
        {
            using var document = JsonDocument.Parse(envelope);
            return Task.FromResult(Convert.FromBase64String(document.RootElement.GetProperty("payload").GetString()!));
        }
    }

    private sealed class FixedTimeProvider(DateTimeOffset now) : TimeProvider
    {
        public override DateTimeOffset GetUtcNow() => now;
    }
}
