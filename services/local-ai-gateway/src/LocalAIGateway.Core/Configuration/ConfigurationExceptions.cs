namespace LocalAIGateway.Core.Configuration;

public class ConfigurationException : Exception
{
    public ConfigurationException(string errorCode, string message, Exception? innerException = null)
        : base(message, innerException)
    {
        ErrorCode = errorCode;
    }

    public string ErrorCode { get; }
}

public sealed class ConfigurationValidationException : ConfigurationException
{
    public ConfigurationValidationException(IReadOnlyList<ConfigurationValidationError> errors)
        : base(
            errors.FirstOrDefault()?.Code ?? "aigw_config_invalid",
            "Configuration validation failed.")
    {
        Errors = errors;
    }

    public IReadOnlyList<ConfigurationValidationError> Errors { get; }
}

public sealed class ConfigurationConcurrencyException : ConfigurationException
{
    public ConfigurationConcurrencyException(long expectedRevision, long actualRevision)
        : base(
            "aigw_config_concurrent_update",
            $"Configuration revision changed from {expectedRevision} to {actualRevision}.")
    {
        ExpectedRevision = expectedRevision;
        ActualRevision = actualRevision;
    }

    public long ExpectedRevision { get; }

    public long ActualRevision { get; }
}
