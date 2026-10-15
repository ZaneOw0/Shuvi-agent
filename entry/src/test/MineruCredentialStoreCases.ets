import { asset } from '@kit.AssetStoreKit';
import { MineruAssetStorePort, MineruCredentialStore } from '../main/ets/knowledge/infra/MineruCredentialStore';
import { DocumentCredentialStatus, DocumentParseFailure, DocumentLeaseBinding } from '../main/ets/knowledge/domain/DocumentParseModels';
import { DocumentParseService } from '../main/ets/knowledge/application/DocumentParseService';
import { DocumentTestRepository, DocumentServiceTestCase, documentServiceCheck } from './DocumentParseServiceCases';

class MineruTestAssetError extends Error {
  code: number;
  constructor(code: number) { super('unit-nonsecret-sdk-detail'); this.code = code; }
}
class MineruTestAssetStore implements MineruAssetStorePort {
  rows: asset.AssetMap[] = [];
  queries: asset.AssetMap[] = [];
  additions: asset.AssetMap[] = [];
  updates: asset.AssetMap[] = [];
  removals: number = 0;
  queryCode: number = 0;
  writeCode: number = 0;
  afterWriteCode: number = 0;
  discardWrite: boolean = false;
  unsafeAfterWrite: boolean = false;
  synchronousQueryFailure: boolean = false;
  addedBytes: Uint8Array = new Uint8Array(0);
  query(query: asset.AssetMap): Promise<asset.AssetMap[]> {
    this.queries.push(query);
    if (this.synchronousQueryFailure) { throw new MineruTestAssetError(401); }
    return this.queryResult();
  }
  private async queryResult(): Promise<asset.AssetMap[]> {
    if (this.queryCode !== 0) { throw new MineruTestAssetError(this.queryCode); }
    if (this.rows.length === 0) { throw new MineruTestAssetError(24000002); }
    return this.rows;
  }
  async add(attributes: asset.AssetMap): Promise<void> {
    this.additions.push(new Map<asset.Tag, asset.Value>(attributes));
    const bytes: asset.Value | undefined = attributes.get(asset.Tag.SECRET);
    if (bytes instanceof Uint8Array) { this.addedBytes = bytes; }
    if (attributes.has(asset.Tag.IS_PERSISTENT)) { throw new MineruTestAssetError(201); }
    this.finishWrite();
  }
  async update(query: asset.AssetMap, attributes: asset.AssetMap): Promise<void> {
    documentServiceCheck(query.size === 1 && query.has(asset.Tag.ALIAS));
    this.updates.push(new Map<asset.Tag, asset.Value>(attributes)); this.finishWrite();
  }
  private finishWrite(): void {
    if (this.writeCode !== 0) { throw new MineruTestAssetError(this.writeCode); }
    if (!this.discardWrite) { this.rows = [mineruTestAttributes()]; }
    if (this.unsafeAfterWrite) { this.rows[0].set(asset.Tag.SYNC_TYPE, asset.SyncType.TRUSTED_DEVICE); }
    this.queryCode = this.afterWriteCode;
  }
  async remove(query: asset.AssetMap): Promise<void> {
    documentServiceCheck(query.size === 1 && query.has(asset.Tag.ALIAS)); this.removals++;
    if (this.writeCode !== 0) { throw new MineruTestAssetError(this.writeCode); }
    this.rows = []; this.queryCode = this.afterWriteCode;
  }
}
function mineruTestAttributes(): asset.AssetMap {
  const row: asset.AssetMap = new Map<asset.Tag, asset.Value>();
  row.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_UNLOCKED); row.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER); return row;
}
async function mineruTestSaveFailure(store: MineruCredentialStore, replace: boolean): Promise<DocumentParseFailure> {
  try { await store.save('unit-nonsecret-input', replace); }
  catch (error) { if (error instanceof DocumentParseFailure) { return error; } }
  throw new Error('Expected sanitized save failure');
}
function mineruTestNoSecretQueries(api: MineruTestAssetStore): void {
  documentServiceCheck(api.queries.every((query: asset.AssetMap): boolean => query.size === 2 &&
    query.get(asset.Tag.RETURN_TYPE) === asset.ReturnType.ATTRIBUTES && query.has(asset.Tag.ALIAS)));
}
export function mineruCredentialStoreCases(): DocumentServiceTestCase[] {
  const tests: DocumentServiceTestCase[] = [
    { name: '新增省略持久权限属性并回查后才公开已配置', run: async (): Promise<void> => {
      const api: MineruTestAssetStore = new MineruTestAssetStore();
      const store: MineruCredentialStore = new MineruCredentialStore('unit-no-files', api);
      const service: DocumentParseService = new DocumentParseService(store, new DocumentTestRepository());
      await service.initialize(); await service.saveToken('unit-nonsecret-input', false);
      documentServiceCheck(service.viewState().credential === DocumentCredentialStatus.Configured && api.additions.length === 1);
      const attrs: asset.AssetMap = api.additions[0];
      documentServiceCheck(attrs.size === 5 && !attrs.has(asset.Tag.IS_PERSISTENT) && !attrs.has(asset.Tag.GROUP_ID));
      documentServiceCheck(attrs.get(asset.Tag.ACCESSIBILITY) === asset.Accessibility.DEVICE_UNLOCKED && attrs.get(asset.Tag.SYNC_TYPE) === asset.SyncType.NEVER);
      documentServiceCheck(attrs.get(asset.Tag.CONFLICT_RESOLUTION) === asset.ConflictResolution.THROW_ERROR);
      documentServiceCheck(api.addedBytes.length > 0 && api.addedBytes.every((n: number): boolean => n === 0));
      documentServiceCheck(JSON.stringify(service.viewState()).indexOf('unit-nonsecret-input') < 0); mineruTestNoSecretQueries(api);
    } },
    { name: '更新只改秘密字段并删除回查不读明文', run: async (): Promise<void> => {
      const api: MineruTestAssetStore = new MineruTestAssetStore(); api.rows = [mineruTestAttributes()];
      const store: MineruCredentialStore = new MineruCredentialStore('unit-no-files', api);
      documentServiceCheck(await store.save('unit-nonsecret-input', true) === DocumentCredentialStatus.Configured);
      documentServiceCheck(api.updates.length === 1 && api.updates[0].size === 1 && api.updates[0].has(asset.Tag.SECRET) && api.additions.length === 0);
      documentServiceCheck(await store.remove() === DocumentCredentialStatus.Missing && api.removals === 1); mineruTestNoSecretQueries(api);
    } },
    { name: '保存前查询失败保留阶段与code且绝不写入', run: async (): Promise<void> => {
      const api: MineruTestAssetStore = new MineruTestAssetStore(); api.queryCode = 24000005;
      const failure: DocumentParseFailure = await mineruTestSaveFailure(new MineruCredentialStore('unit-no-files', api), false);
      documentServiceCheck(failure.stage === '保存前属性查询' && failure.serviceCode === '24000005' && api.additions.length === 0);
      documentServiceCheck(failure.message.indexOf('unit-nonsecret-sdk-detail') < 0);
    } },
    { name: '同步SDK参数拒绝也保留阶段与数值code', run: async (): Promise<void> => {
      const api: MineruTestAssetStore = new MineruTestAssetStore(); api.synchronousQueryFailure = true;
      const failure: DocumentParseFailure = await mineruTestSaveFailure(new MineruCredentialStore('unit-no-files', api), false);
      documentServiceCheck(failure.stage === '保存前属性查询' && failure.serviceCode === '401' && api.additions.length === 0);
    } },
    { name: '写入后属性查询失败不冒充新增失败或已保存', run: async (): Promise<void> => {
      const api: MineruTestAssetStore = new MineruTestAssetStore(); api.afterWriteCode = 24000010;
      const failure: DocumentParseFailure = await mineruTestSaveFailure(new MineruCredentialStore('unit-no-files', api), false);
      documentServiceCheck(api.additions.length === 1 && api.rows.length === 1 && failure.stage === '保存后属性确认' && failure.serviceCode === '24000010');
      documentServiceCheck(failure.message.indexOf('写入已返回') >= 0 && failure.message.indexOf('unit-nonsecret-sdk-detail') < 0);
    } },
    { name: '写入返回但属性缺失绝不假配置', run: async (): Promise<void> => {
      const api: MineruTestAssetStore = new MineruTestAssetStore(); api.discardWrite = true;
      const store: MineruCredentialStore = new MineruCredentialStore('unit-no-files', api);
      const failure: DocumentParseFailure = await mineruTestSaveFailure(store, false);
      documentServiceCheck(failure.stage === '保存后属性确认' && await store.status() === DocumentCredentialStatus.Missing);
    } },
    { name: '写入后保护属性异常不能降低配置判定', run: async (): Promise<void> => {
      const api: MineruTestAssetStore = new MineruTestAssetStore(); api.unsafeAfterWrite = true;
      const store: MineruCredentialStore = new MineruCredentialStore('unit-no-files', api);
      const failure: DocumentParseFailure = await mineruTestSaveFailure(store, false);
      documentServiceCheck(failure.stage === '保存后属性确认' && await store.status() === DocumentCredentialStatus.Unavailable && failure.message.indexOf('保护属性不符') >= 0);
    } },
    { name: '未知属性重复记录和保护不符仍不可用且不覆盖', run: async (): Promise<void> => {
      for (const rows of [[new Map<asset.Tag, asset.Value>()], [mineruTestAttributes(), mineruTestAttributes()]]) {
        const api: MineruTestAssetStore = new MineruTestAssetStore(); api.rows = rows;
        const store: MineruCredentialStore = new MineruCredentialStore('unit-no-files', api);
        documentServiceCheck(await store.status() === DocumentCredentialStatus.Unavailable);
        await mineruTestSaveFailure(store, false); documentServiceCheck(api.additions.length === 0 && api.updates.length === 0);
      }
    } },
    { name: '模式不符不能自动新增或替换已有凭据', run: async (): Promise<void> => {
      const api: MineruTestAssetStore = new MineruTestAssetStore(); api.rows = [mineruTestAttributes()];
      await mineruTestSaveFailure(new MineruCredentialStore('unit-no-files', api), false);
      documentServiceCheck(api.additions.length === 0 && api.updates.length === 0);
    } },
    { name: '地址密钥共用新增参数且不引持久权限', run: async (): Promise<void> => {
      const api: MineruTestAssetStore = new MineruTestAssetStore();
      const store: MineruCredentialStore = new MineruCredentialStore('unit-no-files', api);
      const binding: DocumentLeaseBinding = new DocumentLeaseBinding(); binding.id = 'lease-unit-only';
      // Host adapter deliberately provides no secret on read; stop after exercising key creation.
      try { await store.sealLease(binding, 'unit-nonsecret-address'); } catch {}
      documentServiceCheck(api.additions.length === 1 && !api.additions[0].has(asset.Tag.IS_PERSISTENT) && api.addedBytes.length === 32);
      documentServiceCheck(api.addedBytes.every((n: number): boolean => n === 0));
    } },
    { name: '删除SDK拒绝保留数值code与阶段', run: async (): Promise<void> => {
      const api: MineruTestAssetStore = new MineruTestAssetStore(); api.rows = [mineruTestAttributes()]; api.writeCode = 24000008;
      let failure: DocumentParseFailure | undefined = undefined;
      try { await new MineruCredentialStore('unit-no-files', api).remove(); }
      catch (error) { if (error instanceof DocumentParseFailure) { failure = error; } }
      documentServiceCheck(failure?.stage === '凭据删除' && failure?.serviceCode === '24000008');
    } },
    { name: '保存前同步属性不符不能更新或假配置', run: async (): Promise<void> => {
      const api: MineruTestAssetStore = new MineruTestAssetStore();
      const store: MineruCredentialStore = new MineruCredentialStore('unit-no-files', api);
      api.rows = [mineruTestAttributes()]; api.rows[0].set(asset.Tag.SYNC_TYPE, asset.SyncType.TRUSTED_DEVICE);
      documentServiceCheck(await store.status() === DocumentCredentialStatus.Unavailable);
      const failure: DocumentParseFailure = await mineruTestSaveFailure(store, true);
      documentServiceCheck(failure.stage === '保存前属性查询' && api.updates.length === 0);
    } },
    { name: '适配器拒绝经service到公开消息保留阶段与数值code', run: async (): Promise<void> => {
      const api: MineruTestAssetStore = new MineruTestAssetStore(); api.writeCode = 201;
      const service: DocumentParseService = new DocumentParseService(new MineruCredentialStore('unit-no-files', api), new DocumentTestRepository());
      await service.initialize(); await service.saveToken('unit-nonsecret-input', false);
      const view: string = JSON.stringify(service.viewState());
      documentServiceCheck(service.viewState().credential === DocumentCredentialStatus.Missing && view.indexOf('凭据新增') >= 0 && view.indexOf('201') >= 0 && view.indexOf('unit-nonsecret') < 0);
      documentServiceCheck(api.addedBytes.every((n: number): boolean => n === 0));
    } },
    { name: '写入已返回但确认失败公开状态不可用消息不被刷新覆盖', run: async (): Promise<void> => {
      const api: MineruTestAssetStore = new MineruTestAssetStore(); api.afterWriteCode = 24000010;
      const service: DocumentParseService = new DocumentParseService(new MineruCredentialStore('unit-no-files', api), new DocumentTestRepository());
      await service.initialize(); await service.saveToken('unit-nonsecret-input', false);
      documentServiceCheck(service.viewState().credential === DocumentCredentialStatus.Unavailable && service.viewState().message.indexOf('保存后属性确认') >= 0 && service.viewState().message.indexOf('24000010') >= 0);
      mineruTestNoSecretQueries(api);
    } }
  ];
  for (const replace of [false, true]) {
    for (const code of [201, 401, 24000003, 24000005, 24000008]) {
      tests.push({ name: `写入拒绝保留数值code ${replace ? 'update' : 'add'} ${code}`, run: async (): Promise<void> => {
        const api: MineruTestAssetStore = new MineruTestAssetStore(); api.writeCode = code;
        if (replace) { api.rows = [mineruTestAttributes()]; }
        const failure: DocumentParseFailure = await mineruTestSaveFailure(new MineruCredentialStore('unit-no-files', api), replace);
        documentServiceCheck(failure.stage === (replace ? '凭据更新' : '凭据新增') && failure.serviceCode === `${code}`);
        documentServiceCheck(failure.message.indexOf('unit-nonsecret-sdk-detail') < 0); mineruTestNoSecretQueries(api);
      } });
    }
  }
  return tests;
}
