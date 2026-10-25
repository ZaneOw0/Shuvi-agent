import {
  isNonEmptyText,
  isNonNegativeInteger,
  isPositiveInteger,
  TestKitValidationResult
} from './Common';

export enum FaultKind {
  NETWORK_DISCONNECTED = 'networkDisconnected',
  TIMEOUT = 'timeout',
  HTTP_429 = 'http429',
  HTTP_5XX = 'http5xx',
  AUTHENTICATION_FAILED = 'authenticationFailed',
  PERMISSION_DENIED = 'permissionDenied',
  SCHEMA_DRIFT = 'schemaDrift',
  DUPLICATE_RESPONSE = 'duplicateResponse',
  APPLICATION_RESTART = 'applicationRestart',
  BUDGET_EXHAUSTED = 'budgetExhausted',
  LOW_QUALITY_OUTPUT = 'lowQualityOutput',
  IRREVERSIBLE_UNKNOWN_OUTCOME = 'irreversibleUnknownOutcome'
}

export enum FaultPhase {
  BEFORE_DISPATCH = 'beforeDispatch',
  DURING_CALL = 'duringCall',
  AFTER_RESPONSE = 'afterResponse',
  BEFORE_COMMIT = 'beforeCommit'
}

export class FaultRule {
  ruleId: string = '';
  targetId: string = '';
  phase: FaultPhase = FaultPhase.DURING_CALL;
  occurrence: number = 1;
  kind: FaultKind = FaultKind.NETWORK_DISCONNECTED;
  latencyMs: number = 0;
  statusCode: number = 0;
  responseCopies: number = 1;
  responseJson: string = '';
}

export class FaultScript {
  scriptId: string = '';
  scriptVersion: string = '';
  rules: FaultRule[] = [];
}

export class FaultDecision {
  matched: boolean = false;
  ruleId: string = '';
  kind: FaultKind | undefined = undefined;
  latencyMs: number = 0;
  statusCode: number = 0;
  responseCopies: number = 1;
  responseJson: string = '';
}

class FaultCounter {
  targetId: string = '';
  phase: FaultPhase = FaultPhase.DURING_CALL;
  occurrence: number = 0;
}

function cloneRule(source: FaultRule): FaultRule {
  const clone: FaultRule = new FaultRule();
  clone.ruleId = source.ruleId;
  clone.targetId = source.targetId;
  clone.phase = source.phase;
  clone.occurrence = source.occurrence;
  clone.kind = source.kind;
  clone.latencyMs = source.latencyMs;
  clone.statusCode = source.statusCode;
  clone.responseCopies = source.responseCopies;
  clone.responseJson = source.responseJson;
  return clone;
}

function containsText(values: string[], target: string): boolean {
  for (let index: number = 0; index < values.length; index++) {
    if (values[index] === target) return true;
  }
  return false;
}

export class FaultScriptValidator {
  static validate(script: FaultScript): TestKitValidationResult {
    const result: TestKitValidationResult = new TestKitValidationResult();
    if (!isNonEmptyText(script.scriptId)) result.addIssue('scriptId is required');
    if (!isNonEmptyText(script.scriptVersion)) result.addIssue('scriptVersion is required');
    const seenRuleIds: string[] = [];
    const seenSchedules: string[] = [];
    for (let index: number = 0; index < script.rules.length; index++) {
      const rule: FaultRule = script.rules[index];
      const prefix: string = 'rules[' + index.toString() + '] ';
      if (!isNonEmptyText(rule.ruleId)) {
        result.addIssue(prefix + 'ruleId is required');
      } else if (containsText(seenRuleIds, rule.ruleId)) {
        result.addIssue(prefix + 'ruleId must be unique');
      } else {
        seenRuleIds.push(rule.ruleId);
      }
      if (!isNonEmptyText(rule.targetId)) result.addIssue(prefix + 'targetId is required');
      if (!isPositiveInteger(rule.occurrence)) result.addIssue(prefix + 'occurrence must be a positive integer');
      if (isNonEmptyText(rule.targetId) && isPositiveInteger(rule.occurrence)) {
        const scheduleKey: string = rule.targetId + '\n' + rule.phase + '\n' + rule.occurrence.toString();
        if (containsText(seenSchedules, scheduleKey)) {
          result.addIssue(prefix + 'target, phase, and occurrence must be unique');
        } else {
          seenSchedules.push(scheduleKey);
        }
      }
      if (!isNonNegativeInteger(rule.latencyMs)) result.addIssue(prefix + 'latencyMs must be a non-negative integer');
      if (!isNonNegativeInteger(rule.statusCode)) result.addIssue(prefix + 'statusCode must be a non-negative integer');
      if (!isPositiveInteger(rule.responseCopies)) {
        result.addIssue(prefix + 'responseCopies must be a positive integer');
      }
      if (rule.kind === FaultKind.TIMEOUT && rule.latencyMs === 0) {
        result.addIssue(prefix + 'timeout requires latencyMs');
      }
      if (rule.kind === FaultKind.HTTP_429 && rule.statusCode !== 429) {
        result.addIssue(prefix + 'http429 requires statusCode 429');
      }
      if (rule.kind === FaultKind.HTTP_5XX && (rule.statusCode < 500 || rule.statusCode > 599)) {
        result.addIssue(prefix + 'http5xx requires a 5xx statusCode');
      }
      if (rule.kind === FaultKind.DUPLICATE_RESPONSE && rule.responseCopies < 2) {
        result.addIssue(prefix + 'duplicateResponse requires at least two copies');
      }
      if ((rule.kind === FaultKind.SCHEMA_DRIFT || rule.kind === FaultKind.LOW_QUALITY_OUTPUT) &&
        !isNonEmptyText(rule.responseJson)) {
        result.addIssue(prefix + 'fault requires responseJson');
      }
    }
    return result;
  }
}

export class DeterministicFaultInjector {
  private readonly rules: FaultRule[] = [];
  private readonly counters: FaultCounter[] = [];

  constructor(script: FaultScript) {
    const validation: TestKitValidationResult = FaultScriptValidator.validate(script);
    if (!validation.valid) throw new Error(validation.issues.join('; '));
    for (let index: number = 0; index < script.rules.length; index++) {
      this.rules.push(cloneRule(script.rules[index]));
    }
  }

  next(targetId: string, phase: FaultPhase): FaultDecision {
    const occurrence: number = this.increment(targetId, phase);
    for (let index: number = 0; index < this.rules.length; index++) {
      const rule: FaultRule = this.rules[index];
      if (rule.targetId === targetId && rule.phase === phase && rule.occurrence === occurrence) {
        return this.toDecision(rule);
      }
    }
    return new FaultDecision();
  }

  reset(): void {
    this.counters.splice(0, this.counters.length);
  }

  private increment(targetId: string, phase: FaultPhase): number {
    for (let index: number = 0; index < this.counters.length; index++) {
      const counter: FaultCounter = this.counters[index];
      if (counter.targetId === targetId && counter.phase === phase) {
        counter.occurrence += 1;
        return counter.occurrence;
      }
    }
    const created: FaultCounter = new FaultCounter();
    created.targetId = targetId;
    created.phase = phase;
    created.occurrence = 1;
    this.counters.push(created);
    return created.occurrence;
  }

  private toDecision(rule: FaultRule): FaultDecision {
    const decision: FaultDecision = new FaultDecision();
    decision.matched = true;
    decision.ruleId = rule.ruleId;
    decision.kind = rule.kind;
    decision.latencyMs = rule.latencyMs;
    decision.statusCode = rule.statusCode;
    decision.responseCopies = rule.responseCopies;
    decision.responseJson = rule.responseJson;
    return decision;
  }
}
