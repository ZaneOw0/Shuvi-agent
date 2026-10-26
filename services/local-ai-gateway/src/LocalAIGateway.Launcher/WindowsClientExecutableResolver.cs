namespace LocalAIGateway.Launcher;

public sealed class WindowsClientExecutableResolver : IClientExecutableResolver
{
    private readonly string? searchPath;

    public WindowsClientExecutableResolver(string? searchPath = null)
    {
        this.searchPath = searchPath;
    }

    public string Resolve(ClientKind client)
    {
        var fileName = client switch
        {
            ClientKind.Claude => "claude.exe",
            ClientKind.Codex => "codex.exe",
            _ => throw new ClientLaunchException(
                "aigw_launcher_client_unknown",
                "The requested client adapter is not supported."),
        };
        var pathValue = searchPath ?? Environment.GetEnvironmentVariable("PATH") ?? string.Empty;
        foreach (var entry in pathValue.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            var directory = entry.Trim().Trim('"');
            if (!Path.IsPathFullyQualified(directory))
            {
                continue;
            }

            string candidate;
            try
            {
                candidate = Path.GetFullPath(Path.Combine(directory, fileName));
            }
            catch (Exception exception) when (exception is ArgumentException or NotSupportedException or PathTooLongException)
            {
                continue;
            }

            if (!IsUsableExecutable(candidate))
            {
                continue;
            }

            return candidate;
        }

        throw new ClientLaunchException(
            "aigw_launcher_client_not_found",
            $"The supported executable '{fileName}' was not found on PATH.");
    }

    private static bool IsUsableExecutable(string candidate)
    {
        try
        {
            return File.Exists(candidate) &&
                (File.GetAttributes(candidate) & FileAttributes.ReparsePoint) == 0;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }
}
