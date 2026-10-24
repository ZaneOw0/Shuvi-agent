/** Usage is evidence of consumption, never evidence of a monetary charge. */
export class PendingInvoice {
  schemaVersion: string = '1.0';
  provider: string = '';
  accountScope: string = '';
  currency: string = '';
  requestId: string = '';
  providerRequestId?: string;
  usageState: string = 'unknown';
  credits?: number;
  resultDigest: string = '';
}

/** Only a trusted host invoice importer may supply this; model/tool output is not an invoice. */
export class VerifiedInvoice {
  schemaVersion: string = '1.0';
  operationId: string = '';
  provider: string = '';
  accountScope: string = '';
  currency: string = '';
  providerRequestId: string = '';
  resultDigest: string = '';
  invoiceId: string = '';
  lineId: string = '';
  period: string = '';
  evidenceSource: string = '';
  evidenceDigest: string = '';
  verifiedBy: string = '';
  verifiedAt: string = '';
  amountMicros: number = -1;
}

function text(value: string): boolean {
  return typeof value === 'string' && value.trim() === value && value.length > 0 && value.length <= 256;
}

function record(value: Object): boolean {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function fields(value: Object, allowed: string[]): boolean {
  return Object.keys(value).every((key: string): boolean => allowed.includes(key));
}

export function validPendingInvoice(value: PendingInvoice): boolean {
  if (!record(value) || !fields(value, ['schemaVersion', 'provider', 'accountScope', 'currency',
    'requestId', 'providerRequestId', 'usageState', 'credits', 'resultDigest']) || value.schemaVersion !== '1.0' ||
    !text(value.provider) || !text(value.accountScope) || !text(value.requestId) || !text(value.resultDigest) ||
    typeof value.currency !== 'string' || !/^[A-Z]{3}$/.test(value.currency)) return false;
  if (value.providerRequestId !== undefined && !text(value.providerRequestId)) return false;
  if (value.usageState === 'unknown') return value.credits === undefined;
  return value.usageState === 'known' && typeof value.credits === 'number' &&
    Number.isFinite(value.credits) && value.credits >= 0 && value.credits <= Number.MAX_SAFE_INTEGER;
}

export function validVerifiedInvoice(value: VerifiedInvoice): boolean {
  return record(value) && fields(value, ['schemaVersion', 'operationId', 'provider', 'accountScope',
    'currency', 'providerRequestId', 'resultDigest', 'invoiceId', 'lineId', 'period', 'evidenceSource',
    'evidenceDigest', 'verifiedBy', 'verifiedAt', 'amountMicros']) && value.schemaVersion === '1.0' &&
    text(value.operationId) && text(value.provider) && text(value.accountScope) &&
    typeof value.currency === 'string' && /^[A-Z]{3}$/.test(value.currency) && text(value.providerRequestId) &&
    text(value.resultDigest) && text(value.invoiceId) && text(value.lineId) && text(value.period) &&
    text(value.evidenceSource) && typeof value.evidenceDigest === 'string' &&
    /^(sha256:)?[0-9a-f]{64}$/.test(value.evidenceDigest) && text(value.verifiedBy) &&
    text(value.verifiedAt) && Number.isFinite(Date.parse(value.verifiedAt)) &&
    Number.isSafeInteger(value.amountMicros) && value.amountMicros >= 0;
}

export function invoiceMatches(pending: PendingInvoice, invoice: VerifiedInvoice, operationId: string): boolean {
  return validPendingInvoice(pending) && validVerifiedInvoice(invoice) && invoice.operationId === operationId &&
    pending.provider === invoice.provider && pending.accountScope === invoice.accountScope &&
    pending.currency === invoice.currency && pending.providerRequestId !== undefined &&
    pending.providerRequestId === invoice.providerRequestId && pending.resultDigest === invoice.resultDigest;
}

export function copyPendingInvoice(value: PendingInvoice): PendingInvoice {
  const copy = new PendingInvoice();
  copy.schemaVersion = value.schemaVersion;
  copy.provider = value.provider;
  copy.accountScope = value.accountScope;
  copy.currency = value.currency;
  copy.requestId = value.requestId;
  if (value.providerRequestId !== undefined) copy.providerRequestId = value.providerRequestId;
  copy.usageState = value.usageState;
  if (value.credits !== undefined) copy.credits = value.credits;
  copy.resultDigest = value.resultDigest;
  return copy;
}

export function copyVerifiedInvoice(value: VerifiedInvoice): VerifiedInvoice {
  const copy = new VerifiedInvoice();
  copy.schemaVersion = value.schemaVersion;
  copy.operationId = value.operationId;
  copy.provider = value.provider;
  copy.accountScope = value.accountScope;
  copy.currency = value.currency;
  copy.providerRequestId = value.providerRequestId;
  copy.resultDigest = value.resultDigest;
  copy.invoiceId = value.invoiceId;
  copy.lineId = value.lineId;
  copy.period = value.period;
  copy.evidenceSource = value.evidenceSource;
  copy.evidenceDigest = value.evidenceDigest;
  copy.verifiedBy = value.verifiedBy;
  copy.verifiedAt = value.verifiedAt;
  copy.amountMicros = value.amountMicros;
  return copy;
}
