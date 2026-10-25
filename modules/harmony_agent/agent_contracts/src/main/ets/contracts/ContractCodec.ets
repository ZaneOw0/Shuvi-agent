import { ArtifactManifest } from './ArtifactContracts';
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
import { TaskEnvelope } from './TaskContracts';
import { ToolDescriptor, ToolInvocation, ToolOutcome } from './ToolContracts';
import { TraceEvent } from './TraceContracts';
import { WorkflowGraph } from './WorkflowContracts';

export class ContractCodec {
  static stringify(value: Object): string {
    return JSON.stringify(value);
  }

  static parseTaskEnvelope(json: string): TaskEnvelope {
    const parsed: TaskEnvelope = JSON.parse(json) as TaskEnvelope;
    const value: TaskEnvelope = new TaskEnvelope();
    if (parsed.schemaVersion !== undefined) value.schemaVersion = parsed.schemaVersion;
    if (parsed.contractType !== undefined) value.contractType = parsed.contractType;
    if (parsed.requestId !== undefined) value.requestId = parsed.requestId;
    if (parsed.conversationId !== undefined) value.conversationId = parsed.conversationId;
    if (parsed.taskId !== undefined) value.taskId = parsed.taskId;
    if (parsed.sessionId !== undefined) value.sessionId = parsed.sessionId;
    if (parsed.userId !== undefined) value.userId = parsed.userId;
    if (parsed.userIntent !== undefined) value.userIntent = parsed.userIntent;
    if (parsed.locale !== undefined) value.locale = parsed.locale;
    if (parsed.timeZone !== undefined) value.timeZone = parsed.timeZone;
    if (parsed.referenceTime !== undefined) value.referenceTime = parsed.referenceTime;
    if (parsed.privacyClass !== undefined) value.privacyClass = parsed.privacyClass;
    if (parsed.inputRefs !== undefined) value.inputRefs = parsed.inputRefs;
    if (parsed.executionBudget !== undefined) value.executionBudget = parsed.executionBudget;
    if (parsed.consentContext !== undefined) value.consentContext = parsed.consentContext;
    if (parsed.deviceSnapshotRef !== undefined) value.deviceSnapshotRef = parsed.deviceSnapshotRef;
    if (parsed.createdAt !== undefined) value.createdAt = parsed.createdAt;
    return value;
  }

  static parseTaskSubmission(json: string): TaskSubmission {
    return JSON.parse(json) as TaskSubmission;
  }

  static parseTaskHandle(json: string): TaskHandle {
    return JSON.parse(json) as TaskHandle;
  }

  static parseTaskControlCommand(json: string): TaskControlCommand {
    return JSON.parse(json) as TaskControlCommand;
  }

  static parseCommandReceipt(json: string): CommandReceipt {
    return JSON.parse(json) as CommandReceipt;
  }

  static parseAgentRuntimeEvent(json: string): AgentRuntimeEvent {
    return JSON.parse(json) as AgentRuntimeEvent;
  }

  static parseAgentTaskSnapshot(json: string): AgentTaskSnapshot {
    return JSON.parse(json) as AgentTaskSnapshot;
  }

  static parseReconciliationReport(json: string): ReconciliationReport {
    return JSON.parse(json) as ReconciliationReport;
  }

  static parseClarificationRequest(json: string): ClarificationRequest {
    return JSON.parse(json) as ClarificationRequest;
  }

  static parseClarificationResponse(json: string): ClarificationResponse {
    return JSON.parse(json) as ClarificationResponse;
  }

  static parseWorkflowGraph(json: string): WorkflowGraph {
    return JSON.parse(json) as WorkflowGraph;
  }

  static parseRouterRequest(json: string): RouterRequest {
    return JSON.parse(json) as RouterRequest;
  }

  static parseRouterDecision(json: string): RouterDecision {
    return JSON.parse(json) as RouterDecision;
  }

  static parseToolDescriptor(json: string): ToolDescriptor {
    return JSON.parse(json) as ToolDescriptor;
  }

  static parseToolInvocation(json: string): ToolInvocation {
    return JSON.parse(json) as ToolInvocation;
  }

  static parseToolOutcome(json: string): ToolOutcome {
    return JSON.parse(json) as ToolOutcome;
  }

  static parsePolicyRequest(json: string): PolicyRequest {
    return JSON.parse(json) as PolicyRequest;
  }

  static parseAuthorizationDecision(json: string): AuthorizationDecision {
    return JSON.parse(json) as AuthorizationDecision;
  }

  static parseAuthorizationGrant(json: string): AuthorizationGrant {
    return JSON.parse(json) as AuthorizationGrant;
  }

  static parseTraceEvent(json: string): TraceEvent {
    return JSON.parse(json) as TraceEvent;
  }

  static parseArtifactManifest(json: string): ArtifactManifest {
    const parsed: ArtifactManifest = JSON.parse(json) as ArtifactManifest;
    const value: ArtifactManifest = new ArtifactManifest();
    if (parsed.schemaVersion !== undefined) value.schemaVersion = parsed.schemaVersion;
    if (parsed.contractType !== undefined) value.contractType = parsed.contractType;
    if (parsed.artifactId !== undefined) value.artifactId = parsed.artifactId;
    if (parsed.artifactKind !== undefined) value.artifactKind = parsed.artifactKind;
    if (parsed.algorithm !== undefined) value.algorithm = parsed.algorithm;
    if (parsed.artifactVersion !== undefined) value.artifactVersion = parsed.artifactVersion;
    if (parsed.sourceCommit !== undefined) value.sourceCommit = parsed.sourceCommit;
    if (parsed.sourceLicense !== undefined) value.sourceLicense = parsed.sourceLicense;
    if (parsed.trainingDataLineage !== undefined) value.trainingDataLineage = parsed.trainingDataLineage;
    if (parsed.modelAndProviderSnapshotJson !== undefined) {
      value.modelAndProviderSnapshotJson = parsed.modelAndProviderSnapshotJson;
    }
    if (parsed.featureSchemaVersion !== undefined) value.featureSchemaVersion = parsed.featureSchemaVersion;
    if (parsed.runtimeCompatibility !== undefined) value.runtimeCompatibility = parsed.runtimeCompatibility;
    if (parsed.artifactDigest !== undefined) value.artifactDigest = parsed.artifactDigest;
    if (parsed.checkpointDigest !== undefined) value.checkpointDigest = parsed.checkpointDigest;
    if (parsed.paperReproductionResultsJson !== undefined) {
      value.paperReproductionResultsJson = parsed.paperReproductionResultsJson;
    }
    if (parsed.portParityResultsJson !== undefined) value.portParityResultsJson = parsed.portParityResultsJson;
    if (parsed.harmonyAgentBenchResultsJson !== undefined) {
      value.harmonyAgentBenchResultsJson = parsed.harmonyAgentBenchResultsJson;
    }
    if (parsed.lifecycleStatus !== undefined) value.lifecycleStatus = parsed.lifecycleStatus;
    if (parsed.approvalStatus !== undefined) value.approvalStatus = parsed.approvalStatus;
    if (parsed.approvedBy !== undefined) value.approvedBy = parsed.approvedBy;
    if (parsed.approvedAt !== undefined) value.approvedAt = parsed.approvedAt;
    if (parsed.signedManifestDigest !== undefined) value.signedManifestDigest = parsed.signedManifestDigest;
    if (parsed.signatureAlgorithm !== undefined) value.signatureAlgorithm = parsed.signatureAlgorithm;
    if (parsed.signingKeyId !== undefined) value.signingKeyId = parsed.signingKeyId;
    if (parsed.signatureBase64 !== undefined) value.signatureBase64 = parsed.signatureBase64;
    if (parsed.signedAt !== undefined) value.signedAt = parsed.signedAt;
    if (parsed.rollbackTargetDigest !== undefined) value.rollbackTargetDigest = parsed.rollbackTargetDigest;
    return value;
  }
}
