import {
  AgentRuntimeEvent,
  AgentTaskSnapshot,
  ClarificationResponse,
  CollaborationMode,
  TaskFrame,
  WorkflowStep
} from '@harmony_agent/agent-contracts';
import {
  CollaborationPlan,
  PlanningRequest,
  PlanningResult,
  PreparedToolDispatch,
  StepDispatchReceipt,
  StepDispatchRequest
} from './OrchestrationTypes';

export interface RuntimeClockPort {
  nowMs(): number;
}

export interface RuntimeIdGeneratorPort {
  nextId(kind: string, requestId: string): string;
}

export interface CollaborationSelectorPort {
  select(frame: TaskFrame): CollaborationMode;
}

/** Selects the versioned Role Registry identities used by one planning run. */
export interface CollaborationPlanSelectorPort {
  selectPlan(frame: TaskFrame, maxAgentActivations: number): CollaborationPlan;
}

/** Host-supplied cryptographic digest boundary used for collaboration evidence. */
export interface CollaborationPlanDigestPort {
  digest(value: string): string;
}

export interface SemanticPlannerPort {
  plan(request: PlanningRequest): Promise<PlanningResult>;
  resume(request: PlanningRequest, response: ClarificationResponse): Promise<PlanningResult>;
  replan(request: PlanningRequest): Promise<PlanningResult>;
  /** Interrupts in-flight computation only; task state remains owned by the Runtime queue. */
  interrupt(taskId: string): boolean;
}

export interface ToolInvocationPreparerPort {
  prepare(request: PlanningRequest, step: WorkflowStep, nowMs: number): PreparedToolDispatch;
}

export interface StepDispatchPort {
  dispatch(request: StepDispatchRequest): StepDispatchReceipt;
  /** Cancels one accepted dispatch without affecting unrelated in-flight work. */
  cancel(dispatchId: string): boolean;
}

/** Internal observation hook used by the production Facade composition root. */
export interface RuntimeStateObserverPort {
  onStateChanged(snapshot: AgentTaskSnapshot, event: AgentRuntimeEvent): void;
}

export class NoopRuntimeStateObserver implements RuntimeStateObserverPort {
  onStateChanged(snapshot: AgentTaskSnapshot, event: AgentRuntimeEvent): void {
  }
}

export class SingleAgentCollaborationSelector implements CollaborationSelectorPort {
  select(frame: TaskFrame): CollaborationMode {
    return CollaborationMode.SINGLE;
  }
}
