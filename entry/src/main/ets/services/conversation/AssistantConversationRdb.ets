import relationalStore from '@ohos.data.relationalStore';
import { EncryptedRdbConfigurationRequest, createEncryptedRdbStoreConfigs } from '@harmony_agent/agent-storage';
import { AgentRdbOpenPort, OwnedAgentRdb } from '../model/AgentRdbResources';
import { ConversationPersistencePort, ConversationRecord, ConversationSummary } from './AssistantConversations';

const TABLE: string = 'assistant_conversation';
const CREATE_SQL: string = 'CREATE TABLE IF NOT EXISTS assistant_conversation (' +
  'id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, ' +
  'messages_json TEXT NOT NULL, memory_json TEXT NOT NULL)';
const LIST_SQL: string = 'SELECT id, title, created_at, updated_at FROM assistant_conversation ORDER BY updated_at DESC LIMIT 500';
const LOAD_SQL: string = 'SELECT id, title, created_at, updated_at, messages_json, memory_json FROM assistant_conversation WHERE id = ?';

function conversationConfig(): relationalStore.StoreConfig {
  const request: EncryptedRdbConfigurationRequest = new EncryptedRdbConfigurationRequest();
  request.executionStoreName = 'shuvi_assistant_conversations_v1.db';
  request.memoryStoreName = 'shuvi_assistant_conversations_unused_v1.db';
  return createEncryptedRdbStoreConfigs(request).execution;
}

function validId(id: string): boolean { return typeof id === 'string' && /^[A-Za-z0-9-]{1,64}$/.test(id); }

/** Encrypted app-private store of assistant conversations (display text and model memory; never image bytes). */
export class AssistantConversationRdb extends OwnedAgentRdb implements ConversationPersistencePort {
  private rdb?: relationalStore.RdbStore;
  constructor(opener: AgentRdbOpenPort) { super(opener, conversationConfig(), 'ASSISTANT_CONVERSATIONS'); }
  protected async initialize(store: relationalStore.RdbStore): Promise<void> {
    await store.execute(CREATE_SQL); this.rdb = store;
  }
  protected detach(): void { this.rdb = undefined; }
  private current(): relationalStore.RdbStore {
    if (this.rdb === undefined) throw new Error('ASSISTANT_CONVERSATIONS_NOT_READY');
    return this.rdb;
  }

  list(): Promise<ConversationSummary[]> {
    return this.run(async (): Promise<ConversationSummary[]> => {
      const rows: ConversationSummary[] = [];
      const result: relationalStore.ResultSet = await this.current().querySql(LIST_SQL, []);
      try {
        while (result.goToNextRow()) {
          const row: ConversationSummary = new ConversationSummary();
          row.id = result.getString(0); row.title = result.getString(1);
          row.createdAt = result.getLong(2); row.updatedAt = result.getLong(3);
          rows.push(row);
        }
      } finally { result.close(); }
      return rows;
    });
  }

  load(id: string): Promise<ConversationRecord | undefined> {
    if (!validId(id)) return Promise.resolve(undefined);
    return this.run(async (): Promise<ConversationRecord | undefined> => {
      const result: relationalStore.ResultSet = await this.current().querySql(LOAD_SQL, [id]);
      try {
        if (!result.goToFirstRow()) return undefined;
        const record: ConversationRecord = new ConversationRecord();
        record.id = result.getString(0); record.title = result.getString(1);
        record.createdAt = result.getLong(2); record.updatedAt = result.getLong(3);
        record.messagesJson = result.getString(4); record.memoryJson = result.getString(5);
        return record;
      } finally { result.close(); }
    });
  }

  save(record: ConversationRecord): Promise<void> {
    if (!validId(record.id)) return Promise.reject(new Error('ASSISTANT_CONVERSATION_ID_INVALID'));
    return this.run(async (): Promise<void> => {
      const values: relationalStore.ValuesBucket = {
        'id': record.id, 'title': record.title.slice(0, 200), 'created_at': record.createdAt, 'updated_at': record.updatedAt,
        'messages_json': record.messagesJson, 'memory_json': record.memoryJson
      };
      const rowId: number = await Promise.resolve(this.current().insert(TABLE, values,
        relationalStore.ConflictResolution.ON_CONFLICT_REPLACE));
      if (rowId < 0) throw new Error('ASSISTANT_CONVERSATION_SAVE_FAILED');
    });
  }

  remove(id: string): Promise<void> {
    if (!validId(id)) return Promise.resolve();
    return this.run(async (): Promise<void> => {
      const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(TABLE);
      predicates.equalTo('id', id);
      await this.current().delete(predicates);
    });
  }
}
