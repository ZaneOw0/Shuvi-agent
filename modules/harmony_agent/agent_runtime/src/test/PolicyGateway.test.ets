import { describe, expect, it } from '@ohos/hypium';
import {
  AuthorizationDecision,
  AuthorizationDecisionType,
  ExecutionBudget,
  PolicyRequest,
  RiskLevel,
  SideEffect,
  ToolDescriptor,
  ToolInvocation
} from '@harmony_agent/agent-contracts';
import { BudgetLedger } from '@harmony_agent/agent-core';
import {
  PolicyConstraintSet,
  PolicyDecisionResult
} from '../main/ets/policy/PolicyTypes';
import { DeterministicEligibilityFilter } from '../main/ets/policy/DeterministicEligibilityFilter';
import { PolicyGateway } from '../main/ets/policy/PolicyGateway';
import { SecretRedactor } from '../main/ets/policy/SecretRedactor';

function budget(calls: number = 3): ExecutionBudget {
  const value: ExecutionBudget = new ExecutionBudget();
  value.maxWallTimeMs = 10000;
  value.maxInputTokens = 10000;
  value.maxOutputTokens = 10000;
  value.maxMonetaryCostMicros = 10000;
  value.maxToolCalls = calls;
  value.maxAgentActivations = 10;
  value.maxRetries = 10;
  value.maxReplans = 10;
  return value;
}

function gateway(calls: number = 3): PolicyGateway {
  const ledger: BudgetLedger = new BudgetLedger();
  ledger.registerTask('task-1', budget(calls));
  ledger.registerStep('task-1', 'step-1', budget(calls));
  ledger.registerProvider('task-1', 'provider-1', budget(calls));
  return new PolicyGateway('policy-1', 5000, ledger);
}

function request(id: string = 'request-1'): PolicyRequest {
  const value: PolicyRequest = new PolicyRequest();
  value.requestId = id;
  value.userId = 'user-1';
  value.taskId = 'task-1';
  value.stepId = 'step-1';
  value.operationId = 'operation-1';
  value.toolId = 'calendar.create';
  value.toolIdentityVersion = 'tool-v1';
  value.providerId = 'provider-1';
  value.schemaDigest = 'sha256:schema';
  value.argumentsDigest = 'sha256:arguments';
  value.riskLevel = RiskLevel.MEDIUM;
  value.sideEffect = SideEffect.REVERSIBLE;
  value.estimatedCostMicros = 100;
  value.requestedAt = '2026-09-29T06:00:00.000Z';
  value.expiresAt = '2026-09-29T06:01:00.000Z';
  value.expiresAtMs = 10000;
  return value;
}

function decision(type: AuthorizationDecisionType = AuthorizationDecisionType.APPROVED): AuthorizationDecision {
  const value: AuthorizationDecision = new AuthorizationDecision();
  value.commandId = 'command-1';
  value.policyRequestId = 'request-1';
  value.userId = 'user-1';
  value.taskId = 'task-1';
  value.decision = type;
  if (type === AuthorizationDecisionType.DENIED) {
    value.denialReasonCode = 'USER_REJECTED';
  }
  value.decidedAt = '2026-09-29T06:00:01.000Z';
  value.decidedAtMs = 1000;
  return value;
}

function invocation(grantId: string, invocationId: string = 'invocation-1'): ToolInvocation {
  const value: ToolInvocation = new ToolInvocation();
  value.invocationId = invocationId;
  value.taskId = 'task-1';
  value.stepId = 'step-1';
  value.operationId = 'operation-1';
  value.attemptId = 'attempt-1';
  value.toolId = 'calendar.create';
  value.toolIdentityVersion = 'tool-v1';
  value.schemaDigest = 'sha256:schema';
  value.argumentsJson = '{"title":"review"}';
  value.argumentsDigest = 'sha256:arguments';
  value.authorizationGrantId = grantId;
  value.timeoutMs = 1000;
  value.createdAt = '2026-09-29T06:00:02.000Z';
  return value;
}

export default function policyGatewayTest(): void {
  describe('PolicyGateway', () => {
    it('filtersToolsByControlledPolicyMetadata', 0, () => {
      const tool: ToolDescriptor = new ToolDescriptor();
      tool.toolId = 'calendar.create';
      tool.providerId = 'provider-1';
      tool.riskLevel = RiskLevel.MEDIUM;
      tool.sideEffect = SideEffect.REVERSIBLE;
      const constraints: PolicyConstraintSet = new PolicyConstraintSet();
      constraints.allowedToolIds = ['calendar.create'];
      constraints.allowedProviderIds = ['provider-1'];
      constraints.allowedSideEffects = [SideEffect.REVERSIBLE];
      constraints.maxRiskLevel = RiskLevel.MEDIUM;
      expect(DeterministicEligibilityFilter.evaluate(tool, constraints).eligible).assertTrue();
      tool.riskLevel = RiskLevel.HIGH;
      expect(DeterministicEligibilityFilter.evaluate(tool, constraints).code).assertEqual('RISK_TOO_HIGH');
    });

    it('turnsExternalApprovalIntoBoundInternalGrant', 0, () => {
      const value: PolicyGateway = gateway();
      expect(value.registerRequest(request())).assertTrue();
      const applied: PolicyDecisionResult = value.applyDecision(decision(), 1000);
      expect(applied.authorized).assertTrue();
      expect(applied.grant?.policyVersion).assertEqual('policy-1');
      expect(applied.grant?.budgetReservationId).assertEqual('policy:request-1');
      expect(applied.grant?.decisionCommandId).assertEqual('command-1');
    });

    it('keepsUserDenialSeparateFromGrantIssuance', 0, () => {
      const value: PolicyGateway = gateway();
      value.registerRequest(request());
      const applied: PolicyDecisionResult = value.applyDecision(decision(AuthorizationDecisionType.DENIED), 1000);
      expect(applied.processed).assertTrue();
      expect(applied.authorized).assertFalse();
      expect(applied.code).assertEqual('USER_DENIED');
    });

    it('replaysSameDecisionWithoutIssuingAnotherGrant', 0, () => {
      const value: PolicyGateway = gateway(1);
      const mutableRequest: PolicyRequest = request();
      value.registerRequest(mutableRequest);
      mutableRequest.toolId = 'mutated.after.registration';
      const first: PolicyDecisionResult = value.applyDecision(decision(), 1000);
      const exposedGrantId: string = first.grant?.grantId ?? '';
      if (first.grant !== undefined) {
        first.grant.grantId = 'mutated.after.issuance';
      }
      const replay: PolicyDecisionResult = value.applyDecision(decision(), 1001);
      expect(replay.authorized).assertTrue();
      expect(replay.grant?.grantId).assertEqual(exposedGrantId);
    });

    it('rejectsChangedBindingAndSingleUseReplay', 0, () => {
      const value: PolicyGateway = gateway();
      value.registerRequest(request());
      const applied: PolicyDecisionResult = value.applyDecision(decision(), 1000);
      const grantId: string = applied.grant?.grantId ?? '';
      const changed: ToolInvocation = invocation(grantId);
      changed.argumentsDigest = 'sha256:changed';
      expect(value.authorizeInvocation(changed, 1100).code).assertEqual('GRANT_BINDING_MISMATCH');

      const first: ToolInvocation = invocation(grantId);
      expect(value.authorizeInvocation(first, 1100).allowed).assertTrue();
      expect(value.authorizeInvocation(first, 1101).idempotentReplay).assertTrue();
      const changedReplay: ToolInvocation = invocation(grantId);
      changedReplay.argumentsJson = '{"title":"changed"}';
      expect(value.authorizeInvocation(changedReplay, 1101).code).assertEqual('GRANT_ALREADY_USED');
      expect(value.authorizeInvocation(invocation(grantId, 'invocation-2'), 1102).code)
        .assertEqual('GRANT_ALREADY_USED');
    });

    it('rejectsExpiredRequestsAndExhaustedBudgets', 0, () => {
      const expired: PolicyGateway = gateway();
      expired.registerRequest(request());
      expect(expired.applyDecision(decision(), 10000).code).assertEqual('REQUEST_EXPIRED');

      const exhausted: PolicyGateway = gateway(0);
      exhausted.registerRequest(request());
      expect(exhausted.applyDecision(decision(), 1000).code).assertEqual('BUDGET_DENIED');
    });

    it('rejectsWrongTaskConflictingCommandAndRevokedGrant', 0, () => {
      const value: PolicyGateway = gateway();
      value.registerRequest(request());
      const wrongTask: AuthorizationDecision = decision();
      wrongTask.taskId = 'other-task';
      expect(value.applyDecision(wrongTask, 1000).code).assertEqual('DECISION_BINDING_MISMATCH');

      const conflict: AuthorizationDecision = decision();
      conflict.taskId = 'task-1';
      expect(value.applyDecision(conflict, 1001).code).assertEqual('COMMAND_CONFLICT');

      const second: PolicyGateway = gateway();
      second.registerRequest(request());
      const applied: PolicyDecisionResult = second.applyDecision(decision(), 1000);
      const grantId: string = applied.grant?.grantId ?? '';
      expect(second.revokeGrant(grantId)).assertTrue();
      expect(second.authorizeInvocation(invocation(grantId), 1100).code).assertEqual('GRANT_REVOKED');
    });

    it('redactsEveryExactSecretOccurrence', 0, () => {
      const output: string = SecretRedactor.redact('token=secret; again=secret', ['secret', '']);
      expect(output).assertEqual('token=[REDACTED]; again=[REDACTED]');
      expect(output.includes('secret')).assertFalse();
    });
  });
}
