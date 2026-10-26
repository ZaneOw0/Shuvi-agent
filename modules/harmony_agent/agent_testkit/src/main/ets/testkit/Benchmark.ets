import { AGENT_CONTRACT_SCHEMA_VERSION } from '@harmony_agent/agent-contracts';
import {
  AGENT_TESTKIT_SCHEMA_VERSION,
  isNonEmptyText,
  isNonNegativeInteger,
  TestKitValidationResult
} from './Common';

export enum BenchmarkArmKind {
  STRONG_SINGLE_AGENT = 'strongSingleAgent',
  MULTI_AGENT = 'multiAgent'
}

export class BenchmarkArm {
  armId: string = '';
  kind: BenchmarkArmKind = BenchmarkArmKind.STRONG_SINGLE_AGENT;
  permissionPolicyVersion: string = '';
  contextPolicyVersion: string = '';
}

export class BenchmarkManifest {
  schemaVersion: string = AGENT_TESTKIT_SCHEMA_VERSION;
  benchmarkId: string = '';
  suiteVersion: string = '';
  frozenAt: string = '';
  datasetDigest: string = '';
  modelId: string = '';
  modelVersion: string = '';
  providerId: string = '';
  region: string = '';
  priceSnapshotId: string = '';
  priceSnapshotDigest: string = '';
  contractSchemaVersion: string = AGENT_CONTRACT_SCHEMA_VERSION;
  routerPolicyVersion: string = '';
  arms: BenchmarkArm[] = [];
}

export class BenchmarkSample {
  caseId: string = '';
  runId: string = '';
  armId: string = '';
  passed: boolean = false;
  qualityScoreBasisPoints: number = 0;
  inputTokens: number = 0;
  outputTokens: number = 0;
  monetaryCostMicros: number = 0;
  latencyMs: number = 0;
  toolCalls: number = 0;
  agentActivations: number = 0;
  recoveryEvents: number = 0;
  routerDecisions: number = 0;
  routerCorrectDecisions: number = 0;
}

export class BenchmarkRecordResult extends TestKitValidationResult {
  accepted: boolean = true;

  addIssue(issue: string): void {
    super.addIssue(issue);
    this.accepted = false;
  }
}

export class BenchmarkSummary {
  sampleCount: number = 0;
  passedCount: number = 0;
  failedCount: number = 0;
  averageQualityBasisPoints: number = 0;
  inputTokens: number = 0;
  outputTokens: number = 0;
  monetaryCostMicros: number = 0;
  latencyP50Ms: number = 0;
  latencyP95Ms: number = 0;
  toolCalls: number = 0;
  agentActivations: number = 0;
  recoveryEvents: number = 0;
  routerDecisions: number = 0;
  routerCorrectDecisions: number = 0;
}

export class BenchmarkReport {
  manifest: BenchmarkManifest = new BenchmarkManifest();
  summary: BenchmarkSummary = new BenchmarkSummary();
  armSummaries: BenchmarkArmReport[] = [];
}

export class BenchmarkArmReport {
  armId: string = '';
  summary: BenchmarkSummary = new BenchmarkSummary();
}

function containsText(values: string[], target: string): boolean {
  for (let index: number = 0; index < values.length; index++) {
    if (values[index] === target) return true;
  }
  return false;
}

function cloneArm(source: BenchmarkArm): BenchmarkArm {
  const clone: BenchmarkArm = new BenchmarkArm();
  clone.armId = source.armId;
  clone.kind = source.kind;
  clone.permissionPolicyVersion = source.permissionPolicyVersion;
  clone.contextPolicyVersion = source.contextPolicyVersion;
  return clone;
}

function cloneManifest(source: BenchmarkManifest): BenchmarkManifest {
  const clone: BenchmarkManifest = new BenchmarkManifest();
  clone.schemaVersion = source.schemaVersion;
  clone.benchmarkId = source.benchmarkId;
  clone.suiteVersion = source.suiteVersion;
  clone.frozenAt = source.frozenAt;
  clone.datasetDigest = source.datasetDigest;
  clone.modelId = source.modelId;
  clone.modelVersion = source.modelVersion;
  clone.providerId = source.providerId;
  clone.region = source.region;
  clone.priceSnapshotId = source.priceSnapshotId;
  clone.priceSnapshotDigest = source.priceSnapshotDigest;
  clone.contractSchemaVersion = source.contractSchemaVersion;
  clone.routerPolicyVersion = source.routerPolicyVersion;
  for (let index: number = 0; index < source.arms.length; index++) clone.arms.push(cloneArm(source.arms[index]));
  return clone;
}

function integerField(result: TestKitValidationResult, field: string, value: number): void {
  if (!isNonNegativeInteger(value)) result.addIssue(field + ' must be a non-negative integer');
}

function isPinnedDigest(value: string): boolean {
  return value.startsWith('sha256:') && value.length > 'sha256:'.length;
}

function hasIsoDatePrefix(value: string): boolean {
  return value.length >= 10 && value.charAt(4) === '-' && value.charAt(7) === '-';
}

export class BenchmarkManifestValidator {
  static validate(manifest: BenchmarkManifest): TestKitValidationResult {
    const result: TestKitValidationResult = new TestKitValidationResult();
    if (manifest.schemaVersion !== AGENT_TESTKIT_SCHEMA_VERSION) result.addIssue('unsupported schemaVersion');
    if (!isNonEmptyText(manifest.benchmarkId)) result.addIssue('benchmarkId is required');
    if (!isNonEmptyText(manifest.suiteVersion)) result.addIssue('suiteVersion is required');
    if (!hasIsoDatePrefix(manifest.frozenAt)) result.addIssue('frozenAt must include an ISO date');
    if (!isPinnedDigest(manifest.datasetDigest)) result.addIssue('datasetDigest must be a sha256 digest');
    if (!isNonEmptyText(manifest.modelId)) result.addIssue('modelId is required');
    if (!isNonEmptyText(manifest.modelVersion)) result.addIssue('modelVersion is required');
    if (!isNonEmptyText(manifest.providerId)) result.addIssue('providerId is required');
    if (!isNonEmptyText(manifest.region)) result.addIssue('region is required');
    if (!isNonEmptyText(manifest.priceSnapshotId)) result.addIssue('priceSnapshotId is required');
    if (!isPinnedDigest(manifest.priceSnapshotDigest)) result.addIssue('priceSnapshotDigest must be a sha256 digest');
    if (manifest.contractSchemaVersion !== AGENT_CONTRACT_SCHEMA_VERSION) {
      result.addIssue('contractSchemaVersion must match agent contracts');
    }
    if (!isNonEmptyText(manifest.routerPolicyVersion)) result.addIssue('routerPolicyVersion is required');
    if (manifest.arms.length === 0) result.addIssue('at least one benchmark arm is required');

    const armIds: string[] = [];
    let permissionPolicyVersion: string = '';
    let contextPolicyVersion: string = '';
    for (let index: number = 0; index < manifest.arms.length; index++) {
      const arm: BenchmarkArm = manifest.arms[index];
      const prefix: string = 'arms[' + index.toString() + '] ';
      if (!isNonEmptyText(arm.armId)) {
        result.addIssue(prefix + 'armId is required');
      } else if (containsText(armIds, arm.armId)) {
        result.addIssue(prefix + 'armId must be unique');
      } else {
        armIds.push(arm.armId);
      }
      if (!isNonEmptyText(arm.permissionPolicyVersion)) {
        result.addIssue(prefix + 'permissionPolicyVersion is required');
      }
      if (!isNonEmptyText(arm.contextPolicyVersion)) result.addIssue(prefix + 'contextPolicyVersion is required');
      if (index === 0) {
        permissionPolicyVersion = arm.permissionPolicyVersion;
        contextPolicyVersion = arm.contextPolicyVersion;
      } else {
        if (arm.permissionPolicyVersion !== permissionPolicyVersion) {
          result.addIssue('all benchmark arms must use the same permission policy');
        }
        if (arm.contextPolicyVersion !== contextPolicyVersion) {
          result.addIssue('all benchmark arms must use the same context policy');
        }
      }
    }
    return result;
  }
}

export class BenchmarkEvaluator {
  private readonly manifest: BenchmarkManifest;
  private readonly samples: BenchmarkSample[] = [];
  private readonly sampleKeys: string[] = [];

  constructor(manifest: BenchmarkManifest) {
    const validation: TestKitValidationResult = BenchmarkManifestValidator.validate(manifest);
    if (!validation.valid) throw new Error(validation.issues.join('; '));
    this.manifest = cloneManifest(manifest);
  }

  record(sample: BenchmarkSample): BenchmarkRecordResult {
    const result: BenchmarkRecordResult = this.validateSample(sample);
    if (!result.valid) return result;
    const key: string = sample.caseId + '\n' + sample.runId + '\n' + sample.armId;
    if (containsText(this.sampleKeys, key)) {
      result.addIssue('caseId, runId, and armId must be unique');
      return result;
    }
    this.sampleKeys.push(key);
    this.samples.push(this.cloneSample(sample));
    return result;
  }

  summarize(): BenchmarkSummary {
    return this.summarizeMatching(undefined);
  }

  summarizeArm(armId: string): BenchmarkSummary {
    if (!this.hasArm(armId)) throw new Error('armId is not in the manifest');
    return this.summarizeMatching(armId);
  }

  private summarizeMatching(armId: string | undefined): BenchmarkSummary {
    const summary: BenchmarkSummary = new BenchmarkSummary();
    const latencies: number[] = [];
    let qualityTotal: number = 0;
    for (let index: number = 0; index < this.samples.length; index++) {
      const sample: BenchmarkSample = this.samples[index];
      if (armId !== undefined && sample.armId !== armId) continue;
      summary.sampleCount += 1;
      if (sample.passed) summary.passedCount += 1;
      qualityTotal += sample.qualityScoreBasisPoints;
      summary.inputTokens += sample.inputTokens;
      summary.outputTokens += sample.outputTokens;
      summary.monetaryCostMicros += sample.monetaryCostMicros;
      summary.toolCalls += sample.toolCalls;
      summary.agentActivations += sample.agentActivations;
      summary.recoveryEvents += sample.recoveryEvents;
      summary.routerDecisions += sample.routerDecisions;
      summary.routerCorrectDecisions += sample.routerCorrectDecisions;
      latencies.push(sample.latencyMs);
    }
    summary.failedCount = summary.sampleCount - summary.passedCount;
    if (summary.sampleCount > 0) {
      summary.averageQualityBasisPoints = Math.floor(qualityTotal / summary.sampleCount);
      latencies.sort((left: number, right: number): number => left - right);
      summary.latencyP50Ms = this.nearestRank(latencies, 50);
      summary.latencyP95Ms = this.nearestRank(latencies, 95);
    }
    return summary;
  }

  report(): BenchmarkReport {
    const report: BenchmarkReport = new BenchmarkReport();
    report.manifest = cloneManifest(this.manifest);
    report.summary = this.summarize();
    for (let index: number = 0; index < this.manifest.arms.length; index++) {
      const armReport: BenchmarkArmReport = new BenchmarkArmReport();
      armReport.armId = this.manifest.arms[index].armId;
      armReport.summary = this.summarizeArm(armReport.armId);
      report.armSummaries.push(armReport);
    }
    return report;
  }

  reportJson(): string {
    return JSON.stringify(this.report()) as string;
  }

  private validateSample(sample: BenchmarkSample): BenchmarkRecordResult {
    const result: BenchmarkRecordResult = new BenchmarkRecordResult();
    if (!isNonEmptyText(sample.caseId)) result.addIssue('caseId is required');
    if (!isNonEmptyText(sample.runId)) result.addIssue('runId is required');
    if (!isNonEmptyText(sample.armId) || !this.hasArm(sample.armId)) result.addIssue('armId is not in the manifest');
    integerField(result, 'qualityScoreBasisPoints', sample.qualityScoreBasisPoints);
    if (sample.qualityScoreBasisPoints > 10000) result.addIssue('qualityScoreBasisPoints must not exceed 10000');
    integerField(result, 'inputTokens', sample.inputTokens);
    integerField(result, 'outputTokens', sample.outputTokens);
    integerField(result, 'monetaryCostMicros', sample.monetaryCostMicros);
    integerField(result, 'latencyMs', sample.latencyMs);
    integerField(result, 'toolCalls', sample.toolCalls);
    integerField(result, 'agentActivations', sample.agentActivations);
    integerField(result, 'recoveryEvents', sample.recoveryEvents);
    integerField(result, 'routerDecisions', sample.routerDecisions);
    integerField(result, 'routerCorrectDecisions', sample.routerCorrectDecisions);
    if (sample.routerCorrectDecisions > sample.routerDecisions) {
      result.addIssue('routerCorrectDecisions must not exceed routerDecisions');
    }
    return result;
  }

  private hasArm(armId: string): boolean {
    for (let index: number = 0; index < this.manifest.arms.length; index++) {
      if (this.manifest.arms[index].armId === armId) return true;
    }
    return false;
  }

  private nearestRank(sortedValues: number[], percentile: number): number {
    const rank: number = Math.ceil((percentile * sortedValues.length) / 100);
    const index: number = rank <= 0 ? 0 : rank - 1;
    return sortedValues[index];
  }

  private cloneSample(source: BenchmarkSample): BenchmarkSample {
    const clone: BenchmarkSample = new BenchmarkSample();
    clone.caseId = source.caseId;
    clone.runId = source.runId;
    clone.armId = source.armId;
    clone.passed = source.passed;
    clone.qualityScoreBasisPoints = source.qualityScoreBasisPoints;
    clone.inputTokens = source.inputTokens;
    clone.outputTokens = source.outputTokens;
    clone.monetaryCostMicros = source.monetaryCostMicros;
    clone.latencyMs = source.latencyMs;
    clone.toolCalls = source.toolCalls;
    clone.agentActivations = source.agentActivations;
    clone.recoveryEvents = source.recoveryEvents;
    clone.routerDecisions = source.routerDecisions;
    clone.routerCorrectDecisions = source.routerCorrectDecisions;
    return clone;
  }
}
