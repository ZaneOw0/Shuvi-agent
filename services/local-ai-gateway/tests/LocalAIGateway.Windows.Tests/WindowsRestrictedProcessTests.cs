using System.IO.Pipes;
using System.Text.Json;
using LocalAIGateway.ProcessFixture;
using LocalAIGateway.Windows.Runtime;

namespace LocalAIGateway.Windows.Tests;

public sealed class WindowsRestrictedProcessTests : IDisposable
{
    private readonly string root = Path.Combine(Path.GetTempPath(), $"LocalAIGateway-M5d-Restricted-{Guid.NewGuid():N}");

    [Fact]
    public void Generic_restricted_launcher_preserves_arguments_and_uses_only_explicit_environment()
    {
        Directory.CreateDirectory(root);
        var executable = Path.ChangeExtension(typeof(ProcessFixtureMarker).Assembly.Location, ".exe");
        var output = Path.Combine(root, "capture.json");
        var priorToken = Environment.GetEnvironmentVariable("AIGW_TEST_TOKEN");
        Environment.SetEnvironmentVariable("AIGW_TEST_TOKEN", "must-not-be-inherited");
        try
        {
            using var process = WindowsDetachedProcess.Start(
                executable,
                root,
                ["capture", output, "0", "argument with spaces", "quoted\"argument"],
                new Dictionary<string, string> { ["AIGW_TEST_BASE_URL"] = "http://127.0.0.1:1" });
            Assert.True(process.WaitForExit(10_000));
        }
        finally
        {
            Environment.SetEnvironmentVariable("AIGW_TEST_TOKEN", priorToken);
        }

        using var document = JsonDocument.Parse(File.ReadAllText(output));
        var json = document.RootElement;
        Assert.Equal(new[] { "argument with spaces", "quoted\"argument" },
            json.GetProperty("arguments").EnumerateArray().Select(item => item.GetString()).ToArray());
        Assert.Equal(root, json.GetProperty("workingDirectory").GetString());
        Assert.Equal("http://127.0.0.1:1", json.GetProperty("baseUrl").GetString());
        Assert.Equal(JsonValueKind.Null, json.GetProperty("token").ValueKind);
    }

    [Fact]
    public async Task Restricted_launcher_does_not_inherit_an_unlisted_pipe_handle()
    {
        var executable = Path.ChangeExtension(typeof(ProcessFixtureMarker).Assembly.Location, ".exe");
        using var pipe = new AnonymousPipeServerStream(
            PipeDirection.In,
            HandleInheritability.Inheritable);
        _ = pipe.GetClientHandleAsString();
        using var process = WindowsDetachedProcess.Start(
            executable,
            Path.GetTempPath(),
            ["child"],
            new Dictionary<string, string>());
        try
        {
            pipe.DisposeLocalCopyOfClientHandle();
            var buffer = new byte[1];
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(2));
            Assert.Equal(0, await pipe.ReadAsync(buffer, timeout.Token));
        }
        finally
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
                process.WaitForExit();
            }
        }
    }

    public void Dispose()
    {
        if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
    }
}
