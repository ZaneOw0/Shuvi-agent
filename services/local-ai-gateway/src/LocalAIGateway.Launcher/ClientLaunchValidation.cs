namespace LocalAIGateway.Launcher;

internal static class ClientLaunchValidation
{
    public static void Validate(ClientLaunchRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(request.Arguments);
        ValidateExistingAbsoluteFile(request.ExecutablePath);
        ValidateExistingAbsoluteDirectory(request.WorkingDirectory);
        if (request.BaseUrlEnvironmentVariable is not null)
        {
            ValidateEnvironmentVariable(request.BaseUrlEnvironmentVariable, "base URL");
        }
        ValidateEnvironmentVariable(request.TokenEnvironmentVariable, "token");
        if (request.BaseUrlEnvironmentVariable is not null &&
            string.Equals(
                request.BaseUrlEnvironmentVariable,
                request.TokenEnvironmentVariable,
                StringComparison.OrdinalIgnoreCase))
        {
            throw Invalid("Base URL and token environment variable names must be different.");
        }

        if (request.Arguments.Any(argument => argument is null))
        {
            throw Invalid("Client arguments must not contain null values.");
        }
    }

    private static void ValidateExistingAbsoluteFile(string path)
    {
        if (string.IsNullOrWhiteSpace(path) ||
            !Path.IsPathFullyQualified(path) ||
            !File.Exists(path))
        {
            throw Invalid("Client executable must be an existing fully qualified file.");
        }

        if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
        {
            throw Invalid("Client executable must not be a reparse point.");
        }
    }

    private static void ValidateExistingAbsoluteDirectory(string path)
    {
        if (string.IsNullOrWhiteSpace(path) ||
            !Path.IsPathFullyQualified(path) ||
            !Directory.Exists(path))
        {
            throw Invalid("Client working directory must be an existing fully qualified directory.");
        }
    }

    private static void ValidateEnvironmentVariable(string name, string label)
    {
        if (string.IsNullOrWhiteSpace(name) ||
            name.Contains('=') ||
            name.Any(char.IsControl))
        {
            throw Invalid($"Client {label} environment variable name is malformed.");
        }
    }

    private static ClientLaunchException Invalid(string message) => new(
        "aigw_launcher_request_invalid",
        message);
}
