using System.Collections.Concurrent;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Runtime.ExceptionServices;
using LocalAIGateway.Core.Backend;
using LocalAIGateway.Core.Configuration;

namespace LocalAIGateway.LiteLlm;

public sealed class LiteLlmBackendHost(
    LiteLlmConfigurationCompiler configurationCompiler,
    ILiteLlmProcessFactory processFactory) : IBackendHost, IAsyncDisposable
{
    private readonly ConcurrentDictionary<BackendInstance, ProcessLease> processes = new();
    private readonly ConcurrentDictionary<ProcessLease, byte> failedStarts = new();

    public async Task<BackendInstance> PrepareAsync(
        ProfileConfiguration profile,
        CancellationToken cancellationToken = default)
    {
        await CleanupFailedStartsAsync(cancellationToken);
        var internalToken = Convert.ToHexString(RandomNumberGenerator.GetBytes(32));
        var plan = await configurationCompiler.CompileAsync(profile, internalToken, cancellationToken);
        var process = await processFactory.StartAsync(profile, plan, cancellationToken);
        var lease = new ProcessLease(process);
        try
        {
            ValidateInstance(process.Instance, internalToken);
            if (!processes.TryAdd(process.Instance, lease))
            {
                throw new LiteLlmException(
                    "aigw_litellm_instance_conflict",
                    "The managed LiteLLM instance is already registered.");
            }

            return process.Instance;
        }
        catch (Exception preparationFailure)
        {
            try
            {
                await lease.StopAsync(CancellationToken.None);
            }
            catch (Exception cleanupFailure)
            {
                failedStarts.TryAdd(lease, 0);
                throw PreservePreparationFailure(preparationFailure, cleanupFailure);
            }

            throw;
        }
    }

    public Task<bool> ProbeReadyAsync(
        BackendInstance instance,
        CancellationToken cancellationToken = default) =>
        GetLease(instance).ProbeReadyAsync(cancellationToken);

    public Task DrainAsync(
        BackendInstance instance,
        CancellationToken cancellationToken = default) =>
        GetLease(instance).DrainAsync(cancellationToken);

    public async Task StopAsync(
        BackendInstance instance,
        CancellationToken cancellationToken = default)
    {
        if (!processes.TryGetValue(instance, out var lease))
        {
            return;
        }

        await lease.StopAsync(cancellationToken);
        if (lease.IsStopped)
        {
            processes.TryRemove(new KeyValuePair<BackendInstance, ProcessLease>(instance, lease));
        }
    }

    public async ValueTask DisposeAsync()
    {
        var failures = new List<Exception>();
        foreach (var instance in processes.Keys)
        {
            try
            {
                await StopAsync(instance, CancellationToken.None);
            }
            catch (Exception exception)
            {
                failures.Add(exception);
            }
        }

        try
        {
            await CleanupFailedStartsAsync(CancellationToken.None);
        }
        catch (Exception exception)
        {
            failures.Add(exception);
        }

        if (failures.Count > 0)
        {
            throw new AggregateException(
                "One or more managed LiteLLM processes could not be cleaned up.",
                failures);
        }
    }

    private ProcessLease GetLease(BackendInstance instance) =>
        processes.TryGetValue(instance, out var lease)
            ? lease
            : throw new LiteLlmException(
                "aigw_litellm_instance_unknown",
                "The managed LiteLLM instance is not registered.");

    private async Task CleanupFailedStartsAsync(CancellationToken cancellationToken)
    {
        var failures = new List<Exception>();
        foreach (var lease in failedStarts.Keys)
        {
            try
            {
                await lease.StopAsync(cancellationToken);
                if (lease.IsStopped)
                {
                    failedStarts.TryRemove(lease, out _);
                }
            }
            catch (Exception exception)
            {
                failures.Add(exception);
            }
        }

        if (failures.Count > 0)
        {
            throw new LiteLlmException(
                "aigw_litellm_cleanup_pending",
                "A previously failed LiteLLM start still requires process cleanup.",
                BackendFailureCategory.Unavailable,
                new AggregateException(failures));
        }
    }

    private static LiteLlmException PreservePreparationFailure(
        Exception preparationFailure,
        Exception cleanupFailure)
    {
        var aggregate = new AggregateException(
            "LiteLLM preparation and process cleanup both failed.",
            preparationFailure,
            cleanupFailure);
        return preparationFailure is BackendHostException backendFailure
            ? new LiteLlmException(
                backendFailure.ErrorCode,
                backendFailure.Message,
                backendFailure.Category,
                aggregate)
            : new LiteLlmException(
                "aigw_litellm_prepare_cleanup_failed",
                "LiteLLM preparation failed and the process could not be cleaned up.",
                BackendFailureCategory.Unavailable,
                aggregate);
    }

    private static void ValidateInstance(BackendInstance instance, string expectedToken)
    {
        if (!instance.BaseAddress.IsAbsoluteUri ||
            !instance.BaseAddress.Scheme.Equals(Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase) ||
            !IPAddress.TryParse(instance.BaseAddress.Host, out var address) ||
            !IPAddress.IsLoopback(address) ||
            instance.BaseAddress.AbsolutePath != "/" ||
            !string.IsNullOrEmpty(instance.BaseAddress.UserInfo) ||
            !string.IsNullOrEmpty(instance.BaseAddress.Query) ||
            !string.IsNullOrEmpty(instance.BaseAddress.Fragment) ||
            !FixedTimeEquals(instance.InternalToken, expectedToken))
        {
            throw new LiteLlmException(
                "aigw_litellm_instance_invalid",
                "The managed LiteLLM process returned an invalid private endpoint.");
        }
    }

    private static bool FixedTimeEquals(string left, string right)
    {
        var leftBytes = Encoding.UTF8.GetBytes(left);
        var rightBytes = Encoding.UTF8.GetBytes(right);
        try
        {
            return leftBytes.Length == rightBytes.Length &&
                CryptographicOperations.FixedTimeEquals(leftBytes, rightBytes);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(leftBytes);
            CryptographicOperations.ZeroMemory(rightBytes);
        }
    }

    private sealed class ProcessLease(ILiteLlmManagedProcess process)
    {
        private readonly object stateLock = new();
        private readonly SemaphoreSlim operationGate = new(1, 1);
        private Task? stopTask;
        private ProcessState state = ProcessState.Active;

        public ILiteLlmManagedProcess Process { get; } = process;

        public bool IsStopped
        {
            get
            {
                lock (stateLock)
                {
                    return state == ProcessState.Stopped;
                }
            }
        }

        public async Task<bool> ProbeReadyAsync(CancellationToken cancellationToken)
        {
            EnsureStateAllowsProbe();
            await operationGate.WaitAsync(cancellationToken);
            try
            {
                EnsureStateAllowsProbe();
                return await Process.ProbeReadyAsync(cancellationToken);
            }
            finally
            {
                operationGate.Release();
            }
        }

        public async Task DrainAsync(CancellationToken cancellationToken)
        {
            lock (stateLock)
            {
                if (state == ProcessState.Draining)
                {
                    return;
                }

                EnsureStateAllowsDrain();
                state = ProcessState.Draining;
            }

            var gateEntered = false;
            var drainCompleted = false;
            try
            {
                await operationGate.WaitAsync(cancellationToken);
                gateEntered = true;
                lock (stateLock)
                {
                    if (state != ProcessState.Draining)
                    {
                        return;
                    }
                }

                await Process.DrainAsync(cancellationToken);
                drainCompleted = true;
            }
            finally
            {
                if (!drainCompleted)
                {
                    lock (stateLock)
                    {
                        if (state == ProcessState.Draining)
                        {
                            state = ProcessState.Active;
                        }
                    }
                }

                if (gateEntered)
                {
                    operationGate.Release();
                }
            }
        }

        public Task StopAsync(CancellationToken cancellationToken)
        {
            Task sharedStop;
            lock (stateLock)
            {
                if (state == ProcessState.Stopped)
                {
                    return Task.CompletedTask;
                }

                if (stopTask is null || stopTask.IsCompleted)
                {
                    state = ProcessState.Stopping;
                    stopTask = StopCoreAsync();
                }

                sharedStop = stopTask;
            }

            return sharedStop.WaitAsync(cancellationToken);
        }

        private async Task StopCoreAsync()
        {
            Exception? stopFailure = null;
            Exception? disposeFailure = null;
            await operationGate.WaitAsync(CancellationToken.None);
            try
            {
                try
                {
                    await Process.StopAsync(CancellationToken.None);
                }
                catch (Exception exception)
                {
                    stopFailure = exception;
                }

                try
                {
                    await Process.DisposeAsync();
                }
                catch (Exception exception)
                {
                    disposeFailure = exception;
                }
            }
            finally
            {
                lock (stateLock)
                {
                    state = stopFailure is null && disposeFailure is null
                        ? ProcessState.Stopped
                        : ProcessState.StopFailed;
                }

                operationGate.Release();
            }

            if (stopFailure is not null && disposeFailure is not null)
            {
                throw new AggregateException(
                    "Stopping and disposing the managed LiteLLM process both failed.",
                    stopFailure,
                    disposeFailure);
            }

            if (stopFailure is not null)
            {
                ExceptionDispatchInfo.Capture(stopFailure).Throw();
            }

            if (disposeFailure is not null)
            {
                ExceptionDispatchInfo.Capture(disposeFailure).Throw();
            }
        }

        private void EnsureStateAllowsProbe()
        {
            lock (stateLock)
            {
                if (state != ProcessState.Active)
                {
                    throw StateException();
                }
            }
        }

        private void EnsureStateAllowsDrain()
        {
            if (state != ProcessState.Active)
            {
                throw StateException();
            }
        }

        private LiteLlmException StateException() => state switch
        {
            ProcessState.Draining => new LiteLlmException(
                "aigw_litellm_instance_draining",
                "The managed LiteLLM instance is draining."),
            ProcessState.Stopping => new LiteLlmException(
                "aigw_litellm_instance_stopping",
                "The managed LiteLLM instance is stopping."),
            ProcessState.StopFailed => new LiteLlmException(
                "aigw_litellm_instance_stop_failed",
                "The managed LiteLLM instance could not be stopped and remains tracked."),
            ProcessState.Stopped => new LiteLlmException(
                "aigw_litellm_instance_stopped",
                "The managed LiteLLM instance is stopped."),
            _ => new LiteLlmException(
                "aigw_litellm_instance_state_invalid",
                "The managed LiteLLM instance state is invalid."),
        };

        private enum ProcessState
        {
            Active,
            Draining,
            Stopping,
            StopFailed,
            Stopped,
        }
    }
}
