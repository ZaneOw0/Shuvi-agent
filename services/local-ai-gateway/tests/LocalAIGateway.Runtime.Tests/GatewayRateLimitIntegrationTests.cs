using System.Collections.Concurrent;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text.Json;
using LocalAIGateway.Core.Backend;
using LocalAIGateway.Core.Configuration;
using LocalAIGateway.Core.Credentials;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Server.Kestrel.Core;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

namespace LocalAIGateway.Runtime.Tests;

public sealed class GatewayRateLimitIntegrationTests
{
    private const string ClientToken = "m6e-client-token";

    [Fact]
    public async Task Concurrency_limit_covers_the_full_response_and_releases_after_completion()
    {
        var gate = new ResponseGate();
        await using var backend = new RateLimitBackendHost(gate);
        await using var gateway = await GatewayRuntimeHost.StartAsync(CreateOptions(
            backend,
            CreateConfiguration(profileLimits: new() { MaxConcurrentRequests = 1 })));
        using var client = CreateClient(gateway.BaseAddress);

        var firstTask = client.SendAsync(CreateRequest());
        await gate.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));

        using (var rejected = await client.SendAsync(CreateRequest()))
        {
            await AssertLimitAsync(rejected, "aigw_concurrency_limit_exceeded");
        }

        gate.Release.TrySetResult();
        using (var first = await firstTask)
        {
            Assert.Equal(HttpStatusCode.OK, first.StatusCode);
        }

        using var afterRelease = await client.SendAsync(CreateRequest());
        Assert.Equal(HttpStatusCode.OK, afterRelease.StatusCode);
        Assert.Equal(2, backend.RequestCount);
    }

    [Fact]
    public async Task Cancellation_releases_concurrency_and_rejected_waiters_do_not_consume_rpm()
    {
        var gate = new ResponseGate();
        await using var backend = new RateLimitBackendHost(gate);
        await using var gateway = await GatewayRuntimeHost.StartAsync(CreateOptions(
            backend,
            CreateConfiguration(profileLimits: new()
            {
                MaxConcurrentRequests = 1,
                RequestsPerMinute = 2,
            })));
        using var client = CreateClient(gateway.BaseAddress);
        using var cancellation = new CancellationTokenSource();

        var firstTask = client.SendAsync(CreateRequest(), cancellation.Token);
        await gate.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => firstTask);
        gate.Release.TrySetResult();

        using var next = await SendUntilNotConcurrencyLimitedAsync(client);
        Assert.Equal(HttpStatusCode.OK, next.StatusCode);

        using var rpmRejected = await client.SendAsync(CreateRequest());
        await AssertLimitAsync(rpmRejected, "aigw_rpm_limit_exceeded");
    }

    [Fact]
    public async Task Rpm_state_survives_blue_green_reload_for_the_same_logical_scope()
    {
        await using var backend = new RateLimitBackendHost();
        var initial = CreateConfiguration(
            revision: 1,
            modelLimits: new RequestLimitConfiguration { RequestsPerMinute = 1 });
        await using var gateway = await GatewayRuntimeHost.StartAsync(CreateOptions(backend, initial));
        using var client = CreateClient(gateway.BaseAddress);

        using (var first = await client.SendAsync(CreateRequest()))
        {
            Assert.Equal(HttpStatusCode.OK, first.StatusCode);
        }

        var reload = await gateway.ReloadAsync(initial with { Revision = 2 });
        Assert.True(reload.Reloaded);
        using var rejected = await client.SendAsync(CreateRequest());
        await AssertLimitAsync(rejected, "aigw_rpm_limit_exceeded");
        Assert.Equal(1, backend.RequestCount);
    }

    [Fact]
    public async Task Tpm_uses_copied_response_usage_and_rejects_the_next_request()
    {
        await using var backend = new RateLimitBackendHost(totalTokens: 12);
        await using var gateway = await GatewayRuntimeHost.StartAsync(CreateOptions(
            backend,
            CreateConfiguration(
                providerLimits: new RequestLimitConfiguration { TokensPerMinute = 10 },
                modelLimits: new RequestLimitConfiguration { TokensPerMinute = 20 })));
        using var client = CreateClient(gateway.BaseAddress);

        using (var first = await client.SendAsync(CreateRequest()))
        {
            Assert.Equal(HttpStatusCode.OK, first.StatusCode);
            Assert.Contains("\"total_tokens\":12", await first.Content.ReadAsStringAsync(), StringComparison.Ordinal);
        }

        using var rejected = await client.SendAsync(CreateRequest());
        await AssertLimitAsync(rejected, "aigw_tpm_limit_exceeded");
        Assert.Equal(1, backend.RequestCount);
    }

    [Fact]
    public async Task Token_limited_streaming_chat_forces_standard_usage_summary_without_changing_the_alias()
    {
        await using var backend = new RateLimitBackendHost();
        await using var gateway = await GatewayRuntimeHost.StartAsync(CreateOptions(
            backend,
            CreateConfiguration(modelLimits: new RequestLimitConfiguration { TokensPerMinute = 100 })));
        using var client = CreateClient(gateway.BaseAddress);
        using var request = new HttpRequestMessage(HttpMethod.Post, "/v1/chat/completions")
        {
            Content = JsonContent.Create(new
            {
                model = "public-chat",
                stream = true,
                stream_options = new { include_usage = false, future_option = "preserved" },
                messages = Array.Empty<object>(),
            }),
        };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", ClientToken);

        using var response = await client.SendAsync(request);

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        using var forwarded = JsonDocument.Parse(Assert.Single(backend.RequestBodies));
        Assert.Equal("public-chat", forwarded.RootElement.GetProperty("model").GetString());
        var streamOptions = forwarded.RootElement.GetProperty("stream_options");
        Assert.True(streamOptions.GetProperty("include_usage").GetBoolean());
        Assert.Equal("preserved", streamOptions.GetProperty("future_option").GetString());
    }

    private static GatewayRuntimeOptions CreateOptions(
        IBackendHost backend,
        GatewayConfiguration configuration) => new()
    {
        Configuration = configuration,
        ClientToken = ClientToken,
        BackendHost = backend,
        ListenAddress = IPAddress.Loopback,
        Port = 0,
        ForwardingTimeout = TimeSpan.FromSeconds(5),
    };

    private static GatewayConfiguration CreateConfiguration(
        long revision = 1,
        RequestLimitConfiguration? profileLimits = null,
        RequestLimitConfiguration? providerLimits = null,
        RequestLimitConfiguration? modelLimits = null)
    {
        const string profileId = "limited";
        const string providerId = "primary";
        return new GatewayConfiguration
        {
            Revision = revision,
            ActiveProfileId = profileId,
            Profiles =
            [
                new ProfileConfiguration
                {
                    Id = profileId,
                    Name = "Limited",
                    Limits = profileLimits,
                    Providers =
                    [
                        new ProviderConfiguration
                        {
                            Id = providerId,
                            Name = "Primary",
                            Type = ProviderType.LocalEndpoint,
                            Endpoint = "http://127.0.0.1:1/v1",
                            CredentialTarget = CredentialTargets.UpstreamApiKey(profileId, providerId),
                            Limits = providerLimits,
                        },
                    ],
                    Models =
                    [
                        new ModelConfiguration
                        {
                            Alias = "public-chat",
                            ProviderId = providerId,
                            UpstreamModel = "private-chat",
                            IsDefault = true,
                            Limits = modelLimits,
                        },
                    ],
                },
            ],
        };
    }

    private static HttpClient CreateClient(Uri baseAddress) => new()
    {
        BaseAddress = baseAddress,
        Timeout = TimeSpan.FromSeconds(10),
    };

    private static HttpRequestMessage CreateRequest()
    {
        var request = new HttpRequestMessage(HttpMethod.Post, "/v1/chat/completions")
        {
            Content = JsonContent.Create(new { model = "public-chat", messages = Array.Empty<object>() }),
        };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", ClientToken);
        return request;
    }

    private static async Task AssertLimitAsync(HttpResponseMessage response, string expectedCode)
    {
        Assert.Equal(HttpStatusCode.TooManyRequests, response.StatusCode);
        Assert.True(response.Headers.RetryAfter?.Delta > TimeSpan.Zero);
        using var document = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
        Assert.Equal(expectedCode, document.RootElement.GetProperty("error").GetProperty("code").GetString());
    }

    private static async Task<HttpResponseMessage> SendUntilNotConcurrencyLimitedAsync(HttpClient client)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        while (true)
        {
            var response = await client.SendAsync(CreateRequest(), timeout.Token);
            if (response.StatusCode != HttpStatusCode.TooManyRequests)
            {
                return response;
            }

            var payload = await response.Content.ReadAsStringAsync(timeout.Token);
            response.Dispose();
            if (!payload.Contains("aigw_concurrency_limit_exceeded", StringComparison.Ordinal))
            {
                throw new Xunit.Sdk.XunitException($"Unexpected rate-limit response: {payload}");
            }

            await Task.Delay(20, timeout.Token);
        }
    }

    private sealed class ResponseGate
    {
        public TaskCompletionSource Started { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource Release { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
    }

    private sealed class RateLimitBackendHost(
        ResponseGate? gate = null,
        long totalTokens = 1) : IBackendHost, IAsyncDisposable
    {
        private readonly ConcurrentDictionary<BackendInstance, WebApplication> applications = new();
        private readonly ConcurrentQueue<string> requestBodies = new();
        private int requestCount;

        public int RequestCount => Volatile.Read(ref requestCount);
        public IReadOnlyCollection<string> RequestBodies => requestBodies.ToArray();

        public async Task<BackendInstance> PrepareAsync(
            ProfileConfiguration profile,
            CancellationToken cancellationToken = default)
        {
            var token = Convert.ToHexString(RandomNumberGenerator.GetBytes(32));
            var builder = WebApplication.CreateSlimBuilder();
            builder.Logging.ClearProviders();
            builder.WebHost.ConfigureKestrel(server =>
            {
                server.AddServerHeader = false;
                server.Listen(IPAddress.Loopback, 0, listen => listen.Protocols = HttpProtocols.Http1);
            });
            var application = builder.Build();
            application.MapPost("/{**path}", async context =>
            {
                Interlocked.Increment(ref requestCount);
                using var document = await JsonDocument.ParseAsync(
                    context.Request.Body,
                    cancellationToken: context.RequestAborted);
                requestBodies.Enqueue(document.RootElement.GetRawText());
                Assert.Equal("public-chat", document.RootElement.GetProperty("model").GetString());
                if (gate is not null && !gate.Release.Task.IsCompleted)
                {
                    gate.Started.TrySetResult();
                    await gate.Release.Task.WaitAsync(context.RequestAborted);
                }

                await context.Response.WriteAsJsonAsync(
                    new
                    {
                        id = "response",
                        usage = new
                        {
                            prompt_tokens = totalTokens,
                            completion_tokens = 0,
                            total_tokens = totalTokens,
                        },
                    },
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
