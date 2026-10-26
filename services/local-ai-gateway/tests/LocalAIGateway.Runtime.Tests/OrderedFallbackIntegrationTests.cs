using System.Collections.Concurrent;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using LocalAIGateway.Core.Backend;
using LocalAIGateway.Core.Configuration;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Server.Kestrel.Core;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

namespace LocalAIGateway.Runtime.Tests;

public sealed class OrderedFallbackIntegrationTests
{
    private const string ClientToken = "fallback-client-token";

    [Fact]
    public async Task Transient_primary_exhaustion_uses_fallback_and_open_primary_is_skipped()
    {
        await using var backend = new OrderedFallbackBackendHost(primaryStatusCode: 503);
        await using var gateway = await GatewayRuntimeHost.StartAsync(CreateOptions(backend) with
        {
            CircuitFailureThreshold = 1,
        });
        using var client = CreateClient(gateway.BaseAddress);

        using (var first = await client.SendAsync(CreateRequest()))
        {
            var payload = await first.Content.ReadAsStringAsync();
            Assert.Equal(HttpStatusCode.OK, first.StatusCode);
            Assert.Contains("public-chat", payload, StringComparison.Ordinal);
        }

        Assert.Equal(3, backend.RequestCount("primary"));
        Assert.Equal(1, backend.RequestCount("secondary"));
        var circuits = gateway.GetStatus().TargetCircuits;
        Assert.Equal("open", Assert.Single(circuits, item => item.ProviderId == "primary").State);
        Assert.Equal("closed", Assert.Single(circuits, item => item.ProviderId == "secondary").State);

        using var second = await client.SendAsync(CreateRequest());
        Assert.Equal(HttpStatusCode.OK, second.StatusCode);
        Assert.Equal(3, backend.RequestCount("primary"));
        Assert.Equal(2, backend.RequestCount("secondary"));
    }

    [Fact]
    public async Task Non_transient_primary_response_is_not_fallback_eligible()
    {
        await using var backend = new OrderedFallbackBackendHost(primaryStatusCode: 400);
        await using var gateway = await GatewayRuntimeHost.StartAsync(CreateOptions(backend));
        using var client = CreateClient(gateway.BaseAddress);

        using var response = await client.SendAsync(CreateRequest());

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.Equal(1, backend.RequestCount("primary"));
        Assert.Equal(0, backend.RequestCount("secondary"));
    }

    [Fact]
    public async Task Stream_disconnect_after_first_byte_never_falls_back()
    {
        await using var backend = new OrderedFallbackBackendHost(
            primaryStatusCode: 200,
            disconnectPrimaryAfterFirstByte: true);
        await using var gateway = await GatewayRuntimeHost.StartAsync(CreateOptions(backend));
        using var client = CreateClient(gateway.BaseAddress);
        using var request = CreateRequest(stream: true);
        try
        {
            using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead);
            await using var body = await response.Content.ReadAsStreamAsync();
            var buffer = new byte[128];
            var received = await body.ReadAsync(buffer);

            Assert.Equal(HttpStatusCode.OK, response.StatusCode);
            Assert.True(received > 0);
            backend.ReleasePrimaryDisconnect.TrySetResult();
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
            try
            {
                while (await body.ReadAsync(buffer, timeout.Token) > 0)
                {
                }
            }
            catch (IOException)
            {
                // Aborting the upstream stream may reset the downstream connection.
            }

            Assert.Equal(1, backend.RequestCount("primary"));
            Assert.Equal(0, backend.RequestCount("secondary"));
        }
        finally
        {
            backend.ReleasePrimaryDisconnect.TrySetResult();
        }
    }

    [Fact]
    public async Task Weighted_round_robin_distributes_requests_by_smooth_weight()
    {
        await using var backend = new OrderedFallbackBackendHost(primaryStatusCode: 200);
        await using var gateway = await GatewayRuntimeHost.StartAsync(CreateOptions(
            backend,
            CreateConfiguration(ModelRoutingStrategy.WeightedRoundRobin, primaryWeight: 2, secondaryWeight: 1)));
        using var client = CreateClient(gateway.BaseAddress);

        for (var index = 0; index < 6; index++)
        {
            using var response = await client.SendAsync(CreateRequest());
            Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        }

        Assert.Equal(4, backend.RequestCount("primary"));
        Assert.Equal(2, backend.RequestCount("secondary"));
    }

    [Fact]
    public async Task Weighted_transient_failure_does_not_fallback_and_open_target_is_skipped_next_request()
    {
        await using var backend = new OrderedFallbackBackendHost(primaryStatusCode: 503);
        await using var gateway = await GatewayRuntimeHost.StartAsync(CreateOptions(
            backend,
            CreateConfiguration(ModelRoutingStrategy.WeightedRoundRobin, primaryWeight: 1, secondaryWeight: 1)) with
        {
            CircuitFailureThreshold = 1,
        });
        using var client = CreateClient(gateway.BaseAddress);

        using (var first = await client.SendAsync(CreateRequest()))
        {
            Assert.Equal(HttpStatusCode.ServiceUnavailable, first.StatusCode);
        }

        Assert.Equal(3, backend.RequestCount("primary"));
        Assert.Equal(0, backend.RequestCount("secondary"));

        using var second = await client.SendAsync(CreateRequest());
        Assert.Equal(HttpStatusCode.OK, second.StatusCode);
        Assert.Equal(3, backend.RequestCount("primary"));
        Assert.Equal(1, backend.RequestCount("secondary"));
    }

    private static GatewayRuntimeOptions CreateOptions(
        IBackendHost backend,
        GatewayConfiguration? configuration = null) => new()
    {
        Configuration = configuration ?? CreateConfiguration(),
        ClientToken = ClientToken,
        BackendHost = backend,
        ListenAddress = IPAddress.Loopback,
        Port = 0,
        ForwardingTimeout = TimeSpan.FromSeconds(5),
    };

    private static GatewayConfiguration CreateConfiguration(
        ModelRoutingStrategy routingStrategy = ModelRoutingStrategy.OrderedFallback,
        int primaryWeight = 1,
        int secondaryWeight = 1)
    {
        const string profileId = "fallback-profile";
        return new GatewayConfiguration
        {
            Revision = 1,
            ActiveProfileId = profileId,
            Profiles =
            [
                new ProfileConfiguration
                {
                    Id = profileId,
                    Name = "Fallback",
                    Providers =
                    [
                        Provider(profileId, "primary"),
                        Provider(profileId, "secondary"),
                    ],
                    Models =
                    [
                        new ModelConfiguration
                        {
                            Alias = "public-chat",
                            ProviderId = "primary",
                            UpstreamModel = "primary-private-model",
                            IsDefault = true,
                            RoutingStrategy = routingStrategy,
                            Weight = primaryWeight,
                            Fallbacks =
                            [
                                new ModelFallbackConfiguration
                                {
                                    ProviderId = "secondary",
                                    UpstreamModel = "secondary-private-model",
                                    Weight = secondaryWeight,
                                },
                            ],
                        },
                    ],
                },
            ],
        };
    }

    private static ProviderConfiguration Provider(string profileId, string providerId) => new()
    {
        Id = providerId,
        Name = providerId,
        Type = ProviderType.LocalEndpoint,
        Endpoint = "http://127.0.0.1:9999",
        CredentialTarget = CredentialTargets.UpstreamApiKey(profileId, providerId),
    };

    private static HttpClient CreateClient(Uri baseAddress) => new(new SocketsHttpHandler
    {
        UseProxy = false,
        AllowAutoRedirect = false,
    })
    {
        BaseAddress = baseAddress,
        Timeout = TimeSpan.FromSeconds(10),
    };

    private static HttpRequestMessage CreateRequest(bool stream = false)
    {
        var request = new HttpRequestMessage(HttpMethod.Post, "/v1/chat/completions")
        {
            Content = new StringContent(
                JsonSerializer.Serialize(new { model = "public-chat", input = "hello", stream }),
                Encoding.UTF8,
                "application/json"),
        };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", ClientToken);
        return request;
    }

    private sealed class OrderedFallbackBackendHost(
        int primaryStatusCode,
        bool disconnectPrimaryAfterFirstByte = false) : IBackendHost, IAsyncDisposable
    {
        private readonly ConcurrentDictionary<BackendInstance, WebApplication> applications = new();
        private readonly ConcurrentDictionary<string, int> requestCounts = new(StringComparer.OrdinalIgnoreCase);

        public TaskCompletionSource ReleasePrimaryDisconnect { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        public int RequestCount(string providerId) =>
            requestCounts.TryGetValue(providerId, out var count) ? count : 0;

        public async Task<BackendInstance> PrepareAsync(
            ProfileConfiguration profile,
            CancellationToken cancellationToken = default)
        {
            var model = Assert.Single(profile.Models);
            var providerId = model.ProviderId;
            var token = Convert.ToHexString(RandomNumberGenerator.GetBytes(32));
            var builder = WebApplication.CreateSlimBuilder();
            builder.Logging.ClearProviders();
            builder.WebHost.ConfigureKestrel(server =>
            {
                server.AddServerHeader = false;
                server.Listen(IPAddress.Loopback, 0, listen => listen.Protocols = HttpProtocols.Http1);
            });
            var application = builder.Build();
            application.MapGet("/ready", context =>
            {
                context.Response.StatusCode = string.Equals(
                    context.Request.Headers.Authorization,
                    $"Bearer {token}",
                    StringComparison.Ordinal)
                        ? StatusCodes.Status200OK
                        : StatusCodes.Status401Unauthorized;
                return Task.CompletedTask;
            });
            application.MapPost("/{**path}", async context =>
            {
                requestCounts.AddOrUpdate(providerId, 1, static (_, current) => current + 1);
                using var document = await JsonDocument.ParseAsync(context.Request.Body, cancellationToken: context.RequestAborted);
                Assert.Equal("public-chat", document.RootElement.GetProperty("model").GetString());
                if (providerId == "primary")
                {
                    if (disconnectPrimaryAfterFirstByte)
                    {
                        context.Response.ContentType = "text/event-stream";
                        await context.Response.WriteAsync("data: {\"event\":1}\n\n", context.RequestAborted);
                        await context.Response.Body.FlushAsync(context.RequestAborted);
                        await ReleasePrimaryDisconnect.Task.WaitAsync(context.RequestAborted);
                        context.Abort();
                        return;
                    }

                    context.Response.StatusCode = primaryStatusCode;
                    await context.Response.WriteAsJsonAsync(new { provider = providerId }, context.RequestAborted);
                    return;
                }

                await context.Response.WriteAsJsonAsync(
                    new { provider = providerId, model = "public-chat" },
                    context.RequestAborted);
            });
            await application.StartAsync(cancellationToken);
            var address = application.Services.GetRequiredService<IServer>()
                .Features.Get<IServerAddressesFeature>()?.Addresses.Single()
                ?? throw new InvalidOperationException("Backend address was not reported.");
            var instance = new BackendInstance(new Uri(address), token);
            Assert.True(applications.TryAdd(instance, application));
            return instance;
        }

        public Task<bool> ProbeReadyAsync(
            BackendInstance instance,
            CancellationToken cancellationToken = default) => Task.FromResult(true);

        public Task DrainAsync(
            BackendInstance instance,
            CancellationToken cancellationToken = default) => Task.CompletedTask;

        public async Task StopAsync(
            BackendInstance instance,
            CancellationToken cancellationToken = default)
        {
            if (applications.TryRemove(instance, out var application))
            {
                await application.StopAsync(cancellationToken);
                await application.DisposeAsync();
            }
        }

        public async ValueTask DisposeAsync()
        {
            foreach (var instance in applications.Keys)
            {
                await StopAsync(instance);
            }
        }
    }
}
