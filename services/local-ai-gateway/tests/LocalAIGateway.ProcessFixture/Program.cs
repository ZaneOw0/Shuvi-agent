using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;

namespace LocalAIGateway.ProcessFixture;

public sealed class ProcessFixtureMarker;

internal static class Program
{
    private static async Task<int> Main(string[] args)
    {
        if (args is ["--serve"])
        {
            var standardHandleTypes = string.Join(
                ",",
                FileType(NativeMethods.StandardInputHandle),
                FileType(NativeMethods.StandardOutputHandle),
                FileType(NativeMethods.StandardErrorHandle));
            var markerPath = Path.Combine(
                Environment.CurrentDirectory,
                "daemon-standard-handles.txt");
            var markerTemporaryPath = markerPath + ".tmp";
            await File.WriteAllTextAsync(markerTemporaryPath, standardHandleTypes);
            File.Move(markerTemporaryPath, markerPath);
            await Task.Delay(Timeout.InfiniteTimeSpan);
            return 0;
        }

        if (args is ["child"])
        {
            await Task.Delay(Timeout.InfiniteTimeSpan);
            return 0;
        }

        if (args is ["parent", var pidFile])
        {
            var dotnetHost = Environment.GetEnvironmentVariable("DOTNET_HOST_PATH");
            if (string.IsNullOrWhiteSpace(dotnetHost))
            {
                return 2;
            }

            var startInfo = new ProcessStartInfo
            {
                FileName = dotnetHost,
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            startInfo.ArgumentList.Add(typeof(ProcessFixtureMarker).Assembly.Location);
            startInfo.ArgumentList.Add("child");
            using var child = Process.Start(startInfo) ?? throw new InvalidOperationException(
                "The process fixture could not start its child.");
            await File.WriteAllTextAsync(pidFile, child.Id.ToString(System.Globalization.CultureInfo.InvariantCulture));
            await Task.Delay(Timeout.InfiniteTimeSpan);
            return 0;
        }

        if (args is ["capture", var outputFile, var exitCodeText, .. var capturedArguments] &&
            int.TryParse(
                exitCodeText,
                System.Globalization.NumberStyles.Integer,
                System.Globalization.CultureInfo.InvariantCulture,
                out var exitCode))
        {
            var capture = new
            {
                arguments = capturedArguments,
                workingDirectory = Environment.CurrentDirectory,
                baseUrl = Environment.GetEnvironmentVariable("AIGW_TEST_BASE_URL"),
                token = Environment.GetEnvironmentVariable("AIGW_TEST_TOKEN"),
            };
            await File.WriteAllTextAsync(outputFile, JsonSerializer.Serialize(capture));
            return exitCode;
        }

        return 1;
    }

    private static uint FileType(int standardHandle) =>
        NativeMethods.GetFileType(NativeMethods.GetStdHandle(standardHandle));

    private static class NativeMethods
    {
        internal const int StandardInputHandle = -10;
        internal const int StandardOutputHandle = -11;
        internal const int StandardErrorHandle = -12;

        [DllImport("kernel32.dll", ExactSpelling = true)]
        internal static extern IntPtr GetStdHandle(int standardHandle);

        [DllImport("kernel32.dll", ExactSpelling = true)]
        internal static extern uint GetFileType(IntPtr handle);
    }
}
