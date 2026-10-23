using System.Buffers.Binary;
using System.Text;
using LocalAIGateway.Core.Control;

namespace LocalAIGateway.Core.Tests;

public sealed class ControlProtocolTests
{
    [Fact]
    public async Task Frame_uses_a_four_byte_little_endian_length_prefix()
    {
        await using var stream = new MemoryStream();

        await ControlFrameCodec.WriteAsync(stream, "{}"u8.ToArray());

        Assert.Equal(new byte[] { 2, 0, 0, 0, (byte)'{', (byte)'}' }, stream.ToArray());
    }

    [Fact]
    public async Task Frame_accepts_exactly_64_KiB_and_rejects_larger_payloads()
    {
        await using var accepted = new MemoryStream();
        await ControlFrameCodec.WriteAsync(accepted, new byte[ControlProtocol.MaxFrameLength]);
        Assert.Equal(ControlProtocol.MaxFrameLength, BinaryPrimitives.ReadInt32LittleEndian(accepted.ToArray()));

        await using var rejected = new MemoryStream();
        var exception = await Assert.ThrowsAsync<ControlProtocolException>(
            () => ControlFrameCodec.WriteAsync(
                rejected,
                new byte[ControlProtocol.MaxFrameLength + 1]).AsTask());

        Assert.Equal("aigw_control_frame_too_large", exception.ErrorCode);
    }

    [Fact]
    public async Task Frame_rejects_truncated_header_and_payload_without_echoing_payload()
    {
        await using var truncatedHeader = new MemoryStream(new byte[] { 1, 0 });
        var headerException = await Assert.ThrowsAsync<ControlProtocolException>(
            () => ControlFrameCodec.ReadAsync(truncatedHeader).AsTask());
        Assert.Equal("aigw_control_malformed_frame", headerException.ErrorCode);

        const string canary = "secret-canary-must-not-leak";
        var bytes = new byte[4 + Encoding.UTF8.GetByteCount(canary)];
        BinaryPrimitives.WriteInt32LittleEndian(bytes, bytes.Length);
        Encoding.UTF8.GetBytes(canary, bytes.AsSpan(4));
        await using var truncatedPayload = new MemoryStream(bytes);
        var payloadException = await Assert.ThrowsAsync<ControlProtocolException>(
            () => ControlFrameCodec.ReadAsync(truncatedPayload).AsTask());

        Assert.Equal("aigw_control_malformed_frame", payloadException.ErrorCode);
        Assert.DoesNotContain(canary, payloadException.ToString(), StringComparison.Ordinal);
    }

    [Fact]
    public void Request_round_trip_uses_the_versioned_command_contract()
    {
        var bytes = ControlJson.SerializeRequest(new ControlRequest(ControlProtocol.Version, ControlCommands.Reload));

        Assert.Equal("{\"version\":2,\"command\":\"reload\"}", Encoding.UTF8.GetString(bytes));
        Assert.Equal(new ControlRequest(ControlProtocol.Version, ControlCommands.Reload), ControlJson.DeserializeRequest(bytes));
    }

    [Theory]
    [InlineData("not-json", "aigw_control_malformed_json")]
    [InlineData("[]", "aigw_control_invalid_request")]
    [InlineData("{\"version\":2}", "aigw_control_invalid_request")]
    [InlineData("{\"version\":2,\"version\":2,\"command\":\"status\"}", "aigw_control_duplicate_property")]
    [InlineData("{\"version\":2,\"command\":\"status\",\"extra\":true}", "aigw_control_unknown_property")]
    [InlineData("{\"version\":3,\"command\":\"status\"}", "aigw_control_unsupported_version")]
    [InlineData("{\"version\":2,\"command\":\"launch\"}", "aigw_control_unsupported_command")]
    public void Request_strictly_rejects_invalid_input(string json, string expectedCode)
    {
        var exception = Assert.Throws<ControlProtocolException>(
            () => ControlJson.DeserializeRequest(Encoding.UTF8.GetBytes(json)));

        Assert.Equal(expectedCode, exception.ErrorCode);
    }

    [Theory]
    [InlineData("status")]
    [InlineData("reload")]
    [InlineData("stop")]
    public void Request_accepts_only_the_three_supported_commands(string command)
    {
        var json = Encoding.UTF8.GetBytes($"{{\"version\":2,\"command\":\"{command}\"}}");

        Assert.Equal(command, ControlJson.DeserializeRequest(json).Command);
    }

    [Fact]
    public void Status_response_round_trip_preserves_nullable_state()
    {
        var response = new ControlResponse(
            Version: ControlProtocol.Version,
            Ok: true,
            Status: new ControlStatus(
                Running: true,
                ActiveProfileId: "default",
                ActiveConfigurationRevision: 12,
                PendingConfigurationRevision: 13,
                Switching: true,
                LastReloadErrorCode: "aigw_control_reload_failed",
                TargetCircuits:
                [
                    new TargetCircuitStatus(
                        "provider",
                        "public-chat",
                        CircuitStates.Open,
                        5,
                        new DateTimeOffset(2026, 9, 15, 10, 20, 30, TimeSpan.Zero)),
                ]),
            Error: null);

        var bytes = ControlJson.SerializeResponse(response);
        var json = Encoding.UTF8.GetString(bytes);
        var roundTripped = ControlJson.DeserializeResponse(bytes);

        Assert.Equal(
            "{\"version\":2,\"ok\":true,\"status\":{\"running\":true,\"activeProfileId\":\"default\",\"activeConfigurationRevision\":12,\"pendingConfigurationRevision\":13,\"switching\":true,\"lastReloadErrorCode\":\"aigw_control_reload_failed\",\"targetCircuits\":[{\"providerId\":\"provider\",\"modelAlias\":\"public-chat\",\"state\":\"open\",\"consecutiveFailures\":5,\"openUntilUtc\":\"2026-09-15T10:20:30+00:00\"}]}}",
            json);
        Assert.Equal(json, Encoding.UTF8.GetString(ControlJson.SerializeResponse(roundTripped)));
        Assert.Equal(response.Status?.TargetCircuits.Single(), roundTripped.Status?.TargetCircuits.Single());
    }

    [Fact]
    public void Error_response_round_trip_uses_a_stable_control_error_code()
    {
        var response = new ControlResponse(
            ControlProtocol.Version,
            false,
            null,
            new ControlError("aigw_control_reload_failed", "The configuration could not be reloaded."));

        var bytes = ControlJson.SerializeResponse(response);

        Assert.Equal(response, ControlJson.DeserializeResponse(bytes));
    }

    [Theory]
    [InlineData("{\"version\":2,\"ok\":true,\"error\":{\"code\":\"aigw_control_failed\",\"message\":\"failed\"}}")]
    [InlineData("{\"version\":2,\"ok\":false}")]
    [InlineData("{\"version\":2,\"ok\":false,\"status\":{\"running\":false,\"activeProfileId\":null,\"activeConfigurationRevision\":null,\"pendingConfigurationRevision\":null,\"switching\":false,\"targetCircuits\":[]},\"error\":{\"code\":\"aigw_control_failed\",\"message\":\"failed\"}}")]
    [InlineData("{\"version\":2,\"ok\":false,\"error\":null}")]
    [InlineData("{\"version\":2,\"ok\":false,\"error\":{\"code\":\"other_failed\",\"message\":\"failed\"}}")]
    [InlineData("{\"version\":2,\"ok\":true,\"extra\":true}")]
    [InlineData("{\"version\":3,\"ok\":true}")]
    public void Client_side_response_validation_rejects_invalid_contracts(string json)
    {
        var exception = Assert.Throws<ControlProtocolException>(
            () => ControlJson.DeserializeResponse(Encoding.UTF8.GetBytes(json)));

        Assert.StartsWith("aigw_control_", exception.ErrorCode, StringComparison.Ordinal);
    }

    [Fact]
    public void Response_rejects_duplicate_nested_properties()
    {
        const string json = "{\"version\":2,\"ok\":false,\"error\":{\"code\":\"aigw_control_failed\",\"code\":\"aigw_control_other\",\"message\":\"failed\"}}";

        var exception = Assert.Throws<ControlProtocolException>(
            () => ControlJson.DeserializeResponse(Encoding.UTF8.GetBytes(json)));

        Assert.Equal("aigw_control_duplicate_property", exception.ErrorCode);
    }

    [Fact]
    public void Response_strictly_rejects_invalid_target_circuit_snapshots()
    {
        string[] invalidCircuits =
        [
            "null",
            "[{\"providerId\":\"provider\",\"modelAlias\":\"model\",\"state\":\"broken\",\"consecutiveFailures\":1,\"openUntilUtc\":null}]",
            "[{\"providerId\":\"provider\",\"modelAlias\":\"model\",\"state\":\"open\",\"consecutiveFailures\":5,\"openUntilUtc\":null}]",
            "[{\"providerId\":\"provider\",\"modelAlias\":\"model\",\"state\":\"closed\",\"consecutiveFailures\":0,\"openUntilUtc\":\"2026-09-15T12:00:00+00:00\"}]",
            "[{\"providerId\":\"provider\",\"modelAlias\":\"model\",\"state\":\"closed\",\"consecutiveFailures\":-1,\"openUntilUtc\":null}]",
            "[{\"providerId\":\"provider\",\"modelAlias\":\"model\",\"state\":\"closed\",\"consecutiveFailures\":0,\"openUntilUtc\":null},{\"providerId\":\"PROVIDER\",\"modelAlias\":\"MODEL\",\"state\":\"closed\",\"consecutiveFailures\":0,\"openUntilUtc\":null}]",
        ];

        foreach (var circuits in invalidCircuits)
        {
            var json = $"{{\"version\":2,\"ok\":true,\"status\":{{\"running\":true,\"activeProfileId\":\"profile\",\"activeConfigurationRevision\":1,\"pendingConfigurationRevision\":null,\"switching\":false,\"targetCircuits\":{circuits}}}}}";

            var exception = Assert.Throws<ControlProtocolException>(
                () => ControlJson.DeserializeResponse(Encoding.UTF8.GetBytes(json)));

            Assert.Equal("aigw_control_invalid_response", exception.ErrorCode);
        }
    }
}
