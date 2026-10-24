namespace LocalAIGateway.Launcher;

public interface IClientExecutableResolver
{
    string Resolve(ClientKind client);
}
