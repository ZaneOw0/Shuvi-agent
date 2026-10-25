using System.IO.Pipes;
using System.Security.Principal;
using LocalAIGateway.Core.Control;
using LocalAIGateway.Windows.Control;

namespace LocalAIGateway.Windows.Tests;

public sealed class WindowsControlClientTests
{
    [Fact]
    public void Production_pipe_name_is_scoped_to_the_current_user_SID()
    {
        var sid = WindowsIdentity.GetCurrent().User?.Value;

        var name = WindowsControlPipeName.ForCurrentUser();

        Assert.False(string.IsNullOrWhiteSpace(sid));
        Assert.Equal($"LocalAIGateway.Control.v{ControlProtocol.Version}.{sid}", name);
    }

    [Fact]
    public async Task Client_sends_one_request_and_strictly_reads_one_response()
    {
        var pipeName = $"LocalAIGateway.Control.Tests.{Guid.NewGuid():N}";
        await using var server = new NamedPipeServerStream(
            pipeName,
            PipeDirection.InOut,
            1,
            PipeTransmissionMode.Byte,
            PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        var serverTask = Task.Run(async () =>
        {
            await server.WaitForConnectionAsync();
            var request = ControlJson.DeserializeRequest(await ControlFrameCodec.ReadAsync(server));
            Assert.Equal(new ControlRequest(ControlProtocol.Version, ControlCommands.Status), request);
            var response = new ControlResponse(
                ControlProtocol.Version,
                true,
                new ControlStatus(true, "default", 7, null, false, null, []),
                null);
            await ControlFrameCodec.WriteAsync(server, ControlJson.SerializeResponse(response));
            return response;
        });
        var client = new WindowsNamedPipeControlClient(
            pipeName,
            TimeSpan.FromSeconds(2),
            TimeSpan.FromSeconds(2));

        var actual = await client.SendAsync(ControlCommands.Status);

        var expected = await serverTask;
        Assert.Equal(expected.Version, actual.Version);
        Assert.Equal(expected.Ok, actual.Ok);
        Assert.Equal(expected.Status?.Running, actual.Status?.Running);
        Assert.Equal(expected.Status?.ActiveProfileId, actual.Status?.ActiveProfileId);
        Assert.Empty(actual.Status?.TargetCircuits ?? []);
    }

    [Fact]
    public async Task Connect_timeout_has_a_stable_error_code()
    {
        var client = new WindowsNamedPipeControlClient(
            $"LocalAIGateway.Control.Missing.{Guid.NewGuid():N}",
            TimeSpan.FromMilliseconds(100),
            TimeSpan.FromSeconds(1));

        var exception = await Assert.ThrowsAsync<ControlProtocolException>(
            () => client.SendAsync(ControlCommands.Status));

        Assert.Equal("aigw_control_connect_timeout", exception.ErrorCode);
    }

    [Fact]
    public async Task Caller_cancellation_is_not_reclassified_as_a_timeout()
    {
        var client = new WindowsNamedPipeControlClient(
            $"LocalAIGateway.Control.Missing.{Guid.NewGuid():N}",
            TimeSpan.FromSeconds(5),
            TimeSpan.FromSeconds(1));
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => client.SendAsync(ControlCommands.Status, cancellation.Token));
    }
}
