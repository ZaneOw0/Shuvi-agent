export type ContractId = string;
export type IsoTimestamp = string;
export type Digest = string;
export type JsonText = string;
export type MoneyMicros = number;
export type TokenCount = number;
export type DurationMs = number;

export class ContractValidationResult {
  valid: boolean = true;
  issues: string[] = [];
}

export class ContractLabel {
  key: string = '';
  value: string = '';
}
