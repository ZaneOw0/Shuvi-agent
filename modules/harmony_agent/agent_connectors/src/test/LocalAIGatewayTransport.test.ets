import { describe, expect, it } from '@ohos/hypium';
import { PrivacyClass } from '@harmony_agent/agent-contracts';
import {
  createLocalAIGatewayModelProfile,
  LocalAIGatewayHttpClientPort,
  LocalAIGatewayHttpRequest,
  LocalAIGatewayHttpResponse,
  LocalAIGatewayModelTransport,
  LocalAIGatewayTransportProfile,
  LocalAIGatewayTransportProfileValidator,
  ModelInvocation,
  ModelMessage,
  ModelTransportChunk,
  ModelTransportObserver,
  ModelTransportResult,
  ProviderCredential,
  ProviderErrorCode,
  ProviderOperationHandle,
  ProviderTransportError
} from '../../Index';

class GatewayFixtureOperation<T> implements ProviderOperationHandle<T> {
  readonly result: Promise<T>;
  cancelCount: number = 0;

  constructor(result: Promise<T>) {
    this.result = result;
  }

  cancel(): void {
    this.cancelCount++;
  }
}

class GatewayFixtureHttpClient implements LocalAIGatewayHttpClientPort {
  calls: number = 0;
  lastRequest?: LocalAIGatewayHttpRequest;
  statusCode: number = 200;
  body: string = '{"choices":[{"message":{"content":"{\\"ok\\":true}"},"finish_reason":"stop"}],"usage":{"prompt_tokens":2,"completion_tokens":3,"total_tokens":5}}';
  lastOperation?: GatewayFixtureOperation<LocalAIGatewayHttpResponse>;

  start(request: LocalAIGatewayHttpRequest): ProviderOperationHandle<LocalAIGatewayHttpResponse> {
    this.calls++;
    this.lastRequest = request;
    const response: LocalAIGatewayHttpResponse = new LocalAIGatewayHttpResponse();
    response.statusCode = this.statusCode;
    response.body = this.body;
    const operation: GatewayFixtureOperation<LocalAIGatewayHttpResponse> =
      new GatewayFixtureOperation<LocalAIGatewayHttpResponse>(Promise.resolve(response));
    this.lastOperation = operation;
    return operation;
  }
}

class GatewayFixtureObserver implements ModelTransportObserver {
  chunks: ModelTransportChunk[] = [];

  onChunk(chunk: ModelTransportChunk): void {
    this.chunks.push(chunk);
  }
}

function profile(): LocalAIGatewayTransportProfile {
  const value: LocalAIGatewayTransportProfile = new LocalAIGatewayTransportProfile();
  value.modelVersion = 'gateway-profile-revision-7';
  value.maxInputTokens = 8192;
  value.maxOutputTokens = 1024;
  value.qualityTier = 2;
  value.privacyClasses = [PrivacyClass.PUBLIC, PrivacyClass.PERSONAL];
  value.available = true;
  return value;
}

function request(): ModelInvocation {
  const value: ModelInvocation = new ModelInvocation();
  value.context.requestId = 'request-gateway-1';
  value.context.taskId = 'task-gateway-1';
  value.context.stepId = 'step-gateway-1';
  value.context.operationId = 'operation-gateway-1';
  value.context.providerId = 'local-ai-gateway';
  value.context.region = 'local-windows';
  value.context.priceSnapshotId = 'gateway-price-revision-7';
  value.context.credentialScope = 'gateway.invoke';
  value.context.timeoutMs = 5000;
  value.modelId = 'aigw/default';
  value.modelVersion = 'gateway-profile-revision-7';
  const message: ModelMessage = new ModelMessage();
  message.role = 'user';
  message.content = 'Return a compact status object';
  value.messages = [message];
  value.responseSchemaJson = '{"type":"object"}';
  value.maxOutputTokens = 128;
  value.temperature = 0;
  return value;
}

function bearerCredential(): ProviderCredential {
  const value: ProviderCredential = new ProviderCredential();
  value.headers['Authorization'] = 'Bearer fixture-gateway-token';
  return value;
}

async function failureCode(operation: ProviderOperationHandle<ModelTransportResult>): Promise<ProviderErrorCode> {
  try {
    await operation.result;
  } catch (error) {
    if (error instanceof ProviderTransportError) return error.code;
  }
  return ProviderErrorCode.PROVIDER;
}

export default function localAIGatewayTransportTest(): void {
  describe('LocalAIGatewayTransport', () => {
    it('validatesLoopbackProfileAndBuildsProviderMetadata', 0, () => {
      const source: LocalAIGatewayTransportProfile = profile();
      expect(LocalAIGatewayTransportProfileValidator.valid(source)).assertTrue();
      const metadata = createLocalAIGatewayModelProfile(source);
      source.publicModelAlias = 'mutated';
      source.privacyClasses[0] = PrivacyClass.RESTRICTED;
      expect(metadata.providerModelId).assertEqual('aigw/default');
      expect(metadata.registryModelId).assertEqual('model.local.gateway');
      expect(metadata.privacyClasses[0]).assertEqual(PrivacyClass.PUBLIC);

      const remote: LocalAIGatewayTransportProfile = profile();
      remote.baseUrl = 'http://192.168.1.20:4000/v1';
      expect(LocalAIGatewayTransportProfileValidator.valid(remote)).assertFalse();

      const malformedPort: LocalAIGatewayTransportProfile = profile();
      malformedPort.baseUrl = 'http://localhost:bad/v1';
      expect(LocalAIGatewayTransportProfileValidator.valid(malformedPort)).assertFalse();

      const pathInjection: LocalAIGatewayTransportProfile = profile();
      pathInjection.baseUrl = 'http://127.0.0.1:4000/extra/v1';
      expect(LocalAIGatewayTransportProfileValidator.valid(pathInjection)).assertFalse();
    });

    it('mapsChatCompletionAndNormalizesStructuredUsage', 0, async () => {
      const client: GatewayFixtureHttpClient = new GatewayFixtureHttpClient();
      const transport: LocalAIGatewayModelTransport = new LocalAIGatewayModelTransport(profile(), client);
      const observer: GatewayFixtureObserver = new GatewayFixtureObserver();
      const operation: ProviderOperationHandle<ModelTransportResult> =
        transport.start(request(), bearerCredential(), observer);
      const result: ModelTransportResult = await operation.result;
      const sent: LocalAIGatewayHttpRequest = client.lastRequest as LocalAIGatewayHttpRequest;
      const payload: Record<string, Object> = JSON.parse(sent.body) as Record<string, Object>;

      expect(sent.endpoint).assertEqual('http://127.0.0.1:4000/v1/chat/completions');
      expect(sent.headers['Authorization']).assertEqual('Bearer fixture-gateway-token');
      expect(sent.body.includes('fixture-gateway-token')).assertFalse();
      expect(payload['model']).assertEqual('aigw/default');
      expect(payload['stream']).assertFalse();
      const responseFormat: Record<string, Object> =
        payload['response_format'] as Record<string, Object>;
      expect(responseFormat['type']).assertEqual('json_object');
      expect(Object.keys(responseFormat).length).assertEqual(1);
      expect(result.outputText).assertEqual('{"ok":true}');
      expect(result.outputJson).assertEqual('{"ok":true}');
      expect(result.usage.inputTokens).assertEqual(2);
      expect(result.usage.outputTokens).assertEqual(3);
      expect(result.usage.totalTokens).assertEqual(5);
      expect(result.usage.providerReportedCostMicros).assertEqual(0);
      expect(observer.chunks.length).assertEqual(1);
      expect(observer.chunks[0].delta).assertEqual('{"ok":true}');

      const plain: ModelInvocation = request();
      plain.responseSchemaJson = ' { } ';
      await transport.start(plain, bearerCredential()).result;
      const plainRequest: LocalAIGatewayHttpRequest = client.lastRequest as LocalAIGatewayHttpRequest;
      expect(plainRequest.body.includes('response_format')).assertFalse();
    });

    it('acceptsApiKeyButRejectsConflictingOrExtraCredentialHeaders', 0, async () => {
      const client: GatewayFixtureHttpClient = new GatewayFixtureHttpClient();
      const transport: LocalAIGatewayModelTransport = new LocalAIGatewayModelTransport(profile(), client);
      const apiKey: ProviderCredential = new ProviderCredential();
      apiKey.headers['x-api-key'] = 'fixture-gateway-token';
      await transport.start(request(), apiKey).result;
      expect(client.lastRequest?.headers['x-api-key']).assertEqual('fixture-gateway-token');

      const conflict: ProviderCredential = bearerCredential();
      conflict.headers['x-api-key'] = 'second-token';
      let code: ProviderErrorCode = ProviderErrorCode.PROVIDER;
      try {
        transport.start(request(), conflict);
      } catch (error) {
        if (error instanceof ProviderTransportError) code = error.code;
      }
      expect(code).assertEqual(ProviderErrorCode.AUTHENTICATION);
      expect(client.calls).assertEqual(1);

      const extra: ProviderCredential = bearerCredential();
      extra.headers['X-Debug'] = 'not-allowed';
      try {
        transport.start(request(), extra);
      } catch (error) {
        if (error instanceof ProviderTransportError) code = error.code;
      }
      expect(code).assertEqual(ProviderErrorCode.AUTHENTICATION);
      expect(client.calls).assertEqual(1);
    });

    it('mapsGatewayStatusWithoutLeakingResponseBodies', 0, async () => {
      const client: GatewayFixtureHttpClient = new GatewayFixtureHttpClient();
      client.statusCode = 401;
      client.body = '{"error":{"message":"secret-upstream-detail"}}';
      const transport: LocalAIGatewayModelTransport = new LocalAIGatewayModelTransport(profile(), client);
      let errorMessage: string = '';
      let code: ProviderErrorCode = ProviderErrorCode.PROVIDER;
      try {
        await transport.start(request(), bearerCredential()).result;
      } catch (error) {
        if (error instanceof ProviderTransportError) {
          code = error.code;
          errorMessage = error.message;
        }
      }
      expect(code).assertEqual(ProviderErrorCode.AUTHENTICATION);
      expect(errorMessage.includes('secret-upstream-detail')).assertFalse();

      client.statusCode = 429;
      code = await failureCode(transport.start(request(), bearerCredential()));
      expect(code).assertEqual(ProviderErrorCode.RATE_LIMITED);
    });

    it('rejectsMalformedUsageAndDelegatesCancellation', 0, async () => {
      const client: GatewayFixtureHttpClient = new GatewayFixtureHttpClient();
      client.body = '{"choices":[{"message":{"content":"{\\"ok\\":true}"},"finish_reason":"stop"}],"usage":{"prompt_tokens":2,"completion_tokens":3,"total_tokens":99}}';
      const transport: LocalAIGatewayModelTransport = new LocalAIGatewayModelTransport(profile(), client);
      const operation: ProviderOperationHandle<ModelTransportResult> = transport.start(request(), bearerCredential());
      operation.cancel();
      expect(client.lastOperation?.cancelCount).assertEqual(1);
      expect(await failureCode(operation)).assertEqual(ProviderErrorCode.PROVIDER);
    });
  });
}
