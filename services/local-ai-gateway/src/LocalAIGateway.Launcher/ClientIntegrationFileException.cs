namespace LocalAIGateway.Launcher;

public sealed class ClientIntegrationFileException : Exception
{
    public ClientIntegrationFileException(
        string errorCode,
        string message,
        Exception? innerException = null)
        : base(message, innerException)
    {
        ErrorCode = errorCode;
    }

    public string ErrorCode { get; }
}
