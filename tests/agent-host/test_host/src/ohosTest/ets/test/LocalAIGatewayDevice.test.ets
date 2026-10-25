import { describe, expect, it } from '@ohos/hypium';
import abilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import { PrivacyClass } from '@harmony_agent/agent-contracts';
import {
  AGENT_CONNECTORS_VERSION,
  ArkTsLocalAIGatewayHttpClient,
  LocalAIGatewayModelTransport,
  LocalAIGatewayTransportProfile,
  ModelInvocation,
  ModelMessage,
  ModelTransportResult,
  ProviderCredential,
  ProviderFinishReason
} from '@harmony_agent/agent-connectors';

const EXPECTED_TEXT: string = 'HARMONY_AGENT_DEVICE_OK';

function parameter(name: string): string {
  const parameters: Record<string, string> = abilityDelegatorRegistry.getArguments().parameters;
  const directValue: string | undefined = parameters[name];
  if (directValue !== undefined) return directValue;
  const literalKey: string = '-s ' + name;
  const literalValue: string | undefined = parameters[literalKey];
  return literalValue === undefined ? '' : literalValue;
}

function gatewayPort(): number {
  const text: string = parameter('gatewayPort');
  if (!/^\d+$/.test(text)) return 0;
  const value: number = Number(text);
  return value >= 1 && value <= 65535 ? value : 0;
}

function profile(port: number): LocalAIGatewayTransportProfile {
  const value: LocalAIGatewayTransportProfile = new LocalAIGatewayTransportProfile();
  value.baseUrl = `http://127.0.0.1:${port}/v1`;
  value.modelVersion = 'device-acceptance-revision-12';
  value.maxInputTokens = 8192;
  value.maxOutputTokens = 128;
  value.qualityTier = 1;
  value.privacyClasses = [PrivacyClass.PUBLIC];
  value.available = true;
  value.connectTimeoutMs = 5000;
  return value;
}

function invocation(): ModelInvocation {
  const value: ModelInvocation = new ModelInvocation();
  value.context.requestId = 'device-gateway-request-1';
  value.context.taskId = 'device-gateway-task-1';
  value.context.stepId = 'device-gateway-step-1';
  value.context.operationId = 'device-gateway-operation-1';
  value.context.providerId = 'local-ai-gateway';
  value.context.region = 'local-windows';
  value.context.priceSnapshotId = 'device-gateway-price-revision-12';
  value.context.credentialScope = 'gateway.invoke';
  value.context.timeoutMs = 60000;
  value.modelId = 'aigw/default';
  value.modelVersion = 'device-acceptance-revision-12';
  const message: ModelMessage = new ModelMessage();
  message.role = 'user';
  message.content = `Return exactly ${EXPECTED_TEXT}`;
  value.messages = [message];
  value.responseSchemaJson = '{}';
  value.maxOutputTokens = 128;
  value.temperature = 0;
  return value;
}

function bridgeCredential(): ProviderCredential {
  const value: ProviderCredential = new ProviderCredential();
  value.headers['Authorization'] = 'Bearer device-test';
  return value;
}

export default function localAIGatewayDeviceTest(): void {
  describe('LocalAIGatewayDevice', () => {
    it('loadsConnectorHar', 0, () => {
      expect(AGENT_CONNECTORS_VERSION).assertEqual('0.11.0');
    });

    it('callsOfficialProviderThroughLoopbackBridge', 0, async () => {
      const port: number = gatewayPort();
      expect(port > 0).assertTrue();
      const transport: LocalAIGatewayModelTransport = new LocalAIGatewayModelTransport(
        profile(port), new ArkTsLocalAIGatewayHttpClient());
      const result: ModelTransportResult = await transport.start(invocation(), bridgeCredential()).result;
      expect(result.outputText.trim() === EXPECTED_TEXT).assertTrue();
      expect(result.finishReason).assertEqual(ProviderFinishReason.STOP);
      expect(result.usage.inputTokens > 0).assertTrue();
      expect(result.usage.outputTokens > 0).assertTrue();
      expect(result.usage.totalTokens).assertEqual(result.usage.inputTokens + result.usage.outputTokens);
    });
  });
}
