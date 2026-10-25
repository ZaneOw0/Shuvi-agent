using LocalAIGateway.Core.Configuration;

namespace LocalAIGateway.Core.Backend;

public interface IBackendHost
{
    Task<BackendInstance> PrepareAsync(
        ProfileConfiguration profile,
        CancellationToken cancellationToken = default);

    Task<bool> ProbeReadyAsync(
        BackendInstance instance,
        CancellationToken cancellationToken = default);

    Task DrainAsync(
        BackendInstance instance,
        CancellationToken cancellationToken = default);

    Task StopAsync(
        BackendInstance instance,
        CancellationToken cancellationToken = default);
}

public sealed record BackendInstance(Uri BaseAddress, string InternalToken);
