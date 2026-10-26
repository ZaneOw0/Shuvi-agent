using System.Net;
using LocalAIGateway.Core.Backend;
using LocalAIGateway.Core.Configuration;
using Microsoft.AspNetCore.Connections;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Server.Kestrel.Core;
using Microsoft.Extensions.DependencyInjection;
using Yarp.ReverseProxy.Forwarder;

namespace LocalAIGateway.Runtime;

public sealed class GatewayRuntimeHost : IAsyncDisposable
{
    private readonly WebApplication application;
    private readonly GatewayRouteCoordinator routeCoordinator;
    private readonly HttpMessageInvoker httpClient;
    private readonly object disposeLock = new();
    private Task? disposeTask;

    private GatewayRuntimeHost(
        WebApplication application,
        GatewayRouteCoordinator routeCoordinator,
        HttpMessageInvoker httpClient,
        Uri baseAddress)
    {
        this.application = application;
        this.routeCoordinator = routeCoordinator;
        this.httpClient = httpClient;
        BaseAddress = baseAddress;
    }

    public Uri BaseAddress { get; }

    public static async Task<GatewayRuntimeHost> StartAsync(
        GatewayRuntimeOptions options,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(options);
        ValidateOptions(options);
        GatewayRouteCoordinator? routeCoordinator = null;
        WebApplication? application = null;
        HttpMessageInvoker? httpClient = null;
        try
        {
            routeCoordinator = await GatewayRouteCoordinator.StartAsync(options, cancellationToken);

            var builder = WebApplication.CreateSlimBuilder(new WebApplicationOptions
            {
                ApplicationName = typeof(GatewayRuntimeHost).Assembly.FullName,
                Args = [],
            });
            builder.Logging.ClearProviders();
            builder.WebHost.ConfigureKestrel(server =>
            {
                server.AddServerHeader = false;
                server.Listen(options.ListenAddress, options.Port, listen =>
                {
                    listen.Protocols = HttpProtocols.Http1;
                });
            });
            builder.Services.AddHttpForwarder();

            application = builder.Build();
            httpClient = new HttpMessageInvoker(new SocketsHttpHandler
            {
                AllowAutoRedirect = false,
                AutomaticDecompression = DecompressionMethods.None,
                UseCookies = false,
                UseProxy = false,
            });
            var handler = new GatewayRequestHandler(
                options,
                routeCoordinator,
                application.Services.GetRequiredService<IHttpForwarder>(),
                httpClient);

            application.Use(handler.AuthenticateAsync);
            application.Use(PublicEndpointPolicy.InvokeAsync);
            application.MapGet("/health", handler.HealthAsync);
            application.MapGet("/ready", handler.ReadyAsync);
            application.MapGet("/v1/models", handler.ModelsAsync);
            application.MapPost("/v1/chat/completions", handler.ProxyAsync);
            application.MapPost("/v1/responses", handler.ProxyAsync);
            application.MapPost("/v1/messages", handler.ProxyAsync);

            await application.StartAsync(cancellationToken);
            var server = application.Services.GetRequiredService<IServer>();
            var address = server.Features.Get<IServerAddressesFeature>()?.Addresses.SingleOrDefault()
                ?? throw new RuntimeGatewayException(
                    "aigw_runtime_address_unavailable",
                    "Gateway listen address was not reported by Kestrel.");
            return new GatewayRuntimeHost(
                application,
                routeCoordinator,
                httpClient,
                new Uri(address));
        }
        catch (Exception exception) when (IsAddressInUse(exception))
        {
            await CleanupFailedStartAsync(application, httpClient, routeCoordinator);
            throw new RuntimeConflictException(options.Port, exception);
        }
        catch
        {
            await CleanupFailedStartAsync(application, httpClient, routeCoordinator);
            throw;
        }
    }

    public GatewayRuntimeStatus GetStatus() => routeCoordinator.GetStatus();

    internal int TrackedRetirementCount => routeCoordinator.TrackedRetirementCount;

    public Task<GatewayReloadResult> ReloadAsync(
        GatewayConfiguration configuration,
        CancellationToken cancellationToken = default) =>
        routeCoordinator.ReloadAsync(configuration, cancellationToken);

    public Task RecordReloadFailureAsync(
        string errorCode,
        CancellationToken cancellationToken = default) =>
        routeCoordinator.RecordReloadFailureAsync(errorCode, cancellationToken);

    public ValueTask DisposeAsync()
    {
        lock (disposeLock)
        {
            disposeTask ??= DisposeCoreAsync();
            return new ValueTask(disposeTask);
        }
    }

    private async Task DisposeCoreAsync()
    {
        try
        {
            await application.StopAsync();
        }
        finally
        {
            try
            {
                await routeCoordinator.DisposeAsync();
            }
            finally
            {
                httpClient.Dispose();
                await application.DisposeAsync();
            }
        }
    }

    private static async Task CleanupFailedStartAsync(
        WebApplication? application,
        HttpMessageInvoker? httpClient,
        GatewayRouteCoordinator? routeCoordinator)
    {
        try
        {
            if (application is not null)
            {
                try
                {
                    await application.DisposeAsync();
                }
                catch
                {
                    // Preserve the startup failure. Continue with remaining cleanup.
                }
            }
        }
        finally
        {
            try
            {
                httpClient?.Dispose();
            }
            finally
            {
                if (routeCoordinator is not null)
                {
                    try
                    {
                        await routeCoordinator.DisposeAsync();
                    }
                    catch
                    {
                        // Preserve the startup failure. Backend cleanup is best effort on this path.
                    }
                }
            }
        }
    }

    private static void ValidateOptions(GatewayRuntimeOptions options)
    {
        if (options.Configuration is null)
        {
            throw new RuntimeGatewayException(
                "aigw_runtime_configuration_missing",
                "Gateway configuration is missing.");
        }

        if (options.BackendHost is null)
        {
            throw new RuntimeGatewayException(
                "aigw_runtime_backend_host_missing",
                "Gateway backend host is missing.");
        }

        var validation = ConfigurationValidator.Validate(options.Configuration);
        if (!validation.IsValid)
        {
            throw new ConfigurationValidationException(validation.Errors);
        }

        if (!IPAddress.IsLoopback(options.ListenAddress))
        {
            throw new RuntimeGatewayException(
                "aigw_runtime_listen_address_invalid",
                "Gateway must listen on a loopback address.");
        }

        if (options.Port is < 0 or > 65535)
        {
            throw new RuntimeGatewayException("aigw_runtime_port_invalid", "Gateway port is invalid.");
        }

        if (options.MaxRequestBodyBytes <= 0)
        {
            throw new RuntimeGatewayException(
                "aigw_runtime_request_limit_invalid",
                "Gateway request body limit must be positive.");
        }

        if (options.ForwardingTimeout <= TimeSpan.Zero)
        {
            throw new RuntimeGatewayException(
                "aigw_runtime_forwarding_timeout_invalid",
                "Gateway forwarding timeout must be positive.");
        }

        if (options.BackendReadyTimeout <= TimeSpan.Zero ||
            options.BackendReadyTimeout > TimeSpan.FromMinutes(5))
        {
            throw new RuntimeGatewayException(
                "aigw_runtime_backend_ready_timeout_invalid",
                "Gateway backend readiness timeout must be positive and no greater than five minutes.");
        }

        if (options.BackendReadyPollInterval <= TimeSpan.Zero ||
            options.BackendReadyPollInterval > options.BackendReadyTimeout)
        {
            throw new RuntimeGatewayException(
                "aigw_runtime_backend_ready_poll_invalid",
                "Gateway backend readiness poll interval must be positive and no greater than the timeout.");
        }

        if (options.CircuitFailureThreshold is < 1 or > 1000)
        {
            throw new RuntimeGatewayException(
                "aigw_runtime_circuit_threshold_invalid",
                "Gateway circuit failure threshold must be between 1 and 1000.");
        }

        if (options.CircuitOpenDuration <= TimeSpan.Zero ||
            options.CircuitOpenDuration > TimeSpan.FromHours(1))
        {
            throw new RuntimeGatewayException(
                "aigw_runtime_circuit_duration_invalid",
                "Gateway circuit open duration must be positive and no greater than one hour.");
        }

        if (options.TimeProvider is null)
        {
            throw new RuntimeGatewayException(
                "aigw_runtime_time_provider_missing",
                "Gateway time provider is missing.");
        }
    }

    private static bool IsAddressInUse(Exception exception)
    {
        for (var current = exception; current is not null; current = current.InnerException)
        {
            if (current is AddressInUseException)
            {
                return true;
            }
        }

        return false;
    }

}
