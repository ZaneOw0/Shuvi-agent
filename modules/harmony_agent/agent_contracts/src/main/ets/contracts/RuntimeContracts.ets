import {
  AGENT_CONTRACT_SCHEMA_VERSION,
  CONTRACT_TYPE_AGENT_RUNTIME_EVENT,
  CONTRACT_TYPE_AGENT_TASK_SNAPSHOT,
  CONTRACT_TYPE_COMMAND_RECEIPT,
  CONTRACT_TYPE_CLARIFICATION_REQUEST,
  CONTRACT_TYPE_CLARIFICATION_RESPONSE,
  CONTRACT_TYPE_RECONCILIATION_REPORT,
  CONTRACT_TYPE_TASK_CONTROL_COMMAND,
  CONTRACT_TYPE_TASK_HANDLE,
  CONTRACT_TYPE_TASK_SUBMISSION
} from './Constants';
import { ContractId, Digest, IsoTimestamp, JsonText } from './Common';
import {
  AgentRuntimeEventType,
  AgentTaskStatus,
  PrivacyClass,
  ReconciliationStatus,
  TaskControlAction
} from './Enums';
import { ConsentContext, ExecutionBudget, TaskInputRef } from './TaskContracts';

export class TaskSubmission {
  schemaVersion: string = AGENT_CONTRACT_SCHEMA_VERSION;
  contractType: string = CONTRACT_TYPE_TASK_SUBMISSION;
  requestId: ContractId = '';
  conversationId?: ContractId;
  userId: ContractId = '';
  userIntent: string = '';
  locale: string = '';
  timeZone: string = '';
  referenceTime: IsoTimestamp = '';
  privacyClass: PrivacyClass = PrivacyClass.PERSONAL;
  inputRefs: TaskInputRef[] = [];
  requestedBudget: ExecutionBudget = new ExecutionBudget();
  consentContext: ConsentContext = new ConsentContext();
  submittedAt: IsoTimestamp = '';
}

export class TaskHandle {
  schemaVersion: string = AGENT_CONTRACT_SCHEMA_VERSION;
  contractType: string = CONTRACT_TYPE_TASK_HANDLE;
  requestId: ContractId = '';
  taskId: ContractId = '';
  sessionId: ContractId = '';
  acceptedAt: IsoTimestamp = '';
  snapshotVersion: number = 0;
}

export class TaskControlCommand {
  schemaVersion: string = AGENT_CONTRACT_SCHEMA_VERSION;
  contractType: string = CONTRACT_TYPE_TASK_CONTROL_COMMAND;
  commandId: ContractId = '';
  taskId: ContractId = '';
  action: TaskControlAction = TaskControlAction.CANCEL;
  reasonCode: string = '';
  requestedAt: IsoTimestamp = '';
}

export class CommandReceipt {
  schemaVersion: string = AGENT_CONTRACT_SCHEMA_VERSION;
  contractType: string = CONTRACT_TYPE_COMMAND_RECEIPT;
  commandId: ContractId = '';
  taskId: ContractId = '';
  accepted: boolean = false;
  duplicate: boolean = false;
  snapshotVersion: number = 0;
  rejectionCode?: string;
}

export class AgentRuntimeEvent {
  schemaVersion: string = AGENT_CONTRACT_SCHEMA_VERSION;
  contractType: string = CONTRACT_TYPE_AGENT_RUNTIME_EVENT;
  eventId: ContractId = '';
  taskId: ContractId = '';
  sequence: number = 0;
  snapshotVersion: number = 0;
  eventType: AgentRuntimeEventType = AgentRuntimeEventType.TASK_STATE_CHANGED;
  timestamp: IsoTimestamp = '';
  payloadJson: JsonText = '{}';
}

export class AgentTaskSnapshot {
  schemaVersion: string = AGENT_CONTRACT_SCHEMA_VERSION;
  contractType: string = CONTRACT_TYPE_AGENT_TASK_SNAPSHOT;
  requestId: ContractId = '';
  taskId: ContractId = '';
  sessionId: ContractId = '';
  status: AgentTaskStatus = AgentTaskStatus.RECEIVED;
  snapshotVersion: number = 0;
  lastEventSequence: number = 0;
  resultJson: JsonText = '{}';
  updatedAt: IsoTimestamp = '';
}

export class ReconciliationReport {
  schemaVersion: string = AGENT_CONTRACT_SCHEMA_VERSION;
  contractType: string = CONTRACT_TYPE_RECONCILIATION_REPORT;
  commandId: ContractId = '';
  taskId: ContractId = '';
  stepId: ContractId = '';
  operationId: ContractId = '';
  status: ReconciliationStatus = ReconciliationStatus.STILL_UNKNOWN;
  evidenceDigest: Digest = '';
  providerReceipt?: string;
  reportedAt: IsoTimestamp = '';
}

export class ClarificationRequest {
  schemaVersion: string = AGENT_CONTRACT_SCHEMA_VERSION;
  contractType: string = CONTRACT_TYPE_CLARIFICATION_REQUEST;
  clarificationId: ContractId = '';
  taskId: ContractId = '';
  questionCode: string = '';
  prompt: string = '';
  responseSchemaJson: JsonText = '{}';
  requestedAt: IsoTimestamp = '';
  expiresAt: IsoTimestamp = '';
  expiresAtMs: number = 0;
}

export class ClarificationResponse {
  schemaVersion: string = AGENT_CONTRACT_SCHEMA_VERSION;
  contractType: string = CONTRACT_TYPE_CLARIFICATION_RESPONSE;
  commandId: ContractId = '';
  clarificationId: ContractId = '';
  taskId: ContractId = '';
  answerJson: JsonText = '{}';
  respondedAt: IsoTimestamp = '';
  respondedAtMs: number = 0;
}
