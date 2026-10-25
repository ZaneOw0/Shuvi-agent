using System.Text;
using System.Text.Json;
using LocalAIGateway.Core.Backup;
using LocalAIGateway.Windows.Backup;

namespace LocalAIGateway.Windows.Tests;

public sealed class PrivatePythonBackupCryptographyTests : IDisposable
{
    private readonly string root = Path.Combine(
        Path.GetTempPath(),
        $"LocalAIGateway-M5c-Crypto-{Guid.NewGuid():N}");
    private readonly string python;
    private readonly string script;

    public PrivatePythonBackupCryptographyTests()
    {
        Directory.CreateDirectory(root);
        python = Path.Combine(root, "python.exe");
        script = Path.Combine(root, "aigw_backup_crypto.py");
        File.WriteAllText(python, "fixture");
        File.WriteAllText(script, "fixture");
    }

    [Fact]
    public async Task Encrypt_passes_sensitive_input_only_through_bounded_stdin_request()
    {
        var runner = new RecordingRunner(new BackupCryptoProcessResult(
            0,
            "{\"schemaVersion\":1,\"kind\":\"encrypted\"}"));
        var crypto = new PrivatePythonBackupCryptography(python, script, runner);

        var result = await crypto.EncryptAsync(
            Encoding.UTF8.GetBytes("payload"),
            "correct horse battery staple");

        Assert.Equal("{\"schemaVersion\":1,\"kind\":\"encrypted\"}", Encoding.UTF8.GetString(result));
        Assert.Equal(python, runner.PythonPath);
        Assert.Equal(script, runner.ScriptPath);
        Assert.NotNull(runner.ObservedRequest);
        using var request = JsonDocument.Parse(runner.ObservedRequest!);
        Assert.Equal("encrypt", request.RootElement.GetProperty("operation").GetString());
        Assert.Equal("correct horse battery staple", request.RootElement.GetProperty("passphrase").GetString());
        Assert.All(runner.OriginalRequest!, value => Assert.Equal(0, value));
    }

    [Fact]
    public async Task Decrypt_validates_and_decodes_private_process_result()
    {
        var encoded = Convert.ToBase64String(Encoding.UTF8.GetBytes("decrypted payload"));
        var runner = new RecordingRunner(new BackupCryptoProcessResult(
            0,
            $"{{\"schemaVersion\":1,\"plaintext\":\"{encoded}\"}}"));
        var crypto = new PrivatePythonBackupCryptography(python, script, runner);

        var plaintext = await crypto.DecryptAsync(
            Encoding.UTF8.GetBytes("{\"schemaVersion\":1,\"kind\":\"encrypted\"}"),
            "correct horse battery staple");

        Assert.Equal("decrypted payload", Encoding.UTF8.GetString(plaintext));
        using var request = JsonDocument.Parse(runner.ObservedRequest!);
        Assert.Equal("decrypt", request.RootElement.GetProperty("operation").GetString());
    }

    [Fact]
    public async Task Authentication_failure_has_stable_error_without_process_output()
    {
        var crypto = new PrivatePythonBackupCryptography(
            python,
            script,
            new RecordingRunner(new BackupCryptoProcessResult(21, "sensitive-process-detail")));

        var exception = await Assert.ThrowsAsync<BackupException>(() => crypto.DecryptAsync(
            Encoding.UTF8.GetBytes("{\"kind\":\"encrypted\"}"),
            "incorrect passphrase"));

        Assert.Equal("aigw_backup_authentication_failed", exception.ErrorCode);
        Assert.DoesNotContain("sensitive-process-detail", exception.Message);
    }

    [Fact]
    public async Task Malformed_private_process_output_is_rejected()
    {
        var crypto = new PrivatePythonBackupCryptography(
            python,
            script,
            new RecordingRunner(new BackupCryptoProcessResult(0, "{\"schemaVersion\":1,\"plaintext\":\"not base64!\"}")));

        var exception = await Assert.ThrowsAsync<BackupException>(() => crypto.DecryptAsync(
            Encoding.UTF8.GetBytes("{\"kind\":\"encrypted\"}"),
            "correct horse battery staple"));

        Assert.Equal("aigw_backup_crypto_result_invalid", exception.ErrorCode);
    }

    [Fact]
    public async Task Configured_private_runtime_round_trips_and_authenticates()
    {
        var configuredPython = Environment.GetEnvironmentVariable("AIGW_M5C_PYTHON_PATH");
        var configuredScript = Environment.GetEnvironmentVariable("AIGW_M5C_CRYPTO_SCRIPT_PATH");
        if (string.IsNullOrWhiteSpace(configuredPython) || string.IsNullOrWhiteSpace(configuredScript))
        {
            return;
        }
        var crypto = new PrivatePythonBackupCryptography(
            configuredPython,
            configuredScript,
            new BackupCryptoProcessRunner(TimeSpan.FromSeconds(30)));
        var plaintext = Encoding.UTF8.GetBytes("M5C product cryptography roundtrip");

        var envelope = await crypto.EncryptAsync(plaintext, "correct horse battery staple");
        var decrypted = await crypto.DecryptAsync(envelope, "correct horse battery staple");
        var failure = await Assert.ThrowsAsync<BackupException>(() => crypto.DecryptAsync(
            envelope,
            "incorrect horse battery staple"));

        Assert.Equal(plaintext, decrypted);
        Assert.DoesNotContain("M5C product cryptography roundtrip", Encoding.UTF8.GetString(envelope));
        Assert.Equal("aigw_backup_authentication_failed", failure.ErrorCode);
    }

    [Fact]
    public async Task Configured_private_runtime_timeout_is_stable_and_bounded()
    {
        var configuredPython = Environment.GetEnvironmentVariable("AIGW_M5C_PYTHON_PATH");
        var sleepScript = Environment.GetEnvironmentVariable("AIGW_M5C_SLEEP_SCRIPT_PATH");
        if (string.IsNullOrWhiteSpace(configuredPython) || string.IsNullOrWhiteSpace(sleepScript))
        {
            return;
        }
        var runner = new BackupCryptoProcessRunner(TimeSpan.FromMilliseconds(100));

        var exception = await Assert.ThrowsAsync<BackupException>(() => runner.RunAsync(
            configuredPython,
            sleepScript,
            Encoding.UTF8.GetBytes("{}"),
            CancellationToken.None));

        Assert.Equal("aigw_backup_crypto_timeout", exception.ErrorCode);
    }

    [Fact]
    public async Task Configured_private_runtime_cancellation_is_propagated_after_cleanup()
    {
        var configuredPython = Environment.GetEnvironmentVariable("AIGW_M5C_PYTHON_PATH");
        var sleepScript = Environment.GetEnvironmentVariable("AIGW_M5C_SLEEP_SCRIPT_PATH");
        if (string.IsNullOrWhiteSpace(configuredPython) || string.IsNullOrWhiteSpace(sleepScript))
        {
            return;
        }
        var runner = new BackupCryptoProcessRunner(TimeSpan.FromSeconds(30));
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => runner.RunAsync(
            configuredPython,
            sleepScript,
            Encoding.UTF8.GetBytes("{}"),
            cancellation.Token));
    }

    public void Dispose()
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }

    private sealed class RecordingRunner(BackupCryptoProcessResult result) : IBackupCryptoProcessRunner
    {
        public string? PythonPath { get; private set; }
        public string? ScriptPath { get; private set; }
        public byte[]? OriginalRequest { get; private set; }
        public byte[]? ObservedRequest { get; private set; }

        public Task<BackupCryptoProcessResult> RunAsync(
            string pythonPath,
            string scriptPath,
            byte[] request,
            CancellationToken cancellationToken)
        {
            PythonPath = pythonPath;
            ScriptPath = scriptPath;
            OriginalRequest = request;
            ObservedRequest = request.ToArray();
            return Task.FromResult(result);
        }
    }
}
