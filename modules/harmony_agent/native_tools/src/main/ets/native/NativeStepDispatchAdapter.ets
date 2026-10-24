import { ToolInvocation, ToolOutcome } from '@harmony_agent/agent-contracts';
import {
  StepDispatchPort,
  StepDispatchReceipt,
  StepDispatchRequest
} from '@harmony_agent/agent-runtime';
import {
  NativeCancellationResolverPort,
  NativeCancellationSignalPort,
  NativeToolAdapter,
  NativeToolOutcomeSinkPort
} from './NativeToolContracts';

export class NativeStepDispatchAdapter implements StepDispatchPort {
  private readonly adapter: NativeToolAdapter;
  private readonly cancellations: NativeCancellationResolverPort;
  private readonly sink: NativeToolOutcomeSinkPort;

  constructor(adapter: NativeToolAdapter, cancellations: NativeCancellationResolverPort,
    sink: NativeToolOutcomeSinkPort) {
    this.adapter = adapter;
    this.cancellations = cancellations;
    this.sink = sink;
  }

  dispatch(request: StepDispatchRequest): StepDispatchReceipt {
    const receipt: StepDispatchReceipt = new StepDispatchReceipt();
    const invocation: ToolInvocation | undefined = request.toolInvocation;
    if (invocation === undefined) {
      receipt.rejectionCode = 'NATIVE_TOOL_INVOCATION_REQUIRED';
      return receipt;
    }
    let cancellation: NativeCancellationSignalPort;
    try {
      cancellation = this.cancellations.resolve(request.task.taskId, request.step.stepId,
        request.dispatchId, invocation.invocationId);
    } catch (error) {
      receipt.rejectionCode = 'NATIVE_CANCELLATION_SIGNAL_UNAVAILABLE';
      return receipt;
    }
    receipt.accepted = true;
    this.execute(request, invocation, cancellation);
    return receipt;
  }

  cancel(_dispatchId: string): boolean {
    // Native cancellation ownership remains with the injected resolver.
    return false;
  }

  private async execute(request: StepDispatchRequest, invocation: ToolInvocation,
    cancellation: NativeCancellationSignalPort): Promise<void> {
    const outcome: ToolOutcome = await this.adapter.invoke(invocation, cancellation);
    this.sink.complete(request.task.taskId, request.step.stepId, request.dispatchId, outcome);
  }
}
