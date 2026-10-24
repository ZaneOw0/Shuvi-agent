using System.IO.Pipes;
using System.Text;
using LocalAIGateway.Core.Control;
using LocalAIGateway.Windows.Control;

namespace LocalAIGateway.Runtime.Tests;

public sealed class GatewayControlServerTests
{
    [Fact]
    public async Task Server_writes_the_stop_response_before_running_the_after_response_action()
    {
        var pipeName = $"LocalAIGateway.Control.RuntimeTests.{Guid.NewGuid():N}";
        var afterResponseEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseAfterResponse = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        await using var server = GatewayControlServer.Start(
            pipeName,
            (request, _) => Task.FromResult(new GatewayControlCommandOutcome(
                SuccessStatus(),
                async () =>
                {
                    afterResponseEntered.TrySetResult();
                    await releaseAfterResponse.Task;
                })),
            TimeSpan.FromSeconds(2));
        var client = new WindowsNamedPipeControlClient(
            pipeName,
            TimeSpan.FromSeconds(2),
            TimeSpan.FromSeconds(2));

        var response = await client.SendAsync(ControlCommands.Stop);

        Assert.True(response.Ok);
        Assert.NotNull(response.Status);
        await afterResponseEntered.Task.WaitAsync(TimeSpan.FromSeconds(2));
        releaseAfterResponse.TrySetResult();
    }

    [Fact]
    public async Task Server_returns_a_stable_protocol_error_for_duplicate_request_properties()
    {
        var pipeName = $"LocalAIGateway.Control.RuntimeTests.{Guid.NewGuid():N}";
        await using var server = GatewayControlServer.Start(
            pipeName,
            (_, _) => throw new InvalidOperationException("Invalid requests must not reach the handler."),
            TimeSpan.FromSeconds(2));
        await using var client = new NamedPipeClientStream(
            ".",
            pipeName,
            PipeDirection.InOut,
            PipeOptions.Asynchronous);
        await client.ConnectAsync(2000);
        var invalid = Encoding.UTF8.GetBytes(
            "{\"version\":1,\"version\":1,\"command\":\"status\"}");

        await ControlFrameCodec.WriteAsync(client, invalid);
        var response = ControlJson.DeserializeResponse(await ControlFrameCodec.ReadAsync(client));

        Assert.False(response.Ok);
        Assert.Equal("aigw_control_duplicate_property", response.Error?.Code);
    }

    [Fact]
    public async Task Server_bounds_a_client_that_does_not_finish_its_frame()
    {
        var pipeName = $"LocalAIGateway.Control.RuntimeTests.{Guid.NewGuid():N}";
        await using var server = GatewayControlServer.Start(
            pipeName,
            (_, _) => throw new InvalidOperationException("Incomplete requests must not reach the handler."),
            TimeSpan.FromMilliseconds(100));
        await using var client = new NamedPipeClientStream(
            ".",
            pipeName,
            PipeDirection.InOut,
            PipeOptions.Asynchronous);
        await client.ConnectAsync(2000);
        await client.WriteAsync(new byte[] { 1, 0 });
        await client.FlushAsync();

        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(2));
        var response = ControlJson.DeserializeResponse(
            await ControlFrameCodec.ReadAsync(client, timeout.Token));

        Assert.False(response.Ok);
        Assert.Equal("aigw_control_request_timeout", response.Error?.Code);
    }

    [Fact]
    public async Task Status_can_complete_while_reload_is_still_running()
    {
        var pipeName = $"LocalAIGateway.Control.RuntimeTests.{Guid.NewGuid():N}";
        var reloadEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseReload = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        await using var server = GatewayControlServer.Start(
            pipeName,
            async (request, cancellationToken) =>
            {
                if (request.Command == ControlCommands.Reload)
                {
                    reloadEntered.TrySetResult();
                    await releaseReload.Task.WaitAsync(cancellationToken);
                }

                return new GatewayControlCommandOutcome(SuccessStatus());
            },
            TimeSpan.FromSeconds(2));
        var reloadClient = new WindowsNamedPipeControlClient(
            pipeName,
            TimeSpan.FromSeconds(2),
            TimeSpan.FromSeconds(2));
        var statusClient = new WindowsNamedPipeControlClient(
            pipeName,
            TimeSpan.FromSeconds(2),
            TimeSpan.FromSeconds(2));

        var reload = reloadClient.SendAsync(ControlCommands.Reload);
        await reloadEntered.Task.WaitAsync(TimeSpan.FromSeconds(2));
        var status = await statusClient.SendAsync(ControlCommands.Status);

        Assert.True(status.Ok);
        releaseReload.TrySetResult();
        Assert.True((await reload).Ok);
    }

    [Fact]
    public async Task Completed_connections_are_removed_from_lifecycle_tracking()
    {
        var pipeName = $"LocalAIGateway.Control.RuntimeTests.{Guid.NewGuid():N}";
        await using var server = GatewayControlServer.Start(
            pipeName,
            (_, _) => Task.FromResult(new GatewayControlCommandOutcome(SuccessStatus())),
            TimeSpan.FromSeconds(2));
        var client = new WindowsNamedPipeControlClient(
            pipeName,
            TimeSpan.FromSeconds(2),
            TimeSpan.FromSeconds(2));

        for (var index = 0; index < 50; index++)
        {
            Assert.True((await client.SendAsync(ControlCommands.Status)).Ok);
        }

        await WaitUntilAsync(() => server.TrackedConnectionCount == 0);
        Assert.Equal(0, server.TrackedConnectionCount);
    }

    [Fact]
    public async Task Dispose_reports_an_unexpected_connection_task_failure_after_tracking_cleanup()
    {
        var pipeName = $"LocalAIGateway.Control.RuntimeTests.{Guid.NewGuid():N}";
        var server = GatewayControlServer.Start(
            pipeName,
            (_, _) => Task.FromResult(new GatewayControlCommandOutcome(
                new ControlResponse(ControlProtocol.Version, true, null, null))),
            TimeSpan.FromSeconds(2));
        var client = new WindowsNamedPipeControlClient(
            pipeName,
            TimeSpan.FromSeconds(2),
            TimeSpan.FromSeconds(2));

        await Assert.ThrowsAnyAsync<Exception>(() => client.SendAsync(ControlCommands.Status));
        await WaitUntilAsync(() => server.TrackedConnectionCount == 0);

        var failure = await Assert.ThrowsAsync<ControlProtocolException>(
            async () => await server.DisposeAsync());
        Assert.Equal("aigw_control_invalid_response", failure.ErrorCode);
    }

    private static async Task WaitUntilAsync(Func<bool> predicate)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(2));
        while (!predicate())
        {
            await Task.Delay(10, timeout.Token);
        }
    }

    private static ControlResponse SuccessStatus() => new(
        ControlProtocol.Version,
        true,
        new ControlStatus(true, "default", 1, null, false, null, []),
        null);
}
