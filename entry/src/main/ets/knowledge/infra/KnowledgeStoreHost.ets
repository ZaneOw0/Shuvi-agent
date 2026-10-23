import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { TextChannel } from '../domain/TextKnowledgeModels';
import { KnowledgeFailure } from '../domain/PdfKnowledgeModels';
import { KnowledgeStorageScope } from '../domain/KnowledgeStorageScope';

// The host, not an individual repository, owns the ordinary store and write queue.
export class KnowledgeStoreHost {
  private static instances: KnowledgeStoreHost[] = [];
  private context: common.Context;
  private scope: string;
  readonly storageScope: KnowledgeStorageScope;
  private store: relationalStore.RdbStore | undefined = undefined;
  private opening: Promise<void> | undefined = undefined;
  private tail: Promise<void> = Promise.resolve();
  private leases: number = 0;
  private closeFault: boolean = false;
  injectCloseFault(owner: string): void { this.storageScope.requireTestOwner(owner); this.closeFault = true; }
  m1Ready: boolean = false;
  extensionReady: boolean = false;
  imageReady: boolean = false;
  docxReady: boolean = false;
  unifiedReady: boolean = false;
  private unifiedRequired: boolean = false;
  requireUnifiedProtection(): void { this.unifiedRequired = true; }
  async unifiedHeldAssets(owner: string): Promise<string[]> {
    if (!this.unifiedReady) { if (this.unifiedRequired) { throw new KnowledgeFailure('UnifiedProtectionUnavailable','cleanup'); } return []; }
    const rows: relationalStore.ResultSet = await this.requireStore().querySql('SELECT asset FROM upd_asset_ref WHERE owner=? UNION SELECT asset FROM upd_read_lease WHERE owner=?',[owner,owner]);
    const ids: string[] = []; try { while (rows.goToNextRow()) { ids.push(rows.getString(0)); } } finally { rows.close(); } return ids;
  }
  async assertUnifiedUnheld(owner: string, assets: string[]): Promise<void> {
    const held: string[] = await this.unifiedHeldAssets(owner);
    if (assets.some((id: string): boolean => held.indexOf(id) >= 0)) { throw new KnowledgeFailure('UnifiedAssetHeld','cleanup'); }
  }
  async unifiedLegacyRoute(namespace: string, id: string, active: string): Promise<boolean> {
    if (!this.unifiedReady) { return false; }
    const rows: relationalStore.ResultSet=await this.requireStore().querySql("SELECT l.doc FROM upd_legacy_link l JOIN upd_document d ON d.id=l.doc AND d.active=l.generation WHERE l.namespace=? AND l.legacy_id=? AND l.legacy_generation=? AND l.state='Committed'",[namespace,id,active]);
    try { return rows.goToNextRow(); } finally { rows.close(); }
  }
  withUnifiedCleanup<T>(owner: string, assets: string[], action: () => Promise<T>): Promise<T> {
    // The same queue excludes a concurrent addRef/lease between check and unlink.
    return this.enqueue<T>(async (): Promise<T> => {
      await this.assertUnifiedUnheld(owner,assets);
      if (this.unifiedReady) {
        await this.transaction(async (tx: relationalStore.Transaction): Promise<void> => {
          for (const asset of assets) {
            const rows: relationalStore.ResultSet = await tx.querySql('SELECT owner FROM upd_cleanup WHERE asset=?',[asset]);
            try { if (rows.goToNextRow() && rows.getString(0) !== owner) { throw new KnowledgeFailure('CleanupOwnerConflict','cleanup'); } } finally { rows.close(); }
            await tx.execute("INSERT OR REPLACE INTO upd_cleanup VALUES(?,?,'Claimed','')",[asset,owner]);
          }
        });
      }
      try {
        const result: T = await action();
        if (this.unifiedReady) { for (const asset of assets) { await this.requireStore().executeSql("UPDATE upd_cleanup SET state='Done',failure='' WHERE asset=? AND owner=?",[asset,owner]); } }
        return result;
      } catch (error) {
        if (this.unifiedReady) { for (const asset of assets) { await this.requireStore().executeSql("UPDATE upd_cleanup SET state='Pending',failure='OwnerCleanupPending' WHERE asset=? AND owner=?",[asset,owner]); } }
        if (error instanceof Error) { throw error; } throw new KnowledgeFailure('OwnerCleanupPending','cleanup');
      }
    });
  }
  extensionFailure: string = '';
  sessionId: string = '';
  textChannel: TextChannel = TextChannel.Unavailable;
  private constructor(context: common.Context, storageScope: KnowledgeStorageScope) { this.context = context; this.storageScope = storageScope; this.scope = `${context.filesDir}|${storageScope.key}`; }
  static forContext(context: common.Context, storageScope: KnowledgeStorageScope = KnowledgeStorageScope.production()): KnowledgeStoreHost {
    const existing: KnowledgeStoreHost | undefined = KnowledgeStoreHost.instances.find((host: KnowledgeStoreHost): boolean => host.scope === `${context.filesDir}|${storageScope.key}`);
    if (existing !== undefined) { return existing; }
    const host: KnowledgeStoreHost = new KnowledgeStoreHost(context,storageScope); KnowledgeStoreHost.instances.push(host); return host;
  }
  enqueue<T>(operation: () => Promise<T>): Promise<T> {
    const result: Promise<T> = this.tail.then(operation);
    this.tail = result.then((): void => {}, (_error: Error): void => {}); return result;
  }
  private async start(bootstrap: (store: relationalStore.RdbStore, tokenizer: boolean) => Promise<TextChannel>): Promise<void> {
    const supported: boolean = relationalStore.isTokenizerSupported(relationalStore.Tokenizer.CUSTOM_TOKENIZER);
    const config: relationalStore.StoreConfig = { name: this.storageScope.databaseName, securityLevel: relationalStore.SecurityLevel.S3, vector: false };
    if (supported) { config.tokenizer = relationalStore.Tokenizer.CUSTOM_TOKENIZER; }
    try { this.store = await relationalStore.getRdbStore(this.context, config); }
    catch { config.tokenizer = relationalStore.Tokenizer.NONE_TOKENIZER; this.store = await relationalStore.getRdbStore(this.context, config); }
    try {
      this.textChannel = await bootstrap(this.requireStore(), supported);
      this.m1Ready = true;
    } catch {
      await this.requireStore().close(); this.store = undefined; this.m1Ready = false;
      throw new KnowledgeFailure('M1BootstrapRejected', 'ordinary-store');
    }
  }
  async acquireM1(bootstrap: (store: relationalStore.RdbStore, tokenizer: boolean) => Promise<TextChannel>): Promise<relationalStore.RdbStore> {
    // Serialize acquire/release with writes, including an acquire racing last close.
    return this.enqueue<relationalStore.RdbStore>(async (): Promise<relationalStore.RdbStore> => {
      if (!this.m1Ready) {
        if (this.opening === undefined) { this.opening = this.start(bootstrap); }
        const opening: Promise<void> = this.opening;
        try { await opening; } finally { this.opening = undefined; }
      }
      this.leases++; return this.requireStore();
    });
  }
  async acquireExtension(): Promise<relationalStore.RdbStore> {
    return this.enqueue<relationalStore.RdbStore>(async (): Promise<relationalStore.RdbStore> => {
      if (!this.m1Ready) { throw new KnowledgeFailure('M1NotReady', 'extension-open'); }
      this.leases++; return this.requireStore();
    });
  }
  requireStore(): relationalStore.RdbStore {
    if (this.store === undefined) { throw new KnowledgeFailure('StoreNotOpen', 'ordinary-store'); } return this.store;
  }
  async transaction(operation: (transaction: relationalStore.Transaction) => Promise<void>): Promise<void> {
    const transaction: relationalStore.Transaction = await this.requireStore().createTransaction();
    try { await operation(transaction); await transaction.commit(); }
    catch (error) { await transaction.rollback(); if (error instanceof Error) { throw error; } throw new KnowledgeFailure('TransactionFailed', 'ordinary-store'); }
  }
  async release(): Promise<void> {
    await this.enqueue<void>(async (): Promise<void> => {
      if (this.leases <= 0) { throw new KnowledgeFailure('LeaseUnderflow', 'ordinary-store'); }
      if (this.leases === 1 && this.store !== undefined) {
        if (this.closeFault) { this.closeFault = false; throw new KnowledgeFailure('InjectedCloseFailure','ordinary-store'); }
        await this.store.close(); this.store = undefined; this.m1Ready = false; this.extensionReady = false; this.imageReady = false; this.docxReady = false; this.unifiedReady = false;
        this.textChannel = TextChannel.Unavailable;
      }
      this.leases--;
    });
  }
}
