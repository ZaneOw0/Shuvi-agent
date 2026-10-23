import {
  AgentErrorClass,
  DataBoundary,
  IdempotencyMode,
  PrivacyClass,
  RiskLevel,
  SideEffect,
  ToolDescriptor,
  ToolInvocation,
  ToolOutcome
} from '@harmony_agent/agent-contracts';
import { ModelRegistryEntry, ToolRegistryEntry } from '@harmony_agent/agent-runtime';

export enum ProviderCapabilityKind {
  MODEL = 'model',
  EMBEDDING = 'embedding',
  REMOTE_API = 'remoteApi'
}

export enum ProviderErrorCode {
  CONFIGURATION = 'CONFIGURATION',
  INVALID_REQUEST = 'INVALID_REQUEST',
  AUTHENTICATION = 'AUTHENTICATION',
  FORBIDDEN = 'FORBIDDEN',
  RATE_LIMITED = 'RATE_LIMITED',
  NETWORK = 'NETWORK',
  TIMEOUT = 'TIMEOUT',
  CANCELLED = 'CANCELLED',
  RESPONSE_TOO_LARGE = 'RESPONSE_TOO_LARGE',
  PROVIDER = 'PROVIDER'
}

export enum ProviderFinishReason {
  STOP = 'stop',
  LENGTH = 'length',
  CONTENT_FILTER = 'contentFilter',
  CANCELLED = 'cancelled',
  ERROR = 'error'
}

export class ProviderCredential {
  headers: Record<string, string> = new Object() as Record<string, string>;
}

export class ProviderRequestContext {
  requestId: string = '';
  taskId: string = '';
  stepId: string = '';
  operationId: string = '';
  providerId: string = '';
  region: string = '';
  priceSnapshotId: string = '';
  credentialScope: string = '';
  timeoutMs: number = 0;
}

export class ProviderUsage {
  inputTokens: number = 0;
  outputTokens: number = 0;
  totalTokens: number = 0;
  providerReportedCostMicros: number = 0;
  settledCostMicros: number = 0;
}

export class ProviderPriceSnapshot {
  snapshotId: string = '';
  providerId: string = '';
  capabilityId: string = '';
  capabilityVersion: string = '';
  region: string = '';
  currency: string = 'USD';
  inputMicrosPerMillionTokens: number = 0;
  outputMicrosPerMillionTokens: number = 0;
  fixedCostMicros: number = 0;
  effectiveAt: string = '';
  snapshotDigest: string = '';
}

export class ModelMessage {
  role: string = '';
  content: string = '';
}

export class ModelInvocation {
  context: ProviderRequestContext = new ProviderRequestContext();
  modelId: string = '';
  modelVersion: string = '';
  messages: ModelMessage[] = [];
  responseSchemaJson: string = '{}';
  maxOutputTokens: number = 0;
  temperature: number = 0;
}

export class ModelStreamChunk {
  requestId: string = '';
  sequence: number = 0;
  delta: string = '';
  modelId: string = '';
  modelVersion: string = '';
  region: string = '';
  priceSnapshotId: string = '';
}

export class ModelProviderResult {
  requestId: string = '';
  outputText: string = '';
  outputJson?: string;
  finishReason: ProviderFinishReason = ProviderFinishReason.ERROR;
  modelId: string = '';
  modelVersion: string = '';
  region: string = '';
  priceSnapshotId: string = '';
  usage: ProviderUsage = new ProviderUsage();
}

export class EmbeddingInvocation {
  context: ProviderRequestContext = new ProviderRequestContext();
  modelId: string = '';
  modelVersion: string = '';
  inputs: string[] = [];
}

export class EmbeddingProviderResult {
  requestId: string = '';
  vectors: number[][] = [];
  modelId: string = '';
  modelVersion: string = '';
  region: string = '';
  priceSnapshotId: string = '';
  usage: ProviderUsage = new ProviderUsage();
}

export class RemoteApiProfile {
  providerId: string = '';
  capabilityName: string = '';
  capabilityVersion: string = '';
  regions: string[] = [];
  inputSchemaJson: string = '{}';
  outputSchemaJson?: string;
  capabilityTags: string[] = [];
  permissionRequirements: string[] = [];
  riskLevel: RiskLevel = RiskLevel.LOW;
  sideEffect: SideEffect = SideEffect.NONE;
  dataBoundary: DataBoundary = DataBoundary.REMOTE_ALLOWED;
  idempotencyMode: IdempotencyMode = IdempotencyMode.NONE;
  latencyClass: string = 'network';
  costClass: string = 'provider';
  displayName: string = '';
  description: string = '';
  credentialScope: string = '';
  available: boolean = false;
}

export class RemoteApiProviderResult {
  outcome: ToolOutcome = new ToolOutcome();
  providerId: string = '';
  capabilityName: string = '';
  capabilityVersion: string = '';
  region: string = '';
  priceSnapshotId: string = '';
  usage: ProviderUsage = new ProviderUsage();
}

export class ProviderTransportError extends Error {
  readonly code: ProviderErrorCode;
  readonly errorClass: AgentErrorClass;
  readonly operationStarted: boolean;

  constructor(code: ProviderErrorCode, errorClass: AgentErrorClass, message: string,
    operationStarted: boolean = false) {
    super(message);
    this.name = 'ProviderTransportError';
    this.code = code;
    this.errorClass = errorClass;
    this.operationStarted = operationStarted;
  }
}

export interface ProviderCredentialPort {
  resolve(providerId: string, scope: string): Promise<ProviderCredential>;
}

export interface ProviderCancellationSubscriptionPort {
  dispose(): void;
}

export interface ProviderCancellationSignalPort {
  isCancellationRequested(): boolean;
  subscribe(listener: () => void): ProviderCancellationSubscriptionPort;
}

export interface ProviderTimerHandlePort {
  cancel(): void;
}

export interface ProviderTimerPort {
  schedule(delayMs: number, action: () => void): ProviderTimerHandlePort;
}

export interface ProviderOperationHandle<T> {
  result: Promise<T>;
  cancel(): void;
}

export class ModelTransportChunk {
  delta: string = '';
}

export class ModelTransportResult {
  outputText: string = '';
  outputJson?: string;
  finishReason: ProviderFinishReason = ProviderFinishReason.STOP;
  modelVersion: string = '';
  region: string = '';
  usage: ProviderUsage = new ProviderUsage();
}

export class EmbeddingTransportResult {
  vectors: number[][] = [];
  modelVersion: string = '';
  region: string = '';
  usage: ProviderUsage = new ProviderUsage();
}

export class RemoteApiTransportResult {
  resultJson: string = '{}';
  providerReceipt?: string;
  region: string = '';
  providerReportedCostMicros: number = 0;
}

export interface ModelStreamObserver {
  onChunk(chunk: ModelStreamChunk): void;
}

export interface ModelTransportObserver {
  onChunk(chunk: ModelTransportChunk): void;
}

export interface ModelTransportPort {
  start(request: ModelInvocation, credential: ProviderCredential,
    observer?: ModelTransportObserver): ProviderOperationHandle<ModelTransportResult>;
}

export interface EmbeddingTransportPort {
  start(request: EmbeddingInvocation,
    credential: ProviderCredential): ProviderOperationHandle<EmbeddingTransportResult>;
}

export interface RemoteApiTransportPort {
  start(invocation: ToolInvocation, argumentsValue: Object, region: string,
    credential: ProviderCredential): ProviderOperationHandle<RemoteApiTransportResult>;
}

export interface ModelProvider {
  registryEntry(estimatedInputTokens: number, estimatedOutputTokens: number): ModelRegistryEntry;
  generate(request: ModelInvocation, cancellation: ProviderCancellationSignalPort,
    observer?: ModelStreamObserver): Promise<ModelProviderResult>;
}

export interface EmbeddingProvider {
  embed(request: EmbeddingInvocation,
    cancellation: ProviderCancellationSignalPort): Promise<EmbeddingProviderResult>;
}

export interface RemoteApiProvider {
  registryEntry(): ToolRegistryEntry;
  invoke(invocation: ToolInvocation,
    cancellation: ProviderCancellationSignalPort): Promise<RemoteApiProviderResult>;
}

export interface ProviderGrantVerifierPort {
  verify(invocation: ToolInvocation, descriptor: ToolDescriptor): boolean;
}
