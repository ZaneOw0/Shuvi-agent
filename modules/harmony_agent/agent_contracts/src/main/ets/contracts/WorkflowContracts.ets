import { AGENT_CONTRACT_SCHEMA_VERSION, CONTRACT_TYPE_WORKFLOW_GRAPH } from './Constants';
import { ContractId, DurationMs, JsonText } from './Common';
import { IdempotencyMode, RiskLevel, SideEffect, WorkflowStepKind } from './Enums';

export class WorkflowInputBinding {
  name: string = '';
  sourceStepId?: ContractId;
  sourceOutputPath?: string;
  literalJson?: JsonText;
}

export class WorkflowStep {
  stepId: ContractId = '';
  kind: WorkflowStepKind = WorkflowStepKind.LLM;
  goal: string = '';
  dependencies: ContractId[] = [];
  inputBindings: WorkflowInputBinding[] = [];
  expectedOutputSchemaJson: JsonText = '{}';
  capabilityRequirements: string[] = [];
  sideEffect: SideEffect = SideEffect.NONE;
  riskLevel: RiskLevel = RiskLevel.LOW;
  permissionRequirements: string[] = [];
  idempotencyMode: IdempotencyMode = IdempotencyMode.NONE;
  timeoutMs: DurationMs = 0;
  retryPolicyRef: ContractId = '';
  verificationPolicyRef: ContractId = '';
}

export class WorkflowGraph {
  schemaVersion: string = AGENT_CONTRACT_SCHEMA_VERSION;
  contractType: string = CONTRACT_TYPE_WORKFLOW_GRAPH;
  workflowId: ContractId = '';
  taskId: ContractId = '';
  workflowVersion: string = '';
  entryStepIds: ContractId[] = [];
  steps: WorkflowStep[] = [];
  createdAt: string = '';
}
