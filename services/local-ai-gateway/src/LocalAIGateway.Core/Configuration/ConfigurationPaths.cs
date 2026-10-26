namespace LocalAIGateway.Core.Configuration;

public sealed record ConfigurationPaths(string RootDirectory)
{
    public string ConfigurationFile => Path.Combine(RootDirectory, "config.json");

    public string BackupFile => Path.Combine(RootDirectory, "config.json.bak");

    public string LockFile => Path.Combine(RootDirectory, "config.lock");

    public string LogsDirectory => Path.Combine(RootDirectory, "logs");

    public static ConfigurationPaths ForCurrentUser()
    {
        var localAppData = Environment.GetEnvironmentVariable("LOCALAPPDATA");
        if (string.IsNullOrWhiteSpace(localAppData))
        {
            localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        }

        if (string.IsNullOrWhiteSpace(localAppData))
        {
            throw new ConfigurationException(
                "aigw_config_path_unavailable",
                "The current user's local application data directory is unavailable.");
        }

        if (!Path.IsPathFullyQualified(localAppData))
        {
            throw new ConfigurationException(
                "aigw_config_path_invalid",
                "The current user's local application data directory must be an absolute path.");
        }

        return new ConfigurationPaths(Path.Combine(Path.GetFullPath(localAppData), "LocalAIGateway"));
    }
}
