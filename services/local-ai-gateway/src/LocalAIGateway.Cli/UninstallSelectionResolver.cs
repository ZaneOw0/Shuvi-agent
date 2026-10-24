using LocalAIGateway.Core.Uninstall;

namespace LocalAIGateway.Cli;

internal sealed class UninstallSelectionResolver
{
    internal static readonly string[] CategoryNames =
    [
        "program",
        "autostart",
        "integrations",
        "runtime-credential",
        "provider-credentials",
        "configuration",
        "usage",
        "logs",
        "backups",
    ];

    private readonly TextReader input;
    private readonly TextWriter prompt;

    public UninstallSelectionResolver(TextReader input, TextWriter prompt)
    {
        this.input = input ?? throw new ArgumentNullException(nameof(input));
        this.prompt = prompt ?? throw new ArgumentNullException(nameof(prompt));
    }

    public async Task<UninstallSelection> ResolveAsync(
        bool nonInteractive,
        IReadOnlyDictionary<string, string?> choices,
        string? confirmation,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(choices);
        return nonInteractive
            ? ResolveNonInteractive(choices, confirmation)
            : await ResolveInteractiveAsync(choices, confirmation, cancellationToken);
    }

    private static UninstallSelection ResolveNonInteractive(
        IReadOnlyDictionary<string, string?> choices,
        string? confirmation)
    {
        if (!string.Equals(confirmation, "UNINSTALL", StringComparison.Ordinal))
        {
            throw new UninstallException(
                "aigw_uninstall_confirmation_required",
                "Non-interactive uninstall requires the exact confirmation value UNINSTALL.");
        }

        var resolved = CategoryNames.ToDictionary(
            name => name,
            name => ParseRequiredChoice(name, choices.GetValueOrDefault(name)),
            StringComparer.Ordinal);
        return ToSelection(resolved);
    }

    private async Task<UninstallSelection> ResolveInteractiveAsync(
        IReadOnlyDictionary<string, string?> choices,
        string? confirmation,
        CancellationToken cancellationToken)
    {
        if (confirmation is not null || choices.Any(pair => pair.Value is not null))
        {
            throw new UninstallException(
                "aigw_uninstall_mode_conflict",
                "Interactive uninstall does not accept preselected category choices or --confirm.");
        }

        var resolved = new Dictionary<string, UninstallChoice>(StringComparer.Ordinal);
        foreach (var name in CategoryNames)
        {
            while (true)
            {
                cancellationToken.ThrowIfCancellationRequested();
                await prompt.WriteAsync($"Remove {name}? [y/N]: ");
                var answer = await input.ReadLineAsync(cancellationToken);
                if (answer is null)
                {
                    throw new UninstallException(
                        "aigw_uninstall_input_missing",
                        "Standard input ended before every uninstall category was explicitly answered.");
                }

                var normalized = answer.Trim();
                if (normalized.Equals("y", StringComparison.OrdinalIgnoreCase) ||
                    normalized.Equals("yes", StringComparison.OrdinalIgnoreCase))
                {
                    resolved.Add(name, UninstallChoice.Remove);
                    break;
                }
                if (normalized.Length == 0 ||
                    normalized.Equals("n", StringComparison.OrdinalIgnoreCase) ||
                    normalized.Equals("no", StringComparison.OrdinalIgnoreCase))
                {
                    resolved.Add(name, UninstallChoice.Keep);
                    break;
                }

                await prompt.WriteLineAsync("Answer y/yes or n/no.");
            }
        }

        return ToSelection(resolved);
    }

    private static UninstallChoice ParseRequiredChoice(string name, string? value) => value switch
    {
        "keep" => UninstallChoice.Keep,
        "remove" => UninstallChoice.Remove,
        null => throw new UninstallException(
            "aigw_uninstall_selection_incomplete",
            $"Non-interactive uninstall must explicitly set --{name} to keep or remove."),
        _ => throw new UninstallException(
            "aigw_uninstall_selection_invalid",
            $"Uninstall selection --{name} must be keep or remove."),
    };

    private static UninstallSelection ToSelection(IReadOnlyDictionary<string, UninstallChoice> values) => new(
        values["program"],
        values["autostart"],
        values["integrations"],
        values["runtime-credential"],
        values["provider-credentials"],
        values["configuration"],
        values["usage"],
        values["logs"],
        values["backups"]);
}
