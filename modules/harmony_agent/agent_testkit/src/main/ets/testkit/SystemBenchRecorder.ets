import {
  BenchmarkArm,
  BenchmarkEvaluator,
  BenchmarkManifest,
  BenchmarkManifestValidator,
  BenchmarkSample
} from './Benchmark';
import {
  BenchmarkDataset,
  BenchmarkDatasetValidator,
  BenchmarkTaskCase
} from './BenchPilot';
import { TestKitValidationResult } from './Common';
import {
  SystemBenchmarkAgentEvidence,
  SystemBenchmarkEnvironment,
  SystemBenchmarkEvidence,
  SystemBenchmarkRecord,
  SystemBenchmarkRun,
  SystemBenchmarkRunValidator
} from './SystemBench';

export class SystemBenchmarkAppendResult extends TestKitValidationResult {
  accepted: boolean = true;

  addIssue(issue: string): void {
    super.addIssue(issue);
    this.accepted = false;
  }
}

export class SystemBenchmarkSealResult extends TestKitValidationResult {
  run?: SystemBenchmarkRun;
}

function copyArm(source: BenchmarkArm): BenchmarkArm {
  const value: BenchmarkArm = new BenchmarkArm();
  value.armId = source.armId;
  value.kind = source.kind;
  value.permissionPolicyVersion = source.permissionPolicyVersion;
  value.contextPolicyVersion = source.contextPolicyVersion;
  return value;
}

function copyManifest(source: BenchmarkManifest): BenchmarkManifest {
  const value: BenchmarkManifest = new BenchmarkManifest();
  value.schemaVersion = source.schemaVersion;
  value.benchmarkId = source.benchmarkId;
  value.suiteVersion = source.suiteVersion;
  value.frozenAt = source.frozenAt;
  value.datasetDigest = source.datasetDigest;
  value.modelId = source.modelId;
  value.modelVersion = source.modelVersion;
  value.providerId = source.providerId;
  value.region = source.region;
  value.priceSnapshotId = source.priceSnapshotId;
  value.priceSnapshotDigest = source.priceSnapshotDigest;
  value.contractSchemaVersion = source.contractSchemaVersion;
  value.routerPolicyVersion = source.routerPolicyVersion;
  for (let i: number = 0; i < source.arms.length; i++) value.arms.push(copyArm(source.arms[i]));
  return value;
}

function copyTaskCase(source: BenchmarkTaskCase): BenchmarkTaskCase {
  const value: BenchmarkTaskCase = new BenchmarkTaskCase();
  value.caseId = source.caseId;
  value.kind = source.kind;
  value.promptTemplate = source.promptTemplate;
  value.requiredCapabilities = source.requiredCapabilities.slice();
  value.expectedEvidence = source.expectedEvidence.slice();
  value.requiresAuthorization = source.requiresAuthorization;
  value.includesFailureRecovery = source.includesFailureRecovery;
  return value;
}

function copyDataset(source: BenchmarkDataset): BenchmarkDataset {
  const value: BenchmarkDataset = new BenchmarkDataset();
  value.datasetId = source.datasetId;
  value.datasetVersion = source.datasetVersion;
  value.frozenAt = source.frozenAt;
  for (let i: number = 0; i < source.cases.length; i++) value.cases.push(copyTaskCase(source.cases[i]));
  return value;
}

function copySample(source: BenchmarkSample): BenchmarkSample {
  const value: BenchmarkSample = new BenchmarkSample();
  value.caseId = source.caseId;
  value.runId = source.runId;
  value.armId = source.armId;
  value.passed = source.passed;
  value.qualityScoreBasisPoints = source.qualityScoreBasisPoints;
  value.inputTokens = source.inputTokens;
  value.outputTokens = source.outputTokens;
  value.monetaryCostMicros = source.monetaryCostMicros;
  value.latencyMs = source.latencyMs;
  value.toolCalls = source.toolCalls;
  value.agentActivations = source.agentActivations;
  value.recoveryEvents = source.recoveryEvents;
  value.routerDecisions = source.routerDecisions;
  value.routerCorrectDecisions = source.routerCorrectDecisions;
  return value;
}

function copyAgentEvidence(source: SystemBenchmarkAgentEvidence): SystemBenchmarkAgentEvidence {
  const value: SystemBenchmarkAgentEvidence = new SystemBenchmarkAgentEvidence();
  value.activationId = source.activationId;
  value.roleId = source.roleId;
  value.roleVersion = source.roleVersion;
  value.providerRequestCount = source.providerRequestCount;
  value.providerRequestIdsDigest = source.providerRequestIdsDigest;
  value.traceDigest = source.traceDigest;
  value.resultDigest = source.resultDigest;
  return value;
}

function copyEvidence(source: SystemBenchmarkEvidence): SystemBenchmarkEvidence {
  const value: SystemBenchmarkEvidence = new SystemBenchmarkEvidence();
  value.taskId = source.taskId;
  value.taskSnapshotDigest = source.taskSnapshotDigest;
  value.eventTraceDigest = source.eventTraceDigest;
  value.providerUsageDigest = source.providerUsageDigest;
  value.resultDigest = source.resultDigest;
  value.qualityEvidenceDigest = source.qualityEvidenceDigest;
  value.roleRegistryDigest = source.roleRegistryDigest;
  value.collaborationDecisionDigest = source.collaborationDecisionDigest;
  value.evidenceKinds = source.evidenceKinds.slice();
  value.usedAgentRuntimeFacade = source.usedAgentRuntimeFacade;
  value.providerRequestCount = source.providerRequestCount;
  for (let i: number = 0; i < source.agentEvidence.length; i++) {
    value.agentEvidence.push(copyAgentEvidence(source.agentEvidence[i]));
  }
  return value;
}

function copyRecord(source: SystemBenchmarkRecord): SystemBenchmarkRecord {
  const value: SystemBenchmarkRecord = new SystemBenchmarkRecord();
  value.sample = copySample(source.sample);
  value.evidence = copyEvidence(source.evidence);
  return value;
}

function copyEnvironment(source: SystemBenchmarkEnvironment): SystemBenchmarkEnvironment {
  const value: SystemBenchmarkEnvironment = new SystemBenchmarkEnvironment();
  value.sourceCommit = source.sourceCommit;
  value.runtimeVersion = source.runtimeVersion;
  value.compositionVersion = source.compositionVersion;
  value.harnessVersion = source.harnessVersion;
  value.sdkVersion = source.sdkVersion;
  value.osVersion = source.osVersion;
  value.deviceClass = source.deviceClass;
  value.measurementClock = source.measurementClock;
  value.environmentDigest = source.environmentDigest;
  return value;
}

function copyRun(source: SystemBenchmarkRun, includeRecords: boolean): SystemBenchmarkRun {
  const value: SystemBenchmarkRun = new SystemBenchmarkRun();
  value.schemaVersion = source.schemaVersion;
  value.executionId = source.executionId;
  value.measurementMode = source.measurementMode;
  value.startedAt = source.startedAt;
  value.completedAt = source.completedAt;
  value.performanceComparable = source.performanceComparable;
  value.redactionPolicyVersion = source.redactionPolicyVersion;
  value.qualityJudgeId = source.qualityJudgeId;
  value.qualityJudgeVersion = source.qualityJudgeVersion;
  value.environment = copyEnvironment(source.environment);
  if (includeRecords) {
    for (let i: number = 0; i < source.records.length; i++) value.records.push(copyRecord(source.records[i]));
  }
  return value;
}

function containsCase(dataset: BenchmarkDataset, caseId: string): boolean {
  for (let i: number = 0; i < dataset.cases.length; i++) {
    if (dataset.cases[i].caseId === caseId) return true;
  }
  return false;
}

function containsText(values: string[], target: string): boolean {
  for (let i: number = 0; i < values.length; i++) {
    if (values[i] === target) return true;
  }
  return false;
}

/**
 * Collects already-produced, redacted benchmark observations and seals them
 * only after the schema-2 validator accepts the complete 12 x 2 run. It has no
 * Runtime, Provider, Tool, authorization, or task-control dependency.
 */
export class SystemBenchmarkRunRecorder {
  private readonly manifest: BenchmarkManifest;
  private readonly dataset: BenchmarkDataset;
  private readonly evaluator: BenchmarkEvaluator;
  private readonly run: SystemBenchmarkRun;
  private readonly recordKeys: string[] = [];
  private readonly taskIds: string[] = [];
  private sealed: boolean = false;

  constructor(manifest: BenchmarkManifest, dataset: BenchmarkDataset, runHeader: SystemBenchmarkRun) {
    const manifestValidation: TestKitValidationResult = BenchmarkManifestValidator.validate(manifest);
    const datasetValidation: TestKitValidationResult = BenchmarkDatasetValidator.validate(dataset);
    if (!manifestValidation.valid || !datasetValidation.valid || runHeader.records.length > 0) {
      throw new Error('SYSTEM_BENCH_RECORDER_CONFIGURATION_INVALID');
    }
    this.manifest = copyManifest(manifest);
    this.dataset = copyDataset(dataset);
    this.run = copyRun(runHeader, false);
    this.evaluator = new BenchmarkEvaluator(this.manifest);
  }

  append(record: SystemBenchmarkRecord): SystemBenchmarkAppendResult {
    const result: SystemBenchmarkAppendResult = new SystemBenchmarkAppendResult();
    if (this.sealed) result.addIssue('recorder is sealed');
    if (record.sample.runId !== this.run.executionId) result.addIssue('sample runId must match executionId');
    if (!containsCase(this.dataset, record.sample.caseId)) result.addIssue('sample caseId is not in the dataset');
    const key: string = record.sample.caseId + '\n' + record.sample.armId;
    if (containsText(this.recordKeys, key)) result.addIssue('caseId and armId must be unique');
    if (record.evidence.taskId.trim().length === 0 || containsText(this.taskIds, record.evidence.taskId)) {
      result.addIssue('evidence taskId must be present and unique');
    }
    if (!result.valid) return result;
    const recordValidation: TestKitValidationResult =
      SystemBenchmarkRunValidator.validateRecord(this.manifest, this.dataset, this.run, record);
    if (!recordValidation.valid) {
      for (let i: number = 0; i < recordValidation.issues.length; i++) result.addIssue(recordValidation.issues[i]);
      return result;
    }
    const sampleValidation = this.evaluator.record(copySample(record.sample));
    if (!sampleValidation.valid) {
      for (let i: number = 0; i < sampleValidation.issues.length; i++) result.addIssue(sampleValidation.issues[i]);
      return result;
    }
    this.recordKeys.push(key);
    this.taskIds.push(record.evidence.taskId);
    this.run.records.push(copyRecord(record));
    return result;
  }

  recordCount(): number {
    return this.run.records.length;
  }

  seal(): SystemBenchmarkSealResult {
    const result: SystemBenchmarkSealResult = new SystemBenchmarkSealResult();
    const candidate: SystemBenchmarkRun = copyRun(this.run, true);
    const validation: TestKitValidationResult =
      SystemBenchmarkRunValidator.validate(this.manifest, this.dataset, candidate);
    if (!validation.valid) {
      for (let i: number = 0; i < validation.issues.length; i++) result.addIssue(validation.issues[i]);
      return result;
    }
    this.sealed = true;
    result.run = candidate;
    return result;
  }
}
