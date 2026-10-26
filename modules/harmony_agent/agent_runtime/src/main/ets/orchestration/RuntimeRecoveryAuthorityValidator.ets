import {
  AuthorizationDecisionType,
  AuthorizationGrant,
  ContractCodec,
  ContractValidator,
  PolicyRequest,
  ToolInvocation,
  ToolOutcomeStatus,
  WorkflowStep
} from '@harmony_agent/agent-contracts';
import {
  BudgetLedger,
  BudgetReservationSnapshot,
  BudgetReservationState,
  OperationJournalState
} from '@harmony_agent/agent-core';
import { RuntimeCheckpointValidator } from './RuntimeCheckpointValidator';
import {
  RUNTIME_RECOVERY_AUTHORITY_VERSION,
  RuntimeRecoveryAuthority,
  RuntimeRecoveryAuthorityValidationResult,
  RuntimeRecoveryOperationAuthority,
  RuntimeRecoveryPolicyAuthority
} from './RecoveryAuthorityTypes';
import { RuntimeTaskRecoveryCheckpoint } from './OrchestrationTypes';

function result(valid: boolean, code: string): RuntimeRecoveryAuthorityValidationResult {
  const value: RuntimeRecoveryAuthorityValidationResult = new RuntimeRecoveryAuthorityValidationResult();
  value.valid = valid;
  value.code = code;
  return value;
}

function sameContract(left: Object, right: Object): boolean {
  return ContractCodec.stringify(left) === ContractCodec.stringify(right);
}

function safePositive(value: number): boolean {
  return Number.isSafeInteger(value) && value > 0;
}

function findReservation(values: BudgetReservationSnapshot[], reservationId: string):
  BudgetReservationSnapshot | undefined {
  for (let i: number = 0; i < values.length; i++) {
    if (values[i].reservationId === reservationId) return values[i];
  }
  return undefined;
}

function findStep(checkpoint: RuntimeTaskRecoveryCheckpoint, stepId: string): WorkflowStep | undefined {
  if (checkpoint.workflow === undefined) return undefined;
  for (let i: number = 0; i < checkpoint.workflow.steps.length; i++) {
    if (checkpoint.workflow.steps[i].stepId === stepId) return checkpoint.workflow.steps[i];
  }
  return undefined;
}

function zeroActual(value: BudgetReservationSnapshot): boolean {
  return value.actual.wallTimeMs === 0 && value.actual.inputTokens === 0 && value.actual.outputTokens === 0 &&
    value.actual.monetaryCostMicros === 0 && value.actual.toolCalls === 0 &&
    value.actual.agentActivations === 0 && value.actual.retries === 0 && value.actual.replans === 0;
}

export class RuntimeRecoveryAuthorityValidator {
  static validate(checkpoint: RuntimeTaskRecoveryCheckpoint,
    authority: RuntimeRecoveryAuthority): RuntimeRecoveryAuthorityValidationResult {
    if (!RuntimeCheckpointValidator.validate(checkpoint).valid) return result(false, 'CHECKPOINT_INVALID');
    if (authority.authorityVersion !== RUNTIME_RECOVERY_AUTHORITY_VERSION ||
      authority.taskId !== checkpoint.snapshot.taskId ||
      authority.checkpointSnapshotVersion !== checkpoint.snapshot.snapshotVersion ||
      !safePositive(authority.storageRevision) || authority.policyVersion.trim().length === 0) {
      return result(false, 'AUTHORITY_BINDING_INVALID');
    }
    if (!RuntimeRecoveryAuthorityValidator.validateBudget(checkpoint, authority)) {
      return result(false, 'BUDGET_AUTHORITY_INVALID');
    }

    const pending: PolicyRequest | undefined = checkpoint.pendingPolicyRequest;
    const active: ToolInvocation | undefined = checkpoint.activeInvocation;
    if (pending !== undefined) {
      if (active !== undefined || authority.operation !== undefined || authority.policy === undefined ||
        !RuntimeRecoveryAuthorityValidator.validatePendingPolicy(pending, authority.policy)) {
        return result(false, 'POLICY_AUTHORITY_INVALID');
      }
      return result(true, 'AUTHORITY_VALID');
    }
    if (active !== undefined) {
      if (authority.policy === undefined || authority.operation === undefined ||
        !RuntimeRecoveryAuthorityValidator.validateActivePolicy(checkpoint, active, authority.policy,
          authority.policyVersion) ||
        !RuntimeRecoveryAuthorityValidator.validateOperation(checkpoint, active, authority.policy, authority.operation,
          authority.budgetReservations)) {
        return result(false, 'OPERATION_AUTHORITY_INVALID');
      }
      return result(true, 'AUTHORITY_VALID');
    }
    if (authority.policy !== undefined || authority.operation !== undefined) {
      return result(false, 'UNEXPECTED_OPERATION_AUTHORITY');
    }
    return result(true, 'AUTHORITY_VALID');
  }

  private static validateBudget(checkpoint: RuntimeTaskRecoveryCheckpoint,
    authority: RuntimeRecoveryAuthority): boolean {
    try {
      const ledger: BudgetLedger = new BudgetLedger();
      ledger.registerTask(checkpoint.snapshot.taskId, checkpoint.envelope.executionBudget);
      if (checkpoint.workflow !== undefined) {
        for (let i: number = 0; i < checkpoint.workflow.steps.length; i++) {
          ledger.registerStep(checkpoint.snapshot.taskId, checkpoint.workflow.steps[i].stepId,
            checkpoint.envelope.executionBudget);
        }
      }
      for (let i: number = 0; i < checkpoint.registeredProviderIds.length; i++) {
        ledger.registerProvider(checkpoint.snapshot.taskId, checkpoint.registeredProviderIds[i],
          checkpoint.envelope.executionBudget);
      }
      return ledger.hydrateTask(checkpoint.snapshot.taskId, authority.budgetScopes,
        authority.budgetReservations);
    } catch (error) {
      return false;
    }
  }

  private static validatePendingPolicy(pending: PolicyRequest,
    policy: RuntimeRecoveryPolicyAuthority): boolean {
    return policy.version === 1 && policy.decision === undefined && policy.grant === undefined &&
      ContractValidator.validatePolicyRequest(policy.request).valid && sameContract(pending, policy.request);
  }

  private static validateActivePolicy(checkpoint: RuntimeTaskRecoveryCheckpoint, active: ToolInvocation,
    policy: RuntimeRecoveryPolicyAuthority, policyVersion: string): boolean {
    const grant: AuthorizationGrant | undefined = policy.grant;
    if (policy.version !== 3 || policy.decision === undefined || grant === undefined ||
      !ContractValidator.validatePolicyRequest(policy.request).valid ||
      !ContractValidator.validateAuthorizationDecision(policy.decision).valid ||
      !ContractValidator.validateAuthorizationGrant(grant).valid ||
      policy.decision.decision !== AuthorizationDecisionType.APPROVED ||
      policy.request.taskId !== checkpoint.snapshot.taskId || policy.request.stepId !== active.stepId ||
      policy.request.operationId !== active.operationId || policy.request.toolId !== active.toolId ||
      policy.request.toolIdentityVersion !== active.toolIdentityVersion ||
      policy.request.schemaDigest !== active.schemaDigest || policy.request.argumentsDigest !== active.argumentsDigest ||
      policy.decision.policyRequestId !== policy.request.requestId ||
      grant.policyRequestId !== policy.request.requestId || grant.decisionCommandId !== policy.decision.commandId ||
      grant.grantId !== active.authorizationGrantId || grant.policyVersion !== policyVersion ||
      grant.taskId !== active.taskId || grant.stepId !== active.stepId ||
      grant.operationId !== active.operationId || grant.toolId !== active.toolId ||
      grant.toolIdentityVersion !== active.toolIdentityVersion || grant.schemaDigest !== active.schemaDigest ||
      grant.argumentsDigest !== active.argumentsDigest) return false;
    return true;
  }

  private static validateOperation(checkpoint: RuntimeTaskRecoveryCheckpoint, active: ToolInvocation,
    policy: RuntimeRecoveryPolicyAuthority, operation: RuntimeRecoveryOperationAuthority,
    reservations: BudgetReservationSnapshot[]): boolean {
    const grant: AuthorizationGrant = policy.grant as AuthorizationGrant;
    const step: WorkflowStep | undefined = findStep(checkpoint, active.stepId);
    const expectedKey: string = active.idempotencyKey === undefined ?
      'attempt:' + active.attemptId : active.idempotencyKey as string;
    if (step === undefined || operation.operationId !== active.operationId ||
      operation.invocationId !== active.invocationId || operation.taskId !== active.taskId ||
      operation.stepId !== active.stepId || operation.attemptId !== active.attemptId ||
      operation.toolId !== active.toolId || operation.toolIdentityVersion !== active.toolIdentityVersion ||
      operation.schemaDigest !== active.schemaDigest || operation.argumentsDigest !== active.argumentsDigest ||
      operation.idempotencyKey !== expectedKey || operation.idempotencyMode !== step.idempotencyMode ||
      operation.sideEffect !== step.sideEffect || operation.policyRequestId !== policy.request.requestId ||
      operation.budgetReservationId !== grant.budgetReservationId) return false;
    const budget: BudgetReservationSnapshot | undefined =
      findReservation(reservations, operation.budgetReservationId);
    if (budget === undefined || budget.taskId !== active.taskId || budget.stepId !== active.stepId ||
      budget.providerId !== policy.request.providerId) return false;
    if (operation.state === OperationJournalState.RESULT_RECORDED || operation.state === OperationJournalState.COMMITTED) {
      const outcome = operation.outcome;
      return outcome !== undefined && ContractValidator.validateToolOutcome(outcome).valid &&
        outcome.status === ToolOutcomeStatus.SUCCEEDED && outcome.invocationId === active.invocationId &&
        safePositive(operation.fencingToken) && safePositive(operation.dispatchCount) &&
        (operation.state === OperationJournalState.RESULT_RECORDED ?
          budget.state === BudgetReservationState.RESERVED && zeroActual(budget) :
          budget.state === BudgetReservationState.SETTLED);
    }
    if (operation.outcome !== undefined || !zeroActual(budget)) return false;
    if (operation.state === OperationJournalState.PREPARED) {
      return operation.fencingToken === 0 && operation.dispatchCount === 0 &&
        budget.state === BudgetReservationState.RESERVED;
    }
    if (operation.state === OperationJournalState.IN_FLIGHT) {
      return safePositive(operation.fencingToken) && safePositive(operation.dispatchCount) &&
        budget.state === BudgetReservationState.RESERVED;
    }
    if (operation.state === OperationJournalState.UNKNOWN_OUTCOME) {
      return safePositive(operation.fencingToken) && safePositive(operation.dispatchCount) &&
        budget.state === BudgetReservationState.UNKNOWN;
    }
    return false;
  }
}
