import {
  AgentRuntimeEvent,
  ClarificationRequest,
  ContractCodec,
  PolicyRequest
} from '@harmony_agent/agent-contracts';
import {
  AgentRuntimeFacade,
  AgentRuntimeObserver,
  AgentSubscription,
  SubscriptionRequest
} from '../api/RuntimeApi';

export class FakeAgentConsumer implements AgentRuntimeObserver {
  events: AgentRuntimeEvent[] = [];
  policyRequests: PolicyRequest[] = [];
  clarificationRequests: ClarificationRequest[] = [];
  private subscription?: AgentSubscription;

  async attach(runtime: AgentRuntimeFacade, subscriptionId: string, taskId: string,
    afterSequence: number = 0): Promise<void> {
    this.close();
    const request: SubscriptionRequest = new SubscriptionRequest();
    request.subscriptionId = subscriptionId;
    request.taskId = taskId;
    request.afterSequence = afterSequence;
    this.subscription = await runtime.subscribe(request, this);
  }

  close(): void {
    const active: AgentSubscription | undefined = this.subscription;
    if (active !== undefined) {
      active.close();
      this.subscription = undefined;
    }
  }

  isAttached(): boolean {
    const active: AgentSubscription | undefined = this.subscription;
    return active !== undefined && !active.isClosed();
  }

  onEvent(event: AgentRuntimeEvent): void {
    this.events.push(ContractCodec.parseAgentRuntimeEvent(ContractCodec.stringify(event)));
  }

  onPolicyRequest(request: PolicyRequest): void {
    this.policyRequests.push(ContractCodec.parsePolicyRequest(ContractCodec.stringify(request)));
  }

  onClarificationRequest(request: ClarificationRequest): void {
    this.clarificationRequests.push(ContractCodec.parseClarificationRequest(ContractCodec.stringify(request)));
  }
}
