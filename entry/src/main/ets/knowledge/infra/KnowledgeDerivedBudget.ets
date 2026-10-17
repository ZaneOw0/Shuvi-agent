import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { KnowledgeStorageScope } from '../domain/KnowledgeStorageScope';
import { KnowledgeFailure, PdfBudget } from '../domain/PdfKnowledgeModels';

export class KnowledgeDerivedUsage {
  assetsPhysical: number = 0; vectorPhysical: number = 0; sharedNonReclaimable: number = 0; metadataReserved: number = 0; pendingReserved: number = 0;
  total(): number { return this.assetsPhysical+this.vectorPhysical+Math.max(this.sharedNonReclaimable,this.metadataReserved)+this.pendingReserved; }
}
export interface KnowledgePhysicalBudgetPort { usage(): Promise<KnowledgeDerivedUsage>; }
export class KnowledgeDerivedBudget implements KnowledgePhysicalBudgetPort {
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
    const root: string = `${this.context.databaseDir}/rdb`;
    if (await fileIo.access(root)) {
      for (const name of await fileIo.listFile(root)) {
        // Count the entire dedicated vector family, including ctrl/redo/undo,
        // WAL and directories. Never attribute the shared M1 database to PDF.
        if (name === this.scope.vectorDatabaseName || name.startsWith(this.scope.vectorDatabaseName+'.') || name.startsWith(this.scope.vectorDatabaseName+'-')) { usage.vectorPhysical += await this.tree(`${root}/${name}`); }
        if (name === this.scope.databaseName || name.startsWith(this.scope.databaseName+'.') || name.startsWith(this.scope.databaseName+'-')) { usage.sharedNonReclaimable += await this.tree(`${root}/${name}`); }
      }
    } return usage;
  }
}
