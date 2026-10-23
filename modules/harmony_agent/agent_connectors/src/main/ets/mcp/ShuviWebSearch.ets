import {
  DataBoundary,
  RiskLevel
} from '@harmony_agent/agent-contracts';
import {
  McpAggregateResult,
  McpCancellationSignal,
  McpCapabilityKind,
  McpCapabilityRef,
  McpClientError,
  McpClientManager,
  McpErrorCode,
  McpProtocolMode,
  McpServerProfile,
  McpTool,
  McpToolResult
} from '@harmony_agent/mcp-client';
import { canonicalJson } from './CanonicalJson';
import { McpClientToolPort, McpReadOnlyToolPolicy } from './McpConnectorTypes';
import { McpProviderRegistry } from './McpProviderRegistry';
import { McpReadOnlyToolPolicyRegistry } from './McpToolPolicyRegistry';

export const SHUVI_WEB_SEARCH_SERVER_ID: string = 'shuvi-web-search';
export const SHUVI_WEB_SEARCH_TOOL_NAME: string = 'web_search';
export const SHUVI_WEB_SEARCH_PROFILE_VERSION: string = 'shuvi-search-mcp/0.1.0';

export class ShuviWebSearchMcpConfig {
  endpoint: string = 'http://127.0.0.1:8787/mcp';
  allowInsecureHttp: boolean = true;
  connectTimeoutMs: number = 5000;
  requestTimeoutMs: number = 20000;
  maxResponseBytes: number = 524288;
  estimatedCostMicros: number = 0;
  profileVersion: string = SHUVI_WEB_SEARCH_PROFILE_VERSION;
}

function asRecord(value: Object | undefined): Record<string, Object> | undefined {
  if (value === undefined || value === null || typeof value !== 'object' || Array.isArray(value)) return undefined;
  return value as Record<string, Object>;
}

function hasExactKeys(value: Record<string, Object>, expected: string[]): boolean {
  const keys: string[] = Object.keys(value);
  if (keys.length !== expected.length) return false;
  for (let index: number = 0; index < keys.length; index++) {
    if (expected.indexOf(keys[index]) < 0) return false;
  }
  return true;
}

function unicodeLength(value: string): number {
  let count: number = 0;
  for (let index: number = 0; index < value.length; index++) {
    const code: number = value.charCodeAt(index);
    if (code >= 0xD800 && code <= 0xDBFF && index + 1 < value.length) {
      const low: number = value.charCodeAt(index + 1);
      if (low >= 0xDC00 && low <= 0xDFFF) index++;
    }
    count++;
  }
  return count;
}

function validHttpUrl(value: string): boolean {
  if (value.length === 0 || value.length > 2048 || /[\u0000-\u0020]/.test(value)) return false;
  const lower: string = value.toLowerCase();
  let authorityStart: number = -1;
  if (lower.startsWith('https://')) authorityStart = 8;
  else if (lower.startsWith('http://')) authorityStart = 7;
  if (authorityStart < 0) return false;
  let authorityEnd: number = value.indexOf('/', authorityStart);
  if (authorityEnd < 0) authorityEnd = value.length;
  const authority: string = value.substring(authorityStart, authorityEnd);
  return authority.length > 0 && authority.indexOf('@') < 0;
}

function validUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

function validSearchedAt(value: string): boolean {
  return /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{3})?Z$/.test(value) &&
    !Number.isNaN(Date.parse(value));
}

function validateArguments(argumentsValue: Object): void {
  const record: Record<string, Object> | undefined = asRecord(argumentsValue);
  if (record === undefined || !hasExactKeys(record,
    record['maxResults'] === undefined ? ['query'] : ['query', 'maxResults'])) {
    throw new McpClientError(McpErrorCode.INVALID_ARGUMENT,
      'web_search arguments must contain only query and optional maxResults', SHUVI_WEB_SEARCH_SERVER_ID);
  }
  const query: Object = record['query'];
  if (typeof query !== 'string' || query.trim().length === 0 || unicodeLength(query.trim()) > 500) {
    throw new McpClientError(McpErrorCode.INVALID_ARGUMENT,
      'web_search query must contain 1 to 500 Unicode code points', SHUVI_WEB_SEARCH_SERVER_ID);
  }
  const maxResults: Object = record['maxResults'];
  if (maxResults !== undefined && (typeof maxResults !== 'number' || !Number.isSafeInteger(maxResults) ||
    maxResults < 1 || maxResults > 10)) {
    throw new McpClientError(McpErrorCode.INVALID_ARGUMENT,
      'web_search maxResults must be an integer from 1 to 10', SHUVI_WEB_SEARCH_SERVER_ID);
  }
}

function validateSource(value: Object): boolean {
  const source: Record<string, Object> | undefined = asRecord(value);
  if (source === undefined || !hasExactKeys(source, ['title', 'url', 'snippet'])) return false;
  const title: Object = source['title'];
  const url: Object = source['url'];
  const snippet: Object = source['snippet'];
  return typeof title === 'string' && title.trim().length > 0 && title.length <= 512 &&
    typeof url === 'string' && validHttpUrl(url) &&
    typeof snippet === 'string' && snippet.length <= 8000;
}

function validateSuccess(result: McpToolResult, argumentsValue: Object): void {
  const argumentsRecord: Record<string, Object> = argumentsValue as Record<string, Object>;
  const expectedQuery: string = (argumentsRecord['query'] as string).trim();
  const expectedMaximum: number = argumentsRecord['maxResults'] === undefined ? 5 :
    argumentsRecord['maxResults'] as number;
  const value: Record<string, Object> | undefined = asRecord(result.structuredContent);
  if (value === undefined || !hasExactKeys(value,
    ['schemaVersion', 'requestId', 'provider', 'query', 'searchedAt', 'results']) ||
    value['schemaVersion'] !== '1.0' || value['provider'] !== 'tavily' ||
    typeof value['requestId'] !== 'string' || !validUuid(value['requestId'] as string) ||
    typeof value['query'] !== 'string' || value['query'] !== expectedQuery ||
    typeof value['searchedAt'] !== 'string' ||
    !validSearchedAt(value['searchedAt'] as string) || !Array.isArray(value['results']) ||
    (value['results'] as Object[]).length > expectedMaximum) {
    throw new McpClientError(McpErrorCode.SCHEMA_MISMATCH,
      'web_search returned an invalid success envelope', SHUVI_WEB_SEARCH_SERVER_ID);
  }
  const sources: Object[] = value['results'] as Object[];
  for (let index: number = 0; index < sources.length; index++) {
    if (!validateSource(sources[index])) {
      throw new McpClientError(McpErrorCode.SCHEMA_MISMATCH,
        'web_search returned an invalid source item', SHUVI_WEB_SEARCH_SERVER_ID);
    }
  }
  const expected: string = canonicalJson(value);
  let equivalentText: boolean = false;
  for (let index: number = 0; index < result.content.length; index++) {
    const text: string | undefined = result.content[index].text;
    if (result.content[index].type === 'text' && text !== undefined) {
      try {
        const parsed: Object = JSON.parse(text) as Object;
        if (canonicalJson(parsed) === expected) equivalentText = true;
      } catch (_error) {
        // Keep looking for the required equivalent JSON text block.
      }
    }
  }
  if (!equivalentText) {
    throw new McpClientError(McpErrorCode.SCHEMA_MISMATCH,
      'web_search content does not match structuredContent', SHUVI_WEB_SEARCH_SERVER_ID);
  }
}

function validAdvertisedTool(tool: McpTool): boolean {
  if (tool.ref.serverId !== SHUVI_WEB_SEARCH_SERVER_ID || tool.ref.kind !== McpCapabilityKind.TOOL ||
    tool.name !== SHUVI_WEB_SEARCH_TOOL_NAME || tool.ref.name !== tool.name || tool.outputSchema === undefined) {
    return false;
  }
  const schema: Record<string, Object> | undefined = asRecord(tool.inputSchema);
  const properties: Record<string, Object> | undefined = schema === undefined ? undefined :
    asRecord(schema['properties']);
  const query: Record<string, Object> | undefined = properties === undefined ? undefined :
    asRecord(properties['query']);
  const maxResults: Record<string, Object> | undefined = properties === undefined ? undefined :
    asRecord(properties['maxResults']);
  const required: Object = schema === undefined ? [] : schema['required'];
  return schema !== undefined && schema['type'] === 'object' && schema['additionalProperties'] === false &&
    properties !== undefined && hasExactKeys(properties, ['query', 'maxResults']) &&
    query !== undefined && query['type'] === 'string' &&
    maxResults !== undefined && maxResults['type'] === 'integer' &&
    maxResults['minimum'] === 1 && maxResults['maximum'] === 10 && maxResults['default'] === 5 &&
    Array.isArray(required) && (required as Object[]).indexOf('query') >= 0;
}

/** Enforces the Shuvi web_search input and success-output contract at the Agent boundary. */
export class ShuviWebSearchMcpClientToolPort implements McpClientToolPort {
  private readonly delegate: McpClientToolPort;

  constructor(delegate: McpClientToolPort) {
    this.delegate = delegate;
  }

  listTools(): Promise<McpAggregateResult<McpTool>> {
    return this.delegate.listTools();
  }

  async callTool(ref: McpCapabilityRef, argumentsValue: Object,
    cancellation?: McpCancellationSignal): Promise<McpToolResult> {
    if (ref.serverId === SHUVI_WEB_SEARCH_SERVER_ID && ref.kind === McpCapabilityKind.TOOL &&
      ref.name === SHUVI_WEB_SEARCH_TOOL_NAME) {
      validateArguments(argumentsValue);
    }
    const result: McpToolResult = await this.delegate.callTool(ref, argumentsValue, cancellation);
    if (ref.serverId === SHUVI_WEB_SEARCH_SERVER_ID && ref.kind === McpCapabilityKind.TOOL &&
      ref.name === SHUVI_WEB_SEARCH_TOOL_NAME && !result.isError) {
      validateSuccess(result, argumentsValue);
    }
    return result;
  }
}

export function createShuviWebSearchProfile(config: ShuviWebSearchMcpConfig): McpServerProfile {
  return {
    id: SHUVI_WEB_SEARCH_SERVER_ID,
    endpoint: config.endpoint,
    displayName: 'Shuvi 联网搜索',
    protocolMode: McpProtocolMode.LEGACY,
    connectTimeoutMs: config.connectTimeoutMs,
    requestTimeoutMs: config.requestTimeoutMs,
    maxResponseBytes: config.maxResponseBytes,
    allowInsecureHttp: config.allowInsecureHttp,
    retryToolCallOnExpiredSession: true
  };
}

export function createShuviWebSearchPolicy(config: ShuviWebSearchMcpConfig): McpReadOnlyToolPolicy {
  const policy: McpReadOnlyToolPolicy = new McpReadOnlyToolPolicy();
  policy.serverId = SHUVI_WEB_SEARCH_SERVER_ID;
  policy.toolName = SHUVI_WEB_SEARCH_TOOL_NAME;
  policy.capabilityTags = ['web-search', 'public-web', 'read-only'];
  policy.permissionRequirements = ['network.search.public'];
  policy.riskLevel = RiskLevel.LOW;
  policy.dataBoundary = DataBoundary.REMOTE_ALLOWED;
  policy.latencyClass = 'network';
  policy.costClass = 'provider';
  policy.estimatedCostMicros = config.estimatedCostMicros;
  return policy;
}

/** Registers, connects and discovers the one controlled Shuvi search tool. */
export async function connectShuviWebSearchMcp(manager: McpClientManager,
  providers: McpProviderRegistry, policies: McpReadOnlyToolPolicyRegistry,
  config: ShuviWebSearchMcpConfig): Promise<McpServerProfile> {
  const profile: McpServerProfile = createShuviWebSearchProfile(config);
  if (config.profileVersion.trim().length === 0 || config.requestTimeoutMs <= 15000 ||
    config.maxResponseBytes < 524288 || !Number.isSafeInteger(config.estimatedCostMicros) ||
    config.estimatedCostMicros < 0) {
    throw new McpClientError(McpErrorCode.CONFIGURATION,
      'Invalid Shuvi web search MCP configuration', profile.id);
  }
  manager.registerServer(profile);
  try {
    await manager.connect(profile.id);
    await manager.refreshServer(profile.id);
    const catalog: McpAggregateResult<McpTool> = await manager.listTools();
    let matching: number = 0;
    for (let index: number = 0; index < catalog.items.length; index++) {
      if (catalog.items[index].ref.serverId === profile.id) {
        if (!validAdvertisedTool(catalog.items[index])) {
          throw new McpClientError(McpErrorCode.SCHEMA_MISMATCH,
            'Shuvi web search advertised an incompatible tool contract', profile.id);
        }
        matching++;
      }
    }
    if (matching !== 1) {
      throw new McpClientError(McpErrorCode.SCHEMA_MISMATCH,
        'Shuvi web search must advertise exactly one compatible web_search tool', profile.id);
    }
    if (!providers.register(profile, config.profileVersion) ||
      !policies.register(createShuviWebSearchPolicy(config))) {
      throw new McpClientError(McpErrorCode.CONFIGURATION,
        'Unable to register Shuvi web search policy', profile.id);
    }
    return profile;
  } catch (error) {
    try {
      await manager.unregisterServer(profile.id);
    } catch (_cleanupError) {
      // Preserve the original integration error.
    }
    if (error instanceof Error) throw error;
    throw new McpClientError(McpErrorCode.CONFIGURATION,
      'Shuvi web search MCP connection failed', profile.id);
  }
}
