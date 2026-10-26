using System.Net.Http.Headers;
using LocalAIGateway.Core.Backend;
using LocalAIGateway.Core.Configuration;

namespace LocalAIGateway.Runtime.Backend;

public sealed class StaticBackendHost : IBackendHost, IDisposable
{
    private readonly BackendInstance instance;
    private readonly HttpClient client;

    public StaticBackendHost(Uri baseAddress, string internalToken)
    {
        instance = new BackendInstance(baseAddress, internalToken);
        client = new HttpClient(new SocketsHttpHandler
        {
            AllowAutoRedirect = false,
            UseCookies = false,
            UseProxy = false,
        })
        {
            Timeout = TimeSpan.FromSeconds(5),
        };
    }

    public Task<BackendInstance> PrepareAsync(
        ProfileConfiguration profile,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(instance);

    public async Task<bool> ProbeReadyAsync(
        BackendInstance backend,
        CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, new Uri(backend.BaseAddress, "/ready"));
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", backend.InternalToken);
        using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
        return response.IsSuccessStatusCode;
    }

    public Task DrainAsync(BackendInstance backend, CancellationToken cancellationToken = default) =>
        Task.CompletedTask;

    public Task StopAsync(BackendInstance backend, CancellationToken cancellationToken = default) =>
        Task.CompletedTask;

    public void Dispose() => client.Dispose();
}
