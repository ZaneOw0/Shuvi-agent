import { ExecutionBudget } from '@harmony_agent/agent-contracts';
import { BudgetReservationState, BudgetScopeKind } from './CoreEnums';

export class BudgetAmount {
  wallTimeMs: number = 0;
  inputTokens: number = 0;
  outputTokens: number = 0;
  monetaryCostMicros: number = 0;
  toolCalls: number = 0;
  agentActivations: number = 0;
  retries: number = 0;
  replans: number = 0;
}

export class BudgetReservationRequest {
  reservationId: string = '';
  taskId: string = '';
  stepId: string = '';
  providerId: string = '';
  amount: BudgetAmount = new BudgetAmount();
}

export class BudgetReservationResult {
  accepted: boolean = false;
  code: string = '';
}

export class BudgetSettlementResult {
  accepted: boolean = false;
  overLimit: boolean = false;
  code: string = '';
}

export class BudgetScopeSnapshot {
  kind: BudgetScopeKind = BudgetScopeKind.TASK;
  taskId: string = '';
  scopeId: string = '';
  limit: ExecutionBudget = new ExecutionBudget();
  consumed: BudgetAmount = new BudgetAmount();
  reserved: BudgetAmount = new BudgetAmount();
}

export class BudgetReservationSnapshot {
  reservationId: string = '';
  taskId: string = '';
  stepId: string = '';
  providerId: string = '';
  requested: BudgetAmount = new BudgetAmount();
  actual: BudgetAmount = new BudgetAmount();
  state: BudgetReservationState = BudgetReservationState.RESERVED;
}
