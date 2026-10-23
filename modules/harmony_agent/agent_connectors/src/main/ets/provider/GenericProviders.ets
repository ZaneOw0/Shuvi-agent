import {
  AgentErrorClass,
  ContractCodec,
  ContractValidator,
  SideEffect,
  ToolDescriptor,
  ToolInvocation,
  ToolOutcome,
  ToolOutcomeStatus
} from '@harmony_agent/agent-contracts';
import { ModelRegistryEntry, ToolRegistryEntry } from '@harmony_agent/agent-runtime';
import { canonicalJson, parseJsonObject } from '../mcp/CanonicalJson';
import { ConnectorClockPort, ConnectorDigestPort } from '../mcp/McpConnectorTypes';
import {
  EmbeddingInvocation,
  EmbeddingProvider,
  EmbeddingProviderResult,
  EmbeddingTransportPort,
  EmbeddingTransportResult,
  ModelInvocation,
  ModelMessage,
  ModelProvider,
  ModelProviderResult,
  ModelStreamChunk,
  ModelStreamObserver,
  ModelTransportChunk,
  ModelTransportObserver,
  ModelTransportPort,
  ModelTransportResult,
  ProviderCancellationSignalPort,
  ProviderCapabilityKind,
  ProviderCredential,
  ProviderErrorCode,
  ProviderFinishReason,
  ProviderGrantVerifierPort,
  ProviderOperationHandle,
  ProviderPriceSnapshot,
  ProviderRequestContext,
  ProviderTransportError,
  ProviderUsage,
  RemoteApiProvider,
  RemoteApiProviderResult,
  RemoteApiProfile,
  RemoteApiTransportPort,
  RemoteApiTransportResult
} from './ProviderContracts';
import {
  ModelProviderProfile,
  RegisteredModelProvider,
  RegisteredRemoteApiProvider
} from './ProviderCatalog';
import { ProviderOperationFactory, ProviderOperationRunner } from './ProviderOperationRunner';

function validText(value: string): boolean {
  return value.trim().length > 0;
}

function validCount(value: number): boolean {
  return Number.isSafeInteger(value) && value >= 0;
}

function validUsage(value: ProviderUsage): boolean {
  return validCount(value.inputTokens) && validCount(value.outputTokens) && validCount(value.totalTokens) &&
    validCount(value.providerReportedCostMicros) && value.totalTokens === value.inputTokens + value.outputTokens;
}

function settleUsage(source: ProviderUsage, inputRate: number, outputRate: number, fixedCost: number): ProviderUsage {
  const result: ProviderUsage = new ProviderUsage();
  result.inputTokens = source.inputTokens;
  result.outputTokens = source.outputTokens;
  result.totalTokens = source.totalTokens;
  result.providerReportedCostMicros = source.providerReportedCostMicros;
  result.settledCostMicros = Math.ceil((source.inputTokens * inputRate + source.outputTokens * outputRate) /
    1000000) + fixedCost;
  return result;
}

function copyContext(source: ProviderRequestContext): ProviderRequestContext {
  const result: ProviderRequestContext = new ProviderRequestContext();
  result.requestId = source.requestId;
  result.taskId = source.taskId;
  result.stepId = source.stepId;
  result.operationId = source.operationId;
  result.providerId = source.providerId;
  result.region = source.region;
  result.priceSnapshotId = source.priceSnapshotId;
  result.credentialScope = source.credentialScope;
  result.timeoutMs = source.timeoutMs;
  return result;
}

function copyMessages(source: ModelMessage[]): ModelMessage[] {
  const result: ModelMessage[] = [];
  for (let index: number = 0; index < source.length; index++) {
    const message: ModelMessage = new ModelMessage();
    message.role = source[index].role;
    message.content = source[index].content;
    result.push(message);
  }
  return result;
}

class SafeModelObserver implements ModelTransportObserver {
  private readonly target?: ModelStreamObserver;
  private readonly request: ModelInvocation;
  private readonly profile: ModelProviderProfile;
  private readonly price: ProviderPriceSnapshot;
  private sequence: number = 0;

  constructor(target: ModelStreamObserver | undefined, request: ModelInvocation,
    profile: ModelProviderProfile, price: ProviderPriceSnapshot) {
    this.target = target;
    this.request = request;
    this.profile = profile;
    this.price = price;
  }

  onChunk(chunk: ModelTransportChunk): void {
    const target: ModelStreamObserver | undefined = this.target;
    if (target === undefined) return;
    this.sequence++;
    const normalized: ModelStreamChunk = new ModelStreamChunk();
    normalized.requestId = this.request.context.requestId;
    normalized.sequence = this.sequence;
    normalized.delta = chunk.delta;
    normalized.modelId = this.profile.registryModelId;
    normalized.modelVersion = this.profile.modelVersion;
    normalized.region = this.profile.region;
    normalized.priceSnapshotId = this.price.snapshotId;
    try {
      target.onChunk(normalized);
    } catch (error) {
      // Consumer observers cannot break provider resource cleanup.
    }
  }
}

class ModelOperationFactory implements ProviderOperationFactory<ModelTransportResult> {
  private readonly transport: ModelTransportPort;
  private readonly request: ModelInvocation;
  private readonly observer: ModelTransportObserver;

  constructor(transport: ModelTransportPort, request: ModelInvocation, observer: ModelTransportObserver) {
    this.transport = transport;
    this.request = request;
    this.observer = observer;
  }

  start(credential: ProviderCredential): ProviderOperationHandle<ModelTransportResult> {
    return this.transport.start(this.request, credential, this.observer);
  }
}

class EmbeddingOperationFactory implements ProviderOperationFactory<EmbeddingTransportResult> {
  private readonly transport: EmbeddingTransportPort;
  private readonly request: EmbeddingInvocation;

  constructor(transport: EmbeddingTransportPort, request: EmbeddingInvocation) {
    this.transport = transport;
    this.request = request;
  }

  start(credential: ProviderCredential): ProviderOperationHandle<EmbeddingTransportResult> {
    return this.transport.start(this.request, credential);
  }
}

class RemoteOperationFactory implements ProviderOperationFactory<RemoteApiTransportResult> {
  private readonly transport: RemoteApiTransportPort;
  private readonly invocation: ToolInvocation;
  private readonly argumentsValue: Object;
  private readonly region: string;

  constructor(transport: RemoteApiTransportPort, invocation: ToolInvocation, argumentsValue: Object,
    region: string) {
    this.transport = transport;
    this.invocation = invocation;
    this.argumentsValue = argumentsValue;
    this.region = region;
  }

  start(credential: ProviderCredential): ProviderOperationHandle<RemoteApiTransportResult> {
    return this.transport.start(this.invocation, this.argumentsValue, this.region, credential);
  }
}

export class GenericModelProvider implements ModelProvider {
  private readonly registered: RegisteredModelProvider;
  private readonly profile: ModelProviderProfile;
  private readonly price: ProviderPriceSnapshot;
  private readonly transport: ModelTransportPort;
  private readonly runner: ProviderOperationRunner;

  constructor(registered: RegisteredModelProvider, transport: ModelTransportPort,
    runner: ProviderOperationRunner) {
    this.registered = registered;
    this.profile = registered.profileSnapshot();
    this.price = registered.priceSnapshot();
    this.transport = transport;
    this.runner = runner;
  }

  registryEntry(estimatedInputTokens: number, estimatedOutputTokens: number): ModelRegistryEntry {
    return this.registered.registryEntry(estimatedInputTokens, estimatedOutputTokens);
  }

  async generate(request: ModelInvocation, cancellation: ProviderCancellationSignalPort,
    observer?: ModelStreamObserver): Promise<ModelProviderResult> {
    this.validateRequest(request);
    const transportRequest: ModelInvocation = new ModelInvocation();
    transportRequest.context = copyContext(request.context);
    transportRequest.context.credentialScope = this.profile.credentialScope;
    transportRequest.modelId = this.profile.providerModelId;
    transportRequest.modelVersion = this.profile.modelVersion;
    transportRequest.messages = copyMessages(request.messages);
    transportRequest.responseSchemaJson = request.responseSchemaJson;
    transportRequest.maxOutputTokens = request.maxOutputTokens;
    transportRequest.temperature = request.temperature;
    const safeObserver: SafeModelObserver = new SafeModelObserver(observer, request, this.profile, this.price);
    const raw: ModelTransportResult = await this.runner.run<ModelTransportResult>(transportRequest.context,
      cancellation, new ModelOperationFactory(this.transport, transportRequest, safeObserver));
    if (raw.modelVersion !== this.profile.modelVersion ||
      raw.region !== this.profile.region || !validUsage(raw.usage)) {
      throw new ProviderTransportError(ProviderErrorCode.PROVIDER, AgentErrorClass.PROVIDER,
        'Provider response trace or usage does not match the registered snapshot', true);
    }
    const result: ModelProviderResult = new ModelProviderResult();
    result.requestId = request.context.requestId;
    result.outputText = raw.outputText;
    if (raw.outputJson !== undefined) {
      try {
        result.outputJson = canonicalJson(JSON.parse(raw.outputJson) as Object);
      } catch (error) {
        throw new ProviderTransportError(ProviderErrorCode.PROVIDER, AgentErrorClass.PROVIDER,
          'Provider returned invalid JSON output', true);
      }
    }
    result.finishReason = raw.finishReason;
    result.modelId = this.profile.registryModelId;
    result.modelVersion = raw.modelVersion;
    result.region = raw.region;
    result.priceSnapshotId = this.price.snapshotId;
    result.usage = settleUsage(raw.usage, this.price.inputMicrosPerMillionTokens,
      this.price.outputMicrosPerMillionTokens, this.price.fixedCostMicros);
    return result;
  }

  private validateRequest(request: ModelInvocation): void {
    if (!validText(request.context.requestId) || !validText(request.context.taskId) ||
      !validText(request.context.stepId) || !validText(request.context.operationId) ||
      request.context.providerId !== this.profile.providerId ||
      request.context.region !== this.profile.region ||
      request.context.priceSnapshotId !== this.price.snapshotId ||
      request.modelId !== this.profile.registryModelId ||
      request.modelVersion !== this.profile.modelVersion || request.messages.length === 0 ||
      !Number.isSafeInteger(request.maxOutputTokens) || request.maxOutputTokens <= 0 ||
      request.maxOutputTokens > this.profile.maxOutputTokens || !Number.isFinite(request.temperature) ||
      request.temperature < 0 || request.temperature > 2) {
      throw new ProviderTransportError(ProviderErrorCode.INVALID_REQUEST, AgentErrorClass.INVALID_INPUT,
        'Model invocation does not match the registered provider snapshot');
    }
    for (let index: number = 0; index < request.messages.length; index++) {
      if (!validText(request.messages[index].role) || !validText(request.messages[index].content)) {
        throw new ProviderTransportError(ProviderErrorCode.INVALID_REQUEST, AgentErrorClass.INVALID_INPUT,
          'Model messages must contain role and content');
      }
    }
    try {
      parseJsonObject(request.responseSchemaJson);
    } catch (error) {
      throw new ProviderTransportError(ProviderErrorCode.INVALID_REQUEST, AgentErrorClass.INVALID_INPUT,
        'Model response schema must be a JSON object');
    }
  }
}

export class GenericEmbeddingProvider implements EmbeddingProvider {
  private readonly profile: ModelProviderProfile;
  private readonly price: ProviderPriceSnapshot;
  private readonly transport: EmbeddingTransportPort;
  private readonly runner: ProviderOperationRunner;

  constructor(registered: RegisteredModelProvider, transport: EmbeddingTransportPort,
    runner: ProviderOperationRunner) {
    this.profile = registered.profileSnapshot();
    this.price = registered.priceSnapshot();
    this.transport = transport;
    this.runner = runner;
  }

  async embed(request: EmbeddingInvocation,
    cancellation: ProviderCancellationSignalPort): Promise<EmbeddingProviderResult> {
    if (this.profile.capabilityKind !== ProviderCapabilityKind.EMBEDDING ||
      !validText(request.context.requestId) || !validText(request.context.taskId) ||
      !validText(request.context.stepId) || !validText(request.context.operationId) ||
      request.inputs.length === 0 ||
      request.modelId !== this.profile.registryModelId ||
      request.modelVersion !== this.profile.modelVersion ||
      request.context.providerId !== this.profile.providerId ||
      request.context.region !== this.profile.region ||
      request.context.priceSnapshotId !== this.price.snapshotId) {
      throw new ProviderTransportError(ProviderErrorCode.INVALID_REQUEST, AgentErrorClass.INVALID_INPUT,
        'Embedding invocation does not match the registered provider snapshot');
    }
    for (let index: number = 0; index < request.inputs.length; index++) {
      if (!validText(request.inputs[index])) {
        throw new ProviderTransportError(ProviderErrorCode.INVALID_REQUEST, AgentErrorClass.INVALID_INPUT,
          'Embedding inputs must not be empty');
      }
    }
    const transportRequest: EmbeddingInvocation = new EmbeddingInvocation();
    transportRequest.context = copyContext(request.context);
    transportRequest.context.credentialScope = this.profile.credentialScope;
    transportRequest.modelId = this.profile.providerModelId;
    transportRequest.modelVersion = this.profile.modelVersion;
    transportRequest.inputs = request.inputs.slice();
    const raw: EmbeddingTransportResult = await this.runner.run<EmbeddingTransportResult>(
      transportRequest.context, cancellation, new EmbeddingOperationFactory(this.transport, transportRequest));
    if (raw.modelVersion !== this.profile.modelVersion ||
      raw.region !== this.profile.region || !validUsage(raw.usage) ||
      raw.vectors.length !== request.inputs.length) {
      throw new ProviderTransportError(ProviderErrorCode.PROVIDER, AgentErrorClass.PROVIDER,
        'Embedding response trace, usage or vector count is invalid', true);
    }
    const result: EmbeddingProviderResult = new EmbeddingProviderResult();
    result.requestId = request.context.requestId;
    result.vectors = [];
    for (let index: number = 0; index < raw.vectors.length; index++) {
      result.vectors.push(raw.vectors[index].slice());
    }
    result.modelId = this.profile.registryModelId;
    result.modelVersion = raw.modelVersion;
    result.region = raw.region;
    result.priceSnapshotId = this.price.snapshotId;
    result.usage = settleUsage(raw.usage, this.price.inputMicrosPerMillionTokens,
      this.price.outputMicrosPerMillionTokens, this.price.fixedCostMicros);
    return result;
  }
}

export class GenericRemoteApiProvider implements RemoteApiProvider {
  private readonly profile: RemoteApiProfile;
  private readonly price: ProviderPriceSnapshot;
  private readonly entry: ToolRegistryEntry;
  private readonly transport: RemoteApiTransportPort;
  private readonly runner: ProviderOperationRunner;
  private readonly digestPort: ConnectorDigestPort;
  private readonly clock: ConnectorClockPort;
  private readonly grants: ProviderGrantVerifierPort;

  constructor(registered: RegisteredRemoteApiProvider, transport: RemoteApiTransportPort,
    runner: ProviderOperationRunner, digestPort: ConnectorDigestPort, clock: ConnectorClockPort,
    grants: ProviderGrantVerifierPort) {
    this.profile = registered.profileSnapshot();
    this.price = registered.priceSnapshot();
    this.entry = registered.registryEntry();
    this.transport = transport;
    this.runner = runner;
    this.digestPort = digestPort;
    this.clock = clock;
    this.grants = grants;
  }

  registryEntry(): ToolRegistryEntry {
    const source: ToolRegistryEntry = this.entry;
    const result: ToolRegistryEntry = new ToolRegistryEntry();
    result.descriptor = ContractCodec.parseToolDescriptor(ContractCodec.stringify(source.descriptor));
    result.registryVersion = source.registryVersion;
    result.registryDigest = source.registryDigest;
    result.descriptionDigest = source.descriptionDigest;
    result.retrievalRelationVersion = source.retrievalRelationVersion;
    result.estimatedCostMicros = source.estimatedCostMicros;
    result.requiresNetwork = source.requiresNetwork;
    result.enabled = source.enabled;
    return result;
  }

  async invoke(invocation: ToolInvocation,
    cancellation: ProviderCancellationSignalPort): Promise<RemoteApiProviderResult> {
    const startedAt: string = this.safeNow(invocation.createdAt);
    const descriptor: ToolDescriptor = this.entry.descriptor;
    if (!ContractValidator.validateToolInvocation(invocation).valid || invocation.toolId !== descriptor.toolId) {
      return this.wrap(this.failure(invocation.invocationId, startedAt, ToolOutcomeStatus.FAILED,
        AgentErrorClass.INVALID_INPUT, ProviderErrorCode.INVALID_REQUEST, 'Remote API invocation is invalid'));
    }
    if (invocation.toolIdentityVersion !== descriptor.toolIdentityVersion ||
      invocation.schemaDigest !== descriptor.schemaDigest) {
      return this.wrap(this.failure(invocation.invocationId, startedAt, ToolOutcomeStatus.DENIED,
        AgentErrorClass.POLICY_DENIED, 'REMOTE_API_IDENTITY_STALE', 'Remote API identity changed'));
    }
    let argumentsValue: Object;
    try {
      argumentsValue = parseJsonObject(invocation.argumentsJson);
      if (this.digestPort.digest(canonicalJson(argumentsValue)) !== invocation.argumentsDigest) {
        return this.wrap(this.failure(invocation.invocationId, startedAt, ToolOutcomeStatus.DENIED,
          AgentErrorClass.POLICY_DENIED, 'REMOTE_API_ARGUMENTS_DIGEST_MISMATCH',
          'Remote API arguments changed after authorization'));
      }
      if (!this.grants.verify(invocation, descriptor)) {
        return this.wrap(this.failure(invocation.invocationId, startedAt, ToolOutcomeStatus.DENIED,
          AgentErrorClass.POLICY_DENIED, 'REMOTE_API_GRANT_REJECTED', 'Runtime grant was rejected'));
      }
    } catch (error) {
      return this.wrap(this.failure(invocation.invocationId, startedAt, ToolOutcomeStatus.DENIED,
        AgentErrorClass.POLICY_DENIED, 'REMOTE_API_POLICY_CHECK_FAILED',
        'Remote API policy check failed closed'));
    }
    const context: ProviderRequestContext = new ProviderRequestContext();
    context.requestId = invocation.invocationId;
    context.taskId = invocation.taskId;
    context.stepId = invocation.stepId;
    context.operationId = invocation.operationId;
    context.providerId = descriptor.providerId;
    context.region = this.price.region;
    context.priceSnapshotId = this.price.snapshotId;
    context.credentialScope = this.profile.credentialScope;
    context.timeoutMs = invocation.timeoutMs;
    try {
      const raw: RemoteApiTransportResult = await this.runner.run<RemoteApiTransportResult>(context, cancellation,
        new RemoteOperationFactory(this.transport, invocation, argumentsValue, context.region));
      if (raw.region !== context.region) {
        return this.wrap(this.failure(invocation.invocationId, startedAt, ToolOutcomeStatus.FAILED,
          AgentErrorClass.PROVIDER, ProviderErrorCode.PROVIDER, 'Remote API region does not match snapshot'));
      }
      const resultJson: string = canonicalJson(JSON.parse(raw.resultJson) as Object);
      const outcome: ToolOutcome = new ToolOutcome();
      outcome.invocationId = invocation.invocationId;
      outcome.status = ToolOutcomeStatus.SUCCEEDED;
      outcome.resultJson = resultJson;
      outcome.resultDigest = this.digestPort.digest(resultJson);
      outcome.providerReceipt = raw.providerReceipt;
      outcome.startedAt = startedAt;
      outcome.finishedAt = this.safeNow(startedAt);
      return this.wrap(outcome, raw.providerReportedCostMicros);
    } catch (error) {
      if (error instanceof ProviderTransportError) {
        const uncertain: boolean = descriptor.sideEffect !== SideEffect.NONE && error.operationStarted &&
          (error.code === ProviderErrorCode.NETWORK || error.code === ProviderErrorCode.TIMEOUT ||
            error.code === ProviderErrorCode.CANCELLED);
        return this.wrap(this.failure(invocation.invocationId, startedAt,
          uncertain ? ToolOutcomeStatus.UNKNOWN_OUTCOME :
            (error.code === ProviderErrorCode.CANCELLED ? ToolOutcomeStatus.CANCELLED : ToolOutcomeStatus.FAILED),
          error.errorClass, error.code, error.message));
      }
      return this.wrap(this.failure(invocation.invocationId, startedAt, ToolOutcomeStatus.FAILED,
        AgentErrorClass.UNKNOWN, ProviderErrorCode.PROVIDER, 'Remote API adapter failed'));
    }
  }

  private failure(invocationId: string, startedAt: string, status: ToolOutcomeStatus,
    errorClass: AgentErrorClass, code: string, message: string): ToolOutcome {
    const outcome: ToolOutcome = new ToolOutcome();
    outcome.invocationId = invocationId;
    outcome.status = status;
    outcome.errorClass = errorClass;
    outcome.errorCode = code;
    outcome.errorMessage = message;
    outcome.startedAt = startedAt;
    outcome.finishedAt = this.safeNow(startedAt);
    return outcome;
  }

  private wrap(outcome: ToolOutcome, providerReportedCostMicros: number = 0): RemoteApiProviderResult {
    const result: RemoteApiProviderResult = new RemoteApiProviderResult();
    result.outcome = outcome;
    result.providerId = this.profile.providerId;
    result.capabilityName = this.profile.capabilityName;
    result.capabilityVersion = this.profile.capabilityVersion;
    result.region = this.price.region;
    result.priceSnapshotId = this.price.snapshotId;
    result.usage.providerReportedCostMicros = providerReportedCostMicros;
    result.usage.settledCostMicros = outcome.status === ToolOutcomeStatus.SUCCEEDED ?
      this.price.fixedCostMicros : 0;
    return result;
  }

  private safeNow(fallback: string): string {
    try {
      return this.clock.nowIso();
    } catch (error) {
      return fallback.trim().length > 0 ? fallback : '1970-01-01T00:00:00.000Z';
    }
  }
}
