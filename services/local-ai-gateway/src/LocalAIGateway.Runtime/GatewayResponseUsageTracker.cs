using System.Net;
using System.Text;

namespace LocalAIGateway.Runtime;

internal sealed class GatewayResponseUsageTracker(Action<long> recordTokens)
{
    private readonly StreamingUsageScanner scanner = new(recordTokens);

    public void Append(ReadOnlySpan<byte> bytes) => scanner.Append(bytes);
}

internal sealed class GatewayUsageTrackingContent : HttpContent
{
    private readonly HttpContent inner;
    private readonly GatewayResponseUsageTracker tracker;

    public GatewayUsageTrackingContent(HttpContent inner, GatewayResponseUsageTracker tracker)
    {
        this.inner = inner;
        this.tracker = tracker;
        foreach (var header in inner.Headers)
        {
            Headers.TryAddWithoutValidation(header.Key, header.Value);
        }
    }

    protected override bool TryComputeLength(out long length)
    {
        if (inner.Headers.ContentLength is long contentLength)
        {
            length = contentLength;
            return true;
        }

        length = 0;
        return false;
    }

    protected override async Task SerializeToStreamAsync(Stream stream, TransportContext? context)
    {
        await using var source = new GatewayUsageTrackingStream(
            await inner.ReadAsStreamAsync(),
            tracker,
            leaveOpen: true);
        await source.CopyToAsync(stream);
    }

    protected override async Task SerializeToStreamAsync(
        Stream stream,
        TransportContext? context,
        CancellationToken cancellationToken)
    {
        await using var source = new GatewayUsageTrackingStream(
            await inner.ReadAsStreamAsync(cancellationToken),
            tracker,
            leaveOpen: true);
        await source.CopyToAsync(stream, cancellationToken);
    }

    protected override async Task<Stream> CreateContentReadStreamAsync() =>
        new GatewayUsageTrackingStream(await inner.ReadAsStreamAsync(), tracker, leaveOpen: true);

    protected override async Task<Stream> CreateContentReadStreamAsync(CancellationToken cancellationToken) =>
        new GatewayUsageTrackingStream(
            await inner.ReadAsStreamAsync(cancellationToken),
            tracker,
            leaveOpen: true);

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            inner.Dispose();
        }

        base.Dispose(disposing);
    }
}

internal sealed class GatewayUsageTrackingStream(
    Stream inner,
    GatewayResponseUsageTracker tracker,
    bool leaveOpen) : Stream
{
    public override bool CanRead => inner.CanRead;
    public override bool CanSeek => false;
    public override bool CanWrite => false;
    public override long Length => throw new NotSupportedException();
    public override long Position
    {
        get => throw new NotSupportedException();
        set => throw new NotSupportedException();
    }

    public override int Read(byte[] buffer, int offset, int count)
    {
        var read = inner.Read(buffer, offset, count);
        tracker.Append(buffer.AsSpan(offset, read));
        return read;
    }

    public override int Read(Span<byte> buffer)
    {
        var read = inner.Read(buffer);
        tracker.Append(buffer[..read]);
        return read;
    }

    public override async ValueTask<int> ReadAsync(
        Memory<byte> buffer,
        CancellationToken cancellationToken = default)
    {
        var read = await inner.ReadAsync(buffer, cancellationToken);
        tracker.Append(buffer.Span[..read]);
        return read;
    }

    public override async Task<int> ReadAsync(
        byte[] buffer,
        int offset,
        int count,
        CancellationToken cancellationToken)
    {
        var read = await inner.ReadAsync(buffer.AsMemory(offset, count), cancellationToken);
        tracker.Append(buffer.AsSpan(offset, read));
        return read;
    }

    public override void Flush() => throw new NotSupportedException();
    public override Task FlushAsync(CancellationToken cancellationToken) => throw new NotSupportedException();
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();

    protected override void Dispose(bool disposing)
    {
        if (disposing && !leaveOpen)
        {
            inner.Dispose();
        }

        base.Dispose(disposing);
    }

    public override async ValueTask DisposeAsync()
    {
        if (!leaveOpen)
        {
            await inner.DisposeAsync();
        }

        GC.SuppressFinalize(this);
    }
}

internal sealed class StreamingUsageScanner(Action<long> recordTokens)
{
    private const int MaximumCapturedNameBytes = 32;
    private readonly Stack<UsageObject> usageObjects = new();
    private readonly byte[] capturedName = new byte[MaximumCapturedNameBytes];
    private bool inString;
    private bool stringEscape;
    private bool stringCaptureValid;
    private int capturedNameLength;
    private string? closedString;
    private string? pendingProperty;
    private int pendingPropertyDepth;
    private string? numberProperty;
    private long numberValue;
    private bool numberInvalid;
    private bool readingNumber;
    private int objectDepth;

    public void Append(ReadOnlySpan<byte> bytes)
    {
        foreach (var value in bytes)
        {
            Process(value);
        }
    }

    private void Process(byte value)
    {
        if (inString)
        {
            ProcessString(value);
            return;
        }

        if (readingNumber)
        {
            if (value is >= (byte)'0' and <= (byte)'9')
            {
                try
                {
                    numberValue = checked((numberValue * 10) + value - (byte)'0');
                }
                catch (OverflowException)
                {
                    numberInvalid = true;
                }

                return;
            }

            if (value is (byte)'.' or (byte)'e' or (byte)'E' or (byte)'+' or (byte)'-')
            {
                numberInvalid = true;
                return;
            }

            FinishNumber();
        }

        if (IsWhitespace(value))
        {
            return;
        }

        switch (value)
        {
            case (byte)'"':
                StartString();
                ClearPendingValue();
                return;
            case (byte)':':
                pendingProperty = closedString;
                pendingPropertyDepth = objectDepth;
                closedString = null;
                return;
            case (byte)'{':
                objectDepth++;
                if (string.Equals(pendingProperty, "usage", StringComparison.Ordinal))
                {
                    usageObjects.Push(new UsageObject(objectDepth));
                }

                ClearPendingValue();
                return;
            case (byte)'}':
                if (usageObjects.TryPeek(out var usage) && usage.Depth == objectDepth)
                {
                    usageObjects.Pop();
                    CompleteUsage(usage);
                }

                objectDepth = Math.Max(0, objectDepth - 1);
                closedString = null;
                ClearPendingValue();
                return;
            case >= (byte)'0' and <= (byte)'9':
                if (IsDirectUsageProperty(pendingProperty, pendingPropertyDepth))
                {
                    readingNumber = true;
                    numberProperty = pendingProperty;
                    numberValue = value - (byte)'0';
                    numberInvalid = false;
                }

                closedString = null;
                ClearPendingValue();
                return;
            default:
                closedString = null;
                ClearPendingValue();
                return;
        }
    }

    private void StartString()
    {
        inString = true;
        stringEscape = false;
        stringCaptureValid = true;
        capturedNameLength = 0;
        closedString = null;
    }

    private void ProcessString(byte value)
    {
        if (stringEscape)
        {
            stringEscape = false;
            stringCaptureValid = false;
            return;
        }

        if (value == (byte)'\\')
        {
            stringEscape = true;
            stringCaptureValid = false;
            return;
        }

        if (value == (byte)'"')
        {
            inString = false;
            closedString = stringCaptureValid
                ? Encoding.ASCII.GetString(capturedName, 0, capturedNameLength)
                : null;
            return;
        }

        if (!stringCaptureValid)
        {
            return;
        }

        if (value > 0x7f || capturedNameLength >= capturedName.Length)
        {
            stringCaptureValid = false;
            return;
        }

        capturedName[capturedNameLength++] = value;
    }

    private bool IsDirectUsageProperty(string? property, int propertyDepth) =>
        (property is "total_tokens" or "totalTokens" or "input_tokens" or "prompt_tokens" or
            "output_tokens" or "completion_tokens") &&
        usageObjects.TryPeek(out var usage) &&
        usage.Depth == propertyDepth;

    private void FinishNumber()
    {
        if (!numberInvalid && usageObjects.TryPeek(out var usage))
        {
            switch (numberProperty)
            {
                case "total_tokens":
                case "totalTokens":
                    usage.TotalTokens = numberValue;
                    break;
                case "input_tokens":
                case "prompt_tokens":
                    usage.InputTokens = numberValue;
                    break;
                case "output_tokens":
                case "completion_tokens":
                    usage.OutputTokens = numberValue;
                    break;
            }
        }

        readingNumber = false;
        numberProperty = null;
        numberValue = 0;
        numberInvalid = false;
    }

    private void CompleteUsage(UsageObject usage)
    {
        if (usage.TotalTokens is > 0 and var total)
        {
            recordTokens(total);
            return;
        }

        if (usage.InputTokens is not null || usage.OutputTokens is not null)
        {
            var input = usage.InputTokens ?? 0;
            var output = usage.OutputTokens ?? 0;
            if (input > long.MaxValue - output)
            {
                return;
            }

            var sum = input + output;
            if (sum > 0)
            {
                recordTokens(sum);
            }
        }
    }

    private void ClearPendingValue()
    {
        pendingProperty = null;
        pendingPropertyDepth = 0;
    }

    private static bool IsWhitespace(byte value) =>
        value is (byte)' ' or (byte)'\t' or (byte)'\r' or (byte)'\n';

    private sealed class UsageObject(int depth)
    {
        public int Depth { get; } = depth;
        public long? TotalTokens { get; set; }
        public long? InputTokens { get; set; }
        public long? OutputTokens { get; set; }
    }
}
