namespace LocalAIGateway.Launcher;

public sealed record ClientLaunchRequest(
    string ExecutablePath,
    IReadOnlyList<string> Arguments,
    string WorkingDirectory,
    string? BaseUrlEnvironmentVariable,
    string TokenEnvironmentVariable);
