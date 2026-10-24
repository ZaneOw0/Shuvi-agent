namespace LocalAIGateway.Core.Control;

public static class ControlProtocol
{
    public const int Version = 2;

    public const int MaxFrameLength = 64 * 1024;
}

public static class ControlCommands
{
    public const string Status = "status";

    public const string Reload = "reload";

    public const string Stop = "stop";

    public static bool IsSupported(string command) => command is Status or Reload or Stop;
}

public interface IControlClient
{
    Task<ControlResponse> SendAsync(
        string command,
        CancellationToken cancellationToken = default);
}

public sealed record ControlRequest(int Version, string Command);

public sealed record ControlStatus(
    bool Running,
    string? ActiveProfileId,
    long? ActiveConfigurationRevision,
    long? PendingConfigurationRevision,
    bool Switching,
    string? LastReloadErrorCode,
    IReadOnlyList<TargetCircuitStatus> TargetCircuits);

public static class CircuitStates
{
    public const string Closed = "closed";

    public const string Open = "open";

    public const string HalfOpen = "half-open";

    public static bool IsSupported(string state) => state is Closed or Open or HalfOpen;
}

public sealed record TargetCircuitStatus(
    string ProviderId,
    string ModelAlias,
    string State,
    int ConsecutiveFailures,
    DateTimeOffset? OpenUntilUtc);

public sealed record ControlError(string Code, string Message);

public sealed record ControlResponse(
    int Version,
    bool Ok,
    ControlStatus? Status,
    ControlError? Error);

public sealed class ControlProtocolException : Exception
{
    public ControlProtocolException(string errorCode, string message, Exception? innerException = null)
        : base(message, innerException)
    {
        ErrorCode = errorCode;
    }

    public string ErrorCode { get; }
}
