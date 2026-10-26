using System.Reflection;

namespace LocalAIGateway.LiteLlm;

internal static class LiteLlmUsageCallbackAssets
{
    public const string ModuleName = "aigw_usage_callback";
    public const string InstanceName = "usage_logger";
    public const string ModuleFileName = ModuleName + ".py";
    public const string MetadataFileName = "aigw-usage-metadata.json";
    public const string CallbackReference = ModuleName + "." + InstanceName;

    private const string ModuleResourceName =
        "LocalAIGateway.LiteLlm.Assets.aigw_usage_callback.py";
    private static readonly Lazy<byte[]> Module = new(ReadModule);

    public static ReadOnlyMemory<byte> ModuleUtf8 => Module.Value;

    private static byte[] ReadModule()
    {
        using var stream = typeof(LiteLlmUsageCallbackAssets).Assembly
            .GetManifestResourceStream(ModuleResourceName)
            ?? throw new InvalidOperationException("The embedded LiteLLM usage callback is missing.");
        using var output = new MemoryStream();
        stream.CopyTo(output);
        return output.ToArray();
    }
}
