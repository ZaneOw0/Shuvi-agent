import { common, bundleManager } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { relationalStore } from '@kit.ArkData';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { pdfCodecUtf8 } from '../pipeline/PdfSnapshotCodec';
import { KnowledgeFailure } from '../domain/PdfKnowledgeModels';
export class CapabilityAuditRecord {
  kind: string = ''; app: string = ''; environment: string = ''; implementation: string = ''; suite: string = '';
  state: string = ''; checkedAt: number = 0; digest: string = '';
}
export class CapabilityAuditGate {
  private checked: Promise<void> | undefined;
  require(audit: KnowledgeCapabilityAudit, descriptor: CapabilityAuditRecord, check: () => Promise<void>): Promise<void> {
    if (this.checked === undefined) { this.checked = this.execute(audit,descriptor,check); } return this.checked;
  }
  private async execute(audit: KnowledgeCapabilityAudit, descriptor: CapabilityAuditRecord, check: () => Promise<void>): Promise<void> {
    const previous = await audit.read(descriptor); if (previous?.state === 'Invalidated') { previous.kind = descriptor.kind+'Invalidated'; await audit.save(previous); }
    descriptor.state = 'Checking'; await audit.save(descriptor);
    try { await check(); descriptor.state = 'Available'; await audit.save(descriptor); }
    catch (error) { descriptor.state = error instanceof KnowledgeFailure && error.category.includes('Release') ? 'Releasing' : 'Failed'; await audit.save(descriptor); if (error instanceof Error) { throw error; } throw new KnowledgeFailure('CapabilityCheckFailed','capability'); }
  }
}
export class KnowledgeCapabilityAudit {
  private context: common.Context; private name: string;
  constructor(context: common.Context, name: string = 'shuvi_capability_audit_v1.db') { this.context = context; if (!new RegExp('^(shuvi_capability_audit_v1|shuvi_r2_[a-f0-9]{16}_audit)\\.db$').test(name)) { throw new KnowledgeFailure('AuditScopeRejected','capability'); } this.name = name; }
  async identity(kind: string, implementation: string, suite: string): Promise<CapabilityAuditRecord> {
    const info = await bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
    const record = new CapabilityAuditRecord(); record.kind = kind; record.app = `${info.name}|${info.versionCode}|${info.versionName}`; record.environment = `${deviceInfo.sdkApiVersion}|${deviceInfo.osFullName}|${deviceInfo.abiList}`; record.implementation = implementation; record.suite = suite; return record;
  }
  private async hash(record: CapabilityAuditRecord): Promise<string> { const digest = cryptoFramework.createMd('SHA256'); await digest.update({ data: pdfCodecUtf8(JSON.stringify([record.kind,record.app,record.environment,record.implementation,record.suite,record.state,record.checkedAt])) }); let hex: string = ''; for (const byte of (await digest.digest()).data) { hex += byte.toString(16).padStart(2,'0'); } return hex; }
  private async open(): Promise<relationalStore.RdbStore> {
    const config: relationalStore.StoreConfig = { name: this.name, securityLevel: relationalStore.SecurityLevel.S3, vector: false }; const store = await relationalStore.getRdbStore(this.context,config);
    try { const tx = await store.createTransaction();
      try { await tx.execute('CREATE TABLE IF NOT EXISTS capability_layout (version INTEGER PRIMARY KEY)'); const version = await tx.querySql('SELECT version FROM capability_layout'); let empty: boolean = true; try { if (version.goToNextRow()) { empty = false; if (version.getLong(0) !== 1 || version.goToNextRow()) { throw new KnowledgeFailure('CapabilityAuditLayout','capability'); } } } finally { version.close(); }
        if (empty) { await tx.execute('CREATE TABLE capability_audit (kind TEXT PRIMARY KEY,app TEXT,environment TEXT,implementation TEXT,suite TEXT,state TEXT,checked INTEGER,digest TEXT)'); await tx.execute('INSERT INTO capability_layout VALUES(1)'); }
        const schema = await tx.querySql("SELECT sql FROM sqlite_master WHERE name='capability_audit'"); try { if (!schema.goToNextRow() || schema.getString(0) !== 'CREATE TABLE capability_audit (kind TEXT PRIMARY KEY,app TEXT,environment TEXT,implementation TEXT,suite TEXT,state TEXT,checked INTEGER,digest TEXT)') { throw new KnowledgeFailure('CapabilityAuditSchema','capability'); } } finally { schema.close(); } await tx.commit();
      } catch (error) { await tx.rollback(); if (error instanceof Error) { throw error; } throw new KnowledgeFailure('CapabilityAuditMigration','capability'); }
      return store;
    } catch (error) { await store.close(); if (error instanceof Error) { throw error; } throw new KnowledgeFailure('CapabilityAuditOpen','capability'); }
  }
  async read(expected: CapabilityAuditRecord): Promise<CapabilityAuditRecord | undefined> {
    const store = await this.open(); try { const rows = await store.querySql('SELECT * FROM capability_audit WHERE kind=?',[expected.kind]); try { if (!rows.goToNextRow()) { return undefined; } const record = new CapabilityAuditRecord(); record.kind = rows.getString(0); record.app = rows.getString(1); record.environment = rows.getString(2); record.implementation = rows.getString(3); record.suite = rows.getString(4); record.state = rows.getString(5); record.checkedAt = rows.getLong(6); record.digest = rows.getString(7); if (record.digest !== await this.hash(record)) { throw new KnowledgeFailure('CapabilityAuditDigest','capability'); } if (record.app !== expected.app || record.environment !== expected.environment || record.implementation !== expected.implementation || record.suite !== expected.suite) { record.state = 'Invalidated'; } return record; } finally { rows.close(); } } finally { await store.close(); }
  }
  async save(record: CapabilityAuditRecord): Promise<void> {
    record.checkedAt = Date.now(); record.digest = await this.hash(record); const store = await this.open(); try { await store.executeSql('INSERT OR REPLACE INTO capability_audit VALUES(?,?,?,?,?,?,?,?)',[record.kind,record.app,record.environment,record.implementation,record.suite,record.state,record.checkedAt,record.digest]); } finally { await store.close(); }
    hilog.info(0x0001,'SHUVI_R2','%{public}s',`R2_CAPABILITY kind=${record.kind} state=${record.state} checked=${record.checkedAt} digest=${record.digest} disk_grants=0`);
  }
}
