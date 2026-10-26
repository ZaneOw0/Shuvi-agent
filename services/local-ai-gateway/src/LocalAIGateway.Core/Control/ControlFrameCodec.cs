using System.Buffers.Binary;

namespace LocalAIGateway.Core.Control;

public static class ControlFrameCodec
{
    public static async ValueTask WriteAsync(
        Stream stream,
        ReadOnlyMemory<byte> payload,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(stream);
        if (payload.Length > ControlProtocol.MaxFrameLength)
        {
            throw new ControlProtocolException(
                "aigw_control_frame_too_large",
                "Control message exceeds the maximum frame length.");
        }

        var header = new byte[sizeof(int)];
        BinaryPrimitives.WriteInt32LittleEndian(header, payload.Length);
        await stream.WriteAsync(header, cancellationToken);
        await stream.WriteAsync(payload, cancellationToken);
        await stream.FlushAsync(cancellationToken);
    }

    public static async ValueTask<byte[]> ReadAsync(
        Stream stream,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(stream);
        var header = new byte[sizeof(int)];
        await ReadExactlyAsync(stream, header, cancellationToken);
        var length = BinaryPrimitives.ReadInt32LittleEndian(header);
        if (length < 0 || length > ControlProtocol.MaxFrameLength)
        {
            throw new ControlProtocolException(
                "aigw_control_frame_too_large",
                "Control message length is invalid or exceeds the maximum frame length.");
        }

        var payload = new byte[length];
        await ReadExactlyAsync(stream, payload, cancellationToken);
        return payload;
    }

    private static async ValueTask ReadExactlyAsync(
        Stream stream,
        Memory<byte> destination,
        CancellationToken cancellationToken)
    {
        var offset = 0;
        while (offset < destination.Length)
        {
            var read = await stream.ReadAsync(destination[offset..], cancellationToken);
            if (read == 0)
            {
                throw new ControlProtocolException(
                    "aigw_control_malformed_frame",
                    "Control message ended before the declared frame was complete.");
            }

            offset += read;
        }
    }
}
