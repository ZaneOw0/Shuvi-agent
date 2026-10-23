import {
  AuthorizationDecision,
  AuthorizationDecisionType,
  AuthorizationGrant,
  ContractValidator,
  PolicyRequest,
  ToolInvocation
} from '@harmony_agent/agent-contracts';
import { BudgetAmount, BudgetLedger, BudgetReservationRequest } from '@harmony_agent/agent-core';
import { GrantVerificationResult, PolicyDecisionResult } from './PolicyTypes';

class ProcessedDecision {
  decision: AuthorizationDecision = new AuthorizationDecision();
  result: PolicyDecisionResult = new PolicyDecisionResult();
}

class GrantUse {
  grantId: string = '';
  invocation: ToolInvocation = new ToolInvocation();
}

function copyRequest(source: PolicyRequest): PolicyRequest {
  const value: PolicyRequest = new PolicyRequest();
  value.requestId = source.requestId;
  value.userId = source.userId;
  value.taskId = source.taskId;
  value.stepId = source.stepId;
  value.operationId = source.operationId;
  value.toolId = source.toolId;
  value.toolIdentityVersion = source.toolIdentityVersion;
  value.providerId = source.providerId;
  value.schemaDigest = source.schemaDigest;
  value.argumentsDigest = source.argumentsDigest;
  value.riskLevel = source.riskLevel;
  value.sideEffect = source.sideEffect;
  value.estimatedCostMicros = source.estimatedCostMicros;
  value.requestedAt = source.requestedAt;
  value.expiresAt = source.expiresAt;
  value.expiresAtMs = source.expiresAtMs;
  return value;
}

function copyDecision(source: AuthorizationDecision): AuthorizationDecision {
  const value: AuthorizationDecision = new AuthorizationDecision();
  value.commandId = source.commandId;
  value.policyRequestId = source.policyRequestId;
  value.userId = source.userId;
  value.taskId = source.taskId;
  value.decision = source.decision;
  value.denialReasonCode = source.denialReasonCode;
  value.decidedAt = source.decidedAt;
  value.decidedAtMs = source.decidedAtMs;
  return value;
}

function copyGrant(source: AuthorizationGrant): AuthorizationGrant {
  const value: AuthorizationGrant = new AuthorizationGrant();
  value.grantId = source.grantId;
  value.policyRequestId = source.policyRequestId;
  value.decisionCommandId = source.decisionCommandId;
  value.userId = source.userId;
  value.taskId = source.taskId;
  value.stepId = source.stepId;
  value.operationId = source.operationId;
  value.toolId = source.toolId;
  value.toolIdentityVersion = source.toolIdentityVersion;
  value.schemaDigest = source.schemaDigest;
  value.argumentsDigest = source.argumentsDigest;
  value.budgetReservationId = source.budgetReservationId;
  value.policyVersion = source.policyVersion;
  value.issuedAt = source.issuedAt;
  value.expiresAt = source.expiresAt;
  value.issuedAtMs = source.issuedAtMs;
  value.expiresAtMs = source.expiresAtMs;
  return value;
}

function copyInvocation(source: ToolInvocation): ToolInvocation {
  const value: ToolInvocation = new ToolInvocation();
  value.invocationId = source.invocationId;
  value.taskId = source.taskId;
  value.stepId = source.stepId;
  value.operationId = source.operationId;
  value.attemptId = source.attemptId;
  value.toolId = source.toolId;
  value.toolIdentityVersion = source.toolIdentityVersion;
  value.schemaDigest = source.schemaDigest;
  value.argumentsJson = source.argumentsJson;
  value.argumentsDigest = source.argumentsDigest;
  value.idempotencyKey = source.idempotencyKey;
  value.authorizationGrantId = source.authorizationGrantId;
  value.timeoutMs = source.timeoutMs;
  value.createdAt = source.createdAt;
  return value;
}

function sameInvocation(left: ToolInvocation, right: ToolInvocation): boolean {
  return left.invocationId === right.invocationId && left.taskId === right.taskId &&
    left.stepId === right.stepId && left.operationId === right.operationId &&
    left.attemptId === right.attemptId && left.toolId === right.toolId &&
    left.toolIdentityVersion === right.toolIdentityVersion && left.schemaDigest === right.schemaDigest &&
    left.argumentsJson === right.argumentsJson && left.argumentsDigest === right.argumentsDigest &&
    left.idempotencyKey === right.idempotencyKey &&
    left.authorizationGrantId === right.authorizationGrantId && left.timeoutMs === right.timeoutMs &&
    left.createdAt === right.createdAt;
}

function copyResult(source: PolicyDecisionResult): PolicyDecisionResult {
  const value: PolicyDecisionResult = new PolicyDecisionResult();
  value.processed = source.processed;
  value.authorized = source.authorized;
  value.code = source.code;
  const grant: AuthorizationGrant | undefined = source.grant;
  if (grant !== undefined) {
    value.grant = copyGrant(grant);
  }
  return value;
}

function sameDecision(left: AuthorizationDecision, right: AuthorizationDecision): boolean {
  return left.commandId === right.commandId && left.policyRequestId === right.policyRequestId &&
    left.userId === right.userId && left.taskId === right.taskId && left.decision === right.decision &&
    left.denialReasonCode === right.denialReasonCode && left.decidedAtMs === right.decidedAtMs;
}

export class PolicyGateway {
  private policyVersion: string;
  private grantTtlMs: number;
  private budgetLedger: BudgetLedger;
  private requests: PolicyRequest[] = [];
  private processed: ProcessedDecision[] = [];
  private grants: AuthorizationGrant[] = [];
  private uses: GrantUse[] = [];
  private revokedGrantIds: string[] = [];

  constructor(policyVersion: string, grantTtlMs: number, budgetLedger: BudgetLedger) {
    if (policyVersion.length === 0 || !Number.isSafeInteger(grantTtlMs) || grantTtlMs <= 0) {
      throw new Error('invalid policy gateway configuration');
    }
    this.policyVersion = policyVersion;
    this.grantTtlMs = grantTtlMs;
    this.budgetLedger = budgetLedger;
  }

  registerRequest(request: PolicyRequest): boolean {
    if (!ContractValidator.validatePolicyRequest(request).valid || this.findRequest(request.requestId) >= 0) {
      return false;
    }
    this.requests.push(copyRequest(request));
    return true;
  }

  hasRequest(requestId: string): boolean {
    return this.findRequest(requestId) >= 0;
  }

  getRequest(requestId: string): PolicyRequest | undefined {
    const index: number = this.findRequest(requestId);
    return index < 0 ? undefined : copyRequest(this.requests[index]);
  }

  getDecisionForRequest(requestId: string): AuthorizationDecision | undefined {
    for (let i: number = 0; i < this.processed.length; i++) {
      if (this.processed[i].decision.policyRequestId === requestId) {
        return copyDecision(this.processed[i].decision);
      }
    }
    return undefined;
  }

  getGrant(grantId: string): AuthorizationGrant | undefined {
    const index: number = this.findGrant(grantId);
    return index < 0 ? undefined : copyGrant(this.grants[index]);
  }

  applyDecision(decision: AuthorizationDecision, nowMs: number): PolicyDecisionResult {
    if (!ContractValidator.validateAuthorizationDecision(decision).valid) {
      return this.result(false, false, 'INVALID_DECISION');
    }
    const processedIndex: number = this.findProcessed(decision.commandId);
    if (processedIndex >= 0) {
      if (sameDecision(this.processed[processedIndex].decision, decision)) {
        return copyResult(this.processed[processedIndex].result);
      }
      return this.result(false, false, 'COMMAND_CONFLICT');
    }
    const requestIndex: number = this.findRequest(decision.policyRequestId);
    if (requestIndex < 0) {
      return this.remember(decision, this.result(true, false, 'REQUEST_NOT_FOUND'));
    }
    const request: PolicyRequest = this.requests[requestIndex];
    if (decision.userId !== request.userId || decision.taskId !== request.taskId) {
      return this.remember(decision, this.result(true, false, 'DECISION_BINDING_MISMATCH'));
    }
    if (decision.decidedAtMs > nowMs || nowMs >= request.expiresAtMs) {
      return this.remember(decision, this.result(true, false, 'REQUEST_EXPIRED'));
    }
    if (decision.decision === AuthorizationDecisionType.DENIED) {
      return this.remember(decision, this.result(true, false, 'USER_DENIED'));
    }

    const reservation: BudgetReservationRequest = new BudgetReservationRequest();
    reservation.reservationId = 'policy:' + request.requestId;
    reservation.taskId = request.taskId;
    reservation.stepId = request.stepId;
    reservation.providerId = request.providerId;
    reservation.amount.toolCalls = 1;
    reservation.amount.monetaryCostMicros = request.estimatedCostMicros;
    if (!this.budgetLedger.reserve(reservation).accepted) {
      return this.remember(decision, this.result(true, false, 'BUDGET_DENIED'));
    }

    const grant: AuthorizationGrant = new AuthorizationGrant();
    grant.grantId = 'grant:' + request.requestId + ':' + decision.commandId;
    grant.policyRequestId = request.requestId;
    grant.decisionCommandId = decision.commandId;
    grant.userId = request.userId;
    grant.taskId = request.taskId;
    grant.stepId = request.stepId;
    grant.operationId = request.operationId;
    grant.toolId = request.toolId;
    grant.toolIdentityVersion = request.toolIdentityVersion;
    grant.schemaDigest = request.schemaDigest;
    grant.argumentsDigest = request.argumentsDigest;
    grant.budgetReservationId = reservation.reservationId;
    grant.policyVersion = this.policyVersion;
    grant.issuedAtMs = nowMs;
    grant.expiresAtMs = Math.min(request.expiresAtMs, nowMs + this.grantTtlMs);
    grant.issuedAt = new Date(grant.issuedAtMs).toISOString();
    grant.expiresAt = new Date(grant.expiresAtMs).toISOString();
    this.grants.push(grant);
    const result: PolicyDecisionResult = this.result(true, true, 'AUTHORIZED');
    result.grant = grant;
    return this.remember(decision, result);
  }

  authorizeInvocation(invocation: ToolInvocation, nowMs: number): GrantVerificationResult {
    const result: GrantVerificationResult = new GrantVerificationResult();
    if (!ContractValidator.validateToolInvocation(invocation).valid) {
      result.code = 'INVALID_INVOCATION';
      return result;
    }
    const grantIndex: number = this.findGrant(invocation.authorizationGrantId);
    if (grantIndex < 0) {
      result.code = 'GRANT_NOT_FOUND';
      return result;
    }
    const grant: AuthorizationGrant = this.grants[grantIndex];
    if (this.isRevoked(grant.grantId)) {
      result.code = 'GRANT_REVOKED';
      return result;
    }
    if (grant.policyVersion !== this.policyVersion) {
      result.code = 'POLICY_VERSION_CHANGED';
      return result;
    }
    if (nowMs >= grant.expiresAtMs) {
      result.code = 'GRANT_EXPIRED';
      return result;
    }
    if (grant.taskId !== invocation.taskId || grant.stepId !== invocation.stepId ||
      grant.operationId !== invocation.operationId || grant.toolId !== invocation.toolId ||
      grant.toolIdentityVersion !== invocation.toolIdentityVersion || grant.schemaDigest !== invocation.schemaDigest ||
      grant.argumentsDigest !== invocation.argumentsDigest) {
      result.code = 'GRANT_BINDING_MISMATCH';
      return result;
    }
    const useIndex: number = this.findUse(grant.grantId);
    if (useIndex >= 0) {
      if (sameInvocation(this.uses[useIndex].invocation, invocation)) {
        result.allowed = true;
        result.idempotentReplay = true;
        result.code = 'IDEMPOTENT_REPLAY';
        return result;
      }
      result.code = 'GRANT_ALREADY_USED';
      return result;
    }
    const use: GrantUse = new GrantUse();
    use.grantId = grant.grantId;
    use.invocation = copyInvocation(invocation);
    this.uses.push(use);
    result.allowed = true;
    result.code = 'ALLOWED';
    return result;
  }

  revokeGrant(grantId: string): boolean {
    if (this.findGrant(grantId) < 0 || this.isRevoked(grantId)) {
      return false;
    }
    this.revokedGrantIds.push(grantId);
    return true;
  }

  private result(processed: boolean, authorized: boolean, code: string): PolicyDecisionResult {
    const value: PolicyDecisionResult = new PolicyDecisionResult();
    value.processed = processed;
    value.authorized = authorized;
    value.code = code;
    return value;
  }

  private remember(decision: AuthorizationDecision, result: PolicyDecisionResult): PolicyDecisionResult {
    const record: ProcessedDecision = new ProcessedDecision();
    record.decision = copyDecision(decision);
    record.result = copyResult(result);
    this.processed.push(record);
    return copyResult(result);
  }

  private findRequest(requestId: string): number {
    for (let i: number = 0; i < this.requests.length; i++) {
      if (this.requests[i].requestId === requestId) {
        return i;
      }
    }
    return -1;
  }

  private findProcessed(commandId: string): number {
    for (let i: number = 0; i < this.processed.length; i++) {
      if (this.processed[i].decision.commandId === commandId) {
        return i;
      }
    }
    return -1;
  }

  private findGrant(grantId: string): number {
    for (let i: number = 0; i < this.grants.length; i++) {
      if (this.grants[i].grantId === grantId) {
        return i;
      }
    }
    return -1;
  }

  private findUse(grantId: string): number {
    for (let i: number = 0; i < this.uses.length; i++) {
      if (this.uses[i].grantId === grantId) {
        return i;
      }
    }
    return -1;
  }

  private isRevoked(grantId: string): boolean {
    for (let i: number = 0; i < this.revokedGrantIds.length; i++) {
      if (this.revokedGrantIds[i] === grantId) {
        return true;
      }
    }
    return false;
  }
}
