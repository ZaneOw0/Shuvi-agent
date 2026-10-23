namespace LocalAIGateway.Launcher;

public sealed class ClientLaunchException : Exception
{
    public ClientLaunchException(string errorCode, string message, Exception? innerException = null)
        : base(message, innerException)
    {
        ErrorCode = errorCode;
    }

    public string ErrorCode { get; }
}
