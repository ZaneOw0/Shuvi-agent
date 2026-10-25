using System.Reflection;
using System.Text.Json;
using LocalAIGateway.Core.Backup;
using LocalAIGateway.Core.Configuration;
using LocalAIGateway.Core.Installation;
using LocalAIGateway.Core.Uninstall;
using LocalAIGateway.Core.Update;
using LocalAIGateway.Launcher;
using LocalAIGateway.Launcher.Uninstall;
using LocalAIGateway.Windows;
using LocalAIGateway.Windows.Control;
using LocalAIGateway.Windows.Installation;
using LocalAIGateway.Windows.Runtime;
using LocalAIGateway.Windows.Uninstall;
using LocalAIGateway.Windows.Update;

namespace LocalAIGateway.Updater;

public static class Program
{
    public static Task<int> Main(string[] args) =>
        UpdaterApplication.RunAsync(args, Console.Out, Console.Error);
}

public static class UpdaterApplication
{
    public const int SuccessExitCode = 0;
    public const int InvalidArgumentsExitCode = 2;
    public const int UpdateErrorExitCode = 18;
    public const int UninstallErrorExitCode = 15;
    public const int UnexpectedErrorExitCode = 70;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    };

    public static async Task<int> RunAsync(
        string[] args,
        TextWriter stdout,
        TextWriter stderr,
        Func<CurrentUserInstallationTarget, IPackageUpdateService>? serviceFactory = null,
        Func<CurrentUserInstallationTarget, PackageUpdateRequest, PackageUpdateInspection, int, Task<ScheduledUpdate>>? updateScheduler = null,
        Func<CurrentUserInstallationTarget, UninstallRequest, int, Task<ScheduledUninstall>>? uninstallScheduler = null)
    {
        try
        {
            if (args.Length == 1 && args[0] == "--version")
            {
                await stdout.WriteLineAsync($"Local AI Gateway Updater {GetVersion()}");
                return SuccessExitCode;
            }
            if (args.Length == 0) return await ErrorAsync(stderr, InvalidArgumentsExitCode, "aigw_update_arguments_invalid", "An updater command is required.");
            var command = args[0];
            var parsed = Parse(args[1..]);
            if (command == "cleanup")
            {
                parsed.AssertOnly("--install-root", "--cleanup-path", "--wait-pid");
                var installRoot = Required(parsed, "--install-root");
                var cleanupPath = Required(parsed, "--cleanup-path");
                var waitPids = ParseWaitPids(parsed);
                await WaitForProcessesAsync(waitPids);
                WindowsPackageUpdateService.CleanupDeferredRollback(installRoot, cleanupPath);
                return SuccessExitCode;
            }
            if (command == "cleanup-worker")
            {
                parsed.AssertOnly("--install-root", "--state-root", "--cleanup-path", "--wait-pid");
                var installRoot = Required(parsed, "--install-root");
                ValidateRunningFromInstalledUpdater(installRoot);
                var stateRoot = Required(parsed, "--state-root");
                var cleanupPath = Required(parsed, "--cleanup-path");
                var waitPids = ParseWaitPids(parsed);
                await WaitForProcessesAsync(waitPids);
                CleanupWorkerDirectory(stateRoot, cleanupPath);
                return SuccessExitCode;
            }
            if (command == "worker-apply")
            {
                return await RunWorkerApplyAsync(parsed);
            }
            if (command == "worker-uninstall")
            {
                return await RunWorkerUninstallAsync(parsed);
            }
            if (command == "uninstall")
            {
                var uninstallTarget = Target(parsed);
                ValidateUninstallTargetLayout(uninstallTarget);
                if (uninstallScheduler is null)
                {
                    ValidateRunningFromInstalledUpdater(uninstallTarget.InstallRoot);
                }
                parsed.AssertOnly(
                    "--install-root", "--state-root", "--runtime-executable", "--parent-pid", "--confirm",
                    "--program", "--autostart", "--integrations", "--runtime-credential",
                    "--provider-credentials", "--configuration", "--usage", "--logs", "--backups",
                    "--claude-vscode-target", "--codex-cli-target", "--backup-path");
                var uninstallParentPid = ParsePositiveInt(Required(parsed, "--parent-pid"), "parent PID");
                var uninstallRequest = ParseUninstallRequest(parsed);
                var scheduledUninstall = await (uninstallScheduler ?? ScheduleUninstallWorkerAsync)(
                    uninstallTarget,
                    uninstallRequest,
                    uninstallParentPid);
                await WriteJsonAsync(stdout, new
                {
                    schemaVersion = 1,
                    operation = "uninstall",
                    completionPending = true,
                    scheduledUninstall.OperationId,
                    scheduledUninstall.ReceiptPath,
                });
                return SuccessExitCode;
            }
            if (command is not ("inspect" or "apply"))
                throw InvalidArguments("Unknown updater command.");

            var target = Target(parsed);
            if (serviceFactory is null) ValidateRunningFromInstalledUpdater(target.InstallRoot);
            var service = (serviceFactory ?? CreateDefaultService)(target);
            var package = Required(parsed, "--package");
            var allowUnsigned = parsed.HasFlag("--allow-unsigned-development");
            if (command == "inspect")
            {
                parsed.AssertOnly(
                    "--package", "--install-root", "--state-root", "--runtime-executable",
                    "--allow-unsigned-development");
                var candidateInspection = await service.InspectAsync(package, allowUnsigned);
                await WriteJsonAsync(stdout, new
                {
                    schemaVersion = 1,
                    operation = "inspect",
                    packageRoot = candidateInspection.PackageRoot,
                    version = candidateInspection.Version,
                    manifestSha256 = candidateInspection.ManifestSha256,
                    trustKind = Trust(candidateInspection.TrustKind),
                    candidateInspection.KeyId,
                    candidateInspection.FileCount,
                });
                return SuccessExitCode;
            }

            parsed.AssertOnly(
                "--package", "--install-root", "--state-root", "--runtime-executable",
                "--expected-manifest-sha256", "--confirm", "--parent-pid",
                "--allow-unsigned-development");
            var confirmed = Required(parsed, "--confirm") == "UPDATE";
            if (!confirmed)
                throw new UpdateException("aigw_update_confirmation_required", "Type UPDATE exactly before the candidate package is read.");
            var parentPid = int.TryParse(Required(parsed, "--parent-pid"), out var parsedPid) && parsedPid > 0
                ? parsedPid
                : throw InvalidArguments("Invalid parent PID.");
            var request = new PackageUpdateRequest(
                package,
                Required(parsed, "--expected-manifest-sha256"),
                confirmed,
                allowUnsigned,
                DeferRollbackCleanup: false);
            var inspection = await service.InspectAsync(package, allowUnsigned);
            if (!PackageSignatureJson.IsHash(request.ExpectedManifestSha256) ||
                !inspection.ManifestSha256.Equals(request.ExpectedManifestSha256, StringComparison.Ordinal))
            {
                throw new UpdateException("aigw_update_stale_inspection", "The candidate manifest changed after inspection.");
            }
            var currentVersion = inspection.InstalledVersion
                ?? throw new UpdateException("aigw_update_current_manifest_invalid", "The installed package version is unavailable.");
            if (PackageVersionComparer.Compare(inspection.Version, currentVersion) <= 0)
                throw new UpdateException("aigw_update_version_not_newer", "The candidate package version must be newer than the installed version.");
            var scheduler = updateScheduler ?? ScheduleWorkerAsync;
            var scheduled = await scheduler(target, request, inspection, parentPid);
            await WriteJsonAsync(stdout, new
            {
                schemaVersion = 1,
                operation = "apply",
                previousVersion = currentVersion,
                currentVersion = inspection.Version,
                inspection.ManifestSha256,
                trustKind = Trust(inspection.TrustKind),
                inspection.KeyId,
                completionPending = true,
                scheduled.OperationId,
                scheduled.ReceiptPath,
            });
            return SuccessExitCode;
        }
        catch (UpdaterArgumentsException exception)
        {
            return await ErrorAsync(stderr, InvalidArgumentsExitCode, "aigw_update_arguments_invalid", exception.Message);
        }
        catch (UpdateException exception)
        {
            return await ErrorAsync(stderr, UpdateErrorExitCode, exception.ErrorCode, exception.Message);
        }
        catch (UninstallException exception)
        {
            return await ErrorAsync(stderr, UninstallErrorExitCode, exception.ErrorCode, exception.Message);
        }
        catch (Exception)
        {
            return await ErrorAsync(stderr, UnexpectedErrorExitCode, "aigw_internal_error", "The updater failed unexpectedly.");
        }
    }

    private static async Task<int> RunWorkerApplyAsync(Arguments parsed)
    {
        parsed.AssertOnly(
            "--package", "--install-root", "--state-root", "--runtime-executable",
            "--expected-manifest-sha256", "--confirm", "--operation-id", "--receipt-path",
            "--worker-root", "--wait-pid", "--allow-unsigned-development");
        var target = Target(parsed);
        var operationId = RequiredGuid(parsed, "--operation-id");
        var receiptPath = NormalizeAbsoluteNonRoot(Required(parsed, "--receipt-path"), "receipt path");
        var workerRoot = NormalizeAbsoluteNonRoot(Required(parsed, "--worker-root"), "worker root");
        ValidateWorkerPaths(target.StateRoot, operationId, workerRoot, receiptPath);
        ValidateRunningFromWorker(workerRoot);
        var request = new PackageUpdateRequest(
            Required(parsed, "--package"),
            Required(parsed, "--expected-manifest-sha256"),
            Required(parsed, "--confirm") == "UPDATE",
            parsed.HasFlag("--allow-unsigned-development"),
            DeferRollbackCleanup: false);
        var exitCode = SuccessExitCode;
        object receipt;
        try
        {
            await WaitForProcessesAsync(ParseWaitPids(parsed));
            var result = await CreateDefaultService(target).ApplyAsync(request);
            receipt = new
            {
                schemaVersion = 1,
                operationId,
                state = "completed",
                ok = true,
                result = new
                {
                    result.PreviousVersion,
                    result.CurrentVersion,
                    result.ManifestSha256,
                    trustKind = Trust(result.TrustKind),
                    result.KeyId,
                    result.DaemonWasRunning,
                    result.DaemonRunning,
                    result.RolledBack,
                },
            };
        }
        catch (UpdateException exception)
        {
            exitCode = UpdateErrorExitCode;
            receipt = FailureReceipt(operationId, exception.ErrorCode, exception.Message);
        }
        catch (Exception)
        {
            exitCode = UnexpectedErrorExitCode;
            receipt = FailureReceipt(operationId, "aigw_internal_error", "The updater worker failed unexpectedly.");
        }

        await WriteReceiptAsync(receiptPath, receipt);
        LaunchWorkerCleanup(target, workerRoot);
        return exitCode;
    }

    private static async Task<int> RunWorkerUninstallAsync(Arguments parsed)
    {
        parsed.AssertOnly(
            "--install-root", "--state-root", "--runtime-executable", "--confirm",
            "--program", "--autostart", "--integrations", "--runtime-credential",
            "--provider-credentials", "--configuration", "--usage", "--logs", "--backups",
            "--claude-vscode-target", "--codex-cli-target", "--backup-path",
            "--operation-id", "--receipt-path", "--worker-root", "--wait-pid");
        var target = Target(parsed);
        ValidateUninstallTargetLayout(target);
        var operationId = RequiredGuid(parsed, "--operation-id");
        var receiptPath = NormalizeAbsoluteNonRoot(Required(parsed, "--receipt-path"), "receipt path");
        var workerRoot = NormalizeAbsoluteNonRoot(Required(parsed, "--worker-root"), "worker root");
        ValidateUninstallWorkerPaths(target, operationId, workerRoot, receiptPath);
        ValidateRunningFromUninstallWorker(workerRoot);
        var request = ParseUninstallRequest(parsed);
        var exitCode = SuccessExitCode;
        object receipt;
        try
        {
            await WaitForProcessesAsync(ParseWaitPids(parsed));
            var result = await CreateDefaultUninstallService(target, workerRoot).UninstallAsync(request);
            receipt = new
            {
                schemaVersion = 1,
                operationId,
                state = "completed",
                ok = true,
                result,
            };
        }
        catch (Exception exception) when (TryUninstallFailure(exception, out var code, out var message))
        {
            exitCode = UninstallErrorExitCode;
            receipt = FailureReceipt(operationId, code!, message!);
        }
        catch (Exception)
        {
            exitCode = UnexpectedErrorExitCode;
            receipt = FailureReceipt(operationId, "aigw_internal_error", "The uninstall worker failed unexpectedly.");
        }

        await WriteReceiptAsync(receiptPath, receipt);
        return exitCode;
    }

    private static async Task<ScheduledUninstall> ScheduleUninstallWorkerAsync(
        CurrentUserInstallationTarget target,
        UninstallRequest request,
        int parentPid)
    {
        var operationId = Guid.NewGuid().ToString("N");
        var temporaryRoot = UninstallTemporaryRoot(target);
        var workerRoot = UninstallWorkerRoot(target, operationId);
        var receiptPath = UninstallReceiptPath(target, operationId);
        var sourceRoot = Path.Combine(target.InstallRoot, "updater");
        var security = new WindowsConfigurationFileSecurity();
        try
        {
            EnsureProtectedUninstallDirectory(temporaryRoot, security);
            EnsureProtectedUninstallDirectory(Path.GetDirectoryName(workerRoot)!, security);
            EnsureProtectedUninstallDirectory(Path.GetDirectoryName(receiptPath)!, security);
            try
            {
                CopyWorkerTree(sourceRoot, workerRoot, security);
            }
            catch (UpdateException exception)
            {
                throw new UninstallException(
                    "aigw_uninstall_worker_source_invalid",
                    "The installed uninstall worker payload is missing or unsafe.",
                    exception);
            }

            var executable = Path.Combine(workerRoot, "aigw-updater.exe");
            var arguments = new List<string>();
            AddTargetArguments(arguments, "worker-uninstall", target);
            AddUninstallArguments(arguments, request);
            arguments.Add("--operation-id");
            arguments.Add(operationId);
            arguments.Add("--receipt-path");
            arguments.Add(receiptPath);
            arguments.Add("--worker-root");
            arguments.Add(workerRoot);
            arguments.Add("--wait-pid");
            arguments.Add(Environment.ProcessId.ToString(System.Globalization.CultureInfo.InvariantCulture));
            arguments.Add("--wait-pid");
            arguments.Add(parentPid.ToString(System.Globalization.CultureInfo.InvariantCulture));
            try
            {
                using var process = StartRestrictedUpdateProcess(
                    executable,
                    arguments,
                    "aigw_uninstall_worker_start_failed");
            }
            catch (UpdateException exception)
            {
                throw new UninstallException(
                    "aigw_uninstall_worker_start_failed",
                    "The restricted uninstall worker could not be started.",
                    exception);
            }
            await Task.Yield();
            return new ScheduledUninstall(operationId, receiptPath);
        }
        catch
        {
            if (Directory.Exists(workerRoot))
            {
                Directory.Delete(workerRoot, recursive: true);
            }
            CleanupEmptyUninstallDirectories(temporaryRoot, workerRoot, receiptPath);
            throw;
        }
    }

    private static IUninstallService CreateDefaultUninstallService(
        CurrentUserInstallationTarget target,
        string workerRoot)
    {
        var control = new WindowsNamedPipeControlClient(
            WindowsControlPipeName.ForCurrentUser(),
            TimeSpan.FromMilliseconds(250),
            TimeSpan.FromSeconds(70));
        var daemon = new GatewayDaemonController(control);
        var credentials = new WindowsCredentialStore();
        return new CompleteUninstallExecutor(
            target,
            workerRoot,
            new CurrentUserUninstallCoordinator(
                new WindowsPackageInstaller(),
                daemon,
                credentials,
                credentials),
            new ClientIntegrationLifecycleManager(),
            new BackupFileCleaner());
    }

    private static object FailureReceipt(string operationId, string code, string message) => new
    {
        schemaVersion = 1,
        operationId,
        state = "completed",
        ok = false,
        error = new { code, message },
    };

    private static async Task<ScheduledUpdate> ScheduleWorkerAsync(
        CurrentUserInstallationTarget target,
        PackageUpdateRequest request,
        PackageUpdateInspection inspection,
        int parentPid)
    {
        var operationId = Guid.NewGuid().ToString("N");
        var workersRoot = Path.Combine(target.StateRoot, "update-workers");
        var receiptsRoot = Path.Combine(target.StateRoot, "update-receipts");
        var workerRoot = Path.Combine(workersRoot, operationId);
        var receiptPath = Path.Combine(receiptsRoot, operationId + ".json");
        var sourceRoot = Path.Combine(target.InstallRoot, "updater");
        var security = new WindowsConfigurationFileSecurity();
        EnsureProtectedDirectory(target.StateRoot, security);
        EnsureProtectedDirectory(workersRoot, security);
        EnsureProtectedDirectory(receiptsRoot, security);
        try
        {
            CopyWorkerTree(sourceRoot, workerRoot, security);
            var executable = Path.Combine(workerRoot, "aigw-updater.exe");
            var arguments = new List<string>();
            AddTargetArguments(arguments, "worker-apply", target);
            arguments.Add("--package");
            arguments.Add(request.PackageRoot);
            arguments.Add("--expected-manifest-sha256");
            arguments.Add(request.ExpectedManifestSha256);
            arguments.Add("--confirm");
            arguments.Add("UPDATE");
            arguments.Add("--operation-id");
            arguments.Add(operationId);
            arguments.Add("--receipt-path");
            arguments.Add(receiptPath);
            arguments.Add("--worker-root");
            arguments.Add(workerRoot);
            arguments.Add("--wait-pid");
            arguments.Add(Environment.ProcessId.ToString(System.Globalization.CultureInfo.InvariantCulture));
            arguments.Add("--wait-pid");
            arguments.Add(parentPid.ToString(System.Globalization.CultureInfo.InvariantCulture));
            if (request.AllowUnsignedDevelopment) arguments.Add("--allow-unsigned-development");
            using var process = StartRestrictedUpdateProcess(executable, arguments, "aigw_update_worker_start_failed");
            await Task.Yield();
            return new ScheduledUpdate(operationId, receiptPath);
        }
        catch
        {
            if (Directory.Exists(workerRoot)) Directory.Delete(workerRoot, recursive: true);
            throw;
        }
    }

    private static IPackageUpdateService CreateDefaultService(CurrentUserInstallationTarget target)
    {
        var control = new WindowsNamedPipeControlClient(
            WindowsControlPipeName.ForCurrentUser(),
            TimeSpan.FromMilliseconds(250),
            TimeSpan.FromSeconds(70));
        return new WindowsPackageUpdateService(target, new GatewayDaemonController(control));
    }

    private static CurrentUserInstallationTarget Target(Arguments args)
    {
        var installRoot = NormalizeAbsoluteNonRoot(Required(args, "--install-root"), "install root");
        var stateRoot = NormalizeAbsoluteNonRoot(Required(args, "--state-root"), "state root");
        var runtimeExecutable = NormalizeAbsoluteNonRoot(Required(args, "--runtime-executable"), "runtime executable");
        var expectedRuntime = Path.Combine(installRoot, "aigw-runtime.exe");
        if (!runtimeExecutable.Equals(expectedRuntime, StringComparison.OrdinalIgnoreCase))
            throw InvalidArguments("The runtime executable must be the fixed executable in the install root.");
        return new CurrentUserInstallationTarget(
            installRoot,
            stateRoot,
            Path.Combine(stateRoot, "runtime"),
            runtimeExecutable,
            CredentialTargets.RuntimeClientToken);
    }

    private static int[] ParseWaitPids(Arguments parsed) => parsed.GetValues("--wait-pid").Select(value =>
        int.TryParse(value, out var pid) && pid > 0 ? pid : throw InvalidArguments("Invalid wait PID.")).ToArray();

    private static void ValidateUninstallTargetLayout(CurrentUserInstallationTarget target)
    {
        var programsRoot = Path.GetDirectoryName(target.InstallRoot);
        var localAppDataRoot = programsRoot is null ? null : Path.GetDirectoryName(programsRoot);
        if (programsRoot is null || localAppDataRoot is null ||
            !Path.GetFileName(programsRoot).Equals("Programs", StringComparison.OrdinalIgnoreCase) ||
            !Path.GetFileName(target.InstallRoot).Equals("LocalAIGateway", StringComparison.OrdinalIgnoreCase) ||
            !target.StateRoot.Equals(
                Path.Combine(localAppDataRoot, "LocalAIGateway"),
                StringComparison.OrdinalIgnoreCase) ||
            !target.RuntimeStateRoot.Equals(
                Path.Combine(target.StateRoot, "runtime"),
                StringComparison.OrdinalIgnoreCase) ||
            !target.RuntimeCredentialTarget.Equals(CredentialTargets.RuntimeClientToken, StringComparison.Ordinal))
        {
            throw new UninstallException(
                "aigw_uninstall_target_invalid",
                "Uninstall targets must match the fixed current-user Local AI Gateway layout.");
        }
    }

    private static string RequiredGuid(Arguments parsed, string name)
    {
        var value = Required(parsed, name);
        return Guid.TryParseExact(value, "N", out _) ? value : throw InvalidArguments($"Invalid GUID option {name}.");
    }

    private static void ValidateWorkerPaths(string stateRoot, string operationId, string workerRoot, string receiptPath)
    {
        var normalizedState = NormalizeAbsoluteNonRoot(stateRoot, "state root");
        var expectedWorker = Path.Combine(normalizedState, "update-workers", operationId);
        var expectedReceipt = Path.Combine(normalizedState, "update-receipts", operationId + ".json");
        if (!workerRoot.Equals(expectedWorker, StringComparison.OrdinalIgnoreCase) ||
            !receiptPath.Equals(expectedReceipt, StringComparison.OrdinalIgnoreCase))
        {
            throw InvalidArguments("The update worker paths do not match the owned operation paths.");
        }
    }

    private static void ValidateRunningFromWorker(string workerRoot)
    {
        var expected = Path.Combine(workerRoot, "aigw-updater.exe");
        var actual = Environment.ProcessPath;
        if (actual is null || !Path.GetFullPath(actual).Equals(expected, StringComparison.OrdinalIgnoreCase))
            throw new UpdateException("aigw_update_untrusted_worker", "The update worker is not running from its owned operation directory.");
    }

    private static void EnsureProtectedDirectory(string path, WindowsConfigurationFileSecurity security)
    {
        if (Directory.Exists(path)) return;
        Directory.CreateDirectory(path);
        security.ProtectDirectory(path);
    }

    private static void CopyWorkerTree(string sourceRoot, string workerRoot, WindowsConfigurationFileSecurity security)
    {
        if (!Directory.Exists(sourceRoot) ||
            (File.GetAttributes(sourceRoot) & FileAttributes.ReparsePoint) != 0 ||
            Directory.Exists(workerRoot) || File.Exists(workerRoot))
        {
            throw new UpdateException("aigw_update_worker_source_invalid", "The installed updater payload is missing or unsafe.");
        }
        Directory.CreateDirectory(workerRoot);
        security.ProtectDirectory(workerRoot);
        foreach (var directory in Directory.EnumerateDirectories(sourceRoot, "*", SearchOption.AllDirectories))
        {
            if ((File.GetAttributes(directory) & FileAttributes.ReparsePoint) != 0)
                throw new UpdateException("aigw_update_worker_source_invalid", "The installed updater payload contains a reparse point.");
            Directory.CreateDirectory(Path.Combine(workerRoot, Path.GetRelativePath(sourceRoot, directory)));
        }
        foreach (var file in Directory.EnumerateFiles(sourceRoot, "*", SearchOption.AllDirectories))
        {
            if ((File.GetAttributes(file) & FileAttributes.ReparsePoint) != 0)
                throw new UpdateException("aigw_update_worker_source_invalid", "The installed updater payload contains a reparse point.");
            var destination = Path.Combine(workerRoot, Path.GetRelativePath(sourceRoot, file));
            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            File.Copy(file, destination, overwrite: false);
        }
    }

    private static void AddTargetArguments(
        ICollection<string> arguments,
        string command,
        CurrentUserInstallationTarget target)
    {
        arguments.Add(command);
        arguments.Add("--install-root");
        arguments.Add(target.InstallRoot);
        arguments.Add("--state-root");
        arguments.Add(target.StateRoot);
        arguments.Add("--runtime-executable");
        arguments.Add(target.RuntimeExecutablePath);
    }

    private static void AddUninstallArguments(
        ICollection<string> arguments,
        UninstallRequest request)
    {
        AddChoice(arguments, "--program", request.Selection.Program);
        AddChoice(arguments, "--autostart", request.Selection.Autostart);
        AddChoice(arguments, "--integrations", request.Selection.Integrations);
        AddChoice(arguments, "--runtime-credential", request.Selection.RuntimeCredential);
        AddChoice(arguments, "--provider-credentials", request.Selection.ProviderCredentials);
        AddChoice(arguments, "--configuration", request.Selection.Configuration);
        AddChoice(arguments, "--usage", request.Selection.Usage);
        AddChoice(arguments, "--logs", request.Selection.Logs);
        AddChoice(arguments, "--backups", request.Selection.Backups);
        arguments.Add("--confirm");
        arguments.Add("UNINSTALL");
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
        foreach (var backupPath in request.BackupPaths)
        {
            arguments.Add("--backup-path");
            arguments.Add(backupPath);
        }
    }

    private static UninstallRequest ParseUninstallRequest(Arguments parsed)
    {
        if (Required(parsed, "--confirm") != "UNINSTALL")
        {
            throw new UninstallException(
                "aigw_uninstall_confirmation_required",
                "Uninstall requires the exact confirmation value UNINSTALL.");
        }

        var integrations = new List<UninstallIntegrationTarget>();
        AddParsedIntegration(integrations, "claude-vscode", parsed.GetSingle("--claude-vscode-target"));
        AddParsedIntegration(integrations, "codex-cli", parsed.GetSingle("--codex-cli-target"));
        var request = new UninstallRequest(
            new UninstallSelection(
                ParseChoice(parsed, "--program"),
                ParseChoice(parsed, "--autostart"),
                ParseChoice(parsed, "--integrations"),
                ParseChoice(parsed, "--runtime-credential"),
                ParseChoice(parsed, "--provider-credentials"),
                ParseChoice(parsed, "--configuration"),
                ParseChoice(parsed, "--usage"),
                ParseChoice(parsed, "--logs"),
                ParseChoice(parsed, "--backups")),
            integrations,
            parsed.GetValues("--backup-path").ToArray(),
            Confirmed: true);
        if ((request.Selection.Integrations == UninstallChoice.Remove) != (integrations.Count != 0) ||
            (request.Selection.Backups == UninstallChoice.Keep && request.BackupPaths.Count != 0))
        {
            throw new UninstallException(
                "aigw_uninstall_mode_conflict",
                "Uninstall targets do not match their explicit category selections.");
        }
        return request;
    }

    private static void AddParsedIntegration(
        ICollection<UninstallIntegrationTarget> targets,
        string client,
        string? path)
    {
        if (path is not null)
        {
            targets.Add(new UninstallIntegrationTarget(client, path));
        }
    }

    private static UninstallChoice ParseChoice(Arguments parsed, string name) => Required(parsed, name) switch
    {
        "keep" => UninstallChoice.Keep,
        "remove" => UninstallChoice.Remove,
        _ => throw new UninstallException(
            "aigw_uninstall_selection_invalid",
            $"Uninstall selection {name} must be keep or remove."),
    };

    private static void AddChoice(
        ICollection<string> arguments,
        string name,
        UninstallChoice choice)
    {
        arguments.Add(name);
        arguments.Add(choice == UninstallChoice.Remove ? "remove" : "keep");
    }

    private static int ParsePositiveInt(string value, string label) =>
        int.TryParse(value, out var parsed) && parsed > 0
            ? parsed
            : throw InvalidArguments($"Invalid {label}.");

    private static string UninstallWorkerRoot(
        CurrentUserInstallationTarget target,
        string operationId) =>
        Path.Combine(UninstallTemporaryRoot(target), "uninstall-workers", operationId);

    private static string UninstallReceiptPath(
        CurrentUserInstallationTarget target,
        string operationId) =>
        Path.Combine(UninstallTemporaryRoot(target), "uninstall-receipts", operationId + ".json");

    private static string UninstallTemporaryRoot(CurrentUserInstallationTarget target) =>
        Path.Combine(
            Path.GetDirectoryName(target.StateRoot)
                ?? throw new UninstallException(
                    "aigw_uninstall_worker_path_invalid",
                    "The current-user state root has no Local AppData parent."),
            "Temp",
            "LocalAIGateway-Uninstall");

    private static void EnsureProtectedUninstallDirectory(
        string path,
        WindowsConfigurationFileSecurity security)
    {
        if (File.Exists(path) ||
            (Directory.Exists(path) && (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0))
        {
            throw new UninstallException(
                "aigw_uninstall_worker_path_unsafe",
                "The fixed uninstall temporary directory is occupied or is a reparse point.");
        }
        Directory.CreateDirectory(path);
        security.ProtectDirectory(path);
    }

    private static void CleanupEmptyUninstallDirectories(
        string temporaryRoot,
        string workerRoot,
        string receiptPath)
    {
        foreach (var path in new[]
        {
            Path.GetDirectoryName(workerRoot),
            Path.GetDirectoryName(receiptPath),
            temporaryRoot,
        })
        {
            if (path is not null && Directory.Exists(path) &&
                !Directory.EnumerateFileSystemEntries(path).Any())
            {
                Directory.Delete(path);
            }
        }
    }

    private static void ValidateUninstallWorkerPaths(
        CurrentUserInstallationTarget target,
        string operationId,
        string workerRoot,
        string receiptPath)
    {
        if (!workerRoot.Equals(UninstallWorkerRoot(target, operationId), StringComparison.OrdinalIgnoreCase) ||
            !receiptPath.Equals(UninstallReceiptPath(target, operationId), StringComparison.OrdinalIgnoreCase))
        {
            throw new UninstallException(
                "aigw_uninstall_worker_path_invalid",
                "The uninstall worker paths do not match the fixed temporary operation paths.");
        }
    }

    private static void ValidateRunningFromUninstallWorker(string workerRoot)
    {
        var expected = Path.Combine(workerRoot, "aigw-updater.exe");
        var actual = Environment.ProcessPath;
        if (actual is null || !Path.GetFullPath(actual).Equals(expected, StringComparison.OrdinalIgnoreCase))
        {
            throw new UninstallException(
                "aigw_uninstall_untrusted_worker",
                "The uninstall worker is not running from its fixed operation directory.");
        }
    }

    private static bool TryUninstallFailure(
        Exception exception,
        out string? code,
        out string? message)
    {
        (code, message) = exception switch
        {
            UninstallException failure => (failure.ErrorCode, failure.Message),
            InstallationException failure => (failure.ErrorCode, failure.Message),
            BackupException failure => (failure.ErrorCode, failure.Message),
            ClientIntegrationException failure => (failure.ErrorCode, failure.Message),
            ClientIntegrationFileException failure => (failure.ErrorCode, failure.Message),
            _ => (null, null),
        };
        return code is not null;
    }

    private static async Task WriteReceiptAsync(string receiptPath, object receipt)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(receipt, JsonOptions);
        var temporary = receiptPath + $".tmp-{Guid.NewGuid():N}";
        try
        {
            await using (var stream = new FileStream(
                temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096,
                FileOptions.Asynchronous | FileOptions.WriteThrough))
            {
                await stream.WriteAsync(bytes);
                await stream.FlushAsync();
                stream.Flush(flushToDisk: true);
            }
            File.Move(temporary, receiptPath);
            new WindowsConfigurationFileSecurity().ProtectFile(receiptPath);
        }
        finally
        {
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }

    private static void LaunchWorkerCleanup(CurrentUserInstallationTarget target, string workerRoot)
    {
        var executable = Path.Combine(target.InstallRoot, "updater", "aigw-updater.exe");
        var arguments = new List<string>
        {
            "cleanup-worker",
            "--install-root", target.InstallRoot,
            "--state-root", target.StateRoot,
            "--cleanup-path", workerRoot,
            "--wait-pid", Environment.ProcessId.ToString(System.Globalization.CultureInfo.InvariantCulture),
        };
        using var process = StartRestrictedUpdateProcess(executable, arguments, "aigw_update_cleanup_start_failed");
    }

    private static System.Diagnostics.Process StartRestrictedUpdateProcess(
        string executable,
        IReadOnlyList<string> arguments,
        string errorCode)
    {
        var environment = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["DOTNET_MULTILEVEL_LOOKUP"] = "0",
        };
        var systemRoot = Environment.GetEnvironmentVariable("SystemRoot");
        if (!string.IsNullOrEmpty(systemRoot)) environment["SystemRoot"] = systemRoot;
        try
        {
            return WindowsDetachedProcess.Start(executable, Path.GetTempPath(), arguments, environment);
        }
        catch (Exception exception)
        {
            throw new UpdateException(errorCode, "The restricted update process could not be started.", exception);
        }
    }

    private static void CleanupWorkerDirectory(string stateRoot, string cleanupPath)
    {
        var normalizedState = NormalizeAbsoluteNonRoot(stateRoot, "state root");
        var normalizedCleanup = NormalizeAbsoluteNonRoot(cleanupPath, "cleanup path");
        var expectedParent = Path.Combine(normalizedState, "update-workers");
        if (!string.Equals(Path.GetDirectoryName(normalizedCleanup), expectedParent, StringComparison.OrdinalIgnoreCase) ||
            !Guid.TryParseExact(Path.GetFileName(normalizedCleanup), "N", out _))
        {
            throw new UpdateException("aigw_update_cleanup_path_invalid", "The update worker path is not owned by this installation.");
        }
        if (Directory.Exists(normalizedCleanup)) Directory.Delete(normalizedCleanup, recursive: true);
    }

    private static string NormalizeAbsoluteNonRoot(string path, string label)
    {
        if (!Path.IsPathFullyQualified(path)) throw InvalidArguments($"The {label} must be an absolute path.");
        var normalized = Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var root = Path.GetPathRoot(normalized)?.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        if (normalized.Length == 0 || normalized.Equals(root, StringComparison.OrdinalIgnoreCase))
            throw InvalidArguments($"The {label} must not be a volume root.");
        return normalized;
    }

    private static void ValidateRunningFromInstalledUpdater(string installRoot)
    {
        var expected = Path.Combine(installRoot, "updater", "aigw-updater.exe");
        var actual = Environment.ProcessPath;
        if (actual is null || !Path.GetFullPath(actual).Equals(Path.GetFullPath(expected), StringComparison.OrdinalIgnoreCase))
            throw new UpdateException("aigw_update_untrusted_entrypoint", "Updates must be executed by the currently installed updater.");
    }

    private static Task LaunchCleanupAsync(string installRoot, string cleanupPath, int[] waitPids)
    {
        var executable = Path.Combine(installRoot, "updater", "aigw-updater.exe");
        var start = new System.Diagnostics.ProcessStartInfo
        {
            FileName = executable,
            WorkingDirectory = Path.Combine(installRoot, "updater"),
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        start.ArgumentList.Add("cleanup");
        start.ArgumentList.Add("--install-root");
        start.ArgumentList.Add(installRoot);
        start.ArgumentList.Add("--cleanup-path");
        start.ArgumentList.Add(cleanupPath);
        foreach (var pid in waitPids)
        {
            start.ArgumentList.Add("--wait-pid");
            start.ArgumentList.Add(pid.ToString(System.Globalization.CultureInfo.InvariantCulture));
        }
        try
        {
            using var process = System.Diagnostics.Process.Start(start)
                ?? throw CleanupStartFailed();
            return Task.CompletedTask;
        }
        catch (UpdateException) { throw; }
        catch (Exception exception) when (exception is System.ComponentModel.Win32Exception or IOException)
        {
            throw CleanupStartFailed(exception);
        }
    }

    private static async Task WaitForProcessesAsync(IEnumerable<int> pids)
    {
        foreach (var pid in pids.Distinct())
        {
            try
            {
                using var process = System.Diagnostics.Process.GetProcessById(pid);
                using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(2));
                await process.WaitForExitAsync(timeout.Token);
            }
            catch (ArgumentException) { }
            catch (OperationCanceledException exception)
            {
                throw new UpdateException("aigw_update_cleanup_wait_timeout", "Timed out waiting to clean the previous installation.", exception);
            }
        }
    }

    private static Arguments Parse(IEnumerable<string> tokens)
    {
        var result = new Arguments();
        var values = tokens.ToArray();
        for (var index = 0; index < values.Length; index++)
        {
            var token = values[index];
            if (!token.StartsWith("--", StringComparison.Ordinal)) throw InvalidArguments("Unexpected positional argument.");
            if (token == "--allow-unsigned-development")
            {
                result.Add(token, null);
                continue;
            }
            if (index + 1 >= values.Length || values[index + 1].StartsWith("--", StringComparison.Ordinal))
                throw InvalidArguments($"Missing value for {token}.");
            result.Add(token, values[++index]);
        }
        return result;
    }

    private static string Required(Arguments args, string name) =>
        args.GetSingle(name) ?? throw InvalidArguments($"Missing required option {name}.");

    private static async Task WriteJsonAsync(TextWriter writer, object value) =>
        await writer.WriteLineAsync(JsonSerializer.Serialize(value, JsonOptions));

    private static async Task<int> ErrorAsync(TextWriter writer, int exitCode, string errorCode, string message)
    {
        await WriteJsonAsync(writer, new { schemaVersion = 1, error = new { code = errorCode, message } });
        return exitCode;
    }

    private static string Trust(PackageTrustKind trust) => trust == PackageTrustKind.Signed ? "signed" : "unsigned-development";
    private static UpdateException CleanupStartFailed(Exception? inner = null) => new(
        "aigw_update_cleanup_start_failed", "The deferred rollback cleaner could not be started.", inner);
    private static string GetVersion()
    {
        var assembly = typeof(UpdaterApplication).Assembly;
        return assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion
            ?? assembly.GetName().Version?.ToString() ?? "unknown";
    }
    private static UpdaterArgumentsException InvalidArguments(string message) => new(message);

    private sealed class Arguments
    {
        private readonly Dictionary<string, List<string?>> values = new(StringComparer.Ordinal);
        public void Add(string key, string? value)
        {
            if (!values.TryGetValue(key, out var entries)) values.Add(key, entries = []);
            if (key is not ("--wait-pid" or "--backup-path") && entries.Count != 0)
                throw InvalidArguments($"Duplicate option {key}.");
            entries.Add(value);
        }
        public bool HasFlag(string key) => values.ContainsKey(key);
        public string? GetSingle(string key) => values.TryGetValue(key, out var entries) ? entries.Single() : null;
        public IEnumerable<string> GetValues(string key) =>
            values.TryGetValue(key, out var entries) ? entries.Select(value => value!) : [];
        public void AssertOnly(params string[] allowed)
        {
            var set = allowed.ToHashSet(StringComparer.Ordinal);
            if (values.Keys.Any(key => !set.Contains(key))) throw InvalidArguments("An option is not valid for this updater command.");
        }
    }

    private sealed class UpdaterArgumentsException(string message) : Exception(message);
}

public sealed record ScheduledUpdate(string OperationId, string ReceiptPath);

public sealed record ScheduledUninstall(string OperationId, string ReceiptPath);
