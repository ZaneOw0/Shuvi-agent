import { describe, expect, it } from '@ohos/hypium';
import {
  DataBoundary,
  IdempotencyMode,
  RiskLevel,
  SideEffect,
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
  ToolRegistry,
  ToolRegistryEntry
} from '@harmony_agent/agent-runtime';
import {
  McpAggregateResult,
  McpCancellationSignal,
  McpCapabilityKind,
  McpCapabilityRef,
  McpClientError,
  McpErrorCode,
  McpProtocolMode,
  McpServerProfile,
  McpTool,
  McpToolResult
} from '@harmony_agent/mcp-client';
import { McpClientToolPort } from '../main/ets/mcp/McpConnectorTypes';
import {
  SHUVI_WEB_SEARCH_SERVER_ID,
  SHUVI_WEB_SEARCH_TOOL_NAME,
  ShuviWebSearchMcpClientToolPort,
  ShuviWebSearchMcpConfig,
  createShuviWebSearchPolicy,
  createShuviWebSearchProfile
} from '../main/ets/mcp/ShuviWebSearch';
import {
  McpCredentialAuthProvider,
  McpCredentialBinding
} from '../main/ets/mcp/McpCredentialAuthProvider';
import {
  SHUVI_WEB_SEARCH_TOOL_ID,
  ShuviWebSearchToolInvocationPreparer,
  installShuviWebSearchToolPreparer
} from '../main/ets/mcp/ShuviWebSearchToolPreparer';
import { ConnectorDigestPort } from '../main/ets/mcp/McpConnectorTypes';
import { LocalAIGatewayMcpRuntimePorts } from '../main/ets/provider/LocalAIGatewayProductionRuntime';
import {
  ShuviWebSearchRuntimeCompositionError,
  ShuviWebSearchRuntimeCompositionErrorCode,
  withShuviWebSearchToolPreparation
} from '../main/ets/provider/ShuviWebSearchLocalAIGatewayRuntime';
import { ProviderCredential, ProviderCredentialPort } from '../main/ets/provider/ProviderContracts';

class FixtureClient implements McpClientToolPort {
  calls: number = 0;
  result: McpToolResult = new Object() as McpToolResult;

  listTools(): Promise<McpAggregateResult<McpTool>> {
    const value: McpAggregateResult<McpTool> = { items: [], errors: [] };
    return Promise.resolve(value);
  }

  callTool(_ref: McpCapabilityRef, _argumentsValue: Object,
    _cancellation?: McpCancellationSignal): Promise<McpToolResult> {
    this.calls++;
    return Promise.resolve(this.result);
  }
}

class FixtureCredentials implements ProviderCredentialPort {
  calls: number = 0;

  resolve(providerId: string, scope: string): Promise<ProviderCredential> {
    this.calls++;
    const value: ProviderCredential = new ProviderCredential();
    value.headers.Authorization = 'Bearer ' + providerId + ':' + scope;
    return Promise.resolve(value);
  }
}

class FixtureDigest implements ConnectorDigestPort {
  digest(value: string): string {
    return 'digest:' + value;
  }
}

class FixtureIds implements RuntimeIdGeneratorPort {
  private next: number = 0;

  nextId(kind: string, requestId: string): string {
    this.next++;
    return kind + ':' + requestId + ':' + this.next.toString();
  }
}

function searchRegistry(): ToolRegistry {
  const entry: ToolRegistryEntry = new ToolRegistryEntry();
  entry.descriptor.toolId = SHUVI_WEB_SEARCH_TOOL_ID;
  entry.descriptor.sourceType = ToolSourceType.MCP;
  entry.descriptor.providerId = SHUVI_WEB_SEARCH_SERVER_ID;
  entry.descriptor.capabilityName = SHUVI_WEB_SEARCH_TOOL_NAME;
  entry.descriptor.capabilityVersion = 'shuvi-search-mcp/0.1.0';
  entry.descriptor.toolIdentityVersion = 'tool-v1';
  entry.descriptor.inputSchemaJson = '{"type":"object"}';
  entry.descriptor.schemaDigest = 'schema-digest';
  entry.descriptor.capabilityTags = ['web-search', 'public-web', 'read-only'];
  entry.descriptor.riskLevel = RiskLevel.LOW;
  entry.descriptor.sideEffect = SideEffect.NONE;
  entry.descriptor.permissionRequirements = ['network.search.public'];
  entry.descriptor.dataBoundary = DataBoundary.REMOTE_ALLOWED;
  entry.descriptor.availability = 'available';
  entry.descriptor.idempotencyMode = IdempotencyMode.NONE;
  entry.descriptor.adapterRef = 'mcp:' + SHUVI_WEB_SEARCH_SERVER_ID;
  entry.registryVersion = 'registry-v1';
  entry.registryDigest = 'registry-digest';
  entry.descriptionDigest = 'description-digest';
  entry.retrievalRelationVersion = 'retrieval-v1';
  entry.estimatedCostMicros = 7;
  entry.requiresNetwork = true;
  entry.enabled = true;
  const registry: ToolRegistry = new ToolRegistry();
  registry.register(entry);
  return registry;
}

function planningRequest(): PlanningRequest {
  const request: PlanningRequest = new PlanningRequest();
  request.envelope.requestId = 'request-search-1';
  request.envelope.taskId = 'task-search-1';
  request.envelope.userId = 'user-search-1';
  request.envelope.executionBudget.maxMonetaryCostMicros = 100;
  return request;
}

function searchStep(): WorkflowStep {
  const step: WorkflowStep = new WorkflowStep();
  step.stepId = 'search-step';
  step.kind = WorkflowStepKind.TOOL;
  step.goal = 'HarmonyOS ArkUI official documentation';
  step.capabilityRequirements = ['web-search', 'read-only'];
  step.permissionRequirements = ['network.search.public'];
  step.riskLevel = RiskLevel.LOW;
  step.sideEffect = SideEffect.NONE;
  step.idempotencyMode = IdempotencyMode.NONE;
  step.timeoutMs = 20000;
  step.retryPolicyRef = 'no-tool-retry';
  step.verificationPolicyRef = 'search-schema-v1';
  return step;
}

function ref(): McpCapabilityRef {
  return {
    serverId: SHUVI_WEB_SEARCH_SERVER_ID,
    kind: McpCapabilityKind.TOOL,
    name: SHUVI_WEB_SEARCH_TOOL_NAME
  };
}

function result(structured: string, content?: string): McpToolResult {
  return {
    content: [{ type: 'text', text: content === undefined ? structured : content }],
    structuredContent: JSON.parse(structured) as Object,
    isError: false
  };
}

export default function shuviWebSearchTest(): void {
  describe('ShuviWebSearch', () => {
    it('createsPinnedLegacyProfileAndExplicitReadOnlyPolicy', 0, () => {
      const config: ShuviWebSearchMcpConfig = new ShuviWebSearchMcpConfig();
      config.estimatedCostMicros = 19;
      const profile: McpServerProfile = createShuviWebSearchProfile(config);
      const policy = createShuviWebSearchPolicy(config);
      expect(profile.id).assertEqual(SHUVI_WEB_SEARCH_SERVER_ID);
      expect(profile.protocolMode).assertEqual(McpProtocolMode.LEGACY);
      expect(profile.retryToolCallOnExpiredSession).assertTrue();
      expect((profile.requestTimeoutMs === undefined ? 0 : profile.requestTimeoutMs) > 15000).assertTrue();
      expect(policy.toolName).assertEqual(SHUVI_WEB_SEARCH_TOOL_NAME);
      expect(policy.riskLevel).assertEqual(RiskLevel.LOW);
      expect(policy.dataBoundary).assertEqual(DataBoundary.REMOTE_ALLOWED);
      expect(policy.permissionRequirements[0]).assertEqual('network.search.public');
      expect(policy.estimatedCostMicros).assertEqual(19);
    });

    it('acceptsOnlyContractValidArgumentsAndEquivalentSuccessPayload', 0, async () => {
      const delegate: FixtureClient = new FixtureClient();
      const payload: string = '{"schemaVersion":"1.0",' +
        '"requestId":"00000000-0000-4000-8000-000000000001","provider":"tavily",' +
        '"query":"ArkUI","searchedAt":"2026-10-20T00:00:00.000Z","results":[' +
        '{"title":"ArkUI","url":"https://example.com/docs","snippet":"Official docs"}]}' ;
      delegate.result = result(payload);
      const client: ShuviWebSearchMcpClientToolPort = new ShuviWebSearchMcpClientToolPort(delegate);
      const accepted: McpToolResult = await client.callTool(ref(), JSON.parse('{"query":"ArkUI","maxResults":3}'));
      expect(accepted.isError).assertFalse();
      expect(delegate.calls).assertEqual(1);

      let inputCode: string = '';
      try {
        await client.callTool(ref(), JSON.parse('{"query":"ArkUI","maxResults":0}'));
      } catch (error) {
        inputCode = error instanceof McpClientError ? error.code : '';
      }
      expect(inputCode).assertEqual(McpErrorCode.INVALID_ARGUMENT);
      expect(delegate.calls).assertEqual(1);
    });

    it('failsClosedWhenSuccessShapeOrDuplicateTextDrifts', 0, async () => {
      const delegate: FixtureClient = new FixtureClient();
      const valid: string = '{"schemaVersion":"1.0",' +
        '"requestId":"00000000-0000-4000-8000-000000000001","provider":"tavily",' +
        '"query":"ArkUI","searchedAt":"2026-10-20T00:00:00.000Z","results":[]}' ;
      delegate.result = result(valid, '{"different":true}');
      const client: ShuviWebSearchMcpClientToolPort = new ShuviWebSearchMcpClientToolPort(delegate);
      let code: string = '';
      try {
        await client.callTool(ref(), JSON.parse('{"query":"ArkUI"}'));
      } catch (error) {
        code = error instanceof McpClientError ? error.code : '';
      }
      expect(code).assertEqual(McpErrorCode.SCHEMA_MISMATCH);
    });

    it('bindsSuccessToTheAuthorizedQueryAndRequestedResultLimit', 0, async () => {
      const delegate: FixtureClient = new FixtureClient();
      const wrongQuery: string = '{"schemaVersion":"1.0",' +
        '"requestId":"00000000-0000-4000-8000-000000000001","provider":"tavily",' +
        '"query":"different","searchedAt":"2026-10-20T00:00:00.000Z","results":[]}' ;
      delegate.result = result(wrongQuery);
      const client: ShuviWebSearchMcpClientToolPort = new ShuviWebSearchMcpClientToolPort(delegate);
      let queryCode: string = '';
      try {
        await client.callTool(ref(), JSON.parse('{"query":"ArkUI"}'));
      } catch (error) {
        queryCode = error instanceof McpClientError ? error.code : '';
      }
      expect(queryCode).assertEqual(McpErrorCode.SCHEMA_MISMATCH);

      const tooMany: string = '{"schemaVersion":"1.0",' +
        '"requestId":"00000000-0000-4000-8000-000000000001","provider":"tavily",' +
        '"query":"ArkUI","searchedAt":"2026-10-20T00:00:00.000Z","results":[' +
        '{"title":"A","url":"https://example.com/a","snippet":"A"},' +
        '{"title":"B","url":"https://example.com/b","snippet":"B"}]}' ;
      delegate.result = result(tooMany);
      let limitCode: string = '';
      try {
        await client.callTool(ref(), JSON.parse('{"query":"ArkUI","maxResults":1}'));
      } catch (error) {
        limitCode = error instanceof McpClientError ? error.code : '';
      }
      expect(limitCode).assertEqual(McpErrorCode.SCHEMA_MISMATCH);
    });

    it('resolvesBoundMcpBearerCredentialAtRequestTime', 0, async () => {
      const credentials: FixtureCredentials = new FixtureCredentials();
      const auth: McpCredentialAuthProvider = new McpCredentialAuthProvider(credentials);
      const binding: McpCredentialBinding = new McpCredentialBinding();
      binding.serverId = SHUVI_WEB_SEARCH_SERVER_ID;
      binding.credentialScope = 'mcp.search.invoke';
      expect(auth.register(binding)).assertTrue();
      const headers: Record<string, string> = await auth.getHeaders(
        createShuviWebSearchProfile(new ShuviWebSearchMcpConfig()), 'tools/call');
      expect(headers.Authorization).assertEqual('Bearer shuvi-web-search:mcp.search.invoke');
      expect(credentials.calls).assertEqual(1);
    });

    it('preparesRuntimeAuthorizedSearchInvocationFromThePlannedStep', 0, () => {
      const digest: FixtureDigest = new FixtureDigest();
      const preparer: ShuviWebSearchToolInvocationPreparer =
        new ShuviWebSearchToolInvocationPreparer(searchRegistry(), digest, new FixtureIds());
      const step: WorkflowStep = searchStep();
      const maxResults: WorkflowInputBinding = new WorkflowInputBinding();
      maxResults.name = 'maxResults';
      maxResults.literalJson = '3';
      step.inputBindings.push(maxResults);
      const prepared: PreparedToolDispatch = preparer.prepare(planningRequest(), step, 1000);
      expect(prepared.policyRequest.toolId).assertEqual(SHUVI_WEB_SEARCH_TOOL_ID);
      expect(prepared.policyRequest.providerId).assertEqual(SHUVI_WEB_SEARCH_SERVER_ID);
      expect(prepared.policyRequest.argumentsDigest).assertEqual(prepared.invocation.argumentsDigest);
      expect(prepared.policyRequest.operationId).assertEqual(prepared.invocation.operationId);
      expect(prepared.invocation.argumentsJson)
        .assertEqual('{"maxResults":3,"query":"HarmonyOS ArkUI official documentation"}');
      expect(prepared.invocation.authorizationGrantId).assertEqual('');
    });

    it('installsOnceAndFailsClosedForUntrustedArgumentBindings', 0, () => {
      const digest: FixtureDigest = new FixtureDigest();
      const ids: FixtureIds = new FixtureIds();
      const ports: ProductionAgentRuntimePorts = new ProductionAgentRuntimePorts();
      ports.ids = ids;
      const registry: ToolRegistry = searchRegistry();
      expect(installShuviWebSearchToolPreparer(ports, registry, digest)).assertTrue();
      expect(installShuviWebSearchToolPreparer(ports, registry, digest)).assertFalse();

      const step: WorkflowStep = searchStep();
      const unsafe: WorkflowInputBinding = new WorkflowInputBinding();
      unsafe.name = 'query';
      unsafe.sourceStepId = 'previous-step';
      unsafe.sourceOutputPath = '$.text';
      step.inputBindings.push(unsafe);
      const prepared: PreparedToolDispatch = (ports.toolPreparer as ShuviWebSearchToolInvocationPreparer)
        .prepare(planningRequest(), step, 1000);
      expect(prepared.policyRequest.requestId).assertEqual('');
      expect(prepared.invocation.invocationId).assertEqual('');
    });

    it('composesSearchPreparationWithoutMutatingCallerOwnedRuntimePorts', 0, () => {
      const source: LocalAIGatewayMcpRuntimePorts = new LocalAIGatewayMcpRuntimePorts();
      source.digest = new FixtureDigest();
      source.runtimePorts.ids = new FixtureIds();
      const composed: LocalAIGatewayMcpRuntimePorts =
        withShuviWebSearchToolPreparation(source, searchRegistry());
      expect(source.runtimePorts.toolPreparer === undefined).assertTrue();
      expect(composed.runtimePorts.toolPreparer !== undefined).assertTrue();

      let conflict: ShuviWebSearchRuntimeCompositionErrorCode | undefined = undefined;
      try {
        withShuviWebSearchToolPreparation(composed, searchRegistry());
      } catch (error) {
        if (error instanceof ShuviWebSearchRuntimeCompositionError) conflict = error.code;
      }
      expect(conflict).assertEqual(ShuviWebSearchRuntimeCompositionErrorCode.TOOL_PREPARER_CONFLICT);
    });
  });
}
