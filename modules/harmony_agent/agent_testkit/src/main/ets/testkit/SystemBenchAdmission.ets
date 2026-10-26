import {
  BenchmarkArmKind,
  BenchmarkManifest,
  BenchmarkManifestValidator
} from './Benchmark';
import {
  BenchmarkDataset,
  BenchmarkDatasetValidator,
  BenchmarkTaskKind
} from './BenchPilot';
import {
  isNonEmptyText,
  isPositiveInteger,
  TestKitValidationResult
} from './Common';

export const SYSTEM_BENCHMARK_EXECUTION_PLAN_SCHEMA_VERSION: string = '1';

/** Public price identity used to bound a run. It never contains a credential. */
export class SystemBenchmarkExecutionPrice {
  priceSnapshotId: string = '';
  priceSnapshotDigest: string = '';
  providerId: string = '';
  modelId: string = '';
  modelVersion: string = '';
  region: string = '';
  upstreamProviderId: string = '';
  upstreamModelId: string = '';
  upstreamModelVersion: string = '';
  upstreamRegion: string = '';
  currency: string = 'USD_MICROS';
  pricingTier: string = '';
  frozenAt: string = '';
  sourceUrl: string = '';
  inputMicrosPerMillionTokens: number = 0;
  outputMicrosPerMillionTokens: number = 0;
  fixedCostMicros: number = 0;
}

/** Immutable execution envelope reviewed before a real 12 x 2 Provider run. */
export class SystemBenchmarkExecutionPlan {
  schemaVersion: string = SYSTEM_BENCHMARK_EXECUTION_PLAN_SCHEMA_VERSION;
  benchmarkId: string = '';
  suiteVersion: string = '';
  datasetDigest: string = '';
  recordCount: number = 0;
  maxClarificationRounds: number = 0;
  strongSingleRequestLimit: number = 0;
  multiAgentRequestLimit: number = 0;
  providerRequestLimit: number = 0;
  perRequestInputTokenLimit: number = 0;
  perRequestOutputTokenLimit: number = 0;
  monetaryCostLimitMicros: number = 0;
  price: SystemBenchmarkExecutionPrice = new SystemBenchmarkExecutionPrice();
}

/** Redacted local-gateway observation plus the external batch authorization reference. */
export class SystemBenchmarkAdmissionSnapshot {
  observedAt: string = '';
  gatewayRunning: boolean = false;
  activeProfileId: string = '';
  activeProfileDigest: string = '';
  activeConfigurationRevision: number = 0;
  providerId: string = '';
  modelId: string = '';
  modelVersion: string = '';
  region: string = '';
  upstreamProviderId: string = '';
  upstreamModelId: string = '';
  upstreamModelVersion: string = '';
  upstreamRegion: string = '';
  priceSnapshotId: string = '';
  priceSnapshotDigest: string = '';
  executionAuthorizationRef: string = '';
}

export class SystemBenchmarkExecutionPreflightResult extends TestKitValidationResult {
  ready: boolean = true;
  expectedRecordCount: number = 0;
  expectedStrongSingleRequests: number = 0;
  expectedMultiAgentRequests: number = 0;
  expectedProviderRequestLimit: number = 0;
  expectedMonetaryCostLimitMicros: number = 0;

  addIssue(issue: string): void {
    super.addIssue(issue);
    this.ready = false;
  }
}

function hasIsoDatePrefix(value: string): boolean {
  return value.length >= 10 && value.charAt(4) === '-' && value.charAt(7) === '-';
}

function appendIssues(target: SystemBenchmarkExecutionPreflightResult, prefix: string, issues: string[]): void {
  for (let index: number = 0; index < issues.length; index++) target.addIssue(prefix + issues[index]);
}

function armCount(manifest: BenchmarkManifest, kind: BenchmarkArmKind): number {
  let count: number = 0;
  for (let index: number = 0; index < manifest.arms.length; index++) {
    if (manifest.arms[index].kind === kind) count++;
  }
  return count;
}

function clarificationCount(dataset: BenchmarkDataset): number {
  let count: number = 0;
  for (let index: number = 0; index < dataset.cases.length; index++) {
    if (dataset.cases[index].kind === BenchmarkTaskKind.CLARIFICATION_REQUIRED) count++;
  }
  return count;
}

function sameText(actual: string, expected: string): boolean {
  return actual === expected;
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

/**
 * Validates an execution plan without starting a gateway or submitting a task.
 * The request envelope assumes one role for Strong Single and two roles for Multi.
 * The single clarification case allows one resume round. Strong Single can use
 * two requests. Multi can use two requests before a later role asks for
 * clarification and two more during resume, so the fail-closed ceiling is 39.
 */
export class SystemBenchmarkExecutionPreflightValidator {
  static calculatePerRequestCostMicros(plan: SystemBenchmarkExecutionPlan): number {
    return Math.ceil((plan.perRequestInputTokenLimit * plan.price.inputMicrosPerMillionTokens +
      plan.perRequestOutputTokenLimit * plan.price.outputMicrosPerMillionTokens) / 1000000) +
      plan.price.fixedCostMicros;
  }

  static validate(manifest: BenchmarkManifest, dataset: BenchmarkDataset, plan: SystemBenchmarkExecutionPlan,
    admission: SystemBenchmarkAdmissionSnapshot): SystemBenchmarkExecutionPreflightResult {
    const result: SystemBenchmarkExecutionPreflightResult = new SystemBenchmarkExecutionPreflightResult();
    const manifestValidation: TestKitValidationResult = BenchmarkManifestValidator.validate(manifest);
    const datasetValidation: TestKitValidationResult = BenchmarkDatasetValidator.validate(dataset);
    appendIssues(result, 'manifest: ', manifestValidation.issues);
    appendIssues(result, 'dataset: ', datasetValidation.issues);

    const clarifications: number = clarificationCount(dataset);
    result.expectedRecordCount = dataset.cases.length * manifest.arms.length;
    result.expectedStrongSingleRequests = dataset.cases.length + clarifications;
    result.expectedMultiAgentRequests = dataset.cases.length * 2 + clarifications * 2;
    result.expectedProviderRequestLimit = result.expectedStrongSingleRequests + result.expectedMultiAgentRequests;

    if (plan.schemaVersion !== SYSTEM_BENCHMARK_EXECUTION_PLAN_SCHEMA_VERSION) {
      result.addIssue('unsupported execution plan schemaVersion');
    }
    if (armCount(manifest, BenchmarkArmKind.STRONG_SINGLE_AGENT) !== 1 ||
      armCount(manifest, BenchmarkArmKind.MULTI_AGENT) !== 1) {
      result.addIssue('execution plan requires one strong-single and one multi-agent arm');
    }
    if (clarifications !== 1) result.addIssue('execution plan requires exactly one clarification case');
    if (!sameText(plan.benchmarkId, manifest.benchmarkId)) result.addIssue('benchmarkId must match manifest');
    if (!sameText(plan.suiteVersion, manifest.suiteVersion)) result.addIssue('suiteVersion must match manifest');
    if (!sameText(plan.datasetDigest, manifest.datasetDigest)) result.addIssue('datasetDigest must match manifest');
    if (!isSha256Digest(plan.datasetDigest)) result.addIssue('datasetDigest must be a full sha256 digest');
    if (plan.recordCount !== result.expectedRecordCount) result.addIssue('recordCount must cover the 12 x 2 run');
    if (plan.maxClarificationRounds !== 1) result.addIssue('maxClarificationRounds must be exactly one');
    if (plan.strongSingleRequestLimit !== result.expectedStrongSingleRequests) {
      result.addIssue('strongSingleRequestLimit must match the bounded role plan');
    }
    if (plan.multiAgentRequestLimit !== result.expectedMultiAgentRequests) {
      result.addIssue('multiAgentRequestLimit must match the bounded role plan');
    }
    if (plan.providerRequestLimit !== result.expectedProviderRequestLimit) {
      result.addIssue('providerRequestLimit must equal both arm limits');
    }
    if (!isPositiveInteger(plan.perRequestInputTokenLimit)) {
      result.addIssue('perRequestInputTokenLimit must be a positive integer');
    }
    if (!isPositiveInteger(plan.perRequestOutputTokenLimit)) {
      result.addIssue('perRequestOutputTokenLimit must be a positive integer');
    }

    SystemBenchmarkExecutionPreflightValidator.validatePrice(manifest, plan.price, result);
    if (isPositiveInteger(plan.perRequestInputTokenLimit) &&
      isPositiveInteger(plan.perRequestOutputTokenLimit) &&
      isPositiveInteger(plan.price.inputMicrosPerMillionTokens) &&
      isPositiveInteger(plan.price.outputMicrosPerMillionTokens)) {
      result.expectedMonetaryCostLimitMicros =
        SystemBenchmarkExecutionPreflightValidator.calculatePerRequestCostMicros(plan) *
        result.expectedProviderRequestLimit;
      const safeArithmetic: boolean = Number.isSafeInteger(
        plan.perRequestInputTokenLimit * plan.price.inputMicrosPerMillionTokens) && Number.isSafeInteger(
        plan.perRequestOutputTokenLimit * plan.price.outputMicrosPerMillionTokens) &&
        Number.isSafeInteger(result.expectedMonetaryCostLimitMicros);
      if (!safeArithmetic) result.addIssue('execution cost arithmetic exceeds safe integer bounds');
      if (!safeArithmetic || plan.monetaryCostLimitMicros !== result.expectedMonetaryCostLimitMicros) {
        result.addIssue('monetaryCostLimitMicros must equal the pinned worst-case request envelope');
      }
    }

    SystemBenchmarkExecutionPreflightValidator.validateAdmission(plan, admission, result);
    return result;
  }

  private static validatePrice(manifest: BenchmarkManifest, price: SystemBenchmarkExecutionPrice,
    result: SystemBenchmarkExecutionPreflightResult): void {
    if (!sameText(price.priceSnapshotId, manifest.priceSnapshotId)) {
      result.addIssue('priceSnapshotId must match manifest');
    }
    if (!sameText(price.priceSnapshotDigest, manifest.priceSnapshotDigest)) {
      result.addIssue('priceSnapshotDigest must match manifest');
    }
    if (!isSha256Digest(price.priceSnapshotDigest)) {
      result.addIssue('priceSnapshotDigest must be a full sha256 digest');
    }
    if (!sameText(price.providerId, manifest.providerId)) result.addIssue('price providerId must match manifest');
    if (!sameText(price.modelId, manifest.modelId)) result.addIssue('price modelId must match manifest');
    if (!sameText(price.modelVersion, manifest.modelVersion)) result.addIssue('price modelVersion must match manifest');
    if (!sameText(price.region, manifest.region)) result.addIssue('price region must match manifest');
    if (!isNonEmptyText(price.upstreamProviderId)) result.addIssue('upstreamProviderId is required');
    if (!isNonEmptyText(price.upstreamModelId)) result.addIssue('upstreamModelId is required');
    if (!isNonEmptyText(price.upstreamModelVersion)) result.addIssue('upstreamModelVersion is required');
    if (!isNonEmptyText(price.upstreamRegion)) result.addIssue('upstreamRegion is required');
    if (price.currency !== 'USD_MICROS') result.addIssue('price currency must be USD_MICROS');
    if (!isNonEmptyText(price.pricingTier)) result.addIssue('pricingTier is required');
    if (!hasIsoDatePrefix(price.frozenAt)) result.addIssue('price frozenAt must include an ISO date');
    if (!price.sourceUrl.startsWith('https://')) result.addIssue('price sourceUrl must use https');
    if (!isPositiveInteger(price.inputMicrosPerMillionTokens)) {
      result.addIssue('input price must be a positive integer');
    }
    if (!isPositiveInteger(price.outputMicrosPerMillionTokens)) {
      result.addIssue('output price must be a positive integer');
    }
    if (!Number.isSafeInteger(price.fixedCostMicros) || price.fixedCostMicros < 0) {
      result.addIssue('fixed price must be a non-negative integer');
    }
  }

  private static validateAdmission(plan: SystemBenchmarkExecutionPlan, admission: SystemBenchmarkAdmissionSnapshot,
    result: SystemBenchmarkExecutionPreflightResult): void {
    if (!hasIsoDatePrefix(admission.observedAt)) result.addIssue('admission observedAt must include an ISO date');
    if (!admission.gatewayRunning) result.addIssue('local gateway must be running');
    if (!isNonEmptyText(admission.activeProfileId)) result.addIssue('active gateway profile is required');
    if (!isSha256Digest(admission.activeProfileDigest)) {
      result.addIssue('active gateway profile digest is required');
    }
    if (!isPositiveInteger(admission.activeConfigurationRevision)) {
      result.addIssue('active gateway configuration revision is required');
    }
    if (!sameText(admission.providerId, plan.price.providerId)) {
      result.addIssue('admission providerId must match the execution price');
    }
    if (!sameText(admission.modelId, plan.price.modelId)) {
      result.addIssue('admission modelId must match the execution price');
    }
    if (!sameText(admission.modelVersion, plan.price.modelVersion)) {
      result.addIssue('admission modelVersion must match the execution price');
    }
    if (!sameText(admission.region, plan.price.region)) {
      result.addIssue('admission region must match the execution price');
    }
    if (!sameText(admission.upstreamProviderId, plan.price.upstreamProviderId) ||
      !sameText(admission.upstreamModelId, plan.price.upstreamModelId) ||
      !sameText(admission.upstreamModelVersion, plan.price.upstreamModelVersion) ||
      !sameText(admission.upstreamRegion, plan.price.upstreamRegion)) {
      result.addIssue('admission upstream identity must match the execution price');
    }
    if (!sameText(admission.priceSnapshotId, plan.price.priceSnapshotId) ||
      !sameText(admission.priceSnapshotDigest, plan.price.priceSnapshotDigest)) {
      result.addIssue('admission price snapshot must match the execution price');
    }
    if (!isNonEmptyText(admission.executionAuthorizationRef)) {
      result.addIssue('explicit execution authorization reference is required');
    }
  }
}
