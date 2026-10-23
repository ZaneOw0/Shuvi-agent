export enum McpProtocolMode {
  AUTO = 'auto',
  MODERN = 'modern',
  LEGACY = 'legacy'
}

export enum McpProtocolEra {
  MODERN = 'modern',
  LEGACY = 'legacy'
}

export enum McpConnectionState {
  DISCONNECTED = 'disconnected',
  CONNECTING = 'connecting',
  READY = 'ready',
  DEGRADED = 'degraded',
  FAILED = 'failed'
}

export enum McpCapabilityKind {
  TOOL = 'tool',
  RESOURCE = 'resource',
  RESOURCE_TEMPLATE = 'resourceTemplate',
  PROMPT = 'prompt'
}

export interface McpServerProfile {
  id: string;
  endpoint: string;
  displayName?: string;
  protocolMode?: McpProtocolMode;
  connectTimeoutMs?: number;
  requestTimeoutMs?: number;
  maxResponseBytes?: number;
  allowInsecureHttp?: boolean;
  /** Retry one tool call after a legacy session-expired 404. Use only for read-only tools. */
  retryToolCallOnExpiredSession?: boolean;
}

export interface McpCancellationSubscription {
  dispose(): void;
}

export interface McpCancellationSignal {
  isCancellationRequested(): boolean;
  subscribe(listener: () => void): McpCancellationSubscription;
}

export interface McpCapabilityRef {
  serverId: string;
  kind: McpCapabilityKind;
  name: string;
}

export interface McpContentBlock {
  type: string;
  text?: string;
  data?: string;
  mimeType?: string;
  uri?: string;
  name?: string;
  title?: string;
  resource?: Object;
  raw?: Object;
}

export interface McpTool {
  ref: McpCapabilityRef;
  name: string;
  title?: string;
  description?: string;
  inputSchema: Object;
  outputSchema?: Object;
  annotations?: Object;
  raw?: Object;
}

export interface McpResource {
  ref: McpCapabilityRef;
  uri: string;
  name: string;
  title?: string;
  description?: string;
  mimeType?: string;
  size?: number;
  annotations?: Object;
  raw?: Object;
}

export interface McpResourceTemplate {
  ref: McpCapabilityRef;
  uriTemplate: string;
  name: string;
  title?: string;
  description?: string;
  mimeType?: string;
  annotations?: Object;
  raw?: Object;
}

export interface McpPromptArgument {
  name: string;
  description?: string;
  required?: boolean;
}

export interface McpPrompt {
  ref: McpCapabilityRef;
  name: string;
  title?: string;
  description?: string;
  arguments?: McpPromptArgument[];
  raw?: Object;
}

export interface McpToolResult {
  content: McpContentBlock[];
  structuredContent?: Object;
  isError: boolean;
  raw?: Object;
}

export interface McpReadResourceResult {
  contents: McpContentBlock[];
  raw?: Object;
}

export interface McpPromptMessage {
  role: string;
  content: McpContentBlock;
}

export interface McpGetPromptResult {
  description?: string;
  messages: McpPromptMessage[];
  raw?: Object;
}

export interface McpServerFailure {
  serverId: string;
  code: string;
  message: string;
}

export interface McpAggregateResult<T> {
  items: T[];
  errors: McpServerFailure[];
}

export interface McpConnectionSnapshot {
  serverId: string;
  state: McpConnectionState;
  era?: McpProtocolEra;
  protocolVersion?: string;
  serverInfo?: Object;
  instructions?: string;
  lastError?: string;
}

export interface McpAuthProvider {
  getHeaders(profile: McpServerProfile, operation: string): Promise<Record<string, string>>;
}

export interface McpAuthorizationDecision {
  allowed: boolean;
  reason?: string;
}

export interface McpInvocationContext {
  profile: McpServerProfile;
  tool: McpTool;
  arguments: Object;
}

export interface McpInvocationPolicy {
  authorize(context: McpInvocationContext): Promise<McpAuthorizationDecision>;
}

export interface McpManagerOptions {
  authProvider?: McpAuthProvider;
  invocationPolicy?: McpInvocationPolicy;
  clientName?: string;
  clientVersion?: string;
  debugBuild?: boolean;
}

export type McpConnectionListener = (snapshot: McpConnectionSnapshot) => void;

