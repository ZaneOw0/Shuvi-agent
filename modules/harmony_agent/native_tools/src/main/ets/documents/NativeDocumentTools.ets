import {
  AgentErrorClass, ContractValidator, DataBoundary, IdempotencyMode, RiskLevel, SideEffect,
  ToolDescriptor, ToolInvocation, ToolOutcome, ToolOutcomeStatus, ToolSourceType
} from '@harmony_agent/agent-contracts';
import {
  ProductionRuntimeAdapterFactoryPort, RuntimeToolOutcomeSinkPort, StepDispatchPort,
  StepDispatchReceipt, StepDispatchRequest, ToolRegistryEntry
} from '@harmony_agent/agent-runtime';
import {
  NativeCancellationResolverPort, NativeCancellationSignalPort, NativeCapabilityProbePort,
  NativeClockPort, NativeDigestPort, NativeExecutionEnvironmentPort, NativeGrantVerifierPort,
  NativeToolAdapter, NativeToolOutcomeSinkPort
} from '../native/NativeToolContracts';
import { copyNativeToolEntry, nativeCanonicalJson, parseNativeArguments } from '../native/NativeToolSupport';
import { NativeStepDispatchAdapter } from '../native/NativeStepDispatchAdapter';
import { DocumentWriteRequest, LOCAL_DOCUMENT_MAX_BYTES, LocalDocumentError, LocalDocumentResult } from './DocumentContracts';
import { LocalDocumentStore } from './LocalDocumentStore';

export const NATIVE_DOCUMENT_CAPABILITY: string = 'SystemCapability.FileManagement.File.FileIO';
const RESULT_SCHEMA: string = '{"type":"object","additionalProperties":false,"properties":{' +
  '"documentId":{"type":"string"},"fileName":{"type":"string"},"version":{"type":"integer"},' +
  '"contentDigest":{"type":"string"},"byteLength":{"type":"integer"},"updatedAt":{"type":"string"},' +
  '"content":{"type":"string"},"receipt":{"type":"string"},"replayed":{"type":"boolean"}},' +
  '"required":["documentId","fileName","version","contentDigest","byteLength","updatedAt"]}';

function schema(action: string): string {
  if (action === 'read') return '{"type":"object","additionalProperties":false,' +
    '"properties":{"documentId":{"type":"string"}},"required":["documentId"]}';
  const content: string = '"content":{"type":"string","maxLength":' + LOCAL_DOCUMENT_MAX_BYTES.toString() + '}';
  if (action === 'create') return '{"type":"object","additionalProperties":false,"properties":{' +
    '"fileName":{"type":"string","maxLength":120},' + content + '},"required":["fileName","content"]}';
  return '{"type":"object","additionalProperties":false,"properties":{' +
    '"documentId":{"type":"string"},"expectedVersion":{"type":"integer","minimum":1},' + content +
    '},"required":["documentId","expectedVersion","content"]}';
}

function validateArguments(action: string, args: Record<string, Object>): void {
  const allowed: string[] = action === 'read' ? ['documentId'] :
    (action === 'create' ? ['fileName', 'content'] : ['documentId', 'expectedVersion', 'content']);
  const keys: string[] = Object.keys(args);
  if (keys.length !== allowed.length) throw new LocalDocumentError('DOCUMENT_INVALID_ARGUMENTS');
  for (let i: number = 0; i < keys.length; i++) {
    if (allowed.indexOf(keys[i]) < 0) throw new LocalDocumentError('DOCUMENT_INVALID_ARGUMENTS');
  }
  for (let i: number = 0; i < allowed.length; i++) {
    const key: string = allowed[i];
    if (typeof args[key] !== (key === 'expectedVersion' ? 'number' : 'string')) {
      throw new LocalDocumentError('DOCUMENT_INVALID_ARGUMENTS');
    }
  }
  if (action !== 'read' && (args['content'] as string).length > LOCAL_DOCUMENT_MAX_BYTES) {
    throw new LocalDocumentError('DOCUMENT_TOO_LARGE');
  }
}

export class NativeDocumentToolAdapter implements NativeToolAdapter {
  private readonly action: string;
  private readonly store: LocalDocumentStore;
  private readonly digest: NativeDigestPort;
  private readonly clock: NativeClockPort;
  private readonly capability: NativeCapabilityProbePort;
  private readonly environment: NativeExecutionEnvironmentPort;
  private readonly grants: NativeGrantVerifierPort;
  private readonly boundary: DataBoundary;
  private readonly entry: ToolRegistryEntry;

  constructor(action: string, store: LocalDocumentStore, digest: NativeDigestPort, clock: NativeClockPort,
    capability: NativeCapabilityProbePort, environment: NativeExecutionEnvironmentPort, grants: NativeGrantVerifierPort,
    boundary: DataBoundary = DataBoundary.APP_SANDBOX) {
    if (['create', 'read', 'update'].indexOf(action) < 0) throw new LocalDocumentError('DOCUMENT_INVALID_ACTION');
    if (boundary !== DataBoundary.APP_SANDBOX && boundary !== DataBoundary.DEVICE_ONLY) {
      throw new LocalDocumentError('DOCUMENT_INVALID_BOUNDARY');
    }
    this.action = action;
    this.store = store;
    this.digest = digest;
    this.clock = clock;
    this.capability = capability;
    this.environment = environment;
    this.grants = grants;
    this.boundary = boundary;
    this.entry = this.createEntry();
  }

  registryEntry(): ToolRegistryEntry {
    const entry: ToolRegistryEntry = copyNativeToolEntry(this.entry);
    try {
      entry.enabled = this.capability.isAvailable(NATIVE_DOCUMENT_CAPABILITY);
      entry.descriptor.availability = entry.enabled ? 'available' : 'unavailable';
    } catch (_error) {
      entry.enabled = false;
      entry.descriptor.availability = 'unknown';
    }
    return entry;
  }

  async invoke(source: ToolInvocation, cancellation: NativeCancellationSignalPort): Promise<ToolOutcome> {
    const startedAt: string = this.now(source.createdAt);
    let writeStarted: boolean = false;
    try {
      const invocation: ToolInvocation = JSON.parse(nativeCanonicalJson(source)) as ToolInvocation;
      const descriptor: ToolDescriptor = this.entry.descriptor;
      if (!ContractValidator.validateToolInvocation(invocation).valid || invocation.toolId !== descriptor.toolId) {
        return this.failure(source.invocationId, startedAt, ToolOutcomeStatus.FAILED, 'DOCUMENT_INVALID_INVOCATION');
      }
      if (invocation.toolIdentityVersion !== descriptor.toolIdentityVersion || invocation.schemaDigest !== descriptor.schemaDigest) {
        return this.failure(invocation.invocationId, startedAt, ToolOutcomeStatus.DENIED, 'DOCUMENT_IDENTITY_STALE');
      }
      let args: Record<string, Object>;
      try { args = parseNativeArguments(invocation.argumentsJson) as Record<string, Object>; }
      catch (_error) { throw new LocalDocumentError('DOCUMENT_INVALID_ARGUMENTS'); }
      validateArguments(this.action, args);
      if (this.digest.digest(nativeCanonicalJson(args)) !== invocation.argumentsDigest) {
        return this.failure(invocation.invocationId, startedAt, ToolOutcomeStatus.DENIED, 'DOCUMENT_ARGUMENTS_CHANGED');
      }
      try {
        if (!this.grants.verify(invocation, descriptor) || !this.capability.isAvailable(NATIVE_DOCUMENT_CAPABILITY) ||
          !this.environment.isBackgroundExecutionAllowed(descriptor.toolId)) {
          return this.failure(invocation.invocationId, startedAt, ToolOutcomeStatus.DENIED, 'DOCUMENT_POLICY_DENIED');
        }
      } catch (_error) {
        return this.failure(invocation.invocationId, startedAt, ToolOutcomeStatus.DENIED, 'DOCUMENT_POLICY_UNAVAILABLE');
      }
      let value: LocalDocumentResult;
      if (this.action === 'read') value = await this.store.read(args['documentId'] as string, cancellation);
      else {
        const command: DocumentWriteRequest = new DocumentWriteRequest();
        command.action = this.action;
        command.operationId = invocation.operationId;
        command.idempotencyKey = invocation.idempotencyKey === undefined ? '' : invocation.idempotencyKey;
        command.argumentsDigest = invocation.argumentsDigest;
        command.content = args['content'] as string;
        if (this.action === 'create') command.fileName = args['fileName'] as string;
        else {
          command.documentId = args['documentId'] as string;
          command.expectedVersion = args['expectedVersion'] as number;
        }
        writeStarted = true;
        value = await this.store.write(command, cancellation);
      }
      const outcome: ToolOutcome = new ToolOutcome();
      outcome.invocationId = invocation.invocationId;
      outcome.status = ToolOutcomeStatus.SUCCEEDED;
      outcome.resultJson = nativeCanonicalJson(value);
      outcome.resultDigest = this.digest.digest(outcome.resultJson);
      outcome.providerReceipt = value.receipt;
      outcome.startedAt = startedAt;
      outcome.finishedAt = this.now(startedAt);
      return outcome;
    } catch (error) {
      if (error instanceof LocalDocumentError) {
        return this.failure(source.invocationId, startedAt, error.uncertain ? ToolOutcomeStatus.UNKNOWN_OUTCOME :
          (error.code === 'DOCUMENT_CANCELLED' ? ToolOutcomeStatus.CANCELLED : ToolOutcomeStatus.FAILED), error.code);
      }
      return this.failure(source.invocationId, startedAt,
        writeStarted ? ToolOutcomeStatus.UNKNOWN_OUTCOME : ToolOutcomeStatus.FAILED, 'DOCUMENT_ADAPTER_FAILURE');
    }
  }

  private createEntry(): ToolRegistryEntry {
    const descriptor: ToolDescriptor = new ToolDescriptor();
    descriptor.toolId = 'native://documents/' + this.store.scopeId + '/' + this.action;
    descriptor.sourceType = ToolSourceType.NATIVE;
    descriptor.providerId = 'local-documents/' + this.store.scopeId;
    descriptor.capabilityName = 'document.' + this.action;
    descriptor.capabilityVersion = '1.0.0';
    descriptor.displayName = 'Local document ' + this.action;
    descriptor.description = this.action === 'create' ? 'Create a UTF-8 .txt or .md document in the app private document store.' :
      (this.action === 'read' ? 'Read a private document by its opaque documentId.' :
        'Replace a private document only when expectedVersion matches the current version.');
    if (this.boundary === DataBoundary.DEVICE_ONLY) {
      descriptor.description = this.action === 'read' ? 'Read a versioned local document and check its public Download copy.' :
        'Save a versioned document and publish its named file to this app directory in public Download storage.';
    }
    descriptor.inputSchemaJson = schema(this.action);
    descriptor.outputSchemaJson = RESULT_SCHEMA;
    descriptor.schemaDigest = this.digest.digest(descriptor.inputSchemaJson + '|' + RESULT_SCHEMA);
    descriptor.toolIdentityVersion = this.digest.digest('native-document-v1|' + descriptor.toolId + '|' +
      this.store.storageIdentity + '|' + descriptor.schemaDigest);
    descriptor.capabilityTags = ['document', this.action === 'read' ? 'read-only' : 'write', 'document.' + this.action];
    descriptor.riskLevel = this.action === 'read' ? RiskLevel.LOW : RiskLevel.MEDIUM;
    descriptor.sideEffect = this.action === 'read' ? SideEffect.NONE : SideEffect.REVERSIBLE;
    descriptor.idempotencyMode = this.action === 'read' ? IdempotencyMode.NONE : IdempotencyMode.PROVIDER_KEY;
    descriptor.dataBoundary = this.boundary;
    descriptor.latencyClass = 'local-io';
    descriptor.costClass = 'zero';
    descriptor.adapterRef = 'native:documents/' + this.store.scopeId;
    const entry: ToolRegistryEntry = new ToolRegistryEntry();
    entry.descriptor = descriptor;
    entry.registryVersion = descriptor.toolIdentityVersion;
    entry.descriptionDigest = this.digest.digest(descriptor.description);
    entry.registryDigest = this.digest.digest(nativeCanonicalJson(descriptor));
    entry.retrievalRelationVersion = descriptor.toolIdentityVersion;
    entry.estimatedCostMicros = 0;
    entry.requiresNetwork = false;
    return entry;
  }

  private failure(invocationId: string, startedAt: string, status: ToolOutcomeStatus, code: string): ToolOutcome {
    const outcome: ToolOutcome = new ToolOutcome();
    outcome.invocationId = invocationId;
    outcome.status = status;
    const invalidInput: boolean = code.startsWith('DOCUMENT_INVALID_') || code === 'DOCUMENT_TOO_LARGE' ||
      code === 'DOCUMENT_VERSION_CONFLICT' || code === 'DOCUMENT_IDEMPOTENCY_CONFLICT' ||
      code === 'DOCUMENT_NOT_FOUND' || code === 'DOCUMENT_ALREADY_EXISTS';
    outcome.errorClass = status === ToolOutcomeStatus.DENIED ? AgentErrorClass.POLICY_DENIED :
      (status === ToolOutcomeStatus.CANCELLED ? AgentErrorClass.CANCELLED :
        (invalidInput ? AgentErrorClass.INVALID_INPUT : AgentErrorClass.PROVIDER));
    outcome.errorCode = code;
    outcome.errorMessage = code;
    outcome.startedAt = startedAt;
    outcome.finishedAt = this.now(startedAt);
    return outcome;
  }

  private now(fallback: string): string {
    try { return this.clock.nowIso(); } catch (_error) { return fallback; }
  }
}

class DocumentOutcomeSink implements NativeToolOutcomeSinkPort {
  private readonly sink: RuntimeToolOutcomeSinkPort;
  constructor(sink: RuntimeToolOutcomeSinkPort) { this.sink = sink; }
  complete(taskId: string, stepId: string, dispatchId: string, outcome: ToolOutcome): void {
    this.sink.complete(taskId, stepId, dispatchId, outcome).catch((_error: Error): void => {});
  }
}

class DocumentDispatcher implements StepDispatchPort {
  private readonly routes: Map<string, NativeStepDispatchAdapter> = new Map<string, NativeStepDispatchAdapter>();
  constructor(adapters: NativeDocumentToolAdapter[], cancellations: NativeCancellationResolverPort, sink: RuntimeToolOutcomeSinkPort) {
    for (let i: number = 0; i < adapters.length; i++) {
      this.routes.set(adapters[i].registryEntry().descriptor.toolId,
        new NativeStepDispatchAdapter(adapters[i], cancellations, new DocumentOutcomeSink(sink)));
    }
  }
  dispatch(request: StepDispatchRequest): StepDispatchReceipt {
    const adapter: NativeStepDispatchAdapter | undefined = request.toolInvocation === undefined ? undefined :
      this.routes.get(request.toolInvocation.toolId);
    if (adapter !== undefined) return adapter.dispatch(request);
    const rejected: StepDispatchReceipt = new StepDispatchReceipt();
    rejected.rejectionCode = 'DOCUMENT_TOOL_NOT_REGISTERED';
    return rejected;
  }

  cancel(dispatchId: string): boolean {
    let cancelled: boolean = false;
    this.routes.forEach((adapter: NativeStepDispatchAdapter): void => {
      if (adapter.cancel(dispatchId)) cancelled = true;
    });
    return cancelled;
  }
}

/** Pass entries() and this factory to McpRuntimeToolExtension; no UI or task-control endpoint is exposed. */
export class NativeDocumentTools implements ProductionRuntimeAdapterFactoryPort {
  private readonly adapters: NativeDocumentToolAdapter[];
  private readonly cancellations: NativeCancellationResolverPort;

  constructor(store: LocalDocumentStore, digest: NativeDigestPort, clock: NativeClockPort,
    capability: NativeCapabilityProbePort, environment: NativeExecutionEnvironmentPort,
    grants: NativeGrantVerifierPort, cancellations: NativeCancellationResolverPort,
    boundary: DataBoundary = DataBoundary.APP_SANDBOX) {
    this.cancellations = cancellations;
    this.adapters = ['create', 'read', 'update'].map((action: string): NativeDocumentToolAdapter =>
      new NativeDocumentToolAdapter(action, store, digest, clock, capability, environment, grants, boundary));
  }
  entries(): ToolRegistryEntry[] { return this.adapters.map((adapter: NativeDocumentToolAdapter): ToolRegistryEntry => adapter.registryEntry()); }
  create(sink: RuntimeToolOutcomeSinkPort): StepDispatchPort { return new DocumentDispatcher(this.adapters, this.cancellations, sink); }
}
