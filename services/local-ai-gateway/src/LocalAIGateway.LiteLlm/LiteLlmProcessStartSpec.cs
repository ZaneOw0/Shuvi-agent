using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Globalization;
using System.Text;

namespace LocalAIGateway.LiteLlm;

public sealed class LiteLlmProcessStartSpec
{
    private static readonly string[] AllowedPlatformEnvironment = ["SystemRoot"];

    private LiteLlmProcessStartSpec(
        string fileName,
        string workingDirectory,
        IReadOnlyList<string> arguments,
        IReadOnlyDictionary<string, string> environment)
    {
        FileName = fileName;
        WorkingDirectory = workingDirectory;
        Arguments = arguments;
        Environment = environment;
    }

    public string FileName { get; }

    public string WorkingDirectory { get; }

    public IReadOnlyList<string> Arguments { get; }

    public IReadOnlyDictionary<string, string> Environment { get; }

    public static LiteLlmProcessStartSpec Create(
        string applicationRoot,
        string configurationPath,
        int port,
        IReadOnlyDictionary<string, string> environment)
    {
        ValidateAbsolutePath(applicationRoot, "aigw_litellm_application_root_invalid");
        ValidateAbsolutePath(configurationPath, "aigw_litellm_configuration_path_invalid");
        var root = Path.GetFullPath(applicationRoot);
        var config = Path.GetFullPath(configurationPath);
        var configurationDirectory = Path.GetDirectoryName(config) ?? throw new LiteLlmException(
            "aigw_litellm_configuration_path_invalid",
            "A required LiteLLM path is malformed.");
        var runtimeStateRoot = Path.Combine(configurationDirectory, "runtime-state");
        var cacheRoot = Path.Combine(runtimeStateRoot, "cache");
        var homeRoot = Path.Combine(runtimeStateRoot, "home");
        if (port is < 1 or > 65535)
        {
            throw new LiteLlmException(
                "aigw_litellm_port_invalid",
                "The private LiteLLM port is invalid.");
        }

        ArgumentNullException.ThrowIfNull(environment);
        var processEnvironment = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["PYTHONNOUSERSITE"] = "1",
            ["PYTHONDONTWRITEBYTECODE"] = "1",
            ["PYTHONUTF8"] = "1",
            ["DO_NOT_TRACK"] = "true",
            ["LITELLM_LOCAL_MODEL_COST_MAP"] = "True",
            ["NO_PROXY"] = "127.0.0.1,localhost",
            ["TEMP"] = Path.Combine(runtimeStateRoot, "temp"),
            ["TMP"] = Path.Combine(runtimeStateRoot, "temp"),
            ["HOME"] = homeRoot,
            ["USERPROFILE"] = homeRoot,
            ["APPDATA"] = Path.Combine(runtimeStateRoot, "appdata"),
            ["LOCALAPPDATA"] = Path.Combine(runtimeStateRoot, "localappdata"),
            ["XDG_CACHE_HOME"] = cacheRoot,
            ["HF_HOME"] = Path.Combine(cacheRoot, "huggingface"),
            ["HUGGINGFACE_HUB_CACHE"] = Path.Combine(cacheRoot, "huggingface", "hub"),
            ["TRANSFORMERS_CACHE"] = Path.Combine(cacheRoot, "transformers"),
            ["TORCH_HOME"] = Path.Combine(cacheRoot, "torch"),
            ["PIP_CACHE_DIR"] = Path.Combine(cacheRoot, "pip"),
            ["UV_CACHE_DIR"] = Path.Combine(cacheRoot, "uv"),
            ["CUSTOM_TIKTOKEN_CACHE_DIR"] = Path.Combine(
                root,
                "runtime",
                "python",
                "Lib",
                "site-packages",
                "litellm",
                "litellm_core_utils",
                "tokenizers"),
        };
        foreach (var pair in environment)
        {
            if (!pair.Key.StartsWith("AIGW_", StringComparison.Ordinal) ||
                string.IsNullOrEmpty(pair.Value) ||
                !IsValidEnvironmentName(pair.Key) ||
                pair.Value.Any(char.IsControl) ||
                Encoding.UTF8.GetByteCount(pair.Value) > 8192)
            {
                throw new LiteLlmException(
                    "aigw_litellm_environment_invalid",
                    "The LiteLLM process environment is malformed.");
            }

            processEnvironment.Add(pair.Key, pair.Value);
        }

        if (processEnvironment.Sum(pair => pair.Key.Length + pair.Value.Length + 2) > 24 * 1024)
        {
            throw new LiteLlmException(
                "aigw_litellm_environment_invalid",
                "The LiteLLM process environment is too large.");
        }

        var arguments = Array.AsReadOnly(new[]
        {
            "-B",
            "-I",
            "-c",
            "from litellm import run_server; run_server()",
            "--config",
            config,
            "--host",
            "127.0.0.1",
            "--port",
            port.ToString(CultureInfo.InvariantCulture),
        });
        return new LiteLlmProcessStartSpec(
            Path.Combine(root, "runtime", "python", "python.exe"),
            root,
            arguments,
            new ReadOnlyDictionary<string, string>(processEnvironment));
    }

    public ProcessStartInfo CreateProcessStartInfo(
        IReadOnlyDictionary<string, string> platformEnvironment)
    {
        ArgumentNullException.ThrowIfNull(platformEnvironment);
        var startInfo = new ProcessStartInfo
        {
            FileName = FileName,
            WorkingDirectory = WorkingDirectory,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        startInfo.Environment.Clear();
        foreach (var name in AllowedPlatformEnvironment)
        {
            if (!platformEnvironment.TryGetValue(name, out var value) || string.IsNullOrEmpty(value))
            {
                continue;
            }

            if (value.Any(char.IsControl) || value.Length > 4096)
            {
                throw new LiteLlmException(
                    "aigw_litellm_environment_invalid",
                    "The required Windows process environment is malformed.");
            }

            startInfo.Environment[name] = value;
        }

        foreach (var pair in Environment)
        {
            startInfo.Environment[pair.Key] = pair.Value;
        }

        foreach (var argument in Arguments)
        {
            startInfo.ArgumentList.Add(argument);
        }

        return startInfo;
    }

    private static void ValidateAbsolutePath(string path, string errorCode)
    {
        if (string.IsNullOrWhiteSpace(path) ||
            !Path.IsPathFullyQualified(path) ||
            path.Any(char.IsControl))
        {
            throw new LiteLlmException(errorCode, "A required LiteLLM path is malformed.");
        }
    }

    private static bool IsValidEnvironmentName(string name) =>
        name.Length <= 128 &&
        name.All(character =>
            character is >= 'A' and <= 'Z' or >= '0' and <= '9' or '_');
}
