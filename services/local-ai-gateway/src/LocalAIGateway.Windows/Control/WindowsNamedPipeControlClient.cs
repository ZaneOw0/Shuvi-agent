using System.IO.Pipes;
using LocalAIGateway.Core.Control;

namespace LocalAIGateway.Windows.Control;

public sealed class WindowsNamedPipeControlClient : IControlClient
{
    private readonly string pipeName;
    private readonly TimeSpan connectTimeout;
    private readonly TimeSpan ioTimeout;

    public WindowsNamedPipeControlClient(
        string pipeName,
        TimeSpan? connectTimeout = null,
        TimeSpan? ioTimeout = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(pipeName);
        this.pipeName = pipeName;
        this.connectTimeout = connectTimeout ?? TimeSpan.FromSeconds(5);
        this.ioTimeout = ioTimeout ?? TimeSpan.FromSeconds(70);
        ValidateTimeout(this.connectTimeout, nameof(connectTimeout));
        ValidateTimeout(this.ioTimeout, nameof(ioTimeout));
    }

    public static WindowsNamedPipeControlClient ForCurrentUser() =>
        new(WindowsControlPipeName.ForCurrentUser());

    public async Task<ControlResponse> SendAsync(
        string command,
        CancellationToken cancellationToken = default)
    {
        if (!ControlCommands.IsSupported(command))
        {
            throw new ControlProtocolException(
                "aigw_control_unsupported_command",
                "Control command is not supported.");
        }

        await using var pipe = new NamedPipeClientStream(
            ".",
            pipeName,
            PipeDirection.InOut,
            PipeOptions.Asynchronous);
        using (var connectCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken))
        {
            connectCancellation.CancelAfter(connectTimeout);
            try
            {
                await pipe.ConnectAsync(connectCancellation.Token);
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            {
                throw new ControlProtocolException(
                    "aigw_control_connect_timeout",
                    "Timed out connecting to the Local AI Gateway control pipe.");
            }
            catch (IOException exception)
            {
                throw new ControlProtocolException(
                    "aigw_control_unavailable",
                    "The Local AI Gateway control pipe is unavailable.",
                    exception);
            }
        }

        using var ioCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        ioCancellation.CancelAfter(ioTimeout);
        try
        {
            var request = ControlJson.SerializeRequest(
                new ControlRequest(ControlProtocol.Version, command));
            await ControlFrameCodec.WriteAsync(pipe, request, ioCancellation.Token);
            var response = await ControlFrameCodec.ReadAsync(pipe, ioCancellation.Token);
            return ControlJson.DeserializeResponse(response);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new ControlProtocolException(
                "aigw_control_io_timeout",
                "Timed out exchanging a Local AI Gateway control message.");
        }
        catch (IOException exception)
        {
            throw new ControlProtocolException(
                "aigw_control_io_failed",
                "The Local AI Gateway control message exchange failed.",
                exception);
        }
    }

    private static void ValidateTimeout(TimeSpan value, string parameterName)
    {
        if (value <= TimeSpan.Zero || value > TimeSpan.FromMinutes(5))
        {
            throw new ArgumentOutOfRangeException(
                parameterName,
                "Control pipe timeout must be positive and no greater than five minutes.");
        }
    }
}
