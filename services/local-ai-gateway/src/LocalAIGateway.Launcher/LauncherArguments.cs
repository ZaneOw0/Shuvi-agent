namespace LocalAIGateway.Launcher;

internal sealed record LauncherArguments(ClientLaunchRequest Request)
{
    public static LauncherArguments Parse(IReadOnlyList<string> args)
    {
        if (args.Count > 0 && !args[0].StartsWith("--", StringComparison.Ordinal))
        {
            return new LauncherArguments(ClientLaunchRequestFactory.CreateClaudeForExecutable(
                args[0],
                args.Skip(1).ToArray(),
                Environment.CurrentDirectory));
        }

        string? client = null;
        string? workingDirectory = null;
        string? baseUrlEnvironmentVariable = null;
        string? tokenEnvironmentVariable = null;
        var separator = -1;

        for (var index = 0; index < args.Count; index++)
        {
            if (args[index] == "--")
            {
                separator = index;
                break;
            }

            var option = args[index];
            if (index + 1 >= args.Count)
            {
                throw Invalid();
            }

            var value = args[++index];
            switch (option)
            {
                case "--client" when client is null:
                    client = value;
                    break;
                case "--working-directory" when workingDirectory is null:
                    workingDirectory = value;
                    break;
                case "--base-url-env" when baseUrlEnvironmentVariable is null:
                    baseUrlEnvironmentVariable = value;
                    break;
                case "--token-env" when tokenEnvironmentVariable is null:
                    tokenEnvironmentVariable = value;
                    break;
                default:
                    throw Invalid();
            }
        }

        if (separator < 0 ||
            string.IsNullOrWhiteSpace(client) ||
            string.IsNullOrWhiteSpace(baseUrlEnvironmentVariable) ||
            string.IsNullOrWhiteSpace(tokenEnvironmentVariable))
        {
            throw Invalid();
        }

        workingDirectory ??= Environment.CurrentDirectory;
        return new LauncherArguments(new ClientLaunchRequest(
            client,
            args.Skip(separator + 1).ToArray(),
            workingDirectory,
            baseUrlEnvironmentVariable,
            tokenEnvironmentVariable));
    }

    private static ClientLaunchException Invalid() => new(
        "aigw_launcher_arguments_invalid",
        "Usage: aigw-launcher --client <absolute-path> --base-url-env <name> --token-env <name> [--working-directory <absolute-path>] -- [client arguments]");
}
