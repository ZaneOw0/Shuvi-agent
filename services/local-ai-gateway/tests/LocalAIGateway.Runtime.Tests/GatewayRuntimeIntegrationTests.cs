using System.Diagnostics;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using LocalAIGateway.Core.Backend;
using LocalAIGateway.Core.Configuration;
using LocalAIGateway.Core.Control;

namespace LocalAIGateway.Runtime.Tests;

public sealed class GatewayRuntimeIntegrationTests
{
    private const string ClientToken = "local-client-token";

    [Fact]
    public async Task Authentication_accepts_bearer_or_api_key_and_rejects_missing_bad_or_conflicting_tokens()
    {
        await using var fixture = await RuntimeFixture.StartAsync();

        using var missing = await fixture.Client.GetAsync("/health");
        Assert.Equal(HttpStatusCode.Unauthorized, missing.StatusCode);

        using var badRequest = new HttpRequestMessage(HttpMethod.Get, "/health");
        badRequest.Headers.Authorization = new AuthenticationHeaderValue("Bearer", "wrong");
        using var bad = await fixture.Client.SendAsync(badRequest);
        Assert.Equal(HttpStatusCode.Unauthorized, bad.StatusCode);

        using var nonBearerRequest = new HttpRequestMessage(HttpMethod.Get, "/health");
        nonBearerRequest.Headers.Authorization = new AuthenticationHeaderValue("Basic", ClientToken);
        using var nonBearer = await fixture.Client.SendAsync(nonBearerRequest);
        Assert.Equal(HttpStatusCode.Unauthorized, nonBearer.StatusCode);

        using var duplicateRequest = new HttpRequestMessage(HttpMethod.Get, "/health");
        Assert.True(duplicateRequest.Headers.TryAddWithoutValidation(
            "Authorization",
            ["Bearer local-client-token", "Bearer local-client-token"]));
        using var duplicate = await fixture.Client.SendAsync(duplicateRequest);
        Assert.Equal(HttpStatusCode.Unauthorized, duplicate.StatusCode);

        using var bearerRequest = new HttpRequestMessage(HttpMethod.Get, "/health");
        bearerRequest.Headers.Authorization = new AuthenticationHeaderValue("Bearer", ClientToken);
        using var bearer = await fixture.Client.SendAsync(bearerRequest);
        Assert.Equal(HttpStatusCode.OK, bearer.StatusCode);

        using var apiKeyRequest = new HttpRequestMessage(HttpMethod.Get, "/health");
        apiKeyRequest.Headers.Add("x-api-key", ClientToken);
        using var apiKey = await fixture.Client.SendAsync(apiKeyRequest);
        Assert.Equal(HttpStatusCode.OK, apiKey.StatusCode);

        using var conflictRequest = new HttpRequestMessage(HttpMethod.Get, "/health");
        conflictRequest.Headers.Authorization = new AuthenticationHeaderValue("Bearer", ClientToken);
        conflictRequest.Headers.Add("x-api-key", "different");
        using var conflict = await fixture.Client.SendAsync(conflictRequest);
        Assert.Equal(HttpStatusCode.Unauthorized, conflict.StatusCode);
    }

    [Fact]
    public async Task Models_returns_only_public_aliases_without_upstream_or_credential_details()
    {
        await using var fixture = await RuntimeFixture.StartAsync();

        using var request = Authorized(HttpMethod.Get, "/v1/models");
        using var response = await fixture.Client.SendAsync(request);
        var payload = await response.Content.ReadAsStringAsync();

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Contains("public-chat", payload, StringComparison.Ordinal);
        Assert.Contains("public-reasoning", payload, StringComparison.Ordinal);
        Assert.DoesNotContain("upstream-secret-chat", payload, StringComparison.Ordinal);
        Assert.DoesNotContain("upstream-secret-reasoning", payload, StringComparison.Ordinal);
        Assert.DoesNotContain("LocalAIGateway/profile/provider/api-key", payload, StringComparison.Ordinal);
        Assert.DoesNotContain("127.0.0.1:9999", payload, StringComparison.Ordinal);
        Assert.DoesNotContain(fixture.Backend.InternalToken, payload, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Invalid_circuit_runtime_options_fail_before_backend_start()
    {
        await using var backend = new DeterministicBackendHost();
        var baseline = RuntimeFixture.CreateOptions(backend, 0);
        var cases = new (GatewayRuntimeOptions Options, string ErrorCode)[]
        {
            (baseline with { CircuitFailureThreshold = 0 }, "aigw_runtime_circuit_threshold_invalid"),
            (baseline with { CircuitOpenDuration = TimeSpan.Zero }, "aigw_runtime_circuit_duration_invalid"),
            (baseline with { TimeProvider = null! }, "aigw_runtime_time_provider_missing"),
        };

        foreach (var item in cases)
        {
            var exception = await Assert.ThrowsAsync<RuntimeGatewayException>(
                () => GatewayRuntimeHost.StartAsync(item.Options));
            Assert.Equal(item.ErrorCode, exception.ErrorCode);
        }

        Assert.Equal(0, backend.PrepareCount);
    }

    [Fact]
    public async Task Chat_rewrites_alias_and_removes_client_credentials_and_forwarding_headers()
    {
        await using var fixture = await RuntimeFixture.StartAsync();
        using var request = AuthorizedJson("/v1/chat/completions", "public-chat");
        request.Headers.Add("x-api-key", ClientToken);
        request.Headers.Add("Cookie", "session=client-secret");
        request.Headers.Add("X-Forwarded-For", "203.0.113.10");
        request.Headers.Add("X-Forwarded-Host", "attacker.example");

        using var response = await fixture.Client.SendAsync(request);
        var responseText = await response.Content.ReadAsStringAsync();

        Assert.True(
            response.IsSuccessStatusCode,
            $"Gateway returned {(int)response.StatusCode}: {responseText}; backend requests: {fixture.Backend.RequestCount}");
        Assert.DoesNotContain("Set-Cookie", response.Headers.Select(header => header.Key), StringComparer.OrdinalIgnoreCase);
        Assert.Contains("public-chat", responseText, StringComparison.Ordinal);
        Assert.DoesNotContain("aigw-internal/", responseText, StringComparison.Ordinal);
        Assert.DoesNotContain("upstream-secret-chat", responseText, StringComparison.Ordinal);
        var backendRequest = Assert.Single(fixture.Backend.Requests);
        Assert.Equal("/v1/chat/completions", backendRequest.Path);
        Assert.Equal($"Bearer {fixture.Backend.InternalToken}", backendRequest.Headers["Authorization"]);
        Assert.False(backendRequest.Headers.ContainsKey("x-api-key"));
        Assert.False(backendRequest.Headers.ContainsKey("Cookie"));
        Assert.False(backendRequest.Headers.ContainsKey("X-Forwarded-For"));
        Assert.False(backendRequest.Headers.ContainsKey("X-Forwarded-Host"));
        using var body = JsonDocument.Parse(backendRequest.Body);
        Assert.Equal(
            "public-chat",
            body.RootElement.GetProperty("model").GetString());
    }

    [Theory]
    [InlineData("/v1/responses", false)]
    [InlineData("/v1/messages", true)]
    public async Task Responses_and_anthropic_messages_are_forwarded_with_alias_rewrite(
        string path,
        bool useAnthropicHeader)
    {
        await using var fixture = await RuntimeFixture.StartAsync();
        using var request = AuthorizedJson(path, "public-reasoning", useAnthropicHeader);

        using var response = await fixture.Client.SendAsync(request);
        using var payload = JsonDocument.Parse(await response.Content.ReadAsStringAsync());

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal(path, payload.RootElement.GetProperty("path").GetString());
        Assert.Equal(
            "public-reasoning",
            payload.RootElement.GetProperty("model").GetString());
        var backendRequest = Assert.Single(fixture.Backend.Requests);
        Assert.Equal($"Bearer {fixture.Backend.InternalToken}", backendRequest.Headers["Authorization"]);
        Assert.False(backendRequest.Headers.ContainsKey("x-api-key"));
    }

    [Theory]
    [InlineData("/v1/chat/completions", "tool_calls")]
    [InlineData("/v1/responses", "function_call")]
    [InlineData("/v1/messages", "tool_use")]
    public async Task Tool_call_payload_is_passed_through_for_each_supported_protocol(
        string path,
        string expectedProtocolMarker)
    {
        await using var fixture = await RuntimeFixture.StartAsync();
        using var request = AuthorizedToolJson(path);

        using var response = await fixture.Client.SendAsync(request);
        var payload = await response.Content.ReadAsStringAsync();

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Contains(expectedProtocolMarker, payload, StringComparison.Ordinal);
        Assert.Contains("call_fixed", payload, StringComparison.Ordinal);
        Assert.Contains("get_weather", payload, StringComparison.Ordinal);
        Assert.Contains("Shanghai", payload, StringComparison.Ordinal);
        var backendRequest = Assert.Single(fixture.Backend.Requests);
        using var backendBody = JsonDocument.Parse(backendRequest.Body);
        Assert.Equal(
            "public-chat",
            backendBody.RootElement.GetProperty("model").GetString());
        Assert.True(backendBody.RootElement.TryGetProperty("tools", out _));
    }

    [Fact]
    public async Task Sse_is_streamed_before_backend_completes()
    {
        await using var fixture = await RuntimeFixture.StartAsync();
        using var request = AuthorizedStreamingJson("/v1/chat/completions", "public-chat");
        using var response = await fixture.Client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead);

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal("text/event-stream", response.Content.Headers.ContentType?.MediaType);
        await fixture.Backend.FirstSseEventWritten.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await using var stream = await response.Content.ReadAsStreamAsync();
        using var reader = new StreamReader(stream);
        var firstLine = await reader.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal("data: {\"event\":1}", firstLine);
        Assert.False(fixture.Backend.ReleaseFinalSseEvent.Task.IsCompleted);

        fixture.Backend.ReleaseFinalSseEvent.TrySetResult();
        var remainder = await reader.ReadToEndAsync().WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Contains("data: [DONE]", remainder, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Unknown_model_is_rejected_before_backend_is_reached()
    {
        await using var fixture = await RuntimeFixture.StartAsync();
        using var request = AuthorizedJson("/v1/chat/completions", "not-configured");

        using var response = await fixture.Client.SendAsync(request);
        var payload = await response.Content.ReadAsStringAsync();

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.Contains("aigw_model_unknown", payload, StringComparison.Ordinal);
        Assert.Equal(0, fixture.Backend.RequestCount);
    }

    [Theory]
    [InlineData("status-400", 400, "{\"upstream\":\"bad-request\"}")]
    [InlineData("status-401", 401, "{\"upstream\":\"unauthorized\"}")]
    [InlineData("status-403", 403, "{\"upstream\":\"forbidden\"}")]
    [InlineData("status-500", 500, "{\"upstream\":\"internal-error\"}")]
    public async Task Non_retryable_upstream_status_and_body_are_passed_through_once(
        string fault,
        int expectedStatus,
        string expectedBody)
    {
        await using var fixture = await RuntimeFixture.StartAsync();
        using var request = AuthorizedFaultJson(fault);

        using var response = await fixture.Client.SendAsync(request);
        var body = await response.Content.ReadAsStringAsync();

        Assert.Equal(expectedStatus, (int)response.StatusCode);
        Assert.Equal(expectedBody, body);
        Assert.Equal(1, fixture.Backend.RequestCount);
    }

    [Theory]
    [InlineData("status-429", 429, "{\"upstream\":\"rate-limited\"}")]
    [InlineData("status-502", 502, "{\"upstream\":\"bad-gateway\"}")]
    [InlineData("status-503", 503, "{\"upstream\":\"unavailable\"}")]
    [InlineData("status-504", 504, "{\"upstream\":\"gateway-timeout\"}")]
    public async Task Retryable_upstream_status_stops_after_two_retries_and_passes_final_response(
        string fault,
        int expectedStatus,
        string expectedBody)
    {
        await using var fixture = await RuntimeFixture.StartAsync();
        using var request = AuthorizedFaultJson(fault);

        using var response = await fixture.Client.SendAsync(request);
        var body = await response.Content.ReadAsStringAsync();

        Assert.Equal(expectedStatus, (int)response.StatusCode);
        Assert.Equal(expectedBody, body);
        Assert.Equal(3, fixture.Backend.RequestCount);
        Assert.Single(fixture.Backend.Requests.Select(item => item.Body).Distinct(StringComparer.Ordinal));
    }

    [Fact]
    public async Task Per_model_circuit_opens_blocks_recovers_through_one_half_open_probe_and_reports_status()
    {
        var time = new MutableTimeProvider(
            new DateTimeOffset(2026, 9, 15, 12, 0, 0, TimeSpan.Zero));
        await using var fixture = await RuntimeFixture.StartAsync(
            circuitFailureThreshold: 2,
            circuitOpenDuration: TimeSpan.FromSeconds(30),
            timeProvider: time);

        for (var failure = 0; failure < 2; failure++)
        {
            using var request = AuthorizedFaultJson("status-503");
            using var response = await fixture.Client.SendAsync(request);
            Assert.Equal(HttpStatusCode.ServiceUnavailable, response.StatusCode);
        }

        Assert.Equal(6, fixture.Backend.RequestCount);
        var opened = Assert.Single(
            fixture.Gateway.GetStatus().TargetCircuits,
            circuit => circuit.ModelAlias == "public-chat");
        Assert.Equal("provider", opened.ProviderId);
        Assert.Equal(CircuitStates.Open, opened.State);
        Assert.Equal(2, opened.ConsecutiveFailures);
        Assert.Equal(time.GetUtcNow().AddSeconds(30), opened.OpenUntilUtc);

        using (var blockedRequest = AuthorizedJson("/v1/chat/completions", "public-chat"))
        using (var blocked = await fixture.Client.SendAsync(blockedRequest))
        {
            var body = await blocked.Content.ReadAsStringAsync();
            Assert.Equal(HttpStatusCode.ServiceUnavailable, blocked.StatusCode);
            Assert.Equal(TimeSpan.FromSeconds(30), blocked.Headers.RetryAfter?.Delta);
            Assert.Contains("aigw_target_circuit_open", body, StringComparison.Ordinal);
        }

        Assert.Equal(6, fixture.Backend.RequestCount);
        using (var otherTargetRequest = AuthorizedJson("/v1/chat/completions", "public-reasoning"))
        using (var otherTarget = await fixture.Client.SendAsync(otherTargetRequest))
        {
            Assert.Equal(HttpStatusCode.OK, otherTarget.StatusCode);
        }

        Assert.Equal(CircuitStates.Closed, Assert.Single(
            fixture.Gateway.GetStatus().TargetCircuits,
            circuit => circuit.ModelAlias == "public-reasoning").State);

        time.Advance(TimeSpan.FromSeconds(30));
        using (var probeRequest = AuthorizedJson("/v1/chat/completions", "public-chat"))
        using (var probe = await fixture.Client.SendAsync(probeRequest))
        {
            Assert.Equal(HttpStatusCode.OK, probe.StatusCode);
        }

        var recovered = Assert.Single(
            fixture.Gateway.GetStatus().TargetCircuits,
            circuit => circuit.ModelAlias == "public-chat");
        Assert.Equal(CircuitStates.Closed, recovered.State);
        Assert.Equal(0, recovered.ConsecutiveFailures);
        Assert.Null(recovered.OpenUntilUtc);
        Assert.Equal(8, fixture.Backend.RequestCount);
    }

    [Theory]
    [InlineData("transient-status-429-once")]
    [InlineData("transient-status-502-once")]
    [InlineData("transient-status-503-once")]
    [InlineData("transient-status-504-once")]
    public async Task Transient_retryable_status_replays_request_and_returns_success(string fault)
    {
        await using var fixture = await RuntimeFixture.StartAsync();
        using var request = AuthorizedFaultJson(fault);

        using var response = await fixture.Client.SendAsync(request);
        var body = await response.Content.ReadAsStringAsync();

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Contains("\"ok\":true", body, StringComparison.Ordinal);
        Assert.Null(response.Headers.RetryAfter);
        Assert.Equal(2, fixture.Backend.RequestCount);
        Assert.Single(fixture.Backend.Requests.Select(item => item.Body).Distinct(StringComparer.Ordinal));
    }

    [Fact]
    public async Task Two_transient_failures_consume_both_retries_then_return_success()
    {
        await using var fixture = await RuntimeFixture.StartAsync();
        using var request = AuthorizedFaultJson("transient-status-503-twice");

        using var response = await fixture.Client.SendAsync(request);

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal(3, fixture.Backend.RequestCount);
        Assert.Single(fixture.Backend.Requests.Select(item => item.Body).Distinct(StringComparer.Ordinal));
    }

    [Fact]
    public async Task Retry_after_delta_is_honored_before_replaying_request()
    {
        await using var fixture = await RuntimeFixture.StartAsync();
        using var request = AuthorizedFaultJson("retry-after-429-once");
        var stopwatch = Stopwatch.StartNew();

        using var response = await fixture.Client.SendAsync(request);
        stopwatch.Stop();

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal(2, fixture.Backend.RequestCount);
        Assert.True(stopwatch.Elapsed >= TimeSpan.FromMilliseconds(850), stopwatch.Elapsed.ToString());
    }

    [Fact]
    public async Task Retry_after_beyond_bound_is_passed_through_without_retrying_early()
    {
        await using var fixture = await RuntimeFixture.StartAsync();
        using var request = AuthorizedFaultJson("retry-after-503-too-long");

        using var response = await fixture.Client.SendAsync(request);
        var body = await response.Content.ReadAsStringAsync();

        Assert.Equal(HttpStatusCode.ServiceUnavailable, response.StatusCode);
        Assert.Equal("{\"upstream\":\"unavailable\"}", body);
        Assert.Equal(TimeSpan.FromSeconds(61), response.Headers.RetryAfter?.Delta);
        Assert.Equal(1, fixture.Backend.RequestCount);
    }

    [Fact]
    public async Task Client_cancellation_during_retry_after_stops_before_next_attempt()
    {
        await using var fixture = await RuntimeFixture.StartAsync();
        using var request = AuthorizedFaultJson("retry-after-503-cancel");
        using var cancellation = new CancellationTokenSource();

        var send = fixture.Client.SendAsync(request, cancellation.Token);
        await fixture.Backend.FaultRequestReceived.Task.WaitAsync(TimeSpan.FromSeconds(5));
        cancellation.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => send);
        await Task.Delay(100);
        Assert.Equal(1, fixture.Backend.RequestCount);
        Assert.Equal(0, Assert.Single(
            fixture.Gateway.GetStatus().TargetCircuits,
            circuit => circuit.ModelAlias == "public-chat").ConsecutiveFailures);
    }

    [Fact]
    public async Task Disconnect_before_response_headers_retries_twice_then_returns_502()
    {
        await using var fixture = await RuntimeFixture.StartAsync();
        using var request = AuthorizedFaultJson("disconnect-before-headers");

        using var response = await fixture.Client.SendAsync(request);
        var body = await response.Content.ReadAsStringAsync();

        Assert.Equal(HttpStatusCode.BadGateway, response.StatusCode);
        Assert.Contains("aigw_backend_proxy_failed", body, StringComparison.Ordinal);
        Assert.Equal(3, fixture.Backend.RequestCount);
    }

    [Fact]
    public async Task Forwarding_timeout_retries_twice_then_returns_504_and_aborts_backend_requests()
    {
        await using var fixture = await RuntimeFixture.StartAsync(TimeSpan.FromMilliseconds(250));
        using var request = AuthorizedFaultJson("wait-for-cancel");

        using var response = await fixture.Client.SendAsync(request);
        var body = await response.Content.ReadAsStringAsync();
        await fixture.Backend.RequestAbortedObserved.Task.WaitAsync(TimeSpan.FromSeconds(5));

        Assert.Equal(HttpStatusCode.GatewayTimeout, response.StatusCode);
        Assert.Contains("aigw_backend_proxy_failed", body, StringComparison.Ordinal);
        Assert.Equal(3, fixture.Backend.RequestCount);
    }

    [Fact]
    public async Task Disconnect_after_first_sse_event_does_not_append_gateway_json_error()
    {
        await using var fixture = await RuntimeFixture.StartAsync();
        using var request = AuthorizedFaultJson("disconnect-after-sse", stream: true);
        HttpResponseMessage? response = null;
        try
        {
            response = await fixture.Client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead);
            Assert.Equal(HttpStatusCode.OK, response.StatusCode);
            Assert.Equal("text/event-stream", response.Content.Headers.ContentType?.MediaType);
            await fixture.Backend.FirstSseEventWritten.Task.WaitAsync(TimeSpan.FromSeconds(5));
            await using var stream = await response.Content.ReadAsStreamAsync();
            using var reader = new StreamReader(stream);
            var firstLine = await reader.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(5));
            Assert.Equal("data: {\"event\":1}", firstLine);
            fixture.Backend.ReleaseSseDisconnect.TrySetResult();

            var remainder = string.Empty;
            try
            {
                remainder = await reader.ReadToEndAsync().WaitAsync(TimeSpan.FromSeconds(5));
            }
            catch (IOException)
            {
                // A truncated HTTP response is an expected client-visible result after headers have started.
            }

            Assert.DoesNotContain("aigw_backend_proxy_failed", remainder, StringComparison.Ordinal);
            Assert.DoesNotContain("invalid_request_error", remainder, StringComparison.Ordinal);
            Assert.Equal(1, fixture.Backend.RequestCount);
        }
        finally
        {
            fixture.Backend.ReleaseSseDisconnect.TrySetResult();
            response?.Dispose();
        }
    }

    [Fact]
    public async Task Client_cancellation_is_propagated_to_backend_request()
    {
        await using var fixture = await RuntimeFixture.StartAsync();
        using var request = AuthorizedFaultJson("wait-for-cancel");
        using var cancellation = new CancellationTokenSource();

        var send = fixture.Client.SendAsync(
            request,
            HttpCompletionOption.ResponseHeadersRead,
            cancellation.Token);
        await fixture.Backend.FaultRequestReceived.Task.WaitAsync(TimeSpan.FromSeconds(5));
        cancellation.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => send);
        await fixture.Backend.RequestAbortedObserved.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(1, fixture.Backend.RequestCount);
    }

    [Fact]
    public async Task Unauthenticated_unknown_path_and_wrong_method_are_rejected_before_route_disclosure()
    {
        await using var fixture = await RuntimeFixture.StartAsync();

        using var unknown = await fixture.Client.GetAsync("/not-a-public-route");
        using var wrongMethod = await fixture.Client.PostAsync("/health", content: null);
        Assert.Equal(HttpStatusCode.Unauthorized, unknown.StatusCode);
        Assert.Equal(HttpStatusCode.Unauthorized, wrongMethod.StatusCode);

        using var authorizedUnknownRequest = Authorized(HttpMethod.Get, "/not-a-public-route");
        using var authorizedUnknown = await fixture.Client.SendAsync(authorizedUnknownRequest);
        using var authorizedWrongMethodRequest = Authorized(HttpMethod.Post, "/health");
        using var authorizedWrongMethod = await fixture.Client.SendAsync(authorizedWrongMethodRequest);
        Assert.Equal(HttpStatusCode.NotFound, authorizedUnknown.StatusCode);
        Assert.Equal(HttpStatusCode.MethodNotAllowed, authorizedWrongMethod.StatusCode);
    }

    [Fact]
    public async Task Ready_reflects_backend_probe_and_configuration_revision()
    {
        await using var fixture = await RuntimeFixture.StartAsync();
        using var readyRequest = Authorized(HttpMethod.Get, "/ready");
        using var ready = await fixture.Client.SendAsync(readyRequest);
        var readyPayload = await ready.Content.ReadAsStringAsync();
        Assert.Equal(HttpStatusCode.OK, ready.StatusCode);
        Assert.Contains("\"configurationRevision\":42", readyPayload, StringComparison.Ordinal);

        fixture.Backend.IsReady = false;
        using var unavailableRequest = Authorized(HttpMethod.Get, "/ready");
        using var unavailable = await fixture.Client.SendAsync(unavailableRequest);
        var unavailablePayload = await unavailable.Content.ReadAsStringAsync();
        Assert.Equal(HttpStatusCode.ServiceUnavailable, unavailable.StatusCode);
        Assert.Contains("aigw_backend_not_ready", unavailablePayload, StringComparison.Ordinal);
        Assert.Equal(3, fixture.Backend.ProbeCount);
        Assert.Equal(0, fixture.Backend.RejectedReadyProbeCount);
    }

    [Fact]
    public async Task Occupied_port_fails_without_replacing_listener_and_stops_prepared_backend()
    {
        using var occupied = new TcpListener(IPAddress.Loopback, 0);
        occupied.Start();
        var port = ((IPEndPoint)occupied.LocalEndpoint).Port;
        await using var backend = new DeterministicBackendHost();
        var options = RuntimeFixture.CreateOptions(backend, port);

        var exception = await Assert.ThrowsAsync<RuntimeConflictException>(
            () => GatewayRuntimeHost.StartAsync(options));

        Assert.Equal("aigw_runtime_port_in_use", exception.ErrorCode);
        Assert.Equal(port, exception.Port);
        Assert.Equal(1, backend.PrepareCount);
        Assert.Equal(1, backend.StopCount);
        using var probe = new TcpClient();
        await probe.ConnectAsync(IPAddress.Loopback, port);
        Assert.True(probe.Connected);
    }

    [Fact]
    public async Task Dispose_drains_and_stops_backend_once_and_releases_gateway_port()
    {
        await using var backend = new DeterministicBackendHost();
        var host = await GatewayRuntimeHost.StartAsync(RuntimeFixture.CreateOptions(backend, 0));
        var port = host.BaseAddress.Port;
        Assert.Equal(1, backend.PrepareCount);

        await host.DisposeAsync();
        await host.DisposeAsync();

        Assert.Equal(1, backend.DrainCount);
        Assert.Equal(1, backend.StopCount);
        using var probe = new TcpClient();
        await Assert.ThrowsAnyAsync<SocketException>(
            () => probe.ConnectAsync(IPAddress.Loopback, port));
    }

    [Fact]
    public async Task Concurrent_dispose_drains_and_stops_backend_exactly_once()
    {
        await using var backend = new DeterministicBackendHost();
        var host = await GatewayRuntimeHost.StartAsync(RuntimeFixture.CreateOptions(backend, 0));
        using var gate = new ManualResetEventSlim(false);
        var disposals = Enumerable.Range(0, 16)
            .Select(_ => Task.Run(async () =>
            {
                gate.Wait();
                await host.DisposeAsync();
            }))
            .ToArray();

        gate.Set();
        await Task.WhenAll(disposals);

        Assert.Equal(1, backend.DrainCount);
        Assert.Equal(1, backend.StopCount);
    }

    [Fact]
    public async Task Startup_polls_until_a_transiently_unready_backend_becomes_ready()
    {
        await using var backend = new DeterministicBackendHost
        {
            IsReady = false,
            ReadyAfterProbeCount = 3,
        };
        var options = RuntimeFixture.CreateOptions(backend, 0) with
        {
            BackendReadyTimeout = TimeSpan.FromSeconds(1),
            BackendReadyPollInterval = TimeSpan.FromMilliseconds(10),
        };

        await using var host = await GatewayRuntimeHost.StartAsync(options);

        Assert.Equal(3, backend.ProbeCount);
        Assert.Equal(0, backend.StopCount);
    }

    [Fact]
    public async Task Startup_readiness_failure_stops_prepared_backend()
    {
        await using var backend = new DeterministicBackendHost { IsReady = false };
        var options = RuntimeFixture.CreateOptions(backend, 0) with
        {
            BackendReadyTimeout = TimeSpan.FromMilliseconds(100),
            BackendReadyPollInterval = TimeSpan.FromMilliseconds(10),
        };

        var exception = await Assert.ThrowsAsync<BackendUnavailableException>(
            () => GatewayRuntimeHost.StartAsync(options));

        Assert.Equal("aigw_backend_unavailable", exception.ErrorCode);
        Assert.Equal(1, backend.PrepareCount);
        Assert.True(backend.ProbeCount >= 2);
        Assert.Equal(0, backend.DrainCount);
        Assert.Equal(1, backend.StopCount);
    }

    [Fact]
    public async Task Backend_credential_failure_preserves_credential_category_and_stable_error_code()
    {
        var backend = new ThrowingBackendHost(new BackendHostException(
            "aigw_test_credential_missing",
            "Test credential is missing.",
            BackendFailureCategory.Credential));
        var options = RuntimeFixture.CreateOptions(backend, 0);

        var exception = await Assert.ThrowsAsync<BackendCredentialException>(
            () => GatewayRuntimeHost.StartAsync(options));

        Assert.Equal("aigw_test_credential_missing", exception.ErrorCode);
        Assert.Equal(0, backend.StopCount);
    }

    private static HttpRequestMessage Authorized(HttpMethod method, string path)
    {
        var request = new HttpRequestMessage(method, path);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", ClientToken);
        return request;
    }

    private static HttpRequestMessage AuthorizedJson(
        string path,
        string model,
        bool useAnthropicHeader = false)
    {
        var request = new HttpRequestMessage(HttpMethod.Post, path)
        {
            Content = new StringContent(
                JsonSerializer.Serialize(new { model, input = "hello" }),
                Encoding.UTF8,
                "application/json"),
        };
        if (useAnthropicHeader)
        {
            request.Headers.Add("x-api-key", ClientToken);
        }
        else
        {
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", ClientToken);
        }

        return request;
    }

    private static HttpRequestMessage AuthorizedStreamingJson(string path, string model)
    {
        var request = new HttpRequestMessage(HttpMethod.Post, path)
        {
            Content = new StringContent(
                JsonSerializer.Serialize(new { model, input = "hello", stream = true }),
                Encoding.UTF8,
                "application/json"),
        };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", ClientToken);
        return request;
    }

    private static HttpRequestMessage AuthorizedToolJson(string path)
    {
        var request = new HttpRequestMessage(HttpMethod.Post, path)
        {
            Content = new StringContent(
                JsonSerializer.Serialize(new
                {
                    model = "public-chat",
                    input = "weather",
                    tools = new[]
                    {
                        new
                        {
                            type = "function",
                            name = "get_weather",
                        },
                    },
                }),
                Encoding.UTF8,
                "application/json"),
        };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", ClientToken);
        return request;
    }

    private static HttpRequestMessage AuthorizedFaultJson(string fault, bool stream = false)
    {
        var request = new HttpRequestMessage(HttpMethod.Post, "/v1/chat/completions")
        {
            Content = new StringContent(
                JsonSerializer.Serialize(new
                {
                    model = "public-chat",
                    input = "fault-injection",
                    test_fault = fault,
                    stream,
                }),
                Encoding.UTF8,
                "application/json"),
        };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", ClientToken);
        return request;
    }

    private sealed class RuntimeFixture : IAsyncDisposable
    {
        private RuntimeFixture(DeterministicBackendHost backend, GatewayRuntimeHost gateway, HttpClient client)
        {
            Backend = backend;
            Gateway = gateway;
            Client = client;
        }

        public DeterministicBackendHost Backend { get; }

        public GatewayRuntimeHost Gateway { get; }

        public HttpClient Client { get; }

        public static async Task<RuntimeFixture> StartAsync(
            TimeSpan? forwardingTimeout = null,
            int? circuitFailureThreshold = null,
            TimeSpan? circuitOpenDuration = null,
            TimeProvider? timeProvider = null)
        {
            var backend = new DeterministicBackendHost();
            try
            {
                var gateway = await GatewayRuntimeHost.StartAsync(
                    CreateOptions(backend, 0, forwardingTimeout) with
                    {
                        CircuitFailureThreshold = circuitFailureThreshold ?? GatewayRuntimeOptions.DefaultCircuitFailureThreshold,
                        CircuitOpenDuration = circuitOpenDuration ?? TimeSpan.FromSeconds(30),
                        TimeProvider = timeProvider ?? TimeProvider.System,
                    });
                var client = new HttpClient(new SocketsHttpHandler
                {
                    UseProxy = false,
                    AllowAutoRedirect = false,
                })
                {
                    BaseAddress = gateway.BaseAddress,
                    Timeout = TimeSpan.FromSeconds(10),
                };
                return new RuntimeFixture(backend, gateway, client);
            }
            catch
            {
                await backend.DisposeAsync();
                throw;
            }
        }

        public static GatewayRuntimeOptions CreateOptions(
            IBackendHost backend,
            int port,
            TimeSpan? forwardingTimeout = null) => new()
        {
            Configuration = CreateConfiguration(),
            ClientToken = ClientToken,
            BackendHost = backend,
            ListenAddress = IPAddress.Loopback,
            Port = port,
            ForwardingTimeout = forwardingTimeout ?? TimeSpan.FromSeconds(10),
        };

        public async ValueTask DisposeAsync()
        {
            Client.Dispose();
            await Gateway.DisposeAsync();
            await Backend.DisposeAsync();
        }

        private static GatewayConfiguration CreateConfiguration() => new()
        {
            Revision = 42,
            ActiveProfileId = "profile",
            Profiles =
            [
                new ProfileConfiguration
                {
                    Id = "profile",
                    Name = "Integration",
                    Providers =
                    [
                        new ProviderConfiguration
                        {
                            Id = "provider",
                            Name = "Provider",
                            Type = ProviderType.LocalEndpoint,
                            Endpoint = "http://127.0.0.1:9999",
                            CredentialTarget = "LocalAIGateway/profile/provider/api-key",
                        },
                    ],
                    Models =
                    [
                        new ModelConfiguration
                        {
                            Alias = "public-chat",
                            ProviderId = "provider",
                            UpstreamModel = "upstream-secret-chat",
                            IsDefault = true,
                        },
                        new ModelConfiguration
                        {
                            Alias = "public-reasoning",
                            ProviderId = "provider",
                            UpstreamModel = "upstream-secret-reasoning",
                        },
                    ],
                },
            ],
        };
    }

    private sealed class MutableTimeProvider(DateTimeOffset now) : TimeProvider
    {
        private DateTimeOffset utcNow = now;

        public override DateTimeOffset GetUtcNow() => utcNow;

        public void Advance(TimeSpan value) => utcNow += value;
    }

    private sealed class ThrowingBackendHost(BackendHostException exception) : IBackendHost
    {
        public int StopCount { get; private set; }

        public Task<BackendInstance> PrepareAsync(
            ProfileConfiguration profile,
            CancellationToken cancellationToken = default) =>
            Task.FromException<BackendInstance>(exception);

        public Task<bool> ProbeReadyAsync(
            BackendInstance instance,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();

        public Task DrainAsync(
            BackendInstance instance,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();

        public Task StopAsync(
            BackendInstance instance,
            CancellationToken cancellationToken = default)
        {
            StopCount++;
            return Task.CompletedTask;
        }
    }

}
