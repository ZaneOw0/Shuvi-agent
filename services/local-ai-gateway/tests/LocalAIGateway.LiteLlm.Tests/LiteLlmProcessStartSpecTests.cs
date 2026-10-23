namespace LocalAIGateway.LiteLlm.Tests;

public sealed class LiteLlmProcessStartSpecTests
{
    [Fact]
    public void Create_builds_fixed_shell_free_command_without_secrets_in_arguments()
    {
        const string secret = "process-secret-canary";
        var environment = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["AIGW_LITELLM_MASTER_KEY"] = "internal-token",
            ["AIGW_UPSTREAM_000_API_KEY"] = secret,
        };

        var spec = LiteLlmProcessStartSpec.Create(
            @"C:\Program Files\LocalAIGateway",
            @"C:\Users\Person\AppData\Local\LocalAIGateway\runtime\candidate\config.yaml",
            43123,
            environment);

        Assert.Equal(
            @"C:\Program Files\LocalAIGateway\runtime\python\python.exe",
            spec.FileName);
        Assert.Equal(@"C:\Program Files\LocalAIGateway", spec.WorkingDirectory);
        Assert.Equal(
            [
                "-B",
                "-I",
                "-c",
                "from litellm import run_server; run_server()",
                "--config",
                @"C:\Users\Person\AppData\Local\LocalAIGateway\runtime\candidate\config.yaml",
                "--host",
                "127.0.0.1",
                "--port",
                "43123",
            ],
            spec.Arguments);
        Assert.DoesNotContain(spec.Arguments, argument => argument.Contains(secret, StringComparison.Ordinal));
        Assert.Equal(secret, spec.Environment["AIGW_UPSTREAM_000_API_KEY"]);
        Assert.Equal("1", spec.Environment["PYTHONNOUSERSITE"]);
        Assert.Equal("1", spec.Environment["PYTHONDONTWRITEBYTECODE"]);
        Assert.Equal("1", spec.Environment["PYTHONUTF8"]);
        Assert.Equal("true", spec.Environment["DO_NOT_TRACK"]);
        Assert.Equal("True", spec.Environment["LITELLM_LOCAL_MODEL_COST_MAP"]);
        Assert.Equal(
            @"C:\Users\Person\AppData\Local\LocalAIGateway\runtime\candidate\runtime-state\temp",
            spec.Environment["TEMP"]);
        Assert.Equal(spec.Environment["TEMP"], spec.Environment["TMP"]);
        Assert.Equal(
            @"C:\Users\Person\AppData\Local\LocalAIGateway\runtime\candidate\runtime-state\cache",
            spec.Environment["XDG_CACHE_HOME"]);
        Assert.Equal(
            @"C:\Users\Person\AppData\Local\LocalAIGateway\runtime\candidate\runtime-state\home",
            spec.Environment["USERPROFILE"]);
        Assert.Equal(
            @"C:\Program Files\LocalAIGateway\runtime\python\Lib\site-packages\litellm\litellm_core_utils\tokenizers",
            spec.Environment["CUSTOM_TIKTOKEN_CACHE_DIR"]);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(65536)]
    public void Create_rejects_invalid_private_port(int port)
    {
        var exception = Assert.Throws<LiteLlmException>(() => LiteLlmProcessStartSpec.Create(
            @"C:\LocalAIGateway",
            @"C:\LocalAIGatewayData\config.yaml",
            port,
            new Dictionary<string, string>()));

        Assert.Equal("aigw_litellm_port_invalid", exception.ErrorCode);
    }

    [Fact]
    public void Create_rejects_environment_variable_name_injection()
    {
        var exception = Assert.Throws<LiteLlmException>(() => LiteLlmProcessStartSpec.Create(
            @"C:\LocalAIGateway",
            @"C:\LocalAIGatewayData\config.yaml",
            43123,
            new Dictionary<string, string>
            {
                ["AIGW_KEY=INJECTED"] = "secret",
            }));

        Assert.Equal("aigw_litellm_environment_invalid", exception.ErrorCode);
    }

    [Fact]
    public void CreateProcessStartInfo_uses_argument_list_and_a_minimal_non_inherited_environment()
    {
        var spec = LiteLlmProcessStartSpec.Create(
            @"C:\Program Files\LocalAIGateway",
            @"C:\LocalAIGatewayData\config.yaml",
            43123,
            new Dictionary<string, string>
            {
                ["AIGW_LITELLM_MASTER_KEY"] = "internal-token",
            });

        var startInfo = spec.CreateProcessStartInfo(new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["SystemRoot"] = @"C:\Windows",
            ["TEMP"] = @"C:\Temp",
            ["PATH"] = "must-not-be-inherited",
            ["UNRELATED_SECRET"] = "must-not-be-inherited",
        });

        Assert.False(startInfo.UseShellExecute);
        Assert.True(startInfo.CreateNoWindow);
        Assert.True(startInfo.RedirectStandardOutput);
        Assert.True(startInfo.RedirectStandardError);
        Assert.Equal(spec.Arguments, startInfo.ArgumentList);
        Assert.Equal(@"C:\Windows", startInfo.Environment["SystemRoot"]);
        Assert.Equal(@"C:\LocalAIGatewayData\runtime-state\temp", startInfo.Environment["TEMP"]);
        Assert.Equal(startInfo.Environment["TEMP"], startInfo.Environment["TMP"]);
        Assert.False(startInfo.Environment.ContainsKey("PATH"));
        Assert.False(startInfo.Environment.ContainsKey("UNRELATED_SECRET"));
        Assert.Equal("internal-token", startInfo.Environment["AIGW_LITELLM_MASTER_KEY"]);
    }
}
