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
        try { await this.opening; } finally { this.opening = undefined; }
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
        await this.store.close(); this.store = undefined; this.m1Ready = false; this.extensionReady = false;
        this.textChannel = TextChannel.Unavailable;
      }
      this.leases--;
    });
  }
}
