import { ToolInvocation } from '@harmony_agent/agent-contracts';
import {
  StepDispatchPort,
  StepDispatchReceipt,
  StepDispatchRequest
} from '@harmony_agent/agent-runtime';
import { McpToolOutcomeSinkPort } from './McpConnectorTypes';
import { McpAgentAdapter } from './McpAgentAdapter';

export class McpStepDispatchAdapter implements StepDispatchPort {
  private readonly adapter: McpAgentAdapter;
  private readonly sink: McpToolOutcomeSinkPort;
  private readonly invocations: Map<string, string> = new Map<string, string>();

  constructor(adapter: McpAgentAdapter, sink: McpToolOutcomeSinkPort) {
    this.adapter = adapter;
    this.sink = sink;
  }

  dispatch(request: StepDispatchRequest): StepDispatchReceipt {
    const receipt: StepDispatchReceipt = new StepDispatchReceipt();
    const invocation: ToolInvocation | undefined = request.toolInvocation;
    if (invocation === undefined) {
      receipt.rejectionCode = 'MCP_TOOL_INVOCATION_REQUIRED';
      return receipt;
    }
    receipt.accepted = true;
    this.invocations.set(request.dispatchId, invocation.invocationId);
    this.execute(request, invocation);
    return receipt;
  }

  cancel(dispatchId: string): boolean {
    const invocationId: string | undefined = this.invocations.get(dispatchId);
    if (invocationId === undefined) return false;
    return this.adapter.cancel(invocationId);
  }

  private async execute(request: StepDispatchRequest, invocation: ToolInvocation): Promise<void> {
    const outcome = await this.adapter.invoke(invocation);
    this.invocations.delete(request.dispatchId);
    this.sink.complete(request.task.taskId, request.step.stepId, request.dispatchId, outcome);
  }
}
