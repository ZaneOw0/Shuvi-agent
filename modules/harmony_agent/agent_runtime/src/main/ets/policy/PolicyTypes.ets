import { AuthorizationGrant, RiskLevel, SideEffect } from '@harmony_agent/agent-contracts';

export class PolicyConstraintSet {
  allowedToolIds: string[] = [];
  allowedProviderIds: string[] = [];
  allowedSideEffects: SideEffect[] = [];
  maxRiskLevel: RiskLevel = RiskLevel.LOW;
}

export class EligibilityResult {
  eligible: boolean = false;
  code: string = '';
}

export class PolicyDecisionResult {
  processed: boolean = false;
  authorized: boolean = false;
  code: string = '';
  grant?: AuthorizationGrant;
}

export class GrantVerificationResult {
  allowed: boolean = false;
  idempotentReplay: boolean = false;
  code: string = '';
}
