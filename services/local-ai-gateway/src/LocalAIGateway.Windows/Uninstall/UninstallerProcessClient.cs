using System.ComponentModel;
using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Serialization;
using LocalAIGateway.Core.Installation;
using LocalAIGateway.Core.Uninstall;

namespace LocalAIGateway.Windows.Uninstall;

public sealed class UninstallerProcessClient : IUninstallService
{
    private const int MaximumOutputCharacters = 1024 * 1024;
    private readonly CurrentUserInstallationTarget target;
    private readonly string commandBaseDirectory;
    private readonly string updaterPath;

    public UninstallerProcessClient(
        CurrentUserInstallationTarget target,
        string commandBaseDirectory)
    {
        this.target = target ?? throw new ArgumentNullException(nameof(target));
        this.commandBaseDirectory = Normalize(commandBaseDirectory);
        updaterPath = Path.Combine(target.InstallRoot, "updater", "aigw-updater.exe");
    }

    public async Task<UninstallResult> UninstallAsync(
        UninstallRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        ValidateEntrypoint();
        if (!request.Confirmed)
        {
            throw new UninstallException(
                "aigw_uninstall_confirmation_required",
                "Complete uninstall requires explicit category confirmation.");
        }

        var arguments = new List<string>
        {
            "uninstall",
            "--install-root", target.InstallRoot,
            "--state-root", target.StateRoot,
            "--runtime-executable", target.RuntimeExecutablePath,
            "--parent-pid", Environment.ProcessId.ToString(System.Globalization.CultureInfo.InvariantCulture),
            "--confirm", "UNINSTALL",
        };
        AddChoice(arguments, "--program", request.Selection.Program);
        AddChoice(arguments, "--autostart", request.Selection.Autostart);
        AddChoice(arguments, "--integrations", request.Selection.Integrations);
        AddChoice(arguments, "--runtime-credential", request.Selection.RuntimeCredential);
        AddChoice(arguments, "--provider-credentials", request.Selection.ProviderCredentials);
        AddChoice(arguments, "--configuration", request.Selection.Configuration);
        AddChoice(arguments, "--usage", request.Selection.Usage);
        AddChoice(arguments, "--logs", request.Selection.Logs);
        AddChoice(arguments, "--backups", request.Selection.Backups);
        foreach (var integration in request.IntegrationTargets)
        {
            arguments.Add(integration.Client switch
            {
                "claude-vscode" => "--claude-vscode-target",
                "codex-cli" => "--codex-cli-target",
                _ => throw new UninstallException(
                    "aigw_uninstall_integration_target_invalid",
                    "An uninstall integration client is unknown."),
            });
            arguments.Add(integration.TargetPath);
        }
        foreach (var backup in request.BackupPaths)
        {
            arguments.Add("--backup-path");
            arguments.Add(backup);
        }

        var response = await RunAsync(arguments, cancellationToken);
        return new UninstallResult(
            Pending(request.Selection.Program),
            Pending(request.Selection.Autostart),
            Pending(request.Selection.Integrations),
            Pending(request.Selection.RuntimeCredential),
            Pending(request.Selection.ProviderCredentials),
            Pending(request.Selection.Configuration),
            Pending(request.Selection.Usage),
            Pending(request.Selection.Logs),
            Pending(request.Selection.Backups),
            CompletionPending: true,
            response.OperationId,
            response.ReceiptPath);
    }

    private async Task<ScheduledResponse> RunAsync(
        IReadOnlyList<string> arguments,
        CancellationToken cancellationToken)
    {
        var start = new ProcessStartInfo
        {
            FileName = updaterPath,
            WorkingDirectory = Path.GetTempPath(),
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        foreach (var argument in arguments)
        {
            start.ArgumentList.Add(argument);
        }
        start.Environment.Clear();
        var systemRoot = Environment.GetEnvironmentVariable("SystemRoot");
        if (!string.IsNullOrEmpty(systemRoot))
        {
            start.Environment["SystemRoot"] = systemRoot;
        }
        start.Environment["DOTNET_MULTILEVEL_LOOKUP"] = "0";

        try
        {
            using var process = Process.Start(start) ?? throw StartFailed();
            var outputTask = process.StandardOutput.ReadToEndAsync(CancellationToken.None);
            var errorTask = process.StandardError.ReadToEndAsync(CancellationToken.None);
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));
            using var linked = CancellationTokenSource.CreateLinkedTokenSource(
                timeout.Token,
                cancellationToken);
            try
            {
                await process.WaitForExitAsync(linked.Token);
            }
            catch (OperationCanceledException)
            {
                Kill(process);
                cancellationToken.ThrowIfCancellationRequested();
                throw new UninstallException(
                    "aigw_uninstall_helper_timeout",
                    "The installed uninstall helper exceeded its scheduling time limit.");
            }

            var output = await outputTask;
            var error = await errorTask;
            if (output.Length + error.Length > MaximumOutputCharacters)
            {
                throw InvalidResult();
            }
            if (process.ExitCode != 0)
            {
                var failure = ParseError(error);
                throw new UninstallException(
                    failure.Code ?? "aigw_uninstall_helper_failed",
                    failure.Message ?? "The installed uninstall helper failed.");
            }
            if (!string.IsNullOrWhiteSpace(error))
            {
                throw InvalidResult();
            }

            var response = JsonSerializer.Deserialize<ScheduledResponse>(output, JsonOptions)
                ?? throw InvalidResult();
            if (response.SchemaVersion != 1 || response.Operation != "uninstall" ||
                !response.CompletionPending ||
                !Guid.TryParseExact(response.OperationId, "N", out _) ||
                string.IsNullOrWhiteSpace(response.ReceiptPath) ||
                !Path.IsPathFullyQualified(response.ReceiptPath))
            {
                throw InvalidResult();
            }
            return response;
        }
        catch (UninstallException)
        {
            throw;
        }
        catch (Exception exception) when (exception is Win32Exception or IOException)
        {
            throw StartFailed(exception);
        }
    }

    private void ValidateEntrypoint()
    {
        if (!commandBaseDirectory.Equals(Normalize(target.InstallRoot), StringComparison.OrdinalIgnoreCase))
        {
            throw new UninstallException(
                "aigw_uninstall_helper_not_required",
                "The external uninstall worker is only used by the installed Local AI Gateway CLI.");
        }
        if (!File.Exists(updaterPath) ||
            (File.GetAttributes(updaterPath) & FileAttributes.ReparsePoint) != 0)
        {
            throw new UninstallException(
                "aigw_uninstall_helper_missing",
                "The installed uninstall helper is missing or unsafe.");
        }
    }

    private static void AddChoice(ICollection<string> arguments, string name, UninstallChoice choice)
    {
        arguments.Add(name);
        arguments.Add(choice == UninstallChoice.Remove ? "remove" : "keep");
    }

    private static UninstallCategoryResult Pending(UninstallChoice choice) =>
        new(choice == UninstallChoice.Remove, false, false, []);

    private static string Normalize(string path) => Path.GetFullPath(path).TrimEnd(
        Path.DirectorySeparatorChar,
        Path.AltDirectorySeparatorChar);

    private static ErrorResponse ParseError(string error)
    {
        try
        {
            var response = JsonSerializer.Deserialize<ErrorEnvelope>(error, JsonOptions);
            return response is { SchemaVersion: 1, Error.Code.Length: > 0, Error.Message.Length: > 0 }
                ? response.Error
                : new(null, null);
        }
        catch (JsonException)
        {
            return new(null, null);
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
        }
    }

    private static UninstallException InvalidResult() => new(
        "aigw_uninstall_helper_result_invalid",
        "The installed uninstall helper returned malformed data.");

    private static UninstallException StartFailed(Exception? inner = null) => new(
        "aigw_uninstall_helper_start_failed",
        "Windows could not start the installed uninstall helper.",
        inner);

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
    };

    private sealed record ScheduledResponse
    {
        public int SchemaVersion { get; init; }
        public string? Operation { get; init; }
        public bool CompletionPending { get; init; }
        public string? OperationId { get; init; }
        public string? ReceiptPath { get; init; }
    }

    private sealed record ErrorEnvelope(int SchemaVersion, ErrorResponse Error);
    private sealed record ErrorResponse(string? Code, string? Message);
}
