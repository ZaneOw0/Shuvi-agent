import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { KnowledgeStorageScope } from '../domain/KnowledgeStorageScope';
import { KnowledgeFailure, PdfBudget } from '../domain/PdfKnowledgeModels';
import { KnowledgeStoreHost } from './KnowledgeStoreHost';
import { ParsedPhysicalUsagePort } from '../domain/ParsedDocumentPorts';

export class KnowledgeDerivedUsage {
  assetsPhysical: number = 0; vectorPhysical: number = 0; sharedNonReclaimable: number = 0; metadataReserved: number = 0; pendingReserved: number = 0;
  total(): number { return this.assetsPhysical+this.vectorPhysical+Math.max(this.sharedNonReclaimable,this.metadataReserved)+this.pendingReserved; }
}
export interface KnowledgePhysicalBudgetPort { usage(): Promise<KnowledgeDerivedUsage>; }
export class KnowledgeDerivedBudget implements KnowledgePhysicalBudgetPort, ParsedPhysicalUsagePort {
  private context: common.Context; private scope: KnowledgeStorageScope;
  constructor(context: common.Context, scope: KnowledgeStorageScope = KnowledgeStorageScope.production()) { this.context = context; this.scope = scope; }
  private async tree(root: string, depth: number = 0): Promise<number> {
    if (depth > 6) { throw new KnowledgeFailure('DerivedDirectoryDepth','budget'); }
    if (!(await fileIo.access(root))) { return 0; } const stat: fileIo.Stat = await fileIo.lstat(root);
    if (stat.isSymbolicLink()) { throw new KnowledgeFailure('DerivedSymlinkRejected','budget'); }
    if (stat.isFile()) { return Math.max(Math.ceil(stat.size/4096)*4096,4096); }
    if (!stat.isDirectory()) { throw new KnowledgeFailure('DerivedFileTypeRejected','budget'); }
    const names: string[] = await fileIo.listFile(root); if (names.length > 20001) { throw new KnowledgeFailure('DerivedFileCount','budget'); }
    let total: number = 4096; for (const name of names) { total += await this.tree(`${root}/${name}`,depth+1); if (total > PdfBudget.derivedBytes) { throw new KnowledgeFailure('DerivedBudget','budget'); } } return total;
  }
  async usage(): Promise<KnowledgeDerivedUsage> {
    const usage: KnowledgeDerivedUsage = new KnowledgeDerivedUsage();
    usage.assetsPhysical = await this.tree(`${this.context.filesDir}/${this.scope.derivedDirectory}`)+await this.tree(`${this.context.cacheDir}/${this.scope.derivedDirectory}`);
    const unifiedDirectory: string = this.scope.testing ? `knowledge_unified_v1_${this.scope.key}` : 'knowledge_unified_v1';
    usage.assetsPhysical += await this.tree(`${this.context.filesDir}/${unifiedDirectory}`)+await this.tree(`${this.context.cacheDir}/${unifiedDirectory}`);
    // The recursive derived root includes /image and /docx exactly once.
    if (!this.scope.testing) {
      // Conservative shared accounting includes parse staging and M1 snapshot roots.
      usage.assetsPhysical += await this.tree(`${this.context.filesDir}/knowledge_parse_v1`)+await this.tree(`${this.context.cacheDir}/knowledge_parse_v1`)+await this.tree(`${this.context.filesDir}/knowledge_user_v1`);
    }
    const root: string = `${this.context.databaseDir}/rdb`;
    if (await fileIo.access(root)) {
      for (const name of await fileIo.listFile(root)) {
        // Count the entire dedicated vector family, including ctrl/redo/undo,
        // WAL and directories. Never attribute the shared M1 database to PDF.
        if (name === this.scope.vectorDatabaseName || name.startsWith(this.scope.vectorDatabaseName+'.') || name.startsWith(this.scope.vectorDatabaseName+'-')) { usage.vectorPhysical += await this.tree(`${root}/${name}`); }
        if (name === this.scope.databaseName || name.startsWith(this.scope.databaseName+'.') || name.startsWith(this.scope.databaseName+'-')) { usage.sharedNonReclaimable += await this.tree(`${root}/${name}`); }
        const parseName: string = this.scope.testing ? `shuvi_r2_parse_${this.scope.key}.db` : 'shuvi_parse_stage_v1.db';
        if (name === parseName || name.startsWith(parseName+'.') || name.startsWith(parseName+'-')) { usage.sharedNonReclaimable += await this.tree(`${root}/${name}`); }
      }
    }
    const host: KnowledgeStoreHost = KnowledgeStoreHost.forContext(this.context,this.scope);
    if (host.imageReady) {
      const rows = await host.requireStore().querySql("SELECT COALESCE(SUM(bytes),0) FROM kb_image_reservation WHERE state='Reserved'");
      try { if (!rows.goToNextRow() || rows.getLong(0) < 0) { throw new KnowledgeFailure('ImageReservationReadFailed','budget'); } usage.pendingReserved = rows.getLong(0); } finally { rows.close(); }
    }
    if (host.docxReady) {
      const rows = await host.requireStore().querySql("SELECT COALESCE(SUM(bytes),0) FROM kb_docx_reservation WHERE state='Reserved'");
      try { if (!rows.goToNextRow() || rows.getLong(0) < 0) { throw new KnowledgeFailure('DocxReservationReadFailed','budget'); } usage.pendingReserved += rows.getLong(0); } finally { rows.close(); }
    }
    if (host.unifiedReady) {
      const rows: relationalStore.ResultSet = await host.requireStore().querySql('SELECT path,reserved FROM upd_asset_write WHERE reserved>0');
      try { while (rows.goToNextRow()) {
        const relative: string = rows.getString(0); const reserved: number = rows.getLong(1);
        if (!new RegExp('^(images|snapshots|annotations|history)/[A-Za-z0-9_-]+$').test(relative) || reserved < 0) { throw new KnowledgeFailure('UnifiedReservationInvalid','budget'); }
        const path: string = `${this.context.filesDir}/${unifiedDirectory}/${relative}`;
        // A partially materialized file is already in tree(); reserve only its remainder.
        let materialized: number = 0;
        for (const candidate of [path,`${path}-pending`]) { if (await fileIo.access(candidate)) { materialized += await this.tree(candidate); } }
        usage.pendingReserved += Math.max(0,reserved-materialized);
      } } finally { rows.close(); }
    }
    return usage;
  }
  async totalBytes(): Promise<number> { return (await this.usage()).total(); }
}
