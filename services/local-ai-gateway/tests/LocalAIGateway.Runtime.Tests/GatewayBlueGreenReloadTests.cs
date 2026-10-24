using System.Collections.Concurrent;
using System.Net;
using System.Net.Http.Headers;
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

public sealed class GatewayBlueGreenReloadTests
{
    private const string ClientToken = "blue-green-client-token";

    [Fact]
    public async Task Reload_switches_new_requests_without_cutting_an_existing_stream()
    {
        await using var backend = new MultiInstanceBackendHost();
        await using var gateway = await GatewayRuntimeHost.StartAsync(CreateOptions(
            backend,
            CreateConfiguration(1, "blue")));
        using var client = CreateClient(gateway.BaseAddress);

        using var streamRequest = AuthorizedJson("blue", stream: true);
        using var streamResponse = await client.SendAsync(
            streamRequest,
            HttpCompletionOption.ResponseHeadersRead);
        Assert.Equal(HttpStatusCode.OK, streamResponse.StatusCode);
        await backend.Instance("blue").FirstStreamEventWritten.Task.WaitAsync(TimeSpan.FromSeconds(5));

        var reload = await gateway.ReloadAsync(CreateConfiguration(2, "green"));

        Assert.True(reload.Reloaded);
        Assert.Equal(2, reload.Status.ActiveConfigurationRevision);
        Assert.Equal("green", reload.Status.ActiveProfileId);
        Assert.False(reload.Status.Switching);
        Assert.DoesNotContain("blue", backend.StoppedProfiles);

        using var newResponse = await client.SendAsync(AuthorizedJson("green"));
        Assert.Equal(HttpStatusCode.OK, newResponse.StatusCode);
        using var newPayload = JsonDocument.Parse(await newResponse.Content.ReadAsStringAsync());
        Assert.Equal("green", newPayload.RootElement.GetProperty("backend").GetString());

        backend.Instance("blue").ReleaseFinalStreamEvent.TrySetResult();
        var streamBody = await streamResponse.Content.ReadAsStringAsync();
        Assert.Contains("[DONE]", streamBody, StringComparison.Ordinal);
        await WaitUntilAsync(() => backend.StoppedProfiles.Contains("blue"));

        Assert.Contains("blue", backend.DrainedProfiles);
        Assert.Contains("blue", backend.StoppedProfiles);
        Assert.DoesNotContain("green", backend.StoppedProfiles);
    }

    [Fact]
    public async Task Failed_candidate_preserves_active_route_and_reports_pending_revision()
    {
        await using var backend = new MultiInstanceBackendHost();
        backend.NotReadyProfiles.Add("green");
        await using var gateway = await GatewayRuntimeHost.StartAsync(CreateOptions(
            backend,
            CreateConfiguration(1, "blue"),
            readyTimeout: TimeSpan.FromMilliseconds(150)));
        using var client = CreateClient(gateway.BaseAddress);

        var failure = await Assert.ThrowsAsync<BackendUnavailableException>(
            () => gateway.ReloadAsync(CreateConfiguration(2, "green")));

        Assert.Equal("aigw_backend_not_ready", failure.ErrorCode);
        var status = gateway.GetStatus();
        Assert.Equal(1, status.ActiveConfigurationRevision);
        Assert.Equal(2, status.PendingConfigurationRevision);
        Assert.False(status.Switching);
        Assert.Equal("aigw_backend_not_ready", status.LastReloadErrorCode);
        Assert.Contains("green", backend.StoppedProfiles);
        Assert.DoesNotContain("blue", backend.StoppedProfiles);

        using var response = await client.SendAsync(AuthorizedJson("blue"));
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        using var payload = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
        Assert.Equal("blue", payload.RootElement.GetProperty("backend").GetString());
    }

    [Fact]
    public async Task Equal_revision_is_idempotent_and_older_revision_is_rejected()
    {
        await using var backend = new MultiInstanceBackendHost();
        await using var gateway = await GatewayRuntimeHost.StartAsync(CreateOptions(
            backend,
            CreateConfiguration(5, "blue")));

        var equal = await gateway.ReloadAsync(CreateConfiguration(5, "blue"));
        Assert.False(equal.Reloaded);
        Assert.Single(backend.PreparedProfiles);

        var stale = await Assert.ThrowsAsync<RuntimeGatewayException>(
            () => gateway.ReloadAsync(CreateConfiguration(4, "older")));
        Assert.Equal("aigw_runtime_configuration_revision_stale", stale.ErrorCode);
        Assert.Single(backend.PreparedProfiles);
        Assert.Equal(5, gateway.GetStatus().ActiveConfigurationRevision);
    }

    [Fact]
    public async Task Concurrent_reloads_are_serialized_in_revision_order()
    {
        await using var backend = new MultiInstanceBackendHost();
        var gate = backend.BlockPreparation("green");
        await using var gateway = await GatewayRuntimeHost.StartAsync(CreateOptions(
            backend,
            CreateConfiguration(1, "blue")));

        var revisionTwo = gateway.ReloadAsync(CreateConfiguration(2, "green"));
        await gate.Entered.Task.WaitAsync(TimeSpan.FromSeconds(2));
        var revisionThree = gateway.ReloadAsync(CreateConfiguration(3, "red"));
        gate.Release.TrySetResult();

        await Task.WhenAll(revisionTwo, revisionThree);

        Assert.Equal(3, gateway.GetStatus().ActiveConfigurationRevision);
        Assert.Equal("red", gateway.GetStatus().ActiveProfileId);
    }

    [Fact]
    public async Task Invalid_higher_revision_is_reported_as_pending_without_touching_the_active_route()
    {
        await using var backend = new MultiInstanceBackendHost();
        await using var gateway = await GatewayRuntimeHost.StartAsync(CreateOptions(
            backend,
            CreateConfiguration(1, "blue")));
        var invalid = CreateConfiguration(2, "green") with { Profiles = [] };

        await Assert.ThrowsAsync<ConfigurationValidationException>(
            () => gateway.ReloadAsync(invalid));

        var status = gateway.GetStatus();
        Assert.Equal(1, status.ActiveConfigurationRevision);
        Assert.Equal(2, status.PendingConfigurationRevision);
        Assert.StartsWith("aigw_config_", status.LastReloadErrorCode, StringComparison.Ordinal);
        Assert.Single(backend.PreparedProfiles);
    }

    [Fact]
    public async Task Cancellation_observed_at_candidate_readiness_does_not_publish_the_candidate()
    {
        await using var backend = new MultiInstanceBackendHost();
        using var cancellation = new CancellationTokenSource();
        backend.CancelWhenReady["green"] = cancellation;
        await using var gateway = await GatewayRuntimeHost.StartAsync(CreateOptions(
            backend,
            CreateConfiguration(1, "blue")));

        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => gateway.ReloadAsync(CreateConfiguration(2, "green"), cancellation.Token));

        Assert.Equal(1, gateway.GetStatus().ActiveConfigurationRevision);
        Assert.Equal(2, gateway.GetStatus().PendingConfigurationRevision);
        Assert.Contains("green", backend.StoppedProfiles);
        Assert.DoesNotContain("blue", backend.StoppedProfiles);
    }

    [Fact]
    public async Task Completed_route_retirements_are_removed_from_lifecycle_tracking()
    {
        await using var backend = new MultiInstanceBackendHost();
        await using var gateway = await GatewayRuntimeHost.StartAsync(CreateOptions(
            backend,
            CreateConfiguration(1, "profile-1")));

        for (var revision = 2; revision <= 8; revision++)
        {
            await gateway.ReloadAsync(CreateConfiguration(revision, $"profile-{revision}"));
        }

        await WaitUntilAsync(() => gateway.TrackedRetirementCount == 0);
        Assert.Equal(0, gateway.TrackedRetirementCount);
    }

    private static GatewayRuntimeOptions CreateOptions(
        IBackendHost backend,
        GatewayConfiguration configuration,
        TimeSpan? readyTimeout = null) => new()
    {
        Configuration = configuration,
        ClientToken = ClientToken,
        BackendHost = backend,
        ListenAddress = IPAddress.Loopback,
        Port = 0,
        ForwardingTimeout = TimeSpan.FromSeconds(10),
        BackendReadyTimeout = readyTimeout ?? TimeSpan.FromSeconds(2),
        BackendReadyPollInterval = TimeSpan.FromMilliseconds(20),
    };

    private static GatewayConfiguration CreateConfiguration(long revision, string profileId) => new()
    {
        Revision = revision,
        ActiveProfileId = profileId,
        Profiles =
        [
            new ProfileConfiguration
            {
                Id = profileId,
                Name = profileId,
                Providers =
                [
                    new ProviderConfiguration
                    {
                        Id = "local",
                        Name = "Local",
                        Type = ProviderType.LocalEndpoint,
                        Endpoint = "http://127.0.0.1:9/v1",
                        CredentialTarget = $"LocalAIGateway/{profileId}/local/api-key",
                    },
                ],
                Models =
                [
                    new ModelConfiguration
                    {
                        Alias = "aigw/default",
                        ProviderId = "local",
                        UpstreamModel = $"upstream-{profileId}",
                        IsDefault = true,
                    },
                ],
            },
        ],
    };

    private static HttpClient CreateClient(Uri address) => new(new SocketsHttpHandler
    {
        UseProxy = false,
        AllowAutoRedirect = false,
    })
    {
        BaseAddress = address,
        Timeout = TimeSpan.FromSeconds(10),
    };

    private static HttpRequestMessage AuthorizedJson(string expectedProfile, bool stream = false)
    {
        var request = new HttpRequestMessage(HttpMethod.Post, "/v1/chat/completions")
        {
            Content = new StringContent(
                JsonSerializer.Serialize(new
                {
                    model = "aigw/default",
                    expected_profile = expectedProfile,
                    stream,
                }),
                Encoding.UTF8,
                "application/json"),
        };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", ClientToken);
        return request;
    }

    private static async Task WaitUntilAsync(Func<bool> predicate)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        while (!predicate())
        {
            await Task.Delay(20, timeout.Token);
        }
    }

    private sealed class MultiInstanceBackendHost : IBackendHost, IAsyncDisposable
    {
        private readonly ConcurrentDictionary<BackendInstance, BackendFixture> instances = new();

        public ConcurrentBag<string> PreparedProfiles { get; } = [];

        public ConcurrentBag<string> DrainedProfiles { get; } = [];

        public ConcurrentBag<string> StoppedProfiles { get; } = [];

        public HashSet<string> NotReadyProfiles { get; } = [];

        public ConcurrentDictionary<string, PreparationGate> PreparationGates { get; } = new();

        public ConcurrentDictionary<string, CancellationTokenSource> CancelWhenReady { get; } = new();

        public PreparationGate BlockPreparation(string profileId)
        {
            var gate = new PreparationGate();
            Assert.True(PreparationGates.TryAdd(profileId, gate));
            return gate;
        }

        public BackendFixture Instance(string profileId) =>
            instances.Values.Single(instance => instance.ProfileId == profileId);

        public async Task<BackendInstance> PrepareAsync(
            ProfileConfiguration profile,
            CancellationToken cancellationToken = default)
        {
            if (PreparationGates.TryGetValue(profile.Id, out var gate))
            {
                gate.Entered.TrySetResult();
                await gate.Release.Task.WaitAsync(cancellationToken);
            }

            var fixture = await BackendFixture.StartAsync(profile.Id, cancellationToken);
            if (!instances.TryAdd(fixture.Instance, fixture))
            {
                await fixture.DisposeAsync();
                throw new InvalidOperationException("Duplicate backend instance.");
            }

            PreparedProfiles.Add(profile.Id);
            return fixture.Instance;
        }

        public Task<bool> ProbeReadyAsync(
            BackendInstance instance,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var profileId = instances[instance].ProfileId;
            if (CancelWhenReady.TryGetValue(profileId, out var cancellation))
            {
                cancellation.Cancel();
            }

            return Task.FromResult(!NotReadyProfiles.Contains(profileId));
        }

        public Task DrainAsync(BackendInstance instance, CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            DrainedProfiles.Add(instances[instance].ProfileId);
            return Task.CompletedTask;
        }

        public async Task StopAsync(BackendInstance instance, CancellationToken cancellationToken = default)
        {
            if (instances.TryRemove(instance, out var fixture))
            {
                StoppedProfiles.Add(fixture.ProfileId);
                await fixture.DisposeAsync();
            }
        }

        public async ValueTask DisposeAsync()
        {
            foreach (var instance in instances.Keys.ToArray())
            {
                await StopAsync(instance);
            }
        }
    }

    private sealed class PreparationGate
    {
        public TaskCompletionSource Entered { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        public TaskCompletionSource Release { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
    }

    private sealed class BackendFixture : IAsyncDisposable
    {
        private readonly WebApplication application;

        private BackendFixture(string profileId, WebApplication application, BackendInstance instance)
        {
            ProfileId = profileId;
            this.application = application;
            Instance = instance;
        }

        public string ProfileId { get; }

        public BackendInstance Instance { get; }

        public TaskCompletionSource FirstStreamEventWritten { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        public TaskCompletionSource ReleaseFinalStreamEvent { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        public static async Task<BackendFixture> StartAsync(
            string profileId,
            CancellationToken cancellationToken)
        {
            var builder = WebApplication.CreateSlimBuilder();
            builder.Logging.ClearProviders();
            builder.WebHost.ConfigureKestrel(server =>
            {
                server.AddServerHeader = false;
                server.Listen(IPAddress.Loopback, 0, listen => listen.Protocols = HttpProtocols.Http1);
            });
            var application = builder.Build();
            BackendFixture? fixture = null;
            application.MapPost("/{**path}", async context =>
            {
                using var document = await JsonDocument.ParseAsync(context.Request.Body, cancellationToken: context.RequestAborted);
                var expectedProfile = document.RootElement.GetProperty("expected_profile").GetString();
                if (!string.Equals(expectedProfile, profileId, StringComparison.Ordinal))
                {
                    context.Response.StatusCode = StatusCodes.Status409Conflict;
                    return;
                }

                var streaming = document.RootElement.GetProperty("stream").GetBoolean();
                if (streaming)
                {
                    context.Response.ContentType = "text/event-stream";
                    await context.Response.WriteAsync("data: {\"backend\":\"first\"}\n\n", context.RequestAborted);
                    await context.Response.Body.FlushAsync(context.RequestAborted);
                    fixture!.FirstStreamEventWritten.TrySetResult();
                    await fixture.ReleaseFinalStreamEvent.Task.WaitAsync(context.RequestAborted);
                    await context.Response.WriteAsync("data: [DONE]\n\n", context.RequestAborted);
                    return;
                }

                await context.Response.WriteAsJsonAsync(new { backend = profileId }, context.RequestAborted);
            });
            await application.StartAsync(cancellationToken);
            var address = application.Services.GetRequiredService<IServer>()
                .Features.Get<IServerAddressesFeature>()?.Addresses.Single()
                ?? throw new InvalidOperationException("Backend address was not reported.");
            fixture = new BackendFixture(
                profileId,
                application,
                new BackendInstance(new Uri(address), $"internal-{profileId}"));
            return fixture;
        }

        public async ValueTask DisposeAsync()
        {
            ReleaseFinalStreamEvent.TrySetResult();
            await application.StopAsync();
            await application.DisposeAsync();
        }
    }
}
