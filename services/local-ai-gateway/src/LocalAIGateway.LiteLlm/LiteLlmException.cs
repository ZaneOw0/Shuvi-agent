using LocalAIGateway.Core.Backend;

namespace LocalAIGateway.LiteLlm;

public sealed class LiteLlmException : BackendHostException
{
    public LiteLlmException(
        string errorCode,
        string message,
        BackendFailureCategory category = BackendFailureCategory.Unavailable,
        Exception? innerException = null)
        : base(errorCode, message, category, innerException)
    {
    }
}
