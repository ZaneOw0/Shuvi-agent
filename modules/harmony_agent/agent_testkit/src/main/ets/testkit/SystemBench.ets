import {
  BenchmarkArm,
  BenchmarkArmKind,
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
import {
  isNonEmptyText,
  isPositiveInteger,
  TestKitValidationResult
} from './Common';

export const SYSTEM_BENCHMARK_RUN_SCHEMA_VERSION: string = '2';

export enum SystemBenchmarkMeasurementMode {
  REAL_PROVIDER_RUNTIME = 'realProviderRuntime'
}

export class SystemBenchmarkEnvironment {
  sourceCommit: string = '';
  runtimeVersion: string = '';
  compositionVersion: string = '';
  harnessVersion: string = '';
  sdkVersion: string = '';
  osVersion: string = '';
  deviceClass: string = '';
  measurementClock: string = '';
  environmentDigest: string = '';
}

export class SystemBenchmarkAgentEvidence {
  activationId: string = '';
  roleId: string = '';
  roleVersion: string = '';
  providerRequestCount: number = 0;
  providerRequestIdsDigest: string = '';
  traceDigest: string = '';
  resultDigest: string = '';
}

export class SystemBenchmarkEvidence {
  taskId: string = '';
  taskSnapshotDigest: string = '';
  eventTraceDigest: string = '';
  providerUsageDigest: string = '';
  resultDigest: string = '';
  qualityEvidenceDigest: string = '';
  roleRegistryDigest: string = '';
  collaborationDecisionDigest: string = '';
  evidenceKinds: string[] = [];
  agentEvidence: SystemBenchmarkAgentEvidence[] = [];
  usedAgentRuntimeFacade: boolean = false;
  providerRequestCount: number = 0;
}

export class SystemBenchmarkRecord {
  sample: BenchmarkSample = new BenchmarkSample();
  evidence: SystemBenchmarkEvidence = new SystemBenchmarkEvidence();
}

export class SystemBenchmarkRun {
  schemaVersion: string = SYSTEM_BENCHMARK_RUN_SCHEMA_VERSION;
  executionId: string = '';
  measurementMode: SystemBenchmarkMeasurementMode = SystemBenchmarkMeasurementMode.REAL_PROVIDER_RUNTIME;
  startedAt: string = '';
  completedAt: string = '';
  performanceComparable: boolean = false;
  redactionPolicyVersion: string = '';
  qualityJudgeId: string = '';
  qualityJudgeVersion: string = '';
  environment: SystemBenchmarkEnvironment = new SystemBenchmarkEnvironment();
  records: SystemBenchmarkRecord[] = [];
}

function appendIssues(target: TestKitValidationResult, prefix: string, issues: string[]): void {
  for (let index: number = 0; index < issues.length; index++) target.addIssue(prefix + issues[index]);
}

function hasIsoDatePrefix(value: string): boolean {
  return value.length >= 10 && value.charAt(4) === '-' && value.charAt(7) === '-';
}

function isHexText(value: string): boolean {
  for (let index: number = 0; index < value.length; index++) {
    const character: string = value.substring(index, index + 1).toLowerCase();
    const digit: boolean = character >= '0' && character <= '9';
    const alpha: boolean = character >= 'a' && character <= 'f';
    if (!digit && !alpha) return false;
  }
  return true;
}

function isSha256Digest(value: string): boolean {
  const prefix: string = 'sha256:';
  if (!value.startsWith(prefix)) return false;
  const body: string = value.substring(prefix.length);
  return body.length === 64 && isHexText(body);
}

function isSourceCommit(value: string): boolean {
  return value.length === 40 && isHexText(value);
}

function fixtureIdentity(value: string): boolean {
  const lower: string = value.toLowerCase();
  return lower.indexOf('fixture') >= 0 || lower.indexOf('mock') >= 0 || lower.indexOf('fake') >= 0 ||
    lower.indexOf('deterministic-local') >= 0;
}

function containsText(values: string[], value: string): boolean {
  for (let index: number = 0; index < values.length; index++) {
    if (values[index] === value) return true;
  }
  return false;
}

function armById(manifest: BenchmarkManifest, armId: string): BenchmarkArm | undefined {
  for (let index: number = 0; index < manifest.arms.length; index++) {
    if (manifest.arms[index].armId === armId) return manifest.arms[index];
  }
  return undefined;
}

function caseById(dataset: BenchmarkDataset, caseId: string): BenchmarkTaskCase | undefined {
  for (let index: number = 0; index < dataset.cases.length; index++) {
    if (dataset.cases[index].caseId === caseId) return dataset.cases[index];
  }
  return undefined;
}

export class SystemBenchmarkRunValidator {
  static validate(manifest: BenchmarkManifest, dataset: BenchmarkDataset,
    run: SystemBenchmarkRun): TestKitValidationResult {
    const result: TestKitValidationResult = new TestKitValidationResult();
    const manifestValidation: TestKitValidationResult = BenchmarkManifestValidator.validate(manifest);
    const datasetValidation: TestKitValidationResult = BenchmarkDatasetValidator.validate(dataset);
    appendIssues(result, 'manifest: ', manifestValidation.issues);
    appendIssues(result, 'dataset: ', datasetValidation.issues);

    if (run.schemaVersion !== SYSTEM_BENCHMARK_RUN_SCHEMA_VERSION) result.addIssue('unsupported schemaVersion');
    if (!isNonEmptyText(run.executionId)) result.addIssue('executionId is required');
    if (run.measurementMode !== SystemBenchmarkMeasurementMode.REAL_PROVIDER_RUNTIME) {
      result.addIssue('measurementMode must be realProviderRuntime');
    }
    if (!hasIsoDatePrefix(run.startedAt)) result.addIssue('startedAt must include an ISO date');
    if (!hasIsoDatePrefix(run.completedAt)) result.addIssue('completedAt must include an ISO date');
    if (!run.performanceComparable) result.addIssue('system benchmark must be performance comparable');
    if (!isNonEmptyText(run.redactionPolicyVersion)) result.addIssue('redactionPolicyVersion is required');
    if (!isNonEmptyText(run.qualityJudgeId)) result.addIssue('qualityJudgeId is required');
    if (!isNonEmptyText(run.qualityJudgeVersion)) result.addIssue('qualityJudgeVersion is required');

    SystemBenchmarkRunValidator.validateEnvironment(run.environment, result);
    SystemBenchmarkRunValidator.validateProductionIdentity(manifest, result);
    SystemBenchmarkRunValidator.validateArms(manifest, result);

    if (!manifestValidation.valid || !datasetValidation.valid) return result;
    const expectedRecords: number = manifest.arms.length * dataset.cases.length;
    if (run.records.length !== expectedRecords) {
      result.addIssue('records must contain every dataset case for every benchmark arm');
    }

    const evaluator: BenchmarkEvaluator = new BenchmarkEvaluator(manifest);
    const recordKeys: string[] = [];
    const taskIds: string[] = [];
    for (let index: number = 0; index < run.records.length; index++) {
      const record: SystemBenchmarkRecord = run.records[index];
      SystemBenchmarkRunValidator.validateRecordInternal(record, index, manifest, dataset, run, evaluator,
        recordKeys, taskIds, result);
    }
    for (let caseIndex: number = 0; caseIndex < dataset.cases.length; caseIndex++) {
      for (let armIndex: number = 0; armIndex < manifest.arms.length; armIndex++) {
        const key: string = dataset.cases[caseIndex].caseId + '\n' + manifest.arms[armIndex].armId;
        if (!containsText(recordKeys, key)) result.addIssue('missing record for ' + key.replace('\n', '/'));
      }
    }
    return result;
  }

  static validateRecord(manifest: BenchmarkManifest, dataset: BenchmarkDataset, run: SystemBenchmarkRun,
    record: SystemBenchmarkRecord): TestKitValidationResult {
    const result: TestKitValidationResult = new TestKitValidationResult();
    const manifestValidation: TestKitValidationResult = BenchmarkManifestValidator.validate(manifest);
    const datasetValidation: TestKitValidationResult = BenchmarkDatasetValidator.validate(dataset);
    appendIssues(result, 'manifest: ', manifestValidation.issues);
    appendIssues(result, 'dataset: ', datasetValidation.issues);
    if (!manifestValidation.valid || !datasetValidation.valid) return result;
    const evaluator: BenchmarkEvaluator = new BenchmarkEvaluator(manifest);
    SystemBenchmarkRunValidator.validateRecordInternal(record, 0, manifest, dataset, run, evaluator,
      [], [], result);
    return result;
  }

  private static validateEnvironment(environment: SystemBenchmarkEnvironment,
    result: TestKitValidationResult): void {
    if (!isSourceCommit(environment.sourceCommit)) result.addIssue('environment sourceCommit must be a full Git SHA');
    if (!isNonEmptyText(environment.runtimeVersion)) result.addIssue('environment runtimeVersion is required');
    if (!isNonEmptyText(environment.compositionVersion)) {
      result.addIssue('environment compositionVersion is required');
    }
    if (!isNonEmptyText(environment.harnessVersion)) result.addIssue('environment harnessVersion is required');
    if (!isNonEmptyText(environment.sdkVersion)) result.addIssue('environment sdkVersion is required');
    if (!isNonEmptyText(environment.osVersion)) result.addIssue('environment osVersion is required');
    if (!isNonEmptyText(environment.deviceClass)) result.addIssue('environment deviceClass is required');
    if (!isNonEmptyText(environment.measurementClock) ||
      environment.measurementClock === 'deterministic-virtual-zero') {
      result.addIssue('environment measurementClock must be a real monotonic clock');
    }
    if (!isSha256Digest(environment.environmentDigest)) {
      result.addIssue('environment environmentDigest must be a full sha256 digest');
    }
  }

  private static validateProductionIdentity(manifest: BenchmarkManifest, result: TestKitValidationResult): void {
    if (fixtureIdentity(manifest.providerId)) result.addIssue('manifest providerId must identify a production candidate');
    if (fixtureIdentity(manifest.modelId)) result.addIssue('manifest modelId must identify a production candidate');
    if (fixtureIdentity(manifest.region)) result.addIssue('manifest region must not identify a fixture environment');
    if (fixtureIdentity(manifest.priceSnapshotId)) {
      result.addIssue('manifest priceSnapshotId must identify a production candidate price');
    }
    if (!isSha256Digest(manifest.datasetDigest)) result.addIssue('manifest datasetDigest must be a full sha256 digest');
    if (!isSha256Digest(manifest.priceSnapshotDigest)) {
      result.addIssue('manifest priceSnapshotDigest must be a full sha256 digest');
    }
  }

  private static validateArms(manifest: BenchmarkManifest, result: TestKitValidationResult): void {
    if (manifest.arms.length !== 2) {
      result.addIssue('system benchmark requires exactly two arms');
      return;
    }
    let strongCount: number = 0;
    let multiCount: number = 0;
    for (let index: number = 0; index < manifest.arms.length; index++) {
      if (manifest.arms[index].kind === BenchmarkArmKind.STRONG_SINGLE_AGENT) strongCount++;
      if (manifest.arms[index].kind === BenchmarkArmKind.MULTI_AGENT) multiCount++;
    }
    if (strongCount !== 1 || multiCount !== 1) {
      result.addIssue('system benchmark requires one strong-single and one multi-agent arm');
    }
  }

  private static validateRecordInternal(record: SystemBenchmarkRecord, index: number, manifest: BenchmarkManifest,
    dataset: BenchmarkDataset, run: SystemBenchmarkRun, evaluator: BenchmarkEvaluator, recordKeys: string[],
    taskIds: string[], result: TestKitValidationResult): void {
    const prefix: string = 'records[' + index.toString() + '] ';
    const sample: BenchmarkSample = record.sample;
    const evidence: SystemBenchmarkEvidence = record.evidence;
    const arm: BenchmarkArm | undefined = armById(manifest, sample.armId);
    const taskCase: BenchmarkTaskCase | undefined = caseById(dataset, sample.caseId);
    if (taskCase === undefined) result.addIssue(prefix + 'caseId is not in the dataset');
    if (sample.runId !== run.executionId) result.addIssue(prefix + 'runId must match executionId');
    const recordResult = evaluator.record(sample);
    appendIssues(result, prefix, recordResult.issues);
    const key: string = sample.caseId + '\n' + sample.armId;
    if (containsText(recordKeys, key)) {
      result.addIssue(prefix + 'caseId and armId must be unique');
    } else {
      recordKeys.push(key);
    }
    if (!isNonEmptyText(evidence.taskId) || containsText(taskIds, evidence.taskId)) {
      result.addIssue(prefix + 'evidence taskId must be present and unique');
    } else {
      taskIds.push(evidence.taskId);
    }
    if (!evidence.usedAgentRuntimeFacade) result.addIssue(prefix + 'must record AgentRuntimeFacade execution');
    if (!isPositiveInteger(evidence.providerRequestCount)) {
      result.addIssue(prefix + 'providerRequestCount must be positive');
    }
    if (!isPositiveInteger(sample.latencyMs)) result.addIssue(prefix + 'latencyMs must use a real clock');
    if (sample.inputTokens + sample.outputTokens <= 0) result.addIssue(prefix + 'provider token usage is required');
    if (!isSha256Digest(evidence.taskSnapshotDigest)) result.addIssue(prefix + 'taskSnapshotDigest is invalid');
    if (!isSha256Digest(evidence.eventTraceDigest)) result.addIssue(prefix + 'eventTraceDigest is invalid');
    if (!isSha256Digest(evidence.providerUsageDigest)) result.addIssue(prefix + 'providerUsageDigest is invalid');
    if (!isSha256Digest(evidence.resultDigest)) result.addIssue(prefix + 'resultDigest is invalid');
    if (!isSha256Digest(evidence.qualityEvidenceDigest)) result.addIssue(prefix + 'qualityEvidenceDigest is invalid');
    if (!isSha256Digest(evidence.roleRegistryDigest)) result.addIssue(prefix + 'roleRegistryDigest is invalid');
    if (!isSha256Digest(evidence.collaborationDecisionDigest)) {
      result.addIssue(prefix + 'collaborationDecisionDigest is invalid');
    }
    SystemBenchmarkRunValidator.validateEvidenceKinds(evidence, taskCase, prefix, result);
    SystemBenchmarkRunValidator.validateAgentEvidence(evidence, sample, arm, prefix, result);
    if (arm !== undefined && arm.kind === BenchmarkArmKind.STRONG_SINGLE_AGENT && sample.agentActivations !== 1) {
      result.addIssue(prefix + 'strong-single arm must record exactly one agent activation');
    }
    if (arm !== undefined && arm.kind === BenchmarkArmKind.MULTI_AGENT && sample.agentActivations < 2) {
      result.addIssue(prefix + 'multi-agent arm must record at least two agent activations');
    }
  }

  private static validateEvidenceKinds(evidence: SystemBenchmarkEvidence, taskCase: BenchmarkTaskCase | undefined,
    prefix: string, result: TestKitValidationResult): void {
    const seen: string[] = [];
    for (let index: number = 0; index < evidence.evidenceKinds.length; index++) {
      const kind: string = evidence.evidenceKinds[index];
      if (!isNonEmptyText(kind)) {
        result.addIssue(prefix + 'evidenceKinds must not contain empty values');
      } else if (containsText(seen, kind)) {
        result.addIssue(prefix + 'evidenceKinds must be unique');
      } else {
        seen.push(kind);
      }
    }
    if (taskCase === undefined) return;
    for (let index: number = 0; index < taskCase.expectedEvidence.length; index++) {
      if (!containsText(seen, taskCase.expectedEvidence[index])) {
        result.addIssue(prefix + 'missing expected evidence kind ' + taskCase.expectedEvidence[index]);
      }
    }
  }

  private static validateAgentEvidence(evidence: SystemBenchmarkEvidence, sample: BenchmarkSample,
    arm: BenchmarkArm | undefined, prefix: string, result: TestKitValidationResult): void {
    const activationIds: string[] = [];
    const roleIdentities: string[] = [];
    const requestDigests: string[] = [];
    const traceDigests: string[] = [];
    let providerRequests: number = 0;
    for (let index: number = 0; index < evidence.agentEvidence.length; index++) {
      const value: SystemBenchmarkAgentEvidence = evidence.agentEvidence[index];
      const agentPrefix: string = prefix + 'agentEvidence[' + index.toString() + '] ';
      if (!isNonEmptyText(value.activationId) || containsText(activationIds, value.activationId)) {
        result.addIssue(agentPrefix + 'activationId must be present and unique');
      } else {
        activationIds.push(value.activationId);
      }
      const roleIdentity: string = value.roleId + '\n' + value.roleVersion;
      if (!isNonEmptyText(value.roleId) || !isNonEmptyText(value.roleVersion) ||
        containsText(roleIdentities, roleIdentity)) {
        result.addIssue(agentPrefix + 'role identity must be present and unique');
      } else {
        roleIdentities.push(roleIdentity);
      }
      if (!isPositiveInteger(value.providerRequestCount)) {
        result.addIssue(agentPrefix + 'providerRequestCount must be positive');
      } else {
        providerRequests += value.providerRequestCount;
      }
      if (!isSha256Digest(value.providerRequestIdsDigest) ||
        containsText(requestDigests, value.providerRequestIdsDigest)) {
        result.addIssue(agentPrefix + 'providerRequestIdsDigest must be valid and unique');
      } else {
        requestDigests.push(value.providerRequestIdsDigest);
      }
      if (!isSha256Digest(value.traceDigest) || containsText(traceDigests, value.traceDigest)) {
        result.addIssue(agentPrefix + 'traceDigest must be valid and unique');
      } else {
        traceDigests.push(value.traceDigest);
      }
      if (!isSha256Digest(value.resultDigest)) result.addIssue(agentPrefix + 'resultDigest is invalid');
    }
    if (evidence.agentEvidence.length !== sample.agentActivations) {
      result.addIssue(prefix + 'agentEvidence count must match agentActivations');
    }
    if (providerRequests !== evidence.providerRequestCount) {
      result.addIssue(prefix + 'providerRequestCount must equal the per-agent request total');
    }
    if (arm !== undefined && arm.kind === BenchmarkArmKind.STRONG_SINGLE_AGENT &&
      evidence.agentEvidence.length !== 1) {
      result.addIssue(prefix + 'strong-single arm must contain one agent evidence record');
    }
    if (arm !== undefined && arm.kind === BenchmarkArmKind.MULTI_AGENT &&
      evidence.agentEvidence.length < 2) {
      result.addIssue(prefix + 'multi-agent arm must contain at least two distinct agent evidence records');
    }
  }
}
