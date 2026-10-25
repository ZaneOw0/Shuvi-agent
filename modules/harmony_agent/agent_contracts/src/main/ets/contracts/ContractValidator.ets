import { ArtifactManifest } from './ArtifactContracts';
import {
  AGENT_CONTRACT_SCHEMA_VERSION,
  CONTRACT_TYPE_ARTIFACT_MANIFEST,
  CONTRACT_TYPE_AGENT_RUNTIME_EVENT,
  CONTRACT_TYPE_AGENT_TASK_SNAPSHOT,
  CONTRACT_TYPE_AUTHORIZATION_DECISION,
  CONTRACT_TYPE_AUTHORIZATION_GRANT,
  CONTRACT_TYPE_COMMAND_RECEIPT,
  CONTRACT_TYPE_CLARIFICATION_REQUEST,
  CONTRACT_TYPE_CLARIFICATION_RESPONSE,
  CONTRACT_TYPE_POLICY_REQUEST,
  CONTRACT_TYPE_RECONCILIATION_REPORT,
  CONTRACT_TYPE_ROUTER_DECISION,
  CONTRACT_TYPE_ROUTER_REQUEST,
  CONTRACT_TYPE_TASK_CONTROL_COMMAND,
  CONTRACT_TYPE_TASK_ENVELOPE,
  CONTRACT_TYPE_TASK_HANDLE,
  CONTRACT_TYPE_TASK_SUBMISSION,
  CONTRACT_TYPE_TOOL_DESCRIPTOR,
  CONTRACT_TYPE_TOOL_INVOCATION,
  CONTRACT_TYPE_TOOL_OUTCOME,
  CONTRACT_TYPE_TRACE_EVENT,
  CONTRACT_TYPE_WORKFLOW_GRAPH
} from './Constants';
import { ContractValidationResult } from './Common';
import {
  ArtifactApprovalStatus,
  ArtifactKind,
  ArtifactLifecycleStatus,
  AuthorizationDecisionType
} from './Enums';
import { AuthorizationDecision, AuthorizationGrant, PolicyRequest } from './PolicyContracts';
import { RouterDecision, RouterRequest } from './RoutingContracts';
import {
  AgentRuntimeEvent,
  AgentTaskSnapshot,
  ClarificationRequest,
  ClarificationResponse,
  CommandReceipt,
  ReconciliationReport,
  TaskControlCommand,
  TaskHandle,
  TaskSubmission
} from './RuntimeContracts';
import { TaskEnvelope, ExecutionBudget } from './TaskContracts';
import { ToolDescriptor, ToolInvocation, ToolOutcome } from './ToolContracts';
import { TraceEvent } from './TraceContracts';
import { WorkflowGraph, WorkflowStep } from './WorkflowContracts';

export class ContractValidator {
  private static requireText(result: ContractValidationResult, value: string, path: string): void {
    if (value.trim().length === 0) {
      result.issues.push(path + ' must not be empty');
    }
  }

  private static requireSha256Digest(result: ContractValidationResult, value: string, path: string): void {
    ContractValidator.requireText(result, value, path);
    if (value.trim().length > 0 && !/^sha256:[0-9a-fA-F]{64}$/.test(value)) {
      result.issues.push(path + ' must be a full sha256 digest');
    }
  }

  private static requireSourceCommit(result: ContractValidationResult, value: string): void {
    ContractValidator.requireText(result, value, 'sourceCommit');
    if (value.trim().length > 0 && !/^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$/.test(value)) {
      result.issues.push('sourceCommit must be a full 40 or 64 character hexadecimal commit id');
    }
  }

  private static requireIsoTimestamp(result: ContractValidationResult, value: string, path: string): void {
    ContractValidator.requireText(result, value, path);
    const pattern: RegExp = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$/;
    if (value.trim().length > 0 && !pattern.test(value)) {
      result.issues.push(path + ' must be an ISO-8601 timestamp with an explicit time zone');
    }
  }

  private static requireJsonObject(result: ContractValidationResult, value: string, path: string): void {
    ContractValidator.requireText(result, value, path);
    const trimmed: string = value.trim();
    if (trimmed.length === 0) {
      return;
    }
    if (!trimmed.startsWith('{') || !trimmed.endsWith('}')) {
      result.issues.push(path + ' must encode a JSON object');
      return;
    }
    try {
      JSON.parse(trimmed);
    } catch (error) {
      result.issues.push(path + ' must encode valid JSON');
    }
  }

  private static requireStringList(result: ContractValidationResult, values: string[], path: string,
    requireEntries: boolean): void {
    if (requireEntries && values.length === 0) {
      result.issues.push(path + ' must not be empty for a released artifact');
    }
    for (let i: number = 0; i < values.length; i++) {
      ContractValidator.requireText(result, values[i], path + '[' + i.toString() + ']');
      for (let j: number = 0; j < i; j++) {
        if (values[i] === values[j]) {
          result.issues.push(path + ' must not contain duplicate entries');
          break;
        }
      }
    }
  }

  private static isEmptyJsonObject(value: string): boolean {
    return value.replace(/\s/g, '') === '{}';
  }

  private static requireNonNegative(result: ContractValidationResult, value: number, path: string): void {
    if (!Number.isFinite(value) || value < 0) {
      result.issues.push(path + ' must be a finite non-negative number');
    }
  }

  private static requireCount(result: ContractValidationResult, value: number, path: string): void {
    if (!Number.isFinite(value) || value < 0 || Math.floor(value) !== value) {
      result.issues.push(path + ' must be a finite non-negative integer');
    }
  }

  private static requirePositiveCount(result: ContractValidationResult, value: number, path: string): void {
    if (!Number.isFinite(value) || value <= 0 || Math.floor(value) !== value) {
      result.issues.push(path + ' must be a finite positive integer');
    }
  }

  private static finish(result: ContractValidationResult): ContractValidationResult {
    result.valid = result.issues.length === 0;
    return result;
  }

  private static validateHeader(result: ContractValidationResult, schemaVersion: string, contractType: string,
    expectedContractType: string): void {
    if (schemaVersion !== AGENT_CONTRACT_SCHEMA_VERSION) {
      result.issues.push('schemaVersion is not supported');
    }
    if (contractType !== expectedContractType) {
      result.issues.push('contractType must be ' + expectedContractType);
    }
  }

  static validateExecutionBudget(value: ExecutionBudget): ContractValidationResult {
    const result: ContractValidationResult = new ContractValidationResult();
    ContractValidator.appendBudgetIssues(result, value, 'executionBudget');
    return ContractValidator.finish(result);
  }

  static validateTaskSubmission(value: TaskSubmission): ContractValidationResult {
    const result: ContractValidationResult = new ContractValidationResult();
    ContractValidator.validateHeader(result, value.schemaVersion, value.contractType,
      CONTRACT_TYPE_TASK_SUBMISSION);
    ContractValidator.requireText(result, value.requestId, 'requestId');
    ContractValidator.requireText(result, value.userId, 'userId');
    ContractValidator.requireText(result, value.userIntent, 'userIntent');
    ContractValidator.requireText(result, value.locale, 'locale');
    ContractValidator.requireText(result, value.timeZone, 'timeZone');
    ContractValidator.requireText(result, value.referenceTime, 'referenceTime');
    ContractValidator.requireText(result, value.submittedAt, 'submittedAt');
    ContractValidator.appendBudgetIssues(result, value.requestedBudget, 'requestedBudget');
    for (let i: number = 0; i < value.inputRefs.length; i++) {
      ContractValidator.requireText(result, value.inputRefs[i].refId,
        'inputRefs[' + i.toString() + '].refId');
      ContractValidator.requireText(result, value.inputRefs[i].digest,
        'inputRefs[' + i.toString() + '].digest');
    }
    return ContractValidator.finish(result);
  }

  static validateTaskHandle(value: TaskHandle): ContractValidationResult {
    const result: ContractValidationResult = new ContractValidationResult();
    ContractValidator.validateHeader(result, value.schemaVersion, value.contractType, CONTRACT_TYPE_TASK_HANDLE);
    ContractValidator.requireText(result, value.requestId, 'requestId');
    ContractValidator.requireText(result, value.taskId, 'taskId');
    ContractValidator.requireText(result, value.sessionId, 'sessionId');
    ContractValidator.requireText(result, value.acceptedAt, 'acceptedAt');
    ContractValidator.requireCount(result, value.snapshotVersion, 'snapshotVersion');
    return ContractValidator.finish(result);
  }

  static validateTaskEnvelope(value: TaskEnvelope): ContractValidationResult {
    const result: ContractValidationResult = new ContractValidationResult();
    ContractValidator.validateHeader(result, value.schemaVersion, value.contractType,
      CONTRACT_TYPE_TASK_ENVELOPE);
    ContractValidator.requireText(result, value.requestId, 'requestId');
    ContractValidator.requireText(result, value.taskId, 'taskId');
    ContractValidator.requireText(result, value.sessionId, 'sessionId');
    ContractValidator.requireText(result, value.userId, 'userId');
    ContractValidator.requireText(result, value.userIntent, 'userIntent');
    ContractValidator.requireText(result, value.locale, 'locale');
    ContractValidator.requireText(result, value.timeZone, 'timeZone');
    ContractValidator.requireText(result, value.referenceTime, 'referenceTime');
    ContractValidator.requireText(result, value.createdAt, 'createdAt');
    ContractValidator.appendBudgetIssues(result, value.executionBudget, 'executionBudget');
    for (let i: number = 0; i < value.inputRefs.length; i++) {
      ContractValidator.requireText(result, value.inputRefs[i].refId, 'inputRefs[' + i.toString() + '].refId');
      ContractValidator.requireText(result, value.inputRefs[i].digest, 'inputRefs[' + i.toString() + '].digest');
    }
    return ContractValidator.finish(result);
  }

  static validateWorkflowGraphShape(value: WorkflowGraph): ContractValidationResult {
    const result: ContractValidationResult = new ContractValidationResult();
    ContractValidator.validateHeader(result, value.schemaVersion, value.contractType,
      CONTRACT_TYPE_WORKFLOW_GRAPH);
    ContractValidator.requireText(result, value.workflowId, 'workflowId');
    ContractValidator.requireText(result, value.taskId, 'taskId');
    ContractValidator.requireText(result, value.workflowVersion, 'workflowVersion');
    ContractValidator.requireText(result, value.createdAt, 'createdAt');
    if (value.steps.length === 0) {
      result.issues.push('steps must not be empty');
    }
    for (let i: number = 0; i < value.steps.length; i++) {
      ContractValidator.appendStepIssues(result, value.steps[i], i);
    }
    return ContractValidator.finish(result);
  }

  static validateToolDescriptor(value: ToolDescriptor): ContractValidationResult {
    const result: ContractValidationResult = new ContractValidationResult();
    ContractValidator.validateHeader(result, value.schemaVersion, value.contractType,
      CONTRACT_TYPE_TOOL_DESCRIPTOR);
    ContractValidator.requireText(result, value.toolId, 'toolId');
    ContractValidator.requireText(result, value.providerId, 'providerId');
    ContractValidator.requireText(result, value.capabilityName, 'capabilityName');
    ContractValidator.requireText(result, value.capabilityVersion, 'capabilityVersion');
    ContractValidator.requireText(result, value.toolIdentityVersion, 'toolIdentityVersion');
    ContractValidator.requireText(result, value.inputSchemaJson, 'inputSchemaJson');
    ContractValidator.requireText(result, value.schemaDigest, 'schemaDigest');
    ContractValidator.requireText(result, value.adapterRef, 'adapterRef');
    return ContractValidator.finish(result);
  }

  static validateAuthorizationGrant(value: AuthorizationGrant): ContractValidationResult {
    const result: ContractValidationResult = new ContractValidationResult();
    ContractValidator.validateHeader(result, value.schemaVersion, value.contractType,
      CONTRACT_TYPE_AUTHORIZATION_GRANT);
    ContractValidator.requireText(result, value.grantId, 'grantId');
    ContractValidator.requireText(result, value.policyRequestId, 'policyRequestId');
    ContractValidator.requireText(result, value.decisionCommandId, 'decisionCommandId');
    ContractValidator.requireText(result, value.userId, 'userId');
    ContractValidator.requireText(result, value.taskId, 'taskId');
    ContractValidator.requireText(result, value.stepId, 'stepId');
    ContractValidator.requireText(result, value.operationId, 'operationId');
    ContractValidator.requireText(result, value.toolId, 'toolId');
    ContractValidator.requireText(result, value.toolIdentityVersion, 'toolIdentityVersion');
    ContractValidator.requireText(result, value.schemaDigest, 'schemaDigest');
    ContractValidator.requireText(result, value.argumentsDigest, 'argumentsDigest');
    ContractValidator.requireText(result, value.budgetReservationId, 'budgetReservationId');
    ContractValidator.requireText(result, value.policyVersion, 'policyVersion');
    ContractValidator.requireText(result, value.issuedAt, 'issuedAt');
    ContractValidator.requireText(result, value.expiresAt, 'expiresAt');
    ContractValidator.requireCount(result, value.issuedAtMs, 'issuedAtMs');
    ContractValidator.requirePositiveCount(result, value.expiresAtMs, 'expiresAtMs');
    if (value.expiresAtMs <= value.issuedAtMs) {
      result.issues.push('expiresAtMs must be greater than issuedAtMs');
    }
    return ContractValidator.finish(result);
  }

  static validateAuthorizationDecision(value: AuthorizationDecision): ContractValidationResult {
    const result: ContractValidationResult = new ContractValidationResult();
    ContractValidator.validateHeader(result, value.schemaVersion, value.contractType,
      CONTRACT_TYPE_AUTHORIZATION_DECISION);
    ContractValidator.requireText(result, value.commandId, 'commandId');
    ContractValidator.requireText(result, value.policyRequestId, 'policyRequestId');
    ContractValidator.requireText(result, value.userId, 'userId');
    ContractValidator.requireText(result, value.taskId, 'taskId');
    ContractValidator.requireText(result, value.decidedAt, 'decidedAt');
    ContractValidator.requireCount(result, value.decidedAtMs, 'decidedAtMs');
    if (value.decision === AuthorizationDecisionType.DENIED) {
      const denialReasonCode: string | undefined = value.denialReasonCode;
      if (denialReasonCode === undefined || denialReasonCode.trim().length === 0) {
        result.issues.push('denialReasonCode must not be empty when decision is denied');
      }
    }
    return ContractValidator.finish(result);
  }

  static validateArtifactManifest(value: ArtifactManifest): ContractValidationResult {
    const result: ContractValidationResult = new ContractValidationResult();
    ContractValidator.validateHeader(result, value.schemaVersion, value.contractType,
      CONTRACT_TYPE_ARTIFACT_MANIFEST);
    ContractValidator.requireText(result, value.artifactId, 'artifactId');
    if (value.artifactKind !== ArtifactKind.CHECKPOINT && value.artifactKind !== ArtifactKind.POLICY &&
      value.artifactKind !== ArtifactKind.WORKFLOW) {
      result.issues.push('artifactKind is not supported');
    }
    ContractValidator.requireText(result, value.algorithm, 'algorithm');
    ContractValidator.requireText(result, value.artifactVersion, 'artifactVersion');
    ContractValidator.requireSourceCommit(result, value.sourceCommit);
    ContractValidator.requireText(result, value.sourceLicense, 'sourceLicense');
    ContractValidator.requireText(result, value.featureSchemaVersion, 'featureSchemaVersion');
    ContractValidator.requireSha256Digest(result, value.artifactDigest, 'artifactDigest');
    if (value.checkpointDigest.trim().length > 0) {
      ContractValidator.requireSha256Digest(result, value.checkpointDigest, 'checkpointDigest');
      if (value.checkpointDigest !== value.artifactDigest) {
        result.issues.push('checkpointDigest must match artifactDigest when present');
      }
    }
    ContractValidator.requireJsonObject(result, value.modelAndProviderSnapshotJson,
      'modelAndProviderSnapshotJson');
    ContractValidator.requireJsonObject(result, value.paperReproductionResultsJson,
      'paperReproductionResultsJson');
    ContractValidator.requireJsonObject(result, value.portParityResultsJson, 'portParityResultsJson');
    ContractValidator.requireJsonObject(result, value.harmonyAgentBenchResultsJson,
      'harmonyAgentBenchResultsJson');
    if (value.lifecycleStatus !== ArtifactLifecycleStatus.DISABLED &&
      value.lifecycleStatus !== ArtifactLifecycleStatus.SHADOW &&
      value.lifecycleStatus !== ArtifactLifecycleStatus.CANARY &&
      value.lifecycleStatus !== ArtifactLifecycleStatus.ACTIVE &&
      value.lifecycleStatus !== ArtifactLifecycleStatus.ROLLED_BACK) {
      result.issues.push('lifecycleStatus is not supported');
    }
    if (value.approvalStatus !== ArtifactApprovalStatus.UNREVIEWED &&
      value.approvalStatus !== ArtifactApprovalStatus.APPROVED &&
      value.approvalStatus !== ArtifactApprovalStatus.REJECTED) {
      result.issues.push('approvalStatus is not supported');
    }
    const released: boolean = value.lifecycleStatus !== ArtifactLifecycleStatus.DISABLED;
    ContractValidator.requireStringList(result, value.trainingDataLineage, 'trainingDataLineage', released);
    ContractValidator.requireStringList(result, value.runtimeCompatibility, 'runtimeCompatibility', released);
    if (released) {
      if (ContractValidator.isEmptyJsonObject(value.modelAndProviderSnapshotJson)) {
        result.issues.push('modelAndProviderSnapshotJson must contain a frozen snapshot for a released artifact');
      }
      if (ContractValidator.isEmptyJsonObject(value.paperReproductionResultsJson)) {
        result.issues.push('paperReproductionResultsJson must contain separate reproduction results');
      }
      if (ContractValidator.isEmptyJsonObject(value.portParityResultsJson)) {
        result.issues.push('portParityResultsJson must contain parity results for a released artifact');
      }
      if (ContractValidator.isEmptyJsonObject(value.harmonyAgentBenchResultsJson)) {
        result.issues.push('harmonyAgentBenchResultsJson must contain adaptation results');
      }
    }
    if (value.approvalStatus === ArtifactApprovalStatus.APPROVED) {
      ContractValidator.requireText(result, value.approvedBy, 'approvedBy');
      const approvedAt: string | undefined = value.approvedAt;
      if (approvedAt === undefined) {
        result.issues.push('approvedAt must be present for an approved artifact');
      } else {
        ContractValidator.requireIsoTimestamp(result, approvedAt, 'approvedAt');
      }
    }
    const signedRelease: boolean = value.lifecycleStatus === ArtifactLifecycleStatus.CANARY ||
      value.lifecycleStatus === ArtifactLifecycleStatus.ACTIVE ||
      value.lifecycleStatus === ArtifactLifecycleStatus.ROLLED_BACK;
    const hasSignatureMetadata: boolean = value.signedManifestDigest.trim().length > 0 ||
      value.signatureAlgorithm.trim().length > 0 || value.signingKeyId.trim().length > 0 ||
      value.signatureBase64.trim().length > 0 || value.signedAt !== undefined;
    if (signedRelease || hasSignatureMetadata) {
      if (value.approvalStatus !== ArtifactApprovalStatus.APPROVED) {
        result.issues.push('approvalStatus must be approved for signed, canary, active, or rolledBack artifacts');
      }
      ContractValidator.requireSha256Digest(result, value.signedManifestDigest, 'signedManifestDigest');
      ContractValidator.requireText(result, value.signatureAlgorithm, 'signatureAlgorithm');
      ContractValidator.requireText(result, value.signingKeyId, 'signingKeyId');
      ContractValidator.requireText(result, value.signatureBase64, 'signatureBase64');
      if (value.signatureBase64.trim().length > 0 &&
        (value.signatureBase64.length % 4 !== 0 || !/^[A-Za-z0-9+/]+={0,2}$/.test(value.signatureBase64))) {
        result.issues.push('signatureBase64 must use base64 encoding');
      }
      const signedAt: string | undefined = value.signedAt;
      if (signedAt === undefined) {
        result.issues.push('signedAt must be present for canary, active, or rolledBack artifacts');
      } else {
        ContractValidator.requireIsoTimestamp(result, signedAt, 'signedAt');
      }
    }
    const rollbackTargetDigest: string | undefined = value.rollbackTargetDigest;
    if (rollbackTargetDigest !== undefined) {
      ContractValidator.requireSha256Digest(result, rollbackTargetDigest, 'rollbackTargetDigest');
    }
    if (value.lifecycleStatus === ArtifactLifecycleStatus.ROLLED_BACK) {
      if (rollbackTargetDigest === undefined) {
        result.issues.push('rollbackTargetDigest must be present for a rolledBack artifact');
      } else {
        if (rollbackTargetDigest === value.artifactDigest) {
          result.issues.push('rollbackTargetDigest must identify a different artifact');
        }
      }
    }
    return ContractValidator.finish(result);
  }

  static validateArtifactLifecycleTransition(previous: ArtifactLifecycleStatus,
    next: ArtifactLifecycleStatus): ContractValidationResult {
    const result: ContractValidationResult = new ContractValidationResult();
    if (previous === next) {
      return ContractValidator.finish(result);
    }
    let allowed: boolean = false;
    if (previous === ArtifactLifecycleStatus.DISABLED) {
      allowed = next === ArtifactLifecycleStatus.SHADOW;
    } else if (previous === ArtifactLifecycleStatus.SHADOW) {
      allowed = next === ArtifactLifecycleStatus.CANARY || next === ArtifactLifecycleStatus.DISABLED;
    } else if (previous === ArtifactLifecycleStatus.CANARY) {
      allowed = next === ArtifactLifecycleStatus.ACTIVE || next === ArtifactLifecycleStatus.SHADOW ||
        next === ArtifactLifecycleStatus.ROLLED_BACK;
    } else if (previous === ArtifactLifecycleStatus.ACTIVE) {
      allowed = next === ArtifactLifecycleStatus.ROLLED_BACK;
    } else if (previous === ArtifactLifecycleStatus.ROLLED_BACK) {
      allowed = next === ArtifactLifecycleStatus.DISABLED;
    }
    if (!allowed) {
      result.issues.push('artifact lifecycle transition is not allowed');
    }
    return ContractValidator.finish(result);
  }

  static validateRouterRequest(value: RouterRequest): ContractValidationResult {
    const result: ContractValidationResult = new ContractValidationResult();
    ContractValidator.validateHeader(result, value.schemaVersion, value.contractType,
      CONTRACT_TYPE_ROUTER_REQUEST);
    ContractValidator.requireText(result, value.requestId, 'requestId');
    ContractValidator.requireText(result, value.taskId, 'taskId');
    ContractValidator.requireText(result, value.featuresJson, 'featuresJson');
    ContractValidator.requireText(result, value.createdAt, 'createdAt');
    if (value.candidates.length === 0) {
      result.issues.push('candidates must not be empty');
    }
    for (let i: number = 0; i < value.candidates.length; i++) {
      ContractValidator.requireText(result, value.candidates[i].candidateId,
        'candidates[' + i.toString() + '].candidateId');
      ContractValidator.requireText(result, value.candidates[i].metadataJson,
        'candidates[' + i.toString() + '].metadataJson');
    }
    ContractValidator.appendBudgetIssues(result, value.remainingBudget, 'remainingBudget');
    return ContractValidator.finish(result);
  }

  static validateRouterDecision(value: RouterDecision): ContractValidationResult {
    const result: ContractValidationResult = new ContractValidationResult();
    ContractValidator.validateHeader(result, value.schemaVersion, value.contractType,
      CONTRACT_TYPE_ROUTER_DECISION);
    ContractValidator.requireText(result, value.decisionId, 'decisionId');
    ContractValidator.requireText(result, value.requestId, 'requestId');
    ContractValidator.requireText(result, value.policyVersion, 'policyVersion');
    ContractValidator.requireText(result, value.inputFeatureDigest, 'inputFeatureDigest');
    ContractValidator.requireText(result, value.createdAt, 'createdAt');
    if (value.selectedCandidateIds.length === 0) {
      result.issues.push('selectedCandidateIds must not be empty');
    }
    if (!Number.isFinite(value.confidence) || value.confidence < 0 || value.confidence > 1) {
      result.issues.push('confidence must be between 0 and 1');
    }
    ContractValidator.requireNonNegative(result, value.latencyMs, 'latencyMs');
    ContractValidator.requireCount(result, value.estimatedCostMicros, 'estimatedCostMicros');
    return ContractValidator.finish(result);
  }

  static validateToolInvocation(value: ToolInvocation): ContractValidationResult {
    const result: ContractValidationResult = new ContractValidationResult();
    ContractValidator.validateHeader(result, value.schemaVersion, value.contractType,
      CONTRACT_TYPE_TOOL_INVOCATION);
    ContractValidator.requireText(result, value.invocationId, 'invocationId');
    ContractValidator.requireText(result, value.taskId, 'taskId');
    ContractValidator.requireText(result, value.stepId, 'stepId');
    ContractValidator.requireText(result, value.operationId, 'operationId');
    ContractValidator.requireText(result, value.attemptId, 'attemptId');
    ContractValidator.requireText(result, value.toolId, 'toolId');
    ContractValidator.requireText(result, value.toolIdentityVersion, 'toolIdentityVersion');
    ContractValidator.requireText(result, value.schemaDigest, 'schemaDigest');
    ContractValidator.requireText(result, value.argumentsJson, 'argumentsJson');
    ContractValidator.requireText(result, value.argumentsDigest, 'argumentsDigest');
    ContractValidator.requireText(result, value.authorizationGrantId, 'authorizationGrantId');
    ContractValidator.requireText(result, value.createdAt, 'createdAt');
    ContractValidator.requireNonNegative(result, value.timeoutMs, 'timeoutMs');
    return ContractValidator.finish(result);
  }

  static validateToolOutcome(value: ToolOutcome): ContractValidationResult {
    const result: ContractValidationResult = new ContractValidationResult();
    ContractValidator.validateHeader(result, value.schemaVersion, value.contractType,
      CONTRACT_TYPE_TOOL_OUTCOME);
    ContractValidator.requireText(result, value.invocationId, 'invocationId');
    ContractValidator.requireText(result, value.startedAt, 'startedAt');
    ContractValidator.requireText(result, value.finishedAt, 'finishedAt');
    return ContractValidator.finish(result);
  }

  static validatePolicyRequest(value: PolicyRequest): ContractValidationResult {
    const result: ContractValidationResult = new ContractValidationResult();
    ContractValidator.validateHeader(result, value.schemaVersion, value.contractType,
      CONTRACT_TYPE_POLICY_REQUEST);
    ContractValidator.requireText(result, value.requestId, 'requestId');
    ContractValidator.requireText(result, value.userId, 'userId');
    ContractValidator.requireText(result, value.taskId, 'taskId');
    ContractValidator.requireText(result, value.stepId, 'stepId');
    ContractValidator.requireText(result, value.operationId, 'operationId');
    ContractValidator.requireText(result, value.toolId, 'toolId');
    ContractValidator.requireText(result, value.toolIdentityVersion, 'toolIdentityVersion');
    ContractValidator.requireText(result, value.providerId, 'providerId');
    ContractValidator.requireText(result, value.schemaDigest, 'schemaDigest');
    ContractValidator.requireText(result, value.argumentsDigest, 'argumentsDigest');
    ContractValidator.requireText(result, value.requestedAt, 'requestedAt');
    ContractValidator.requireText(result, value.expiresAt, 'expiresAt');
    ContractValidator.requirePositiveCount(result, value.expiresAtMs, 'expiresAtMs');
    ContractValidator.requireCount(result, value.estimatedCostMicros, 'estimatedCostMicros');
    return ContractValidator.finish(result);
  }

  static validateTaskControlCommand(value: TaskControlCommand): ContractValidationResult {
    const result: ContractValidationResult = new ContractValidationResult();
    ContractValidator.validateHeader(result, value.schemaVersion, value.contractType,
      CONTRACT_TYPE_TASK_CONTROL_COMMAND);
    ContractValidator.requireText(result, value.commandId, 'commandId');
    ContractValidator.requireText(result, value.taskId, 'taskId');
    ContractValidator.requireText(result, value.reasonCode, 'reasonCode');
    ContractValidator.requireText(result, value.requestedAt, 'requestedAt');
    return ContractValidator.finish(result);
  }

  static validateCommandReceipt(value: CommandReceipt): ContractValidationResult {
    const result: ContractValidationResult = new ContractValidationResult();
    ContractValidator.validateHeader(result, value.schemaVersion, value.contractType,
      CONTRACT_TYPE_COMMAND_RECEIPT);
    ContractValidator.requireText(result, value.commandId, 'commandId');
    ContractValidator.requireText(result, value.taskId, 'taskId');
    ContractValidator.requireCount(result, value.snapshotVersion, 'snapshotVersion');
    if (!value.accepted) {
      const rejectionCode: string | undefined = value.rejectionCode;
      if (rejectionCode === undefined || rejectionCode.trim().length === 0) {
        result.issues.push('rejectionCode must not be empty when command is rejected');
      }
    }
    return ContractValidator.finish(result);
  }

  static validateAgentRuntimeEvent(value: AgentRuntimeEvent): ContractValidationResult {
    const result: ContractValidationResult = new ContractValidationResult();
    ContractValidator.validateHeader(result, value.schemaVersion, value.contractType,
      CONTRACT_TYPE_AGENT_RUNTIME_EVENT);
    ContractValidator.requireText(result, value.eventId, 'eventId');
    ContractValidator.requireText(result, value.taskId, 'taskId');
    ContractValidator.requirePositiveCount(result, value.sequence, 'sequence');
    ContractValidator.requirePositiveCount(result, value.snapshotVersion, 'snapshotVersion');
    ContractValidator.requireText(result, value.timestamp, 'timestamp');
    ContractValidator.requireText(result, value.payloadJson, 'payloadJson');
    return ContractValidator.finish(result);
  }

  static validateAgentTaskSnapshot(value: AgentTaskSnapshot): ContractValidationResult {
    const result: ContractValidationResult = new ContractValidationResult();
    ContractValidator.validateHeader(result, value.schemaVersion, value.contractType,
      CONTRACT_TYPE_AGENT_TASK_SNAPSHOT);
    ContractValidator.requireText(result, value.requestId, 'requestId');
    ContractValidator.requireText(result, value.taskId, 'taskId');
    ContractValidator.requireText(result, value.sessionId, 'sessionId');
    ContractValidator.requirePositiveCount(result, value.snapshotVersion, 'snapshotVersion');
    ContractValidator.requireCount(result, value.lastEventSequence, 'lastEventSequence');
    ContractValidator.requireText(result, value.resultJson, 'resultJson');
    ContractValidator.requireText(result, value.updatedAt, 'updatedAt');
    return ContractValidator.finish(result);
  }

  static validateReconciliationReport(value: ReconciliationReport): ContractValidationResult {
    const result: ContractValidationResult = new ContractValidationResult();
    ContractValidator.validateHeader(result, value.schemaVersion, value.contractType,
      CONTRACT_TYPE_RECONCILIATION_REPORT);
    ContractValidator.requireText(result, value.commandId, 'commandId');
    ContractValidator.requireText(result, value.taskId, 'taskId');
    ContractValidator.requireText(result, value.stepId, 'stepId');
    ContractValidator.requireText(result, value.operationId, 'operationId');
    ContractValidator.requireText(result, value.evidenceDigest, 'evidenceDigest');
    ContractValidator.requireText(result, value.reportedAt, 'reportedAt');
    return ContractValidator.finish(result);
  }

  static validateClarificationRequest(value: ClarificationRequest): ContractValidationResult {
    const result: ContractValidationResult = new ContractValidationResult();
    ContractValidator.validateHeader(result, value.schemaVersion, value.contractType,
      CONTRACT_TYPE_CLARIFICATION_REQUEST);
    ContractValidator.requireText(result, value.clarificationId, 'clarificationId');
    ContractValidator.requireText(result, value.taskId, 'taskId');
    ContractValidator.requireText(result, value.questionCode, 'questionCode');
    ContractValidator.requireText(result, value.prompt, 'prompt');
    ContractValidator.requireText(result, value.responseSchemaJson, 'responseSchemaJson');
    ContractValidator.requireText(result, value.requestedAt, 'requestedAt');
    ContractValidator.requireText(result, value.expiresAt, 'expiresAt');
    ContractValidator.requirePositiveCount(result, value.expiresAtMs, 'expiresAtMs');
    return ContractValidator.finish(result);
  }

  static validateClarificationResponse(value: ClarificationResponse): ContractValidationResult {
    const result: ContractValidationResult = new ContractValidationResult();
    ContractValidator.validateHeader(result, value.schemaVersion, value.contractType,
      CONTRACT_TYPE_CLARIFICATION_RESPONSE);
    ContractValidator.requireText(result, value.commandId, 'commandId');
    ContractValidator.requireText(result, value.clarificationId, 'clarificationId');
    ContractValidator.requireText(result, value.taskId, 'taskId');
    ContractValidator.requireText(result, value.answerJson, 'answerJson');
    ContractValidator.requireText(result, value.respondedAt, 'respondedAt');
    ContractValidator.requireCount(result, value.respondedAtMs, 'respondedAtMs');
    return ContractValidator.finish(result);
  }

  static validateTraceEvent(value: TraceEvent): ContractValidationResult {
    const result: ContractValidationResult = new ContractValidationResult();
    ContractValidator.validateHeader(result, value.schemaVersion, value.contractType,
      CONTRACT_TYPE_TRACE_EVENT);
    ContractValidator.requireText(result, value.eventId, 'eventId');
    ContractValidator.requireText(result, value.taskId, 'taskId');
    ContractValidator.requireText(result, value.eventType, 'eventType');
    ContractValidator.requireText(result, value.timestamp, 'timestamp');
    ContractValidator.requireText(result, value.component, 'component');
    ContractValidator.requireText(result, value.componentVersion, 'componentVersion');
    ContractValidator.requireText(result, value.privacyRedactionVersion, 'privacyRedactionVersion');
    ContractValidator.requireNonNegative(result, value.latencyMs, 'latencyMs');
    ContractValidator.requireCount(result, value.inputTokens, 'inputTokens');
    ContractValidator.requireCount(result, value.outputTokens, 'outputTokens');
    ContractValidator.requireCount(result, value.monetaryCostMicros, 'monetaryCostMicros');
    return ContractValidator.finish(result);
  }

  private static appendBudgetIssues(result: ContractValidationResult, value: ExecutionBudget,
    path: string): void {
    ContractValidator.requireNonNegative(result, value.maxWallTimeMs, path + '.maxWallTimeMs');
    ContractValidator.requireCount(result, value.maxInputTokens, path + '.maxInputTokens');
    ContractValidator.requireCount(result, value.maxOutputTokens, path + '.maxOutputTokens');
    ContractValidator.requireCount(result, value.maxMonetaryCostMicros,
      path + '.maxMonetaryCostMicros');
    ContractValidator.requireCount(result, value.maxToolCalls, path + '.maxToolCalls');
    ContractValidator.requireCount(result, value.maxAgentActivations, path + '.maxAgentActivations');
    ContractValidator.requireCount(result, value.maxRetries, path + '.maxRetries');
    ContractValidator.requireCount(result, value.maxReplans, path + '.maxReplans');
  }

  private static appendStepIssues(result: ContractValidationResult, value: WorkflowStep, index: number): void {
    const path: string = 'steps[' + index.toString() + ']';
    ContractValidator.requireText(result, value.stepId, path + '.stepId');
    ContractValidator.requireText(result, value.goal, path + '.goal');
    ContractValidator.requireText(result, value.expectedOutputSchemaJson, path + '.expectedOutputSchemaJson');
    ContractValidator.requireText(result, value.retryPolicyRef, path + '.retryPolicyRef');
    ContractValidator.requireText(result, value.verificationPolicyRef, path + '.verificationPolicyRef');
    ContractValidator.requireNonNegative(result, value.timeoutMs, path + '.timeoutMs');
  }
}
