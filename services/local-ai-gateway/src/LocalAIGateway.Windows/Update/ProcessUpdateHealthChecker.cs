using System.ComponentModel;
using System.Diagnostics;
using LocalAIGateway.Core.Update;

namespace LocalAIGateway.Windows.Update;

public sealed class ProcessUpdateHealthChecker : IUpdateHealthChecker
{
    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(20);

    public async Task CheckAsync(string packageRoot, CancellationToken cancellationToken = default)
    {
        var root = Path.GetFullPath(packageRoot);
        var checks = new (string Path, string[] Arguments)[]
        {
            (Path.Combine(root, "aigw.exe"), ["--version"]),
            (Path.Combine(root, "aigw-runtime.exe"), ["--version"]),
            (Path.Combine(root, "aigw-launcher.exe"), ["--version"]),
            (Path.Combine(root, "tray", "aigw-tray.exe"), ["--version"]),
            (Path.Combine(root, "updater", "aigw-updater.exe"), ["--version"]),
            (Path.Combine(root, "runtime", "python", "python.exe"),
                ["-B", "-I", "-c", "import cryptography, sqlite3"]),
        };

        foreach (var check in checks)
        {
            if (!File.Exists(check.Path) || IsReparse(check.Path))
            {
                throw new UpdateException("aigw_update_health_component_missing", "The candidate is missing a required health-check component.");
            }
            await RunAsync(check.Path, root, check.Arguments, cancellationToken);
        }
    }

    private static async Task RunAsync(
        string executable,
        string workingDirectory,
        IReadOnlyList<string> arguments,
        CancellationToken cancellationToken)
    {
        var start = new ProcessStartInfo
        {
            FileName = executable,
            WorkingDirectory = workingDirectory,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        start.Environment.Clear();
        var systemRoot = Environment.GetEnvironmentVariable("SystemRoot");
        if (!string.IsNullOrEmpty(systemRoot)) start.Environment["SystemRoot"] = systemRoot;
        start.Environment["DOTNET_MULTILEVEL_LOOKUP"] = "0";
        start.Environment["DOTNET_ROOT"] = Path.Combine(workingDirectory, ".missing-global-dotnet");
        start.Environment["PYTHONNOUSERSITE"] = "1";
        start.Environment["PYTHONDONTWRITEBYTECODE"] = "1";
        start.Environment["PYTHONUTF8"] = "1";

        try
        {
            using var process = Process.Start(start) ?? throw StartFailed();
            var outputTask = process.StandardOutput.ReadToEndAsync(CancellationToken.None);
            var errorTask = process.StandardError.ReadToEndAsync(CancellationToken.None);
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(Timeout);
            try
            {
                await process.WaitForExitAsync(timeout.Token);
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            {
                Kill(process);
                throw new UpdateException("aigw_update_health_timeout", "A candidate side-load health check timed out.");
            }
            catch (OperationCanceledException)
            {
                Kill(process);
                throw;
            }
            var output = await outputTask;
            var error = await errorTask;
            if (output.Length + error.Length > 1024 * 1024)
            {
                throw new UpdateException("aigw_update_health_output_too_large", "A candidate health check produced too much output.");
            }
            if (process.ExitCode != 0)
            {
                throw new UpdateException("aigw_update_health_failed", "A candidate side-load health check failed.");
            }
        }
        catch (UpdateException) { throw; }
        catch (Win32Exception exception) { throw StartFailed(exception); }
        catch (IOException exception)
        {
            throw new UpdateException("aigw_update_health_failed", "A candidate side-load health check could not be completed.", exception);
        }
    }

    private static void Kill(Process process)
    {
        try
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
                process.WaitForExit();
            }
        }
        catch (InvalidOperationException) { }
    }

    private static bool IsReparse(string path) =>
        (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0;

    private static UpdateException StartFailed(Exception? inner = null) => new(
        "aigw_update_health_start_failed",
        "Windows could not start a candidate side-load health check.",
        inner);
}
