import { ToolOutcome } from '@harmony_agent/agent-contracts';
import { PendingInvoice, RuntimePendingInvoicePort, StoredOperation, validPendingInvoice } from '@harmony_agent/agent-storage';
import { SearchUsageReceipts } from './SearchUsageReceipts';

/** Host configuration identifies the billed account without storing its key or private invoice. */
export class SearchPendingInvoice implements RuntimePendingInvoicePort {
  private readonly receipts: SearchUsageReceipts;
  private readonly accountScope: string;
  private readonly currency: string;
  constructor(receipts: SearchUsageReceipts, accountScope: string, currency: string) {
    if (!/^[A-Za-z0-9_.-]{1,128}$/.test(accountScope) || !/^[A-Z]{3}$/.test(currency)) {
      throw new Error('SEARCH_BILLING_SCOPE_REQUIRED');
    }
    this.receipts = receipts;
    this.accountScope = accountScope;
    this.currency = currency;
  }
  receiptForOutcome(operation: StoredOperation, outcome: ToolOutcome): PendingInvoice | undefined {
    const usage = this.receipts.lookupOperation(operation, outcome);
    if (usage === undefined || outcome.resultDigest === undefined) return undefined;
    const pending = new PendingInvoice();
    pending.provider = usage.provider;
    pending.accountScope = this.accountScope;
    pending.currency = this.currency;
    pending.requestId = usage.requestId;
    pending.providerRequestId = usage.providerRequestId;
    pending.usageState = usage.state;
    pending.credits = usage.credits;
    pending.resultDigest = outcome.resultDigest;
    return validPendingInvoice(pending) ? pending : undefined;
  }
}
