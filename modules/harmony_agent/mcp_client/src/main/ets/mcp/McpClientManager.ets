import { MCP_CLIENT_VERSION } from './Constants';
import { McpClientError, McpErrorCode } from './Errors';
import {
  McpAggregateResult,
  McpCapabilityKind,
  McpCapabilityRef,
  McpCancellationSignal,
  McpConnectionListener,
  McpConnectionSnapshot,
  McpConnectionState,
  McpGetPromptResult,
  McpManagerOptions,
  McpPrompt,
  McpReadResourceResult,
  McpResource,
  McpResourceTemplate,
  McpServerFailure,
  McpServerProfile,
  McpTool,
  McpToolResult
} from './Types';
import {
  McpProtocolClient,
  McpProtocolClientOptions,
  McpProtocolConnectionInfo
} from './internal/ProtocolClient';

class ManagedServer {
  readonly profile: McpServerProfile;
  readonly client: McpProtocolClient;
  state: McpConnectionState = McpConnectionState.DISCONNECTED;
  info?: McpProtocolConnectionInfo;
  lastError?: string;
  tools: McpTool[] = [];
  resources: McpResource[] = [];
  resourceTemplates: McpResourceTemplate[] = [];
  prompts: McpPrompt[] = [];
  toolsLoaded: boolean = false;
  resourcesLoaded: boolean = false;
  resourceTemplatesLoaded: boolean = false;
  promptsLoaded: boolean = false;

  constructor(profile: McpServerProfile, client: McpProtocolClient) {
    this.profile = profile;
    this.client = client;
  }
}

interface ServerCollection<T> {
  items: T[];
  error?: McpServerFailure;
}

export class McpClientManager {
  private readonly options: McpManagerOptions;
  private readonly servers: Map<string, ManagedServer> = new Map<string, ManagedServer>();
  private readonly listeners: McpConnectionListener[] = [];

  constructor(options?: McpManagerOptions) {
    this.options = options === undefined ? new Object() as McpManagerOptions : options;
  }

  registerServer(profile: McpServerProfile): void {
    if (this.servers.has(profile.id)) {
      throw new McpClientError(McpErrorCode.CONFIGURATION,
        `Server id is already registered: ${profile.id}`, profile.id);
    }
    const protocolOptions: McpProtocolClientOptions = {
      authProvider: this.options.authProvider,
      clientName: this.options.clientName === undefined ? 'harmony_agent' : this.options.clientName,
      clientVersion: this.options.clientVersion === undefined ? MCP_CLIENT_VERSION : this.options.clientVersion,
      debugBuild: this.options.debugBuild === true
    };
    const client: McpProtocolClient = this.createProtocolClient(profile, protocolOptions);
    this.servers.set(profile.id, new ManagedServer(profile, client));
    this.emit(this.requireServer(profile.id));
  }

  protected createProtocolClient(profile: McpServerProfile,
    protocolOptions: McpProtocolClientOptions): McpProtocolClient {
    return new McpProtocolClient(profile, protocolOptions);
  }

  async unregisterServer(serverId: string): Promise<void> {
    const server: ManagedServer = this.requireServer(serverId);
    await server.client.close();
    this.servers.delete(serverId);
  }

  async connect(serverId: string): Promise<McpConnectionSnapshot> {
    const server: ManagedServer = this.requireServer(serverId);
    server.state = McpConnectionState.CONNECTING;
    server.lastError = undefined;
    this.emit(server);
    try {
      server.info = await server.client.connect();
      server.state = McpConnectionState.READY;
      this.emit(server);
      return this.snapshot(server);
    } catch (error) {
      server.state = McpConnectionState.FAILED;
      server.lastError = this.errorMessage(error);
      this.emit(server);
      throw this.normalizeError(error);
    }
  }

  async connectAll(): Promise<McpAggregateResult<McpConnectionSnapshot>> {
    const promises: Promise<ServerCollection<McpConnectionSnapshot>>[] = [];
    this.servers.forEach((server: ManagedServer): void => {
      promises.push(this.connectOne(server));
    });
    return this.combine(await Promise.all(promises));
  }

  async disconnect(serverId: string): Promise<void> {
    const server: ManagedServer = this.requireServer(serverId);
    await server.client.close();
    server.state = McpConnectionState.DISCONNECTED;
    server.info = undefined;
    server.lastError = undefined;
    this.clearCatalog(server);
    this.emit(server);
  }

  async disconnectAll(): Promise<void> {
    const promises: Promise<void>[] = [];
    this.servers.forEach((server: ManagedServer): void => {
      promises.push(this.disconnect(server.profile.id));
    });
    await Promise.all(promises);
  }

  async refreshServer(serverId: string): Promise<void> {
    const server: ManagedServer = this.requireReadyServer(serverId);
    const collections: Promise<void>[] = [];
    if (server.client.hasCapability('tools')) {
      collections.push(this.refreshTools(server));
    } else {
      server.tools = [];
      server.toolsLoaded = true;
    }
    if (server.client.hasCapability('resources')) {
      collections.push(this.refreshResources(server));
      collections.push(this.refreshResourceTemplates(server));
    } else {
      server.resources = [];
      server.resourceTemplates = [];
      server.resourcesLoaded = true;
      server.resourceTemplatesLoaded = true;
    }
    if (server.client.hasCapability('prompts')) {
      collections.push(this.refreshPrompts(server));
    } else {
      server.prompts = [];
      server.promptsLoaded = true;
    }
    const failures: McpServerFailure[] = [];
    const results: ServerCollection<Object>[] = await Promise.all(collections.map(
      async (operation: Promise<void>): Promise<ServerCollection<Object>> => {
        try {
          await operation;
          return { items: [] };
        } catch (error) {
          return { items: [], error: this.failure(server.profile.id, error) };
        }
      }));
    for (let index: number = 0; index < results.length; index++) {
      if (results[index].error !== undefined) {
        failures.push(results[index].error as McpServerFailure);
      }
    }
    server.state = failures.length === 0 ? McpConnectionState.READY : McpConnectionState.DEGRADED;
    server.lastError = failures.length === 0 ? undefined : failures[0].message;
    this.emit(server);
    if (failures.length > 0) {
      throw new McpClientError(McpErrorCode.PROTOCOL,
        `Capability refresh failed for ${failures.length} operation(s)`, serverId, undefined, undefined, failures);
    }
  }

  async refreshAll(): Promise<McpAggregateResult<McpConnectionSnapshot>> {
    const promises: Promise<ServerCollection<McpConnectionSnapshot>>[] = [];
    this.servers.forEach((server: ManagedServer): void => {
      promises.push(this.refreshOne(server));
    });
    return this.combine(await Promise.all(promises));
  }

  async listTools(): Promise<McpAggregateResult<McpTool>> {
    const promises: Promise<ServerCollection<McpTool>>[] = [];
    this.servers.forEach((server: ManagedServer): void => {
      promises.push(this.collectTools(server));
    });
    return this.combine(await Promise.all(promises));
  }

  async listResources(): Promise<McpAggregateResult<McpResource>> {
    const promises: Promise<ServerCollection<McpResource>>[] = [];
    this.servers.forEach((server: ManagedServer): void => {
      promises.push(this.collectResources(server));
    });
    return this.combine(await Promise.all(promises));
  }

  async listResourceTemplates(): Promise<McpAggregateResult<McpResourceTemplate>> {
    const promises: Promise<ServerCollection<McpResourceTemplate>>[] = [];
    this.servers.forEach((server: ManagedServer): void => {
      promises.push(this.collectResourceTemplates(server));
    });
    return this.combine(await Promise.all(promises));
  }

  async listPrompts(): Promise<McpAggregateResult<McpPrompt>> {
    const promises: Promise<ServerCollection<McpPrompt>>[] = [];
    this.servers.forEach((server: ManagedServer): void => {
      promises.push(this.collectPrompts(server));
    });
    return this.combine(await Promise.all(promises));
  }

  async callTool(ref: McpCapabilityRef, argumentsValue: Object,
    cancellation?: McpCancellationSignal): Promise<McpToolResult> {
    if (ref.kind !== McpCapabilityKind.TOOL) {
      throw new McpClientError(McpErrorCode.CONFIGURATION, 'Capability reference is not a tool', ref.serverId);
    }
    const server: ManagedServer = this.requireReadyServer(ref.serverId);
    let tool: McpTool | undefined = this.findTool(server, ref.name);
    if (tool === undefined) {
      await this.refreshTools(server);
      tool = this.findTool(server, ref.name);
    }
    if (tool === undefined) {
      throw new McpClientError(McpErrorCode.CONFIGURATION,
        `Unknown tool ${ref.name}`, ref.serverId);
    }
    if (this.options.invocationPolicy === undefined) {
      throw new McpClientError(McpErrorCode.POLICY_DENIED,
        'Tool calls are denied until an invocation policy is registered', ref.serverId);
    }
    let allowed: boolean = false;
    let reason: string | undefined = undefined;
    try {
      const decision = await this.options.invocationPolicy.authorize({
        profile: server.profile,
        tool: tool,
        arguments: argumentsValue
      });
      allowed = decision.allowed;
      reason = decision.reason;
    } catch (error) {
      throw new McpClientError(McpErrorCode.POLICY_DENIED,
        `Invocation policy failed closed: ${this.errorMessage(error)}`, ref.serverId);
    }
    if (!allowed) {
      throw new McpClientError(McpErrorCode.POLICY_DENIED,
        reason === undefined ? 'Tool call denied by invocation policy' : reason, ref.serverId);
    }
    return server.client.callTool(tool, argumentsValue, cancellation);
  }

  async readResource(ref: McpCapabilityRef): Promise<McpReadResourceResult> {
    if (ref.kind !== McpCapabilityKind.RESOURCE && ref.kind !== McpCapabilityKind.RESOURCE_TEMPLATE) {
      throw new McpClientError(McpErrorCode.CONFIGURATION,
        'Capability reference is not a resource', ref.serverId);
    }
    return this.requireReadyServer(ref.serverId).client.readResource(ref.name);
  }

  async getPrompt(ref: McpCapabilityRef, argumentsValue?: Object): Promise<McpGetPromptResult> {
    if (ref.kind !== McpCapabilityKind.PROMPT) {
      throw new McpClientError(McpErrorCode.CONFIGURATION,
        'Capability reference is not a prompt', ref.serverId);
    }
    return this.requireReadyServer(ref.serverId).client.getPrompt(ref.name, argumentsValue);
  }

  getConnections(): McpConnectionSnapshot[] {
    const snapshots: McpConnectionSnapshot[] = [];
    this.servers.forEach((server: ManagedServer): void => {
      snapshots.push(this.snapshot(server));
    });
    return snapshots;
  }

  addConnectionListener(listener: McpConnectionListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  removeConnectionListener(listener: McpConnectionListener): void {
    const index: number = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  private async connectOne(server: ManagedServer): Promise<ServerCollection<McpConnectionSnapshot>> {
    try {
      return { items: [await this.connect(server.profile.id)] };
    } catch (error) {
      return { items: [], error: this.failure(server.profile.id, error) };
    }
  }

  private async refreshOne(server: ManagedServer): Promise<ServerCollection<McpConnectionSnapshot>> {
    try {
      await this.refreshServer(server.profile.id);
      return { items: [this.snapshot(server)] };
    } catch (error) {
      return { items: [this.snapshot(server)], error: this.failure(server.profile.id, error) };
    }
  }

  private async collectTools(server: ManagedServer): Promise<ServerCollection<McpTool>> {
    try {
      this.requireReadyServer(server.profile.id);
      if (!server.client.hasCapability('tools')) {
        return { items: [] };
      }
      if (!server.toolsLoaded) {
        await this.refreshTools(server);
      }
      return { items: server.tools.slice() };
    } catch (error) {
      return { items: [], error: this.failure(server.profile.id, error) };
    }
  }

  private async collectResources(server: ManagedServer): Promise<ServerCollection<McpResource>> {
    try {
      this.requireReadyServer(server.profile.id);
      if (!server.client.hasCapability('resources')) {
        return { items: [] };
      }
      if (!server.resourcesLoaded) {
        await this.refreshResources(server);
      }
      return { items: server.resources.slice() };
    } catch (error) {
      return { items: [], error: this.failure(server.profile.id, error) };
    }
  }

  private async collectResourceTemplates(server: ManagedServer): Promise<ServerCollection<McpResourceTemplate>> {
    try {
      this.requireReadyServer(server.profile.id);
      if (!server.client.hasCapability('resources')) {
        return { items: [] };
      }
      if (!server.resourceTemplatesLoaded) {
        await this.refreshResourceTemplates(server);
      }
      return { items: server.resourceTemplates.slice() };
    } catch (error) {
      return { items: [], error: this.failure(server.profile.id, error) };
    }
  }

  private async collectPrompts(server: ManagedServer): Promise<ServerCollection<McpPrompt>> {
    try {
      this.requireReadyServer(server.profile.id);
      if (!server.client.hasCapability('prompts')) {
        return { items: [] };
      }
      if (!server.promptsLoaded) {
        await this.refreshPrompts(server);
      }
      return { items: server.prompts.slice() };
    } catch (error) {
      return { items: [], error: this.failure(server.profile.id, error) };
    }
  }

  private async refreshTools(server: ManagedServer): Promise<void> {
    server.tools = await server.client.listTools();
    server.toolsLoaded = true;
  }

  private async refreshResources(server: ManagedServer): Promise<void> {
    server.resources = await server.client.listResources();
    server.resourcesLoaded = true;
  }

  private async refreshResourceTemplates(server: ManagedServer): Promise<void> {
    server.resourceTemplates = await server.client.listResourceTemplates();
    server.resourceTemplatesLoaded = true;
  }

  private async refreshPrompts(server: ManagedServer): Promise<void> {
    server.prompts = await server.client.listPrompts();
    server.promptsLoaded = true;
  }

  private findTool(server: ManagedServer, name: string): McpTool | undefined {
    for (let index: number = 0; index < server.tools.length; index++) {
      if (server.tools[index].name === name) {
        return server.tools[index];
      }
    }
    return undefined;
  }

  private requireServer(serverId: string): ManagedServer {
    const server: ManagedServer | undefined = this.servers.get(serverId);
    if (server === undefined) {
      throw new McpClientError(McpErrorCode.CONFIGURATION,
        `Unknown server ${serverId}`, serverId);
    }
    return server;
  }

  private requireReadyServer(serverId: string): ManagedServer {
    const server: ManagedServer = this.requireServer(serverId);
    if (server.state !== McpConnectionState.READY && server.state !== McpConnectionState.DEGRADED) {
      throw new McpClientError(McpErrorCode.CONFIGURATION,
        `Server ${serverId} is not connected`, serverId);
    }
    return server;
  }

  private clearCatalog(server: ManagedServer): void {
    server.tools = [];
    server.resources = [];
    server.resourceTemplates = [];
    server.prompts = [];
    server.toolsLoaded = false;
    server.resourcesLoaded = false;
    server.resourceTemplatesLoaded = false;
    server.promptsLoaded = false;
  }

  private snapshot(server: ManagedServer): McpConnectionSnapshot {
    return {
      serverId: server.profile.id,
      state: server.state,
      era: server.info === undefined ? undefined : server.info.era,
      protocolVersion: server.info === undefined ? undefined : server.info.protocolVersion,
      serverInfo: server.info === undefined ? undefined : server.info.serverInfo,
      instructions: server.info === undefined ? undefined : server.info.instructions,
      lastError: server.lastError
    };
  }

  private emit(server: ManagedServer): void {
    const snapshot: McpConnectionSnapshot = this.snapshot(server);
    for (let index: number = 0; index < this.listeners.length; index++) {
      try {
        this.listeners[index](snapshot);
      } catch (_error) {
        // Observers cannot break connection lifecycle processing.
      }
    }
  }

  private combine<T>(collections: ServerCollection<T>[]): McpAggregateResult<T> {
    const items: T[] = [];
    const errors: McpServerFailure[] = [];
    for (let index: number = 0; index < collections.length; index++) {
      for (let itemIndex: number = 0; itemIndex < collections[index].items.length; itemIndex++) {
        items.push(collections[index].items[itemIndex]);
      }
      if (collections[index].error !== undefined) {
        errors.push(collections[index].error as McpServerFailure);
      }
    }
    return { items: items, errors: errors };
  }

  private failure(serverId: string, error: Object): McpServerFailure {
    if (error instanceof McpClientError) {
      return { serverId: serverId, code: error.code, message: error.message };
    }
    return { serverId: serverId, code: McpErrorCode.PROTOCOL, message: this.errorMessage(error) };
  }

  private errorMessage(error: Object): string {
    return error instanceof Error ? error.message : String(error);
  }

  private normalizeError(error: Object): Error {
    return error instanceof Error ? error : new Error(String(error));
  }
}
