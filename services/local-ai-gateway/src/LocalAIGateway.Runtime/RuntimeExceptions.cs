namespace LocalAIGateway.Runtime;

public class RuntimeGatewayException : Exception
{
    public RuntimeGatewayException(string errorCode, string message, Exception? innerException = null)
        : base(message, innerException)
    {
        ErrorCode = errorCode;
    }

    public string ErrorCode { get; }
}

public sealed class RuntimeConflictException : RuntimeGatewayException
{
    public RuntimeConflictException(int port, Exception? innerException = null)
        : base(
            "aigw_runtime_port_in_use",
            $"The required gateway port {port} is already in use.",
            innerException)
    {
        Port = port;
    }

    public int Port { get; }
}

public sealed class RuntimeInstanceConflictException : RuntimeGatewayException
{
    public RuntimeInstanceConflictException()
        : base(
            "aigw_runtime_already_running",
            "Another Local AI Gateway runtime instance is already running for the current Windows user.")
    {
    }
}

public sealed class BackendUnavailableException : RuntimeGatewayException
{
    public BackendUnavailableException(
        string message,
        Exception? innerException = null,
        string errorCode = "aigw_backend_unavailable")
        : base(errorCode, message, innerException)
    {
    }
}

public sealed class BackendCredentialException : RuntimeGatewayException
{
    public BackendCredentialException(string errorCode, string message, Exception? innerException = null)
        : base(errorCode, message, innerException)
    {
    }
}
