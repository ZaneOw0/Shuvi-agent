namespace LocalAIGateway.Core.Installation;

public class InstallationException : Exception
{
    public InstallationException(string errorCode, string message, Exception? innerException = null)
        : base(message, innerException)
    {
        ErrorCode = errorCode;
    }

    public string ErrorCode { get; }
}
