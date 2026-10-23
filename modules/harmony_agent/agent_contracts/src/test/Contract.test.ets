import { describe, expect, it } from '@ohos/hypium';
import {
  AGENT_CONTRACT_SCHEMA_VERSION,
  AGENT_CONTRACTS_VERSION,
  ArtifactApprovalStatus,
  ArtifactKind,
  ArtifactLifecycleStatus,
  ArtifactManifest,
  AgentRuntimeEvent,
  AgentRuntimeEventType,
  AgentTaskSnapshot,
  AgentTaskStatus,
  AuthorizationDecision,
  AuthorizationDecisionType,
  AuthorizationGrant,
  ClarificationRequest,
  ClarificationResponse,
  CommandReceipt,
  ContractCodec,
  ContractValidationResult,
  ContractValidator,
  DataBoundary,
  IdempotencyMode,
  PrivacyClass,
  PolicyRequest,
  ReconciliationReport,
  ReconciliationStatus,
  RiskLevel,
  RouterCandidate,
  RouterDecision,
  RouterKind,
  RouterRequest,
  SideEffect,
  TaskControlAction,
  TaskControlCommand,
  TaskEnvelope,
  TaskHandle,
  TaskInputRef,
  TaskSubmission,
  ToolDescriptor,
  ToolInvocation,
  ToolOutcome,
  ToolOutcomeStatus,
  ToolSourceType,
  TraceEvent,
  WorkflowGraph,
  WorkflowStep,
  WorkflowStepKind
} from '../../Index';

function validTask(): TaskEnvelope {
  const task: TaskEnvelope = new TaskEnvelope();
  task.requestId = 'request-20260929-001';
  task.taskId = 'task-20260929-001';
  task.sessionId = 'session-local-17';
  task.userId = 'user-local';
  task.userIntent = '整理本周经过授权的日程摘要';
  task.locale = 'zh-CN';
  task.timeZone = 'Asia/Shanghai';
  task.referenceTime = '2026-09-29T09:30:00+08:00';
  task.privacyClass = PrivacyClass.SENSITIVE;
  task.createdAt = '2026-09-29T09:30:00+08:00';
  task.executionBudget.maxWallTimeMs = 45000;
  task.executionBudget.maxInputTokens = 12000;
  task.executionBudget.maxOutputTokens = 2500;
  task.executionBudget.maxMonetaryCostMicros = 900000;
  task.executionBudget.maxToolCalls = 4;
  task.executionBudget.maxAgentActivations = 1;
  task.executionBudget.maxRetries = 1;
  task.executionBudget.maxReplans = 1;
  const input: TaskInputRef = new TaskInputRef();
  input.refId = 'input-calendar-week';
  input.mediaType = 'application/json';
  input.digest = 'sha256:calendar-fixture';
  input.source = 'device-calendar';
  task.inputRefs = [input];
  return task;
}

function validWorkflow(): WorkflowGraph {
  const graph: WorkflowGraph = new WorkflowGraph();
  graph.workflowId = 'workflow-weekly-summary';
  graph.taskId = 'task-20260929-001';
  graph.workflowVersion = '1.0.0';
  graph.createdAt = '2026-09-29T09:30:01+08:00';
  const step: WorkflowStep = new WorkflowStep();
  step.stepId = 'read-calendar';
  step.kind = WorkflowStepKind.TOOL;
  step.goal = '读取已授权时间范围内的日程';
  step.expectedOutputSchemaJson = '{"type":"object"}';
  step.sideEffect = SideEffect.NONE;
  step.riskLevel = RiskLevel.MEDIUM;
  step.idempotencyMode = IdempotencyMode.NONE;
  step.timeoutMs = 10000;
  step.retryPolicyRef = 'policy.safe-read-once';
  step.verificationPolicyRef = 'verify.calendar-shape';
  graph.entryStepIds = [step.stepId];
  graph.steps = [step];
  return graph;
}

function validArtifact(status: ArtifactLifecycleStatus = ArtifactLifecycleStatus.SHADOW): ArtifactManifest {
  const artifact: ArtifactManifest = new ArtifactManifest();
  artifact.artifactId = 'mtrouter-policy-2026-10';
  artifact.artifactKind = ArtifactKind.POLICY;
  artifact.algorithm = 'MTRouter';
  artifact.artifactVersion = '0.1.0';
  artifact.sourceCommit = '0123456789abcdef0123456789abcdef01234567';
  artifact.sourceLicense = 'MIT';
  artifact.trainingDataLineage = ['harmony-agent-bench:system-live:20261017'];
  artifact.modelAndProviderSnapshotJson = '{"provider":"fixture","model":"mtrouter-v1"}';
  artifact.featureSchemaVersion = 'harmony_agent-router-features-1';
  artifact.runtimeCompatibility = ['harmony_agent-runtime>=2.7.0', 'api>=26'];
  artifact.artifactDigest = 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  artifact.paperReproductionResultsJson = '{"quality":0.75}';
  artifact.portParityResultsJson = '{"matched":12,"total":12}';
  artifact.harmonyAgentBenchResultsJson = '{"passed":true}';
  artifact.lifecycleStatus = status;
  return artifact;
}

function approveAndSignArtifact(artifact: ArtifactManifest): void {
  artifact.approvalStatus = ArtifactApprovalStatus.APPROVED;
  artifact.approvedBy = 'artifact-release-policy-v1';
  artifact.approvedAt = '2026-10-17T22:00:00+08:00';
  artifact.signedManifestDigest =
    'sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  artifact.signatureAlgorithm = 'SHA256withECDSA';
  artifact.signingKeyId = 'release-key-fixture';
  artifact.signatureBase64 = 'AQIDBA==';
  artifact.signedAt = '2026-10-17T22:01:00+08:00';
}

export default function contractTest(): void {
  describe('AgentContracts', () => {
    it('exportsStableVersionsAndWireEnums', 0, () => {
      expect(AGENT_CONTRACTS_VERSION).assertEqual('0.3.0');
      expect(AGENT_CONTRACT_SCHEMA_VERSION).assertEqual('1');
      expect(SideEffect.IRREVERSIBLE).assertEqual('irreversible');
      expect(DataBoundary.DEVICE_ONLY).assertEqual('deviceOnly');
    });

    it('roundTripsTaskEnvelopeWithExplicitUnits', 0, () => {
      const json: string = ContractCodec.stringify(validTask());
      const decoded: TaskEnvelope = ContractCodec.parseTaskEnvelope(json);
      expect(decoded.taskId).assertEqual('task-20260929-001');
      expect(decoded.executionBudget.maxWallTimeMs).assertEqual(45000);
      expect(decoded.executionBudget.maxMonetaryCostMicros).assertEqual(900000);
      expect(decoded.inputRefs[0].digest).assertEqual('sha256:calendar-fixture');
    });

    it('keepsDefaultsAndIgnoresUnknownFutureFields', 0, () => {
      const json: string = '{"schemaVersion":"1","taskId":"future-task",' +
        '"futureField":{"enabled":true}}';
      const decoded: TaskEnvelope = ContractCodec.parseTaskEnvelope(json);
      expect(decoded.taskId).assertEqual('future-task');
      expect(decoded.contractType).assertEqual('TaskEnvelope');
      expect(decoded.executionBudget.maxToolCalls).assertEqual(0);
      expect(decoded.consentContext.interactiveAllowed).assertTrue();
    });

    it('validatesTaskAndRejectsNegativeBudget', 0, () => {
      const task: TaskEnvelope = validTask();
      const valid: ContractValidationResult = ContractValidator.validateTaskEnvelope(task);
      expect(valid.valid).assertTrue();
      task.executionBudget.maxToolCalls = -1;
      const invalid: ContractValidationResult = ContractValidator.validateTaskEnvelope(task);
      expect(invalid.valid).assertFalse();
      expect(invalid.issues.length).assertEqual(1);
    });

    it('rejectsFractionalCountUnitsAndWrongContractType', 0, () => {
      const task: TaskEnvelope = validTask();
      task.executionBudget.maxInputTokens = 12.5;
      task.contractType = 'ToolDescriptor';
      const invalid: ContractValidationResult = ContractValidator.validateTaskEnvelope(task);
      expect(invalid.valid).assertFalse();
      expect(invalid.issues.length).assertEqual(2);
    });

    it('validatesWorkflowShapeWithoutOwningGraphSemantics', 0, () => {
      const graph: WorkflowGraph = validWorkflow();
      const valid: ContractValidationResult = ContractValidator.validateWorkflowGraphShape(graph);
      expect(valid.valid).assertTrue();
      graph.steps[0].retryPolicyRef = '';
      const invalid: ContractValidationResult = ContractValidator.validateWorkflowGraphShape(graph);
      expect(invalid.valid).assertFalse();
      expect(invalid.issues.length).assertEqual(1);
    });

    it('bindsAuthorizationGrantToToolSchemaAndArguments', 0, () => {
      const grant: AuthorizationGrant = new AuthorizationGrant();
      grant.grantId = 'grant-98';
      grant.policyRequestId = 'policy-request-44';
      grant.decisionCommandId = 'authorization-command-44';
      grant.userId = 'user-local';
      grant.taskId = 'task-20260929-001';
      grant.stepId = 'write-calendar';
      grant.operationId = 'operation-calendar-44';
      grant.toolId = 'mcp:calendar:list';
      grant.toolIdentityVersion = 'calendar-list-4';
      grant.schemaDigest = 'sha256:schema-v4';
      grant.argumentsDigest = 'sha256:args-v2';
      grant.budgetReservationId = 'budget-policy-request-44';
      grant.policyVersion = 'policy-3';
      grant.issuedAt = '2026-09-29T09:31:00+08:00';
      grant.expiresAt = '2026-09-29T09:36:00+08:00';
      grant.issuedAtMs = 1000;
      grant.expiresAtMs = 2000;
      const result: ContractValidationResult = ContractValidator.validateAuthorizationGrant(grant);
      expect(result.valid).assertTrue();
      grant.argumentsDigest = '';
      expect(ContractValidator.validateAuthorizationGrant(grant).valid).assertFalse();
    });

    it('validatesNormalizedToolDescriptor', 0, () => {
      const tool: ToolDescriptor = new ToolDescriptor();
      tool.toolId = 'mcp:calendar:list@4';
      tool.sourceType = ToolSourceType.MCP;
      tool.providerId = 'calendar-server';
      tool.capabilityName = 'list';
      tool.capabilityVersion = '4';
      tool.toolIdentityVersion = 'calendar-list-4';
      tool.inputSchemaJson = '{"type":"object"}';
      tool.schemaDigest = 'sha256:schema-v4';
      tool.adapterRef = 'adapter.mcp';
      const result: ContractValidationResult = ContractValidator.validateToolDescriptor(tool);
      expect(result.valid).assertTrue();
    });

    it('requiresAuditableArtifactIdentity', 0, () => {
      const artifact: ArtifactManifest = validArtifact();
      const decodedArtifact: ArtifactManifest = ContractCodec.parseArtifactManifest(ContractCodec.stringify(artifact));
      expect(decodedArtifact.harmonyAgentBenchResultsJson).assertEqual('{"passed":true}');
      expect(ContractValidator.validateArtifactManifest(artifact).valid).assertTrue();
      artifact.checkpointDigest = artifact.artifactDigest;
      expect(ContractValidator.validateArtifactManifest(artifact).valid).assertTrue();
      artifact.checkpointDigest =
        'sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd';
      expect(ContractValidator.validateArtifactManifest(artifact).valid).assertFalse();
      artifact.checkpointDigest = '';
      artifact.sourceLicense = '';
      expect(ContractValidator.validateArtifactManifest(artifact).valid).assertFalse();
    });

    it('defaultsMissingArtifactFieldsAndFailsClosed', 0, () => {
      const artifact: ArtifactManifest = ContractCodec.parseArtifactManifest('{"artifactId":"partial"}');
      expect(artifact.contractType).assertEqual('ArtifactManifest');
      expect(artifact.trainingDataLineage.length).assertEqual(0);
      expect(ContractValidator.validateArtifactManifest(artifact).valid).assertFalse();
    });

    it('rejectsTruncatedArtifactIdentityAndDigest', 0, () => {
      const artifact: ArtifactManifest = validArtifact();
      artifact.sourceCommit = '0123456789abcdef';
      artifact.artifactDigest = 'sha256:checkpoint';
      const result: ContractValidationResult = ContractValidator.validateArtifactManifest(artifact);
      expect(result.valid).assertFalse();
      expect(result.issues.length).assertEqual(2);
    });

    it('keepsPaperParityAndAdaptationEvidenceSeparate', 0, () => {
      const artifact: ArtifactManifest = validArtifact();
      artifact.portParityResultsJson = artifact.paperReproductionResultsJson;
      expect(ContractValidator.validateArtifactManifest(artifact).valid).assertTrue();
      artifact.portParityResultsJson = '{}';
      expect(ContractValidator.validateArtifactManifest(artifact).valid).assertFalse();
      artifact.portParityResultsJson = '{broken';
      expect(ContractValidator.validateArtifactManifest(artifact).valid).assertFalse();
    });

    it('allowsUnsignedShadowAndRejectsUnsignedActive', 0, () => {
      const shadow: ArtifactManifest = validArtifact(ArtifactLifecycleStatus.SHADOW);
      expect(ContractValidator.validateArtifactManifest(shadow).valid).assertTrue();
      shadow.signatureAlgorithm = 'SHA256withECDSA';
      expect(ContractValidator.validateArtifactManifest(shadow).valid).assertFalse();
      shadow.signatureAlgorithm = '';
      shadow.lifecycleStatus = ArtifactLifecycleStatus.ACTIVE;
      expect(ContractValidator.validateArtifactManifest(shadow).valid).assertFalse();
      approveAndSignArtifact(shadow);
      expect(ContractValidator.validateArtifactManifest(shadow).valid).assertTrue();
    });

    it('enforcesArtifactLifecycleTransitions', 0, () => {
      expect(ContractValidator.validateArtifactLifecycleTransition(
        ArtifactLifecycleStatus.DISABLED, ArtifactLifecycleStatus.SHADOW).valid).assertTrue();
      expect(ContractValidator.validateArtifactLifecycleTransition(
        ArtifactLifecycleStatus.SHADOW, ArtifactLifecycleStatus.ACTIVE).valid).assertFalse();
      expect(ContractValidator.validateArtifactLifecycleTransition(
        ArtifactLifecycleStatus.CANARY, ArtifactLifecycleStatus.ACTIVE).valid).assertTrue();
      expect(ContractValidator.validateArtifactLifecycleTransition(
        ArtifactLifecycleStatus.ACTIVE, ArtifactLifecycleStatus.ROLLED_BACK).valid).assertTrue();
      expect(ContractValidator.validateArtifactLifecycleTransition(
        ArtifactLifecycleStatus.ROLLED_BACK, ArtifactLifecycleStatus.ACTIVE).valid).assertFalse();
    });

    it('rejectsIncompleteLineageCompatibilityAndSignatureMetadata', 0, () => {
      const artifact: ArtifactManifest = validArtifact(ArtifactLifecycleStatus.CANARY);
      approveAndSignArtifact(artifact);
      artifact.trainingDataLineage = [];
      artifact.runtimeCompatibility = ['api>=26', 'api>=26'];
      artifact.signatureBase64 = 'not-base64!';
      const result: ContractValidationResult = ContractValidator.validateArtifactManifest(artifact);
      expect(result.valid).assertFalse();
      expect(result.issues.length).assertEqual(3);
    });

    it('requiresDifferentRollbackTargetDigest', 0, () => {
      const artifact: ArtifactManifest = validArtifact(ArtifactLifecycleStatus.ROLLED_BACK);
      approveAndSignArtifact(artifact);
      expect(ContractValidator.validateArtifactManifest(artifact).valid).assertFalse();
      artifact.rollbackTargetDigest = artifact.artifactDigest;
      expect(ContractValidator.validateArtifactManifest(artifact).valid).assertFalse();
      artifact.rollbackTargetDigest =
        'sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
      expect(ContractValidator.validateArtifactManifest(artifact).valid).assertTrue();
    });

    it('roundTripsAndValidatesRoutingPolicyInvocationOutcomeAndTrace', 0, () => {
      const candidate: RouterCandidate = new RouterCandidate();
      candidate.candidateId = 'model:balanced-v3';
      candidate.metadataJson = '{"region":"cn"}';
      const request: RouterRequest = new RouterRequest();
      request.requestId = 'router-request-1';
      request.taskId = 'task-20260929-001';
      request.routerKind = RouterKind.MODEL;
      request.candidates = [candidate];
      request.createdAt = '2026-09-29T09:31:10+08:00';
      const decodedRequest: RouterRequest = ContractCodec.parseRouterRequest(ContractCodec.stringify(request));
      expect(ContractValidator.validateRouterRequest(decodedRequest).valid).assertTrue();

      const decision: RouterDecision = new RouterDecision();
      decision.decisionId = 'router-decision-1';
      decision.requestId = request.requestId;
      decision.routerKind = RouterKind.MODEL;
      decision.policyVersion = 'static-model-router-1';
      decision.inputFeatureDigest = 'sha256:features';
      decision.eligibleCandidateIds = [candidate.candidateId];
      decision.selectedCandidateIds = [candidate.candidateId];
      decision.confidence = 1;
      decision.createdAt = '2026-09-29T09:31:11+08:00';
      expect(ContractValidator.validateRouterDecision(decision).valid).assertTrue();

      const policy: PolicyRequest = new PolicyRequest();
      policy.requestId = 'policy-request-1';
      policy.userId = 'user-local';
      policy.taskId = request.taskId;
      policy.stepId = 'read-calendar';
      policy.operationId = 'operation-read-calendar-1';
      policy.toolId = 'mcp:calendar:list@4';
      policy.toolIdentityVersion = 'calendar-list-4';
      policy.providerId = 'calendar-server';
      policy.schemaDigest = 'sha256:schema-v4';
      policy.argumentsDigest = 'sha256:args-v2';
      policy.requestedAt = '2026-09-29T09:31:12+08:00';
      policy.expiresAt = '2026-09-29T09:36:12+08:00';
      policy.expiresAtMs = 2000;
      expect(ContractValidator.validatePolicyRequest(policy).valid).assertTrue();

      const invocation: ToolInvocation = new ToolInvocation();
      invocation.invocationId = 'invocation-1';
      invocation.taskId = request.taskId;
      invocation.stepId = policy.stepId;
      invocation.operationId = policy.operationId;
      invocation.attemptId = 'attempt-read-calendar-1';
      invocation.toolId = policy.toolId;
      invocation.toolIdentityVersion = policy.toolIdentityVersion;
      invocation.schemaDigest = policy.schemaDigest;
      invocation.argumentsJson = '{"from":"2026-09-22","to":"2026-09-29"}';
      invocation.argumentsDigest = policy.argumentsDigest;
      invocation.authorizationGrantId = 'grant-98';
      invocation.timeoutMs = 10000;
      invocation.createdAt = '2026-09-29T09:31:13+08:00';
      const decodedInvocation: ToolInvocation = ContractCodec.parseToolInvocation(
        ContractCodec.stringify(invocation));
      expect(ContractValidator.validateToolInvocation(decodedInvocation).valid).assertTrue();

      const outcome: ToolOutcome = new ToolOutcome();
      outcome.invocationId = invocation.invocationId;
      outcome.status = ToolOutcomeStatus.SUCCEEDED;
      outcome.resultJson = '{"events":[]}';
      outcome.startedAt = '2026-09-29T09:31:13+08:00';
      outcome.finishedAt = '2026-09-29T09:31:14+08:00';
      expect(ContractValidator.validateToolOutcome(outcome).valid).assertTrue();

      const trace: TraceEvent = new TraceEvent();
      trace.eventId = 'trace-1';
      trace.taskId = request.taskId;
      trace.stepId = invocation.stepId;
      trace.eventType = 'tool.completed';
      trace.timestamp = outcome.finishedAt;
      trace.component = 'mcp-agent-adapter';
      trace.componentVersion = '0.1.0';
      trace.privacyRedactionVersion = 'redaction-1';
      expect(ContractValidator.validateTraceEvent(trace).valid).assertTrue();
    });

    it('validatesSubmissionWithoutCallerAssignedTaskIdentity', 0, () => {
      const submission: TaskSubmission = new TaskSubmission();
      submission.requestId = 'request-calendar-create-77';
      submission.userId = 'user-local';
      submission.userIntent = '明天下午三点创建一小时项目复盘日程';
      submission.locale = 'zh-CN';
      submission.timeZone = 'Asia/Shanghai';
      submission.referenceTime = '2026-09-29T10:00:00+08:00';
      submission.submittedAt = '2026-09-29T10:00:01+08:00';
      submission.requestedBudget.maxToolCalls = 2;
      const decoded: TaskSubmission = ContractCodec.parseTaskSubmission(ContractCodec.stringify(submission));
      expect(ContractValidator.validateTaskSubmission(decoded).valid).assertTrue();
      expect(decoded.requestId).assertEqual('request-calendar-create-77');
    });

    it('requiresDenialReasonAndKeepsDecisionSeparateFromGrant', 0, () => {
      const decision: AuthorizationDecision = new AuthorizationDecision();
      decision.commandId = 'authorization-command-78';
      decision.policyRequestId = 'policy-request-78';
      decision.userId = 'user-local';
      decision.taskId = 'task-calendar-create-78';
      decision.decision = AuthorizationDecisionType.DENIED;
      decision.decidedAt = '2026-09-29T10:02:00+08:00';
      decision.decidedAtMs = 2000;
      expect(ContractValidator.validateAuthorizationDecision(decision).valid).assertFalse();
      decision.denialReasonCode = 'user-rejected';
      expect(ContractValidator.validateAuthorizationDecision(decision).valid).assertTrue();
    });

    it('validatesVersionedControlEventSnapshotAndReconciliationContracts', 0, () => {
      const handle: TaskHandle = new TaskHandle();
      handle.requestId = 'request-79';
      handle.taskId = 'task-79';
      handle.sessionId = 'session-79';
      handle.acceptedAt = '2026-09-29T10:03:00+08:00';
      handle.snapshotVersion = 1;
      expect(ContractValidator.validateTaskHandle(handle).valid).assertTrue();

      const command: TaskControlCommand = new TaskControlCommand();
      command.commandId = 'command-pause-79';
      command.taskId = handle.taskId;
      command.action = TaskControlAction.PAUSE;
      command.reasonCode = 'caller-backgrounded';
      command.requestedAt = '2026-09-29T10:03:01+08:00';
      expect(ContractValidator.validateTaskControlCommand(command).valid).assertTrue();

      const receipt: CommandReceipt = new CommandReceipt();
      receipt.commandId = command.commandId;
      receipt.taskId = command.taskId;
      receipt.accepted = true;
      receipt.snapshotVersion = 2;
      expect(ContractValidator.validateCommandReceipt(receipt).valid).assertTrue();

      const event: AgentRuntimeEvent = new AgentRuntimeEvent();
      event.eventId = 'event-79-3';
      event.taskId = handle.taskId;
      event.sequence = 3;
      event.snapshotVersion = 2;
      event.eventType = AgentRuntimeEventType.TASK_STATE_CHANGED;
      event.timestamp = '2026-09-29T10:03:02+08:00';
      event.payloadJson = '{"status":"paused"}';
      expect(ContractValidator.validateAgentRuntimeEvent(event).valid).assertTrue();

      const snapshot: AgentTaskSnapshot = new AgentTaskSnapshot();
      snapshot.requestId = handle.requestId;
      snapshot.taskId = handle.taskId;
      snapshot.sessionId = handle.sessionId;
      snapshot.status = AgentTaskStatus.PAUSED;
      snapshot.snapshotVersion = 2;
      snapshot.lastEventSequence = event.sequence;
      snapshot.updatedAt = event.timestamp;
      expect(ContractValidator.validateAgentTaskSnapshot(snapshot).valid).assertTrue();

      const reconciliation: ReconciliationReport = new ReconciliationReport();
      reconciliation.commandId = 'command-reconcile-79';
      reconciliation.taskId = handle.taskId;
      reconciliation.stepId = 'create-calendar';
      reconciliation.operationId = 'operation-calendar-79';
      reconciliation.status = ReconciliationStatus.CONFIRMED_SUCCEEDED;
      reconciliation.evidenceDigest = 'sha256:calendar-provider-receipt';
      reconciliation.reportedAt = '2026-09-29T10:04:00+08:00';
      expect(ContractValidator.validateReconciliationReport(reconciliation).valid).assertTrue();
    });

    it('roundTripsClarificationRequestAndResponse', 0, () => {
      const request: ClarificationRequest = new ClarificationRequest();
      request.clarificationId = 'clarification-time-zone-80';
      request.taskId = 'task-80';
      request.questionCode = 'MISSING_TIME_ZONE';
      request.prompt = '请选择日程使用的时区';
      request.responseSchemaJson = '{"type":"string"}';
      request.requestedAt = '2026-09-29T10:05:00+08:00';
      request.expiresAt = '2026-09-29T10:10:00+08:00';
      request.expiresAtMs = 5000;
      const decodedRequest: ClarificationRequest = ContractCodec.parseClarificationRequest(
        ContractCodec.stringify(request));
      expect(ContractValidator.validateClarificationRequest(decodedRequest).valid).assertTrue();

      const response: ClarificationResponse = new ClarificationResponse();
      response.commandId = 'command-clarification-80';
      response.clarificationId = request.clarificationId;
      response.taskId = request.taskId;
      response.answerJson = '"Asia/Shanghai"';
      response.respondedAt = '2026-09-29T10:05:10+08:00';
      response.respondedAtMs = 1000;
      const decodedResponse: ClarificationResponse = ContractCodec.parseClarificationResponse(
        ContractCodec.stringify(response));
      expect(ContractValidator.validateClarificationResponse(decodedResponse).valid).assertTrue();
    });
  });
}
