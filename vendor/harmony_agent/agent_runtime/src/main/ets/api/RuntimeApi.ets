import {
  AgentRuntimeEvent,
  AgentTaskSnapshot,
  AuthorizationDecision,
  ClarificationRequest,
  ClarificationResponse,
  CommandReceipt,
  PolicyRequest,
  ReconciliationReport,
  TaskControlCommand,
  TaskHandle,
  TaskSubmission
} from '@harmony_agent/agent-contracts';

export enum ShutdownMode {
  GRACEFUL = 'graceful',
  IMMEDIATE = 'immediate'
}

export enum AgentRuntimeErrorCode {
  INVALID_CONTRACT = 'INVALID_CONTRACT',
  TASK_NOT_FOUND = 'TASK_NOT_FOUND',
  SUBSCRIPTION_CONFLICT = 'SUBSCRIPTION_CONFLICT',
  PERSISTENCE_FAILURE = 'PERSISTENCE_FAILURE',
  RUNTIME_SHUTDOWN = 'RUNTIME_SHUTDOWN'
}

export class SubscriptionRequest {
  subscriptionId: string = '';
  taskId: string = '';
  afterSequence: number = 0;
}

export interface AgentRuntimeObserver {
  onEvent(event: AgentRuntimeEvent): void;
  onPolicyRequest(request: PolicyRequest): void;
  onClarificationRequest(request: ClarificationRequest): void;
}

export interface AgentSubscription {
  close(): void;
  isClosed(): boolean;
}

export interface AgentRuntimeFacade {
  submitTask(submission: TaskSubmission): Promise<TaskHandle>;
  getTaskSnapshot(taskId: string): Promise<AgentTaskSnapshot>;
  cancelTask(command: TaskControlCommand): Promise<CommandReceipt>;
  pauseTask(command: TaskControlCommand): Promise<CommandReceipt>;
  resumeTask(command: TaskControlCommand): Promise<CommandReceipt>;
  provideAuthorization(decision: AuthorizationDecision): Promise<CommandReceipt>;
  provideClarification(response: ClarificationResponse): Promise<CommandReceipt>;
  provideReconciliation(report: ReconciliationReport): Promise<CommandReceipt>;
  subscribe(request: SubscriptionRequest, observer: AgentRuntimeObserver): Promise<AgentSubscription>;
  shutdown(mode: ShutdownMode): Promise<void>;
}
