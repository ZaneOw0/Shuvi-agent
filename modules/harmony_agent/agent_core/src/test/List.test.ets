import workflowKernelTest from './WorkflowKernel.test';
import budgetLedgerTest from './BudgetLedger.test';

export default function testsuite(): void {
  workflowKernelTest();
  budgetLedgerTest();
}
