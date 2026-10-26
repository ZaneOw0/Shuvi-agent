using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Runtime.ExceptionServices;
using System.Security.Cryptography;
using LocalAIGateway.Core.Backend;
using LocalAIGateway.Core.Configuration;

namespace LocalAIGateway.LiteLlm;

public sealed class WindowsLiteLlmProcessFactory : ILiteLlmProcessFactory
{
    private static readonly string[] RuntimeStateDirectories =
    [
        "temp",
        "cache",
        "home",
        "appdata",
        "localappdata",
    ];

    private readonly string applicationRoot;
    private readonly string instancesRoot;
    private readonly string usageRoot;
    private readonly string usageDatabasePath;
    private readonly IConfigurationFileSecurity fileSecurity;
    private readonly TimeSpan stopTimeout;
    private readonly IWindowsJobProcessLauncher processLauncher;
    private readonly Func<int> portAllocator;
    private readonly Func<string> instanceIdFactory;
    private readonly Func<HttpMessageHandler> httpHandlerFactory;

    public WindowsLiteLlmProcessFactory(
        string applicationRoot,
        string runtimeRoot,
        IConfigurationFileSecurity fileSecurity,
        TimeSpan? stopTimeout = null)
        : this(
            applicationRoot,
            runtimeRoot,
            fileSecurity,
            stopTimeout ?? TimeSpan.FromSeconds(10),
            WindowsJobProcessLauncher.Instance,
            AllocateLoopbackPort,
            CreateInstanceId,
            CreateHttpHandler)
    {
    }

    internal WindowsLiteLlmProcessFactory(
        string applicationRoot,
        string runtimeRoot,
        IConfigurationFileSecurity fileSecurity,
        TimeSpan stopTimeout,
        IWindowsJobProcessLauncher processLauncher,
        Func<int> portAllocator,
        Func<string> instanceIdFactory,
        Func<HttpMessageHandler> httpHandlerFactory)
    {
        ValidateRoot(applicationRoot, "aigw_litellm_application_root_invalid");
        ValidateRoot(runtimeRoot, "aigw_litellm_runtime_root_invalid");
        ArgumentNullException.ThrowIfNull(fileSecurity);
        ArgumentNullException.ThrowIfNull(processLauncher);
        ArgumentNullException.ThrowIfNull(portAllocator);
        ArgumentNullException.ThrowIfNull(instanceIdFactory);
        ArgumentNullException.ThrowIfNull(httpHandlerFactory);
        if (stopTimeout <= TimeSpan.Zero || stopTimeout > TimeSpan.FromMinutes(5))
        {
            throw new ArgumentOutOfRangeException(nameof(stopTimeout));
        }

        this.applicationRoot = Path.GetFullPath(applicationRoot);
        var normalizedRuntimeRoot = Path.GetFullPath(runtimeRoot);
        instancesRoot = Path.Combine(normalizedRuntimeRoot, "instances");
        var dataRoot = Directory.GetParent(normalizedRuntimeRoot)?.FullName ?? throw new LiteLlmException(
            "aigw_litellm_runtime_root_invalid",
            "The LiteLLM runtime root does not have a data root.");
        usageRoot = Path.Combine(dataRoot, "usage");
        usageDatabasePath = Path.Combine(usageRoot, "usage.db");
        this.fileSecurity = fileSecurity;
        this.stopTimeout = stopTimeout;
        this.processLauncher = processLauncher;
        this.portAllocator = portAllocator;
        this.instanceIdFactory = instanceIdFactory;
        this.httpHandlerFactory = httpHandlerFactory;
    }

    public async Task<ILiteLlmManagedProcess> StartAsync(
        ProfileConfiguration profile,
        LiteLlmConfigurationPlan plan,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(profile);
        ArgumentNullException.ThrowIfNull(plan);
        cancellationToken.ThrowIfCancellationRequested();
        if (!plan.Environment.TryGetValue("AIGW_LITELLM_MASTER_KEY", out var internalToken) ||
            string.IsNullOrEmpty(internalToken))
        {
            throw new LiteLlmException(
                "aigw_litellm_internal_token_missing",
                "The LiteLLM process plan does not contain its private token.");
        }

        var instanceId = instanceIdFactory();
        ValidateInstanceId(instanceId);
        var instanceDirectory = Path.Combine(instancesRoot, instanceId);
        var configurationPath = Path.Combine(instanceDirectory, "litellm.yaml");
        var callbackModulePath = Path.Combine(instanceDirectory, LiteLlmUsageCallbackAssets.ModuleFileName);
        var usageMetadataPath = Path.Combine(instanceDirectory, LiteLlmUsageCallbackAssets.MetadataFileName);
        IWindowsJobProcess? process = null;
        try
        {
            PrepareInstanceDirectories(instanceDirectory);
            await WriteConfigurationAsync(configurationPath, plan.ConfigurationUtf8, cancellationToken);
            if (plan.CallbackModuleUtf8.IsEmpty || plan.UsageMetadataUtf8.IsEmpty)
            {
                throw new LiteLlmException(
                    "aigw_litellm_usage_callback_missing",
                    "The private usage callback assets are missing.",
                    BackendFailureCategory.Configuration);
            }
            await WriteConfigurationAsync(callbackModulePath, plan.CallbackModuleUtf8, cancellationToken);
            await WriteConfigurationAsync(usageMetadataPath, plan.UsageMetadataUtf8, cancellationToken);

            var pythonPath = Path.Combine(applicationRoot, "runtime", "python", "python.exe");
            if (!File.Exists(pythonPath))
            {
                throw new LiteLlmException(
                    "aigw_litellm_python_missing",
                    "The private LiteLLM Python runtime is missing.",
                    BackendFailureCategory.Configuration);
            }

            var port = portAllocator();
            var processEnvironment = new Dictionary<string, string>(plan.Environment, StringComparer.Ordinal)
            {
                ["AIGW_USAGE_DATABASE"] = usageDatabasePath,
                ["AIGW_USAGE_METADATA"] = usageMetadataPath,
            };
            var spec = LiteLlmProcessStartSpec.Create(
                applicationRoot,
                configurationPath,
                port,
                processEnvironment);
            var platformEnvironment = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            var systemRoot = Environment.GetEnvironmentVariable("SystemRoot");
            if (!string.IsNullOrEmpty(systemRoot))
            {
                platformEnvironment["SystemRoot"] = systemRoot;
            }

            process = processLauncher.Start(spec.CreateProcessStartInfo(platformEnvironment));
            cancellationToken.ThrowIfCancellationRequested();
            var httpClient = new HttpClient(httpHandlerFactory(), disposeHandler: true)
            {
                BaseAddress = new Uri($"http://127.0.0.1:{port}/", UriKind.Absolute),
                Timeout = Timeout.InfiniteTimeSpan,
            };
            var instance = new BackendInstance(httpClient.BaseAddress, internalToken);
            return new ManagedProcess(
                instance,
                process,
                httpClient,
                instanceDirectory,
                instancesRoot,
                stopTimeout);
        }
        catch (Exception startFailure)
        {
            var cleanupFailures = new List<Exception>();
            var processStopped = process is null;
            if (process is not null)
            {
                try
                {
                    await process.TerminateAsync(stopTimeout, CancellationToken.None);
                }
                catch (Exception cleanupFailure)
                {
                    cleanupFailures.Add(cleanupFailure);
                }

                try
                {
                    await process.DisposeAsync();
                    processStopped = true;
                }
                catch (Exception cleanupFailure)
                {
                    cleanupFailures.Add(cleanupFailure);
                }
            }

            if (processStopped)
            {
                try
                {
                    DeleteOwnedInstanceDirectory(instanceDirectory, instancesRoot);
                }
                catch (Exception cleanupFailure)
                {
                    cleanupFailures.Add(cleanupFailure);
                }
            }

            if (cleanupFailures.Count == 0)
            {
                throw;
            }

            throw new LiteLlmException(
                "aigw_litellm_start_cleanup_failed",
                "LiteLLM startup failed and its private process state could not be completely cleaned.",
                BackendFailureCategory.Unavailable,
                new AggregateException([startFailure, .. cleanupFailures]));
        }
    }

    private void PrepareInstanceDirectories(string instanceDirectory)
    {
        Directory.CreateDirectory(usageRoot);
        fileSecurity.ProtectDirectory(usageRoot);
        Directory.CreateDirectory(instancesRoot);
        fileSecurity.ProtectDirectory(instancesRoot);
        Directory.CreateDirectory(instanceDirectory);
        fileSecurity.ProtectDirectory(instanceDirectory);
        var stateRoot = Path.Combine(instanceDirectory, "runtime-state");
        Directory.CreateDirectory(stateRoot);
        foreach (var name in RuntimeStateDirectories)
        {
            Directory.CreateDirectory(Path.Combine(stateRoot, name));
        }
    }

    private async Task WriteConfigurationAsync(
        string path,
        ReadOnlyMemory<byte> configuration,
        CancellationToken cancellationToken)
    {
        await using (var output = new FileStream(
            path,
            FileMode.CreateNew,
            FileAccess.Write,
            FileShare.None,
            4096,
            FileOptions.Asynchronous | FileOptions.WriteThrough))
        {
            await output.WriteAsync(configuration, cancellationToken);
            await output.FlushAsync(cancellationToken);
        }
        fileSecurity.ProtectFile(path);
    }

    private static int AllocateLoopbackPort()
    {
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        return ((IPEndPoint)listener.LocalEndpoint).Port;
    }

    private static string CreateInstanceId() =>
        Convert.ToHexString(RandomNumberGenerator.GetBytes(16)).ToLowerInvariant();

    private static HttpMessageHandler CreateHttpHandler() => new SocketsHttpHandler
    {
        UseProxy = false,
        AllowAutoRedirect = false,
        AutomaticDecompression = DecompressionMethods.None,
    };

    private static void ValidateRoot(string path, string errorCode)
    {
        if (string.IsNullOrWhiteSpace(path) ||
            !Path.IsPathFullyQualified(path) ||
            path.Any(char.IsControl))
        {
            throw new LiteLlmException(errorCode, "A required LiteLLM process root is malformed.");
        }
    }

    private static void ValidateInstanceId(string instanceId)
    {
        if (instanceId.Length != 32 ||
            instanceId.Any(character => character is not (>= '0' and <= '9' or >= 'a' and <= 'f')))
        {
            throw new LiteLlmException(
                "aigw_litellm_instance_id_invalid",
                "The private LiteLLM instance identifier is malformed.");
        }
    }

    private static void DeleteOwnedInstanceDirectory(string instanceDirectory, string instancesRoot)
    {
        var fullRoot = Path.GetFullPath(instancesRoot).TrimEnd(Path.DirectorySeparatorChar) +
            Path.DirectorySeparatorChar;
        var fullInstance = Path.GetFullPath(instanceDirectory);
        if (!fullInstance.StartsWith(fullRoot, StringComparison.OrdinalIgnoreCase) ||
            Path.GetDirectoryName(fullInstance)?.Equals(
                fullRoot.TrimEnd(Path.DirectorySeparatorChar),
                StringComparison.OrdinalIgnoreCase) != true)
        {
            throw new LiteLlmException(
                "aigw_litellm_instance_cleanup_unsafe",
                "Refusing to clean a LiteLLM instance directory outside its owned root.");
        }

        if (Directory.Exists(fullInstance))
        {
            Directory.Delete(fullInstance, recursive: true);
        }
    }

    private sealed class ManagedProcess(
        BackendInstance instance,
        IWindowsJobProcess process,
        HttpClient httpClient,
        string instanceDirectory,
        string instancesRoot,
        TimeSpan stopTimeout) : ILiteLlmManagedProcess
    {
        private readonly SemaphoreSlim stopGate = new(1, 1);
        private bool processStopped;
        private bool directoryRemoved;
        private int disposeCompleted;

        public BackendInstance Instance { get; } = instance;

        public async Task<bool> ProbeReadyAsync(CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (processStopped || process.HasExited)
            {
                return false;
            }

            try
            {
                using var request = new HttpRequestMessage(HttpMethod.Get, "health/liveliness");
                using var response = await httpClient.SendAsync(
                    request,
                    HttpCompletionOption.ResponseHeadersRead,
                    cancellationToken);
                return response.IsSuccessStatusCode && !process.HasExited;
            }
            catch (HttpRequestException)
            {
                return false;
            }
            catch (TaskCanceledException) when (!cancellationToken.IsCancellationRequested)
            {
                return false;
            }
        }

        public Task DrainAsync(CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return Task.CompletedTask;
        }

        public async Task StopAsync(CancellationToken cancellationToken = default)
        {
            await stopGate.WaitAsync(cancellationToken);
            try
            {
                if (!processStopped)
                {
                    Exception? terminationFailure = null;
                    Exception? disposeFailure = null;
                    try
                    {
                        await process.TerminateAsync(stopTimeout, cancellationToken);
                    }
                    catch (Exception exception)
                    {
                        terminationFailure = exception;
                    }

                    try
                    {
                        await process.DisposeAsync();
                        httpClient.Dispose();
                        processStopped = true;
                    }
                    catch (Exception exception)
                    {
                        disposeFailure = exception;
                    }

                    if (terminationFailure is not null && disposeFailure is not null)
                    {
                        throw new AggregateException(
                            "Terminating and closing the LiteLLM Job Object both failed.",
                            terminationFailure,
                            disposeFailure);
                    }
                    if (terminationFailure is not null)
                    {
                        ExceptionDispatchInfo.Capture(terminationFailure).Throw();
                    }
                    if (disposeFailure is not null)
                    {
                        ExceptionDispatchInfo.Capture(disposeFailure).Throw();
                    }
                }

                if (!directoryRemoved)
                {
                    DeleteOwnedInstanceDirectory(instanceDirectory, instancesRoot);
                    directoryRemoved = true;
                }
            }
            finally
            {
                stopGate.Release();
            }
        }

        public async ValueTask DisposeAsync()
        {
            if (Volatile.Read(ref disposeCompleted) != 0)
            {
                return;
            }

            await StopAsync(CancellationToken.None);
            if (processStopped && directoryRemoved)
            {
                Interlocked.Exchange(ref disposeCompleted, 1);
            }
        }
    }
}
