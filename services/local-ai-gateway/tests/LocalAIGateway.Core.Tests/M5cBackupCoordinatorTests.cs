using System.Text;
using System.Text.Json;
using LocalAIGateway.Core.Backup;
using LocalAIGateway.Core.Configuration;
using LocalAIGateway.Core.Credentials;

namespace LocalAIGateway.Core.Tests;

public sealed class M5cBackupCoordinatorTests : IDisposable
{
    private readonly string root = Path.Combine(
        Path.GetTempPath(),
        $"LocalAIGateway-M5c-Core-{Guid.NewGuid():N}");
    private readonly MemoryCredentialStore credentials = new();
    private readonly FakeCryptography cryptography = new();
    private readonly ConfigurationStore store;
    private readonly BackupCoordinator coordinator;

    public M5cBackupCoordinatorTests()
    {
        Directory.CreateDirectory(root);
        store = new ConfigurationStore(
            new ConfigurationPaths(Path.Combine(root, "state")),
            NoOpConfigurationFileSecurity.Instance);
        coordinator = new BackupCoordinator(
            store,
            credentials,
            cryptography,
            NoOpConfigurationFileSecurity.Instance,
            new FixedTimeProvider(new DateTimeOffset(2026, 9, 10, 12, 34, 56, TimeSpan.Zero)));
    }

    [Fact]
    public async Task Plain_backup_is_atomic_and_excludes_all_credentials()
    {
        var configuration = await SeedAsync("original");
        credentials.Values[CredentialTargets.UpstreamApiKey("work", "primary")] = "provider-secret-canary";
        credentials.Values[CredentialTargets.RuntimeClientToken] = "runtime-secret-canary";
        var output = Path.Combine(root, "plain.aigw-backup.json");

        var created = await coordinator.CreateAsync(new BackupCreateRequest(output, false, null));
        var inspected = await coordinator.InspectAsync(new BackupInspectRequest(output, null));

        Assert.False(created.Encrypted);
        Assert.Equal(configuration.Revision, created.SourceRevision);
        Assert.Equal(created, inspected);
        Assert.Equal(0, inspected.SecretCount);
        Assert.DoesNotContain("provider-secret-canary", await File.ReadAllTextAsync(output));
        Assert.DoesNotContain("runtime-secret-canary", await File.ReadAllTextAsync(output));
        Assert.Empty(Directory.GetFiles(root, "*.tmp", SearchOption.AllDirectories));
        Assert.Equal(0, cryptography.EncryptCalls);
    }

    [Fact]
    public async Task Create_refuses_existing_output_without_changing_it()
    {
        await SeedAsync("original");
        var output = Path.Combine(root, "existing.json");
        await File.WriteAllTextAsync(output, "keep");

        var exception = await Assert.ThrowsAsync<BackupException>(() =>
            coordinator.CreateAsync(new BackupCreateRequest(output, false, null)));

        Assert.Equal("aigw_backup_output_exists", exception.ErrorCode);
        Assert.Equal("keep", await File.ReadAllTextAsync(output));
    }

    [Fact]
    public async Task Create_cleans_temporary_file_when_protection_fails_before_publish()
    {
        await SeedAsync("original");
        var output = Path.Combine(root, "protection-failure.json");
        var failing = new BackupCoordinator(
            store,
            credentials,
            cryptography,
            new FailingFileProtection(),
            TimeProvider.System);

        var exception = await Assert.ThrowsAsync<BackupException>(() =>
            failing.CreateAsync(new BackupCreateRequest(output, false, null)));

        Assert.Equal("aigw_backup_write_failed", exception.ErrorCode);
        Assert.False(File.Exists(output));
        Assert.Empty(Directory.GetFiles(root, "*.tmp", SearchOption.AllDirectories));
    }

    [Fact]
    public async Task Encrypted_backup_collects_only_configured_provider_secrets()
    {
        await SeedAsync("original");
        credentials.Values[CredentialTargets.UpstreamApiKey("work", "primary")] = "provider-secret";
        credentials.Values[CredentialTargets.RuntimeClientToken] = "runtime-secret";
        var output = Path.Combine(root, "encrypted.aigw-backup.json");

        var created = await coordinator.CreateAsync(new BackupCreateRequest(
            output,
            true,
            "correct horse battery staple"));
        var inspected = await coordinator.InspectAsync(new BackupInspectRequest(
            output,
            "correct horse battery staple"));

        Assert.True(created.Encrypted);
        Assert.Equal(1, inspected.SecretCount);
        Assert.Equal(1, cryptography.EncryptCalls);
        Assert.DoesNotContain("provider-secret", await File.ReadAllTextAsync(output));
        Assert.DoesNotContain("runtime-secret", Encoding.UTF8.GetString(cryptography.LastPlaintext!));
        Assert.Contains("provider-secret", Encoding.UTF8.GetString(cryptography.LastPlaintext!));
    }

    [Fact]
    public async Task Restore_requires_confirmation_before_reading_input()
    {
        var exception = await Assert.ThrowsAsync<BackupException>(() =>
            coordinator.RestoreAsync(new BackupRestoreRequest(
                Path.Combine(root, "missing.json"),
                new string('0', 64),
                0,
                false,
                null)));

        Assert.Equal("aigw_backup_confirmation_required", exception.ErrorCode);
    }

    [Fact]
    public async Task Plain_restore_is_hash_and_current_revision_bound()
    {
        var source = await SeedAsync("from-backup");
        var output = Path.Combine(root, "plain.json");
        var backup = await coordinator.CreateAsync(new BackupCreateRequest(output, false, null));
        var current = await store.SaveAsync(
            source with { ActiveProfileId = null },
            source.Revision);

        var wrongHash = await Assert.ThrowsAsync<BackupException>(() =>
            coordinator.RestoreAsync(new BackupRestoreRequest(
                output,
                new string('0', 64),
                current.Revision,
                true,
                null)));
        Assert.Equal("aigw_backup_changed", wrongHash.ErrorCode);

        var wrongRevision = await Assert.ThrowsAsync<BackupException>(() =>
            coordinator.RestoreAsync(new BackupRestoreRequest(
                output,
                backup.Sha256,
                source.Revision,
                true,
                null)));
        Assert.Equal("aigw_backup_current_revision_changed", wrongRevision.ErrorCode);

        var restored = await coordinator.RestoreAsync(new BackupRestoreRequest(
            output,
            backup.Sha256,
            current.Revision,
            true,
            null));

        Assert.Equal(current.Revision + 1, restored.CurrentRevision);
        Assert.Equal("work", (await store.LoadAsync()).ActiveProfileId);
    }

    [Fact]
    public async Task Encrypted_restore_rolls_back_credentials_when_configuration_commit_races()
    {
        var source = await SeedAsync("from-backup");
        var target = CredentialTargets.UpstreamApiKey("work", "primary");
        credentials.Values[target] = "backup-secret";
        var output = Path.Combine(root, "encrypted.json");
        var backup = await coordinator.CreateAsync(new BackupCreateRequest(
            output,
            true,
            "correct horse battery staple"));
        credentials.Values[target] = "current-secret";
        var raceTriggered = false;
        credentials.AfterSet = async () =>
        {
            if (raceTriggered)
            {
                return;
            }
            raceTriggered = true;
            var current = await store.LoadAsync();
            await store.SaveAsync(current with { ActiveProfileId = null }, current.Revision);
        };

        await Assert.ThrowsAsync<ConfigurationConcurrencyException>(() =>
            coordinator.RestoreAsync(new BackupRestoreRequest(
                output,
                backup.Sha256,
                source.Revision,
                true,
                "correct horse battery staple")));

        Assert.Equal("current-secret", credentials.Values[target]);
        Assert.Null((await store.LoadAsync()).ActiveProfileId);
    }

    [Fact]
    public async Task Encrypted_restore_updates_listed_provider_and_retains_runtime_credential()
    {
        var source = await SeedAsync("from-backup");
        var providerTarget = CredentialTargets.UpstreamApiKey("work", "primary");
        credentials.Values[providerTarget] = "backup-secret";
        var output = Path.Combine(root, "encrypted-success.json");
        var backup = await coordinator.CreateAsync(new BackupCreateRequest(
            output,
            true,
            "correct horse battery staple"));
        credentials.Values[providerTarget] = "current-secret";
        credentials.Values[CredentialTargets.RuntimeClientToken] = "runtime-token-must-remain";

        var result = await coordinator.RestoreAsync(new BackupRestoreRequest(
            output,
            backup.Sha256,
            source.Revision,
            true,
            "correct horse battery staple"));

        Assert.Equal(1, result.SecretsRestored);
        Assert.Equal("backup-secret", credentials.Values[providerTarget]);
        Assert.Equal("runtime-token-must-remain", credentials.Values[CredentialTargets.RuntimeClientToken]);
    }

    [Fact]
    public async Task Duplicate_or_unknown_backup_properties_are_rejected()
    {
        var output = Path.Combine(root, "invalid.json");
        await File.WriteAllTextAsync(output, "{\"schemaVersion\":1,\"schemaVersion\":1,\"kind\":\"configuration\"}");

        var exception = await Assert.ThrowsAsync<BackupException>(() =>
            coordinator.InspectAsync(new BackupInspectRequest(output, null)));

        Assert.Equal("aigw_backup_format_invalid", exception.ErrorCode);
    }

    public void Dispose()
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }

    private async Task<GatewayConfiguration> SeedAsync(string upstreamModel)
    {
        var configuration = new GatewayConfiguration
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
                            UpstreamModel = upstreamModel,
                            IsDefault = true,
                        },
                    ],
                },
            ],
        };
        return await store.SaveAsync(configuration, 0);
    }

    private sealed class FakeCryptography : IBackupCryptography
    {
        public int EncryptCalls { get; private set; }
        public byte[]? LastPlaintext { get; private set; }

        public Task<byte[]> EncryptAsync(ReadOnlyMemory<byte> plaintext, string passphrase, CancellationToken cancellationToken = default)
        {
            EncryptCalls++;
            LastPlaintext = plaintext.ToArray();
            return Task.FromResult(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new
            {
                schemaVersion = 1,
                kind = "encrypted",
                payload = Convert.ToBase64String(plaintext.Span),
            })));
        }

        public Task<byte[]> DecryptAsync(ReadOnlyMemory<byte> envelope, string passphrase, CancellationToken cancellationToken = default)
        {
            using var document = JsonDocument.Parse(envelope);
            return Task.FromResult(Convert.FromBase64String(
                document.RootElement.GetProperty("payload").GetString()!));
        }
    }

    private sealed class MemoryCredentialStore : ICredentialStore
    {
        public Dictionary<string, string> Values { get; } = new(StringComparer.Ordinal);
        public Func<Task>? AfterSet { get; set; }

        public async ValueTask SetSecretAsync(string target, string secret, CancellationToken cancellationToken = default)
        {
            Values[target] = secret;
            if (AfterSet is not null)
            {
                await AfterSet();
            }
        }

        public ValueTask<string?> GetSecretAsync(string target, CancellationToken cancellationToken = default) =>
            ValueTask.FromResult(Values.GetValueOrDefault(target));

        public ValueTask DeleteSecretAsync(string target, CancellationToken cancellationToken = default)
        {
            Values.Remove(target);
            return ValueTask.CompletedTask;
        }
    }

    private sealed class FixedTimeProvider(DateTimeOffset now) : TimeProvider
    {
        public override DateTimeOffset GetUtcNow() => now;
    }

    private sealed class FailingFileProtection : IConfigurationFileSecurity
    {
        public void ProtectDirectory(string path) => throw new NotSupportedException();
        public void ProtectFile(string path) => throw new UnauthorizedAccessException("fixture");
    }
}
