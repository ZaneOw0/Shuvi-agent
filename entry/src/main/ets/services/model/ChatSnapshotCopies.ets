// Explicit DTO snapshots: nested arrays and records must never alias journal state.
import { RuntimeTaskRecoveryCheckpoint, OrchestrationUsage, PlanningRequest, CollaborationPlan, CollaborationRoleAssignment } from '@harmony_agent/agent-runtime';
import { TaskSubmission, TaskInputRef, ExecutionBudget, ConsentContext, TaskEnvelope, TaskFrame, TaskHandle, AgentTaskSnapshot, AgentRuntimeEvent, WorkflowGraph, WorkflowStep, WorkflowInputBinding, ClarificationRequest, PolicyRequest, ToolInvocation, ToolOutcome } from '@harmony_agent/agent-contracts';
import { WorkflowRuntimeSnapshot, StepRuntimeRecord } from '@harmony_agent/agent-core';

export function copyRuntimeTaskRecoveryCheckpoint(value: RuntimeTaskRecoveryCheckpoint): RuntimeTaskRecoveryCheckpoint {
  const copy = new RuntimeTaskRecoveryCheckpoint();
  copy.collaborationPreparation.version = value.collaborationPreparation.version;
  copy.collaborationPreparation.evaluations = value.collaborationPreparation.evaluations;
  copy.collaborationPreparation.pending = value.collaborationPreparation.pending;
  copy.collaborationPreparation.baselineOnly = value.collaborationPreparation.baselineOnly;
  copy.checkpointVersion = value.checkpointVersion;
  copy.submission = copyTaskSubmission(value.submission);
  copy.envelope = copyTaskEnvelope(value.envelope);
  copy.frame = copyTaskFrame(value.frame);
  copy.collaborationMode = value.collaborationMode;
  copy.handle = copyTaskHandle(value.handle);
  copy.snapshot = copyAgentTaskSnapshot(value.snapshot);
  copy.events = value.events.map((item: AgentRuntimeEvent): AgentRuntimeEvent => copyAgentRuntimeEvent(item));
  copy.usage = copyOrchestrationUsage(value.usage);
  copy.planningRequest = copyPlanningRequest(value.planningRequest);
  if (value.workflow !== undefined) copy.workflow = copyWorkflowGraph(value.workflow);
  if (value.scheduler !== undefined) copy.scheduler = copyWorkflowRuntimeSnapshot(value.scheduler);
  if (value.pendingClarification !== undefined) copy.pendingClarification = copyClarificationRequest(value.pendingClarification);
  if (value.pendingPolicyRequest !== undefined) copy.pendingPolicyRequest = copyPolicyRequest(value.pendingPolicyRequest);
  if (value.pendingInvocation !== undefined) copy.pendingInvocation = copyToolInvocation(value.pendingInvocation);
  if (value.activeInvocation !== undefined) copy.activeInvocation = copyToolInvocation(value.activeInvocation);
  copy.pendingStepId = value.pendingStepId;
  copy.pendingDispatchId = value.pendingDispatchId;
  copy.pendingOperationId = value.pendingOperationId;
  copy.registeredProviderIds = value.registeredProviderIds.slice();
  copy.paused = value.paused;
  return copy;
}

function copyTaskSubmission(value: TaskSubmission): TaskSubmission {
  const copy = new TaskSubmission();
  copy.schemaVersion = value.schemaVersion;
  copy.contractType = value.contractType;
  copy.requestId = value.requestId;
  if (value.conversationId !== undefined) copy.conversationId = value.conversationId;
  copy.userId = value.userId;
  copy.userIntent = value.userIntent;
  copy.locale = value.locale;
  copy.timeZone = value.timeZone;
  copy.referenceTime = value.referenceTime;
  copy.privacyClass = value.privacyClass;
  copy.inputRefs = value.inputRefs.map((item: TaskInputRef): TaskInputRef => copyTaskInputRef(item));
  copy.requestedBudget = copyExecutionBudget(value.requestedBudget);
  copy.consentContext = copyConsentContext(value.consentContext);
  copy.submittedAt = value.submittedAt;
  return copy;
}

function copyTaskInputRef(value: TaskInputRef): TaskInputRef {
  const copy = new TaskInputRef();
  copy.refId = value.refId;
  copy.mediaType = value.mediaType;
  copy.digest = value.digest;
  copy.source = value.source;
  return copy;
}

function copyExecutionBudget(value: ExecutionBudget): ExecutionBudget {
  const copy = new ExecutionBudget();
  copy.maxWallTimeMs = value.maxWallTimeMs;
  copy.maxInputTokens = value.maxInputTokens;
  copy.maxOutputTokens = value.maxOutputTokens;
  copy.maxMonetaryCostMicros = value.maxMonetaryCostMicros;
  copy.maxToolCalls = value.maxToolCalls;
  copy.maxAgentActivations = value.maxAgentActivations;
  copy.maxRetries = value.maxRetries;
  copy.maxReplans = value.maxReplans;
  if (value.deadlineAt !== undefined) copy.deadlineAt = value.deadlineAt;
  return copy;
}

function copyConsentContext(value: ConsentContext): ConsentContext {
  const copy = new ConsentContext();
  copy.interactiveAllowed = value.interactiveAllowed;
  copy.grantedPolicyIds = value.grantedPolicyIds.slice();
  return copy;
}

function copyTaskEnvelope(value: TaskEnvelope): TaskEnvelope {
  const copy = new TaskEnvelope();
  copy.schemaVersion = value.schemaVersion;
  copy.contractType = value.contractType;
  copy.requestId = value.requestId;
  if (value.conversationId !== undefined) copy.conversationId = value.conversationId;
  copy.taskId = value.taskId;
  copy.sessionId = value.sessionId;
  copy.userId = value.userId;
  copy.userIntent = value.userIntent;
  copy.locale = value.locale;
  copy.timeZone = value.timeZone;
  copy.referenceTime = value.referenceTime;
  copy.privacyClass = value.privacyClass;
  copy.inputRefs = value.inputRefs.map((item: TaskInputRef): TaskInputRef => copyTaskInputRef(item));
  copy.executionBudget = copyExecutionBudget(value.executionBudget);
  copy.consentContext = copyConsentContext(value.consentContext);
  if (value.deviceSnapshotRef !== undefined) copy.deviceSnapshotRef = value.deviceSnapshotRef;
  copy.createdAt = value.createdAt;
  return copy;
}

function copyTaskFrame(value: TaskFrame): TaskFrame {
  const copy = new TaskFrame();
  copy.schemaVersion = value.schemaVersion;
  copy.taskId = value.taskId;
  copy.goal = value.goal;
  copy.constraints = value.constraints.slice();
  copy.capabilityCategories = value.capabilityCategories.slice();
  copy.riskLevel = value.riskLevel;
  copy.canParallelize = value.canParallelize;
  copy.featuresJson = value.featuresJson;
  return copy;
}

function copyTaskHandle(value: TaskHandle): TaskHandle {
  const copy = new TaskHandle();
  copy.schemaVersion = value.schemaVersion;
  copy.contractType = value.contractType;
  copy.requestId = value.requestId;
  copy.taskId = value.taskId;
  copy.sessionId = value.sessionId;
  copy.acceptedAt = value.acceptedAt;
  copy.snapshotVersion = value.snapshotVersion;
  return copy;
}

function copyAgentTaskSnapshot(value: AgentTaskSnapshot): AgentTaskSnapshot {
  const copy = new AgentTaskSnapshot();
  copy.schemaVersion = value.schemaVersion;
  copy.contractType = value.contractType;
  copy.requestId = value.requestId;
  copy.taskId = value.taskId;
  copy.sessionId = value.sessionId;
  copy.status = value.status;
  copy.snapshotVersion = value.snapshotVersion;
  copy.lastEventSequence = value.lastEventSequence;
  copy.resultJson = value.resultJson;
  copy.updatedAt = value.updatedAt;
  return copy;
}

function copyAgentRuntimeEvent(value: AgentRuntimeEvent): AgentRuntimeEvent {
  const copy = new AgentRuntimeEvent();
  copy.schemaVersion = value.schemaVersion;
  copy.contractType = value.contractType;
  copy.eventId = value.eventId;
  copy.taskId = value.taskId;
  copy.sequence = value.sequence;
  copy.snapshotVersion = value.snapshotVersion;
  copy.eventType = value.eventType;
  copy.timestamp = value.timestamp;
  copy.payloadJson = value.payloadJson;
  return copy;
}

function copyOrchestrationUsage(value: OrchestrationUsage): OrchestrationUsage {
  const copy = new OrchestrationUsage();
  copy.plannerCalls = value.plannerCalls;
  copy.agentActivations = value.agentActivations;
  copy.replans = value.replans;
  return copy;
}

function copyPlanningRequest(value: PlanningRequest): PlanningRequest {
  const copy = new PlanningRequest();
  copy.envelope = copyTaskEnvelope(value.envelope);
  copy.frame = copyTaskFrame(value.frame);
  copy.collaborationMode = value.collaborationMode;
  if (value.collaborationPlan !== undefined) copy.collaborationPlan = copyCollaborationPlan(value.collaborationPlan);
  if (value.previousWorkflow !== undefined) copy.previousWorkflow = copyWorkflowGraph(value.previousWorkflow);
  copy.affectedStepIds = value.affectedStepIds.slice();
  return copy;
}

function copyCollaborationPlan(value: CollaborationPlan): CollaborationPlan {
  const copy = new CollaborationPlan();
  copy.planVersion = value.planVersion;
  copy.taskId = value.taskId;
  copy.mode = value.mode;
  copy.roleRegistryDigest = value.roleRegistryDigest;
  copy.decisionDigest = value.decisionDigest;
  copy.assignments = value.assignments.map((item: CollaborationRoleAssignment): CollaborationRoleAssignment => copyCollaborationRoleAssignment(item));
  return copy;
}

function copyCollaborationRoleAssignment(value: CollaborationRoleAssignment): CollaborationRoleAssignment {
  const copy = new CollaborationRoleAssignment();
  copy.roleId = value.roleId;
  copy.roleVersion = value.roleVersion;
  copy.roleRegistryDigest = value.roleRegistryDigest;
  return copy;
}

function copyWorkflowGraph(value: WorkflowGraph): WorkflowGraph {
  const copy = new WorkflowGraph();
  copy.schemaVersion = value.schemaVersion;
  copy.contractType = value.contractType;
  copy.workflowId = value.workflowId;
  copy.taskId = value.taskId;
  copy.workflowVersion = value.workflowVersion;
  copy.entryStepIds = value.entryStepIds.slice();
  copy.steps = value.steps.map((item: WorkflowStep): WorkflowStep => copyWorkflowStep(item));
  copy.createdAt = value.createdAt;
  return copy;
}

function copyWorkflowStep(value: WorkflowStep): WorkflowStep {
  const copy = new WorkflowStep();
  copy.stepId = value.stepId;
  copy.kind = value.kind;
  copy.goal = value.goal;
  copy.dependencies = value.dependencies.slice();
  copy.inputBindings = value.inputBindings.map((item: WorkflowInputBinding): WorkflowInputBinding => copyWorkflowInputBinding(item));
  copy.expectedOutputSchemaJson = value.expectedOutputSchemaJson;
  copy.capabilityRequirements = value.capabilityRequirements.slice();
  copy.sideEffect = value.sideEffect;
  copy.riskLevel = value.riskLevel;
  copy.permissionRequirements = value.permissionRequirements.slice();
  copy.idempotencyMode = value.idempotencyMode;
  copy.timeoutMs = value.timeoutMs;
  copy.retryPolicyRef = value.retryPolicyRef;
  copy.verificationPolicyRef = value.verificationPolicyRef;
  return copy;
}

function copyWorkflowInputBinding(value: WorkflowInputBinding): WorkflowInputBinding {
  const copy = new WorkflowInputBinding();
  copy.name = value.name;
  if (value.sourceStepId !== undefined) copy.sourceStepId = value.sourceStepId;
  if (value.sourceOutputPath !== undefined) copy.sourceOutputPath = value.sourceOutputPath;
  if (value.literalJson !== undefined) copy.literalJson = value.literalJson;
  return copy;
}

function copyWorkflowRuntimeSnapshot(value: WorkflowRuntimeSnapshot): WorkflowRuntimeSnapshot {
  const copy = new WorkflowRuntimeSnapshot();
  copy.workflowId = value.workflowId;
  copy.taskId = value.taskId;
  copy.runState = value.runState;
  copy.steps = value.steps.map((item: StepRuntimeRecord): StepRuntimeRecord => copyStepRuntimeRecord(item));
  copy.cancellationRequested = value.cancellationRequested;
  copy.deadlineAtMs = value.deadlineAtMs;
  copy.terminalReason = value.terminalReason;
  copy.nextEventSequence = value.nextEventSequence;
  return copy;
}

function copyStepRuntimeRecord(value: StepRuntimeRecord): StepRuntimeRecord {
  const copy = new StepRuntimeRecord();
  copy.stepId = value.stepId;
  copy.state = value.state;
  copy.attemptCount = value.attemptCount;
  copy.startedAtMs = value.startedAtMs;
  copy.finishedAtMs = value.finishedAtMs;
  copy.lastErrorClass = value.lastErrorClass;
  copy.outputDigest = value.outputDigest;
  return copy;
}

function copyClarificationRequest(value: ClarificationRequest): ClarificationRequest {
  const copy = new ClarificationRequest();
  copy.schemaVersion = value.schemaVersion;
  copy.contractType = value.contractType;
  copy.clarificationId = value.clarificationId;
  copy.taskId = value.taskId;
  copy.questionCode = value.questionCode;
  copy.prompt = value.prompt;
  copy.responseSchemaJson = value.responseSchemaJson;
  copy.requestedAt = value.requestedAt;
  copy.expiresAt = value.expiresAt;
  copy.expiresAtMs = value.expiresAtMs;
  return copy;
}

function copyPolicyRequest(value: PolicyRequest): PolicyRequest {
  const copy = new PolicyRequest();
  copy.schemaVersion = value.schemaVersion;
  copy.contractType = value.contractType;
  copy.requestId = value.requestId;
  copy.userId = value.userId;
  copy.taskId = value.taskId;
  copy.stepId = value.stepId;
  copy.operationId = value.operationId;
  copy.toolId = value.toolId;
  copy.toolIdentityVersion = value.toolIdentityVersion;
  copy.providerId = value.providerId;
  copy.schemaDigest = value.schemaDigest;
  copy.argumentsDigest = value.argumentsDigest;
  copy.riskLevel = value.riskLevel;
  copy.sideEffect = value.sideEffect;
  copy.estimatedCostMicros = value.estimatedCostMicros;
  copy.requestedAt = value.requestedAt;
  copy.expiresAt = value.expiresAt;
  copy.expiresAtMs = value.expiresAtMs;
  return copy;
}

function copyToolInvocation(value: ToolInvocation): ToolInvocation {
  const copy = new ToolInvocation();
  copy.schemaVersion = value.schemaVersion;
  copy.contractType = value.contractType;
  copy.invocationId = value.invocationId;
  copy.taskId = value.taskId;
  copy.stepId = value.stepId;
  copy.operationId = value.operationId;
  copy.attemptId = value.attemptId;
  copy.toolId = value.toolId;
  copy.toolIdentityVersion = value.toolIdentityVersion;
  copy.schemaDigest = value.schemaDigest;
  copy.argumentsJson = value.argumentsJson;
  copy.argumentsDigest = value.argumentsDigest;
  if (value.idempotencyKey !== undefined) copy.idempotencyKey = value.idempotencyKey;
  copy.authorizationGrantId = value.authorizationGrantId;
  copy.timeoutMs = value.timeoutMs;
  copy.createdAt = value.createdAt;
  return copy;
}

export function copyToolOutcome(value: ToolOutcome): ToolOutcome {
  const copy = new ToolOutcome();
  copy.schemaVersion = value.schemaVersion;
  copy.contractType = value.contractType;
  copy.invocationId = value.invocationId;
  copy.status = value.status;
  if (value.resultJson !== undefined) copy.resultJson = value.resultJson;
  if (value.resultDigest !== undefined) copy.resultDigest = value.resultDigest;
  if (value.errorClass !== undefined) copy.errorClass = value.errorClass;
  if (value.errorCode !== undefined) copy.errorCode = value.errorCode;
  if (value.errorMessage !== undefined) copy.errorMessage = value.errorMessage;
  if (value.providerReceipt !== undefined) copy.providerReceipt = value.providerReceipt;
  copy.startedAt = value.startedAt;
  copy.finishedAt = value.finishedAt;
  return copy;
}
