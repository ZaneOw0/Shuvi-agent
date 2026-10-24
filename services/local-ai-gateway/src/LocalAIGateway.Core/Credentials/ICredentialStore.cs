namespace LocalAIGateway.Core.Credentials;

public interface ICredentialStore
{
    ValueTask SetSecretAsync(string target, string secret, CancellationToken cancellationToken = default);

    ValueTask<string?> GetSecretAsync(string target, CancellationToken cancellationToken = default);

    ValueTask DeleteSecretAsync(string target, CancellationToken cancellationToken = default);
}

public interface ICredentialTargetCatalog
{
    ValueTask<IReadOnlyList<string>> ListTargetsAsync(
        string ownedPrefix,
        CancellationToken cancellationToken = default);
}

public sealed class CredentialException : Exception
{
    public CredentialException(string errorCode, string message, Exception? innerException = null)
        : base(message, innerException)
    {
        ErrorCode = errorCode;
    }

    public string ErrorCode { get; }
}
