using System.CommandLine;
using System.Text;
using System.Globalization;
using LocalAIGateway.Core.Backup;
using LocalAIGateway.Core.Configuration;
using LocalAIGateway.Core.Control;
using LocalAIGateway.Core.Credentials;
using LocalAIGateway.Core.Installation;
using LocalAIGateway.Core.Usage;
using LocalAIGateway.Core.Update;
using LocalAIGateway.Core.Uninstall;
using LocalAIGateway.Launcher;

namespace LocalAIGateway.Cli;

internal sealed record CliCommandResult(
    object? Data,
    string EnglishMessage,
    string ChineseMessage,
    bool ShowDataInHumanOutput = false,
    int ExitCode = CliApplication.SuccessExitCode,
    bool SuppressOutput = false);

internal sealed class CliCommandExecutor
{
    private readonly GatewayConfigurationManager configuration;
    private readonly CliOperationalServices? operations;
    private readonly CliClientServices? clients;
    private readonly CliIntegrationServices? integrations;
    private readonly CliUsageServices? usage;
    private readonly CliBackupServices? backup;
    private readonly CliUpdateServices? update;
    private readonly CliUninstallServices? uninstall;
    private readonly TextReader stdin;
    private readonly TextWriter promptWriter;

    public CliCommandExecutor(CliServices services, TextReader stdin, TextWriter promptWriter)
    {
        ArgumentNullException.ThrowIfNull(services);
        configuration = services.Configuration;
        operations = services.Operations;
        clients = services.Clients;
        integrations = services.Integrations;
        usage = services.Usage;
        backup = services.Backup;
        update = services.Update;
        uninstall = services.Uninstall;
        this.stdin = stdin;
        this.promptWriter = promptWriter;
    }

    public async Task<CliCommandResult> ExecuteAsync(
        string commandKey,
        ParseResult parseResult,
        CancellationToken cancellationToken = default) => commandKey switch
    {
        "profile.create" => await CreateProfileAsync(parseResult, cancellationToken),
        "profile.list" => await ListProfilesAsync(cancellationToken),
        "profile.show" => await ShowProfileAsync(parseResult, cancellationToken),
        "profile.use" => await UseProfileAsync(parseResult, cancellationToken),
        "profile.delete" => await DeleteProfileAsync(parseResult, cancellationToken),
        "provider.add" => await AddProviderAsync(parseResult, cancellationToken),
        "provider.list" => await ListProvidersAsync(parseResult, cancellationToken),
        "provider.show" => await ShowProviderAsync(parseResult, cancellationToken),
        "provider.update" => await UpdateProviderAsync(parseResult, cancellationToken),
        "provider.set-secret" => await SetProviderSecretAsync(parseResult, cancellationToken),
        "provider.remove" => await RemoveProviderAsync(parseResult, cancellationToken),
        "model.add" => await AddModelAsync(parseResult, cancellationToken),
        "model.list" => await ListModelsAsync(parseResult, cancellationToken),
        "model.show" => await ShowModelAsync(parseResult, cancellationToken),
        "model.update" => await UpdateModelAsync(parseResult, cancellationToken),
        "model.remove" => await RemoveModelAsync(parseResult, cancellationToken),
        "model.set-default" => await SetDefaultModelAsync(parseResult, cancellationToken),
        "model.fallback-add" => await AddModelFallbackAsync(parseResult, cancellationToken),
        "model.fallback-remove" => await RemoveModelFallbackAsync(parseResult, cancellationToken),
        "model.routing-set" => await SetModelRoutingStrategyAsync(parseResult, cancellationToken),
        "model.weight-set" => await SetModelTargetWeightAsync(parseResult, cancellationToken),
        "limits.profile-set" => await SetProfileLimitsAsync(parseResult, cancellationToken),
        "limits.profile-clear" => await ClearProfileLimitsAsync(parseResult, cancellationToken),
        "limits.provider-set" => await SetProviderLimitsAsync(parseResult, cancellationToken),
        "limits.provider-clear" => await ClearProviderLimitsAsync(parseResult, cancellationToken),
        "limits.model-set" => await SetModelLimitsAsync(parseResult, cancellationToken),
        "limits.model-clear" => await ClearModelLimitsAsync(parseResult, cancellationToken),
        "config.show" => await ShowConfigurationAsync(cancellationToken),
        "config.path" => ShowConfigurationPath(),
        "config.validate" => await ValidateConfigurationAsync(cancellationToken),
        "install" => await InstallAsync(parseResult, cancellationToken),
        "uninstall" => await UninstallAsync(parseResult, cancellationToken),
        "start" => await StartAsync(cancellationToken),
        "stop" => await StopAsync(cancellationToken),
        "restart" => await RestartAsync(cancellationToken),
        "status" => await StatusAsync(cancellationToken),
        "doctor" => await DoctorAsync(cancellationToken),
        "autostart.enable" => await EnableAutostartAsync(cancellationToken),
        "autostart.disable" => await DisableAutostartAsync(cancellationToken),
        "autostart.status" => await AutostartStatusAsync(cancellationToken),
        "run.client" => await RunCustomClientAsync(parseResult, cancellationToken),
        "run.claude" => await RunKnownClientAsync(ClientKind.Claude, parseResult, cancellationToken),
        "run.codex" => await RunKnownClientAsync(ClientKind.Codex, parseResult, cancellationToken),
        "integrate.preview" => await PreviewIntegrationAsync(parseResult, cancellationToken),
        "integrate.apply" => await ApplyIntegrationAsync(parseResult, cancellationToken),
        "integrate.status" => await GetIntegrationStatusAsync(parseResult, cancellationToken),
        "integrate.unintegrate" => await UnintegrateAsync(parseResult, cancellationToken),
        "usage.today" => await ShowTodayUsageAsync(cancellationToken),
        "backup.create" => await CreateBackupAsync(parseResult, cancellationToken),
        "backup.inspect" => await InspectBackupAsync(parseResult, cancellationToken),
        "backup.restore" => await RestoreBackupAsync(parseResult, cancellationToken),
        "update.inspect" => await InspectUpdateAsync(parseResult, cancellationToken),
        "update.apply" => await ApplyUpdateAsync(parseResult, cancellationToken),
        _ => throw new InvalidOperationException($"Unknown command key '{commandKey}'."),
    };

    private async Task<CliCommandResult> InspectUpdateAsync(ParseResult result, CancellationToken token)
    {
        var inspection = await RequiredUpdate().Service.InspectAsync(
            Required(result, "--package"),
            result.GetValue<bool>("--allow-unsigned-development"),
            token);
        return Shown(
            UpdateInspectionData(inspection),
            $"Verified offline update candidate {inspection.Version}; no installation state was changed.",
            $"已验证离线更新候选 {inspection.Version}；未修改安装状态。");
    }

    private async Task<CliCommandResult> ApplyUpdateAsync(ParseResult result, CancellationToken token)
    {
        var applied = await RequiredUpdate().Service.ApplyAsync(new PackageUpdateRequest(
            Required(result, "--package"),
            Required(result, "--expected-manifest-sha256"),
            string.Equals(Required(result, "--confirm"), "UPDATE", StringComparison.Ordinal),
            result.GetValue<bool>("--allow-unsigned-development")), token);
        if (applied.CompletionPending)
        {
            return Changed(
                new
                {
                    applied.PreviousVersion,
                    candidateVersion = applied.CurrentVersion,
                    applied.ManifestSha256,
                    trustKind = applied.TrustKind == PackageTrustKind.Signed ? "signed" : "unsigned-development",
                    applied.KeyId,
                    completionPending = true,
                    applied.OperationId,
                    applied.ReceiptPath,
                },
                $"Scheduled Local AI Gateway update to {applied.CurrentVersion}; completion will be recorded in the receipt.",
                $"已安排 Local AI Gateway 更新到 {applied.CurrentVersion}；完成结果将写入收据。",
                showData: true);
        }
        return Changed(
            new
            {
                applied.PreviousVersion,
                applied.CurrentVersion,
                applied.ManifestSha256,
                trustKind = applied.TrustKind == PackageTrustKind.Signed ? "signed" : "unsigned-development",
                applied.KeyId,
                applied.DaemonWasRunning,
                applied.DaemonRunning,
                applied.RolledBack,
                completionPending = false,
            },
            $"Updated Local AI Gateway from {applied.PreviousVersion} to {applied.CurrentVersion}.",
            $"Local AI Gateway 已从 {applied.PreviousVersion} 更新到 {applied.CurrentVersion}。",
            showData: true);
    }

    private static object UpdateInspectionData(PackageUpdateInspection inspection) => new
    {
        inspection.PackageRoot,
        inspection.Version,
        inspection.ManifestSha256,
        trustKind = inspection.TrustKind == PackageTrustKind.Signed ? "signed" : "unsigned-development",
        inspection.KeyId,
        inspection.FileCount,
        applyPerformed = false,
    };

    private async Task<CliCommandResult> ShowTodayUsageAsync(CancellationToken token)
    {
        var services = RequiredUsage();
        var now = services.TimeProvider.GetUtcNow();
        var zone = services.TimeProvider.LocalTimeZone;
        var localNow = TimeZoneInfo.ConvertTime(now, zone);
        var localMidnight = new DateTime(
            localNow.Year,
            localNow.Month,
            localNow.Day,
            0,
            0,
            0,
            DateTimeKind.Unspecified);
        var startUtc = new DateTimeOffset(TimeZoneInfo.ConvertTimeToUtc(localMidnight, zone));
        var summary = await services.Reader.ReadAsync(startUtc, now, token);
        return Shown(
            summary,
            $"Today's token usage: {summary.Totals.TotalTokens}.",
            $"今日 Token 用量：{summary.Totals.TotalTokens}。");
    }

    private async Task<CliCommandResult> CreateBackupAsync(ParseResult result, CancellationToken token)
    {
        var includeSecrets = result.GetValue<bool>("--include-secrets");
        if (!includeSecrets && result.GetValue<bool>("--passphrase-stdin"))
        {
            throw new BackupException(
                "aigw_backup_passphrase_unexpected",
                "--passphrase-stdin requires --include-secrets when creating a backup.");
        }
        var passphrase = includeSecrets
            ? await ReadPassphraseAsync(result.GetValue<bool>("--passphrase-stdin"), token)
            : null;
        var created = await RequiredBackup().Coordinator.CreateAsync(new BackupCreateRequest(
            Required(result, "--output"),
            includeSecrets,
            passphrase), token);
        return Changed(
            BackupData(created),
            created.Encrypted ? "Created encrypted configuration and provider-credential backup." : "Created configuration backup without credentials.",
            created.Encrypted ? "已创建加密的配置和提供方凭据备份。" : "已创建不含凭据的配置备份。",
            showData: true);
    }

    private async Task<CliCommandResult> InspectBackupAsync(ParseResult result, CancellationToken token)
    {
        var input = Required(result, "--input");
        var inspected = await WithOptionalPassphraseAsync(
            result.GetValue<bool>("--passphrase-stdin"),
            passphrase => RequiredBackup().Coordinator.InspectAsync(
                new BackupInspectRequest(input, passphrase), token),
            token);
        return Shown(BackupData(inspected), "Backup inspected; no local state was changed.", "已检查备份；未修改本地状态。");
    }

    private async Task<CliCommandResult> RestoreBackupAsync(ParseResult result, CancellationToken token)
    {
        if (!long.TryParse(
            Required(result, "--expected-current-revision"),
            NumberStyles.None,
            CultureInfo.InvariantCulture,
            out var expectedRevision))
        {
            throw new BackupException("aigw_backup_revision_invalid", "The expected current revision is malformed.");
        }
        var input = Required(result, "--input");
        var expectedHash = Required(result, "--expected-sha256");
        var confirmed = string.Equals(Required(result, "--confirm"), "RESTORE", StringComparison.Ordinal);
        var restored = await WithOptionalPassphraseAsync(
            result.GetValue<bool>("--passphrase-stdin"),
            passphrase => RequiredBackup().Coordinator.RestoreAsync(new BackupRestoreRequest(
                input,
                expectedHash,
                expectedRevision,
                confirmed,
                passphrase), token),
            token);
        return Changed(
            new
            {
                backup = BackupData(restored.Backup),
                restored.PreviousRevision,
                restored.CurrentRevision,
                restored.SecretsRestored,
                confirmationConsumed = true,
            },
            "Backup restored atomically; unlisted credentials were retained.",
            "已原子恢复备份；未列入备份的凭据已保留。",
            showData: true);
    }

    private static object BackupData(BackupSummary summary) => new
    {
        summary.Path,
        summary.Sha256,
        summary.Encrypted,
        summary.CreatedUtc,
        summary.SourceRevision,
        summary.ProfileCount,
        summary.ProviderCount,
        summary.ModelCount,
        summary.SecretCount,
        runtimeCredentialIncluded = false,
    };

    private async Task<T> WithOptionalPassphraseAsync<T>(
        bool passphraseStdin,
        Func<string?, Task<T>> action,
        CancellationToken token)
    {
        if (passphraseStdin)
        {
            return await action(await ReadPassphraseAsync(fromStdin: true, token));
        }
        try
        {
            return await action(null);
        }
        catch (BackupException exception) when (exception.ErrorCode == "aigw_backup_passphrase_required")
        {
            return await action(await ReadPassphraseAsync(fromStdin: false, token));
        }
    }

    private async Task<CliCommandResult> GetIntegrationStatusAsync(
        ParseResult result,
        CancellationToken token)
    {
        var service = RequiredIntegrations().Lifecycle ?? throw new InvalidOperationException(
            "Client integration lifecycle services are not configured.");
        var client = ParseIntegrationClient(Required(result, "--client"));
        var status = await service.GetStatusAsync(new ClientIntegrationStatusRequest(
            client,
            Required(result, "--target")), token);
        var state = status.Status switch
        {
            ClientIntegrationStatusKind.Absent => "absent",
            ClientIntegrationStatusKind.NotIntegrated => "not-integrated",
            _ => "owned",
        };
        var action = status.Action.ToString().ToLowerInvariant();
        var owned = status.Status == ClientIntegrationStatusKind.Owned;
        return Changed(
            new
            {
                client = ClientName(client),
                status.TargetPath,
                state,
                exists = status.Status != ClientIntegrationStatusKind.Absent,
                owned,
                canUnintegrate = owned,
                action,
                status.BeforeSha256,
                status.AfterSha256,
                diff = status.ManagedDiff,
                applyPerformed = false,
                confirmationRequiredForUnintegrate = owned,
            },
            "Integration target status was inspected; no files were changed.",
            "已检查客户端集成目标状态；未修改任何文件。",
            showData: true);
    }

    private async Task<CliCommandResult> UnintegrateAsync(
        ParseResult result,
        CancellationToken token)
    {
        var service = RequiredIntegrations().Lifecycle ?? throw new InvalidOperationException(
            "Client integration lifecycle services are not configured.");
        var client = ParseIntegrationClient(Required(result, "--client"));
        var removed = await service.UnintegrateAsync(new ClientIntegrationUnintegrateRequest(
            client,
            Required(result, "--target"),
            Required(result, "--expected-before-sha256"),
            result.GetValue<string>("--expected-after-sha256"),
            result.GetValue<bool>("--expect-delete"),
            string.Equals(
                result.GetValue<string>("--confirm"),
                "UNINTEGRATE",
                StringComparison.Ordinal)), token);
        return Changed(
            new
            {
                client = ClientName(client),
                removed.TargetPath,
                action = removed.Action.ToString().ToLowerInvariant(),
                removed.Applied,
                removed.BackupPath,
                removed.BeforeSha256,
                removed.AfterSha256,
                confirmationConsumed = true,
            },
            "Owned client integration was removed atomically; the recovery backup was preserved.",
            "已原子移除工具拥有的客户端集成；恢复备份已保留。",
            showData: true);
    }

    private async Task<CliCommandResult> ApplyIntegrationAsync(
        ParseResult result,
        CancellationToken token)
    {
        var service = RequiredIntegrations().Applier ?? throw new InvalidOperationException(
            "Client integration apply services are not configured.");
        var client = ParseIntegrationClient(Required(result, "--client"));
        var applied = await service.ApplyAsync(new ClientIntegrationApplyRequest(
            client,
            Required(result, "--target"),
            Required(result, "--client-version"),
            result.GetValue<string>("--expected-before-sha256"),
            result.GetValue<bool>("--expect-absent"),
            Required(result, "--expected-after-sha256"),
            string.Equals(result.GetValue<string>("--confirm"), "APPLY", StringComparison.Ordinal),
            result.GetValue<string>("--host-version"),
            result.GetValue<string>("--wrapper")), token);
        var action = applied.Action.ToString().ToLowerInvariant();
        return Changed(
            new
            {
                client = ClientName(client),
                applied.TargetPath,
                action,
                applied.Applied,
                applied.BackupPath,
                applied.BeforeSha256,
                applied.AfterSha256,
                confirmationConsumed = true,
            },
            applied.Applied ? "Integration preview was applied atomically." : "Integration target already matches the confirmed preview.",
            applied.Applied ? "客户端集成预览已原子应用。" : "客户端集成目标已与确认的预览一致。",
            showData: true);
    }

    private async Task<CliCommandResult> PreviewIntegrationAsync(
        ParseResult result,
        CancellationToken token)
    {
        var service = RequiredIntegrations().Previewer;
        var sourcePath = result.GetValue<string>("--source");
        string? existingContent = null;
        if (sourcePath is not null)
        {
            try
            {
                if (!Path.IsPathFullyQualified(sourcePath) ||
                    !File.Exists(sourcePath) ||
                    (File.GetAttributes(sourcePath) & FileAttributes.ReparsePoint) != 0 ||
                    new FileInfo(sourcePath).Length > ClientIntegrationPreviewer.MaximumSourceCharacters * 4L)
                {
                    throw SourceInvalid();
                }
                existingContent = await ReadUtf8FixtureAsync(sourcePath, token);
            }
            catch (Exception exception) when (exception is
                IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
            {
                throw SourceInvalid();
            }
        }

        var client = ParseIntegrationClient(Required(result, "--client"));
        var preview = service.Preview(new ClientIntegrationPreviewRequest(
            client,
            Required(result, "--target"),
            existingContent,
            Required(result, "--client-version"),
            result.GetValue<string>("--host-version"),
            result.GetValue<string>("--wrapper")));
        var action = preview.Action.ToString().ToLowerInvariant();
        return Changed(
            new
            {
                client = ClientName(client),
                preview.TargetPath,
                action,
                preview.BeforeSha256,
                preview.AfterSha256,
                diff = preview.ManagedDiff,
                applyPerformed = false,
                confirmationRequiredForApply = true,
            },
            "Integration preview is ready; no files were changed.",
            "客户端集成预览已生成；未修改任何文件。",
            showData: true);

        static ClientIntegrationException SourceInvalid() => new(
            "aigw_integration_source_invalid",
            "The fixture source must be a readable fully qualified non-reparse file within the preview size limit.");

        static async Task<string> ReadUtf8FixtureAsync(string path, CancellationToken cancellationToken)
        {
            await using var input = new FileStream(
                path,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read,
                4096,
                FileOptions.Asynchronous | FileOptions.SequentialScan);
            var length = input.Length;
            if (length > ClientIntegrationPreviewer.MaximumSourceCharacters * 4L + 3)
            {
                throw SourceInvalid();
            }
            var bytes = new byte[checked((int)length)];
            await input.ReadExactlyAsync(bytes, cancellationToken);
            if (input.Length != length)
            {
                throw SourceInvalid();
            }
            ReadOnlySpan<byte> contentBytes = bytes;
            if (contentBytes.StartsWith(new byte[] { 0xEF, 0xBB, 0xBF }))
            {
                contentBytes = contentBytes[3..];
            }
            try
            {
                var content = new UTF8Encoding(
                    encoderShouldEmitUTF8Identifier: false,
                    throwOnInvalidBytes: true).GetString(contentBytes);
                if (content.Length > ClientIntegrationPreviewer.MaximumSourceCharacters)
                {
                    throw SourceInvalid();
                }
                return content;
            }
            catch (DecoderFallbackException)
            {
                throw SourceInvalid();
            }
        }
    }

    private static ClientIntegrationKind ParseIntegrationClient(string value) => value switch
    {
        "claude-vscode" => ClientIntegrationKind.ClaudeVsCode,
        "codex-cli" => ClientIntegrationKind.CodexCli,
        _ => throw new ClientIntegrationException(
            "aigw_integration_request_invalid",
            "The requested client integration is unknown."),
    };

    private static string ClientName(ClientIntegrationKind client) =>
        client == ClientIntegrationKind.ClaudeVsCode ? "claude-vscode" : "codex-cli";

    private async Task<CliCommandResult> RunKnownClientAsync(
        ClientKind client,
        ParseResult result,
        CancellationToken token)
    {
        var services = RequiredClients();
        var request = services.RequestFactory.CreateKnown(
            client,
            result.GetValue<string[]>("client-arguments") ?? [],
            WorkingDirectory(result));
        var exitCode = await services.Launcher.LaunchAsync(request, token);
        return ClientExit(exitCode);
    }

    private async Task<CliCommandResult> RunCustomClientAsync(
        ParseResult result,
        CancellationToken token)
    {
        var services = RequiredClients();
        var request = services.RequestFactory.CreateCustom(
            Required(result, "--client"),
            Required(result, "--base-url-env"),
            Required(result, "--token-env"),
            result.GetValue<string[]>("client-arguments") ?? [],
            WorkingDirectory(result));
        var exitCode = await services.Launcher.LaunchAsync(request, token);
        return ClientExit(exitCode);
    }

    private static string WorkingDirectory(ParseResult result) =>
        result.GetValue<string>("--working-directory") ?? Environment.CurrentDirectory;

    private static CliCommandResult ClientExit(int exitCode) => new(
        null,
        string.Empty,
        string.Empty,
        ExitCode: exitCode,
        SuppressOutput: true);

    private async Task<CliCommandResult> InstallAsync(ParseResult parsed, CancellationToken token)
    {
        var services = RequiredOperations();
        var enableAutostart = await ResolveInstallAutostartAsync(parsed, token);
        var outcome = await services.Installation.InstallAsync(
            services.CreateInstallPlan(),
            enableAutostart,
            token);
        var result = outcome.Installation;
        var autostart = outcome.Autostart;
        var shellIntegration = outcome.ShellIntegration;
        return Changed(
            new
            {
                result.Package.Installed,
                result.Package.AlreadyInstalled,
                result.Package.InstallRoot,
                result.RuntimeCredentialCreated,
                autostartEnabled = autostart.Status.Owned,
                autostartChanged = autostart.Changed,
                autostartIncomplete = autostart.Status.Incomplete,
                runtimeAutostart = autostart.Status.Runtime,
                trayAutostart = autostart.Status.Tray,
                shellIntegrationChanged = shellIntegration.Changed,
                userPath = shellIntegration.Status.UserPath,
                startMenu = shellIntegration.Status.StartMenu,
            },
            result.Package.Installed ? "Installed Local AI Gateway for the current user." : "Local AI Gateway is already installed.",
            result.Package.Installed ? "已为当前用户安装 Local AI Gateway。" : "Local AI Gateway 已安装。",
            showData: true);
    }

    private async Task<bool> ResolveInstallAutostartAsync(ParseResult parsed, CancellationToken token)
    {
        var explicitChoice = parsed.GetValue<string>("--autostart");
        if (explicitChoice is not null)
        {
            return explicitChoice.Equals("enable", StringComparison.Ordinal);
        }

        if (parsed.GetValue<bool>("--json"))
        {
            throw new InstallationException(
                "aigw_install_autostart_choice_required",
                "Non-interactive JSON installation requires '--autostart enable' or '--autostart disable'.");
        }

        while (true)
        {
            token.ThrowIfCancellationRequested();
            await promptWriter.WriteAsync("Enable Runtime and Tray login autostart? [Y/n] ");
            var answer = await stdin.ReadLineAsync(token);
            if (string.IsNullOrWhiteSpace(answer) ||
                answer.Equals("y", StringComparison.OrdinalIgnoreCase) ||
                answer.Equals("yes", StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }

            if (answer.Equals("n", StringComparison.OrdinalIgnoreCase) ||
                answer.Equals("no", StringComparison.OrdinalIgnoreCase))
            {
                return false;
            }

            await promptWriter.WriteLineAsync("Enter Y or N.");
        }
    }

    private async Task<CliCommandResult> UninstallAsync(ParseResult parsed, CancellationToken token)
    {
        if (uninstall is null)
        {
            return await LegacyUninstallAsync(token);
        }

        var choices = UninstallSelectionResolver.CategoryNames.ToDictionary(
            name => name,
            name => parsed.GetValue<string>("--" + name),
            StringComparer.Ordinal);
        var selection = await new UninstallSelectionResolver(stdin, promptWriter).ResolveAsync(
            parsed.GetValue<bool>("--non-interactive"),
            choices,
            parsed.GetValue<string>("--confirm"),
            token);
        var integrationTargets = new List<UninstallIntegrationTarget>();
        AddIntegrationTarget(integrationTargets, "claude-vscode", parsed.GetValue<string>("--claude-vscode-target"));
        AddIntegrationTarget(integrationTargets, "codex-cli", parsed.GetValue<string>("--codex-cli-target"));
        var backupPaths = parsed.GetValue<string[]>("--backup-path") ?? [];
        if (selection.Integrations == UninstallChoice.Remove && integrationTargets.Count == 0)
        {
            throw new UninstallException(
                "aigw_uninstall_integration_targets_required",
                "Removing integrations requires at least one explicit client target; uninstall never scans client configuration.");
        }
        if (selection.Integrations == UninstallChoice.Keep && integrationTargets.Count != 0)
        {
            throw new UninstallException(
                "aigw_uninstall_mode_conflict",
                "Integration targets must not be supplied when integrations are kept.");
        }
        if (selection.Backups == UninstallChoice.Keep && backupPaths.Length != 0)
        {
            throw new UninstallException(
                "aigw_uninstall_mode_conflict",
                "Backup paths must not be supplied when backups are kept.");
        }

        var result = await RequiredUninstall().Service.UninstallAsync(new UninstallRequest(
            selection,
            integrationTargets,
            backupPaths,
            Confirmed: true), token);
        return Changed(
            new
            {
                result.CompletionPending,
                result.OperationId,
                result.ReceiptPath,
                result.Program,
                result.Autostart,
                result.Integrations,
                result.RuntimeCredential,
                result.ProviderCredentials,
                result.Configuration,
                result.Usage,
                result.Logs,
                result.Backups,
            },
            result.CompletionPending
                ? "Scheduled complete uninstall; use the receipt path to verify completion."
                : "Completed the explicitly selected Local AI Gateway uninstall actions.",
            result.CompletionPending
                ? "已安排完整卸载；请使用回执路径验证完成状态。"
                : "已完成明确选择的 Local AI Gateway 卸载操作。",
            showData: true);
    }

    private async Task<CliCommandResult> LegacyUninstallAsync(CancellationToken token)
    {
        var services = RequiredOperations();
        if (IsSameOrDescendant(services.CommandBaseDirectory, services.Target.InstallRoot))
        {
            throw new InstallationException(
                "aigw_uninstall_running_from_install_root",
                "Run uninstall from the original extracted package so the installed executable is not in use.");
        }

        await services.Daemon.StopAsync(token);
        var result = await services.Installation.UninstallAsync(services.Target, token);
        if (!result.Package.Removed && !result.Package.AlreadyAbsent)
        {
            throw new InstallationException(
                "aigw_uninstall_incomplete",
                $"Uninstall preserved {result.Package.PreservedPaths.Count} unknown or modified path(s).");
        }

        return Changed(
            new
            {
                result.Package.Removed,
                result.Package.AlreadyAbsent,
                result.RuntimeCredentialDeleted,
                result.AutostartRemoved,
                result.ShellIntegrationRemoved,
            },
            result.Package.Removed ? "Uninstalled Local AI Gateway program files and runtime credential." : "Local AI Gateway is already absent.",
            result.Package.Removed ? "已卸载 Local AI Gateway 程序文件和运行时凭据。" : "Local AI Gateway 已不存在。",
            showData: true);
    }

    private static void AddIntegrationTarget(
        ICollection<UninstallIntegrationTarget> targets,
        string client,
        string? path)
    {
        if (path is not null)
        {
            targets.Add(new UninstallIntegrationTarget(client, path));
        }
    }

    private async Task<CliCommandResult> EnableAutostartAsync(CancellationToken token)
    {
        var services = RequiredOperations();
        var result = await services.Installation.EnableAutostartAsync(services.Target, token);
        return Changed(
            new
            {
                result.Changed,
                result.Status.TaskPath,
                result.Status.Registered,
                result.Status.Owned,
                result.Status.Conflict,
                result.Status.Incomplete,
                result.Status.Runtime,
                result.Status.Tray,
            },
            result.Changed ? "Enabled current-user login autostart." : "Current-user login autostart is already enabled.",
            result.Changed ? "已启用当前用户登录自启。" : "当前用户登录自启已启用。",
            showData: true);
    }

    private async Task<CliCommandResult> DisableAutostartAsync(CancellationToken token)
    {
        var services = RequiredOperations();
        var result = await services.Installation.DisableAutostartAsync(services.Target, token);
        return Changed(
            new
            {
                result.Changed,
                result.Status.TaskPath,
                result.Status.Registered,
                result.Status.Owned,
                result.Status.Conflict,
                result.Status.Incomplete,
                result.Status.Runtime,
                result.Status.Tray,
            },
            result.Changed ? "Disabled current-user login autostart." : "Current-user login autostart is already disabled.",
            result.Changed ? "已禁用当前用户登录自启。" : "当前用户登录自启已禁用。",
            showData: true);
    }

    private async Task<CliCommandResult> AutostartStatusAsync(CancellationToken token)
    {
        var services = RequiredOperations();
        var status = await services.Installation.GetAutostartStatusAsync(services.Target, token);
        return Shown(
            status,
            status.Owned
                ? "Current-user login autostart is enabled."
                : status.Conflict
                    ? "The fixed autostart task name is occupied by a different task."
                    : status.Incomplete
                        ? "Current-user login autostart is incomplete."
                    : "Current-user login autostart is disabled.",
            status.Owned
                ? "当前用户登录自启已启用。"
                : status.Conflict
                    ? "固定自启任务名已被其他定义占用。"
                    : status.Incomplete
                        ? "当前用户登录自启不完整。"
                    : "当前用户登录自启已禁用。");
    }

    private async Task<CliCommandResult> StartAsync(CancellationToken token)
    {
        var services = RequiredOperations();
        var result = await services.Daemon.StartAsync(services.Target, token);
        return LifecycleResult(result.Status, result.Changed, "Started Local AI Gateway.", "Local AI Gateway is already running.", "已启动 Local AI Gateway。", "Local AI Gateway 已在运行。");
    }

    private async Task<CliCommandResult> StopAsync(CancellationToken token)
    {
        var result = await RequiredOperations().Daemon.StopAsync(token);
        return LifecycleResult(result.Status, result.Changed, "Stopped Local AI Gateway.", "Local AI Gateway is already stopped.", "已停止 Local AI Gateway。", "Local AI Gateway 已停止。");
    }

    private async Task<CliCommandResult> RestartAsync(CancellationToken token)
    {
        var services = RequiredOperations();
        var result = await services.Daemon.RestartAsync(services.Target, token);
        return LifecycleResult(result.Status, true, "Restarted Local AI Gateway.", "Restarted Local AI Gateway.", "已重启 Local AI Gateway。", "已重启 Local AI Gateway。");
    }

    private async Task<CliCommandResult> StatusAsync(CancellationToken token)
    {
        var status = await RequiredOperations().Daemon.GetStatusAsync(token);
        return Shown(
            status,
            status.Running ? "Local AI Gateway is running." : "Local AI Gateway is stopped.",
            status.Running ? "Local AI Gateway 正在运行。" : "Local AI Gateway 已停止。");
    }

    private async Task<CliCommandResult> DoctorAsync(CancellationToken token)
    {
        var services = RequiredOperations();
        var status = await services.Daemon.GetStatusAsync(token);
        var installRootPresent = Directory.Exists(services.Target.InstallRoot);
        var packageManifestPresent = File.Exists(Path.Combine(
            services.Target.InstallRoot,
            PackageManifest.FileName));
        var runtimeExecutablePresent = File.Exists(services.Target.RuntimeExecutablePath);
        var configurationPresent = File.Exists(configuration.Paths.ConfigurationFile);
        var issues = new List<string>();
        if (!installRootPresent)
        {
            issues.Add("aigw_doctor_install_missing");
        }
        else
        {
            if (!packageManifestPresent)
            {
                issues.Add("aigw_doctor_package_manifest_missing");
            }

            if (!runtimeExecutablePresent)
            {
                issues.Add("aigw_doctor_runtime_missing");
            }
        }

        if (!configurationPresent)
        {
            issues.Add("aigw_doctor_configuration_missing");
        }

        if (status.TargetCircuits.Any(circuit => circuit.State is CircuitStates.Open or CircuitStates.HalfOpen))
        {
            issues.Add("aigw_doctor_target_circuit_open");
        }

        var data = new
        {
            healthy = issues.Count == 0,
            checks = new
            {
                installRootPresent,
                packageManifestPresent,
                runtimeExecutablePresent,
                configurationPresent,
                runtimeRunning = status.Running,
                targetCircuits = status.TargetCircuits,
            },
            issues,
            modelProbePerformed = false,
            upstreamContacted = false,
        };
        return Shown(
            data,
            issues.Count == 0 ? "Local diagnostics passed." : $"Local diagnostics found {issues.Count} issue(s).",
            issues.Count == 0 ? "本地诊断通过。" : $"本地诊断发现 {issues.Count} 个问题。");
    }

    private static CliCommandResult LifecycleResult(
        object status,
        bool changed,
        string changedEnglish,
        string unchangedEnglish,
        string changedChinese,
        string unchangedChinese) =>
        Changed(status, changed ? changedEnglish : unchangedEnglish, changed ? changedChinese : unchangedChinese, showData: true);

    private CliOperationalServices RequiredOperations() =>
        operations ?? throw new InvalidOperationException("Lifecycle services are not configured.");

    private CliClientServices RequiredClients() =>
        clients ?? throw new InvalidOperationException("Client launch services are not configured.");

    private CliIntegrationServices RequiredIntegrations() =>
        integrations ?? throw new InvalidOperationException("Client integration services are not configured.");

    private CliUsageServices RequiredUsage() =>
        usage ?? throw new InvalidOperationException("Usage services are not configured.");

    private CliUpdateServices RequiredUpdate() =>
        update ?? throw new InvalidOperationException("Update services are not configured.");

    private static bool IsSameOrDescendant(string candidatePath, string rootPath)
    {
        var candidate = Path.GetFullPath(candidatePath).TrimEnd(
            Path.DirectorySeparatorChar,
            Path.AltDirectorySeparatorChar);
        var root = Path.GetFullPath(rootPath).TrimEnd(
            Path.DirectorySeparatorChar,
            Path.AltDirectorySeparatorChar);
        return string.Equals(candidate, root, StringComparison.OrdinalIgnoreCase) ||
               candidate.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
    }

    private async Task<CliCommandResult> CreateProfileAsync(ParseResult result, CancellationToken token)
    {
        var id = Required(result, "--id");
        var saved = await configuration.CreateProfileAsync(id, Required(result, "--name"), token);
        return Changed(new { id, revision = saved.Revision }, $"Created profile '{id}'.", $"已创建配置档案“{id}”。");
    }

    private async Task<CliCommandResult> ListProfilesAsync(CancellationToken token)
    {
        var loaded = await configuration.LoadAsync(token);
        var data = loaded.Profiles.Select(profile => new
        {
            profile.Id,
            profile.Name,
            active = string.Equals(loaded.ActiveProfileId, profile.Id, StringComparison.OrdinalIgnoreCase),
            complete = ConfigurationValidator.IsActivatable(profile),
        }).ToArray();
        return Shown(data, $"Profiles: {data.Length}.", $"配置档案：{data.Length} 个。");
    }

    private async Task<CliCommandResult> ShowProfileAsync(ParseResult result, CancellationToken token)
    {
        var loaded = await configuration.LoadAsync(token);
        var profile = GatewayConfigurationManager.FindProfile(loaded, Required(result, "--id"));
        return Shown(profile, $"Profile '{profile.Id}'.", $"配置档案“{profile.Id}”。");
    }

    private async Task<CliCommandResult> UseProfileAsync(ParseResult result, CancellationToken token)
    {
        var id = Required(result, "--id");
        var saved = await configuration.UseProfileAsync(id, token);
        return Changed(new { id, revision = saved.Revision }, $"Activated profile '{id}'.", $"已激活配置档案“{id}”。");
    }

    private async Task<CliCommandResult> DeleteProfileAsync(ParseResult result, CancellationToken token)
    {
        var id = Required(result, "--id");
        var deleteSecrets = result.GetValue<bool>("--delete-secrets");
        var before = await configuration.LoadAsync(token);
        var targets = GatewayConfigurationManager.FindProfile(before, id).Providers
            .Select(provider => provider.CredentialTarget)
            .ToArray();
        var saved = await configuration.DeleteProfileAsync(id, deleteSecrets, token);
        return Changed(
            new
            {
                id,
                revision = saved.Revision,
                secretsDeleted = deleteSecrets,
                credentialTargetsRetained = deleteSecrets ? Array.Empty<string>() : targets,
            },
            deleteSecrets
                ? $"Deleted profile '{id}' and its provider credentials."
                : $"Deleted profile '{id}'. Provider credentials were retained.",
            deleteSecrets
                ? $"已删除配置档案“{id}”及其提供方凭据。"
                : $"已删除配置档案“{id}”；提供方凭据已保留。",
            showData: !deleteSecrets && targets.Length > 0);
    }

    private async Task<CliCommandResult> AddProviderAsync(ParseResult result, CancellationToken token)
    {
        var profileId = Required(result, "--profile");
        var id = Required(result, "--id");
        ProviderTypes.TryParse(Required(result, "--type"), out var type);
        var provider = new ProviderConfiguration
        {
            Id = id,
            Name = Required(result, "--name"),
            Type = type,
            Endpoint = Required(result, "--endpoint"),
            CredentialTarget = CredentialTargets.UpstreamApiKey(profileId, id),
        };
        var saved = await configuration.AddProviderAsync(profileId, provider, token);
        return Changed(new { profileId, provider, revision = saved.Revision }, $"Added provider '{id}'.", $"已添加提供方“{id}”。");
    }

    private async Task<CliCommandResult> ListProvidersAsync(ParseResult result, CancellationToken token)
    {
        var loaded = await configuration.LoadAsync(token);
        var profile = GatewayConfigurationManager.FindProfile(loaded, Required(result, "--profile"));
        return Shown(profile.Providers, $"Providers: {profile.Providers.Count}.", $"提供方：{profile.Providers.Count} 个。");
    }

    private async Task<CliCommandResult> ShowProviderAsync(ParseResult result, CancellationToken token)
    {
        var loaded = await configuration.LoadAsync(token);
        var profile = GatewayConfigurationManager.FindProfile(loaded, Required(result, "--profile"));
        var provider = GatewayConfigurationManager.FindProvider(profile, Required(result, "--id"));
        return Shown(provider, $"Provider '{provider.Id}'.", $"提供方“{provider.Id}”。");
    }

    private async Task<CliCommandResult> UpdateProviderAsync(ParseResult result, CancellationToken token)
    {
        var profileId = Required(result, "--profile");
        var id = Required(result, "--id");
        ProviderType? type = null;
        var typeText = result.GetValue<string>("--type");
        if (typeText is not null)
        {
            ProviderTypes.TryParse(typeText, out var parsedType);
            type = parsedType;
        }
        var saved = await configuration.UpdateProviderAsync(
            profileId,
            id,
            result.GetValue<string>("--name"),
            type,
            result.GetValue<string>("--endpoint"),
            token);
        return Changed(new { profileId, id, revision = saved.Revision }, $"Updated provider '{id}'.", $"已更新提供方“{id}”。");
    }

    private async Task<CliCommandResult> SetProviderSecretAsync(ParseResult result, CancellationToken token)
    {
        var profileId = Required(result, "--profile");
        var providerId = Required(result, "--id");
        var secret = await ReadSecretAsync(result.GetValue<bool>("--secret-stdin"), token);
        await configuration.SetProviderSecretAsync(profileId, providerId, secret, token);
        var target = CredentialTargets.UpstreamApiKey(profileId, providerId);
        return Changed(new { profileId, providerId, credentialTarget = target }, "Stored provider credential.", "已保存提供方凭据。");
    }

    private async Task<CliCommandResult> RemoveProviderAsync(ParseResult result, CancellationToken token)
    {
        var profileId = Required(result, "--profile");
        var providerId = Required(result, "--id");
        var deleteSecret = result.GetValue<bool>("--delete-secret");
        var target = CredentialTargets.UpstreamApiKey(profileId, providerId);
        var saved = await configuration.RemoveProviderAsync(profileId, providerId, deleteSecret, token);
        return Changed(
            new
            {
                profileId,
                providerId,
                revision = saved.Revision,
                secretDeleted = deleteSecret,
                credentialTargetRetained = deleteSecret ? null : target,
            },
            deleteSecret ? $"Removed provider '{providerId}' and its credential." : $"Removed provider '{providerId}'. Credential was retained.",
            deleteSecret ? $"已移除提供方“{providerId}”及其凭据。" : $"已移除提供方“{providerId}”；凭据已保留。",
            showData: !deleteSecret);
    }

    private async Task<CliCommandResult> AddModelAsync(ParseResult result, CancellationToken token)
    {
        var profileId = Required(result, "--profile");
        var alias = Required(result, "--alias");
        var saved = await configuration.AddModelAsync(
            profileId,
            new ModelConfiguration
            {
                Alias = alias,
                ProviderId = Required(result, "--provider"),
                UpstreamModel = Required(result, "--upstream"),
            },
            result.GetValue<bool>("--default"),
            token);
        return Changed(new { profileId, alias, revision = saved.Revision }, $"Added model alias '{alias}'.", $"已添加模型别名“{alias}”。");
    }

    private async Task<CliCommandResult> ListModelsAsync(ParseResult result, CancellationToken token)
    {
        var loaded = await configuration.LoadAsync(token);
        var profile = GatewayConfigurationManager.FindProfile(loaded, Required(result, "--profile"));
        return Shown(profile.Models, $"Models: {profile.Models.Count}.", $"模型：{profile.Models.Count} 个。");
    }

    private async Task<CliCommandResult> ShowModelAsync(ParseResult result, CancellationToken token)
    {
        var loaded = await configuration.LoadAsync(token);
        var profile = GatewayConfigurationManager.FindProfile(loaded, Required(result, "--profile"));
        var model = GatewayConfigurationManager.FindModel(profile, Required(result, "--alias"));
        return Shown(model, $"Model alias '{model.Alias}'.", $"模型别名“{model.Alias}”。");
    }

    private async Task<CliCommandResult> UpdateModelAsync(ParseResult result, CancellationToken token)
    {
        var profileId = Required(result, "--profile");
        var alias = Required(result, "--alias");
        var saved = await configuration.UpdateModelAsync(
            profileId,
            alias,
            result.GetValue<string>("--new-alias"),
            result.GetValue<string>("--provider"),
            result.GetValue<string>("--upstream"),
            token);
        return Changed(new { profileId, alias, revision = saved.Revision }, $"Updated model alias '{alias}'.", $"已更新模型别名“{alias}”。");
    }

    private async Task<CliCommandResult> RemoveModelAsync(ParseResult result, CancellationToken token)
    {
        var profileId = Required(result, "--profile");
        var alias = Required(result, "--alias");
        var saved = await configuration.RemoveModelAsync(profileId, alias, token);
        return Changed(new { profileId, alias, revision = saved.Revision }, $"Removed model alias '{alias}'.", $"已移除模型别名“{alias}”。");
    }

    private async Task<CliCommandResult> SetDefaultModelAsync(ParseResult result, CancellationToken token)
    {
        var profileId = Required(result, "--profile");
        var alias = Required(result, "--alias");
        var saved = await configuration.SetDefaultModelAsync(profileId, alias, token);
        return Changed(new { profileId, alias, revision = saved.Revision }, $"Set default model '{alias}'.", $"已将“{alias}”设为默认模型。");
    }

    private async Task<CliCommandResult> AddModelFallbackAsync(ParseResult result, CancellationToken token)
    {
        var profileId = Required(result, "--profile");
        var alias = Required(result, "--alias");
        var providerId = Required(result, "--provider");
        var saved = await configuration.AddModelFallbackAsync(
            profileId,
            alias,
            new ModelFallbackConfiguration
            {
                ProviderId = providerId,
                UpstreamModel = Required(result, "--upstream"),
            },
            token);
        return Changed(
            new { profileId, alias, providerId, revision = saved.Revision },
            $"Added secondary provider '{providerId}' to '{alias}'.",
            $"已为“{alias}”追加次要目标提供方“{providerId}”。");
    }

    private async Task<CliCommandResult> RemoveModelFallbackAsync(ParseResult result, CancellationToken token)
    {
        var profileId = Required(result, "--profile");
        var alias = Required(result, "--alias");
        var providerId = Required(result, "--provider");
        var saved = await configuration.RemoveModelFallbackAsync(profileId, alias, providerId, token);
        return Changed(
            new { profileId, alias, providerId, revision = saved.Revision },
            $"Removed secondary provider '{providerId}' from '{alias}'.",
            $"已从“{alias}”移除次要目标提供方“{providerId}”。");
    }

    private async Task<CliCommandResult> SetModelRoutingStrategyAsync(ParseResult result, CancellationToken token)
    {
        var profileId = Required(result, "--profile");
        var alias = Required(result, "--alias");
        ModelRoutingStrategies.TryParse(Required(result, "--strategy"), out var strategy);
        var saved = await configuration.SetModelRoutingStrategyAsync(profileId, alias, strategy, token);
        return Changed(
            new { profileId, alias, strategy = strategy.ToContractValue(), revision = saved.Revision },
            $"Set routing strategy for '{alias}' to '{strategy.ToContractValue()}'.",
            $"已将“{alias}”的路由策略设为“{strategy.ToContractValue()}”。");
    }

    private async Task<CliCommandResult> SetModelTargetWeightAsync(ParseResult result, CancellationToken token)
    {
        var profileId = Required(result, "--profile");
        var alias = Required(result, "--alias");
        var providerId = Required(result, "--provider");
        var weight = result.GetValue<int>("--weight");
        var saved = await configuration.SetModelTargetWeightAsync(
            profileId,
            alias,
            providerId,
            weight,
            token);
        return Changed(
            new { profileId, alias, providerId, weight, revision = saved.Revision },
            $"Set target weight for provider '{providerId}' on '{alias}' to {weight}.",
            $"已将“{alias}”中提供方“{providerId}”的目标权重设为 {weight}。");
    }

    private async Task<CliCommandResult> SetProfileLimitsAsync(ParseResult result, CancellationToken token)
    {
        var profileId = Required(result, "--profile");
        var limits = ParseLimits(result);
        var saved = await configuration.SetProfileLimitsAsync(profileId, limits, token);
        return Changed(
            new { profileId, limits, revision = saved.Revision },
            $"Replaced request limits for profile '{profileId}'.",
            $"已替换 Profile“{profileId}”的请求限制。");
    }

    private async Task<CliCommandResult> ClearProfileLimitsAsync(ParseResult result, CancellationToken token)
    {
        var profileId = Required(result, "--profile");
        var saved = await configuration.SetProfileLimitsAsync(profileId, null, token);
        return Changed(
            new { profileId, revision = saved.Revision },
            $"Cleared request limits for profile '{profileId}'.",
            $"已清除 Profile“{profileId}”的请求限制。");
    }

    private async Task<CliCommandResult> SetProviderLimitsAsync(ParseResult result, CancellationToken token)
    {
        var profileId = Required(result, "--profile");
        var providerId = Required(result, "--provider");
        var limits = ParseLimits(result);
        var saved = await configuration.SetProviderLimitsAsync(profileId, providerId, limits, token);
        return Changed(
            new { profileId, providerId, limits, revision = saved.Revision },
            $"Replaced request limits for provider '{providerId}'.",
            $"已替换提供方“{providerId}”的请求限制。");
    }

    private async Task<CliCommandResult> ClearProviderLimitsAsync(ParseResult result, CancellationToken token)
    {
        var profileId = Required(result, "--profile");
        var providerId = Required(result, "--provider");
        var saved = await configuration.SetProviderLimitsAsync(profileId, providerId, null, token);
        return Changed(
            new { profileId, providerId, revision = saved.Revision },
            $"Cleared request limits for provider '{providerId}'.",
            $"已清除提供方“{providerId}”的请求限制。");
    }

    private async Task<CliCommandResult> SetModelLimitsAsync(ParseResult result, CancellationToken token)
    {
        var profileId = Required(result, "--profile");
        var alias = Required(result, "--alias");
        var limits = ParseLimits(result);
        var saved = await configuration.SetModelLimitsAsync(profileId, alias, limits, token);
        return Changed(
            new { profileId, alias, limits, revision = saved.Revision },
            $"Replaced request limits for model '{alias}'.",
            $"已替换模型“{alias}”的请求限制。");
    }

    private async Task<CliCommandResult> ClearModelLimitsAsync(ParseResult result, CancellationToken token)
    {
        var profileId = Required(result, "--profile");
        var alias = Required(result, "--alias");
        var saved = await configuration.SetModelLimitsAsync(profileId, alias, null, token);
        return Changed(
            new { profileId, alias, revision = saved.Revision },
            $"Cleared request limits for model '{alias}'.",
            $"已清除模型“{alias}”的请求限制。");
    }

    private static RequestLimitConfiguration ParseLimits(ParseResult result)
    {
        var limits = new RequestLimitConfiguration
        {
            MaxConcurrentRequests = result.GetValue<int?>("--concurrency"),
            RequestsPerMinute = result.GetValue<int?>("--rpm"),
            TokensPerMinute = result.GetValue<long?>("--tpm"),
        };
        if (limits.MaxConcurrentRequests is null &&
            limits.RequestsPerMinute is null &&
            limits.TokensPerMinute is null)
        {
            throw new ConfigurationException(
                "aigw_limits_values_required",
                "At least one request limit must be specified.");
        }

        return limits;
    }

    private async Task<CliCommandResult> ShowConfigurationAsync(CancellationToken token)
    {
        var loaded = await configuration.LoadAsync(token);
        return Shown(loaded, "Configuration (secrets excluded).", "配置（不含密钥）。");
    }

    private CliCommandResult ShowConfigurationPath()
    {
        var data = new
        {
            root = configuration.Paths.RootDirectory,
            configuration = configuration.Paths.ConfigurationFile,
            backup = configuration.Paths.BackupFile,
        };
        return Shown(data, "Configuration paths.", "配置路径。");
    }

    private async Task<CliCommandResult> ValidateConfigurationAsync(CancellationToken token)
    {
        var loaded = await configuration.LoadAsync(token);
        return Changed(
            new { valid = true, schemaVersion = loaded.SchemaVersion, revision = loaded.Revision },
            "Configuration is valid.",
            "配置有效。");
    }

    private async Task<string> ReadSecretAsync(bool secretStdin, CancellationToken token)
    {
        if (secretStdin)
        {
            var line = await stdin.ReadLineAsync(token);
            return line ?? throw new CredentialException(
                "aigw_credential_input_missing",
                "Standard input ended before a secret was read.");
        }

        if (!ReferenceEquals(stdin, Console.In) || Console.IsInputRedirected)
        {
            throw new CredentialException(
                "aigw_credential_secret_stdin_required",
                "Use --secret-stdin for redirected or non-interactive input.");
        }

        await promptWriter.WriteAsync("Secret: ");
        var builder = new StringBuilder();
        while (true)
        {
            token.ThrowIfCancellationRequested();
            var key = Console.ReadKey(intercept: true);
            if (key.Key == ConsoleKey.Enter)
            {
                await promptWriter.WriteLineAsync();
                return builder.ToString();
            }

            if (key.Key == ConsoleKey.Backspace && builder.Length > 0)
            {
                builder.Length--;
            }
            else if (!char.IsControl(key.KeyChar))
            {
                builder.Append(key.KeyChar);
            }
        }
    }

    private async Task<string> ReadPassphraseAsync(bool fromStdin, CancellationToken token)
    {
        if (fromStdin)
        {
            var line = await stdin.ReadLineAsync(token);
            return line ?? throw new BackupException(
                "aigw_backup_passphrase_input_missing",
                "Standard input ended before a backup passphrase was read.");
        }
        if (!ReferenceEquals(stdin, Console.In) || Console.IsInputRedirected)
        {
            throw new BackupException(
                "aigw_backup_passphrase_stdin_required",
                "Use --passphrase-stdin for redirected or non-interactive input.");
        }
        await promptWriter.WriteAsync("Backup passphrase: ");
        var builder = new StringBuilder();
        while (true)
        {
            token.ThrowIfCancellationRequested();
            var key = Console.ReadKey(intercept: true);
            if (key.Key == ConsoleKey.Enter)
            {
                await promptWriter.WriteLineAsync();
                return builder.ToString();
            }
            if (key.Key == ConsoleKey.Backspace && builder.Length > 0)
            {
                builder.Length--;
            }
            else if (!char.IsControl(key.KeyChar))
            {
                builder.Append(key.KeyChar);
            }
        }
    }

    private static string Required(ParseResult result, string optionName) =>
        result.GetValue<string>(optionName)
        ?? throw new InvalidOperationException($"Required option '{optionName}' was not parsed.");

    private CliBackupServices RequiredBackup() => backup ?? throw new InvalidOperationException(
        "Backup services are not configured.");

    private CliUninstallServices RequiredUninstall() => uninstall ?? throw new InvalidOperationException(
        "Complete uninstall services are not configured.");

    private static CliCommandResult Changed(object data, string english, string chinese, bool showData = false) =>
        new(data, english, chinese, showData);

    private static CliCommandResult Shown(object data, string english, string chinese) =>
        new(data, english, chinese, ShowDataInHumanOutput: true);
}
