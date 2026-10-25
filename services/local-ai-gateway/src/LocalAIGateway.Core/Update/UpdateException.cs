namespace LocalAIGateway.Core.Update;

public sealed class UpdateException : Exception
{
    public UpdateException(string errorCode, string message, Exception? innerException = null)
        : base(message, innerException)
    {
        ErrorCode = errorCode;
    }

    public string ErrorCode { get; }
}
