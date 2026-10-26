namespace LocalAIGateway.Launcher;

public sealed class ClientIntegrationException : Exception
{
    public ClientIntegrationException(
        string errorCode,
        string message,
        Exception? innerException = null)
        : base(message, innerException)
    {
        ErrorCode = errorCode;
    }

    public string ErrorCode { get; }
}
