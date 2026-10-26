export const AGENT_TESTKIT_VERSION: string = '0.6.0';
export const AGENT_TESTKIT_SCHEMA_VERSION: string = '1';

export class TestKitValidationResult {
  valid: boolean = true;
  issues: string[] = [];

  addIssue(issue: string): void {
    this.valid = false;
    this.issues.push(issue);
  }
}

export function isNonEmptyText(value: string): boolean {
  return value.trim().length > 0;
}

export function isNonNegativeInteger(value: number): boolean {
  return Number.isFinite(value) && value >= 0 && Math.floor(value) === value;
}

export function isPositiveInteger(value: number): boolean {
  return Number.isFinite(value) && value > 0 && Math.floor(value) === value;
}
