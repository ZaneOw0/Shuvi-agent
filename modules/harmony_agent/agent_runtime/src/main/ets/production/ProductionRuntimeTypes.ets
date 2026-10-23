import { CollaborationPolicyPreparationPort } from '../routing/CollaborationPreparation';
import {
  ReconciliationReport,
  ToolOutcome
} from '@harmony_agent/agent-contracts';
import {
  CollaborationSelectorPort,
  CollaborationPlanSelectorPort,
  RuntimeClockPort,
  RuntimeIdGeneratorPort,
  SemanticPlannerPort,
  StepDispatchPort,
  ToolInvocationPreparerPort
} from '../orchestration/RuntimePorts';
import {
  DispatchPersistenceContext,
  RuntimeTaskRecoveryCheckpoint
} from '../orchestration/OrchestrationTypes';
import {
  RuntimeDurableAuthorityPayload,
  RuntimeRecoveryAuthority
} from '../orchestration/RecoveryAuthorityTypes';

/** 2.7 adds task-bound interruption for every Semantic Planner invocation. */
export const PRODUCTION_RUNTIME_COMPOSITION_VERSION: string = '2.7';

export enum RuntimePersistenceCode {
  SAVED = 'SAVED',
  UNCHANGED = 'UNCHANGED',
  NOT_FOUND = 'NOT_FOUND',
  VERSION_CONFLICT = 'VERSION_CONFLICT',
  REJECTED = 'REJECTED'
}

export class RuntimePersistenceResult {
  accepted: boolean = false;
  duplicate: boolean = false;
  code: RuntimePersistenceCode = RuntimePersistenceCode.REJECTED;
}

/**
 * Versioned M05-A composition boundary.
 *
 * Implementations must persist task versions in order. beforeDispatch must
 * atomically persist its checkpoint and operation authority before resolving success. The Runtime
 * checkpoint and authority payload are sensitive recovery state and must be stored with
 * host-managed access control and encryption appropriate to their privacy class.
 * DispatchPersistenceContext remains the minimal operation index used by rejection and
 * outcome paths; the authority data Runtime can prove at that checkpoint travels separately and only
 * through the persistence boundary. Non-tool dispatches have no operation context. The Runtime
 * never invokes an adapter before this Promise resolves success. Values returned
 * from loadCheckpoint are untrusted until the Runtime validates their version,
 * structure and task identity bindings.
 *
 * saveCheckpoint may persist a version-1 pending policy request, but it must not
 * recreate or regress operation state from an authority payload. Only beforeDispatch
 * may prepare a new operation. Outcome and reconciliation methods own all later
 * operation, fencing and budget settlement transitions.
 */
export interface ProductionRuntimePersistencePort {
  saveCheckpoint(checkpoint: RuntimeTaskRecoveryCheckpoint, expectedPreviousVersion: number,
    authority: RuntimeDurableAuthorityPayload, nowMs: number): Promise<RuntimePersistenceResult>;
  loadCheckpoint(taskId: string): Promise<RuntimeTaskRecoveryCheckpoint | undefined>;
  normalizeRecoveredOperation(checkpoint: RuntimeTaskRecoveryCheckpoint, expectedPreviousVersion: number,
    nowMs: number): Promise<RuntimePersistenceResult>;
  beforeDispatch(checkpoint: RuntimeTaskRecoveryCheckpoint, expectedPreviousVersion: number,
    context: DispatchPersistenceContext | undefined, authority: RuntimeDurableAuthorityPayload,
    nowMs: number): Promise<RuntimePersistenceResult>;
  recordDispatchRejected(context: DispatchPersistenceContext | undefined, dispatchId: string,
    rejectionCode: string,
    nowMs: number): Promise<RuntimePersistenceResult>;
  recordOutcome(taskId: string, stepId: string, dispatchId: string, outcome: ToolOutcome,
    nowMs: number): Promise<RuntimePersistenceResult>;
  recordReconciliation(report: ReconciliationReport, nowMs: number): Promise<RuntimePersistenceResult>;
}

/** Read-only startup source. It discovers durable tasks and returns authority; it cannot control them. */
export interface ProductionRuntimeRecoverySourcePort {
  listRecoveryTaskIds(): Promise<string[]>;
  loadRecoveryAuthority(taskId: string): Promise<RuntimeRecoveryAuthority | undefined>;
}

/** Completion-only ingress bound by the production factory. It cannot control tasks. */
export interface RuntimeToolOutcomeSinkPort {
  complete(taskId: string, stepId: string, dispatchId: string, outcome: ToolOutcome): Promise<void>;
}

/** Creates the enabled adapter after the private completion sink exists. */
export interface ProductionRuntimeAdapterFactoryPort {
  create(sink: RuntimeToolOutcomeSinkPort): StepDispatchPort;
}

export class ProductionAgentRuntimeConfig {
  compositionVersion: string = PRODUCTION_RUNTIME_COMPOSITION_VERSION;
  policyVersion: string = '';
  grantTtlMs: number = 0;
  autoAdvanceLimit: number = 32;
  collaborationPreparationTimeoutMs: number = 5000;
}

export class ProductionAgentRuntimePorts {
  clock?: RuntimeClockPort;
  ids?: RuntimeIdGeneratorPort;
  planner?: SemanticPlannerPort;
  collaboration?: CollaborationSelectorPort;
  collaborationPlan?: CollaborationPlanSelectorPort;
  collaborationPreparation?: CollaborationPolicyPreparationPort;
  toolPreparer?: ToolInvocationPreparerPort;
  adapterFactory?: ProductionRuntimeAdapterFactoryPort;
  persistence?: ProductionRuntimePersistencePort;
  recovery?: ProductionRuntimeRecoverySourcePort;
}
