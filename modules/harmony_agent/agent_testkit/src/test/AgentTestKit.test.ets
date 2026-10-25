import { describe, expect, it } from '@ohos/hypium';
import {
  AGENT_TESTKIT_SCHEMA_VERSION,
  AGENT_TESTKIT_VERSION,
  BenchmarkArm,
  BenchmarkArmKind,
  BenchmarkDataset,
  BenchmarkDatasetValidator,
  BenchmarkEvaluator,
  BenchmarkManifest,
  BenchmarkManifestValidator,
  BenchmarkRecordResult,
  BenchmarkSample,
  BenchmarkSummary,
  DeterministicFaultInjector,
  FaultKind,
  FaultPhase,
  FaultRule,
  FaultScript,
  FaultScriptValidator,
  HarmonyAgentBenchPilotCatalog,
  IntegrationFixtureCatalog,
  IntegrationFixtureDescriptor,
  IntegrationFixtureKind,
  SYSTEM_BENCHMARK_RUN_SCHEMA_VERSION,
  SYSTEM_BENCHMARK_EXECUTION_PLAN_SCHEMA_VERSION,
  SystemBenchmarkAdmissionSnapshot,
  SystemBenchmarkAgentEvidence,
  SystemBenchmarkAppendResult,
  SystemBenchmarkEnvironment,
  SystemBenchmarkEvidence,
  SystemBenchmarkExecutionPlan,
  SystemBenchmarkExecutionPreflightResult,
  SystemBenchmarkExecutionPreflightValidator,
  SystemBenchmarkExecutionPrice,
  SystemBenchmarkMeasurementMode,
  SystemBenchmarkRecord,
  SystemBenchmarkRun,
  SystemBenchmarkRunRecorder,
  SystemBenchmarkRunValidator,
  SystemBenchmarkSealResult,
  ToolScaleCase,
  ToolScaleCaseValidator
} from '../../Index';

function arm(armId: string, kind: BenchmarkArmKind): BenchmarkArm {
  const value: BenchmarkArm = new BenchmarkArm();
  value.armId = armId;
  value.kind = kind;
  value.permissionPolicyVersion = 'permission-policy-7';
  value.contextPolicyVersion = 'context-policy-4';
  return value;
}

function manifest(): BenchmarkManifest {
  const value: BenchmarkManifest = new BenchmarkManifest();
  value.benchmarkId = 'harmony-agent-bench-pilot';
  value.suiteVersion = '2026.10.12';
  value.frozenAt = '2026-10-12T00:00:00+08:00';
  value.datasetDigest = 'sha256:dataset-pilot-v1';
  value.modelId = 'fixture-model-balanced';
  value.modelVersion = '2026-09';
  value.providerId = 'fixture-provider';
  value.region = 'local-fixture';
  value.priceSnapshotId = 'fixture-price-2026-10-12';
  value.priceSnapshotDigest = 'sha256:fixture-price-v1';
  value.routerPolicyVersion = 'deterministic-router-1';
  value.arms = [
    arm('strong-single', BenchmarkArmKind.STRONG_SINGLE_AGENT),
    arm('multi-agent', BenchmarkArmKind.MULTI_AGENT)
  ];
  return value;
}

function sample(caseId: string, runId: string, armId: string, latencyMs: number): BenchmarkSample {
  const value: BenchmarkSample = new BenchmarkSample();
  value.caseId = caseId;
  value.runId = runId;
  value.armId = armId;
  value.passed = true;
  value.qualityScoreBasisPoints = 8200;
  value.inputTokens = 1100;
  value.outputTokens = 240;
  value.monetaryCostMicros = 3200;
  value.latencyMs = latencyMs;
  value.toolCalls = 2;
  value.agentActivations = armId === 'multi-agent' ? 2 : 1;
  value.recoveryEvents = 0;
  value.routerDecisions = 2;
  value.routerCorrectDecisions = 2;
  return value;
}

function fullDigest(character: string): string {
  let value: string = 'sha256:';
  for (let index: number = 0; index < 64; index++) value += character;
  return value;
}

function systemManifest(): BenchmarkManifest {
  const value: BenchmarkManifest = manifest();
  value.datasetDigest = fullDigest('a');
  value.modelId = 'aigw/default';
  value.modelVersion = 'deepseek-pinned-2026-10-14';
  value.providerId = 'local-ai-gateway';
  value.region = 'local-windows';
  value.priceSnapshotId = 'deepseek-price-2026-10-14';
  value.priceSnapshotDigest = fullDigest('b');
  return value;
}

function executionPrice(valueManifest: BenchmarkManifest): SystemBenchmarkExecutionPrice {
  const value: SystemBenchmarkExecutionPrice = new SystemBenchmarkExecutionPrice();
  value.priceSnapshotId = valueManifest.priceSnapshotId;
  value.priceSnapshotDigest = valueManifest.priceSnapshotDigest;
  value.providerId = valueManifest.providerId;
  value.modelId = valueManifest.modelId;
  value.modelVersion = valueManifest.modelVersion;
  value.region = valueManifest.region;
  value.upstreamProviderId = 'deepseek';
  value.upstreamModelId = 'deepseek-flash';
  value.upstreamModelVersion = 'DeepSeek-V4.1-Flash';
  value.upstreamRegion = 'global';
  value.currency = 'USD_MICROS';
  value.pricingTier = 'peak-cache-miss';
  value.frozenAt = '2026-10-17T00:00:00+08:00';
  value.sourceUrl = 'https://api-docs.deepseek.com/quick_start/pricing/';
  value.inputMicrosPerMillionTokens = 300000;
  value.outputMicrosPerMillionTokens = 1200000;
  value.fixedCostMicros = 0;
  return value;
}

function executionPlan(valueManifest: BenchmarkManifest): SystemBenchmarkExecutionPlan {
  const value: SystemBenchmarkExecutionPlan = new SystemBenchmarkExecutionPlan();
  value.benchmarkId = valueManifest.benchmarkId;
  value.suiteVersion = valueManifest.suiteVersion;
  value.datasetDigest = valueManifest.datasetDigest;
  value.recordCount = 24;
  value.maxClarificationRounds = 1;
  value.strongSingleRequestLimit = 13;
  value.multiAgentRequestLimit = 26;
  value.providerRequestLimit = 39;
  value.perRequestInputTokenLimit = 4096;
  value.perRequestOutputTokenLimit = 8192;
  value.price = executionPrice(valueManifest);
  value.monetaryCostLimitMicros =
    SystemBenchmarkExecutionPreflightValidator.calculatePerRequestCostMicros(value) * value.providerRequestLimit;
  return value;
}

function admissionSnapshot(plan: SystemBenchmarkExecutionPlan): SystemBenchmarkAdmissionSnapshot {
  const value: SystemBenchmarkAdmissionSnapshot = new SystemBenchmarkAdmissionSnapshot();
  value.observedAt = '2026-10-17T10:00:00+08:00';
  value.gatewayRunning = true;
  value.activeProfileId = 'deepseek';
  value.activeProfileDigest = fullDigest('e');
  value.activeConfigurationRevision = 14;
  value.providerId = plan.price.providerId;
  value.modelId = plan.price.modelId;
  value.modelVersion = plan.price.modelVersion;
  value.region = plan.price.region;
  value.upstreamProviderId = plan.price.upstreamProviderId;
  value.upstreamModelId = plan.price.upstreamModelId;
  value.upstreamModelVersion = plan.price.upstreamModelVersion;
  value.upstreamRegion = plan.price.upstreamRegion;
  value.priceSnapshotId = plan.price.priceSnapshotId;
  value.priceSnapshotDigest = plan.price.priceSnapshotDigest;
  value.executionAuthorizationRef = 'user-approved-bench-batch-20261017';
  return value;
}

function systemEvidence(taskId: string, expectedEvidence: string[], armKind: BenchmarkArmKind): SystemBenchmarkEvidence {
  const value: SystemBenchmarkEvidence = new SystemBenchmarkEvidence();
  value.taskId = taskId;
  value.taskSnapshotDigest = fullDigest('1');
  value.eventTraceDigest = fullDigest('2');
  value.providerUsageDigest = fullDigest('3');
  value.resultDigest = fullDigest('4');
  value.qualityEvidenceDigest = fullDigest('5');
  value.roleRegistryDigest = fullDigest('a');
  value.collaborationDecisionDigest = fullDigest('b');
  value.evidenceKinds = expectedEvidence.slice();
  value.usedAgentRuntimeFacade = true;
  const agentCount: number = armKind === BenchmarkArmKind.MULTI_AGENT ? 2 : 1;
  const requestDigestCharacters: string[] = ['6', '7'];
  const traceDigestCharacters: string[] = ['8', '9'];
  for (let index: number = 0; index < agentCount; index++) {
    const agent: SystemBenchmarkAgentEvidence = new SystemBenchmarkAgentEvidence();
    agent.activationId = taskId + '-activation-' + index.toString();
    agent.roleId = index === 0 ? 'planner' : 'verifier';
    agent.roleVersion = '1';
    agent.providerRequestCount = 1;
    agent.providerRequestIdsDigest = fullDigest(requestDigestCharacters[index]);
    agent.traceDigest = fullDigest(traceDigestCharacters[index]);
    agent.resultDigest = fullDigest(index === 0 ? 'c' : 'd');
    value.agentEvidence.push(agent);
  }
  value.providerRequestCount = agentCount;
  return value;
}

function systemRun(valueManifest: BenchmarkManifest, dataset: BenchmarkDataset): SystemBenchmarkRun {
  const run: SystemBenchmarkRun = new SystemBenchmarkRun();
  run.executionId = 'system-run-20261014-1';
  run.measurementMode = SystemBenchmarkMeasurementMode.REAL_PROVIDER_RUNTIME;
  run.startedAt = '2026-10-14T14:00:00+08:00';
  run.completedAt = '2026-10-14T14:30:00+08:00';
  run.performanceComparable = true;
  run.redactionPolicyVersion = 'bench-redaction-1';
  run.qualityJudgeId = 'pinned-rubric';
  run.qualityJudgeVersion = '1';
  const environment: SystemBenchmarkEnvironment = new SystemBenchmarkEnvironment();
  environment.sourceCommit = '1234567890abcdef1234567890abcdef12345678';
  environment.runtimeVersion = '0.12.0';
  environment.compositionVersion = '2.4';
  environment.harnessVersion = '1';
  environment.sdkVersion = '26.0.0';
  environment.osVersion = 'OpenHarmony-7.0.0';
  environment.deviceClass = 'api26-emulator';
  environment.measurementClock = 'system-monotonic-ms';
  environment.environmentDigest = fullDigest('c');
  run.environment = environment;
  for (let caseIndex: number = 0; caseIndex < dataset.cases.length; caseIndex++) {
    for (let armIndex: number = 0; armIndex < valueManifest.arms.length; armIndex++) {
      const armValue: BenchmarkArm = valueManifest.arms[armIndex];
      const record: SystemBenchmarkRecord = new SystemBenchmarkRecord();
      record.sample = sample(dataset.cases[caseIndex].caseId, run.executionId, armValue.armId,
        100 + caseIndex + armIndex);
      record.sample.agentActivations = armValue.kind === BenchmarkArmKind.MULTI_AGENT ? 2 : 1;
      record.evidence = systemEvidence('task-' + caseIndex.toString() + '-' + armIndex.toString(),
        dataset.cases[caseIndex].expectedEvidence, armValue.kind);
      run.records.push(record);
    }
  }
  return run;
}

function rule(ruleId: string, occurrence: number, kind: FaultKind): FaultRule {
  const value: FaultRule = new FaultRule();
  value.ruleId = ruleId;
  value.targetId = 'provider:model.generate';
  value.phase = FaultPhase.DURING_CALL;
  value.occurrence = occurrence;
  value.kind = kind;
  return value;
}

export default function agentTestKitTest(): void {
  describe('AgentTestKit', () => {
    it('exportsVersionedPublicContract', 0, () => {
      expect(AGENT_TESTKIT_VERSION).assertEqual('0.6.0');
      expect(AGENT_TESTKIT_SCHEMA_VERSION).assertEqual('1');
      expect(SYSTEM_BENCHMARK_RUN_SCHEMA_VERSION).assertEqual('2');
      expect(SYSTEM_BENCHMARK_EXECUTION_PLAN_SCHEMA_VERSION).assertEqual('1');
    });

    it('coversEveryArchitectureFaultKind', 0, () => {
      const kinds: FaultKind[] = [
        FaultKind.NETWORK_DISCONNECTED,
        FaultKind.TIMEOUT,
        FaultKind.HTTP_429,
        FaultKind.HTTP_5XX,
        FaultKind.AUTHENTICATION_FAILED,
        FaultKind.PERMISSION_DENIED,
        FaultKind.SCHEMA_DRIFT,
        FaultKind.DUPLICATE_RESPONSE,
        FaultKind.APPLICATION_RESTART,
        FaultKind.BUDGET_EXHAUSTED,
        FaultKind.LOW_QUALITY_OUTPUT,
        FaultKind.IRREVERSIBLE_UNKNOWN_OUTCOME
      ];
      expect(kinds.length).assertEqual(12);
    });

    it('matchesFaultsByTargetPhaseAndOccurrence', 0, () => {
      const script: FaultScript = new FaultScript();
      script.scriptId = 'second-call-timeout';
      script.scriptVersion = '1';
      const timeout: FaultRule = rule('timeout-on-second-call', 2, FaultKind.TIMEOUT);
      timeout.latencyMs = 15000;
      script.rules = [timeout];
      const injector: DeterministicFaultInjector = new DeterministicFaultInjector(script);

      expect(injector.next('provider:model.generate', FaultPhase.DURING_CALL).matched).assertFalse();
      const second = injector.next('provider:model.generate', FaultPhase.DURING_CALL);
      expect(second.matched).assertTrue();
      expect(second.kind).assertEqual(FaultKind.TIMEOUT);
      expect(second.latencyMs).assertEqual(15000);
      expect(injector.next('provider:model.generate', FaultPhase.AFTER_RESPONSE).matched).assertFalse();
    });

    it('resetMakesFaultScheduleReproducible', 0, () => {
      const script: FaultScript = new FaultScript();
      script.scriptId = 'disconnect-first-call';
      script.scriptVersion = '1';
      script.rules = [rule('disconnect', 1, FaultKind.NETWORK_DISCONNECTED)];
      const injector: DeterministicFaultInjector = new DeterministicFaultInjector(script);
      expect(injector.next('provider:model.generate', FaultPhase.DURING_CALL).matched).assertTrue();
      expect(injector.next('provider:model.generate', FaultPhase.DURING_CALL).matched).assertFalse();
      injector.reset();
      expect(injector.next('provider:model.generate', FaultPhase.DURING_CALL).matched).assertTrue();
    });

    it('rejectsAmbiguousOrMalformedFaultMetadata', 0, () => {
      const script: FaultScript = new FaultScript();
      script.scriptId = 'bad-script';
      script.scriptVersion = '1';
      const first: FaultRule = rule('same-rule', 0, FaultKind.HTTP_429);
      first.statusCode = 500;
      const second: FaultRule = rule('same-rule', 1, FaultKind.DUPLICATE_RESPONSE);
      const collision: FaultRule = rule('colliding-schedule', 1, FaultKind.NETWORK_DISCONNECTED);
      script.rules = [first, second, collision];
      const validation = FaultScriptValidator.validate(script);
      expect(validation.valid).assertFalse();
      expect(validation.issues.length).assertEqual(5);
    });

    it('requiresFullyPinnedBenchmarkIdentity', 0, () => {
      const value: BenchmarkManifest = manifest();
      expect(BenchmarkManifestValidator.validate(value).valid).assertTrue();
      value.priceSnapshotDigest = '';
      value.contractSchemaVersion = 'future';
      const invalid = BenchmarkManifestValidator.validate(value);
      expect(invalid.valid).assertFalse();
      expect(invalid.issues.length).assertEqual(2);
    });

    it('requiresSamePermissionAndContextPoliciesAcrossArms', 0, () => {
      const value: BenchmarkManifest = manifest();
      value.arms[1].permissionPolicyVersion = 'broader-policy';
      value.arms[1].contextPolicyVersion = 'larger-context';
      const invalid = BenchmarkManifestValidator.validate(value);
      expect(invalid.valid).assertFalse();
      expect(invalid.issues.length).assertEqual(2);
    });

    it('exportsDeterministicQualityCostLatencyAndRuntimeMetrics', 0, () => {
      const evaluator: BenchmarkEvaluator = new BenchmarkEvaluator(manifest());
      const latencies: number[] = [410, 90, 270, 160, 520];
      for (let index: number = 0; index < latencies.length; index++) {
        const value: BenchmarkSample = sample('case-' + index.toString(), 'run-1',
          index % 2 === 0 ? 'strong-single' : 'multi-agent', latencies[index]);
        value.qualityScoreBasisPoints = 8000 + index * 100;
        if (index === 4) value.passed = false;
        expect(evaluator.record(value).accepted).assertTrue();
      }
      const summary: BenchmarkSummary = evaluator.summarize();
      expect(summary.sampleCount).assertEqual(5);
      expect(summary.passedCount).assertEqual(4);
      expect(summary.failedCount).assertEqual(1);
      expect(summary.averageQualityBasisPoints).assertEqual(8200);
      expect(summary.latencyP50Ms).assertEqual(270);
      expect(summary.latencyP95Ms).assertEqual(520);
      expect(summary.inputTokens).assertEqual(5500);
      expect(summary.outputTokens).assertEqual(1200);
      expect(summary.monetaryCostMicros).assertEqual(16000);
      expect(summary.toolCalls).assertEqual(10);
      expect(summary.agentActivations).assertEqual(7);
      expect(summary.routerDecisions).assertEqual(10);
      expect(summary.routerCorrectDecisions).assertEqual(10);
      expect(evaluator.summarizeArm('strong-single').sampleCount).assertEqual(3);
      expect(evaluator.summarizeArm('multi-agent').sampleCount).assertEqual(2);
      expect(evaluator.report().armSummaries.length).assertEqual(2);
      expect(evaluator.report().armSummaries[0].armId).assertEqual('strong-single');
    });

    it('rejectsInvalidAndDuplicateSamplesWithoutChangingSummary', 0, () => {
      const evaluator: BenchmarkEvaluator = new BenchmarkEvaluator(manifest());
      const first: BenchmarkSample = sample('case-recovery', 'run-8', 'strong-single', 800);
      expect(evaluator.record(first).accepted).assertTrue();
      const duplicate: BenchmarkRecordResult = evaluator.record(first);
      expect(duplicate.accepted).assertFalse();
      const invalid: BenchmarkSample = sample('case-invalid', 'run-8', 'unknown-arm', 200);
      invalid.routerCorrectDecisions = 3;
      invalid.routerDecisions = 2;
      expect(evaluator.record(invalid).issues.length).assertEqual(2);
      expect(evaluator.summarize().sampleCount).assertEqual(1);
    });

    it('copiesInputsAndExportsAConsumerSafeReport', 0, () => {
      const source: BenchmarkManifest = manifest();
      const evaluator: BenchmarkEvaluator = new BenchmarkEvaluator(source);
      source.modelId = 'mutated-model';
      const recorded: BenchmarkSample = sample('case-copy', 'run-3', 'strong-single', 340);
      expect(evaluator.record(recorded).accepted).assertTrue();
      recorded.inputTokens = 999999;
      const json: string = evaluator.reportJson();
      expect(json.includes('fixture-model-balanced')).assertTrue();
      expect(json.includes('mutated-model')).assertFalse();
      expect(json.includes('"inputTokens":1100')).assertTrue();
      expect(json.includes('secret')).assertFalse();
    });

    it('publishesTheTenSharedIntegrationFixtures', 0, () => {
      const fixtures: IntegrationFixtureDescriptor[] = IntegrationFixtureCatalog.baseline();
      expect(fixtures.length).assertEqual(10);
      expect(fixtures[0].kind).assertEqual(IntegrationFixtureKind.INVALID_INPUT);
      expect(fixtures[5].kind).assertEqual(IntegrationFixtureKind.UNKNOWN_WRITE_OUTCOME);
      expect(fixtures[6].requiresProcessRestart).assertTrue();
      expect(fixtures[6].expectedAdapterCalls).assertEqual(1);
      expect(fixtures[9].kind).assertEqual(IntegrationFixtureKind.BUDGET_EXHAUSTED);
    });

    it('publishesTwelveUniqueBenchPilotTaskKinds', 0, () => {
      const dataset: BenchmarkDataset = HarmonyAgentBenchPilotCatalog.datasetV1();
      expect(BenchmarkDatasetValidator.validate(dataset).valid).assertTrue();
      expect(dataset.cases.length).assertEqual(12);
      expect(dataset.cases[0].caseId).assertEqual('pilot-01-read-only-retrieval');
      expect(dataset.cases[8].requiresAuthorization).assertTrue();
      expect(dataset.cases[10].includesFailureRecovery).assertTrue();
    });

    it('returnsAnIsolatedBenchPilotDatasetCopy', 0, () => {
      const first: BenchmarkDataset = HarmonyAgentBenchPilotCatalog.datasetV1();
      first.cases[0].caseId = 'mutated';
      first.cases[0].requiredCapabilities[0] = 'mutated';
      const second: BenchmarkDataset = HarmonyAgentBenchPilotCatalog.datasetV1();
      expect(second.cases[0].caseId).assertEqual('pilot-01-read-only-retrieval');
      expect(second.cases[0].requiredCapabilities[0]).assertEqual('tool.read');
    });

    it('rejectsIncompleteOrDuplicateBenchPilotCases', 0, () => {
      const dataset: BenchmarkDataset = HarmonyAgentBenchPilotCatalog.datasetV1();
      dataset.cases.pop();
      dataset.cases[1].caseId = dataset.cases[0].caseId;
      dataset.cases[1].kind = dataset.cases[0].kind;
      const validation = BenchmarkDatasetValidator.validate(dataset);
      expect(validation.valid).assertFalse();
      expect(validation.issues.length).assertEqual(3);
    });

    it('pinsTheRequiredToolRegistryScales', 0, () => {
      const cases: ToolScaleCase[] = HarmonyAgentBenchPilotCatalog.toolScaleV1();
      expect(ToolScaleCaseValidator.validate(cases).valid).assertTrue();
      expect(cases.length).assertEqual(3);
      expect(cases[0].registrySize).assertEqual(32);
      expect(cases[1].registrySize).assertEqual(128);
      expect(cases[2].registrySize).assertEqual(512);
    });

    it('rejectsMissingAndDuplicateToolRegistryScales', 0, () => {
      const cases: ToolScaleCase[] = HarmonyAgentBenchPilotCatalog.toolScaleV1();
      cases[2].registrySize = 128;
      const validation = ToolScaleCaseValidator.validate(cases);
      expect(validation.valid).assertFalse();
      expect(validation.issues.length).assertEqual(2);
    });

    it('acceptsACompleteRealProviderFacadeSystemBenchRun', 0, () => {
      const valueManifest: BenchmarkManifest = systemManifest();
      const dataset: BenchmarkDataset = HarmonyAgentBenchPilotCatalog.datasetV1();
      const run: SystemBenchmarkRun = systemRun(valueManifest, dataset);
      expect(SystemBenchmarkRunValidator.validate(valueManifest, dataset, run).valid).assertTrue();
    });

    it('rejectsFixtureIdentityAndVirtualClockAsSystemEvidence', 0, () => {
      const valueManifest: BenchmarkManifest = manifest();
      valueManifest.datasetDigest = fullDigest('a');
      valueManifest.priceSnapshotDigest = fullDigest('b');
      const dataset: BenchmarkDataset = HarmonyAgentBenchPilotCatalog.datasetV1();
      const run: SystemBenchmarkRun = systemRun(valueManifest, dataset);
      run.environment.measurementClock = 'deterministic-virtual-zero';
      const validation = SystemBenchmarkRunValidator.validate(valueManifest, dataset, run);
      expect(validation.valid).assertFalse();
      expect(validation.issues.join('|').includes('production candidate')).assertTrue();
      expect(validation.issues.join('|').includes('real monotonic clock')).assertTrue();
    });

    it('requiresExactlyOneRecordForEveryCaseAndArm', 0, () => {
      const valueManifest: BenchmarkManifest = systemManifest();
      const dataset: BenchmarkDataset = HarmonyAgentBenchPilotCatalog.datasetV1();
      const run: SystemBenchmarkRun = systemRun(valueManifest, dataset);
      run.records.pop();
      run.records.push(run.records[0]);
      const validation = SystemBenchmarkRunValidator.validate(valueManifest, dataset, run);
      expect(validation.valid).assertFalse();
      expect(validation.issues.join('|').includes('caseId and armId must be unique')).assertTrue();
      expect(validation.issues.join('|').includes('missing record')).assertTrue();
    });

    it('requiresFacadeProviderUsageAndDigestOnlyEvidence', 0, () => {
      const valueManifest: BenchmarkManifest = systemManifest();
      const dataset: BenchmarkDataset = HarmonyAgentBenchPilotCatalog.datasetV1();
      const run: SystemBenchmarkRun = systemRun(valueManifest, dataset);
      run.records[0].evidence.usedAgentRuntimeFacade = false;
      run.records[0].evidence.providerRequestCount = 0;
      run.records[0].evidence.eventTraceDigest = '';
      run.records[0].sample.inputTokens = 0;
      run.records[0].sample.outputTokens = 0;
      run.records[0].sample.latencyMs = 0;
      const validation = SystemBenchmarkRunValidator.validate(valueManifest, dataset, run);
      expect(validation.valid).assertFalse();
      const issues: string = validation.issues.join('|');
      expect(issues.includes('AgentRuntimeFacade')).assertTrue();
      expect(issues.includes('providerRequestCount')).assertTrue();
      expect(issues.includes('eventTraceDigest')).assertTrue();
      expect(issues.includes('provider token usage')).assertTrue();
      expect(issues.includes('real clock')).assertTrue();
    });

    it('rejectsMultiArmWithoutDistinctPerAgentProviderEvidence', 0, () => {
      const valueManifest: BenchmarkManifest = systemManifest();
      const dataset: BenchmarkDataset = HarmonyAgentBenchPilotCatalog.datasetV1();
      const run: SystemBenchmarkRun = systemRun(valueManifest, dataset);
      run.records[1].evidence.agentEvidence.pop();
      run.records[1].evidence.providerRequestCount = 1;
      const validation = SystemBenchmarkRunValidator.validate(valueManifest, dataset, run);
      expect(validation.valid).assertFalse();
      const issues: string = validation.issues.join('|');
      expect(issues.includes('agentEvidence count must match agentActivations')).assertTrue();
      expect(issues.includes('at least two distinct agent evidence records')).assertTrue();
    });

    it('rejectsLegacySystemBenchmarkEvidenceSchema', 0, () => {
      const valueManifest: BenchmarkManifest = systemManifest();
      const dataset: BenchmarkDataset = HarmonyAgentBenchPilotCatalog.datasetV1();
      const run: SystemBenchmarkRun = systemRun(valueManifest, dataset);
      run.schemaVersion = '1';
      const validation = SystemBenchmarkRunValidator.validate(valueManifest, dataset, run);
      expect(validation.valid).assertFalse();
      expect(validation.issues.join('|').includes('unsupported schemaVersion')).assertTrue();
    });

    it('requiresPinnedCollaborationAndCaseSpecificEvidence', 0, () => {
      const valueManifest: BenchmarkManifest = systemManifest();
      const dataset: BenchmarkDataset = HarmonyAgentBenchPilotCatalog.datasetV1();
      const run: SystemBenchmarkRun = systemRun(valueManifest, dataset);
      run.records[0].evidence.roleRegistryDigest = '';
      run.records[0].evidence.collaborationDecisionDigest = '';
      run.records[0].evidence.evidenceKinds = [];
      const validation = SystemBenchmarkRunValidator.validate(valueManifest, dataset, run);
      expect(validation.valid).assertFalse();
      const issues: string = validation.issues.join('|');
      expect(issues.includes('roleRegistryDigest')).assertTrue();
      expect(issues.includes('collaborationDecisionDigest')).assertTrue();
      expect(issues.includes('missing expected evidence kind')).assertTrue();
    });

    it('recordsAndDefensivelySealsACompleteSystemRun', 0, () => {
      const valueManifest: BenchmarkManifest = systemManifest();
      const dataset: BenchmarkDataset = HarmonyAgentBenchPilotCatalog.datasetV1();
      const header: SystemBenchmarkRun = systemRun(valueManifest, dataset);
      const records: SystemBenchmarkRecord[] = header.records.slice();
      header.records = [];
      const recorder: SystemBenchmarkRunRecorder =
        new SystemBenchmarkRunRecorder(valueManifest, dataset, header);
      valueManifest.modelId = 'mutated-after-construction';
      dataset.cases[0].caseId = 'mutated-after-construction';

      for (let i: number = 0; i < records.length; i++) {
        expect(recorder.append(records[i]).accepted).assertTrue();
      }
      records[0].sample.inputTokens = 999999;
      expect(recorder.recordCount()).assertEqual(24);
      const sealed: SystemBenchmarkSealResult = recorder.seal();
      expect(sealed.valid).assertTrue();
      expect(sealed.run?.records.length).assertEqual(24);
      expect(sealed.run?.records[0].sample.inputTokens).assertEqual(1100);
      if (sealed.run !== undefined) sealed.run.records[0].sample.inputTokens = 1;
      expect(recorder.seal().run?.records[0].sample.inputTokens).assertEqual(1100);
      expect(recorder.append(records[0]).accepted).assertFalse();
    });

    it('rejectsUnknownAndDuplicateRecordsWithoutPublishingThem', 0, () => {
      const valueManifest: BenchmarkManifest = systemManifest();
      const dataset: BenchmarkDataset = HarmonyAgentBenchPilotCatalog.datasetV1();
      const header: SystemBenchmarkRun = systemRun(valueManifest, dataset);
      const records: SystemBenchmarkRecord[] = header.records.slice();
      header.records = [];
      const recorder: SystemBenchmarkRunRecorder =
        new SystemBenchmarkRunRecorder(valueManifest, dataset, header);

      expect(recorder.append(records[0]).accepted).assertTrue();
      const duplicate: SystemBenchmarkAppendResult = recorder.append(records[0]);
      expect(duplicate.accepted).assertFalse();
      expect(duplicate.issues.join('|').includes('unique')).assertTrue();
      const unknown: SystemBenchmarkRecord = records[2];
      unknown.sample.caseId = 'case-outside-frozen-dataset';
      unknown.evidence.taskId = 'task-outside-frozen-dataset';
      expect(recorder.append(unknown).accepted).assertFalse();
      const malformed: SystemBenchmarkRecord = records[4];
      malformed.evidence.eventTraceDigest = '';
      expect(recorder.append(malformed).accepted).assertFalse();
      malformed.evidence.eventTraceDigest = fullDigest('2');
      expect(recorder.append(malformed).accepted).assertTrue();
      expect(recorder.recordCount()).assertEqual(2);
    });

    it('failsClosedWhenSealingAnIncompleteSystemRun', 0, () => {
      const valueManifest: BenchmarkManifest = systemManifest();
      const dataset: BenchmarkDataset = HarmonyAgentBenchPilotCatalog.datasetV1();
      const header: SystemBenchmarkRun = systemRun(valueManifest, dataset);
      const first: SystemBenchmarkRecord = header.records[0];
      header.records = [];
      const recorder: SystemBenchmarkRunRecorder =
        new SystemBenchmarkRunRecorder(valueManifest, dataset, header);
      expect(recorder.append(first).accepted).assertTrue();

      const sealed: SystemBenchmarkSealResult = recorder.seal();
      expect(sealed.valid).assertFalse();
      expect(sealed.run === undefined).assertTrue();
      expect(sealed.issues.join('|').includes('every dataset case')).assertTrue();
    });

    it('admitsOnlyThePinnedThirtyNineRequestCostEnvelope', 0, () => {
      const valueManifest: BenchmarkManifest = systemManifest();
      const dataset: BenchmarkDataset = HarmonyAgentBenchPilotCatalog.datasetV1();
      const plan: SystemBenchmarkExecutionPlan = executionPlan(valueManifest);
      const admission: SystemBenchmarkAdmissionSnapshot = admissionSnapshot(plan);
      const result: SystemBenchmarkExecutionPreflightResult =
        SystemBenchmarkExecutionPreflightValidator.validate(valueManifest, dataset, plan, admission);
      expect(result.ready).assertTrue();
      expect(result.expectedRecordCount).assertEqual(24);
      expect(result.expectedStrongSingleRequests).assertEqual(13);
      expect(result.expectedMultiAgentRequests).assertEqual(26);
      expect(result.expectedProviderRequestLimit).assertEqual(39);
      expect(result.expectedMonetaryCostLimitMicros).assertEqual(431340);
      expect(plan.monetaryCostLimitMicros).assertEqual(431340);
    });

    it('blocksBenchExecutionWithoutAnActiveProfileAndExplicitAuthorization', 0, () => {
      const valueManifest: BenchmarkManifest = systemManifest();
      const dataset: BenchmarkDataset = HarmonyAgentBenchPilotCatalog.datasetV1();
      const plan: SystemBenchmarkExecutionPlan = executionPlan(valueManifest);
      const admission: SystemBenchmarkAdmissionSnapshot = admissionSnapshot(plan);
      admission.gatewayRunning = false;
      admission.activeProfileId = '';
      admission.activeConfigurationRevision = 0;
      admission.executionAuthorizationRef = '';
      const result: SystemBenchmarkExecutionPreflightResult =
        SystemBenchmarkExecutionPreflightValidator.validate(valueManifest, dataset, plan, admission);
      expect(result.ready).assertFalse();
      const issues: string = result.issues.join('|');
      expect(issues.includes('gateway must be running')).assertTrue();
      expect(issues.includes('active gateway profile')).assertTrue();
      expect(issues.includes('configuration revision')).assertTrue();
      expect(issues.includes('explicit execution authorization')).assertTrue();
    });

    it('rejectsRequestPriceAndUpstreamIdentityDriftBeforeExecution', 0, () => {
      const valueManifest: BenchmarkManifest = systemManifest();
      const dataset: BenchmarkDataset = HarmonyAgentBenchPilotCatalog.datasetV1();
      const plan: SystemBenchmarkExecutionPlan = executionPlan(valueManifest);
      const admission: SystemBenchmarkAdmissionSnapshot = admissionSnapshot(plan);
      plan.providerRequestLimit = 40;
      plan.perRequestOutputTokenLimit = Number.MAX_SAFE_INTEGER;
      plan.price.outputMicrosPerMillionTokens = 600000;
      admission.upstreamModelId = 'changed-upstream-model';
      const result: SystemBenchmarkExecutionPreflightResult =
        SystemBenchmarkExecutionPreflightValidator.validate(valueManifest, dataset, plan, admission);
      expect(result.ready).assertFalse();
      const issues: string = result.issues.join('|');
      expect(issues.includes('providerRequestLimit')).assertTrue();
      expect(issues.includes('safe integer bounds')).assertTrue();
      expect(issues.includes('monetaryCostLimitMicros')).assertTrue();
      expect(issues.includes('upstream identity')).assertTrue();
    });
  });
}
