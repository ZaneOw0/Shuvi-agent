namespace LocalAIGateway.Core.Installation;

public sealed class PackageManifestException : InstallationException
{
    public PackageManifestException(string errorCode, string message, Exception? innerException = null)
        : base(errorCode, message, innerException)
    {
    }
}
