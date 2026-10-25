using System.Diagnostics;
using LocalAIGateway.ProcessFixture;

namespace LocalAIGateway.LiteLlm.Tests;

public sealed class WindowsSuspendedJobProcessTests
{
    [Fact]
    public async Task Terminate_stops_the_process_and_its_descendant_after_suspended_job_assignment()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        var dotnetHost = Environment.GetEnvironmentVariable("DOTNET_HOST_PATH");
        Assert.False(string.IsNullOrWhiteSpace(dotnetHost));
        var directory = Path.Combine(
            Path.GetTempPath(),
            "LocalAIGateway.Tests",
            $"job-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        var pidFile = Path.Combine(directory, "child.pid");
        Process? parent = null;
        Process? child = null;
        try
        {
            var startInfo = new ProcessStartInfo
            {
                FileName = dotnetHost,
                WorkingDirectory = directory,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            startInfo.Environment.Clear();
            startInfo.Environment["SystemRoot"] = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
            startInfo.Environment["DOTNET_HOST_PATH"] = dotnetHost;
            startInfo.ArgumentList.Add(typeof(ProcessFixtureMarker).Assembly.Location);
            startInfo.ArgumentList.Add("parent");
            startInfo.ArgumentList.Add(pidFile);

            await using var jobProcess = WindowsSuspendedJobProcess.Start(startInfo);
            parent = Process.GetProcessById(jobProcess.ProcessId);
            var childId = await WaitForChildPidAsync(pidFile, TimeSpan.FromSeconds(10));
            child = Process.GetProcessById(childId);

            Assert.False(parent.HasExited);
            Assert.False(child.HasExited);

            await jobProcess.TerminateAsync(TimeSpan.FromSeconds(10));
            await parent.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(10));
            await child.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(10));

            Assert.True(jobProcess.HasExited);
            Assert.True(parent.HasExited);
            Assert.True(child.HasExited);
        }
        finally
        {
            KillIfRunning(child);
            KillIfRunning(parent);
            child?.Dispose();
            parent?.Dispose();
            if (Directory.Exists(directory))
            {
                Directory.Delete(directory, recursive: true);
            }
        }
    }

    private static async Task<int> WaitForChildPidAsync(string path, TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            if (File.Exists(path))
            {
                try
                {
                    var text = await File.ReadAllTextAsync(path);
                    if (int.TryParse(text, out var processId))
                    {
                        return processId;
                    }
                }
                catch (IOException)
                {
                    // The fixture can expose the path just before its asynchronous write closes the handle.
                }
            }

            await Task.Delay(25);
        }

        throw new TimeoutException("The process fixture did not report its child process.");
    }

    private static void KillIfRunning(Process? process)
    {
        if (process is null)
        {
            return;
        }

        try
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
                process.WaitForExit(5000);
            }
        }
        catch (InvalidOperationException)
        {
        }
    }
}
