import {
  isNonEmptyText,
  isPositiveInteger,
  TestKitValidationResult
} from './Common';

export enum BenchmarkTaskKind {
  READ_ONLY_RETRIEVAL = 'readOnlyRetrieval',
  MULTI_SOURCE_SYNTHESIS = 'multiSourceSynthesis',
  STRUCTURED_EXTRACTION = 'structuredExtraction',
  SCHEMA_TRANSFORMATION = 'schemaTransformation',
  TOOL_SELECTION = 'toolSelection',
  SEQUENTIAL_WORKFLOW = 'sequentialWorkflow',
  PARALLEL_WORKFLOW = 'parallelWorkflow',
  CLARIFICATION_REQUIRED = 'clarificationRequired',
  AUTHORIZATION_REQUIRED = 'authorizationRequired',
  BUDGET_CONSTRAINED = 'budgetConstrained',
  RECOVERY_RECONCILIATION = 'recoveryReconciliation',
  LONG_TERM_MEMORY_RECALL = 'longTermMemoryRecall'
}

export class BenchmarkTaskCase {
  caseId: string = '';
  kind: BenchmarkTaskKind = BenchmarkTaskKind.READ_ONLY_RETRIEVAL;
  promptTemplate: string = '';
  requiredCapabilities: string[] = [];
  expectedEvidence: string[] = [];
  requiresAuthorization: boolean = false;
  includesFailureRecovery: boolean = false;
}

export class BenchmarkDataset {
  datasetId: string = '';
  datasetVersion: string = '';
  frozenAt: string = '';
  cases: BenchmarkTaskCase[] = [];
}

export class ToolScaleCase {
  caseId: string = '';
  registrySize: number = 0;
  targetToolId: string = '';
  queryTerms: string[] = [];
}

function includesText(values: string[], target: string): boolean {
  for (let index: number = 0; index < values.length; index++) {
    if (values[index] === target) return true;
  }
  return false;
}

function cloneText(values: string[]): string[] {
  const clone: string[] = [];
  for (let index: number = 0; index < values.length; index++) clone.push(values[index]);
  return clone;
}

function task(caseId: string, kind: BenchmarkTaskKind, promptTemplate: string,
  requiredCapabilities: string[], expectedEvidence: string[], requiresAuthorization: boolean = false,
  includesFailureRecovery: boolean = false): BenchmarkTaskCase {
  const value: BenchmarkTaskCase = new BenchmarkTaskCase();
  value.caseId = caseId;
  value.kind = kind;
  value.promptTemplate = promptTemplate;
  value.requiredCapabilities = cloneText(requiredCapabilities);
  value.expectedEvidence = cloneText(expectedEvidence);
  value.requiresAuthorization = requiresAuthorization;
  value.includesFailureRecovery = includesFailureRecovery;
  return value;
}

function cloneTask(source: BenchmarkTaskCase): BenchmarkTaskCase {
  return task(source.caseId, source.kind, source.promptTemplate, source.requiredCapabilities,
    source.expectedEvidence, source.requiresAuthorization, source.includesFailureRecovery);
}

function hasIsoDatePrefix(value: string): boolean {
  return value.length >= 10 && value.charAt(4) === '-' && value.charAt(7) === '-';
}

export class BenchmarkDatasetValidator {
  static validate(dataset: BenchmarkDataset): TestKitValidationResult {
    const result: TestKitValidationResult = new TestKitValidationResult();
    if (!isNonEmptyText(dataset.datasetId)) result.addIssue('datasetId is required');
    if (!isNonEmptyText(dataset.datasetVersion)) result.addIssue('datasetVersion is required');
    if (!hasIsoDatePrefix(dataset.frozenAt)) result.addIssue('frozenAt must include an ISO date');
    if (dataset.cases.length !== 12) result.addIssue('pilot dataset must contain exactly twelve cases');

    const caseIds: string[] = [];
    const kinds: string[] = [];
    for (let index: number = 0; index < dataset.cases.length; index++) {
      const value: BenchmarkTaskCase = dataset.cases[index];
      const prefix: string = 'cases[' + index.toString() + '] ';
      if (!isNonEmptyText(value.caseId)) {
        result.addIssue(prefix + 'caseId is required');
      } else if (includesText(caseIds, value.caseId)) {
        result.addIssue(prefix + 'caseId must be unique');
      } else {
        caseIds.push(value.caseId);
      }
      if (includesText(kinds, value.kind)) {
        result.addIssue(prefix + 'task kind must be unique');
      } else {
        kinds.push(value.kind);
      }
      if (!isNonEmptyText(value.promptTemplate)) result.addIssue(prefix + 'promptTemplate is required');
      if (value.requiredCapabilities.length === 0) result.addIssue(prefix + 'requiredCapabilities are required');
      if (value.expectedEvidence.length === 0) result.addIssue(prefix + 'expectedEvidence is required');
    }
    return result;
  }
}

export class HarmonyAgentBenchPilotCatalog {
  static datasetV1(): BenchmarkDataset {
    const dataset: BenchmarkDataset = new BenchmarkDataset();
    dataset.datasetId = 'harmony-agent-bench-pilot';
    dataset.datasetVersion = '1.0.0';
    dataset.frozenAt = '2026-10-12T00:00:00+08:00';
    const source: BenchmarkTaskCase[] = [
      task('pilot-01-read-only-retrieval', BenchmarkTaskKind.READ_ONLY_RETRIEVAL,
        'Retrieve one pinned fact and cite its tool evidence.', ['tool.read'], ['toolOutcome', 'sourceIdentity']),
      task('pilot-02-multi-source-synthesis', BenchmarkTaskKind.MULTI_SOURCE_SYNTHESIS,
        'Combine two pinned read-only sources and preserve provenance.', ['tool.read', 'evidence.merge'],
        ['toolOutcome', 'sourceIdentity', 'mergedEvidence']),
      task('pilot-03-structured-extraction', BenchmarkTaskKind.STRUCTURED_EXTRACTION,
        'Extract the requested fields from a pinned fixture.', ['schema.extract'], ['schemaDigest', 'fieldEvidence']),
      task('pilot-04-schema-transformation', BenchmarkTaskKind.SCHEMA_TRANSFORMATION,
        'Transform a pinned input into the requested output schema.', ['schema.transform'],
        ['inputDigest', 'outputSchemaDigest']),
      task('pilot-05-tool-selection', BenchmarkTaskKind.TOOL_SELECTION,
        'Select the only eligible tool from a distractor registry.', ['router.tool'],
        ['registrySnapshot', 'routerDecision']),
      task('pilot-06-sequential-workflow', BenchmarkTaskKind.SEQUENTIAL_WORKFLOW,
        'Execute two dependent read-only steps in order.', ['workflow.sequence', 'tool.read'],
        ['stepTrace', 'dependencyEvidence']),
      task('pilot-07-parallel-workflow', BenchmarkTaskKind.PARALLEL_WORKFLOW,
        'Execute two independent read-only steps and join their results.', ['workflow.parallel', 'tool.read'],
        ['stepTrace', 'joinEvidence']),
      task('pilot-08-clarification-required', BenchmarkTaskKind.CLARIFICATION_REQUIRED,
        'Detect a missing required field and request clarification.', ['runtime.clarification'],
        ['clarificationEvent']),
      task('pilot-09-authorization-required', BenchmarkTaskKind.AUTHORIZATION_REQUIRED,
        'Stop before a protected action until an external decision is supplied.', ['policy.authorization'],
        ['policyRequest', 'authorizationBinding'], true),
      task('pilot-10-budget-constrained', BenchmarkTaskKind.BUDGET_CONSTRAINED,
        'Respect a pinned token and tool-call budget.', ['budget.enforcement'], ['budgetLedger']),
      task('pilot-11-recovery-reconciliation', BenchmarkTaskKind.RECOVERY_RECONCILIATION,
        'Recover an uncertain write as unknown and require reconciliation.', ['runtime.recovery', 'operation.reconcile'],
        ['operationId', 'unknownOutcome', 'reconciliationEvent'], true, true),
      task('pilot-12-long-term-memory-recall', BenchmarkTaskKind.LONG_TERM_MEMORY_RECALL,
        'Recall one pinned durable fact without exposing unrelated memory.', ['memory.read'],
        ['memoryRecordId', 'scopeEvidence'])
    ];
    for (let index: number = 0; index < source.length; index++) dataset.cases.push(cloneTask(source[index]));
    return dataset;
  }

  static toolScaleV1(): ToolScaleCase[] {
    const sizes: number[] = [32, 128, 512];
    const cases: ToolScaleCase[] = [];
    for (let index: number = 0; index < sizes.length; index++) {
      const value: ToolScaleCase = new ToolScaleCase();
      value.caseId = 'tool-scale-' + sizes[index].toString();
      value.registrySize = sizes[index];
      value.targetToolId = 'fixture.weather.current';
      value.queryTerms = ['current', 'weather', 'fixture-city'];
      cases.push(value);
    }
    return cases;
  }
}

export class ToolScaleCaseValidator {
  static validate(cases: ToolScaleCase[]): TestKitValidationResult {
    const result: TestKitValidationResult = new TestKitValidationResult();
    if (cases.length !== 3) result.addIssue('tool scale suite must contain exactly three cases');
    const expectedSizes: number[] = [32, 128, 512];
    const seenSizes: number[] = [];
    const caseIds: string[] = [];
    for (let index: number = 0; index < cases.length; index++) {
      const value: ToolScaleCase = cases[index];
      const prefix: string = 'cases[' + index.toString() + '] ';
      if (!isNonEmptyText(value.caseId)) {
        result.addIssue(prefix + 'caseId is required');
      } else if (includesText(caseIds, value.caseId)) {
        result.addIssue(prefix + 'caseId must be unique');
      } else {
        caseIds.push(value.caseId);
      }
      if (!isPositiveInteger(value.registrySize)) result.addIssue(prefix + 'registrySize must be a positive integer');
      if (seenSizes.indexOf(value.registrySize) >= 0) {
        result.addIssue(prefix + 'registrySize must be unique');
      } else {
        seenSizes.push(value.registrySize);
      }
      if (!isNonEmptyText(value.targetToolId)) result.addIssue(prefix + 'targetToolId is required');
      if (value.queryTerms.length === 0) result.addIssue(prefix + 'queryTerms are required');
    }
    for (let index: number = 0; index < expectedSizes.length; index++) {
      if (seenSizes.indexOf(expectedSizes[index]) < 0) {
        result.addIssue('missing required registry size ' + expectedSizes[index].toString());
      }
    }
    return result;
  }
}
