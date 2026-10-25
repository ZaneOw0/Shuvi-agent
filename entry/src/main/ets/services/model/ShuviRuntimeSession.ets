import {
  AgentApplicationBackend, AgentApplicationBackendState, AgentFrontendAuthorizationPrompt,
  AgentFrontendCommandReceipt, AgentFrontendEventListener, AgentFrontendSubscription,
  AgentFrontendTaskHandle, AgentFrontendTaskRequest, AgentFrontendTaskState, ShutdownMode, SingleAgentHostResourcePort
} from '@harmony_agent/agent-runtime';
import { McpClientManager } from '@harmony_agent/mcp-client';
import { ProviderPriceSnapshot } from '@harmony_agent/agent-connectors';
import { DeepSeekProfile } from './DeepSeekProtocol';
import { ArkTsDeepSeekHttpClient } from './DeepSeekHttpClient';
import { createDeepSeekProvider } from './DeepSeekProvider';
import { SearchAuthorizationPreviews, decideSearchAuthorization } from './SearchAuthorizationPreview';
import { SessionModelHttpClient } from './SessionModelHttpClient';
import { ShuviDeviceHostResources } from './ShuviDeviceHostResources';
import { ShuviModelBackendConfig, ShuviModelBackendPorts, createShuviModelBackend } from './ShuviModelBackend';
import { SearchUsageReceipts } from './SearchUsageReceipts';
import { SessionModelCredentials } from './SessionModelCredentials';

export interface ShuviSessionResources {
  credentials: SessionModelCredentials;
  execution: SingleAgentHostResourcePort;
  memory: SingleAgentHostResourcePort;
}

/** App-private boundary for lifecycle tests and the single production implementation below. */
export interface ShuviRuntimeSessionPort {
  start(key: Uint8Array): Promise<void>;
  stop(): Promise<void>;
  submit(request: AgentFrontendTaskRequest): Promise<AgentFrontendTaskHandle>;
  authorize(prompt: AgentFrontendAuthorizationPrompt, approved: boolean): Promise<AgentFrontendCommandReceipt>;
  cancel(taskId: string): Promise<AgentFrontendCommandReceipt>;
  getTask(taskId: string): Promise<AgentFrontendTaskState>;
  subscribe(taskId: string, listener: AgentFrontendEventListener, afterSequence: number): Promise<AgentFrontendSubscription>;
}

export interface ShuviRuntimeSessionFactory {
  // Construct a fresh session with no key or I/O. The controller consumes the key after accepting ownership.
  create(): ShuviRuntimeSessionPort;
}

export class ShuviRuntimeSession implements ShuviRuntimeSessionPort {
  private readonly backend: AgentApplicationBackend;
  private readonly resources: ShuviSessionResources;
  private readonly http: SessionModelHttpClient;
  private readonly manager: McpClientManager;
  private readonly previews: SearchAuthorizationPreviews;
  private readonly searchUsage?: SearchUsageReceipts;
  private starting?: Promise<void>;
  private stopping?: Promise<void>;
  private stopped: boolean = false;
  private ready: boolean = false;

  constructor(backend: AgentApplicationBackend, resources: ShuviSessionResources,
    http: SessionModelHttpClient, manager: McpClientManager, previews: SearchAuthorizationPreviews,
    searchUsage?: SearchUsageReceipts) {
    this.backend = backend; this.resources = resources; this.http = http;
    this.manager = manager; this.previews = previews;
    this.searchUsage = searchUsage;
  }

  async start(key: Uint8Array): Promise<void> {
    try {
      if (this.stopped || this.starting !== undefined) throw new Error('AGENT_SESSION_ALREADY_USED');
      this.resources.credentials.configure(key);
      this.starting = this.backend.onCreate();
      await this.starting;
      if (this.stopped) throw new Error('AGENT_SESSION_START_INTERRUPTED');
      this.ready = true;
    } finally { key.fill(0); }
  }

  stop(): Promise<void> {
    if (this.stopping !== undefined) return this.stopping;
    this.stopped = true;
    this.ready = false;
    this.previews.clear();
    this.searchUsage?.close();
    let cancellationFailed: boolean = false;
    try { this.http.stop(); } catch (error) { cancellationFailed = true; }
    // close() synchronously revokes future credential resolution, even during slow host startup.
    const revoked: Promise<void> = this.resources.credentials.close();
    const disconnected: Promise<void> = this.manager.disconnectAll();
    this.stopping = this.stopOnce(revoked, disconnected, cancellationFailed);
    return this.stopping;
  }

  private async stopOnce(revoked: Promise<void>, disconnected: Promise<void>, cancellationFailed: boolean): Promise<void> {
    let failed: boolean = cancellationFailed;
    try { await revoked; } catch (error) { failed = true; }
    // Interrupt discovery/tool network immediately; a late startup is drained and disconnected again below.
    try { await disconnected; } catch (error) { failed = true; }
    if (this.starting !== undefined) {
      try { await this.starting; } catch (error) { /* The host has attempted startup rollback. */ }
    }
    const state = this.backend.lifecycleState();
    if (state !== AgentApplicationBackendState.NEW && state !== AgentApplicationBackendState.FAILED) {
      try { await this.backend.onDestroy(ShutdownMode.IMMEDIATE); } catch (error) { failed = true; }
    }
    // Also retry owned cleanup after a failed startup; never erase or rebuild user databases.
    try { await this.manager.disconnectAll(); } catch (error) { failed = true; }
    try { await this.resources.memory.close(); } catch (error) { failed = true; }
    try { await this.resources.execution.close(); } catch (error) { failed = true; }
    try { await this.resources.credentials.close(); } catch (error) { failed = true; }
    this.previews.clear();
    if (failed) throw new Error('AGENT_SESSION_SHUTDOWN_FAILED');
  }

  private assertReady(): void {
    if (!this.ready || this.stopped) throw new Error('AGENT_SESSION_NOT_READY');
  }
  async submit(request: AgentFrontendTaskRequest): Promise<AgentFrontendTaskHandle> {
    this.assertReady(); return await this.backend.submitTask(request);
  }
  async authorize(prompt: AgentFrontendAuthorizationPrompt, approved: boolean): Promise<AgentFrontendCommandReceipt> {
    this.assertReady();
    return await decideSearchAuthorization(this.backend, this.previews, prompt, approved, Date.now());
  }
  async cancel(taskId: string): Promise<AgentFrontendCommandReceipt> {
    this.assertReady();
    const result = await this.backend.cancelTask(taskId);
    if (result.accepted) this.previews.forgetTask(taskId);
    return result;
  }
  async getTask(taskId: string): Promise<AgentFrontendTaskState> {
    this.assertReady(); return await this.backend.getTaskState(taskId);
  }
  async subscribe(taskId: string, listener: AgentFrontendEventListener,
    afterSequence: number): Promise<AgentFrontendSubscription> {
    this.assertReady(); return await this.backend.subscribe(taskId, listener, afterSequence);
  }
}

/** Only constructs the real composition; no model price, budget, identity or search endpoint is guessed. */
export function createShuviRuntimeSession(config: ShuviModelBackendConfig, ports: ShuviModelBackendPorts,
  resources: ShuviDeviceHostResources, profile: DeepSeekProfile, price: ProviderPriceSnapshot): ShuviRuntimeSession {
  const manager = ports.manager;
  if (manager === undefined) throw new Error('AGENT_SESSION_MCP_REQUIRED');
  resources.bind(ports);
  const http = new SessionModelHttpClient(new ArkTsDeepSeekHttpClient());
  const model = createDeepSeekProvider(profile, price, resources.digest, resources.credentials, http);
  const backend = createShuviModelBackend(config, ports, model.registered, model.provider);
  return new ShuviRuntimeSession(backend, resources, http, manager, ports.authorizations, ports.searchUsage);
}
