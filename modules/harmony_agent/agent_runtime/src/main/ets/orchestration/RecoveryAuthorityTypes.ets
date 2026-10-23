import {
  AuthorizationDecision,
  AuthorizationGrant,
  IdempotencyMode,
  PolicyRequest,
  SideEffect,
  ToolOutcome
} from '@harmony_agent/agent-contracts';
import {
  BudgetReservationSnapshot,
  BudgetScopeSnapshot,
  OperationJournalState
} from '@harmony_agent/agent-core';

export const RUNTIME_RECOVERY_AUTHORITY_VERSION: string = '1.0';

/** Storage-neutral image of the durable policy record joined to a checkpoint. */
export class RuntimeRecoveryPolicyAuthority {
  version: number = 0;
  request: PolicyRequest = new PolicyRequest();
  decision?: AuthorizationDecision;
  grant?: AuthorizationGrant;
}

/**
 * Storage-neutral operation authority. The extra policy and effect fields are
 * required because recovery must not infer them from defaults after restart.
 */
export class RuntimeRecoveryOperationAuthority {
  operationId: string = '';
  invocationId: string = '';
  taskId: string = '';
  stepId: string = '';
  attemptId: string = '';
  toolId: string = '';
  toolIdentityVersion: string = '';
  schemaDigest: string = '';
  argumentsDigest: string = '';
  idempotencyKey: string = '';
  idempotencyMode: IdempotencyMode = IdempotencyMode.NONE;
  sideEffect: SideEffect = SideEffect.NONE;
  policyRequestId: string = '';
  budgetReservationId: string = '';
  state: OperationJournalState = OperationJournalState.PREPARED;
  outcome?: ToolOutcome;
  fencingToken: number = 0;
  dispatchCount: number = 0;
}

/**
 * Storage-neutral authority write payload captured with a checkpoint. It has no
 * storage revision because the persistence adapter owns the compare-and-swap
 * transaction that assigns that revision. Operation authority is present only
 * for the dispatch preparation write; later writes must preserve the operation
 * state already committed by outcome or reconciliation persistence.
 */
export class RuntimeDurableAuthorityPayload {
  authorityVersion: string = RUNTIME_RECOVERY_AUTHORITY_VERSION;
  taskId: string = '';
  checkpointSnapshotVersion: number = 0;
  policyVersion: string = '';
  budgetScopes: BudgetScopeSnapshot[] = [];
  budgetReservations: BudgetReservationSnapshot[] = [];
  policy?: RuntimeRecoveryPolicyAuthority;
  operation?: RuntimeRecoveryOperationAuthority;
}

/**
 * Complete authority image returned after a durable read. The storage revision
 * binds it to the host transaction that committed the checkpoint and payload.
 */
export class RuntimeRecoveryAuthority extends RuntimeDurableAuthorityPayload {
  storageRevision: number = 0;
}

export class RuntimeRecoveryAuthorityValidationResult {
  valid: boolean = false;
  code: string = 'RECOVERY_AUTHORITY_INVALID';
}
