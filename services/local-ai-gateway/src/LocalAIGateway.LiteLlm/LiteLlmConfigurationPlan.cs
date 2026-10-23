using System.Collections.ObjectModel;

namespace LocalAIGateway.LiteLlm;

public sealed class LiteLlmConfigurationPlan
{
    internal LiteLlmConfigurationPlan(
        byte[] configurationUtf8,
        IDictionary<string, string> environment,
        ReadOnlyMemory<byte> callbackModuleUtf8 = default,
        ReadOnlyMemory<byte> usageMetadataUtf8 = default)
    {
        ConfigurationUtf8 = configurationUtf8;
        Environment = new ReadOnlyDictionary<string, string>(environment);
        CallbackModuleUtf8 = callbackModuleUtf8;
        UsageMetadataUtf8 = usageMetadataUtf8;
    }

    public ReadOnlyMemory<byte> ConfigurationUtf8 { get; }

    public IReadOnlyDictionary<string, string> Environment { get; }

    public ReadOnlyMemory<byte> CallbackModuleUtf8 { get; }

    public ReadOnlyMemory<byte> UsageMetadataUtf8 { get; }
}
