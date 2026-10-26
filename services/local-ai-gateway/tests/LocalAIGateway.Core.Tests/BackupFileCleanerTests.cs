using System.Text;
using LocalAIGateway.Core.Backup;
using LocalAIGateway.Core.Configuration;

namespace LocalAIGateway.Core.Tests;

public sealed class BackupFileCleanerTests : IDisposable
{
    private readonly string root = Path.Combine(
        Path.GetTempPath(),
        $"LocalAIGateway-BackupCleanup-{Guid.NewGuid():N}");

    [Fact]
    public async Task Strict_plain_and_encrypted_backups_are_deleted_without_passphrases()
    {
        Directory.CreateDirectory(root);
        var plain = Path.Combine(root, "plain.json");
        var encrypted = Path.Combine(root, "encrypted.json");
        File.WriteAllBytes(plain, BackupJson.Serialize(new BackupPayloadDocument
        {
            SchemaVersion = 1,
            Kind = BackupJson.ConfigurationKind,
            CreatedUtc = DateTimeOffset.Parse("2026-09-01T00:00:00Z"),
            Configuration = GatewayConfiguration.Empty,
        }));
        File.WriteAllBytes(encrypted, Encoding.UTF8.GetBytes(EncryptedEnvelope()));

        var result = await new BackupFileCleaner().DeleteAsync([plain, encrypted]);

        Assert.Equal(2, result.DeletedFiles.Count);
        Assert.Contains(result.DeletedFiles, file => !file.Encrypted && file.Path == plain);
        Assert.Contains(result.DeletedFiles, file => file.Encrypted && file.Path == encrypted);
        Assert.False(File.Exists(plain));
        Assert.False(File.Exists(encrypted));
    }

    [Fact]
    public async Task Malformed_or_nonbackup_file_is_preserved()
    {
        Directory.CreateDirectory(root);
        var path = Path.Combine(root, "notes.json");
        File.WriteAllText(path, "{\"kind\":\"encrypted\",\"extra\":true}");

        var failure = await Assert.ThrowsAsync<BackupException>(() =>
            new BackupFileCleaner().DeleteAsync([path]));

        Assert.Equal("aigw_backup_format_invalid", failure.ErrorCode);
        Assert.True(File.Exists(path));
    }

    [Fact]
    public async Task Duplicate_paths_fail_before_deletion()
    {
        Directory.CreateDirectory(root);
        var path = Path.Combine(root, "plain.json");
        File.WriteAllBytes(path, BackupJson.Serialize(new BackupPayloadDocument
        {
            SchemaVersion = 1,
            Kind = BackupJson.ConfigurationKind,
            CreatedUtc = DateTimeOffset.Parse("2026-09-01T00:00:00Z"),
            Configuration = GatewayConfiguration.Empty,
        }));

        var failure = await Assert.ThrowsAsync<BackupException>(() =>
            new BackupFileCleaner().DeleteAsync([path, path.ToUpperInvariant()]));

        Assert.Equal("aigw_backup_path_duplicate", failure.ErrorCode);
        Assert.True(File.Exists(path));
    }

    [Fact]
    public async Task Empty_explicit_list_is_an_idempotent_noop()
    {
        var result = await new BackupFileCleaner().DeleteAsync([]);

        Assert.True(result.AlreadyAbsent);
        Assert.Empty(result.DeletedFiles);
    }

    private static string EncryptedEnvelope() =>
        """
        {"schemaVersion":1,"kind":"encrypted","kdf":{"algorithm":"argon2id","salt":"AAAAAAAAAAAAAAAAAAAAAA==","length":32,"iterations":3,"lanes":4,"memoryKiB":65536},"cipher":{"algorithm":"aes-256-gcm","nonce":"AAAAAAAAAAAAAAAA","ciphertext":"AAAAAAAAAAAAAAAAAAAAAA=="}}
        """;

    public void Dispose()
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }
}
