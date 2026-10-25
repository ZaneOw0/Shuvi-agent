namespace LocalAIGateway.Core.Configuration;

public interface IConfigurationFileSecurity
{
    void ProtectDirectory(string path);

    void ProtectFile(string path);
}

public sealed class NoOpConfigurationFileSecurity : IConfigurationFileSecurity
{
    public static NoOpConfigurationFileSecurity Instance { get; } = new();

    private NoOpConfigurationFileSecurity()
    {
    }

    public void ProtectDirectory(string path)
    {
    }

    public void ProtectFile(string path)
    {
    }
}
