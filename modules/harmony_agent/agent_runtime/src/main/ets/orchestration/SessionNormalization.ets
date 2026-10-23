import {
  ContractCodec,
  TaskEnvelope,
  TaskHandle,
  TaskSubmission
} from '@harmony_agent/agent-contracts';

/** Rebuilds the normalized envelope while preserving coordinator-owned IDs. */
export function normalizeTaskSubmission(submission: TaskSubmission, handle: TaskHandle): TaskEnvelope {
  const source: TaskSubmission = ContractCodec.parseTaskSubmission(ContractCodec.stringify(submission));
  const value: TaskEnvelope = new TaskEnvelope();
  value.requestId = source.requestId;
  value.conversationId = source.conversationId;
  value.taskId = handle.taskId;
  value.sessionId = handle.sessionId;
  value.userId = source.userId;
  value.userIntent = source.userIntent;
  value.locale = source.locale;
  value.timeZone = source.timeZone;
  value.referenceTime = source.referenceTime;
  value.privacyClass = source.privacyClass;
  value.inputRefs = source.inputRefs;
  value.executionBudget = source.requestedBudget;
  value.consentContext = source.consentContext;
  value.createdAt = handle.acceptedAt;
  return value;
}
