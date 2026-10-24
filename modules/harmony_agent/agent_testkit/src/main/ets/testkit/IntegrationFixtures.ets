export enum IntegrationFixtureKind {
  INVALID_INPUT = 'invalidInput',
  DUPLICATE_DELIVERY = 'duplicateDelivery',
  PERMISSION_REJECTED = 'permissionRejected',
  PARTIAL_SUCCESS = 'partialSuccess',
  CANCEL_BEFORE_CALL = 'cancelBeforeCall',
  UNKNOWN_WRITE_OUTCOME = 'unknownWriteOutcome',
  PROCESS_RESTART = 'processRestart',
  STALE_AUTHORIZATION = 'staleAuthorization',
  SNAPSHOT_EVENT_RACE = 'snapshotEventRace',
  BUDGET_EXHAUSTED = 'budgetExhausted'
}

export class IntegrationFixtureDescriptor {
  fixtureId: string = '';
  kind: IntegrationFixtureKind = IntegrationFixtureKind.INVALID_INPUT;
  expectedAdapterCalls: number = 0;
  requiresProcessRestart: boolean = false;
  expectedInvariant: string = '';
}

function descriptor(fixtureId: string, kind: IntegrationFixtureKind, expectedAdapterCalls: number,
  requiresProcessRestart: boolean, expectedInvariant: string): IntegrationFixtureDescriptor {
  const value: IntegrationFixtureDescriptor = new IntegrationFixtureDescriptor();
  value.fixtureId = fixtureId;
  value.kind = kind;
  value.expectedAdapterCalls = expectedAdapterCalls;
  value.requiresProcessRestart = requiresProcessRestart;
  value.expectedInvariant = expectedInvariant;
  return value;
}

export class IntegrationFixtureCatalog {
  static baseline(): IntegrationFixtureDescriptor[] {
    return [
      descriptor('invalid-input', IntegrationFixtureKind.INVALID_INPUT, 0, false,
        'invalid input cannot produce an executable plan'),
      descriptor('duplicate-delivery', IntegrationFixtureKind.DUPLICATE_DELIVERY, 1, false,
        'stable identifiers prevent duplicate execution'),
      descriptor('permission-rejected', IntegrationFixtureKind.PERMISSION_REJECTED, 0, false,
        'a denied action cannot be rerouted around policy'),
      descriptor('partial-success', IntegrationFixtureKind.PARTIAL_SUCCESS, 2, false,
        'successful results remain while only failed work is remediated'),
      descriptor('cancel-before-call', IntegrationFixtureKind.CANCEL_BEFORE_CALL, 0, false,
        'cancelled work produces no side effect'),
      descriptor('unknown-write-outcome', IntegrationFixtureKind.UNKNOWN_WRITE_OUTCOME, 1, false,
        'an uncertain write waits for reconciliation and is not replayed'),
      descriptor('process-restart', IntegrationFixtureKind.PROCESS_RESTART, 1, true,
        'operation identity, result state, and budget survive restart'),
      descriptor('stale-authorization', IntegrationFixtureKind.STALE_AUTHORIZATION, 0, false,
        'stale or wrongly bound authorization cannot approve changed work'),
      descriptor('snapshot-event-race', IntegrationFixtureKind.SNAPSHOT_EVENT_RACE, 0, false,
        'sequence and version deduplicate without state regression'),
      descriptor('budget-exhausted', IntegrationFixtureKind.BUDGET_EXHAUSTED, 0, false,
        'budget exhaustion cannot expand the configured budget')
    ];
  }
}
