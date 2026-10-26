import {
  DEFAULT_CONNECT_TIMEOUT_MS,
  DEFAULT_MAX_RESPONSE_BYTES,
  DEFAULT_REQUEST_TIMEOUT_MS,
  MCP_CLIENT_VERSION,
  MCP_LEGACY_PROTOCOL_VERSION,
  MCP_MODERN_PROTOCOL_VERSION
} from '../Constants';
import { McpClientError, McpErrorCode } from '../Errors';
import {
  McpAuthProvider,
  McpCancellationSignal,
  McpCapabilityKind,
  McpContentBlock,
  McpGetPromptResult,
  McpPrompt,
  McpPromptArgument,
  McpPromptMessage,
  McpProtocolEra,
  McpProtocolMode,
  McpReadResourceResult,
  McpResource,
  McpResourceTemplate,
  McpServerProfile,
  McpTool,
  McpToolResult
} from '../Types';
import { JsonRpcCodec, McpJsonRpcOutcome } from './JsonRpc';
import {
  ArkTsHttpTransport,
  McpHttpMethod,
  McpTransport,
  McpTransportRequest,
  McpTransportResponse
} from './Transport';
import util from '@ohos.util';

const MAX_LIST_PAGES: number = 100;
const MAX_SAFE_INTEGER: number = 9007199254740991;

interface ToolHeaderBinding {
  headerName: string;
  path: string[];
  parameterType: string;
}

export interface McpProtocolClientOptions {
  authProvider?: McpAuthProvider;
  clientName: string;
  clientVersion: string;
  debugBuild: boolean;
}

export interface McpProtocolConnectionInfo {
  era: McpProtocolEra;
  protocolVersion: string;
  serverInfo?: Object;
  instructions?: string;
  capabilities: Object;
}

export class McpProtocolClient {
  private readonly profile: McpServerProfile;
  private readonly options: McpProtocolClientOptions;
  private readonly transport: McpTransport;
  private requestId: number = 0;
  private connection?: McpProtocolConnectionInfo;
  private sessionId?: string;
  private readonly toolHeaderBindings: Map<string, ToolHeaderBinding[]> =
    new Map<string, ToolHeaderBinding[]>();

  constructor(profile: McpServerProfile, options: McpProtocolClientOptions,
    transport?: McpTransport) {
    this.profile = profile;
    this.options = options;
    this.transport = transport === undefined ? new ArkTsHttpTransport() : transport;
    this.validateProfile();
  }

  async connect(): Promise<McpProtocolConnectionInfo> {
    const mode: McpProtocolMode = this.profile.protocolMode === undefined ?
      McpProtocolMode.AUTO : this.profile.protocolMode;
    if (mode === McpProtocolMode.MODERN) {
      return this.connectModern();
    }
    if (mode === McpProtocolMode.LEGACY) {
      return this.connectLegacy();
    }
    try {
      return await this.connectModern();
    } catch (error) {
      if (!this.shouldFallbackToLegacy(error)) {
        throw this.normalizeError(error);
      }
      return this.connectLegacy();
    }
  }

  getConnectionInfo(): McpProtocolConnectionInfo | undefined {
    return this.connection;
  }

  hasCapability(name: string): boolean {
    if (this.connection === undefined) {
      return false;
    }
    const capabilities: Record<string, Object> = this.asRecord(this.connection.capabilities, 'capabilities');
    return capabilities[name] !== undefined;
  }

  async listTools(): Promise<McpTool[]> {
    this.requireCapability('tools');
    const records: Object[] = await this.collectPages('tools/list', 'tools', this.emptyRecord());
    const tools: McpTool[] = [];
    this.toolHeaderBindings.clear();
    for (let index: number = 0; index < records.length; index++) {
      const record: Record<string, Object> = this.asRecord(records[index], 'tool');
      const name: string = this.requiredString(record, 'name', 'tool');
      const inputSchema: Object = record['inputSchema'] === undefined ? this.emptyRecord() : record['inputSchema'];
      const bindings: ToolHeaderBinding[] | undefined = this.readToolHeaderBindings(inputSchema);
      if (bindings === undefined) {
        continue;
      }
      this.toolHeaderBindings.set(name, bindings);
      tools.push({
        ref: { serverId: this.profile.id, kind: McpCapabilityKind.TOOL, name: name },
        name: name,
        title: this.optionalString(record, 'title'),
        description: this.optionalString(record, 'description'),
        inputSchema: inputSchema,
        outputSchema: record['outputSchema'],
        annotations: record['annotations'],
        raw: records[index]
      });
    }
    return tools;
  }

  async listResources(): Promise<McpResource[]> {
    this.requireCapability('resources');
    const records: Object[] = await this.collectPages('resources/list', 'resources', this.emptyRecord());
    const resources: McpResource[] = [];
    for (let index: number = 0; index < records.length; index++) {
      const record: Record<string, Object> = this.asRecord(records[index], 'resource');
      const uri: string = this.requiredString(record, 'uri', 'resource');
      const name: string = this.requiredString(record, 'name', 'resource');
      resources.push({
        ref: { serverId: this.profile.id, kind: McpCapabilityKind.RESOURCE, name: uri },
        uri: uri,
        name: name,
        title: this.optionalString(record, 'title'),
        description: this.optionalString(record, 'description'),
        mimeType: this.optionalString(record, 'mimeType'),
        size: this.optionalNumber(record, 'size'),
        annotations: record['annotations'],
        raw: records[index]
      });
    }
    return resources;
  }

  async listResourceTemplates(): Promise<McpResourceTemplate[]> {
    this.requireCapability('resources');
    const records: Object[] = await this.collectPages('resources/templates/list', 'resourceTemplates',
      this.emptyRecord());
    const templates: McpResourceTemplate[] = [];
    for (let index: number = 0; index < records.length; index++) {
      const record: Record<string, Object> = this.asRecord(records[index], 'resource template');
      const uriTemplate: string = this.requiredString(record, 'uriTemplate', 'resource template');
      const name: string = this.requiredString(record, 'name', 'resource template');
      templates.push({
        ref: { serverId: this.profile.id, kind: McpCapabilityKind.RESOURCE_TEMPLATE, name: uriTemplate },
        uriTemplate: uriTemplate,
        name: name,
        title: this.optionalString(record, 'title'),
        description: this.optionalString(record, 'description'),
        mimeType: this.optionalString(record, 'mimeType'),
        annotations: record['annotations'],
        raw: records[index]
      });
    }
    return templates;
  }

  async listPrompts(): Promise<McpPrompt[]> {
    this.requireCapability('prompts');
    const records: Object[] = await this.collectPages('prompts/list', 'prompts', this.emptyRecord());
    const prompts: McpPrompt[] = [];
    for (let index: number = 0; index < records.length; index++) {
      const record: Record<string, Object> = this.asRecord(records[index], 'prompt');
      const name: string = this.requiredString(record, 'name', 'prompt');
      const argumentsValue: Object[] = this.optionalArray(record, 'arguments');
      const promptArguments: McpPromptArgument[] = [];
      for (let argumentIndex: number = 0; argumentIndex < argumentsValue.length; argumentIndex++) {
        const argument: Record<string, Object> = this.asRecord(argumentsValue[argumentIndex], 'prompt argument');
        promptArguments.push({
          name: this.requiredString(argument, 'name', 'prompt argument'),
          description: this.optionalString(argument, 'description'),
          required: this.optionalBoolean(argument, 'required')
        });
      }
      prompts.push({
        ref: { serverId: this.profile.id, kind: McpCapabilityKind.PROMPT, name: name },
        name: name,
        title: this.optionalString(record, 'title'),
        description: this.optionalString(record, 'description'),
        arguments: promptArguments,
        raw: records[index]
      });
    }
    return prompts;
  }

  async callTool(tool: McpTool, argumentsValue: Object,
    cancellation?: McpCancellationSignal): Promise<McpToolResult> {
    this.requireCapability('tools');
    const params: Record<string, Object> = this.emptyRecord();
    params['name'] = tool.name;
    params['arguments'] = argumentsValue;
    const additionalHeaders: Record<string, string> = this.toolArgumentHeaders(tool.name, argumentsValue);
    let result: Object;
    try {
      result = await this.request('tools/call', params, tool.name, false, additionalHeaders, cancellation);
    } catch (error) {
      if (!this.shouldRecoverExpiredToolSession(error)) throw this.normalizeError(error);
      this.throwIfCancelled(cancellation);
      this.connection = undefined;
      this.sessionId = undefined;
      await this.connectLegacy(cancellation);
      this.throwIfCancelled(cancellation);
      result = await this.request('tools/call', params, tool.name, false, additionalHeaders, cancellation);
    }
    const record: Record<string, Object> = this.asRecord(result, 'tool result');
    return {
      content: this.parseContentArray(this.optionalArray(record, 'content')),
      structuredContent: record['structuredContent'],
      isError: this.optionalBoolean(record, 'isError') === true,
      raw: result
    };
  }

  async readResource(uri: string): Promise<McpReadResourceResult> {
    this.requireCapability('resources');
    const params: Record<string, Object> = this.emptyRecord();
    params['uri'] = uri;
    const result: Object = await this.request('resources/read', params, uri, true);
    const record: Record<string, Object> = this.asRecord(result, 'resource result');
    return {
      contents: this.parseContentArray(this.optionalArray(record, 'contents')),
      raw: result
    };
  }

  async getPrompt(name: string, argumentsValue?: Object): Promise<McpGetPromptResult> {
    this.requireCapability('prompts');
    const params: Record<string, Object> = this.emptyRecord();
    params['name'] = name;
    if (argumentsValue !== undefined) {
      params['arguments'] = argumentsValue;
    }
    const result: Object = await this.request('prompts/get', params, name, true);
    const record: Record<string, Object> = this.asRecord(result, 'prompt result');
    const messageValues: Object[] = this.optionalArray(record, 'messages');
    const messages: McpPromptMessage[] = [];
    for (let index: number = 0; index < messageValues.length; index++) {
      const message: Record<string, Object> = this.asRecord(messageValues[index], 'prompt message');
      const contentRecord: Record<string, Object> = this.asRecord(message['content'], 'prompt content');
      messages.push({
        role: this.requiredString(message, 'role', 'prompt message'),
        content: this.parseContent(contentRecord)
      });
    }
    return {
      description: this.optionalString(record, 'description'),
      messages: messages,
      raw: result
    };
  }

  async close(): Promise<void> {
    const session: string | undefined = this.sessionId;
    this.connection = undefined;
    this.sessionId = undefined;
    this.transport.close();
    if (session !== undefined) {
      try {
        const headers: Record<string, string> = await this.baseHeaders('session/delete');
        headers['MCP-Protocol-Version'] = MCP_LEGACY_PROTOCOL_VERSION;
        headers['MCP-Session-Id'] = session;
        await this.transport.send(this.transportRequest(McpHttpMethod.DELETE, headers));
      } catch (_error) {
        // A server may reject session deletion with 405. Local cleanup still proceeds.
      }
    }
    this.transport.close();
  }

  private async connectModern(): Promise<McpProtocolConnectionInfo> {
    const result: Object = await this.requestWithEra('server/discover', this.emptyRecord(), undefined,
      McpProtocolEra.MODERN, MCP_MODERN_PROTOCOL_VERSION, false);
    const record: Record<string, Object> = this.asRecord(result, 'discover result');
    const versions: Object[] = this.optionalArray(record, 'supportedVersions');
    let supported: boolean = false;
    for (let index: number = 0; index < versions.length; index++) {
      if (String(versions[index]) === MCP_MODERN_PROTOCOL_VERSION) {
        supported = true;
      }
    }
    if (!supported) {
      throw new McpClientError(McpErrorCode.NEGOTIATION,
        `Server did not advertise ${MCP_MODERN_PROTOCOL_VERSION}`, this.profile.id);
    }
    const metadata: Record<string, Object> = record['_meta'] === undefined ? {} :
      this.asRecord(record['_meta'], 'discover metadata');
    this.connection = {
      era: McpProtocolEra.MODERN,
      protocolVersion: MCP_MODERN_PROTOCOL_VERSION,
      serverInfo: metadata['io.modelcontextprotocol/serverInfo'],
      instructions: this.optionalString(record, 'instructions'),
      capabilities: record['capabilities'] === undefined ? this.emptyRecord() : record['capabilities']
    };
    return this.connection;
  }

  private async connectLegacy(cancellation?: McpCancellationSignal): Promise<McpProtocolConnectionInfo> {
    const params: Record<string, Object> = this.emptyRecord();
    const clientInfo: Record<string, Object> = this.emptyRecord();
    clientInfo['name'] = this.options.clientName;
    clientInfo['version'] = this.options.clientVersion;
    params['protocolVersion'] = MCP_LEGACY_PROTOCOL_VERSION;
    params['capabilities'] = this.emptyRecord();
    params['clientInfo'] = clientInfo;
    const result: Object = await this.requestWithEra('initialize', params, undefined,
      McpProtocolEra.LEGACY, MCP_LEGACY_PROTOCOL_VERSION, false, true, undefined, cancellation);
    const record: Record<string, Object> = this.asRecord(result, 'initialize result');
    const negotiatedVersion: string = this.requiredString(record, 'protocolVersion', 'initialize result');
    if (negotiatedVersion !== MCP_LEGACY_PROTOCOL_VERSION) {
      throw new McpClientError(McpErrorCode.NEGOTIATION,
        `Server selected unsupported legacy version ${negotiatedVersion}`, this.profile.id);
    }
    this.connection = {
      era: McpProtocolEra.LEGACY,
      protocolVersion: negotiatedVersion,
      serverInfo: record['serverInfo'],
      instructions: this.optionalString(record, 'instructions'),
      capabilities: record['capabilities'] === undefined ? this.emptyRecord() : record['capabilities']
    };
    await this.sendInitializedNotification(cancellation);
    return this.connection;
  }

  private async sendInitializedNotification(cancellation?: McpCancellationSignal): Promise<void> {
    const headers: Record<string, string> = await this.baseHeaders('notifications/initialized');
    headers['Content-Type'] = 'application/json';
    headers['Accept'] = 'application/json, text/event-stream';
    headers['MCP-Protocol-Version'] = MCP_LEGACY_PROTOCOL_VERSION;
    if (this.sessionId !== undefined) {
      headers['MCP-Session-Id'] = this.sessionId;
    }
    const body: string = JsonRpcCodec.notification('notifications/initialized', this.emptyRecord());
    const response: McpTransportResponse = await this.transport.send(
      this.transportRequest(McpHttpMethod.POST, headers, body, cancellation));
    if (response.statusCode === 401 || response.statusCode === 403 || response.statusCode >= 500) {
      throw this.httpError(response.statusCode, 'notifications/initialized');
    }
  }

  private async collectPages(method: string, field: string, initialParams: Object): Promise<Object[]> {
    const items: Object[] = [];
    let cursor: string | undefined = undefined;
    let page: number = 0;
    const seenCursors: Set<string> = new Set<string>();
    do {
      const params: Record<string, Object> = this.cloneRecord(initialParams);
      if (cursor !== undefined) {
        params['cursor'] = cursor;
      }
      const result: Object = await this.request(method, params, undefined, true);
      const record: Record<string, Object> = this.asRecord(result, `${method} result`);
      const pageItems: Object[] = this.optionalArray(record, field);
      for (let index: number = 0; index < pageItems.length; index++) {
        items.push(pageItems[index]);
      }
      cursor = this.optionalString(record, 'nextCursor');
      if (cursor !== undefined) {
        if (seenCursors.has(cursor)) {
          throw new McpClientError(McpErrorCode.PROTOCOL,
            `${method} returned a repeated cursor`, this.profile.id);
        }
        seenCursors.add(cursor);
      }
      page += 1;
      if (page >= MAX_LIST_PAGES && cursor !== undefined) {
        throw new McpClientError(McpErrorCode.PROTOCOL,
          `${method} exceeded ${MAX_LIST_PAGES} pages`, this.profile.id);
      }
    } while (cursor !== undefined);
    return items;
  }

  private async request(method: string, params: Object, name: string | undefined,
    safeToRetry: boolean, additionalHeaders?: Record<string, string>,
    cancellation?: McpCancellationSignal): Promise<Object> {
    if (this.connection === undefined) {
      throw new McpClientError(McpErrorCode.CONFIGURATION,
        'MCP server is not connected', this.profile.id);
    }
    return this.requestWithEra(method, params, name, this.connection.era,
      this.connection.protocolVersion, safeToRetry, false, additionalHeaders, cancellation);
  }

  private async requestWithEra(method: string, params: Object, name: string | undefined,
    era: McpProtocolEra, protocolVersion: string, safeToRetry: boolean,
    initializeRequest: boolean = false, additionalHeaders?: Record<string, string>,
    cancellation?: McpCancellationSignal): Promise<Object> {
    let attempt: number = 0;
    while (true) {
      try {
        return await this.requestOnce(method, params, name, era, protocolVersion, initializeRequest,
          additionalHeaders, cancellation);
      } catch (error) {
        if (!safeToRetry || attempt > 0 || !this.isRetryable(error)) {
          throw this.normalizeError(error);
        }
        attempt += 1;
      }
    }
  }

  private async requestOnce(method: string, params: Object, name: string | undefined,
    era: McpProtocolEra, protocolVersion: string, initializeRequest: boolean,
    additionalHeaders?: Record<string, string>, cancellation?: McpCancellationSignal): Promise<Object> {
    this.throwIfCancelled(cancellation);
    this.requestId += 1;
    const id: number = this.requestId;
    const wireParams: Record<string, Object> = this.cloneRecord(params);
    if (era === McpProtocolEra.MODERN) {
      const clientInfo: Record<string, Object> = this.emptyRecord();
      clientInfo['name'] = this.options.clientName;
      clientInfo['version'] = this.options.clientVersion;
      const metadata: Record<string, Object> = this.emptyRecord();
      metadata['io.modelcontextprotocol/protocolVersion'] = protocolVersion;
      metadata['io.modelcontextprotocol/clientInfo'] = clientInfo;
      metadata['io.modelcontextprotocol/clientCapabilities'] = this.emptyRecord();
      wireParams['_meta'] = metadata;
    }
    const headers: Record<string, string> = await this.baseHeaders(method);
    headers['Content-Type'] = 'application/json';
    headers['Accept'] = 'application/json, text/event-stream';
    if (!initializeRequest || era === McpProtocolEra.MODERN) {
      headers['MCP-Protocol-Version'] = protocolVersion;
    }
    if (era === McpProtocolEra.MODERN) {
      headers['Mcp-Method'] = method;
      if (name !== undefined) {
        headers['Mcp-Name'] = this.encodeHeaderValue(name);
      }
      if (additionalHeaders !== undefined) {
        const headerNames: string[] = Object.keys(additionalHeaders);
        for (let index: number = 0; index < headerNames.length; index++) {
          headers[headerNames[index]] = additionalHeaders[headerNames[index]];
        }
      }
    } else if (this.sessionId !== undefined) {
      headers['MCP-Session-Id'] = this.sessionId;
    }
    const body: string = JsonRpcCodec.request(id, method, wireParams);
    const response: McpTransportResponse = await this.transport.send(
      this.transportRequest(McpHttpMethod.POST, headers, body, cancellation));
    if (initializeRequest) {
      const session: string | undefined = response.headers['mcp-session-id'];
      if (session !== undefined && session.length > 0) {
        this.sessionId = session;
      }
    }
    if (response.statusCode === 401 || response.statusCode === 403 || response.statusCode >= 500) {
      throw this.httpError(response.statusCode, method);
    }
    let outcome: McpJsonRpcOutcome;
    try {
      outcome = JsonRpcCodec.decode(response, id);
    } catch (error) {
      if (response.statusCode >= 400) {
        throw new McpClientError(McpErrorCode.PROTOCOL,
          `HTTP ${response.statusCode} returned no valid JSON-RPC error for ${method}`,
          this.profile.id, response.statusCode);
      }
      throw this.normalizeError(error);
    }
    if (outcome.error !== undefined) {
      throw new McpClientError(McpErrorCode.JSON_RPC,
        outcome.error.message, this.profile.id, response.statusCode,
        outcome.error.code, outcome.error.data);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw this.httpError(response.statusCode, method);
    }
    if (outcome.result === undefined) {
      throw new McpClientError(McpErrorCode.PROTOCOL,
        `Missing JSON-RPC result for ${method}`, this.profile.id, response.statusCode);
    }
    return outcome.result;
  }

  private async baseHeaders(operation: string): Promise<Record<string, string>> {
    const headers: Record<string, string> = {};
    if (this.options.authProvider === undefined) {
      return headers;
    }
    let authHeaders: Record<string, string>;
    try {
      authHeaders = await this.options.authProvider.getHeaders(this.profile, operation);
    } catch (_error) {
      throw new McpClientError(McpErrorCode.AUTHENTICATION,
        'Authentication provider failed', this.profile.id);
    }
    const keys: string[] = Object.keys(authHeaders);
    for (let index: number = 0; index < keys.length; index++) {
      const key: string = keys[index];
      if (this.isReservedHeader(key)) {
        throw new McpClientError(McpErrorCode.CONFIGURATION,
          `Authentication provider cannot override ${key}`, this.profile.id);
      }
      headers[key] = authHeaders[key];
    }
    return headers;
  }

  private transportRequest(method: McpHttpMethod, headers: Record<string, string>,
    body?: string, cancellation?: McpCancellationSignal): McpTransportRequest {
    return {
      endpoint: this.profile.endpoint,
      method: method,
      headers: headers,
      body: body,
      connectTimeoutMs: this.profile.connectTimeoutMs === undefined ?
        DEFAULT_CONNECT_TIMEOUT_MS : this.profile.connectTimeoutMs,
      requestTimeoutMs: this.profile.requestTimeoutMs === undefined ?
        DEFAULT_REQUEST_TIMEOUT_MS : this.profile.requestTimeoutMs,
      maxResponseBytes: this.profile.maxResponseBytes === undefined ?
        DEFAULT_MAX_RESPONSE_BYTES : this.profile.maxResponseBytes,
      cancellation: cancellation
    };
  }

  private shouldRecoverExpiredToolSession(error: Object): boolean {
    return this.profile.retryToolCallOnExpiredSession === true &&
      this.connection !== undefined && this.connection.era === McpProtocolEra.LEGACY &&
      error instanceof McpClientError && error.statusCode === 404;
  }

  private throwIfCancelled(cancellation?: McpCancellationSignal): void {
    if (cancellation !== undefined && cancellation.isCancellationRequested()) {
      throw new McpClientError(McpErrorCode.CANCELLED, 'MCP request was cancelled', this.profile.id);
    }
  }

  private requireCapability(name: string): void {
    if (this.connection === undefined) {
      throw new McpClientError(McpErrorCode.CONFIGURATION,
        'MCP server is not connected', this.profile.id);
    }
    const capabilities: Record<string, Object> = this.asRecord(this.connection.capabilities, 'capabilities');
    if (capabilities[name] === undefined) {
      throw new McpClientError(McpErrorCode.UNSUPPORTED,
        `Server does not advertise ${name}`, this.profile.id);
    }
  }

  private shouldFallbackToLegacy(error: Object): boolean {
    if (!(error instanceof McpClientError)) {
      return false;
    }
    if (error.code === McpErrorCode.AUTHENTICATION || error.code === McpErrorCode.FORBIDDEN ||
      error.code === McpErrorCode.NETWORK || error.code === McpErrorCode.TIMEOUT) {
      return false;
    }
    if (error.rpcCode === -32020 || error.rpcCode === -32021 || error.rpcCode === -32022) {
      return false;
    }
    return error.rpcCode === -32601 || error.statusCode === 404 ||
      error.code === McpErrorCode.NEGOTIATION;
  }

  private isRetryable(error: Object): boolean {
    return error instanceof McpClientError &&
      error.statusCode === undefined &&
      (error.code === McpErrorCode.NETWORK || error.code === McpErrorCode.TIMEOUT);
  }

  private httpError(statusCode: number, operation: string): McpClientError {
    let code: McpErrorCode = McpErrorCode.PROTOCOL;
    if (statusCode === 401) {
      code = McpErrorCode.AUTHENTICATION;
    } else if (statusCode === 403) {
      code = McpErrorCode.FORBIDDEN;
    } else if (statusCode >= 500) {
      code = McpErrorCode.NETWORK;
    }
    return new McpClientError(code, `HTTP ${statusCode} for ${operation}`,
      this.profile.id, statusCode);
  }

  private validateProfile(): void {
    if (this.profile.id.trim().length === 0) {
      throw new McpClientError(McpErrorCode.CONFIGURATION, 'Server id is required');
    }
    const endpoint: string = this.profile.endpoint.trim();
    const isHttps: boolean = endpoint.startsWith('https://');
    const isHttp: boolean = endpoint.startsWith('http://');
    if ((!isHttps && !isHttp) || endpoint.indexOf('://') + 3 >= endpoint.length) {
      throw new McpClientError(McpErrorCode.CONFIGURATION,
        'Server endpoint must be an absolute HTTP(S) URL', this.profile.id);
    }
    if (isHttp && (!this.options.debugBuild || this.profile.allowInsecureHttp !== true)) {
      throw new McpClientError(McpErrorCode.CONFIGURATION,
        'Cleartext HTTP requires a debug build and allowInsecureHttp=true', this.profile.id);
    }
    if (this.profile.connectTimeoutMs !== undefined && this.profile.connectTimeoutMs <= 0) {
      throw new McpClientError(McpErrorCode.CONFIGURATION,
        'connectTimeoutMs must be greater than zero', this.profile.id);
    }
    if (this.profile.requestTimeoutMs !== undefined && this.profile.requestTimeoutMs <= 0) {
      throw new McpClientError(McpErrorCode.CONFIGURATION,
        'requestTimeoutMs must be greater than zero', this.profile.id);
    }
    if (this.profile.maxResponseBytes !== undefined && this.profile.maxResponseBytes <= 0) {
      throw new McpClientError(McpErrorCode.CONFIGURATION,
        'maxResponseBytes must be greater than zero', this.profile.id);
    }
  }

  private emptyRecord(): Record<string, Object> {
    return new Object() as Record<string, Object>;
  }

  private cloneRecord(value: Object): Record<string, Object> {
    const source: Record<string, Object> = this.asRecord(value, 'request parameters');
    const result: Record<string, Object> = this.emptyRecord();
    const keys: string[] = Object.keys(source);
    for (let index: number = 0; index < keys.length; index++) {
      result[keys[index]] = source[keys[index]];
    }
    return result;
  }

  private normalizeError(value: Object): Error {
    if (value instanceof Error) {
      return value;
    }
    return new Error(String(value));
  }

  private isReservedHeader(name: string): boolean {
    const normalized: string = name.toLowerCase();
    return normalized === 'content-type' || normalized === 'accept' ||
      normalized === 'mcp-protocol-version' || normalized === 'mcp-session-id' ||
      normalized === 'mcp-method' || normalized === 'mcp-name' ||
      normalized.startsWith('mcp-param-');
  }

  private encodeHeaderValue(value: string): string {
    let safe: boolean = value.length > 0 && value.trim() === value &&
      !(value.startsWith('=?base64?') && value.endsWith('?='));
    for (let index: number = 0; index < value.length; index++) {
      const code: number = value.charCodeAt(index);
      if ((code < 0x20 && code !== 0x09) || code > 0x7e) {
        safe = false;
      }
    }
    if (safe) {
      return value;
    }
    const encoder: util.TextEncoder = new util.TextEncoder('utf-8');
    const encoded: Uint8Array = encoder.encodeInto(value);
    const base64: string = new util.Base64Helper().encodeToStringSync(encoded, util.Type.BASIC);
    return `=?base64?${base64}?=`;
  }

  private readToolHeaderBindings(inputSchema: Object): ToolHeaderBinding[] | undefined {
    const bindings: ToolHeaderBinding[] = [];
    const names: Set<string> = new Set<string>();
    if (!this.scanToolSchema(inputSchema, [], false, bindings, names)) {
      return undefined;
    }
    return bindings;
  }

  private scanToolSchema(value: Object, path: string[], reachableProperty: boolean,
    bindings: ToolHeaderBinding[], names: Set<string>): boolean {
    if (Array.isArray(value)) {
      const values: Object[] = value as Object[];
      for (let index: number = 0; index < values.length; index++) {
        if (!this.scanToolSchema(values[index], path, false, bindings, names)) {
          return false;
        }
      }
      return true;
    }
    if (value === null || typeof value !== 'object') {
      return true;
    }
    const schema: Record<string, Object> = value as Record<string, Object>;
    const annotation: Object | undefined = schema['x-mcp-header'];
    if (annotation !== undefined) {
      const parameterType: Object | undefined = schema['type'];
      if (!reachableProperty || path.length === 0 || typeof annotation !== 'string' ||
        annotation.length === 0 || !this.isHttpToken(annotation) ||
        (parameterType !== 'string' && parameterType !== 'integer' && parameterType !== 'boolean')) {
        return false;
      }
      const normalized: string = annotation.toLowerCase();
      if (names.has(normalized)) {
        return false;
      }
      names.add(normalized);
      bindings.push({ headerName: annotation, path: path.slice(), parameterType: String(parameterType) });
    }

    const keys: string[] = Object.keys(schema);
    for (let index: number = 0; index < keys.length; index++) {
      const key: string = keys[index];
      const child: Object = schema[key];
      if (key === 'properties' && child !== null && typeof child === 'object' && !Array.isArray(child)) {
        const properties: Record<string, Object> = child as Record<string, Object>;
        const propertyNames: string[] = Object.keys(properties);
        for (let propertyIndex: number = 0; propertyIndex < propertyNames.length; propertyIndex++) {
          const propertyName: string = propertyNames[propertyIndex];
          const propertyPath: string[] = path.slice();
          propertyPath.push(propertyName);
          if (!this.scanToolSchema(properties[propertyName], propertyPath, true, bindings, names)) {
            return false;
          }
        }
      } else if (key !== 'x-mcp-header' && child !== null && typeof child === 'object') {
        if (!this.scanToolSchema(child, path, false, bindings, names)) {
          return false;
        }
      }
    }
    return true;
  }

  private toolArgumentHeaders(toolName: string, argumentsValue: Object): Record<string, string> {
    const headers: Record<string, string> = {};
    if (this.connection === undefined || this.connection.era !== McpProtocolEra.MODERN) {
      return headers;
    }
    const bindings: ToolHeaderBinding[] | undefined = this.toolHeaderBindings.get(toolName);
    if (bindings === undefined) {
      return headers;
    }
    for (let index: number = 0; index < bindings.length; index++) {
      const binding: ToolHeaderBinding = bindings[index];
      const value: Object | undefined = this.valueAtPath(argumentsValue, binding.path);
      if (value === undefined || value === null) {
        continue;
      }
      if (!this.matchesHeaderType(value, binding.parameterType)) {
        throw new McpClientError(McpErrorCode.CONFIGURATION,
          `Tool argument ${binding.path.join('.')} does not match its x-mcp-header type`, this.profile.id);
      }
      headers[`Mcp-Param-${binding.headerName}`] = this.encodeHeaderValue(String(value));
    }
    return headers;
  }

  private valueAtPath(value: Object, path: string[]): Object | undefined {
    let current: Object | undefined = value;
    for (let index: number = 0; index < path.length; index++) {
      if (current === undefined || current === null || typeof current !== 'object' || Array.isArray(current)) {
        return undefined;
      }
      const record: Record<string, Object> = current as Record<string, Object>;
      current = record[path[index]];
    }
    return current;
  }

  private matchesHeaderType(value: Object, parameterType: string): boolean {
    if (parameterType === 'string') {
      return typeof value === 'string';
    }
    if (parameterType === 'boolean') {
      return typeof value === 'boolean';
    }
    return typeof value === 'number' && Number.isInteger(value) &&
      value >= -MAX_SAFE_INTEGER && value <= MAX_SAFE_INTEGER;
  }

  private isHttpToken(value: string): boolean {
    for (let index: number = 0; index < value.length; index++) {
      const character: string = value.charAt(index);
      const code: number = value.charCodeAt(index);
      const alphaNumeric: boolean = (code >= 0x30 && code <= 0x39) ||
        (code >= 0x41 && code <= 0x5a) || (code >= 0x61 && code <= 0x7a);
      if (!alphaNumeric && "!#$%&'*+-.^_`|~".indexOf(character) < 0) {
        return false;
      }
    }
    return value.length > 0;
  }

  private parseContentArray(values: Object[]): McpContentBlock[] {
    const content: McpContentBlock[] = [];
    for (let index: number = 0; index < values.length; index++) {
      content.push(this.parseContent(this.asRecord(values[index], 'content block')));
    }
    return content;
  }

  private parseContent(record: Record<string, Object>): McpContentBlock {
    return {
      type: this.requiredString(record, 'type', 'content block'),
      text: this.optionalString(record, 'text'),
      data: this.optionalString(record, 'data'),
      mimeType: this.optionalString(record, 'mimeType'),
      uri: this.optionalString(record, 'uri'),
      name: this.optionalString(record, 'name'),
      title: this.optionalString(record, 'title'),
      resource: record['resource'],
      raw: record
    };
  }

  private asRecord(value: Object | undefined, context: string): Record<string, Object> {
    if (value === undefined || value === null || Array.isArray(value) || typeof value !== 'object') {
      throw new McpClientError(McpErrorCode.PROTOCOL,
        `Expected ${context} to be an object`, this.profile.id);
    }
    return value as Record<string, Object>;
  }

  private optionalArray(record: Record<string, Object>, key: string): Object[] {
    const value: Object | undefined = record[key];
    if (value === undefined) {
      return [];
    }
    if (!Array.isArray(value)) {
      throw new McpClientError(McpErrorCode.PROTOCOL,
        `Expected ${key} to be an array`, this.profile.id);
    }
    return value as Object[];
  }

  private requiredString(record: Record<string, Object>, key: string, context: string): string {
    const value: Object | undefined = record[key];
    if (typeof value !== 'string' || value.length === 0) {
      throw new McpClientError(McpErrorCode.PROTOCOL,
        `Expected ${context}.${key} to be a non-empty string`, this.profile.id);
    }
    return value;
  }

  private optionalString(record: Record<string, Object>, key: string): string | undefined {
    const value: Object | undefined = record[key];
    if (value === undefined) {
      return undefined;
    }
    if (typeof value !== 'string') {
      throw new McpClientError(McpErrorCode.PROTOCOL,
        `Expected ${key} to be a string`, this.profile.id);
    }
    return value;
  }

  private optionalNumber(record: Record<string, Object>, key: string): number | undefined {
    const value: Object | undefined = record[key];
    if (value === undefined) {
      return undefined;
    }
    if (typeof value !== 'number') {
      throw new McpClientError(McpErrorCode.PROTOCOL,
        `Expected ${key} to be a number`, this.profile.id);
    }
    return value;
  }

  private optionalBoolean(record: Record<string, Object>, key: string): boolean | undefined {
    const value: Object | undefined = record[key];
    if (value === undefined) {
      return undefined;
    }
    if (typeof value !== 'boolean') {
      throw new McpClientError(McpErrorCode.PROTOCOL,
        `Expected ${key} to be a boolean`, this.profile.id);
    }
    return value;
  }
}

