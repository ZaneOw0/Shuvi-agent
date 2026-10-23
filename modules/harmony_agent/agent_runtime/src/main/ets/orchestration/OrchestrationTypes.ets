import {
  AgentRuntimeEvent,
  AgentTaskSnapshot,
  ClarificationRequest,
  CollaborationMode,
  IdempotencyMode,
  PolicyRequest,
  SideEffect,
  TaskEnvelope,
  TaskFrame,
  TaskHandle,
  TaskSubmission,
  ToolInvocation,
  WorkflowGraph,
  WorkflowStep
} from '@harmony_agent/agent-contracts';
import { StepExecutionResult, WorkflowRuntimeSnapshot } from '@harmony_agent/agent-core';

export const RUNTIME_TASK_RECOVERY_CHECKPOINT_VERSION: string = '1.2';
export const COLLABORATION_PLAN_VERSION: string = '1.0';

export enum PlanningStatus {
  READY = 'ready',
  CLARIFICATION_REQUIRED = 'clarificationRequired',
  REJECTED = 'rejected'
}

/** Stable Role Registry identity selected for one planned Agent activation. */
export class CollaborationRoleAssignment {
  roleId: string = '';
  roleVersion: string = '';
  roleRegistryDigest: string = '';
}

/**
 * Versioned, persistence-safe collaboration decision. It contains identities
 * and digests only; prompts, model output and credentials are excluded.
 */
export class CollaborationPlan {
  planVersion: string = COLLABORATION_PLAN_VERSION;
  taskId: string = '';
  mode: CollaborationMode = CollaborationMode.SINGLE;
  roleRegistryDigest: string = '';
  decisionDigest: string = '';
  assignments: CollaborationRoleAssignment[] = [];
}

export class PlanningRequest {
  envelope: TaskEnvelope = new TaskEnvelope();
  frame: TaskFrame = new TaskFrame();
  collaborationMode: CollaborationMode = CollaborationMode.SINGLE;
  collaborationPlan?: CollaborationPlan;
  previousWorkflow?: WorkflowGraph;
  affectedStepIds: string[] = [];
}

export class PlanningResult {
  status: PlanningStatus = PlanningStatus.REJECTED;
  workflow?: WorkflowGraph;
  clarification?: ClarificationRequest;
  rejectionCode: string = '';
}

export class SessionAcceptance {
  duplicate: boolean = false;
  handle: TaskHandle = new TaskHandle();
  envelope: TaskEnvelope = new TaskEnvelope();
}

export class OrchestrationAcceptance {
  duplicate: boolean = false;
  handle: TaskHandle = new TaskHandle();
  snapshot: AgentTaskSnapshot = new AgentTaskSnapshot();
}

export class PreparedToolDispatch {
  policyRequest: PolicyRequest = new PolicyRequest();
  invocation: ToolInvocation = new ToolInvocation();
}

export class StepDispatchRequest {
  task: TaskEnvelope = new TaskEnvelope();
  workflowId: string = '';
  workflowVersion: string = '';
  step: WorkflowStep = new WorkflowStep();
  dispatchId: string = '';
  toolInvocation?: ToolInvocation;
  persistenceContext?: DispatchPersistenceContext;
}

/**
 * Storage-neutral operation metadata for M05-A composition.
 *
 * It contains stable identifiers and reserved budget facts only. Provider
 * credentials, arguments JSON and authorization decisions are excluded.
 */
export class DispatchPersistenceContext {
  contextVersion: string = '1.0';
  operationId: string = '';
  dispatchId: string = '';
  invocationId: string = '';
  attemptId: string = '';
  taskId: string = '';
  stepId: string = '';
  toolId: string = '';
  toolIdentityVersion: string = '';
  schemaDigest: string = '';
  argumentsDigest: string = '';
  idempotencyKey: string = '';
  idempotencyMode: IdempotencyMode = IdempotencyMode.NONE;
  sideEffect: SideEffect = SideEffect.NONE;
  policyRequestId: string = '';
  budgetReservationId: string = '';
  providerId: string = '';
  requestedToolCalls: number = 0;
  requestedCostMicros: number = 0;
  createdAt: string = '';
}

export class StepDispatchReceipt {
  accepted: boolean = false;
  rejectionCode: string = '';
}

export class StepCompletion {
  taskId: string = '';
  stepId: string = '';
  dispatchId: string = '';
  result: StepExecutionResult = new StepExecutionResult();
}

export class CoordinatorCommandResult {
  accepted: boolean = false;
  duplicate: boolean = false;
  code: string = '';
  snapshotVersion: number = 0;
}

export class OrchestrationUsage {
  plannerCalls: number = 0;
  agentActivations: number = 0;
  replans: number = 0;
}

/**
 * Sensitive internal task state needed to reconstruct one active coordinator
 * record. It is a persistence DTO, not a task-control entry or public event.
 * The host must protect it because it can contain user intent, arguments JSON
 * and short-lived authorization references. Durable budget and policy records
 * remain authoritative and are joined by their stable IDs during recovery.
 */
export class CollaborationPreparationState {
  version: string = '1.0';
  evaluations: number = 0;
  pending: boolean = false;
  baselineOnly: boolean = false;
}

export class RuntimeTaskRecoveryCheckpoint {
  collaborationPreparation: CollaborationPreparationState = new CollaborationPreparationState();
  checkpointVersion: string = RUNTIME_TASK_RECOVERY_CHECKPOINT_VERSION;
  submission: TaskSubmission = new TaskSubmission();
  envelope: TaskEnvelope = new TaskEnvelope();
  frame: TaskFrame = new TaskFrame();
  collaborationMode: CollaborationMode = CollaborationMode.SINGLE;
  handle: TaskHandle = new TaskHandle();
  snapshot: AgentTaskSnapshot = new AgentTaskSnapshot();
  events: AgentRuntimeEvent[] = [];
  usage: OrchestrationUsage = new OrchestrationUsage();
  planningRequest: PlanningRequest = new PlanningRequest();
  workflow?: WorkflowGraph;
  scheduler?: WorkflowRuntimeSnapshot;
  pendingClarification?: ClarificationRequest;
  pendingPolicyRequest?: PolicyRequest;
  pendingInvocation?: ToolInvocation;
  activeInvocation?: ToolInvocation;
  pendingStepId: string = '';
  pendingDispatchId: string = '';
  pendingOperationId: string = '';
  registeredProviderIds: string[] = [];
  paused: boolean = false;
}

export class ReplanResult {
  accepted: boolean = false;
  code: string = '';
  workflow?: WorkflowGraph;
}
