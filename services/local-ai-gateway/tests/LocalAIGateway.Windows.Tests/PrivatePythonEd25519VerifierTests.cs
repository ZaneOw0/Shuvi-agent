using System.Text.Json;
using LocalAIGateway.Core.Update;
using LocalAIGateway.Windows.Update;

namespace LocalAIGateway.Windows.Tests;

public sealed class PrivatePythonEd25519VerifierTests : IDisposable
{
    private readonly string root = Path.Combine(Path.GetTempPath(), $"LocalAIGateway-M5d-Verify-{Guid.NewGuid():N}");
    private readonly string python;
    private readonly string script;

    public PrivatePythonEd25519VerifierTests()
    {
        Directory.CreateDirectory(root);
        python = Path.Combine(root, "python.exe");
        script = Path.Combine(root, "aigw_update_verify.py");
        File.WriteAllText(python, "fixture");
        File.WriteAllText(script, "fixture");
    }

    [Fact]
    public async Task Verification_uses_bounded_stdin_and_zeroes_request()
    {
        var runner = new RecordingRunner(new UpdateVerificationProcessResult(
            0, "{\"schemaVersion\":1,\"valid\":true}"));
        var verifier = new PrivatePythonEd25519Verifier(python, script, runner);

        Assert.True(await verifier.VerifyAsync(new byte[32], new byte[] { 1, 2, 3 }, new byte[64]));
        using var request = JsonDocument.Parse(runner.Observed!);
        Assert.Equal(1, request.RootElement.GetProperty("schemaVersion").GetInt32());
        Assert.All(runner.Original!, value => Assert.Equal(0, value));
    }

    [Fact]
    public async Task Process_result_must_match_exit_code()
    {
        var verifier = new PrivatePythonEd25519Verifier(
            python, script,
            new RecordingRunner(new UpdateVerificationProcessResult(
                21, "{\"schemaVersion\":1,\"valid\":true}")));

        var exception = await Assert.ThrowsAsync<UpdateException>(() =>
            verifier.VerifyAsync(new byte[32], ReadOnlyMemory<byte>.Empty, new byte[64]));
        Assert.Equal("aigw_update_verifier_result_invalid", exception.ErrorCode);
    }

    [Fact]
    public async Task Configured_private_runtime_verifies_RFC8032_vector()
    {
        var configuredPython = Environment.GetEnvironmentVariable("AIGW_M5D_PYTHON_PATH");
        var configuredScript = Environment.GetEnvironmentVariable("AIGW_M5D_VERIFY_SCRIPT_PATH");
        if (string.IsNullOrWhiteSpace(configuredPython) || string.IsNullOrWhiteSpace(configuredScript)) return;

        var publicKey = Convert.FromHexString("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a");
        var signature = Convert.FromHexString(
            "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155" +
            "5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b");
        var verifier = new PrivatePythonEd25519Verifier(
            configuredPython, configuredScript,
            new UpdateVerificationProcessRunner(TimeSpan.FromSeconds(10)));

        Assert.True(await verifier.VerifyAsync(publicKey, ReadOnlyMemory<byte>.Empty, signature));
        signature[0] ^= 1;
        Assert.False(await verifier.VerifyAsync(publicKey, ReadOnlyMemory<byte>.Empty, signature));
    }

    public void Dispose()
    {
        if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
    }

    private sealed class RecordingRunner(UpdateVerificationProcessResult result) : IUpdateVerificationProcessRunner
    {
        public byte[]? Original { get; private set; }
        public byte[]? Observed { get; private set; }

        public Task<UpdateVerificationProcessResult> RunAsync(
            string pythonPath,
            string scriptPath,
            byte[] request,
            CancellationToken cancellationToken)
        {
            Original = request;
            Observed = request.ToArray();
            return Task.FromResult(result);
        }
    }
}
