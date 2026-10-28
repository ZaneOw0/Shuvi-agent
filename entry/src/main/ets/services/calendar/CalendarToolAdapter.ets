import { AgentErrorClass, ToolOutcome, ToolOutcomeStatus, WorkflowStepKind } from '@harmony_agent/agent-contracts';
import { RuntimeToolOutcomeSinkPort, StepDispatchPort, StepDispatchReceipt, StepDispatchRequest } from '@harmony_agent/agent-runtime';
import { AgentHostDigest } from '../model/AgentHostDigest';
import { CalendarExecutionResource } from './CalendarExecutionResource';
import { CALENDAR_TOOL_ID, CalendarToolResult, parseCalendarToolArguments } from './CalendarToolContract';
import { CalendarProbeDraft, CalendarProbeResult } from './CalendarProbeSession';

export interface CalendarNativeToolPort {
  create(draft: CalendarProbeDraft, operationId: string, cancelled: () => boolean): Promise<CalendarProbeResult>;
  cancel(): void;
}
class CalendarCall { cancelled: boolean = false; }
export class CalendarToolAdapter implements StepDispatchPort {
  private readonly native: CalendarNativeToolPort;
  private readonly journal: CalendarExecutionResource;
  private readonly digest: AgentHostDigest;
  private readonly sink: RuntimeToolOutcomeSinkPort;
  private readonly resultSink: (taskId: string, result: CalendarToolResult) => void;
  private active: Map<string, CalendarCall> = new Map<string, CalendarCall>();
  constructor(native: CalendarNativeToolPort, journal: CalendarExecutionResource, digest: AgentHostDigest, sink: RuntimeToolOutcomeSinkPort,
    resultSink: (taskId: string, result: CalendarToolResult) => void) {
    this.native = native; this.journal = journal; this.digest = digest; this.sink = sink; this.resultSink = resultSink;
  }
  dispatch(request: StepDispatchRequest): StepDispatchReceipt {
    const receipt = new StepDispatchReceipt(); const invocation = request.toolInvocation;
    if (invocation === undefined || invocation.toolId !== CALENDAR_TOOL_ID || request.step.kind !== WorkflowStepKind.TOOL ||
      request.step.stepId !== invocation.stepId || request.task.taskId !== invocation.taskId ||
      invocation.idempotencyKey !== invocation.operationId || invocation.argumentsDigest !== this.digest.digest(invocation.argumentsJson) ||
      parseCalendarToolArguments(invocation.argumentsJson, Date.now()) === undefined || this.active.size > 0 ||
      !this.journal.verify(invocation)) { receipt.rejectionCode = 'CALENDAR_GRANT_OR_ARGUMENTS_REJECTED'; return receipt; }
    const call = new CalendarCall(); this.active.set(request.dispatchId, call); receipt.accepted = true;
    void this.execute(request, call).catch((): void => { /* UI timeout exposes an unconfirmed result; never retry writes. */ });
    return receipt;
  }
  cancel(dispatchId: string): boolean {
    const call = this.active.get(dispatchId); if (call === undefined) return false;
    call.cancelled = true; this.native.cancel(); return true;
  }
  private async execute(request: StepDispatchRequest, call: CalendarCall): Promise<void> {
    const invocation = request.toolInvocation; if (invocation === undefined) return;
    const outcome = new ToolOutcome(); outcome.invocationId = invocation.invocationId; outcome.startedAt = new Date().toISOString();
    try {
      const draft = parseCalendarToolArguments(invocation.argumentsJson, Date.now());
      if (draft === undefined || call.cancelled) throw new Error('CALENDAR_EXPIRED');
      const state = await this.native.create(draft, invocation.operationId, (): boolean => call.cancelled);
      const record = state.records.find((item): boolean => item.operationId === invocation.operationId);
      const result = new CalendarToolResult(); result.operationId = invocation.operationId;
      result.eventId = record?.eventId ?? -1; result.verified = record?.verified === true;
      result.reminderConfigured = record?.reminderConfigured === true; result.message = state.message;
      if (!call.cancelled) this.resultSink(request.task.taskId, result);
      outcome.resultJson = JSON.stringify(result); outcome.resultDigest = this.digest.digest(outcome.resultJson);
      outcome.status = result.verified ? ToolOutcomeStatus.SUCCEEDED :
        (record !== undefined ? ToolOutcomeStatus.UNKNOWN_OUTCOME : ToolOutcomeStatus.FAILED);
      if (!result.verified) { outcome.errorClass = AgentErrorClass.VERIFICATION_FAILED; outcome.errorCode = 'CALENDAR_NOT_VERIFIED'; }
    } catch {
      // A native exception may follow a successful write. Keep the Runtime operation unresolved.
      outcome.status = ToolOutcomeStatus.UNKNOWN_OUTCOME; outcome.errorClass = AgentErrorClass.UNKNOWN; outcome.errorCode = 'CALENDAR_OUTCOME_UNKNOWN';
    }
    outcome.finishedAt = new Date().toISOString(); this.active.delete(request.dispatchId);
    if (!call.cancelled) await this.sink.complete(request.task.taskId, request.step.stepId, request.dispatchId, outcome);
  }
}
