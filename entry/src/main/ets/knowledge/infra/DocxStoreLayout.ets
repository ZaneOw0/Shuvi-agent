import { relationalStore } from '@kit.ArkData';
import { DocxFailure, DocxLimits } from '../domain/DocxKnowledgeModels';
import { parsedPublicationBudget } from './ParsedPublicationBudget';

export const DOCX_STORE_LAYOUT: string = 'KB-DOCX-EXT-1';
export const DOCX_STORE_DDL: string[] = [
  'CREATE TABLE kb_docx_meta (id TEXT PRIMARY KEY,value TEXT NOT NULL)',
  'CREATE TABLE kb_docx_document (id TEXT PRIMARY KEY,title TEXT NOT NULL,epoch INTEGER NOT NULL,archived INTEGER NOT NULL,tombstone INTEGER NOT NULL,active_original TEXT NOT NULL,active_generation TEXT NOT NULL,chunks INTEGER NOT NULL,stage TEXT NOT NULL)',
  'CREATE TABLE kb_docx_original (asset TEXT PRIMARY KEY,doc TEXT NOT NULL,source TEXT NOT NULL,version INTEGER NOT NULL,title TEXT NOT NULL,hash TEXT NOT NULL,bytes INTEGER NOT NULL,main_part TEXT NOT NULL,saved INTEGER NOT NULL)',
  'CREATE TABLE kb_docx_job (id TEXT PRIMARY KEY,doc TEXT NOT NULL,generation TEXT UNIQUE NOT NULL,original TEXT NOT NULL,epoch INTEGER NOT NULL,old_active TEXT NOT NULL,report TEXT NOT NULL,snapshot TEXT NOT NULL,stage TEXT NOT NULL,checkpoint TEXT NOT NULL,failure TEXT NOT NULL,result_binding TEXT NOT NULL)',
  'CREATE TABLE kb_docx_generation (id TEXT PRIMARY KEY,doc TEXT NOT NULL,original TEXT NOT NULL,epoch INTEGER NOT NULL,state TEXT NOT NULL,asset TEXT NOT NULL,hash TEXT NOT NULL,report TEXT NOT NULL,expected INTEGER NOT NULL)',
  'CREATE TABLE kb_docx_chunk (id TEXT PRIMARY KEY,doc TEXT NOT NULL,generation TEXT NOT NULL,ordinal INTEGER NOT NULL,text TEXT NOT NULL,embedding_text TEXT NOT NULL,input_hash TEXT NOT NULL,locator TEXT NOT NULL)',
  'CREATE TABLE kb_docx_asset (id TEXT PRIMARY KEY,doc TEXT NOT NULL,owner TEXT NOT NULL,hash TEXT NOT NULL,bytes INTEGER NOT NULL,generation TEXT NOT NULL,role TEXT NOT NULL,pins INTEGER NOT NULL)',
  'CREATE TABLE kb_docx_lease (id TEXT PRIMARY KEY,doc TEXT NOT NULL,asset TEXT NOT NULL,owner TEXT NOT NULL,epoch INTEGER NOT NULL)',
  'CREATE TABLE kb_docx_release (id TEXT PRIMARY KEY,resource TEXT NOT NULL,state TEXT NOT NULL,failure TEXT NOT NULL)',
  'CREATE TABLE kb_docx_cleanup (id TEXT PRIMARY KEY,doc TEXT NOT NULL,asset TEXT NOT NULL,owner TEXT NOT NULL,state TEXT NOT NULL,failure TEXT NOT NULL)',
  'CREATE TABLE kb_docx_reservation (id TEXT PRIMARY KEY,owner TEXT NOT NULL,bytes INTEGER NOT NULL,state TEXT NOT NULL)',
  'CREATE TABLE kb_docx_vector (id TEXT PRIMARY KEY,doc TEXT NOT NULL,content TEXT NOT NULL,space TEXT NOT NULL,job TEXT UNIQUE NOT NULL,epoch INTEGER NOT NULL,state TEXT NOT NULL,expected INTEGER NOT NULL,grant_id TEXT NOT NULL,snapshot TEXT NOT NULL,config TEXT NOT NULL,session TEXT NOT NULL,window INTEGER NOT NULL,failure TEXT NOT NULL)',
  'CREATE TABLE kb_docx_vector_input (generation TEXT NOT NULL,chunk TEXT NOT NULL,input_hash TEXT NOT NULL,state TEXT NOT NULL,readback_hash TEXT NOT NULL,PRIMARY KEY(generation,chunk))',
  'CREATE TABLE kb_docx_vector_mirror (doc TEXT PRIMARY KEY,content TEXT NOT NULL,generation TEXT NOT NULL,space TEXT NOT NULL,epoch INTEGER NOT NULL,revision INTEGER NOT NULL,state TEXT NOT NULL)'
];
export function docxTableNames(): string[] { return DOCX_STORE_DDL.map((ddl: string): string => ddl.slice(13,ddl.indexOf(' ('))); }
export async function docxVerifyExisting(tx: relationalStore.Transaction): Promise<boolean> {
  const names: string[] = docxTableNames(); let count: number = 0;
  const rows: relationalStore.ResultSet = await tx.querySql("SELECT name,sql FROM sqlite_master WHERE type='table' AND name GLOB 'kb_docx_*'");
  try { while (rows.goToNextRow()) {
    const at: number = names.indexOf(rows.getString(0));
    if (at < 0 || rows.getString(1) !== DOCX_STORE_DDL[at]) { throw new DocxFailure('DocxLayoutMismatch','migration'); } count++;
  } } finally { rows.close(); }
  if (count === 0) { return false; }
  if (count !== names.length) { throw new DocxFailure('DocxLayoutIncomplete','migration'); }
  const meta: relationalStore.ResultSet = await tx.querySql('SELECT id,value FROM kb_docx_meta ORDER BY id');
  const seen: string[] = [];
  try { while (meta.goToNextRow()) {
    const id: string = meta.getString(0); const expected: string = id === 'layout' ? DOCX_STORE_LAYOUT : id === 'state' ? 'Committed' : '';
    if (expected.length === 0 || meta.getString(1) !== expected || seen.indexOf(id) >= 0) { throw new DocxFailure('DocxMigrationUncertain','migration'); } seen.push(id);
  } } finally { meta.close(); }
  if (seen.length !== 2) { throw new DocxFailure('DocxMigrationUncertain','migration'); }
  return true;
}
export async function docxPublicationBudget(tx: relationalStore.Transaction, documentId: string, chunks: number): Promise<void> {
  await parsedPublicationBudget(tx,'',chunks,'Docx',documentId);
  if (!Number.isSafeInteger(chunks) || chunks < 0 || chunks > DocxLimits.chunks) { throw new DocxFailure('DocxDocumentChunkBudget','publish'); }
  const rows: relationalStore.ResultSet = await tx.querySql('SELECT (SELECT COALESCE(SUM(chunks),0) FROM text_doc),(SELECT COALESCE(SUM(chunks),0) FROM kb_document WHERE tombstone=0),(SELECT COALESCE(SUM(chunks),0) FROM kb_image_document WHERE tombstone=0),(SELECT COALESCE(SUM(chunks),0) FROM kb_docx_document WHERE tombstone=0 AND id<>?)',[documentId]);
  try {
    if (!rows.goToNextRow()) { throw new DocxFailure('PublicationBudgetIncomplete','publish'); }
    let total: number = 0;
    for (let at: number = 0; at < 4; at++) {
      const n: number = rows.getLong(at)+(at === 3 ? chunks : 0);
      if (!Number.isSafeInteger(n) || n < 0 || n > 10000) { throw new DocxFailure('SourceChunkBudget','publish'); } total += n;
    }
    if (total > 30000) { throw new DocxFailure('AllSourceChunkBudget','publish'); }
  } finally { rows.close(); }
}
