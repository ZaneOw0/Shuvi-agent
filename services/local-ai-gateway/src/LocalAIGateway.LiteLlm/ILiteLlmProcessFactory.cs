using LocalAIGateway.Core.Backend;
using LocalAIGateway.Core.Configuration;

namespace LocalAIGateway.LiteLlm;

public interface ILiteLlmProcessFactory
{
    Task<ILiteLlmManagedProcess> StartAsync(
        ProfileConfiguration profile,
        LiteLlmConfigurationPlan plan,
        CancellationToken cancellationToken = default);
}

public interface ILiteLlmManagedProcess : IAsyncDisposable
{
    BackendInstance Instance { get; }

    Task<bool> ProbeReadyAsync(CancellationToken cancellationToken = default);

    Task DrainAsync(CancellationToken cancellationToken = default);

    Task StopAsync(CancellationToken cancellationToken = default);
}
