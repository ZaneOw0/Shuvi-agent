namespace LocalAIGateway.Launcher;

public interface IClientLaunchService
{
    Task<int> LaunchAsync(
        ClientLaunchRequest request,
        CancellationToken cancellationToken = default);
}
