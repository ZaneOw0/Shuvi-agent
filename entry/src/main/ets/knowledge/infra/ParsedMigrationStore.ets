import { relationalStore } from '@kit.ArkData';
import { ParsedMigrationInput } from '../domain/ParsedMigrationModels';
import { ParsedLegacyLink, ParsedFailure } from '../domain/ParsedDocumentModels';

export async function migrationAssertLegacy(tx: relationalStore.Transaction, namespace: string, id: string, active: string, epoch: number, hash: string): Promise<void> {
  const sql: string=namespace==='Text'?'SELECT active,version,hash,0 FROM text_doc WHERE id=?':namespace==='Pdf'?'SELECT active_content,epoch,original_hash,tombstone FROM kb_document WHERE id=?':namespace==='Image'?'SELECT d.active_generation,d.epoch,o.hash,d.tombstone FROM kb_image_document d JOIN kb_image_original o ON o.asset=d.active_original WHERE d.id=?':namespace==='Docx'?'SELECT d.active_generation,d.epoch,o.hash,d.tombstone FROM kb_docx_document d JOIN kb_docx_original o ON o.asset=d.active_original WHERE d.id=?':'';
  if (sql.length===0) { throw new ParsedFailure('UnknownLegacyNamespace','migration-cas'); }
  const rows: relationalStore.ResultSet=await tx.querySql(sql,[id]);
  try { if (!rows.goToNextRow() || rows.getString(0)!==active || rows.getLong(1)!==epoch || rows.getString(2)!==hash || rows.getLong(3)!==0) { throw new ParsedFailure('LegacyChangedOrDeleted','migration-cas'); } } finally { rows.close(); }
}
export async function migrationCheckInput(tx: relationalStore.Transaction, input: ParsedMigrationInput): Promise<void> {
  await migrationAssertLegacy(tx,input.namespace,input.legacyId,input.active,input.epoch,input.sourceHash);
  const sql: string=input.namespace==='Text'?'SELECT snapshot,hash FROM text_generation WHERE id=?':input.namespace==='Pdf'?'SELECT snapshot,snapshot_hash FROM kb_content_generation WHERE id=?':input.namespace==='Image'?'SELECT wire,hash FROM kb_image_generation WHERE id=?':'SELECT asset,hash FROM kb_docx_generation WHERE id=?';
  const rows: relationalStore.ResultSet=await tx.querySql(sql,[input.active]);
  try { if (!rows.goToNextRow() || rows.getString(0)!==input.snapshotAsset || rows.getString(1)!==input.snapshotHash) { throw new ParsedFailure('LegacySnapshotIdentityChanged','migration-cas'); } } finally { rows.close(); }
  await migrationCheckSourceVersion(tx,input.namespace,input.legacyId,input.sourceVersion,input.archived);
  const tables: relationalStore.ResultSet=await tx.querySql("SELECT name FROM sqlite_master WHERE type='table' AND name IN ('kb_cleanup','kb_image_cleanup','kb_docx_cleanup')"); const names: string[]=[]; try { while (tables.goToNextRow()) { names.push(tables.getString(0)); } } finally { tables.close(); }
  for (const source of input.sources) {
    const table: string=source.owner==='ImageSnapshotAssets'?'kb_image_cleanup':source.owner==='DocxSnapshotAssets'?'kb_docx_cleanup':'';
    if (table.length>0 && names.indexOf(table)>=0) { const cleanup: relationalStore.ResultSet=await tx.querySql(`SELECT asset FROM ${table} WHERE asset=? AND state IN ('Claimed','Done')`,[source.id]); try { if (cleanup.goToNextRow()) { throw new ParsedFailure('LegacyOwnerCleanupClaimed','migration-hold'); } } finally { cleanup.close(); } }
  }
  if (names.indexOf('kb_cleanup')>=0 && input.namespace==='Pdf') { const cleanup: relationalStore.ResultSet=await tx.querySql('SELECT claim FROM kb_cleanup WHERE generation=? AND claim<>?',[input.active,'']); try { if (cleanup.goToNextRow()) { throw new ParsedFailure('LegacyPdfCleanupClaimed','migration-hold'); } } finally { cleanup.close(); } }
}
async function migrationCheckSourceVersion(tx: relationalStore.Transaction, namespace: string, id: string, version: number, archived: boolean): Promise<void> {
  const sql: string=namespace==='Text'?'SELECT version,archived FROM text_doc WHERE id=?':namespace==='Pdf'?'SELECT original_version,archived FROM kb_document WHERE id=?':namespace==='Image'?'SELECT o.version,d.archived FROM kb_image_document d JOIN kb_image_original o ON o.asset=d.active_original WHERE d.id=?':'SELECT o.version,d.archived FROM kb_docx_document d JOIN kb_docx_original o ON o.asset=d.active_original WHERE d.id=?';
  const rows: relationalStore.ResultSet=await tx.querySql(sql,[id]); try { if (!rows.goToNextRow() || rows.getLong(0)!==version || (rows.getLong(1)===1)!==archived) { throw new ParsedFailure('LegacyVersionOrArchiveChanged','migration-cas'); } } finally { rows.close(); }
}
export async function migrationCommitLink(tx: relationalStore.Transaction, link: ParsedLegacyLink): Promise<void> {
  const sql: string=link.namespace==='Text'?'SELECT hash,snapshot FROM text_generation WHERE id=?':link.namespace==='Pdf'?'SELECT snapshot_hash,snapshot FROM kb_content_generation WHERE id=?':link.namespace==='Image'?'SELECT hash,wire FROM kb_image_generation WHERE id=?':'SELECT hash,asset FROM kb_docx_generation WHERE id=?';
  const current: relationalStore.ResultSet=await tx.querySql(sql,[link.legacyGeneration]); try { if (!current.goToNextRow() || current.getString(0)!==link.legacyHash || current.getString(1)!==link.snapshotAsset) { throw new ParsedFailure('LegacySnapshotHashChanged','migration-cas'); } } finally { current.close(); }
  await migrationCheckSourceVersion(tx,link.namespace,link.legacyId,link.sourceVersion,link.archived);
  const old: relationalStore.ResultSet=await tx.querySql('SELECT legacy_wire,legacy_hash,doc,generation,epoch,old_active FROM upd_legacy_link WHERE namespace=? AND legacy_id=? AND legacy_generation=?',[link.namespace,link.legacyId,link.legacyGeneration]);
  try { if (old.goToNextRow() && (old.getString(0)!==link.legacyWire || old.getString(1)!==link.legacyHash || old.getString(2)!==link.documentKey || old.getString(3)!==link.generation || old.getLong(4)!==link.epoch || old.getString(5)!==link.oldActive)) { throw new ParsedFailure('LegacyLinkConflict','migration-cas'); } } finally { old.close(); }
  await tx.execute('INSERT INTO upd_legacy_link VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(namespace,legacy_id,legacy_generation) DO UPDATE SET state=excluded.state',[link.namespace,link.legacyId,link.legacyGeneration,link.legacyWire,link.legacyHash,link.documentKey,link.generation,link.epoch,link.oldActive,'Committed']);
}
