import {
  DataBoundary,
  IdempotencyMode,
  PolicyRequest,
  RiskLevel,
  SideEffect,
  ToolInvocation,
  ToolSourceType,
  WorkflowInputBinding,
  WorkflowStep,
  WorkflowStepKind
} from '@harmony_agent/agent-contracts';
import {
  PlanningRequest,
  PreparedToolDispatch,
  ProductionAgentRuntimePorts,
  RuntimeIdGeneratorPort,
  ToolInvocationPreparerPort,
  ToolRegistry,
  ToolRegistryEntry
} from '@harmony_agent/agent-runtime';
import { canonicalJson } from './CanonicalJson';
import { ConnectorDigestPort } from './McpConnectorTypes';
import {
  SHUVI_WEB_SEARCH_SERVER_ID,
  SHUVI_WEB_SEARCH_TOOL_NAME
} from './ShuviWebSearch';

export const SHUVI_WEB_SEARCH_TOOL_ID: string = 'mcp://shuvi-web-search/tool/web_search';

export class ShuviWebSearchToolPreparationConfig {
  policyTtlMs: number = 60000;
  defaultMaxResults: number = 5;
}

export function validShuviWebSearchToolPreparationConfig(
  config: ShuviWebSearchToolPreparationConfig): boolean {
  return Number.isSafeInteger(config.policyTtlMs) && config.policyTtlMs > 0 &&
    Number.isSafeInteger(config.defaultMaxResults) &&
    config.defaultMaxResults >= 1 && config.defaultMaxResults <= 10;
}

function validText(value: string): boolean {
  return value.trim().length > 0;
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

function containsAll(available: string[], required: string[]): boolean {
  for (let index: number = 0; index < required.length; index++) {
    if (available.indexOf(required[index]) < 0) return false;
  }
  return true;
}

function binding(step: WorkflowStep, name: string): WorkflowInputBinding | undefined {
  for (let index: number = 0; index < step.inputBindings.length; index++) {
    if (step.inputBindings[index].name === name) return step.inputBindings[index];
  }
  return undefined;
}

function literal(value: WorkflowInputBinding | undefined): Object | undefined {
  if (value === undefined) return undefined;
  if (value.sourceStepId !== undefined || value.sourceOutputPath !== undefined ||
    value.literalJson === undefined) return undefined;
  return JSON.parse(value.literalJson) as Object;
}

function emptyPreparation(): PreparedToolDispatch {
  return new PreparedToolDispatch();
}

/**
 * Converts one planned, read-only web-search step into the policy/invocation pair
 * consumed by the existing Runtime authorization gate.
 */
export class ShuviWebSearchToolInvocationPreparer implements ToolInvocationPreparerPort {
  private readonly registry: ToolRegistry;
  private readonly digest: ConnectorDigestPort;
  private readonly ids: RuntimeIdGeneratorPort;
  private readonly config: ShuviWebSearchToolPreparationConfig;

  constructor(registry: ToolRegistry, digest: ConnectorDigestPort, ids: RuntimeIdGeneratorPort,
    config: ShuviWebSearchToolPreparationConfig = new ShuviWebSearchToolPreparationConfig()) {
    this.registry = registry;
    this.digest = digest;
    this.ids = ids;
    this.config = config;
  }

  prepare(request: PlanningRequest, step: WorkflowStep, nowMs: number): PreparedToolDispatch {
    try {
      if (!this.validConfig() || !Number.isSafeInteger(nowMs) || nowMs < 0 ||
        nowMs > 8640000000000000 - this.config.policyTtlMs || !this.validStep(step)) {
        return emptyPreparation();
      }
      const entry: ToolRegistryEntry | undefined = this.searchEntry();
      if (entry === undefined || entry.estimatedCostMicros >
        request.envelope.executionBudget.maxMonetaryCostMicros ||
        !containsAll(entry.descriptor.capabilityTags, step.capabilityRequirements) ||
        !containsAll(entry.descriptor.permissionRequirements, step.permissionRequirements)) {
        return emptyPreparation();
      }
      const argumentsValue: Object | undefined = this.arguments(step);
      if (argumentsValue === undefined) return emptyPreparation();
      const argumentsJson: string = canonicalJson(argumentsValue);
      const argumentsDigest: string = this.digest.digest(argumentsJson);
      if (!validText(argumentsDigest)) return emptyPreparation();

      const identity: string = request.envelope.requestId + ':' + step.stepId;
      const requestedAt: string = new Date(nowMs).toISOString();
      const expiresAtMs: number = nowMs + this.config.policyTtlMs;
      const operationId: string = this.ids.nextId('operation', identity);
      const policyRequestId: string = this.ids.nextId('policyRequest', identity);
      const invocationId: string = this.ids.nextId('invocation', identity);
      const attemptId: string = this.ids.nextId('attempt', identity);
      if (!validText(operationId) || !validText(policyRequestId) ||
        !validText(invocationId) || !validText(attemptId)) return emptyPreparation();

      const policy: PolicyRequest = new PolicyRequest();
      policy.requestId = policyRequestId;
      policy.userId = request.envelope.userId;
      policy.taskId = request.envelope.taskId;
      policy.stepId = step.stepId;
      policy.operationId = operationId;
      policy.toolId = entry.descriptor.toolId;
      policy.toolIdentityVersion = entry.descriptor.toolIdentityVersion;
      policy.providerId = entry.descriptor.providerId;
      policy.schemaDigest = entry.descriptor.schemaDigest;
      policy.argumentsDigest = argumentsDigest;
      policy.riskLevel = entry.descriptor.riskLevel;
      policy.sideEffect = entry.descriptor.sideEffect;
      policy.estimatedCostMicros = entry.estimatedCostMicros;
      policy.requestedAt = requestedAt;
      policy.expiresAtMs = expiresAtMs;
      policy.expiresAt = new Date(expiresAtMs).toISOString();

      const invocation: ToolInvocation = new ToolInvocation();
      invocation.invocationId = invocationId;
      invocation.taskId = request.envelope.taskId;
      invocation.stepId = step.stepId;
      invocation.operationId = operationId;
      invocation.attemptId = attemptId;
      invocation.toolId = entry.descriptor.toolId;
      invocation.toolIdentityVersion = entry.descriptor.toolIdentityVersion;
      invocation.schemaDigest = entry.descriptor.schemaDigest;
      invocation.argumentsJson = argumentsJson;
      invocation.argumentsDigest = argumentsDigest;
      invocation.authorizationGrantId = '';
      invocation.timeoutMs = step.timeoutMs;
      invocation.createdAt = requestedAt;

      const result: PreparedToolDispatch = new PreparedToolDispatch();
      result.policyRequest = policy;
      result.invocation = invocation;
      return result;
    } catch (_error) {
      return emptyPreparation();
    }
  }

  private validConfig(): boolean {
    return validShuviWebSearchToolPreparationConfig(this.config);
  }

  private validStep(step: WorkflowStep): boolean {
    if (step.kind !== WorkflowStepKind.TOOL || step.sideEffect !== SideEffect.NONE ||
      step.riskLevel !== RiskLevel.LOW || step.idempotencyMode !== IdempotencyMode.NONE ||
      step.timeoutMs <= 0 || step.capabilityRequirements.indexOf('web-search') < 0 ||
      step.permissionRequirements.indexOf('network.search.public') < 0) return false;
    let queryBindings: number = 0;
    let maxResultBindings: number = 0;
    for (let index: number = 0; index < step.inputBindings.length; index++) {
      const name: string = step.inputBindings[index].name;
      if (name !== 'query' && name !== 'maxResults') return false;
      if (name === 'query') queryBindings++; else maxResultBindings++;
    }
    return queryBindings <= 1 && maxResultBindings <= 1;
  }

  private searchEntry(): ToolRegistryEntry | undefined {
    const entries: ToolRegistryEntry[] = this.registry.activeEntries();
    let result: ToolRegistryEntry | undefined = undefined;
    for (let index: number = 0; index < entries.length; index++) {
      const entry: ToolRegistryEntry = entries[index];
      if (entry.descriptor.toolId !== SHUVI_WEB_SEARCH_TOOL_ID) continue;
      if (result !== undefined || entry.descriptor.providerId !== SHUVI_WEB_SEARCH_SERVER_ID ||
        entry.descriptor.capabilityName !== SHUVI_WEB_SEARCH_TOOL_NAME ||
        entry.descriptor.sourceType !== ToolSourceType.MCP ||
        entry.descriptor.adapterRef !== 'mcp:' + SHUVI_WEB_SEARCH_SERVER_ID ||
        entry.descriptor.availability !== 'available' || !entry.enabled || !entry.requiresNetwork ||
        entry.descriptor.sideEffect !== SideEffect.NONE ||
        entry.descriptor.idempotencyMode !== IdempotencyMode.NONE ||
        entry.descriptor.riskLevel !== RiskLevel.LOW ||
        entry.descriptor.dataBoundary !== DataBoundary.REMOTE_ALLOWED ||
        entry.descriptor.capabilityTags.indexOf('web-search') < 0 ||
        entry.descriptor.permissionRequirements.indexOf('network.search.public') < 0) return undefined;
      result = entry;
    }
    return result;
  }

  private arguments(step: WorkflowStep): Object | undefined {
    const queryBinding: WorkflowInputBinding | undefined = binding(step, 'query');
    const queryValue: Object | undefined = literal(queryBinding);
    const query: string = queryBinding === undefined ? step.goal.trim() :
      (typeof queryValue === 'string' ? (queryValue as string).trim() : '');
    if (!validText(query) || unicodeLength(query) > 500) return undefined;

    const maxBinding: WorkflowInputBinding | undefined = binding(step, 'maxResults');
    const maxValue: Object | undefined = literal(maxBinding);
    const maxResults: number = maxBinding === undefined ? this.config.defaultMaxResults :
      (typeof maxValue === 'number' ? maxValue as number : 0);
    if (!Number.isSafeInteger(maxResults) || maxResults < 1 || maxResults > 10) return undefined;

    const value: Record<string, Object> = {};
    value['query'] = query;
    value['maxResults'] = maxResults;
    return value;
  }
}

/** Installs the production search preparer without replacing a caller-owned preparer. */
export function installShuviWebSearchToolPreparer(ports: ProductionAgentRuntimePorts,
  registry: ToolRegistry, digest: ConnectorDigestPort,
  config: ShuviWebSearchToolPreparationConfig = new ShuviWebSearchToolPreparationConfig()): boolean {
  if (ports.toolPreparer !== undefined || ports.ids === undefined) return false;
  ports.toolPreparer = new ShuviWebSearchToolInvocationPreparer(registry, digest, ports.ids, config);
  return true;
}
