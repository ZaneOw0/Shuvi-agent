using System.ComponentModel;
using System.Diagnostics;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;
using LocalAIGateway.Core.Update;

namespace LocalAIGateway.Windows.Update;

public sealed class PrivatePythonEd25519Verifier : IEd25519Verifier
{
    private readonly string pythonPath;
    private readonly string scriptPath;
    private readonly IUpdateVerificationProcessRunner runner;

    public PrivatePythonEd25519Verifier(string applicationRoot)
        : this(
            Path.Combine(NormalizeRoot(applicationRoot), "runtime", "python", "python.exe"),
            Path.Combine(NormalizeRoot(applicationRoot), "runtime-tools", "aigw_update_verify.py"),
            new UpdateVerificationProcessRunner(TimeSpan.FromSeconds(10)))
    {
    }

    internal PrivatePythonEd25519Verifier(
        string pythonPath,
        string scriptPath,
        IUpdateVerificationProcessRunner runner)
    {
        this.pythonPath = NormalizeFile(pythonPath);
        this.scriptPath = NormalizeFile(scriptPath);
        this.runner = runner;
    }

    public async Task<bool> VerifyAsync(
        ReadOnlyMemory<byte> publicKey,
        ReadOnlyMemory<byte> message,
        ReadOnlyMemory<byte> signature,
        CancellationToken cancellationToken = default)
    {
        if (publicKey.Length != 32 || signature.Length != 64 || message.Length > 8 * 1024 * 1024)
        {
            throw new UpdateException("aigw_update_signature_input_invalid", "Ed25519 verification input is invalid.");
        }
        if (!File.Exists(pythonPath) || !File.Exists(scriptPath) ||
            IsReparse(pythonPath) || IsReparse(scriptPath))
        {
            throw new UpdateException("aigw_update_verifier_missing", "The installed update verifier is missing or unsafe.");
        }

        var request = JsonSerializer.SerializeToUtf8Bytes(new
        {
            schemaVersion = 1,
            publicKey = Convert.ToBase64String(publicKey.Span),
            message = Convert.ToBase64String(message.Span),
            signature = Convert.ToBase64String(signature.Span),
        });
        try
        {
            var result = await runner.RunAsync(pythonPath, scriptPath, request, cancellationToken);
            if (result.ExitCode is not (0 or 21))
            {
                throw new UpdateException("aigw_update_verifier_failed", "The private Ed25519 verifier rejected the request.");
            }
            try
            {
                var response = JsonSerializer.Deserialize<VerificationResponse>(result.StandardOutput, JsonOptions)
                    ?? throw InvalidResult();
                if (response.SchemaVersion != 1 || response.Valid != (result.ExitCode == 0))
                {
                    throw InvalidResult();
                }
                return response.Valid;
            }
            catch (JsonException exception)
            {
                throw new UpdateException("aigw_update_verifier_result_invalid", "The private Ed25519 verifier returned malformed data.", exception);
            }
        }
        finally
        {
            CryptographicOperations.ZeroMemory(request);
        }
    }

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
    };

    private static string NormalizeRoot(string path) =>
        NormalizeFile(path).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);

    private static string NormalizeFile(string path)
    {
        if (string.IsNullOrWhiteSpace(path) || !Path.IsPathFullyQualified(path))
            throw new ArgumentException("Update verifier paths must be fully qualified.", nameof(path));
        return Path.GetFullPath(path);
    }

    private static bool IsReparse(string path) =>
        (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0;

    private static UpdateException InvalidResult() => new(
        "aigw_update_verifier_result_invalid",
        "The private Ed25519 verifier returned malformed data.");

    private sealed record VerificationResponse
    {
        public int SchemaVersion { get; init; }
        public bool Valid { get; init; }
    }
}

internal sealed record UpdateVerificationProcessResult(int ExitCode, string StandardOutput);

internal interface IUpdateVerificationProcessRunner
{
    Task<UpdateVerificationProcessResult> RunAsync(
        string pythonPath,
        string scriptPath,
        byte[] request,
        CancellationToken cancellationToken);
}

internal sealed class UpdateVerificationProcessRunner(TimeSpan timeout) : IUpdateVerificationProcessRunner
{
    public async Task<UpdateVerificationProcessResult> RunAsync(
        string pythonPath,
        string scriptPath,
        byte[] request,
        CancellationToken cancellationToken)
    {
        var start = new ProcessStartInfo
        {
            FileName = pythonPath,
            WorkingDirectory = Path.GetDirectoryName(scriptPath)!,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        start.ArgumentList.Add("-B");
        start.ArgumentList.Add("-I");
        start.ArgumentList.Add(scriptPath);
        start.Environment.Clear();
        var systemRoot = Environment.GetEnvironmentVariable("SystemRoot");
        if (!string.IsNullOrEmpty(systemRoot)) start.Environment["SystemRoot"] = systemRoot;
        start.Environment["PYTHONNOUSERSITE"] = "1";
        start.Environment["PYTHONDONTWRITEBYTECODE"] = "1";
        start.Environment["PYTHONUTF8"] = "1";

        try
        {
            using var process = Process.Start(start) ?? throw StartFailed();
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
                throw new UpdateException("aigw_update_verifier_timeout", "The private Ed25519 verifier exceeded its time limit.");
            }
            catch (OperationCanceledException)
            {
                Kill(process);
                throw;
            }
            var output = (await outputTask).Trim();
            await errorTask;
            if (output.Length > 1024)
            {
                throw new UpdateException(
                    "aigw_update_verifier_result_invalid",
                    "The private Ed25519 verifier returned too much data.");
            }
            return new(process.ExitCode, output);
        }
        catch (UpdateException) { throw; }
        catch (Win32Exception exception) { throw StartFailed(exception); }
        catch (IOException exception)
        {
            throw new UpdateException("aigw_update_verifier_failed", "The private Ed25519 verifier could not be completed.", exception);
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
        catch (InvalidOperationException) { }
    }

    private static UpdateException StartFailed(Exception? inner = null) => new(
        "aigw_update_verifier_start_failed",
        "Windows could not start the private Ed25519 verifier.",
        inner);
}
