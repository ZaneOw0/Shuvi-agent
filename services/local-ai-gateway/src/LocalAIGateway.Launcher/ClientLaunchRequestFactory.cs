namespace LocalAIGateway.Launcher;

public sealed class ClientLaunchRequestFactory
{
    public const string ClaudeModelAlias = "aigw/default";
    public const string CodexModelAlias = "aigw/codex/default";
    public const string CodexTokenEnvironmentVariable = "AIGW_CODEX_API_KEY";
    public const string CodexProviderBaseUrl = "http://127.0.0.1:4000/v1";

    private readonly IClientExecutableResolver executableResolver;

    public ClientLaunchRequestFactory(IClientExecutableResolver executableResolver)
    {
        ArgumentNullException.ThrowIfNull(executableResolver);
        this.executableResolver = executableResolver;
    }

    public ClientLaunchRequest CreateKnown(
        ClientKind client,
        IReadOnlyList<string> arguments,
        string workingDirectory)
    {
        ArgumentNullException.ThrowIfNull(arguments);
        return client switch
        {
            ClientKind.Claude => CreateClaude(arguments, workingDirectory),
            ClientKind.Codex => CreateCodex(arguments, workingDirectory),
            _ => throw new ClientLaunchException(
                "aigw_launcher_client_unknown",
                "The requested client adapter is not supported."),
        };
    }

    public ClientLaunchRequest CreateCustom(
        string executablePath,
        string baseUrlEnvironmentVariable,
        string tokenEnvironmentVariable,
        IReadOnlyList<string> arguments,
        string workingDirectory) => new(
            executablePath,
            arguments,
            workingDirectory,
            baseUrlEnvironmentVariable,
            tokenEnvironmentVariable);

    private ClientLaunchRequest CreateClaude(
        IReadOnlyList<string> arguments,
        string workingDirectory) => CreateClaudeForExecutable(
            executableResolver.Resolve(ClientKind.Claude),
            arguments,
            workingDirectory);

    public static ClientLaunchRequest CreateClaudeForExecutable(
        string executablePath,
        IReadOnlyList<string> arguments,
        string workingDirectory)
    {
        ArgumentNullException.ThrowIfNull(arguments);
        RejectOption(arguments, "--model");
        return new ClientLaunchRequest(
            executablePath,
            ["--model", ClaudeModelAlias, .. arguments],
            workingDirectory,
            "ANTHROPIC_BASE_URL",
            "ANTHROPIC_AUTH_TOKEN");
    }

    private ClientLaunchRequest CreateCodex(
        IReadOnlyList<string> arguments,
        string workingDirectory)
    {
        RejectOption(arguments, "--model", "-m");
        RejectOption(arguments, "--config", "-c");
        return new ClientLaunchRequest(
            executableResolver.Resolve(ClientKind.Codex),
            [
                "--model", CodexModelAlias,
                "--config", "model_provider=\"aigw\"",
                "--config", "model_providers.aigw.name=\"Local AI Gateway\"",
                "--config", $"model_providers.aigw.base_url=\"{CodexProviderBaseUrl}\"",
                "--config", $"model_providers.aigw.env_key=\"{CodexTokenEnvironmentVariable}\"",
                "--config", "model_providers.aigw.wire_api=\"responses\"",
                .. arguments,
            ],
            workingDirectory,
            null,
            CodexTokenEnvironmentVariable);
    }

    private static void RejectOption(IReadOnlyList<string> arguments, params string[] optionNames)
    {
        foreach (var argument in arguments)
        {
            if (optionNames.Any(option =>
                    string.Equals(argument, option, StringComparison.OrdinalIgnoreCase) ||
                    argument.StartsWith(option + "=", StringComparison.OrdinalIgnoreCase)))
            {
                throw new ClientLaunchException(
                    "aigw_launcher_option_conflict",
                    "The client arguments override a gateway-owned model or provider option.");
            }
        }
    }
}
