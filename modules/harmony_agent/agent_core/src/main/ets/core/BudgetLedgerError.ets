export class BudgetLedgerError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'BudgetLedgerError';
  }
}
