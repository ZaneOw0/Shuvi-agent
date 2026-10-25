using System.ComponentModel;
using System.Diagnostics;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;
using LocalAIGateway.Core.Backup;

namespace LocalAIGateway.Windows.Backup;

public sealed class PrivatePythonBackupCryptography : IBackupCryptography
{
    private const int MaximumOutputCharacters = 8 * 1024 * 1024;
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
    };
    private readonly string pythonPath;
    private readonly string scriptPath;
    private readonly IBackupCryptoProcessRunner runner;

    public PrivatePythonBackupCryptography(string applicationRoot)
        : this(
            Path.Combine(NormalizeRoot(applicationRoot), "runtime", "python", "python.exe"),
            Path.Combine(NormalizeRoot(applicationRoot), "runtime-tools", "aigw_backup_crypto.py"),
            new BackupCryptoProcessRunner(TimeSpan.FromSeconds(30)))
    {
    }

    internal PrivatePythonBackupCryptography(
        string pythonPath,
        string scriptPath,
        IBackupCryptoProcessRunner runner)
    {
        this.pythonPath = NormalizeFile(pythonPath);
        this.scriptPath = NormalizeFile(scriptPath);
        this.runner = runner ?? throw new ArgumentNullException(nameof(runner));
    }

    public async Task<byte[]> EncryptAsync(
        ReadOnlyMemory<byte> plaintext,
        string passphrase,
        CancellationToken cancellationToken = default)
    {
        ValidateFiles();
        var request = JsonSerializer.SerializeToUtf8Bytes(new
        {
            schemaVersion = 1,
            operation = "encrypt",
            passphrase,
            plaintext = Convert.ToBase64String(plaintext.Span),
        });
        try
        {
            var result = await runner.RunAsync(pythonPath, scriptPath, request, cancellationToken);
            ThrowForFailure(result);
            if (result.StandardOutput.Length == 0 || result.StandardOutput.Length > MaximumOutputCharacters)
            {
                throw InvalidResult();
            }
            return System.Text.Encoding.UTF8.GetBytes(result.StandardOutput);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(request);
        }
    }

    public async Task<byte[]> DecryptAsync(
        ReadOnlyMemory<byte> envelope,
        string passphrase,
        CancellationToken cancellationToken = default)
    {
        ValidateFiles();
        JsonElement envelopeElement;
        try
        {
            using var parsed = JsonDocument.Parse(envelope);
            envelopeElement = parsed.RootElement.Clone();
        }
        catch (JsonException exception)
        {
            throw new BackupException("aigw_backup_format_invalid", "The encrypted backup envelope is malformed.", exception);
        }
        var request = JsonSerializer.SerializeToUtf8Bytes(new
        {
            schemaVersion = 1,
            operation = "decrypt",
            passphrase,
            envelope = envelopeElement,
        });
        try
        {
            var result = await runner.RunAsync(pythonPath, scriptPath, request, cancellationToken);
            ThrowForFailure(result);
            if (result.StandardOutput.Length == 0 || result.StandardOutput.Length > MaximumOutputCharacters)
            {
                throw InvalidResult();
            }
            var response = JsonSerializer.Deserialize<DecryptResponse>(result.StandardOutput, JsonOptions)
                ?? throw InvalidResult();
            if (response.SchemaVersion != 1 || string.IsNullOrEmpty(response.Plaintext))
            {
                throw InvalidResult();
            }
            try
            {
                var plaintext = Convert.FromBase64String(response.Plaintext);
                if (plaintext.Length == 0 || plaintext.Length > 4 * 1024 * 1024)
                {
                    throw InvalidResult();
                }
                return plaintext;
            }
            catch (FormatException exception)
            {
                throw new BackupException("aigw_backup_crypto_result_invalid", "The private backup process returned malformed data.", exception);
            }
        }
        catch (JsonException exception)
        {
            throw new BackupException("aigw_backup_crypto_result_invalid", "The private backup process returned malformed data.", exception);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(request);
        }
    }

    private void ValidateFiles()
    {
        if (!File.Exists(pythonPath) || !File.Exists(scriptPath) ||
            (File.GetAttributes(pythonPath) & FileAttributes.ReparsePoint) != 0 ||
            (File.GetAttributes(scriptPath) & FileAttributes.ReparsePoint) != 0)
        {
            throw new BackupException(
                "aigw_backup_crypto_missing",
                "A required private backup cryptography component is missing or unsafe.");
        }
    }

    private static void ThrowForFailure(BackupCryptoProcessResult result)
    {
        if (result.ExitCode == 0)
        {
            return;
        }
        throw result.ExitCode == 21
            ? new BackupException("aigw_backup_authentication_failed", "The backup passphrase is incorrect or the encrypted backup was modified.")
            : new BackupException("aigw_backup_crypto_failed", "The private backup cryptography process rejected the request.");
    }

    private static string NormalizeRoot(string path)
    {
        var normalized = NormalizeFile(path).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        if (string.Equals(
            normalized,
            Path.GetPathRoot(normalized)?.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
            StringComparison.OrdinalIgnoreCase))
        {
            throw new ArgumentException("The application root must not be a volume root.", nameof(path));
        }
        return normalized;
    }

    private static string NormalizeFile(string path)
    {
        if (string.IsNullOrWhiteSpace(path) || !Path.IsPathFullyQualified(path))
        {
            throw new ArgumentException("The private backup component path must be fully qualified.", nameof(path));
        }
        return Path.GetFullPath(path);
    }

    private static BackupException InvalidResult() => new(
        "aigw_backup_crypto_result_invalid",
        "The private backup process returned malformed data.");

    private sealed record DecryptResponse
    {
        public int SchemaVersion { get; init; }
        public string? Plaintext { get; init; }
    }
}

internal sealed record BackupCryptoProcessResult(int ExitCode, string StandardOutput);

internal interface IBackupCryptoProcessRunner
{
    Task<BackupCryptoProcessResult> RunAsync(
        string pythonPath,
        string scriptPath,
        byte[] request,
        CancellationToken cancellationToken);
}

internal sealed class BackupCryptoProcessRunner(TimeSpan timeout) : IBackupCryptoProcessRunner
{
    public async Task<BackupCryptoProcessResult> RunAsync(
        string pythonPath,
        string scriptPath,
        byte[] request,
        CancellationToken cancellationToken)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = pythonPath,
            WorkingDirectory = Path.GetDirectoryName(scriptPath)!,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        startInfo.ArgumentList.Add("-B");
        startInfo.ArgumentList.Add("-I");
        startInfo.ArgumentList.Add(scriptPath);
        startInfo.Environment.Clear();
        var systemRoot = Environment.GetEnvironmentVariable("SystemRoot");
        if (!string.IsNullOrEmpty(systemRoot))
        {
            startInfo.Environment["SystemRoot"] = systemRoot;
        }
        startInfo.Environment["PYTHONNOUSERSITE"] = "1";
        startInfo.Environment["PYTHONDONTWRITEBYTECODE"] = "1";
        startInfo.Environment["PYTHONUTF8"] = "1";

        try
        {
            using var process = Process.Start(startInfo) ?? throw StartFailed();
            var outputTask = process.StandardOutput.ReadToEndAsync(CancellationToken.None);
            var errorTask = process.StandardError.ReadToEndAsync(CancellationToken.None);
            using var timeoutSource = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeoutSource.CancelAfter(timeout);
            try
            {
                await process.StandardInput.BaseStream.WriteAsync(request, timeoutSource.Token);
                await process.StandardInput.BaseStream.FlushAsync(timeoutSource.Token);
                process.StandardInput.Close();
                await process.WaitForExitAsync(timeoutSource.Token);
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            {
                Kill(process);
                throw new BackupException("aigw_backup_crypto_timeout", "The private backup cryptography process exceeded its time limit.");
            }
            catch (OperationCanceledException)
            {
                Kill(process);
                throw;
            }
            var output = await outputTask;
            await errorTask;
            return new BackupCryptoProcessResult(process.ExitCode, output.Trim());
        }
        catch (BackupException)
        {
            throw;
        }
        catch (Win32Exception exception)
        {
            throw StartFailed(exception);
        }
        catch (IOException exception)
        {
            throw new BackupException("aigw_backup_crypto_failed", "The private backup cryptography process could not be completed.", exception);
        }
    }

    private static void Kill(Process process)
    {
        try
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
                process.WaitForExit();
            }
        }
        catch (InvalidOperationException)
        {
            // The process exited between the state check and tree termination.
        }
    }

    private static BackupException StartFailed(Exception? inner = null) => new(
        "aigw_backup_crypto_start_failed",
        "Windows could not start the private backup cryptography process.",
        inner);
}
