import { describe, expect, it } from '@ohos/hypium';
import {
  AgentErrorClass,
  DataBoundary,
  IdempotencyMode,
  PrivacyClass,
  RiskLevel,
  SideEffect,
  ToolDescriptor,
  ToolInvocation,
  ToolOutcomeStatus
} from '@harmony_agent/agent-contracts';
import {
  ConnectorClockPort,
  ConnectorDigestPort,
  EmbeddingInvocation,
  EmbeddingProviderResult,
  EmbeddingTransportPort,
  EmbeddingTransportResult,
  GenericEmbeddingProvider,
  GenericModelProvider,
  GenericRemoteApiProvider,
  ModelInvocation,
  ModelMessage,
  ModelProviderProfile,
  ModelProviderResult,
  ModelStreamChunk,
  ModelStreamObserver,
  ModelTransportChunk,
  ModelTransportObserver,
  ModelTransportPort,
  ModelTransportResult,
  ProviderCancellationSource,
  ProviderCapabilityKind,
  ProviderCredential,
  ProviderCredentialPort,
  ProviderErrorCode,
  ProviderFinishReason,
  ProviderGrantVerifierPort,
  ProviderOperationHandle,
  ProviderOperationRunner,
  ProviderPriceSnapshot,
  ProviderRequestContext,
  ProviderTimerHandlePort,
  ProviderTimerPort,
  ProviderTransportError,
  ProviderUsage,
  RegisteredModelProvider,
  RegisteredRemoteApiProvider,
  RemoteApiProviderResult,
  RemoteApiProfile,
  RemoteApiTransportPort,
  RemoteApiTransportResult,
  ProviderCatalog,
  canonicalJson
} from '../../Index';

class FixtureDigest implements ConnectorDigestPort {
  digest(value: string): string {
    return 'digest:' + value;
  }
}

class FixtureClock implements ConnectorClockPort {
  private tick: number = 0;

  nowIso(): string {
    this.tick++;
    return this.tick === 1 ? '2026-10-02T14:00:00.000Z' : '2026-10-02T14:00:00.001Z';
  }
}

class FixtureCredentials implements ProviderCredentialPort {
  calls: number = 0;
  fail: boolean = false;
  providerId: string = '';
  scope: string = '';
  readonly secret: string = 'fixture-secret-must-not-leak';

  async resolve(providerId: string, scope: string): Promise<ProviderCredential> {
    this.calls++;
    this.providerId = providerId;
    this.scope = scope;
    if (this.fail) throw new Error('credential store unavailable');
    const credential: ProviderCredential = new ProviderCredential();
    credential.headers['Authorization'] = 'Bearer ' + this.secret;
    return credential;
  }
}

class FixtureTimerHandle implements ProviderTimerHandlePort {
  readonly action: () => void;
  cancelled: boolean = false;

  constructor(action: () => void) {
    this.action = action;
  }

  cancel(): void {
    this.cancelled = true;
  }

  fire(): void {
    if (!this.cancelled) this.action();
  }
}

class FixtureTimer implements ProviderTimerPort {
  scheduledDelay: number = 0;
  handle?: FixtureTimerHandle;

  schedule(delayMs: number, action: () => void): ProviderTimerHandlePort {
    this.scheduledDelay = delayMs;
    this.handle = new FixtureTimerHandle(action);
    return this.handle;
  }

  fire(): void {
    const current: FixtureTimerHandle | undefined = this.handle;
    if (current !== undefined) current.fire();
  }
}

class FixtureDeferred<T> {
  readonly promise: Promise<T>;
  private resolveValue?: (value: T) => void;
  private rejectValue?: (reason: Object) => void;

  constructor() {
    this.promise = new Promise<T>((resolve: (value: T) => void, reject: (reason: Object) => void): void => {
      this.resolveValue = resolve;
      this.rejectValue = reject;
    });
  }

  complete(value: T): void {
    const action: ((value: T) => void) | undefined = this.resolveValue;
    if (action !== undefined) action(value);
  }

  fail(error: Object): void {
    const action: ((reason: Object) => void) | undefined = this.rejectValue;
    if (action !== undefined) action(error);
  }
}

class FixtureOperation<T> implements ProviderOperationHandle<T> {
  readonly result: Promise<T>;
  cancelCount: number = 0;

  constructor(result: Promise<T>) {
    this.result = result;
  }

  cancel(): void {
    this.cancelCount++;
  }
}

function usage(input: number, output: number): ProviderUsage {
  const result: ProviderUsage = new ProviderUsage();
  result.inputTokens = input;
  result.outputTokens = output;
  result.totalTokens = input + output;
  result.providerReportedCostMicros = 99;
  return result;
}

function price(capabilityId: string, version: string): ProviderPriceSnapshot {
  const result: ProviderPriceSnapshot = new ProviderPriceSnapshot();
  result.snapshotId = 'price-2026-10-02';
  result.providerId = 'provider-fixture';
  result.capabilityId = capabilityId;
  result.capabilityVersion = version;
  result.region = 'cn-east';
  result.currency = 'USD';
  result.inputMicrosPerMillionTokens = 1000000;
  result.outputMicrosPerMillionTokens = 2000000;
  result.fixedCostMicros = 3;
  result.effectiveAt = '2026-10-02T00:00:00.000Z';
  result.snapshotDigest = 'price-digest-v1';
  return result;
}

function modelProfile(kind: ProviderCapabilityKind = ProviderCapabilityKind.MODEL): ModelProviderProfile {
  const result: ModelProviderProfile = new ModelProviderProfile();
  result.registryModelId = kind === ProviderCapabilityKind.MODEL ? 'model.general' : 'embedding.general';
  result.providerId = 'provider-fixture';
  result.providerModelId = kind === ProviderCapabilityKind.MODEL ? 'vendor-model-42' : 'vendor-embedding-7';
  result.modelVersion = '2026-10-01';
  result.region = 'cn-east';
  result.capabilityKind = kind;
  result.capabilityTags = kind === ProviderCapabilityKind.MODEL ? ['chat', 'json'] : ['embedding'];
  result.privacyClasses = [PrivacyClass.PUBLIC, PrivacyClass.PERSONAL];
  result.maxInputTokens = 8192;
  result.maxOutputTokens = 1024;
  result.qualityTier = 2;
  result.credentialScope = kind === ProviderCapabilityKind.MODEL ? 'model.invoke' : 'embedding.invoke';
  result.available = true;
  return result;
}

function registeredModel(kind: ProviderCapabilityKind = ProviderCapabilityKind.MODEL): RegisteredModelProvider {
  const catalog: ProviderCatalog = new ProviderCatalog(new FixtureDigest());
  const profile: ModelProviderProfile = modelProfile(kind);
  expect(catalog.registerModel(profile, price(profile.providerModelId, profile.modelVersion))).assertTrue();
  return catalog.getModel(profile.registryModelId) as RegisteredModelProvider;
}

function context(modelId: string): ProviderRequestContext {
  const result: ProviderRequestContext = new ProviderRequestContext();
  result.requestId = 'request-1';
  result.taskId = 'task-1';
  result.stepId = 'step-1';
  result.operationId = 'operation-1';
  result.providerId = 'provider-fixture';
  result.region = 'cn-east';
  result.priceSnapshotId = 'price-2026-10-02';
  result.credentialScope = 'caller-controlled-scope';
  result.timeoutMs = 5000;
  return result;
}

function modelInvocation(): ModelInvocation {
  const result: ModelInvocation = new ModelInvocation();
  result.context = context('model.general');
  result.modelId = 'model.general';
  result.modelVersion = '2026-10-01';
  const message: ModelMessage = new ModelMessage();
  message.role = 'user';
  message.content = 'Return a compact status object';
  result.messages = [message];
  result.responseSchemaJson = '{"type":"object"}';
  result.maxOutputTokens = 100;
  result.temperature = 0;
  return result;
}

class FixtureStreamObserver implements ModelStreamObserver {
  readonly chunks: ModelStreamChunk[] = [];
  fail: boolean = false;

  onChunk(chunk: ModelStreamChunk): void {
    this.chunks.push(chunk);
    if (this.fail) throw new Error('consumer callback failed');
  }
}

class FixtureModelTransport implements ModelTransportPort {
  calls: number = 0;
  lastRequest?: ModelInvocation;
  credentialValue: string = '';
  lastOperation?: FixtureOperation<ModelTransportResult>;
  readonly started: FixtureDeferred<number> = new FixtureDeferred<number>();
  readonly pending: FixtureDeferred<ModelTransportResult> = new FixtureDeferred<ModelTransportResult>();
  hold: boolean = false;
  responseVersion: string = '2026-10-01';
  responseRegion: string = 'cn-east';
  outputJson: string = '{"ok":true}';

  start(request: ModelInvocation, credential: ProviderCredential,
    observer?: ModelTransportObserver): ProviderOperationHandle<ModelTransportResult> {
    this.calls++;
    this.lastRequest = request;
    this.credentialValue = credential.headers['Authorization'];
    const target: ModelTransportObserver | undefined = observer;
    if (target !== undefined) {
      const first: ModelTransportChunk = new ModelTransportChunk();
      first.delta = '{"ok"';
      target.onChunk(first);
      const second: ModelTransportChunk = new ModelTransportChunk();
      second.delta = ':true}';
      target.onChunk(second);
    }
    const value: ModelTransportResult = new ModelTransportResult();
    value.outputText = '{"ok":true}';
    value.outputJson = this.outputJson;
    value.finishReason = ProviderFinishReason.STOP;
    value.modelVersion = this.responseVersion;
    value.region = this.responseRegion;
    value.usage = usage(2, 3);
    const resultPromise: Promise<ModelTransportResult> = this.hold ? this.pending.promise : Promise.resolve(value);
    const operation: FixtureOperation<ModelTransportResult> = new FixtureOperation<ModelTransportResult>(resultPromise);
    this.lastOperation = operation;
    this.started.complete(this.calls);
    return operation;
  }
}

class FixtureEmbeddingTransport implements EmbeddingTransportPort {
  calls: number = 0;
  lastRequest?: EmbeddingInvocation;
  vectorCount: number = 2;
  vectors?: number[][];

  start(request: EmbeddingInvocation,
    _credential: ProviderCredential): ProviderOperationHandle<EmbeddingTransportResult> {
    this.calls++;
    this.lastRequest = request;
    const result: EmbeddingTransportResult = new EmbeddingTransportResult();
    result.vectors = this.vectors === undefined ? [[0.1, 0.2], [0.3, 0.4]].slice(0, this.vectorCount) : this.vectors;
    result.modelVersion = '2026-10-01';
    result.region = 'cn-east';
    result.usage = usage(4, 0);
    return new FixtureOperation<EmbeddingTransportResult>(Promise.resolve(result));
  }
}

function remoteProfile(sideEffect: SideEffect = SideEffect.NONE): RemoteApiProfile {
  const result: RemoteApiProfile = new RemoteApiProfile();
  result.providerId = 'provider-fixture';
  result.capabilityName = 'weather.current';
  result.capabilityVersion = '1.0.0';
  result.regions = ['cn-east'];
  result.inputSchemaJson = '{"type":"object","required":["city"]}';
  result.outputSchemaJson = '{"type":"object"}';
  result.capabilityTags = ['weather', 'remote'];
  result.permissionRequirements = ['network.weather'];
  result.riskLevel = sideEffect === SideEffect.NONE ? RiskLevel.LOW : RiskLevel.MEDIUM;
  result.sideEffect = sideEffect;
  result.dataBoundary = DataBoundary.REMOTE_ALLOWED;
  result.idempotencyMode = sideEffect === SideEffect.NONE ? IdempotencyMode.NONE : IdempotencyMode.PROVIDER_KEY;
  result.latencyClass = 'network';
  result.costClass = 'provider';
  result.displayName = 'Current weather';
  result.description = 'Fetches a current weather sample';
  result.credentialScope = 'weather.read';
  result.available = true;
  return result;
}

function registeredRemote(sideEffect: SideEffect = SideEffect.NONE): RegisteredRemoteApiProvider {
  const catalog: ProviderCatalog = new ProviderCatalog(new FixtureDigest());
  const profile: RemoteApiProfile = remoteProfile(sideEffect);
  expect(catalog.registerRemoteApi(profile,
    price(profile.capabilityName, profile.capabilityVersion))).assertTrue();
  const toolId: string = 'remote://provider-fixture/api/weather.current@cn-east';
  return catalog.getRemoteApi(toolId) as RegisteredRemoteApiProvider;
}

class FixtureGrantVerifier implements ProviderGrantVerifierPort {
  allowed: boolean = true;
  calls: number = 0;

  verify(_invocation: ToolInvocation, _descriptor: ToolDescriptor): boolean {
    this.calls++;
    return this.allowed;
  }
}

class FixtureRemoteTransport implements RemoteApiTransportPort {
  calls: number = 0;
  region: string = '';
  credentialValue: string = '';
  hold: boolean = false;
  failure?: ProviderTransportError;
  readonly started: FixtureDeferred<number> = new FixtureDeferred<number>();
  readonly pending: FixtureDeferred<RemoteApiTransportResult> = new FixtureDeferred<RemoteApiTransportResult>();
  lastOperation?: FixtureOperation<RemoteApiTransportResult>;

  start(_invocation: ToolInvocation, _argumentsValue: Object, region: string,
    credential: ProviderCredential): ProviderOperationHandle<RemoteApiTransportResult> {
    this.calls++;
    this.region = region;
    this.credentialValue = credential.headers['Authorization'];
    let resultPromise: Promise<RemoteApiTransportResult>;
    const failure: ProviderTransportError | undefined = this.failure;
    if (failure !== undefined) {
      resultPromise = Promise.reject(failure);
    } else if (this.hold) {
      resultPromise = this.pending.promise;
    } else {
      const result: RemoteApiTransportResult = new RemoteApiTransportResult();
      result.resultJson = '{"temperature":22,"city":"Hangzhou"}';
      result.providerReceipt = 'receipt-1';
      result.region = region;
      result.providerReportedCostMicros = 8;
      resultPromise = Promise.resolve(result);
    }
    const operation: FixtureOperation<RemoteApiTransportResult> =
      new FixtureOperation<RemoteApiTransportResult>(resultPromise);
    this.lastOperation = operation;
    this.started.complete(this.calls);
    return operation;
  }
}

function remoteInvocation(registered: RegisteredRemoteApiProvider, digest: ConnectorDigestPort): ToolInvocation {
  const descriptor: ToolDescriptor = registered.registryEntry().descriptor;
  const result: ToolInvocation = new ToolInvocation();
  result.invocationId = 'remote-invocation-1';
  result.taskId = 'task-1';
  result.stepId = 'step-1';
  result.operationId = 'operation-1';
  result.attemptId = 'attempt-1';
  result.toolId = descriptor.toolId;
  result.toolIdentityVersion = descriptor.toolIdentityVersion;
  result.schemaDigest = descriptor.schemaDigest;
  result.argumentsJson = '{"city":"Hangzhou"}';
  result.argumentsDigest = digest.digest(canonicalJson(JSON.parse(result.argumentsJson) as Object));
  result.idempotencyKey = 'remote-idempotency-1';
  result.authorizationGrantId = 'grant-1';
  result.timeoutMs = 5000;
  result.createdAt = '2026-10-02T13:59:59.000Z';
  return result;
}

function runner(credentials: FixtureCredentials, timer: FixtureTimer): ProviderOperationRunner {
  return new ProviderOperationRunner(credentials, timer);
}

export default function providerConnectorsTest(): void {
  describe('ProviderConnectors', () => {
    it('registersModelWithVersionRegionPriceAndIsolatedSnapshot', 0, () => {
      const catalog: ProviderCatalog = new ProviderCatalog(new FixtureDigest());
      const profile: ModelProviderProfile = modelProfile();
      const snapshot: ProviderPriceSnapshot = price(profile.providerModelId, profile.modelVersion);
      expect(catalog.registerModel(profile, snapshot)).assertTrue();
      profile.capabilityTags[0] = 'mutated';
      snapshot.fixedCostMicros = 999;

      const registered: RegisteredModelProvider = catalog.getModel('model.general') as RegisteredModelProvider;
      const entry = registered.registryEntry(4, 5);
      expect(entry.modelVersion).assertEqual('2026-10-01');
      expect(entry.regions[0]).assertEqual('cn-east');
      expect(entry.capabilityTags[0]).assertEqual('chat');
      expect(entry.estimatedCostMicros).assertEqual(17);

      const changedCatalog: ProviderCatalog = new ProviderCatalog(new FixtureDigest());
      const changedPrice: ProviderPriceSnapshot = price('vendor-model-42', '2026-10-01');
      changedPrice.fixedCostMicros = 4;
      expect(changedCatalog.registerModel(modelProfile(), changedPrice)).assertTrue();
      const changed: RegisteredModelProvider = changedCatalog.getModel('model.general') as RegisteredModelProvider;
      expect(changed.registryDigest === registered.registryDigest).assertFalse();
    });

    it('normalizesModelRequestStreamUsageAndKeepsCredentialAtTransportBoundary', 0, async () => {
      const credentials: FixtureCredentials = new FixtureCredentials();
      const timer: FixtureTimer = new FixtureTimer();
      const transport: FixtureModelTransport = new FixtureModelTransport();
      const provider: GenericModelProvider = new GenericModelProvider(registeredModel(), transport,
        runner(credentials, timer));
      const observer: FixtureStreamObserver = new FixtureStreamObserver();
      observer.fail = true;

      const result: ModelProviderResult = await provider.generate(modelInvocation(),
        new ProviderCancellationSource(), observer);

      expect(transport.lastRequest?.modelId).assertEqual('vendor-model-42');
      expect(transport.lastRequest?.context.credentialScope).assertEqual('model.invoke');
      expect(credentials.scope).assertEqual('model.invoke');
      expect(transport.credentialValue).assertEqual('Bearer ' + credentials.secret);
      expect(observer.chunks.length).assertEqual(2);
      expect(observer.chunks[0].sequence).assertEqual(1);
      expect(observer.chunks[0].modelId).assertEqual('model.general');
      expect(observer.chunks[0].priceSnapshotId).assertEqual('price-2026-10-02');
      expect(result.modelId).assertEqual('model.general');
      expect(result.usage.settledCostMicros).assertEqual(11);
      expect(JSON.stringify(result).includes(credentials.secret)).assertFalse();
      expect(timer.handle?.cancelled).assertTrue();
    });

    it('rejectsStaleModelInvocationBeforeCredentialOrTransport', 0, async () => {
      const credentials: FixtureCredentials = new FixtureCredentials();
      const transport: FixtureModelTransport = new FixtureModelTransport();
      const provider: GenericModelProvider = new GenericModelProvider(registeredModel(), transport,
        runner(credentials, new FixtureTimer()));
      const request: ModelInvocation = modelInvocation();
      request.context.priceSnapshotId = 'stale-price';
      let code: ProviderErrorCode = ProviderErrorCode.PROVIDER;
      try {
        await provider.generate(request, new ProviderCancellationSource());
      } catch (error) {
        if (error instanceof ProviderTransportError) code = error.code;
      }
      expect(code).assertEqual(ProviderErrorCode.INVALID_REQUEST);
      expect(credentials.calls).assertEqual(0);
      expect(transport.calls).assertEqual(0);

      const invalidSchema: ModelInvocation = modelInvocation();
      invalidSchema.responseSchemaJson = '[]';
      try {
        await provider.generate(invalidSchema, new ProviderCancellationSource());
      } catch (error) {
        if (error instanceof ProviderTransportError) code = error.code;
      }
      expect(code).assertEqual(ProviderErrorCode.INVALID_REQUEST);
      expect(credentials.calls).assertEqual(0);
      expect(transport.calls).assertEqual(0);
    });

    it('rejectsModelResponseThatDoesNotMatchRegisteredVersion', 0, async () => {
      const transport: FixtureModelTransport = new FixtureModelTransport();
      transport.responseVersion = 'unexpected-version';
      const provider: GenericModelProvider = new GenericModelProvider(registeredModel(), transport,
        runner(new FixtureCredentials(), new FixtureTimer()));
      let code: ProviderErrorCode = ProviderErrorCode.INVALID_REQUEST;
      try {
        await provider.generate(modelInvocation(), new ProviderCancellationSource());
      } catch (error) {
        if (error instanceof ProviderTransportError) code = error.code;
      }
      expect(code).assertEqual(ProviderErrorCode.PROVIDER);

      const invalidJsonTransport: FixtureModelTransport = new FixtureModelTransport();
      invalidJsonTransport.outputJson = '{';
      const invalidJsonProvider: GenericModelProvider = new GenericModelProvider(registeredModel(),
        invalidJsonTransport, runner(new FixtureCredentials(), new FixtureTimer()));
      try {
        await invalidJsonProvider.generate(modelInvocation(), new ProviderCancellationSource());
      } catch (error) {
        if (error instanceof ProviderTransportError) code = error.code;
      }
      expect(code).assertEqual(ProviderErrorCode.PROVIDER);
    });

    it('doesNotResolveCredentialWhenAlreadyCancelled', 0, async () => {
      const credentials: FixtureCredentials = new FixtureCredentials();
      const transport: FixtureModelTransport = new FixtureModelTransport();
      const provider: GenericModelProvider = new GenericModelProvider(registeredModel(), transport,
        runner(credentials, new FixtureTimer()));
      const cancellation: ProviderCancellationSource = new ProviderCancellationSource();
      cancellation.cancel();
      let code: ProviderErrorCode = ProviderErrorCode.PROVIDER;
      try {
        await provider.generate(modelInvocation(), cancellation);
      } catch (error) {
        if (error instanceof ProviderTransportError) code = error.code;
      }
      expect(code).assertEqual(ProviderErrorCode.CANCELLED);
      expect(credentials.calls).assertEqual(0);
      expect(transport.calls).assertEqual(0);
    });

    it('cancelsActiveModelTransportExactlyOnce', 0, async () => {
      const transport: FixtureModelTransport = new FixtureModelTransport();
      transport.hold = true;
      const provider: GenericModelProvider = new GenericModelProvider(registeredModel(), transport,
        runner(new FixtureCredentials(), new FixtureTimer()));
      const cancellation: ProviderCancellationSource = new ProviderCancellationSource();
      const pending: Promise<ModelProviderResult> = provider.generate(modelInvocation(), cancellation);
      await transport.started.promise;
      cancellation.cancel();
      cancellation.cancel();
      let code: ProviderErrorCode = ProviderErrorCode.PROVIDER;
      try {
        await pending;
      } catch (error) {
        if (error instanceof ProviderTransportError) code = error.code;
      }
      expect(code).assertEqual(ProviderErrorCode.CANCELLED);
      expect(transport.lastOperation?.cancelCount).assertEqual(1);
    });

    it('timesOutAndCancelsActiveModelTransportExactlyOnce', 0, async () => {
      const timer: FixtureTimer = new FixtureTimer();
      const transport: FixtureModelTransport = new FixtureModelTransport();
      transport.hold = true;
      const provider: GenericModelProvider = new GenericModelProvider(registeredModel(), transport,
        runner(new FixtureCredentials(), timer));
      const pending: Promise<ModelProviderResult> = provider.generate(modelInvocation(),
        new ProviderCancellationSource());
      await transport.started.promise;
      timer.fire();
      let code: ProviderErrorCode = ProviderErrorCode.PROVIDER;
      try {
        await pending;
      } catch (error) {
        if (error instanceof ProviderTransportError) code = error.code;
      }
      expect(code).assertEqual(ProviderErrorCode.TIMEOUT);
      expect(transport.lastOperation?.cancelCount).assertEqual(1);
      expect(timer.scheduledDelay).assertEqual(5000);
    });

    it('failsClosedWhenCredentialResolutionFails', 0, async () => {
      const credentials: FixtureCredentials = new FixtureCredentials();
      credentials.fail = true;
      const transport: FixtureModelTransport = new FixtureModelTransport();
      const provider: GenericModelProvider = new GenericModelProvider(registeredModel(), transport,
        runner(credentials, new FixtureTimer()));
      let code: ProviderErrorCode = ProviderErrorCode.PROVIDER;
      try {
        await provider.generate(modelInvocation(), new ProviderCancellationSource());
      } catch (error) {
        if (error instanceof ProviderTransportError) code = error.code;
      }
      expect(code).assertEqual(ProviderErrorCode.AUTHENTICATION);
      expect(transport.calls).assertEqual(0);
    });

    it('normalizesEmbeddingTraceUsageAndCopiesVectors', 0, async () => {
      const credentials: FixtureCredentials = new FixtureCredentials();
      const transport: FixtureEmbeddingTransport = new FixtureEmbeddingTransport();
      const sourceVectors: number[][] = [[0.1, 0.2], [0.3, 0.4]];
      transport.vectors = sourceVectors;
      const provider: GenericEmbeddingProvider = new GenericEmbeddingProvider(
        registeredModel(ProviderCapabilityKind.EMBEDDING), transport, runner(credentials, new FixtureTimer()));
      const request: EmbeddingInvocation = new EmbeddingInvocation();
      request.context = context('embedding.general');
      request.modelId = 'embedding.general';
      request.modelVersion = '2026-10-01';
      request.inputs = ['alpha', 'beta'];

      const result: EmbeddingProviderResult = await provider.embed(request, new ProviderCancellationSource());
      sourceVectors[0][0] = 9;

      expect(transport.lastRequest?.modelId).assertEqual('vendor-embedding-7');
      expect(credentials.scope).assertEqual('embedding.invoke');
      expect(result.vectors[0][0]).assertEqual(0.1);
      expect(result.priceSnapshotId).assertEqual('price-2026-10-02');
      expect(result.usage.settledCostMicros).assertEqual(7);
    });

    it('rejectsEmbeddingVectorCountMismatch', 0, async () => {
      const transport: FixtureEmbeddingTransport = new FixtureEmbeddingTransport();
      transport.vectorCount = 1;
      const provider: GenericEmbeddingProvider = new GenericEmbeddingProvider(
        registeredModel(ProviderCapabilityKind.EMBEDDING), transport,
        runner(new FixtureCredentials(), new FixtureTimer()));
      const request: EmbeddingInvocation = new EmbeddingInvocation();
      request.context = context('embedding.general');
      request.modelId = 'embedding.general';
      request.modelVersion = '2026-10-01';
      request.inputs = ['alpha', 'beta'];
      let code: ProviderErrorCode = ProviderErrorCode.INVALID_REQUEST;
      try {
        await provider.embed(request, new ProviderCancellationSource());
      } catch (error) {
        if (error instanceof ProviderTransportError) code = error.code;
      }
      expect(code).assertEqual(ProviderErrorCode.PROVIDER);
    });

    it('rejectsMalformedRemoteSchemaAndWriteWithoutIdempotency', 0, () => {
      const catalog: ProviderCatalog = new ProviderCatalog(new FixtureDigest());
      const malformed: RemoteApiProfile = remoteProfile();
      malformed.inputSchemaJson = '{';
      expect(catalog.registerRemoteApi(malformed,
        price(malformed.capabilityName, malformed.capabilityVersion))).assertFalse();
      const nonObject: RemoteApiProfile = remoteProfile();
      nonObject.inputSchemaJson = '[]';
      expect(catalog.registerRemoteApi(nonObject,
        price(nonObject.capabilityName, nonObject.capabilityVersion))).assertFalse();
      const unsafeWrite: RemoteApiProfile = remoteProfile(SideEffect.REVERSIBLE);
      unsafeWrite.idempotencyMode = IdempotencyMode.NONE;
      expect(catalog.registerRemoteApi(unsafeWrite,
        price(unsafeWrite.capabilityName, unsafeWrite.capabilityVersion))).assertFalse();
    });

    it('invokesRemoteReadAfterIdentityDigestAndGrantChecks', 0, async () => {
      const digest: FixtureDigest = new FixtureDigest();
      const registered: RegisteredRemoteApiProvider = registeredRemote();
      const credentials: FixtureCredentials = new FixtureCredentials();
      const transport: FixtureRemoteTransport = new FixtureRemoteTransport();
      const grants: FixtureGrantVerifier = new FixtureGrantVerifier();
      const provider: GenericRemoteApiProvider = new GenericRemoteApiProvider(registered, transport,
        runner(credentials, new FixtureTimer()), digest, new FixtureClock(), grants);

      const result: RemoteApiProviderResult = await provider.invoke(remoteInvocation(registered, digest),
        new ProviderCancellationSource());
      const outcome = result.outcome;

      expect(outcome.status).assertEqual(ToolOutcomeStatus.SUCCEEDED);
      expect(outcome.resultJson).assertEqual('{"city":"Hangzhou","temperature":22}');
      expect(outcome.providerReceipt).assertEqual('receipt-1');
      expect(transport.region).assertEqual('cn-east');
      expect(credentials.scope).assertEqual('weather.read');
      expect(grants.calls).assertEqual(1);
      expect(result.capabilityVersion).assertEqual('1.0.0');
      expect(result.region).assertEqual('cn-east');
      expect(result.priceSnapshotId).assertEqual('price-2026-10-02');
      expect(result.usage.providerReportedCostMicros).assertEqual(8);
      expect(result.usage.settledCostMicros).assertEqual(3);
      expect(JSON.stringify(result).includes(credentials.secret)).assertFalse();
    });

    it('deniesChangedRemoteArgumentsBeforeGrantCredentialAndTransport', 0, async () => {
      const digest: FixtureDigest = new FixtureDigest();
      const registered: RegisteredRemoteApiProvider = registeredRemote();
      const credentials: FixtureCredentials = new FixtureCredentials();
      const transport: FixtureRemoteTransport = new FixtureRemoteTransport();
      const grants: FixtureGrantVerifier = new FixtureGrantVerifier();
      const provider: GenericRemoteApiProvider = new GenericRemoteApiProvider(registered, transport,
        runner(credentials, new FixtureTimer()), digest, new FixtureClock(), grants);
      const invocation: ToolInvocation = remoteInvocation(registered, digest);
      invocation.argumentsJson = '{"city":"Shanghai"}';

      const outcome = (await provider.invoke(invocation, new ProviderCancellationSource())).outcome;

      expect(outcome.status).assertEqual(ToolOutcomeStatus.DENIED);
      expect(outcome.errorCode).assertEqual('REMOTE_API_ARGUMENTS_DIGEST_MISMATCH');
      expect(grants.calls).assertEqual(0);
      expect(credentials.calls).assertEqual(0);
      expect(transport.calls).assertEqual(0);
    });

    it('marksTimedOutRemoteWriteUnknownAndCancelsTransport', 0, async () => {
      const digest: FixtureDigest = new FixtureDigest();
      const registered: RegisteredRemoteApiProvider = registeredRemote(SideEffect.REVERSIBLE);
      const transport: FixtureRemoteTransport = new FixtureRemoteTransport();
      transport.hold = true;
      const timer: FixtureTimer = new FixtureTimer();
      const provider: GenericRemoteApiProvider = new GenericRemoteApiProvider(registered, transport,
        runner(new FixtureCredentials(), timer), digest, new FixtureClock(), new FixtureGrantVerifier());
      const pending = provider.invoke(remoteInvocation(registered, digest), new ProviderCancellationSource());
      await transport.started.promise;
      timer.fire();
      const result: RemoteApiProviderResult = await pending;
      const outcome = result.outcome;

      expect(outcome.status).assertEqual(ToolOutcomeStatus.UNKNOWN_OUTCOME);
      expect(outcome.errorCode).assertEqual(ProviderErrorCode.TIMEOUT);
      expect(transport.calls).assertEqual(1);
      expect(transport.lastOperation?.cancelCount).assertEqual(1);
      expect(result.priceSnapshotId).assertEqual('price-2026-10-02');
    });

    it('marksStartedRemoteWriteNetworkFailureUnknownWithoutRetry', 0, async () => {
      const digest: FixtureDigest = new FixtureDigest();
      const registered: RegisteredRemoteApiProvider = registeredRemote(SideEffect.IRREVERSIBLE);
      const transport: FixtureRemoteTransport = new FixtureRemoteTransport();
      transport.failure = new ProviderTransportError(ProviderErrorCode.NETWORK, AgentErrorClass.NETWORK,
        'connection dropped after request bytes were sent', true);
      const provider: GenericRemoteApiProvider = new GenericRemoteApiProvider(registered, transport,
        runner(new FixtureCredentials(), new FixtureTimer()), digest, new FixtureClock(),
        new FixtureGrantVerifier());

      const outcome = (await provider.invoke(remoteInvocation(registered, digest),
        new ProviderCancellationSource())).outcome;

      expect(outcome.status).assertEqual(ToolOutcomeStatus.UNKNOWN_OUTCOME);
      expect(outcome.errorCode).assertEqual(ProviderErrorCode.NETWORK);
      expect(transport.calls).assertEqual(1);
    });
  });
}
