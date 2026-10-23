export class WorkflowKernelError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'WorkflowKernelError';
  }
}
