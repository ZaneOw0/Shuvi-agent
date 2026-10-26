namespace LocalAIGateway.Core.Backend;

public enum BackendFailureCategory
{
    Configuration,
    Credential,
    Unavailable,
}

public class BackendHostException : Exception
{
    public BackendHostException(
        string errorCode,
        string message,
        BackendFailureCategory category,
        Exception? innerException = null)
        : base(message, innerException)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(errorCode);
        ErrorCode = errorCode;
        Category = category;
    }

    public string ErrorCode { get; }

    public BackendFailureCategory Category { get; }
}
