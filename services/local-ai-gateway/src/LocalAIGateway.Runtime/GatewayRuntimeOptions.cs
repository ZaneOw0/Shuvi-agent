using System.Net;
using LocalAIGateway.Core.Backend;
using LocalAIGateway.Core.Configuration;

namespace LocalAIGateway.Runtime;

public sealed record GatewayRuntimeOptions
{
    public const int ProductionPort = 4000;
    public const long DefaultMaxRequestBodyBytes = 8 * 1024 * 1024;
    public const int DefaultCircuitFailureThreshold = 5;

    public required GatewayConfiguration Configuration { get; init; }

    public required string ClientToken { get; init; }

    public required IBackendHost BackendHost { get; init; }

    public IPAddress ListenAddress { get; init; } = IPAddress.Loopback;

    public int Port { get; init; } = ProductionPort;

    public long MaxRequestBodyBytes { get; init; } = DefaultMaxRequestBodyBytes;

    public TimeSpan ForwardingTimeout { get; init; } = TimeSpan.FromMinutes(5);

    public TimeSpan BackendReadyTimeout { get; init; } = TimeSpan.FromSeconds(60);

    public TimeSpan BackendReadyPollInterval { get; init; } = TimeSpan.FromMilliseconds(100);

    public int CircuitFailureThreshold { get; init; } = DefaultCircuitFailureThreshold;

    public TimeSpan CircuitOpenDuration { get; init; } = TimeSpan.FromSeconds(30);

    public TimeProvider TimeProvider { get; init; } = TimeProvider.System;
}
