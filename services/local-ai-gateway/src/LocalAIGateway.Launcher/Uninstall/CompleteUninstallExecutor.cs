using LocalAIGateway.Core.Backup;
using LocalAIGateway.Core.Installation;
using LocalAIGateway.Core.Uninstall;
using LocalAIGateway.Windows.Uninstall;

namespace LocalAIGateway.Launcher.Uninstall;

public sealed class CompleteUninstallExecutor : IUninstallService
{
    private readonly CurrentUserInstallationTarget target;
    private readonly string commandBaseDirectory;
    private readonly ICurrentUserUninstallCoordinator platform;
    private readonly IClientIntegrationLifecycleManager integrations;
    private readonly BackupFileCleaner backups;

    public CompleteUninstallExecutor(
        CurrentUserInstallationTarget target,
        string commandBaseDirectory,
        ICurrentUserUninstallCoordinator platform,
        IClientIntegrationLifecycleManager integrations,
        BackupFileCleaner backups)
    {
        this.target = target ?? throw new ArgumentNullException(nameof(target));
        this.commandBaseDirectory = Path.GetFullPath(commandBaseDirectory);
        this.platform = platform ?? throw new ArgumentNullException(nameof(platform));
        this.integrations = integrations ?? throw new ArgumentNullException(nameof(integrations));
        this.backups = backups ?? throw new ArgumentNullException(nameof(backups));
    }

    public async Task<UninstallResult> UninstallAsync(
        UninstallRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        ValidateRequest(request);
        if (request.Selection.Program == UninstallChoice.Remove &&
            IsSameOrDescendant(commandBaseDirectory, target.InstallRoot))
        {
            throw new UninstallException(
                "aigw_uninstall_running_from_install_root",
                "Program-file removal from the installed CLI requires the dedicated external uninstall worker.");
        }

        var integrationPlans = await InspectIntegrationsAsync(request, cancellationToken);
        var backupPlans = request.Selection.Backups == UninstallChoice.Remove
            ? await backups.InspectAsync(request.BackupPaths, cancellationToken)
            : [];
        cancellationToken.ThrowIfCancellationRequested();

        var integrationResults = new List<ClientIntegrationUnintegrateResult>();
        foreach (var plan in integrationPlans)
        {
            integrationResults.Add(await integrations.UnintegrateAsync(new(
                plan.Client,
                plan.TargetPath,
                plan.BeforeSha256!,
                plan.AfterSha256,
                plan.Action == ClientIntegrationRemovalAction.Delete,
                Confirmed: true), CancellationToken.None));
        }

        var platformResult = await platform.UninstallAsync(
            target,
            request.Selection,
            CancellationToken.None);
        var backupResult = request.Selection.Backups == UninstallChoice.Remove
            ? await backups.DeleteInspectedAsync(backupPlans, CancellationToken.None)
            : new BackupFileCleanupResult([], false);

        return new UninstallResult(
            platformResult.Program,
            platformResult.Autostart,
            IntegrationCategory(request.Selection.Integrations, integrationResults),
            platformResult.RuntimeCredential,
            platformResult.ProviderCredentials,
            platformResult.Configuration,
            platformResult.Usage,
            platformResult.Logs,
            BackupCategory(request.Selection.Backups, backupResult),
            CompletionPending: false,
            OperationId: null,
            ReceiptPath: null);
    }

    private async Task<IReadOnlyList<ClientIntegrationStatusResult>> InspectIntegrationsAsync(
        UninstallRequest request,
        CancellationToken cancellationToken)
    {
        if (request.Selection.Integrations == UninstallChoice.Keep)
        {
            return [];
        }

        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var plans = new List<ClientIntegrationStatusResult>();
        foreach (var requested in request.IntegrationTargets)
        {
            var client = requested.Client switch
            {
                "claude-vscode" => ClientIntegrationKind.ClaudeVsCode,
                "codex-cli" => ClientIntegrationKind.CodexCli,
                _ => throw new UninstallException(
                    "aigw_uninstall_integration_target_invalid",
                    "An uninstall integration client is unknown."),
            };
            var normalized = NormalizeIntegrationTarget(requested.TargetPath);
            if (!seen.Add(normalized))
            {
                throw new UninstallException(
                    "aigw_uninstall_integration_target_duplicate",
                    "The uninstall integration target list contains a duplicate path.");
            }

            var status = await integrations.GetStatusAsync(
                new ClientIntegrationStatusRequest(client, normalized),
                cancellationToken);
            if (status.Status != ClientIntegrationStatusKind.Owned)
            {
                throw new UninstallException(
                    "aigw_uninstall_integration_not_owned",
                    "An explicit integration target is absent or not owned; no uninstall action was started.");
            }
            plans.Add(status);
        }
        return plans;
    }

    private static void ValidateRequest(UninstallRequest request)
    {
        if (!request.Confirmed)
        {
            throw new UninstallException(
                "aigw_uninstall_confirmation_required",
                "Complete uninstall requires explicit category confirmation.");
        }
        if ((request.Selection.Integrations == UninstallChoice.Remove) != (request.IntegrationTargets.Count != 0))
        {
            throw new UninstallException(
                "aigw_uninstall_integration_targets_required",
                "Integration removal requires one or more explicit targets, and kept integrations accept none.");
        }
        if (request.Selection.Backups == UninstallChoice.Keep && request.BackupPaths.Count != 0)
        {
            throw new UninstallException(
                "aigw_uninstall_mode_conflict",
                "Kept backups accept no explicit removal paths.");
        }
    }

    private static UninstallCategoryResult IntegrationCategory(
        UninstallChoice choice,
        IReadOnlyList<ClientIntegrationUnintegrateResult> results) =>
        choice == UninstallChoice.Keep
            ? Skipped()
            : new(true, results.Any(result => result.Applied), results.Count == 0,
                results.Where(result => result.BackupPath is not null)
                    .Select(result => result.BackupPath!)
                    .ToArray());

    private static UninstallCategoryResult BackupCategory(
        UninstallChoice choice,
        BackupFileCleanupResult result) =>
        choice == UninstallChoice.Keep
            ? Skipped()
            : new(true, result.DeletedFiles.Count != 0, result.AlreadyAbsent, []);

    private static bool IsSameOrDescendant(string candidate, string root)
    {
        var normalizedCandidate = Path.GetFullPath(candidate).TrimEnd(
            Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var normalizedRoot = Path.GetFullPath(root).TrimEnd(
            Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        return normalizedCandidate.Equals(normalizedRoot, StringComparison.OrdinalIgnoreCase) ||
               normalizedCandidate.StartsWith(normalizedRoot + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
    }

    private static string NormalizeIntegrationTarget(string path)
    {
        try
        {
            if (string.IsNullOrWhiteSpace(path) || !Path.IsPathFullyQualified(path))
            {
                throw new ArgumentException("Path is not fully qualified.", nameof(path));
            }
            return Path.GetFullPath(path);
        }
        catch (Exception exception) when (exception is ArgumentException or NotSupportedException)
        {
            throw new UninstallException(
                "aigw_uninstall_integration_target_invalid",
                "An uninstall integration target must be a valid absolute path.",
                exception);
        }
    }

    private static UninstallCategoryResult Skipped() => new(false, false, false, []);
}
