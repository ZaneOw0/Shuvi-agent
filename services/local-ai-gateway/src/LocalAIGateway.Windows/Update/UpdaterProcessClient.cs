using System.ComponentModel;
using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Serialization;
using LocalAIGateway.Core.Installation;
using LocalAIGateway.Core.Update;

namespace LocalAIGateway.Windows.Update;

public sealed class UpdaterProcessClient : IPackageUpdateService
{
    private const int MaximumOutputCharacters = 1024 * 1024;
    private readonly CurrentUserInstallationTarget target;
    private readonly string commandBaseDirectory;
    private readonly string updaterPath;

    public UpdaterProcessClient(CurrentUserInstallationTarget target, string commandBaseDirectory)
    {
        this.target = target ?? throw new ArgumentNullException(nameof(target));
        this.commandBaseDirectory = Path.GetFullPath(commandBaseDirectory).TrimEnd(
            Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        updaterPath = Path.Combine(target.InstallRoot, "updater", "aigw-updater.exe");
    }

    public async Task<PackageUpdateInspection> InspectAsync(
        string packageRoot,
        bool allowUnsignedDevelopment,
        CancellationToken cancellationToken = default)
    {
        var arguments = CommonArguments("inspect", packageRoot, allowUnsignedDevelopment);
        var result = await RunAsync(arguments, mayTerminateBeforeMutation: true, cancellationToken);
        var response = ParseSuccess<InspectResponse>(result, "inspect");
        return new PackageUpdateInspection(
            response.PackageRoot!, response.Version!, response.ManifestSha256!,
            ParseTrust(response.TrustKind), response.KeyId, response.FileCount);
    }

    public async Task<PackageUpdateResult> ApplyAsync(
        PackageUpdateRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (!request.Confirmed)
            throw new UpdateException("aigw_update_confirmation_required", "Type UPDATE exactly before the candidate package is read.");
        var arguments = CommonArguments("apply", request.PackageRoot, request.AllowUnsignedDevelopment);
        arguments.Add("--expected-manifest-sha256");
        arguments.Add(request.ExpectedManifestSha256);
        arguments.Add("--confirm");
        arguments.Add("UPDATE");
        arguments.Add("--parent-pid");
        arguments.Add(Environment.ProcessId.ToString(System.Globalization.CultureInfo.InvariantCulture));
        var result = await RunAsync(arguments, mayTerminateBeforeMutation: false, cancellationToken);
        var response = ParseSuccess<ApplyResponse>(result, "apply");
        if (!response.CompletionPending || string.IsNullOrWhiteSpace(response.OperationId) ||
            string.IsNullOrWhiteSpace(response.ReceiptPath))
            throw InvalidResult();
        return new PackageUpdateResult(
            response.PreviousVersion!, response.CurrentVersion!, response.ManifestSha256!,
            ParseTrust(response.TrustKind), response.KeyId,
            false, false, false, null, true, response.OperationId, response.ReceiptPath);
    }

    private List<string> CommonArguments(string command, string packageRoot, bool allowUnsigned)
    {
        ValidateEntrypoint();
        var arguments = new List<string>
        {
            command,
            "--package", packageRoot,
            "--install-root", target.InstallRoot,
            "--state-root", target.StateRoot,
            "--runtime-executable", target.RuntimeExecutablePath,
        };
        if (allowUnsigned) arguments.Add("--allow-unsigned-development");
        return arguments;
    }

    private void ValidateEntrypoint()
    {
        if (!commandBaseDirectory.Equals(
                Path.GetFullPath(target.InstallRoot).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
                StringComparison.OrdinalIgnoreCase))
        {
            throw new UpdateException(
                "aigw_update_running_outside_install_root",
                "Run update from the currently installed Local AI Gateway CLI.");
        }
        if (!File.Exists(updaterPath) || (File.GetAttributes(updaterPath) & FileAttributes.ReparsePoint) != 0)
        {
            throw new UpdateException("aigw_update_updater_missing", "The installed updater executable is missing or unsafe.");
        }
    }

    private async Task<ProcessResult> RunAsync(
        IReadOnlyList<string> arguments,
        bool mayTerminateBeforeMutation,
        CancellationToken cancellationToken)
    {
        var start = new ProcessStartInfo
        {
            FileName = updaterPath,
            // Windows refuses to rename a directory that is a process working directory.
            // Keep the trusted executable path fixed in the installed tree, but run it
            // from an existing directory outside both the program and state roots.
            WorkingDirectory = Path.GetTempPath(),
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        start.Environment.Clear();
        var systemRoot = Environment.GetEnvironmentVariable("SystemRoot");
        if (!string.IsNullOrEmpty(systemRoot)) start.Environment["SystemRoot"] = systemRoot;
        start.Environment["DOTNET_MULTILEVEL_LOOKUP"] = "0";

        try
        {
            using var process = Process.Start(start) ?? throw StartFailed();
            var outputTask = process.StandardOutput.ReadToEndAsync(CancellationToken.None);
            var errorTask = process.StandardError.ReadToEndAsync(CancellationToken.None);
            using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(10));
            using var linked = mayTerminateBeforeMutation
                ? CancellationTokenSource.CreateLinkedTokenSource(timeout.Token, cancellationToken)
                : CancellationTokenSource.CreateLinkedTokenSource(timeout.Token);
            try
            {
                await process.WaitForExitAsync(linked.Token);
            }
            catch (OperationCanceledException) when (mayTerminateBeforeMutation)
            {
                Kill(process);
                cancellationToken.ThrowIfCancellationRequested();
                throw new UpdateException("aigw_update_updater_timeout", "The installed updater exceeded its time limit.");
            }
            catch (OperationCanceledException)
            {
                throw new UpdateException(
                    "aigw_update_completion_unknown",
                    "The updater is still running; do not start another installation operation until it completes.");
            }
            var output = await outputTask;
            var error = await errorTask;
            if (output.Length + error.Length > MaximumOutputCharacters) throw InvalidResult();
            if (process.ExitCode != 0)
            {
                var failure = ParseError(error);
                throw new UpdateException(failure.Code ?? "aigw_update_failed", failure.Message ?? "The installed updater failed.");
            }
            return new ProcessResult(output.Trim(), error.Trim());
        }
        catch (UpdateException) { throw; }
        catch (Win32Exception exception) { throw StartFailed(exception); }
        catch (IOException exception)
        {
            throw new UpdateException("aigw_update_process_failed", "The installed updater process could not be completed.", exception);
        }
    }

    private static T ParseSuccess<T>(ProcessResult result, string operation) where T : UpdateResponse
    {
        try
        {
            if (!string.IsNullOrEmpty(result.StandardError)) throw InvalidResult();
            var response = JsonSerializer.Deserialize<T>(result.StandardOutput, JsonOptions) ?? throw InvalidResult();
            if (response.SchemaVersion != 1 || response.Operation != operation ||
                !PackageSignatureJson.IsHash(response.ManifestSha256)) throw InvalidResult();
            return response;
        }
        catch (JsonException exception)
        {
            throw new UpdateException("aigw_update_process_result_invalid", "The installed updater returned malformed data.", exception);
        }
    }

    private static ErrorResponse ParseError(string error)
    {
        try
        {
            var envelope = JsonSerializer.Deserialize<ErrorEnvelope>(error, JsonOptions);
            return envelope is { SchemaVersion: 1, Error.Code.Length: > 0, Error.Message.Length: > 0 }
                ? envelope.Error
                : new ErrorResponse(null, null);
        }
        catch (JsonException) { return new ErrorResponse(null, null); }
    }

    private static PackageTrustKind ParseTrust(string? value) => value switch
    {
        "signed" => PackageTrustKind.Signed,
        "unsigned-development" => PackageTrustKind.UnsignedDevelopment,
        _ => throw InvalidResult(),
    };

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
    };

    private static void Kill(Process process)
    {
        try
        {
            if (!process.HasExited) { process.Kill(entireProcessTree: true); process.WaitForExit(); }
        }
        catch (InvalidOperationException) { }
    }

    private static UpdateException InvalidResult() => new(
        "aigw_update_process_result_invalid", "The installed updater returned malformed data.");
    private static UpdateException StartFailed(Exception? inner = null) => new(
        "aigw_update_process_start_failed", "Windows could not start the installed updater.", inner);

    private sealed record ProcessResult(string StandardOutput, string StandardError);
    private abstract record UpdateResponse
    {
        public int SchemaVersion { get; init; }
        public string? Operation { get; init; }
        public string? ManifestSha256 { get; init; }
    }
    private sealed record InspectResponse : UpdateResponse
    {
        public string? PackageRoot { get; init; }
        public string? Version { get; init; }
        public string? TrustKind { get; init; }
        public string? KeyId { get; init; }
        public int FileCount { get; init; }
    }
    private sealed record ApplyResponse : UpdateResponse
    {
        public string? PreviousVersion { get; init; }
        public string? CurrentVersion { get; init; }
        public string? TrustKind { get; init; }
        public string? KeyId { get; init; }
        public bool CompletionPending { get; init; }
        public string? OperationId { get; init; }
        public string? ReceiptPath { get; init; }
    }
    private sealed record ErrorEnvelope(int SchemaVersion, ErrorResponse Error);
    private sealed record ErrorResponse(string? Code, string? Message);
}
