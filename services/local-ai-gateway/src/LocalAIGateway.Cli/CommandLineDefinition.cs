using System.CommandLine;

namespace LocalAIGateway.Cli;

internal sealed class CommandLineDefinition
{
    private readonly Dictionary<Command, string> commandKeys = new();

    private CommandLineDefinition(
        RootCommand root,
        Option<bool> helpOption,
        Option<bool> versionOption,
        Option<bool> jsonOption,
        Option<string> languageOption,
        Option<bool> noColorOption,
        Option<bool> verboseOption)
    {
        Root = root;
        HelpOption = helpOption;
        VersionOption = versionOption;
        JsonOption = jsonOption;
        LanguageOption = languageOption;
        NoColorOption = noColorOption;
        VerboseOption = verboseOption;
    }

    public RootCommand Root { get; }
    public Option<bool> HelpOption { get; }
    public Option<bool> VersionOption { get; }
    public Option<bool> JsonOption { get; }
    public Option<string> LanguageOption { get; }
    public Option<bool> NoColorOption { get; }
    public Option<bool> VerboseOption { get; }

    public string? GetCommandKey(Command command) => commandKeys.GetValueOrDefault(command);

    public static CommandLineDefinition Create()
    {
        var root = new RootCommand("Private Windows local AI gateway.");
        root.SetAction(_ => 0);
        foreach (var builtInOption in root.Options.ToArray())
        {
            root.Options.Remove(builtInOption);
        }

        var help = Flag("--help", "Show help.", recursive: true, aliases: ["-h"]);
        var version = Flag("--version", "Show version.", recursive: true);
        var json = Flag("--json", "Write stable JSON output.", recursive: true);
        var language = Text("--lang", "Set language: en or zh-CN.", recursive: true);
        language.AcceptOnlyFromAmong("en", "zh", "zh-CN");
        var noColor = Flag("--no-color", "Disable color output.", recursive: true);
        var verbose = Flag("--verbose", "Enable diagnostic details.", recursive: true);
        root.Options.Add(help);
        root.Options.Add(version);
        root.Options.Add(json);
        root.Options.Add(language);
        root.Options.Add(noColor);
        root.Options.Add(verbose);

        var definition = new CommandLineDefinition(root, help, version, json, language, noColor, verbose);
        definition.AddProfileCommands();
        definition.AddProviderCommands();
        definition.AddModelCommands();
        definition.AddLimitCommands();
        definition.AddConfigCommands();
        definition.AddLifecycleCommands();
        definition.AddRunCommands();
        definition.AddIntegrationCommands();
        definition.AddUsageCommands();
        definition.AddBackupCommands();
        definition.AddUpdateCommands();
        return definition;
    }

    private void AddProfileCommands()
    {
        var group = new Command("profile", "Manage isolated profiles.");
        group.SetAction(_ => 0);
        Root.Subcommands.Add(group);
        Register(group, "profile.create", "create", "Create a draft profile.",
            Text("--id", "Profile ID.", required: true),
            Text("--name", "Display name.", required: true));
        Register(group, "profile.list", "list", "List profiles.");
        Register(group, "profile.show", "show", "Show a profile.",
            Text("--id", "Profile ID.", required: true));
        Register(group, "profile.use", "use", "Activate a complete profile.",
            Text("--id", "Profile ID.", required: true));
        Register(group, "profile.delete", "delete", "Delete a profile.",
            Text("--id", "Profile ID.", required: true),
            Flag("--delete-secrets", "Also delete provider credentials."));
    }

    private void AddProviderCommands()
    {
        var group = new Command("provider", "Manage providers within a profile.");
        group.SetAction(_ => 0);
        Root.Subcommands.Add(group);
        var type = Text("--type", "Provider type.", required: true);
        type.AcceptOnlyFromAmong("openai-compatible", "anthropic", "azure-openai", "local-endpoint");
        Register(group, "provider.add", "add", "Add a provider.",
            Text("--profile", "Profile ID.", required: true),
            Text("--id", "Provider ID.", required: true),
            Text("--name", "Display name.", required: true),
            type,
            Text("--endpoint", "Provider base endpoint.", required: true));
        Register(group, "provider.list", "list", "List providers.",
            Text("--profile", "Profile ID.", required: true));
        Register(group, "provider.show", "show", "Show a provider.",
            Text("--profile", "Profile ID.", required: true),
            Text("--id", "Provider ID.", required: true));
        var updateType = Text("--type", "New provider type.");
        updateType.AcceptOnlyFromAmong("openai-compatible", "anthropic", "azure-openai", "local-endpoint");
        Register(group, "provider.update", "update", "Update a provider.",
            Text("--profile", "Profile ID.", required: true),
            Text("--id", "Provider ID.", required: true),
            Text("--name", "New display name."),
            updateType,
            Text("--endpoint", "New provider endpoint."));
        Register(group, "provider.set-secret", "set-secret", "Store a provider secret.",
            Text("--profile", "Profile ID.", required: true),
            Text("--id", "Provider ID.", required: true),
            Flag("--secret-stdin", "Read one secret line from standard input."));
        Register(group, "provider.remove", "remove", "Remove an unused provider.",
            Text("--profile", "Profile ID.", required: true),
            Text("--id", "Provider ID.", required: true),
            Flag("--delete-secret", "Also delete the provider credential."));
    }

    private void AddModelCommands()
    {
        var group = new Command("model", "Manage public model aliases within a profile.");
        group.SetAction(_ => 0);
        Root.Subcommands.Add(group);
        Register(group, "model.add", "add", "Add a model alias.",
            Text("--profile", "Profile ID.", required: true),
            Text("--alias", "Public model alias.", required: true),
            Text("--provider", "Provider ID.", required: true),
            Text("--upstream", "Upstream model name.", required: true),
            Flag("--default", "Make this the default model."));
        Register(group, "model.list", "list", "List model aliases.",
            Text("--profile", "Profile ID.", required: true));
        Register(group, "model.show", "show", "Show a model alias.",
            Text("--profile", "Profile ID.", required: true),
            Text("--alias", "Public model alias.", required: true));
        Register(group, "model.update", "update", "Update a model alias.",
            Text("--profile", "Profile ID.", required: true),
            Text("--alias", "Current public model alias.", required: true),
            Text("--new-alias", "New public model alias."),
            Text("--provider", "New provider ID."),
            Text("--upstream", "New upstream model name."));
        Register(group, "model.remove", "remove", "Remove a model alias.",
            Text("--profile", "Profile ID.", required: true),
            Text("--alias", "Public model alias.", required: true));
        Register(group, "model.set-default", "set-default", "Set the profile default model.",
            Text("--profile", "Profile ID.", required: true),
            Text("--alias", "Public model alias.", required: true));
        Register(group, "model.fallback-add", "fallback-add", "Append a secondary model target.",
            Text("--profile", "Profile ID.", required: true),
            Text("--alias", "Public model alias.", required: true),
            Text("--provider", "Secondary provider ID.", required: true),
            Text("--upstream", "Secondary upstream model name.", required: true));
        Register(group, "model.fallback-remove", "fallback-remove", "Remove a secondary model target.",
            Text("--profile", "Profile ID.", required: true),
            Text("--alias", "Public model alias.", required: true),
            Text("--provider", "Secondary provider ID.", required: true));
        var routingStrategy = Text("--strategy", "Routing strategy.", required: true);
        routingStrategy.AcceptOnlyFromAmong("ordered-fallback", "weighted-round-robin");
        Register(group, "model.routing-set", "routing-set", "Set the model routing strategy.",
            Text("--profile", "Profile ID.", required: true),
            Text("--alias", "Public model alias.", required: true),
            routingStrategy);
        Register(group, "model.weight-set", "weight-set", "Set one model target weight.",
            Text("--profile", "Profile ID.", required: true),
            Text("--alias", "Public model alias.", required: true),
            Text("--provider", "Target provider ID.", required: true),
            Number("--weight", "Target weight from 1 to 100.", required: true));
    }

    private void AddConfigCommands()
    {
        var group = new Command("config", "Inspect and validate the versioned JSON configuration.");
        group.SetAction(_ => 0);
        Root.Subcommands.Add(group);
        Register(group, "config.show", "show", "Show configuration without secrets.");
        Register(group, "config.path", "path", "Show configuration paths.");
        Register(group, "config.validate", "validate", "Validate the current configuration.");
    }

    private void AddLimitCommands()
    {
        var group = new Command("limits", "Manage profile, provider, and model request limits.");
        group.SetAction(_ => 0);
        Root.Subcommands.Add(group);

        var profile = new Command("profile", "Manage profile-wide limits.");
        profile.SetAction(_ => 0);
        group.Subcommands.Add(profile);
        Register(profile, "limits.profile-set", "set", "Replace profile request limits.",
            Text("--profile", "Profile ID.", required: true),
            NullableNumber("--concurrency", "Maximum concurrent logical requests."),
            NullableNumber("--rpm", "Maximum admitted requests in a rolling minute."),
            NullableLong("--tpm", "Maximum recorded tokens in a rolling minute."));
        Register(profile, "limits.profile-clear", "clear", "Remove all profile request limits.",
            Text("--profile", "Profile ID.", required: true));

        var provider = new Command("provider", "Manage provider limits.");
        provider.SetAction(_ => 0);
        group.Subcommands.Add(provider);
        Register(provider, "limits.provider-set", "set", "Replace provider request limits.",
            Text("--profile", "Profile ID.", required: true),
            Text("--provider", "Provider ID.", required: true),
            NullableNumber("--concurrency", "Maximum concurrent logical requests."),
            NullableNumber("--rpm", "Maximum admitted requests in a rolling minute."),
            NullableLong("--tpm", "Maximum recorded tokens in a rolling minute."));
        Register(provider, "limits.provider-clear", "clear", "Remove all provider request limits.",
            Text("--profile", "Profile ID.", required: true),
            Text("--provider", "Provider ID.", required: true));

        var model = new Command("model", "Manage public model limits.");
        model.SetAction(_ => 0);
        group.Subcommands.Add(model);
        Register(model, "limits.model-set", "set", "Replace public model request limits.",
            Text("--profile", "Profile ID.", required: true),
            Text("--alias", "Public model alias.", required: true),
            NullableNumber("--concurrency", "Maximum concurrent logical requests."),
            NullableNumber("--rpm", "Maximum admitted requests in a rolling minute."),
            NullableLong("--tpm", "Maximum recorded tokens in a rolling minute."));
        Register(model, "limits.model-clear", "clear", "Remove all public model request limits.",
            Text("--profile", "Profile ID.", required: true),
            Text("--alias", "Public model alias.", required: true));
    }

    private void AddLifecycleCommands()
    {
        var installAutostart = Text(
            "--autostart",
            "Login autostart choice: enable or disable. Omit for an interactive prompt; the default is enable.");
        installAutostart.AcceptOnlyFromAmong("enable", "disable");
        Register(
            Root,
            "install",
            "install",
            "Install for this Windows user, add the install root to user PATH, and create the Tray Start Menu shortcut.",
            installAutostart);
        var uninstallChoices = new[]
        {
            Choice("--program", "Program files: keep or remove."),
            Choice("--autostart", "Owned login task: keep or remove."),
            Choice("--integrations", "Explicit client integrations: keep or remove."),
            Choice("--runtime-credential", "Runtime client credential: keep or remove."),
            Choice("--provider-credentials", "Provider credentials: keep or remove."),
            Choice("--configuration", "Configuration files: keep or remove."),
            Choice("--usage", "Usage database: keep or remove."),
            Choice("--logs", "Log files: keep or remove."),
            Choice("--backups", "Explicit backup files: keep or remove."),
        };
        Register(Root, "uninstall", "uninstall", "Remove explicitly selected Local AI Gateway components.",
            [
                Flag("--non-interactive", "Require every category choice and exact UNINSTALL confirmation."),
                .. uninstallChoices,
                Text("--confirm", "Type UNINSTALL in non-interactive mode."),
                Text("--claude-vscode-target", "Explicit absolute Claude VS Code settings.json target."),
                Text("--codex-cli-target", "Explicit absolute Codex aigw.config.toml target."),
                MultiText("--backup-path", "Explicit absolute Local AI Gateway backup path."),
            ]);
        Register(Root, "start", "start", "Start the installed gateway runtime.");
        Register(Root, "stop", "stop", "Stop the running gateway runtime.");
        Register(Root, "restart", "restart", "Restart the installed gateway runtime.");
        Register(Root, "status", "status", "Show gateway runtime status.");
        Register(Root, "doctor", "doctor", "Run read-only local diagnostics without a model request.");

        var autostart = new Command("autostart", "Manage current-user login autostart.");
        autostart.SetAction(_ => 0);
        Root.Subcommands.Add(autostart);
        Register(autostart, "autostart.enable", "enable", "Register the owned current-user login task.");
        Register(autostart, "autostart.disable", "disable", "Remove only the owned current-user login task.");
        Register(autostart, "autostart.status", "status", "Inspect the fixed current-user login task.");
    }

    private void AddRunCommands()
    {
        var group = new Command("run", "Launch a client through Local AI Gateway.");
        group.SetAction(_ => 0);
        group.Options.Add(Text("--client", "Absolute path to a custom executable.", required: true));
        group.Options.Add(Text("--base-url-env", "Custom client base URL environment variable.", required: true));
        group.Options.Add(Text("--token-env", "Custom client token environment variable.", required: true));
        group.Options.Add(Text("--working-directory", "Existing absolute client working directory."));
        group.Arguments.Add(ClientArguments());
        Root.Subcommands.Add(group);
        commandKeys.Add(group, "run.client");

        RegisterRunClient(group, "run.claude", "claude", "Launch Claude CLI through Local AI Gateway.");
        RegisterRunClient(group, "run.codex", "codex", "Launch Codex CLI through Local AI Gateway.");
    }

    private void AddIntegrationCommands()
    {
        var group = new Command("integrate", "Preview and manage owned client integration.");
        group.SetAction(_ => 0);
        Root.Subcommands.Add(group);

        var client = Text("--client", "Integration client.", required: true);
        client.AcceptOnlyFromAmong("claude-vscode", "codex-cli");
        Register(group, "integrate.preview", "preview", "Preview an owned fixture change without writing files.",
            client,
            Text("--source", "Optional absolute fixture source path."),
            Text("--target", "Absolute path represented by the preview.", required: true),
            Text("--client-version", "Detected client version in major.minor.patch form.", required: true),
            Text("--host-version", "VS Code version in major.minor.patch form."),
            Text("--wrapper", "Absolute installed Claude process-wrapper path."));

        var applyClient = Text("--client", "Integration client.", required: true);
        applyClient.AcceptOnlyFromAmong("claude-vscode", "codex-cli");
        Register(group, "integrate.apply", "apply", "Apply an explicitly confirmed integration preview.",
            applyClient,
            Text("--target", "Existing fixture target or new file path.", required: true),
            Text("--client-version", "Confirmed client version in major.minor.patch form.", required: true),
            Text("--host-version", "VS Code version in major.minor.patch form."),
            Text("--wrapper", "Absolute installed Claude process-wrapper path."),
            Text("--expected-before-sha256", "Before SHA-256 from preview for an existing target."),
            Flag("--expect-absent", "Confirm that preview observed no target file."),
            Text("--expected-after-sha256", "After SHA-256 from preview.", required: true),
            Text("--confirm", "Type APPLY to authorize the represented write.", required: true));

        var statusClient = Text("--client", "Integration client.", required: true);
        statusClient.AcceptOnlyFromAmong("claude-vscode", "codex-cli");
        Register(group, "integrate.status", "status", "Inspect one explicit integration target without writing files.",
            statusClient,
            Text("--target", "Existing fixture target or represented file path.", required: true));

        var unintegrateClient = Text("--client", "Integration client.", required: true);
        unintegrateClient.AcceptOnlyFromAmong("claude-vscode", "codex-cli");
        Register(group, "integrate.unintegrate", "unintegrate", "Remove an explicitly confirmed owned integration.",
            unintegrateClient,
            Text("--target", "Existing owned fixture target.", required: true),
            Text("--expected-before-sha256", "Before SHA-256 from integration status.", required: true),
            Text("--expected-after-sha256", "After SHA-256 from status for an updated target."),
            Flag("--expect-delete", "Confirm that status planned deletion of the fully owned target."),
            Text("--confirm", "Type UNINTEGRATE to authorize the represented removal.", required: true));
    }

    private void AddUsageCommands()
    {
        var group = new Command("usage", "Inspect privacy-bounded local token usage.");
        group.SetAction(_ => 0);
        Root.Subcommands.Add(group);
        Register(group, "usage.today", "today", "Show token usage since local midnight.");
    }

    private void AddBackupCommands()
    {
        var group = new Command("backup", "Create, inspect, and restore Local AI Gateway backups.");
        group.SetAction(_ => 0);
        Root.Subcommands.Add(group);
        Register(group, "backup.create", "create", "Create a new backup without overwriting an existing file.",
            Text("--output", "Absolute output path.", required: true),
            Flag("--include-secrets", "Encrypt and include available provider credentials."),
            Flag("--passphrase-stdin", "Read one backup passphrase line from standard input."));
        Register(group, "backup.inspect", "inspect", "Inspect and hash one backup without changing local state.",
            Text("--input", "Absolute backup path.", required: true),
            Flag("--passphrase-stdin", "Read one backup passphrase line from standard input."));
        Register(group, "backup.restore", "restore", "Restore a hash- and revision-bound backup.",
            Text("--input", "Absolute backup path.", required: true),
            Text("--expected-sha256", "SHA-256 returned by backup inspect.", required: true),
            Text("--expected-current-revision", "Current configuration revision observed before restore.", required: true),
            Text("--confirm", "Type RESTORE to authorize configuration and credential writes.", required: true),
            Flag("--passphrase-stdin", "Read one backup passphrase line from standard input."));
    }

    private void AddUpdateCommands()
    {
        var group = new Command("update", "Inspect and apply an offline Local AI Gateway package update.");
        group.SetAction(_ => 0);
        Root.Subcommands.Add(group);
        Register(group, "update.inspect", "inspect", "Verify an offline candidate without changing the installation.",
            Text("--package", "Absolute extracted candidate package root.", required: true),
            Flag("--allow-unsigned-development", "Explicitly allow an unsigned development candidate."));
        Register(group, "update.apply", "apply", "Apply a verified offline candidate with automatic rollback.",
            Text("--package", "Absolute extracted candidate package root.", required: true),
            Text("--expected-manifest-sha256", "Candidate manifest SHA-256 returned by update inspect.", required: true),
            Text("--confirm", "Type UPDATE to authorize the installation switch.", required: true),
            Flag("--allow-unsigned-development", "Explicitly allow an unsigned development candidate."));
    }

    private void RegisterRunClient(Command parent, string key, string name, string description)
    {
        var command = new Command(name, description);
        command.SetAction(_ => 0);
        command.Options.Add(Text("--working-directory", "Existing absolute client working directory."));
        command.Arguments.Add(ClientArguments());
        parent.Subcommands.Add(command);
        commandKeys.Add(command, key);
    }

    private static Argument<string[]> ClientArguments() => new("client-arguments")
    {
        Description = "Arguments after '--' are passed verbatim to the client.",
        Arity = ArgumentArity.ZeroOrMore,
    };

    private void Register(Command parent, string key, string name, string description, params Option[] options)
    {
        var command = new Command(name, description);
        command.SetAction(_ => 0);
        foreach (var option in options)
        {
            command.Options.Add(option);
        }
        parent.Subcommands.Add(command);
        commandKeys.Add(command, key);
    }

    private static Option<string> Text(
        string name,
        string description,
        bool required = false,
        bool recursive = false) => new(name)
        {
            Description = description,
            Required = required,
            Recursive = recursive,
        };

    private static Option<string> Choice(string name, string description)
    {
        var option = Text(name, description);
        option.AcceptOnlyFromAmong("keep", "remove");
        return option;
    }

    private static Option<string[]> MultiText(string name, string description) => new(name)
    {
        Description = description,
        Arity = ArgumentArity.ZeroOrMore,
        AllowMultipleArgumentsPerToken = true,
    };

    private static Option<int> Number(string name, string description, bool required = false) => new(name)
    {
        Description = description,
        Required = required,
    };

    private static Option<int?> NullableNumber(string name, string description) => new(name)
    {
        Description = description,
    };

    private static Option<long?> NullableLong(string name, string description) => new(name)
    {
        Description = description,
    };

    private static Option<bool> Flag(
        string name,
        string description,
        bool recursive = false,
        string[]? aliases = null) => new(name, aliases ?? [])
        {
            Description = description,
            Recursive = recursive,
        };
}
