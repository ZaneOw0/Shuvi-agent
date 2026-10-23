import {
  AGENT_CONTRACT_SCHEMA_VERSION,
  CONTRACT_TYPE_TOOL_DESCRIPTOR,
  CONTRACT_TYPE_TOOL_INVOCATION,
  CONTRACT_TYPE_TOOL_OUTCOME
} from './Constants';
import { ContractId, Digest, DurationMs, IsoTimestamp, JsonText } from './Common';
import {
  AgentErrorClass,
  DataBoundary,
  IdempotencyMode,
  RiskLevel,
  SideEffect,
  ToolOutcomeStatus,
  ToolSourceType
} from './Enums';

export class ToolDescriptor {
  schemaVersion: string = AGENT_CONTRACT_SCHEMA_VERSION;
  contractType: string = CONTRACT_TYPE_TOOL_DESCRIPTOR;
  toolId: ContractId = '';
  sourceType: ToolSourceType = ToolSourceType.MCP;
  providerId: ContractId = '';
  capabilityName: string = '';
  capabilityVersion: string = '';
  toolIdentityVersion: string = '';
  displayName: string = '';
  description: string = '';
  inputSchemaJson: JsonText = '{}';
  outputSchemaJson?: JsonText;
  schemaDigest: Digest = '';
  capabilityTags: string[] = [];
  riskLevel: RiskLevel = RiskLevel.LOW;
  sideEffect: SideEffect = SideEffect.NONE;
  permissionRequirements: string[] = [];
  dataBoundary: DataBoundary = DataBoundary.APP_SANDBOX;
  availability: string = 'unknown';
  latencyClass: string = '';
  costClass: string = '';
  idempotencyMode: IdempotencyMode = IdempotencyMode.NONE;
  adapterRef: ContractId = '';
}

export class ToolInvocation {
  schemaVersion: string = AGENT_CONTRACT_SCHEMA_VERSION;
  contractType: string = CONTRACT_TYPE_TOOL_INVOCATION;
  invocationId: ContractId = '';
  taskId: ContractId = '';
  stepId: ContractId = '';
  operationId: ContractId = '';
  attemptId: ContractId = '';
  toolId: ContractId = '';
  toolIdentityVersion: string = '';
  schemaDigest: Digest = '';
  argumentsJson: JsonText = '{}';
  argumentsDigest: Digest = '';
  idempotencyKey?: string;
  authorizationGrantId: ContractId = '';
  timeoutMs: DurationMs = 0;
  createdAt: IsoTimestamp = '';
}

export class ToolOutcome {
  schemaVersion: string = AGENT_CONTRACT_SCHEMA_VERSION;
  contractType: string = CONTRACT_TYPE_TOOL_OUTCOME;
  invocationId: ContractId = '';
  status: ToolOutcomeStatus = ToolOutcomeStatus.FAILED;
  resultJson?: JsonText;
  resultDigest?: Digest;
  errorClass?: AgentErrorClass;
  errorCode?: string;
  errorMessage?: string;
  providerReceipt?: string;
  startedAt: IsoTimestamp = '';
  finishedAt: IsoTimestamp = '';
}
