using System.IO.Pipes;
using System.Collections.Concurrent;
using System.Runtime.ExceptionServices;
using LocalAIGateway.Core.Control;

namespace LocalAIGateway.Runtime;

internal sealed record GatewayControlCommandOutcome(
    ControlResponse Response,
    Func<Task>? AfterResponse = null);

internal sealed class GatewayControlServer : IAsyncDisposable
{
    private const int MaxConcurrentConnections = 8;
    private readonly string pipeName;
    private readonly Func<ControlRequest, CancellationToken, Task<GatewayControlCommandOutcome>> handler;
    private readonly TimeSpan requestTimeout;
    private readonly CancellationTokenSource shutdown = new();
    private readonly object stateLock = new();
    private readonly SemaphoreSlim connectionSlots = new(MaxConcurrentConnections, MaxConcurrentConnections);
    private readonly ConcurrentDictionary<long, Task> connectionTasks = new();
    private readonly ConcurrentQueue<Exception> connectionFailures = new();
    private readonly Task serverTask;
    private NamedPipeServerStream? currentPipe;
    private long nextConnectionId;
    private int disposed;

    private GatewayControlServer(
        string pipeName,
        Func<ControlRequest, CancellationToken, Task<GatewayControlCommandOutcome>> handler,
        TimeSpan requestTimeout,
        NamedPipeServerStream initialPipe)
    {
        this.pipeName = pipeName;
        this.handler = handler;
        this.requestTimeout = requestTimeout;
        currentPipe = initialPipe;
        serverTask = RunAsync(initialPipe);
    }

    public static GatewayControlServer Start(
        string pipeName,
        Func<ControlRequest, CancellationToken, Task<GatewayControlCommandOutcome>> handler,
        TimeSpan requestTimeout)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(pipeName);
        ArgumentNullException.ThrowIfNull(handler);
        if (requestTimeout <= TimeSpan.Zero || requestTimeout > TimeSpan.FromMinutes(5))
        {
            throw new ArgumentOutOfRangeException(
                nameof(requestTimeout),
                "Control request timeout must be positive and no greater than five minutes.");
        }

        var initialPipe = CreatePipe(pipeName, firstInstance: true);
        return new GatewayControlServer(pipeName, handler, requestTimeout, initialPipe);
    }

    internal int TrackedConnectionCount => connectionTasks.Count;

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0)
        {
            return;
        }

        shutdown.Cancel();
        lock (stateLock)
        {
            currentPipe?.Dispose();
        }

        var failures = new List<Exception>();
        try
        {
            await serverTask;
        }
        catch (OperationCanceledException) when (shutdown.IsCancellationRequested)
        {
        }
        catch (ObjectDisposedException) when (shutdown.IsCancellationRequested)
        {
        }
        catch (Exception failure)
        {
            failures.Add(failure);
        }

        var connections = connectionTasks.Values.ToArray();

        try
        {
            await Task.WhenAll(connections);
        }
        catch (OperationCanceledException) when (shutdown.IsCancellationRequested)
        {
        }
        catch (ObjectDisposedException) when (shutdown.IsCancellationRequested)
        {
        }
        catch (Exception failure)
        {
            failures.Add(failure);
        }

        while (connectionFailures.TryDequeue(out var connectionFailure))
        {
            failures.Add(connectionFailure);
        }

        connectionSlots.Dispose();
        shutdown.Dispose();
        if (failures.Count == 1)
        {
            ExceptionDispatchInfo.Capture(failures[0]).Throw();
        }

        if (failures.Count > 1)
        {
            throw new AggregateException(
                "The control server could not release every owned resource.",
                failures);
        }
    }

    private async Task RunAsync(NamedPipeServerStream pipe)
    {
        var first = true;
        while (!shutdown.IsCancellationRequested)
        {
            var slotAcquired = false;
            try
            {
                await connectionSlots.WaitAsync(shutdown.Token);
                slotAcquired = true;
            }
            catch (OperationCanceledException) when (shutdown.IsCancellationRequested)
            {
                return;
            }

            if (!first)
            {
                try
                {
                    pipe = CreatePipe(pipeName, firstInstance: false);
                }
                catch (IOException) when (!shutdown.IsCancellationRequested)
                {
                    connectionSlots.Release();
                    await Task.Delay(50, shutdown.Token);
                    continue;
                }

                lock (stateLock)
                {
                    if (shutdown.IsCancellationRequested)
                    {
                        pipe.Dispose();
                        connectionSlots.Release();
                        return;
                    }

                    currentPipe = pipe;
                }
            }

            first = false;
            try
            {
                await pipe.WaitForConnectionAsync(shutdown.Token);
                lock (stateLock)
                {
                    if (ReferenceEquals(currentPipe, pipe))
                    {
                        currentPipe = null;
                    }
                }

                var connectionId = Interlocked.Increment(ref nextConnectionId);
                var startGate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                var connection = HandleTrackedConnectionAsync(
                    connectionId,
                    pipe,
                    startGate.Task);
                if (!connectionTasks.TryAdd(connectionId, connection))
                {
                    throw new InvalidOperationException("Duplicate control connection identifier.");
                }

                startGate.TrySetResult();

                pipe = null!;
                slotAcquired = false;
            }
            catch (OperationCanceledException) when (shutdown.IsCancellationRequested)
            {
                if (slotAcquired)
                {
                    connectionSlots.Release();
                }

                return;
            }
            catch (ObjectDisposedException) when (shutdown.IsCancellationRequested)
            {
                if (slotAcquired)
                {
                    connectionSlots.Release();
                }

                return;
            }
            catch (IOException) when (!shutdown.IsCancellationRequested)
            {
                if (slotAcquired)
                {
                    connectionSlots.Release();
                }

                // The client disconnected. A fresh pipe instance accepts the next request.
            }
            finally
            {
                if (pipe is not null)
                {
                    lock (stateLock)
                    {
                        if (ReferenceEquals(currentPipe, pipe))
                        {
                            currentPipe = null;
                        }
                    }

                    pipe.Dispose();
                }
            }
        }
    }

    private async Task HandleTrackedConnectionAsync(
        long connectionId,
        NamedPipeServerStream pipe,
        Task startGate)
    {
        try
        {
            await startGate;
            await HandleOwnedConnectionAsync(pipe);
        }
        catch (Exception failure)
        {
            connectionFailures.Enqueue(failure);
        }
        finally
        {
            connectionSlots.Release();
            connectionTasks.TryRemove(connectionId, out _);
        }
    }

    private async Task HandleOwnedConnectionAsync(NamedPipeServerStream pipe)
    {
        await using (pipe)
        {
            try
            {
                await HandleConnectionAsync(pipe);
            }
            catch (OperationCanceledException) when (shutdown.IsCancellationRequested)
            {
            }
            catch (ObjectDisposedException) when (shutdown.IsCancellationRequested)
            {
            }
            catch (IOException)
            {
                // A connected client can leave at any point. Its pipe instance is isolated.
            }
        }
    }

    private async Task HandleConnectionAsync(NamedPipeServerStream pipe)
    {
        GatewayControlCommandOutcome outcome;
        using (var requestCancellation = CancellationTokenSource.CreateLinkedTokenSource(shutdown.Token))
        {
            requestCancellation.CancelAfter(requestTimeout);
            try
            {
                var payload = await ControlFrameCodec.ReadAsync(pipe, requestCancellation.Token);
                var request = ControlJson.DeserializeRequest(payload);
                outcome = await handler(request, requestCancellation.Token);
            }
            catch (ControlProtocolException exception)
            {
                outcome = Error(exception.ErrorCode, "The control request was rejected.");
            }
            catch (OperationCanceledException)
                when (!shutdown.IsCancellationRequested && requestCancellation.IsCancellationRequested)
            {
                outcome = Error(
                    "aigw_control_request_timeout",
                    "The control request did not complete within the allowed time.");
            }
            catch (Exception)
            {
                outcome = Error(
                    "aigw_control_internal_error",
                    "The control request could not be completed.");
            }
        }

        using var responseCancellation = CancellationTokenSource.CreateLinkedTokenSource(shutdown.Token);
        responseCancellation.CancelAfter(requestTimeout);
        var response = ControlJson.SerializeResponse(outcome.Response);
        await ControlFrameCodec.WriteAsync(pipe, response, responseCancellation.Token);
        if (outcome.AfterResponse is not null)
        {
            try
            {
                await outcome.AfterResponse();
            }
            catch
            {
                // The response has already been delivered. Lifecycle cleanup owns any failure reporting.
            }
        }
    }

    private static GatewayControlCommandOutcome Error(string code, string message) => new(
        new ControlResponse(
            ControlProtocol.Version,
            false,
            null,
            new ControlError(code, message)));

    private static NamedPipeServerStream CreatePipe(string pipeName, bool firstInstance) => new(
        pipeName,
        PipeDirection.InOut,
        MaxConcurrentConnections,
        PipeTransmissionMode.Byte,
        PipeOptions.Asynchronous |
        PipeOptions.CurrentUserOnly |
        (firstInstance ? PipeOptions.FirstPipeInstance : PipeOptions.None),
        ControlProtocol.MaxFrameLength + sizeof(int),
        ControlProtocol.MaxFrameLength + sizeof(int));
}
