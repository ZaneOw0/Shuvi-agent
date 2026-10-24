using System.ComponentModel;
using System.Diagnostics;

namespace LocalAIGateway.Launcher;

internal interface IClientProcessRunner
{
    Task<int> RunAsync(
        ClientLaunchRequest request,
        string baseUrl,
        string token,
        CancellationToken cancellationToken);
}

internal sealed class ClientProcessRunner : IClientProcessRunner
{
    public async Task<int> RunAsync(
        ClientLaunchRequest request,
        string baseUrl,
        string token,
        CancellationToken cancellationToken)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = request.ExecutablePath,
            WorkingDirectory = request.WorkingDirectory,
            UseShellExecute = false,
        };
        foreach (var argument in request.Arguments)
        {
            startInfo.ArgumentList.Add(argument);
        }
        if (request.BaseUrlEnvironmentVariable is not null)
        {
            startInfo.Environment[request.BaseUrlEnvironmentVariable] = baseUrl;
        }
        startInfo.Environment[request.TokenEnvironmentVariable] = token;

        try
        {
            using var process = Process.Start(startInfo)
                ?? throw new ClientLaunchException(
                    "aigw_launcher_process_start_failed",
                    "The target client process could not be created.");
            await process.WaitForExitAsync(cancellationToken);
            return process.ExitCode;
        }
        catch (ClientLaunchException)
        {
            throw;
        }
        catch (Win32Exception exception)
        {
            throw new ClientLaunchException(
                "aigw_launcher_process_start_failed",
                "Windows could not create the target client process.",
                exception);
        }
        finally
        {
            startInfo.Environment.Remove(request.TokenEnvironmentVariable);
        }
    }
}
