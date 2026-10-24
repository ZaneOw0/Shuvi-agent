import relationalStore from '@ohos.data.relationalStore';
import { DurableSnapshotBackendPort } from './StoragePorts';
import { StorageSnapshotEnvelope } from './StorageTypes';

const SNAPSHOT_TABLE: string = 'harmony_agent_recovery_snapshot';
const SNAPSHOT_SLOT_ID: number = 1;

const CREATE_SNAPSHOT_TABLE_SQL: string =
  'CREATE TABLE IF NOT EXISTS harmony_agent_recovery_snapshot (' +
  'slot_id INTEGER PRIMARY KEY, ' +
  'revision INTEGER NOT NULL, ' +
  'schema_version TEXT NOT NULL, ' +
  'payload_json TEXT NOT NULL, ' +
  'payload_digest TEXT NOT NULL)';

const LOAD_SNAPSHOT_SQL: string =
  'SELECT revision, schema_version, payload_json, payload_digest ' +
  'FROM harmony_agent_recovery_snapshot WHERE slot_id = ?';

/**
 * API 26 RDB adapter for the recovery snapshot boundary.
 *
 * The adapter deliberately accepts an already-open RdbStore. Opening,
 * encryption configuration, migration scheduling, backup, and closing belong
 * to the external composition root. No Ability or UI dependency is required.
 */
export class RdbSnapshotBackend implements DurableSnapshotBackendPort {
  private readonly store: relationalStore.RdbStore;

  constructor(store: relationalStore.RdbStore) {
    this.store = store;
  }

  async initialize(): Promise<void> {
    try {
      await this.store.execute(CREATE_SNAPSHOT_TABLE_SQL);
    } catch (error) {
      throw error as Error;
    }
  }

  async load(): Promise<StorageSnapshotEnvelope | undefined> {
    let resultSet: relationalStore.ResultSet | undefined = undefined;
    try {
      resultSet = await this.store.querySql(LOAD_SNAPSHOT_SQL, [SNAPSHOT_SLOT_ID]);
      if (!resultSet.goToFirstRow()) {
        return undefined;
      }
      const envelope: StorageSnapshotEnvelope = new StorageSnapshotEnvelope();
      envelope.revision = resultSet.getLong(0);
      envelope.schemaVersion = resultSet.getString(1);
      envelope.payloadJson = resultSet.getString(2);
      envelope.payloadDigest = resultSet.getString(3);
      return envelope;
    } catch (error) {
      throw error as Error;
    } finally {
      if (resultSet !== undefined) {
        try {
          resultSet.close();
        } catch (closeError) {
          throw closeError as Error;
        }
      }
    }
  }

  async compareAndSet(expectedRevision: number, next: StorageSnapshotEnvelope): Promise<boolean> {
    this.assertValidWrite(expectedRevision, next);

    const updateValues: relationalStore.ValuesBucket = {
      'revision': next.revision,
      'schema_version': next.schemaVersion,
      'payload_json': next.payloadJson,
      'payload_digest': next.payloadDigest
    };
    const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(SNAPSHOT_TABLE);
    predicates.equalTo('slot_id', SNAPSHOT_SLOT_ID).and().equalTo('revision', expectedRevision);
    let updated: number = 0;
    try {
      updated = await this.store.update(updateValues, predicates);
    } catch (error) {
      throw error as Error;
    }
    if (updated === 1) {
      return true;
    }
    if (expectedRevision !== 0) {
      return false;
    }

    const insertValues: relationalStore.ValuesBucket = {
      'slot_id': SNAPSHOT_SLOT_ID,
      'revision': next.revision,
      'schema_version': next.schemaVersion,
      'payload_json': next.payloadJson,
      'payload_digest': next.payloadDigest
    };
    let rowId: number = -1;
    try {
      // API 26 insert(table, values, conflict) returns Promise<number>; keep awaiting the actual write.
      rowId = await Promise.resolve(this.store.insert(
        SNAPSHOT_TABLE,
        insertValues,
        relationalStore.ConflictResolution.ON_CONFLICT_IGNORE
      ));
    } catch (error) {
      throw error as Error;
    }
    return rowId >= 0;
  }

  private assertValidWrite(expectedRevision: number, next: StorageSnapshotEnvelope): void {
    if (expectedRevision < 0 || !Number.isInteger(expectedRevision)) {
      throw new Error('expectedRevision must be a non-negative integer');
    }
    if (next.revision <= expectedRevision || !Number.isInteger(next.revision)) {
      throw new Error('next revision must be an integer greater than expectedRevision');
    }
    if (next.schemaVersion.length === 0 || next.payloadJson.length === 0 || next.payloadDigest.length === 0) {
      throw new Error('snapshot envelope fields must not be empty');
    }
  }
}
