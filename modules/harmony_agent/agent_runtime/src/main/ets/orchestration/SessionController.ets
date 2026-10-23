import {
  ContractCodec,
  ContractValidator,
  TaskEnvelope,
  TaskHandle,
  TaskSubmission
} from '@harmony_agent/agent-contracts';
import { AgentRuntimeError } from '../api/AgentRuntimeError';
import { AgentRuntimeErrorCode } from '../api/RuntimeApi';
import { SessionAcceptance } from './OrchestrationTypes';
import { RuntimeClockPort, RuntimeIdGeneratorPort } from './RuntimePorts';
import { normalizeTaskSubmission } from './SessionNormalization';

class SessionRecord {
  submissionJson: string = '';
  handle: TaskHandle = new TaskHandle();
  envelope: TaskEnvelope = new TaskEnvelope();
}

function copyHandle(value: TaskHandle): TaskHandle {
  return ContractCodec.parseTaskHandle(ContractCodec.stringify(value));
}

function copyEnvelope(value: TaskEnvelope): TaskEnvelope {
  return ContractCodec.parseTaskEnvelope(ContractCodec.stringify(value));
}

export class SessionController {
  private clock: RuntimeClockPort;
  private ids: RuntimeIdGeneratorPort;
  private sessions: SessionRecord[] = [];

  constructor(clock: RuntimeClockPort, ids: RuntimeIdGeneratorPort) {
    this.clock = clock;
    this.ids = ids;
  }

  accept(submission: TaskSubmission): SessionAcceptance {
    if (!ContractValidator.validateTaskSubmission(submission).valid) {
      throw new AgentRuntimeError(AgentRuntimeErrorCode.INVALID_CONTRACT, 'invalid TaskSubmission');
    }
    const submissionJson: string = ContractCodec.stringify(submission);
    const existing: number = this.findByRequestId(submission.requestId);
    if (existing >= 0) {
      if (this.sessions[existing].submissionJson !== submissionJson) {
        throw new AgentRuntimeError(AgentRuntimeErrorCode.INVALID_CONTRACT,
          'requestId reused with different submission');
      }
      return this.result(this.sessions[existing], true);
    }

    const nowMs: number = this.clock.nowMs();
    const record: SessionRecord = new SessionRecord();
    record.submissionJson = submissionJson;
    record.handle.requestId = submission.requestId;
    record.handle.taskId = this.ids.nextId('task', submission.requestId);
    record.handle.sessionId = this.ids.nextId('session', submission.requestId);
    record.handle.acceptedAt = new Date(nowMs).toISOString();
    record.handle.snapshotVersion = 1;
    record.envelope = normalizeTaskSubmission(submission, record.handle);
    if (!ContractValidator.validateTaskEnvelope(record.envelope).valid) {
      throw new AgentRuntimeError(AgentRuntimeErrorCode.INVALID_CONTRACT,
        'normalized TaskEnvelope is invalid');
    }
    this.sessions.push(record);
    return this.result(record, false);
  }

  canRestore(submission: TaskSubmission, handle: TaskHandle, envelope: TaskEnvelope): boolean {
    if (!ContractValidator.validateTaskSubmission(submission).valid ||
      !ContractValidator.validateTaskHandle(handle).valid ||
      !ContractValidator.validateTaskEnvelope(envelope).valid ||
      handle.requestId !== submission.requestId || handle.requestId !== envelope.requestId ||
      handle.taskId !== envelope.taskId || handle.sessionId !== envelope.sessionId ||
      ContractCodec.stringify(normalizeTaskSubmission(submission, handle)) !==
        ContractCodec.stringify(envelope)) {
      return false;
    }
    const submissionJson: string = ContractCodec.stringify(submission);
    const existing: number = this.findByRequestId(handle.requestId);
    if (existing >= 0) {
      return this.sessions[existing].submissionJson === submissionJson &&
        ContractCodec.stringify(this.sessions[existing].handle) === ContractCodec.stringify(handle) &&
        ContractCodec.stringify(this.sessions[existing].envelope) === ContractCodec.stringify(envelope);
    }
    return this.findByTaskId(handle.taskId) < 0 && this.findBySessionId(handle.sessionId) < 0;
  }

  restore(submission: TaskSubmission, handle: TaskHandle, envelope: TaskEnvelope): boolean {
    if (!this.canRestore(submission, handle, envelope)) return false;
    const existing: number = this.findByRequestId(handle.requestId);
    if (existing >= 0) return true;
    const record: SessionRecord = new SessionRecord();
    record.submissionJson = ContractCodec.stringify(submission);
    record.handle = copyHandle(handle);
    record.envelope = copyEnvelope(envelope);
    this.sessions.push(record);
    return true;
  }

  private result(record: SessionRecord, duplicate: boolean): SessionAcceptance {
    const value: SessionAcceptance = new SessionAcceptance();
    value.duplicate = duplicate;
    value.handle = copyHandle(record.handle);
    value.envelope = copyEnvelope(record.envelope);
    return value;
  }

  private findByRequestId(requestId: string): number {
    for (let i: number = 0; i < this.sessions.length; i++) {
      if (this.sessions[i].handle.requestId === requestId) {
        return i;
      }
    }
    return -1;
  }

  private findByTaskId(taskId: string): number {
    for (let i: number = 0; i < this.sessions.length; i++) {
      if (this.sessions[i].handle.taskId === taskId) return i;
    }
    return -1;
  }

  private findBySessionId(sessionId: string): number {
    for (let i: number = 0; i < this.sessions.length; i++) {
      if (this.sessions[i].handle.sessionId === sessionId) return i;
    }
    return -1;
  }
}
