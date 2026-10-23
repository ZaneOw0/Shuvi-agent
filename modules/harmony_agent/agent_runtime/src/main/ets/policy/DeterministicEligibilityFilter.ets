import { RiskLevel, ToolDescriptor } from '@harmony_agent/agent-contracts';
import { EligibilityResult, PolicyConstraintSet } from './PolicyTypes';

function includes(values: string[], target: string): boolean {
  for (let i: number = 0; i < values.length; i++) {
    if (values[i] === target) {
      return true;
    }
  }
  return false;
}

function riskRank(value: RiskLevel): number {
  if (value === RiskLevel.LOW) {
    return 0;
  }
  if (value === RiskLevel.MEDIUM) {
    return 1;
  }
  if (value === RiskLevel.HIGH) {
    return 2;
  }
  return 3;
}

export class DeterministicEligibilityFilter {
  static evaluate(tool: ToolDescriptor, constraints: PolicyConstraintSet): EligibilityResult {
    const result: EligibilityResult = new EligibilityResult();
    if (!includes(constraints.allowedToolIds, tool.toolId)) {
      result.code = 'TOOL_NOT_ALLOWED';
      return result;
    }
    if (!includes(constraints.allowedProviderIds, tool.providerId)) {
      result.code = 'PROVIDER_NOT_ALLOWED';
      return result;
    }
    if (!includes(constraints.allowedSideEffects, tool.sideEffect)) {
      result.code = 'SIDE_EFFECT_NOT_ALLOWED';
      return result;
    }
    if (riskRank(tool.riskLevel) > riskRank(constraints.maxRiskLevel)) {
      result.code = 'RISK_TOO_HIGH';
      return result;
    }
    result.eligible = true;
    result.code = 'ELIGIBLE';
    return result;
  }
}
