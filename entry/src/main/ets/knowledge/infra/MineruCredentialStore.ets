import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { fileIo, ReadOptions, WriteOptions } from '@kit.CoreFileKit';
import { rcp } from '@kit.RemoteCommunicationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { MineruCredentialPort } from '../domain/DocumentParsePorts';
import { DocumentCredentialStatus, DocumentLeaseBinding, DocumentParseFailure, documentValidateToken } from '../domain/DocumentParseModels';

const MINERU_TOKEN_ALIAS: string = 'shuvi.m2.mineru.precision.token.v1';
const MINERU_KEY_ALIAS: string = 'shuvi.m2.parse.lease.aes256.v1';
function mineruAssetQuery(alias: string, kind: asset.ReturnType): asset.AssetMap {
  const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
  query.set(asset.Tag.ALIAS, new util.TextEncoder().encodeInto(alias)); query.set(asset.Tag.RETURN_TYPE, kind); return query;
}
function mineruAssetAlias(alias: string): asset.AssetMap {
  const query: asset.AssetMap = new Map<asset.Tag, asset.Value>(); query.set(asset.Tag.ALIAS, new util.TextEncoder().encodeInto(alias)); return query;
}
async function mineruAttributes(alias: string): Promise<asset.AssetMap[]> {
  return asset.query(mineruAssetQuery(alias, asset.ReturnType.ATTRIBUTES)).catch((error: BusinessError): asset.AssetMap[] => {
    if (error.code === 24000002) { return []; }
    throw new DocumentParseFailure('安全存储不可用或设备锁定', '属性查询');
  });
}
function mineruLeaseAAD(binding: DocumentLeaseBinding): string {
  return ['M2-LEASE-1', binding.taskId, binding.hash, `${binding.version}`, `${binding.credentialRevision}`,
    binding.purpose, `${binding.issuedAt}`, `${binding.expiresAt}`, binding.remoteExpiry].join('\n');
}
export class MineruCredentialStore implements MineruCredentialPort {
  private root: string;
  private generation: number = 0;
  private activeRequests: rcp.Request[] = [];
  private activeBytes: Uint8Array[] = [];
  constructor(filesDir: string) { this.root = `${filesDir}/knowledge_parse_v1`; }
  clearTransient(): void {
    this.generation++; for (const request of this.activeRequests) { request.headers = undefined; }
    for (const bytes of this.activeBytes) { bytes.fill(0); }
  }
  async status(): Promise<DocumentCredentialStatus> {
    try {
      const rows: asset.AssetMap[] = await mineruAttributes(MINERU_TOKEN_ALIAS);
      if (rows.length > 1) { return DocumentCredentialStatus.Unavailable; }
      if (rows.length === 1 && (rows[0].get(asset.Tag.ACCESSIBILITY) !== asset.Accessibility.DEVICE_UNLOCKED || rows[0].get(asset.Tag.SYNC_TYPE) !== asset.SyncType.NEVER)) { return DocumentCredentialStatus.Unavailable; }
      return rows.length === 1 ? DocumentCredentialStatus.Configured : DocumentCredentialStatus.Missing;
    } catch { return DocumentCredentialStatus.Unavailable; }
  }
  private async addSecret(alias: string, bytes: Uint8Array): Promise<void> {
    const attrs: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    attrs.set(asset.Tag.ALIAS, new util.TextEncoder().encodeInto(alias)); attrs.set(asset.Tag.SECRET, bytes);
    attrs.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_UNLOCKED); attrs.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER);
    attrs.set(asset.Tag.IS_PERSISTENT, false); attrs.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.THROW_ERROR);
    await asset.add(attrs);
  }
  async save(input: string, replace: boolean): Promise<DocumentCredentialStatus> {
    documentValidateToken(input); const bytes: Uint8Array = new util.TextEncoder().encodeInto(input);
    try {
      const current: DocumentCredentialStatus = await this.status();
      if (current === DocumentCredentialStatus.Unavailable || (current === DocumentCredentialStatus.Configured) !== replace) {
        throw new DocumentParseFailure('安全存储状态不符', '设置');
      }
      if (replace) {
        const attrs: asset.AssetMap = new Map<asset.Tag, asset.Value>(); attrs.set(asset.Tag.SECRET, bytes);
        await asset.update(mineruAssetAlias(MINERU_TOKEN_ALIAS), attrs);
      } else { await this.addSecret(MINERU_TOKEN_ALIAS, bytes); }
      const finalStatus: DocumentCredentialStatus = await this.status();
      if (finalStatus !== DocumentCredentialStatus.Configured) { throw new DocumentParseFailure('安全存储确认失败', '设置'); }
      return finalStatus;
    } catch { throw new DocumentParseFailure('安全存储写入失败或设备锁定', '设置'); }
    finally { bytes.fill(0); this.clearTransient(); }
  }
  async remove(): Promise<DocumentCredentialStatus> {
    try {
      const state: DocumentCredentialStatus = await this.status();
      if (state === DocumentCredentialStatus.Unavailable) { throw new DocumentParseFailure('安全存储不可用', '设置'); }
      if (state === DocumentCredentialStatus.Configured) { await asset.remove(mineruAssetAlias(MINERU_TOKEN_ALIAS)); }
      const finalStatus: DocumentCredentialStatus = await this.status();
      if (finalStatus !== DocumentCredentialStatus.Missing) { throw new DocumentParseFailure('凭据删除未确认', '设置'); }
      return finalStatus;
    } catch { throw new DocumentParseFailure('安全存储删除失败或设备锁定', '设置'); }
    finally { this.clearTransient(); }
  }
  private async secret(alias: string): Promise<Uint8Array> {
    const rows: asset.AssetMap[] = await asset.query(mineruAssetQuery(alias, asset.ReturnType.ALL));
    if (rows.length !== 1) { throw new DocumentParseFailure('安全凭据不可用', '认证'); }
    const raw: asset.Value | undefined = rows[0].get(asset.Tag.SECRET);
    if (!(raw instanceof Uint8Array)) { throw new DocumentParseFailure('安全凭据类型非法', '认证'); }
    return raw;
  }
  async authenticatedFetch(request: rcp.Request, session: rcp.Session, check: () => void): Promise<rcp.Response> {
    const epoch: number = this.generation; const bytes: Uint8Array = await this.secret(MINERU_TOKEN_ALIAS);
    this.activeRequests.push(request); this.activeBytes.push(bytes);
    try {
      if (epoch !== this.generation) { throw new DocumentParseFailure('认证世代失效', '控制请求'); }
      check(); const token: string = util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(bytes);
      documentValidateToken(token);
      const headers: rcp.RequestHeaders = { 'authorization': `Bearer ${token}`, 'content-type': 'application/json', 'accept': 'application/json' };
      request.headers = headers; check(); return await session.fetch(request);
    } catch (error) { if (error instanceof DocumentParseFailure) { throw error; } throw new DocumentParseFailure('控制请求失败、鉴权或网络不可用', '控制请求'); }
    finally {
      bytes.fill(0); request.headers = undefined;
      this.activeRequests = this.activeRequests.filter((item: rcp.Request): boolean => item !== request);
      this.activeBytes = this.activeBytes.filter((item: Uint8Array): boolean => item !== bytes);
    }
  }
  private async key(allowCreate: boolean): Promise<cryptoFramework.SymKey> {
    const attrs: asset.AssetMap[] = await mineruAttributes(MINERU_KEY_ALIAS);
    if (attrs.length === 0) {
      if (!allowCreate) { throw new DocumentParseFailure('原地址密钥缺失，租约不可恢复', '安全存储'); }
      const random: cryptoFramework.DataBlob = await cryptoFramework.createRandom().generateRandom(32);
      try { await this.addSecret(MINERU_KEY_ALIAS, random.data); } finally { random.data.fill(0); }
    } else if (attrs.length !== 1 || attrs[0].get(asset.Tag.ACCESSIBILITY) !== asset.Accessibility.DEVICE_UNLOCKED || attrs[0].get(asset.Tag.SYNC_TYPE) !== asset.SyncType.NEVER) { throw new DocumentParseFailure('地址密钥身份异常', '安全存储'); }
    const bytes: Uint8Array = await this.secret(MINERU_KEY_ALIAS);
    try {
      if (bytes.length !== 32) { throw new DocumentParseFailure('地址密钥长度异常', '安全存储'); }
      const blob: cryptoFramework.DataBlob = { data: bytes };
      return await cryptoFramework.createSymKeyGenerator('AES256').convertKey(blob);
    } finally { bytes.fill(0); }
  }
  private path(id: string): string {
    if (!new RegExp('^lease-[a-zA-Z0-9_-]{1,100}$').test(id)) { throw new DocumentParseFailure('租约身份非法', '缓存'); }
    return `${this.root}/${id}`;
  }
  private async ensureRoot(): Promise<void> {
    if (!(await fileIo.access(this.root))) { await fileIo.mkdir(this.root); }
    const stat: fileIo.Stat = await fileIo.lstat(this.root);
    if (!stat.isDirectory() || stat.isSymbolicLink()) { throw new DocumentParseFailure('安全缓存目录非法', '缓存'); }
  }
  async sealLease(binding: DocumentLeaseBinding, address: string): Promise<void> {
    await this.ensureRoot(); const path: string = this.path(binding.id);
    if (address.length === 0 || address.length > 16384 || await fileIo.access(path)) { throw new DocumentParseFailure('租约长度或身份非法', '缓存'); }
    const key: cryptoFramework.SymKey = await this.key(true);
    const nonce: cryptoFramework.DataBlob = await cryptoFramework.createRandom().generateRandom(12);
    const aad: Uint8Array = new util.TextEncoder().encodeInto(mineruLeaseAAD(binding));
    const params: cryptoFramework.GcmParamsSpec = { algName: 'GcmParamsSpec', iv: nonce, aad: { data: aad }, authTag: { data: new Uint8Array(16) } };
    const plain: Uint8Array = new util.TextEncoder().encodeInto(address);
    try {
      const cipher: cryptoFramework.Cipher = cryptoFramework.createCipher('AES256|GCM');
      await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, key, params);
      const blob: cryptoFramework.DataBlob = { data: plain }; const encrypted: cryptoFramework.DataBlob = await cipher.doFinal(blob);
      const header: Uint8Array = new util.TextEncoder().encodeInto(`${mineruLeaseAAD(binding)}\n`);
      const output: Uint8Array = new Uint8Array(header.length + 12 + encrypted.data.length);
      output.set(header); output.set(nonce.data, header.length); output.set(encrypted.data, header.length + 12);
      const file: fileIo.File = await fileIo.open(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.NOFOLLOW);
      try {
        const options: WriteOptions = { offset: 0, length: output.length };
        if (await fileIo.write(file.fd, output.buffer, options) !== output.length) { throw new DocumentParseFailure('租约写入不完整', '缓存'); }
        await fileIo.fsync(file.fd);
      } finally { await fileIo.close(file); }
    } catch { if (await fileIo.access(path)) { await fileIo.unlink(path); } throw new DocumentParseFailure('租约加密保存失败', '缓存'); }
    finally { plain.fill(0); key.clearMem(); }
  }
  async withLease(binding: DocumentLeaseBinding, consume: (address: string) => Promise<void>): Promise<void> {
    await this.ensureRoot(); const file: fileIo.File = await fileIo.open(this.path(binding.id), fileIo.OpenMode.READ_ONLY | fileIo.OpenMode.NOFOLLOW);
    let data: Uint8Array = new Uint8Array(0);
    try {
      const stat: fileIo.Stat = await fileIo.stat(file.fd);
      if (!stat.isFile() || stat.size < 50 || stat.size > 20000) { throw new DocumentParseFailure('租约文件非法', '恢复'); }
      data = new Uint8Array(stat.size); const options: ReadOptions = { offset: 0, length: data.length };
      if (await fileIo.read(file.fd, data.buffer, options) !== data.length) { throw new DocumentParseFailure('租约文件截断', '恢复'); }
    } finally { await fileIo.close(file); }
    let end: number = 0; let lines: number = 0;
    while (end < data.length && lines < 9) { if (data[end++] === 10) { lines++; } }
    if (lines !== 9 || end + 28 >= data.length) { throw new DocumentParseFailure('租约布局非法', '恢复'); }
    const header: string = util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(data.slice(0, end - 1));
    const fields: string[] = header.split('\n');
    if (fields.length !== 9 || fields[0] !== 'M2-LEASE-1' || fields[1] !== binding.taskId || fields[2] !== binding.hash || fields[3] !== `${binding.version}` || fields[4] !== `${binding.credentialRevision}` || fields[5] !== binding.purpose) {
      throw new DocumentParseFailure('租约关联不符', '恢复');
    }
    const issued: number = Number(fields[6]); const expires: number = Number(fields[7]);
    if (!Number.isSafeInteger(issued) || !Number.isSafeInteger(expires) || expires <= issued || expires - issued > (binding.purpose === 'UPLOAD' ? 86400000 : 600000) || Date.now() >= expires || issued > Date.now()) {
      await this.removeLeases([binding.id]); throw new DocumentParseFailure('租约过期或时间非法', '恢复');
    }
    const key: cryptoFramework.SymKey = await this.key(false);
    const params: cryptoFramework.GcmParamsSpec = { algName: 'GcmParamsSpec', iv: { data: data.slice(end, end + 12) },
      aad: { data: data.slice(0, end - 1) }, authTag: { data: data.slice(data.length - 16) } };
    let plain: cryptoFramework.DataBlob | undefined = undefined;
    try {
      const cipher: cryptoFramework.Cipher = cryptoFramework.createCipher('AES256|GCM'); await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, key, params);
      const blob: cryptoFramework.DataBlob = { data: data.slice(end + 12, data.length - 16) };
      plain = await cipher.doFinal(blob);
      const address: string = util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(plain.data); await consume(address);
    } catch (error) { if (error instanceof DocumentParseFailure) { throw error; } throw new DocumentParseFailure('租约认证或读取失败', '恢复'); }
    finally { plain?.data.fill(0); data.fill(0); key.clearMem(); }
  }
  async removeLeases(ids: string[]): Promise<void> {
    await this.ensureRoot();
    for (const id of ids) {
      if (id.length === 0) { continue; } const path: string = this.path(id);
      if (!(await fileIo.access(path))) { continue; }
      const stat: fileIo.Stat = await fileIo.lstat(path);
      if (!stat.isFile() || stat.isSymbolicLink()) { throw new DocumentParseFailure('拒绝越界清理', '租约'); }
      await fileIo.unlink(path);
    }
  }
  async reconcileLeases(keepIds: string[]): Promise<void> {
    await this.ensureRoot(); const names: string[] = await fileIo.listFile(this.root);
    for (const name of names) {
      if (!new RegExp('^lease-m2-[a-f0-9]{32}-(upload|result-[0-9]+-[0-9]+)$').test(name)) { continue; }
      if (keepIds.indexOf(name) < 0) { await this.removeLeases([name]); continue; }
      const file: fileIo.File = await fileIo.open(this.path(name), fileIo.OpenMode.READ_ONLY | fileIo.OpenMode.NOFOLLOW);
      let header: Uint8Array = new Uint8Array(0);
      try {
        const stat: fileIo.Stat = await fileIo.stat(file.fd); if (!stat.isFile() || stat.size > 20000) { throw new DocumentParseFailure('租约缓存非法', '对账'); }
        const block: ArrayBuffer = new ArrayBuffer(Math.min(stat.size, 512)); const options: ReadOptions = { offset: 0, length: block.byteLength };
        const n: number = await fileIo.read(file.fd, block, options); header = new Uint8Array(block, 0, n);
      } finally { await fileIo.close(file); }
      let lines: number = 0; let at: number = 0; while (at < header.length && lines < 9) { if (header[at++] === 10) { lines++; } }
      if (lines !== 9) { throw new DocumentParseFailure('租约头不完整', '对账'); }
      const text: string = util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(header.slice(0, at)); const fields: string[] = text.split('\n');
      const expires: number = Number(fields[7]);
      if (!Number.isSafeInteger(expires) || expires <= Date.now()) { await this.removeLeases([name]); }
    }
  }
}
