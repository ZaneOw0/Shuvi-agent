using System.Reflection;
using LocalAIGateway.Core.Configuration;
using LocalAIGateway.LiteLlm;
using LocalAIGateway.Runtime.Backend;
using LocalAIGateway.Windows;

namespace LocalAIGateway.Runtime;

public static class Program
{
    public const int SuccessExitCode = 0;
    public const int InvalidArgumentsExitCode = 2;
    public const int ConfigurationErrorExitCode = 10;
    public const int CredentialErrorExitCode = 11;
    public const int RuntimeConflictExitCode = 12;
    public const int BackendUnavailableExitCode = 13;
    public const int UnexpectedErrorExitCode = 70;

    public static async Task<int> Main(string[] args)
    {
        if (args.Length == 1 && args[0].Equals("--version", StringComparison.OrdinalIgnoreCase))
        {
            Console.Out.WriteLine($"Local AI Gateway Runtime {GetVersion()}");
            return SuccessExitCode;
        }

        if (args.Length == 1 && args[0].Equals("--help", StringComparison.OrdinalIgnoreCase))
        {
            Console.Out.WriteLine("Local AI Gateway Runtime");
            Console.Out.WriteLine("Use --serve for the private LiteLLM runtime or --m2-test-serve for development verification.");
            return SuccessExitCode;
        }

        if (args.Length != 1 ||
            (!args[0].Equals("--serve", StringComparison.Ordinal) &&
             !args[0].Equals("--m2-test-serve", StringComparison.Ordinal)))
        {
            Console.Error.WriteLine("Invalid runtime arguments (aigw_invalid_arguments).");
            return InvalidArgumentsExitCode;
        }

        try
        {
            return args[0] == "--serve"
                ? await RunProductionHostAsync()
                : await RunM2TestHostAsync();
        }
        catch (ConfigurationException exception)
        {
            Console.Error.WriteLine($"Configuration failed ({exception.ErrorCode}).");
            return ConfigurationErrorExitCode;
        }
        catch (RuntimeConflictException exception)
        {
            Console.Error.WriteLine($"Runtime conflict ({exception.ErrorCode}).");
            return RuntimeConflictExitCode;
        }
        catch (RuntimeInstanceConflictException exception)
        {
            Console.Error.WriteLine($"Runtime conflict ({exception.ErrorCode}).");
            return RuntimeConflictExitCode;
        }
        catch (BackendCredentialException exception)
        {
            Console.Error.WriteLine($"Credential failed ({exception.ErrorCode}).");
            return CredentialErrorExitCode;
        }
        catch (BackendUnavailableException exception)
        {
            Console.Error.WriteLine($"Backend unavailable ({exception.ErrorCode}).");
            return BackendUnavailableExitCode;
        }
        catch (RuntimeGatewayException exception)
        {
            Console.Error.WriteLine($"Runtime failed ({exception.ErrorCode}).");
            return ConfigurationErrorExitCode;
        }
        catch
        {
            Console.Error.WriteLine("An unexpected runtime error occurred.");
            return UnexpectedErrorExitCode;
        }
    }

    private static async Task<int> RunProductionHostAsync()
    {
        var paths = ConfigurationPaths.ForCurrentUser();
        var fileSecurity = new WindowsConfigurationFileSecurity();
        var operationalLog = new BoundedJsonFileOperationalLog(
            new GatewayOperationalLogOptions
            {
                DirectoryPath = paths.LogsDirectory,
            },
            fileSecurity);
        var credentialStore = new WindowsCredentialStore();
        var backendHost = new LiteLlmBackendHost(
            new LiteLlmConfigurationCompiler(credentialStore),
            new WindowsLiteLlmProcessFactory(
                AppContext.BaseDirectory,
                Path.Combine(paths.RootDirectory, "runtime"),
                fileSecurity));
        GatewayDaemonHost? daemon = null;
        try
        {
            daemon = await GatewayDaemonHost.StartAsync(new GatewayDaemonOptions
            {
                ConfigurationStore = new ConfigurationStore(paths, fileSecurity),
                CredentialStore = credentialStore,
                BackendHost = backendHost,
                SingleInstanceProvider = new WindowsCurrentUserSingleInstanceProvider(),
                OperationalLog = operationalLog,
            });
            Console.Out.WriteLine($"READY {daemon.BaseAddress.AbsoluteUri}");
            await WaitForDaemonOrConsoleShutdownAsync(daemon);
            return SuccessExitCode;
        }
        finally
        {
            if (daemon is not null)
            {
                await daemon.DisposeAsync();
            }
            else
            {
                await backendHost.DisposeAsync();
            }
        }
    }

    private static async Task<int> RunM2TestHostAsync()
    {
        if (!string.Equals(
                Environment.GetEnvironmentVariable("AIGW_M2_TEST_MODE"),
                "1",
                StringComparison.Ordinal))
        {
            throw new RuntimeGatewayException(
                "aigw_runtime_test_mode_required",
                "M2 verification host requires explicit test mode.");
        }

        var backendText = RequiredEnvironmentVariable("AIGW_M2_BACKEND_URI");
        if (!Uri.TryCreate(backendText, UriKind.Absolute, out var backendUri))
        {
            throw new BackendUnavailableException("M2 backend URI is invalid.");
        }

        var clientToken = RequiredEnvironmentVariable("AIGW_M2_CLIENT_TOKEN");
        var backendToken = RequiredEnvironmentVariable("AIGW_M2_BACKEND_TOKEN");
        var portText = Environment.GetEnvironmentVariable("AIGW_M2_LISTEN_PORT");
        var port = GatewayRuntimeOptions.ProductionPort;
        if (!string.IsNullOrWhiteSpace(portText) &&
            (!int.TryParse(
                portText,
                System.Globalization.NumberStyles.None,
                System.Globalization.CultureInfo.InvariantCulture,
                out port) ||
             port is < 0 or > 65535))
        {
            throw new RuntimeGatewayException(
                "aigw_runtime_port_invalid",
                "M2 listen port is invalid.");
        }

        var store = new ConfigurationStore(
            ConfigurationPaths.ForCurrentUser(),
            new WindowsConfigurationFileSecurity());
        var configuration = await store.LoadAsync();
        using var backend = new StaticBackendHost(backendUri, backendToken);
        await using var runtime = await GatewayRuntimeHost.StartAsync(new GatewayRuntimeOptions
        {
            Configuration = configuration,
            ClientToken = clientToken,
            BackendHost = backend,
            Port = port,
        });

        Console.Out.WriteLine($"READY {runtime.BaseAddress.AbsoluteUri}");
        await WaitForConsoleShutdownAsync();
        return SuccessExitCode;
    }

    private static async Task WaitForConsoleShutdownAsync()
    {
        using var shutdown = new CancellationTokenSource();
        ConsoleCancelEventHandler cancelHandler = (_, eventArgs) =>
        {
            eventArgs.Cancel = true;
            shutdown.Cancel();
        };
        Console.CancelKeyPress += cancelHandler;
        try
        {
            await Task.Delay(Timeout.InfiniteTimeSpan, shutdown.Token);
        }
        catch (OperationCanceledException) when (shutdown.IsCancellationRequested)
        {
        }
        finally
        {
            Console.CancelKeyPress -= cancelHandler;
        }
    }

    private static async Task WaitForDaemonOrConsoleShutdownAsync(GatewayDaemonHost daemon)
    {
        using var shutdown = new CancellationTokenSource();
        ConsoleCancelEventHandler cancelHandler = (_, eventArgs) =>
        {
            eventArgs.Cancel = true;
            shutdown.Cancel();
        };
        Console.CancelKeyPress += cancelHandler;
        try
        {
            await daemon.WaitForShutdownAsync(shutdown.Token);
        }
        catch (OperationCanceledException) when (shutdown.IsCancellationRequested)
        {
        }
        finally
        {
            Console.CancelKeyPress -= cancelHandler;
        }
    }

    private static string RequiredEnvironmentVariable(string name)
    {
        var value = Environment.GetEnvironmentVariable(name);
        return !string.IsNullOrWhiteSpace(value)
            ? value
            : throw new RuntimeGatewayException(
                "aigw_runtime_test_environment_missing",
                "M2 verification environment is incomplete.");
    }

    private static string GetVersion()
    {
        var assembly = typeof(Program).Assembly;
        return assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion
            ?? assembly.GetName().Version?.ToString()
            ?? "unknown";
    }
}
