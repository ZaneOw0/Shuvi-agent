using System.CommandLine;

namespace LocalAIGateway.Cli;

internal static class CliHelp
{
    public static async Task WriteAsync(
        TextWriter output,
        bool json,
        CliApplication.UiLanguage language,
        CommandLineDefinition definition,
        Command selectedCommand,
        string? commandKey)
    {
        var path = GetCommandPath(definition.Root, selectedCommand);
        var subcommands = selectedCommand.Subcommands.Select(command => command.Name).ToArray();
        var rootCommands = definition.Root.Subcommands.Select(command => command.Name).ToArray();
        var commandOptions = selectedCommand.Options.Select(option => option.Name).ToArray();
        var usage = Usage(commandKey, path, subcommands.Length > 0);
        if (json)
        {
            await output.WriteLineAsync(System.Text.Json.JsonSerializer.Serialize(
                new
                {
                    schemaVersion = CliApplication.JsonSchemaVersion,
                    ok = true,
                    command = "help",
                    data = new
                    {
                        product = CliApplication.ProductName,
                        usage,
                        commands = rootCommands,
                        subcommands,
                        options = commandOptions,
                        globalOptions = new[]
                        {
                            "--help",
                            "--version",
                            "--json",
                            "--lang <en|zh-CN>",
                            "--no-color",
                            "--verbose",
                        },
                    },
                },
                CliApplication.JsonOptions));
            return;
        }

        await output.WriteLineAsync(CliApplication.ProductName);
        await output.WriteLineAsync(CliApplication.Localize(
            language,
            "Private Windows local AI gateway.",
            "Windows 私有本地 AI 网关。"));
        await output.WriteLineAsync();
        await output.WriteLineAsync(CliApplication.Localize(language, "Usage:", "用法："));
        await output.WriteLineAsync($"  {usage}");
        if (commandKey == "install")
        {
            await output.WriteLineAsync();
            await output.WriteLineAsync(CliApplication.Localize(
                language,
                "Install behavior: add the install root to user PATH and create the Tray Start Menu shortcut.",
                "安装行为：将安装根加入当前用户 PATH，并创建 Tray 开始菜单快捷方式。"));
        }
        if (subcommands.Length > 0)
        {
            await output.WriteLineAsync();
            await output.WriteLineAsync(ReferenceEquals(selectedCommand, definition.Root)
                ? CliApplication.Localize(language, "Command families:", "命令族：")
                : CliApplication.Localize(language, "Subcommands:", "子命令："));
            foreach (var command in subcommands)
            {
                await output.WriteLineAsync($"  {command}");
            }
        }
        if (!ReferenceEquals(selectedCommand, definition.Root) && commandOptions.Length > 0)
        {
            await output.WriteLineAsync();
            await output.WriteLineAsync(CliApplication.Localize(language, "Command options:", "命令选项："));
            foreach (var option in selectedCommand.Options)
            {
                var required = option.Required
                    ? CliApplication.Localize(language, " (required)", "（必填）")
                    : string.Empty;
                await output.WriteLineAsync($"  {option.Name,-32} {option.Description}{required}");
            }
        }
        await output.WriteLineAsync();
        await output.WriteLineAsync(CliApplication.Localize(language, "Global options:", "全局选项："));
        await output.WriteLineAsync($"  --help        {CliApplication.Localize(language, "Show help.", "显示帮助。")}");
        await output.WriteLineAsync($"  --version     {CliApplication.Localize(language, "Show version.", "显示版本。")}");
        await output.WriteLineAsync($"  --json        {CliApplication.Localize(language, "Write stable JSON output.", "输出稳定的 JSON。")}");
        await output.WriteLineAsync($"  --lang <lang> {CliApplication.Localize(language, "Set language: en or zh-CN.", "设置语言：en 或 zh-CN。")}");
        await output.WriteLineAsync($"  --no-color    {CliApplication.Localize(language, "Disable color output.", "禁用彩色输出。")}");
        await output.WriteLineAsync($"  --verbose     {CliApplication.Localize(language, "Enable diagnostic details.", "启用诊断详情。")}");
    }

    private static string[] GetCommandPath(Command root, Command selectedCommand)
    {
        var path = new List<string>();
        if (!FindCommand(root, selectedCommand, path))
        {
            throw new InvalidOperationException("The selected command is not registered in the command tree.");
        }

        return [.. path];
    }

    private static bool FindCommand(Command current, Command selectedCommand, List<string> path)
    {
        if (ReferenceEquals(current, selectedCommand))
        {
            return true;
        }

        foreach (var child in current.Subcommands)
        {
            path.Add(child.Name);
            if (FindCommand(child, selectedCommand, path))
            {
                return true;
            }
            path.RemoveAt(path.Count - 1);
        }

        return false;
    }

    private static string Usage(string? commandKey, string[] path, bool hasSubcommands) => commandKey switch
    {
        "profile.create" => "aigw profile create --id <id> --name <name> [global options]",
        "profile.show" or "profile.use" or "profile.delete" => $"aigw {commandKey.Replace('.', ' ')} --id <id> [options]",
        "provider.add" => "aigw provider add --profile <id> --id <id> --name <name> --type <type> --endpoint <uri> [global options]",
        "provider.set-secret" => "aigw provider set-secret --profile <id> --id <id> [--secret-stdin] [global options]",
        "model.add" => "aigw model add --profile <id> --alias <alias> --provider <id> --upstream <name> [--default]",
        "model.fallback-add" => "aigw model fallback-add --profile <id> --alias <alias> --provider <id> --upstream <name>",
        "model.fallback-remove" => "aigw model fallback-remove --profile <id> --alias <alias> --provider <id>",
        "model.routing-set" => "aigw model routing-set --profile <id> --alias <alias> --strategy <ordered-fallback|weighted-round-robin>",
        "model.weight-set" => "aigw model weight-set --profile <id> --alias <alias> --provider <id> --weight <1-100>",
        "limits.profile-set" => "aigw limits profile set --profile <id> [--concurrency <n>] [--rpm <n>] [--tpm <n>]",
        "limits.profile-clear" => "aigw limits profile clear --profile <id>",
        "limits.provider-set" => "aigw limits provider set --profile <id> --provider <id> [--concurrency <n>] [--rpm <n>] [--tpm <n>]",
        "limits.provider-clear" => "aigw limits provider clear --profile <id> --provider <id>",
        "limits.model-set" => "aigw limits model set --profile <id> --alias <alias> [--concurrency <n>] [--rpm <n>] [--tpm <n>]",
        "limits.model-clear" => "aigw limits model clear --profile <id> --alias <alias>",
        "run.claude" => "aigw run claude [--working-directory <absolute-path>] -- [client arguments]",
        "run.codex" => "aigw run codex [--working-directory <absolute-path>] -- [client arguments]",
        "run.client" => "aigw run --client <absolute-path> --base-url-env <name> --token-env <name> [--working-directory <absolute-path>] -- [client arguments]",
        "integrate.preview" => "aigw integrate preview --client <claude-vscode|codex-cli> --target <absolute-path> --client-version <x.y.z> [--source <fixture>] [--host-version <x.y.z>] [--wrapper <absolute-path>]",
        "integrate.apply" => "aigw integrate apply --client <claude-vscode|codex-cli> --target <absolute-path> --client-version <x.y.z> (--expected-before-sha256 <hash>|--expect-absent) --expected-after-sha256 <hash> --confirm APPLY [client options]",
        "integrate.status" => "aigw integrate status --client <claude-vscode|codex-cli> --target <absolute-path>",
        "integrate.unintegrate" => "aigw integrate unintegrate --client <claude-vscode|codex-cli> --target <absolute-path> --expected-before-sha256 <hash> (--expected-after-sha256 <hash>|--expect-delete) --confirm UNINTEGRATE",
        "usage.today" => "aigw usage today [global options]",
        "backup.create" => "aigw backup create --output <absolute-path> [--include-secrets] [--passphrase-stdin]",
        "backup.inspect" => "aigw backup inspect --input <absolute-path> [--passphrase-stdin]",
        "backup.restore" => "aigw backup restore --input <absolute-path> --expected-sha256 <hash> --expected-current-revision <revision> --confirm RESTORE [--passphrase-stdin]",
        "install" => "aigw install [--autostart <enable|disable>] [global options]",
        "uninstall" => "aigw uninstall [--non-interactive --program <keep|remove> ... --backups <keep|remove> --confirm UNINSTALL] [explicit targets]",
        null when path.Length == 0 => "aigw [options]",
        null when hasSubcommands => $"aigw {string.Join(' ', path)} <command> [options]",
        _ => $"aigw {string.Join(' ', path)} [options]",
    };
}
