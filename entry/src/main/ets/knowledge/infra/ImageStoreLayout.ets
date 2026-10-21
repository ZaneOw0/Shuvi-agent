import { relationalStore } from '@kit.ArkData';
import { ImageKnowledgeFailure } from '../domain/ImageKnowledgeModels';
import { docxVerifyExisting } from './DocxStoreLayout';
import { parsedPublicationBudget } from './ParsedPublicationBudget';

export const IMAGE_STORE_LAYOUT: string = 'KB-IMAGE-EXT-1';
// Existing columns express basic evidence too: sdk/frames retain actual values (0 means unobserved).
// IMAGE-NORMALIZED-2 assets use the same owned snapshot slot; legacy registry remains a compatible reader family.
export const IMAGE_STORE_DDL: string[] = [
  'CREATE TABLE kb_image_meta (id TEXT PRIMARY KEY,value TEXT NOT NULL)',
  'CREATE TABLE kb_image_document (id TEXT PRIMARY KEY,title TEXT NOT NULL,epoch INTEGER NOT NULL,archived INTEGER NOT NULL,tombstone INTEGER NOT NULL,active_original TEXT NOT NULL,active_generation TEXT NOT NULL,chunks INTEGER NOT NULL,stage TEXT NOT NULL)',
  'CREATE TABLE kb_image_original (asset TEXT PRIMARY KEY,doc TEXT NOT NULL,source TEXT NOT NULL,version INTEGER NOT NULL,title TEXT NOT NULL,suffix TEXT NOT NULL,hash TEXT NOT NULL,bytes INTEGER NOT NULL,encoding TEXT NOT NULL,mime TEXT NOT NULL,width INTEGER NOT NULL,height INTEGER NOT NULL,orientation INTEGER NOT NULL,orientation_evidence TEXT NOT NULL,alpha INTEGER NOT NULL,variant TEXT NOT NULL,static INTEGER NOT NULL,sdk INTEGER NOT NULL,frames INTEGER NOT NULL,saved INTEGER NOT NULL)',
  'CREATE TABLE kb_image_job (id TEXT PRIMARY KEY,doc TEXT NOT NULL,generation TEXT UNIQUE NOT NULL,original TEXT NOT NULL,epoch INTEGER NOT NULL,old_active TEXT NOT NULL,report TEXT NOT NULL,snapshot TEXT NOT NULL,stage TEXT NOT NULL,checkpoint TEXT NOT NULL,failure TEXT NOT NULL,task TEXT NOT NULL,result_asset TEXT NOT NULL,result_hash TEXT NOT NULL)',
  'CREATE TABLE kb_image_generation (id TEXT PRIMARY KEY,doc TEXT NOT NULL,original TEXT NOT NULL,epoch INTEGER NOT NULL,state TEXT NOT NULL,wire TEXT NOT NULL,hash TEXT NOT NULL,report TEXT NOT NULL,expected INTEGER NOT NULL)',
  'CREATE TABLE kb_image_chunk (id TEXT PRIMARY KEY,doc TEXT NOT NULL,generation TEXT NOT NULL,ordinal INTEGER NOT NULL,text TEXT NOT NULL,input_hash TEXT NOT NULL,locator TEXT NOT NULL)',
  'CREATE TABLE kb_image_asset (id TEXT PRIMARY KEY,doc TEXT NOT NULL,owner TEXT NOT NULL,hash TEXT NOT NULL,bytes INTEGER NOT NULL,generation TEXT NOT NULL,role TEXT NOT NULL,pins INTEGER NOT NULL)',
  'CREATE TABLE kb_image_lease (id TEXT PRIMARY KEY,doc TEXT NOT NULL,asset TEXT NOT NULL,owner TEXT NOT NULL,epoch INTEGER NOT NULL)',
  'CREATE TABLE kb_image_release (id TEXT PRIMARY KEY,pixel TEXT NOT NULL,source TEXT NOT NULL,file TEXT NOT NULL,lease TEXT NOT NULL,failure TEXT NOT NULL)',
  'CREATE TABLE kb_image_cleanup (id TEXT PRIMARY KEY,doc TEXT NOT NULL,asset TEXT NOT NULL,owner TEXT NOT NULL,state TEXT NOT NULL,failure TEXT NOT NULL)',
  'CREATE TABLE kb_image_reservation (id TEXT PRIMARY KEY,owner TEXT NOT NULL,bytes INTEGER NOT NULL,state TEXT NOT NULL)',
  'CREATE TABLE kb_source_registry (kind TEXT PRIMARY KEY,reader TEXT NOT NULL,state TEXT NOT NULL)',
  'CREATE TABLE kb_image_vector (id TEXT PRIMARY KEY,doc TEXT NOT NULL,content TEXT NOT NULL,space TEXT NOT NULL,job TEXT UNIQUE NOT NULL,epoch INTEGER NOT NULL,state TEXT NOT NULL,expected INTEGER NOT NULL,grant_id TEXT NOT NULL,snapshot TEXT NOT NULL,config TEXT NOT NULL,session TEXT NOT NULL,window INTEGER NOT NULL,failure TEXT NOT NULL)',
  'CREATE TABLE kb_image_vector_input (generation TEXT NOT NULL,chunk TEXT NOT NULL,input_hash TEXT NOT NULL,state TEXT NOT NULL,readback_hash TEXT NOT NULL,PRIMARY KEY(generation,chunk))',
  'CREATE TABLE kb_image_vector_mirror (doc TEXT PRIMARY KEY,content TEXT NOT NULL,generation TEXT NOT NULL,space TEXT NOT NULL,epoch INTEGER NOT NULL,revision INTEGER NOT NULL,state TEXT NOT NULL)'
];
export function imageTableNames(): string[] { return IMAGE_STORE_DDL.map((ddl: string): string => ddl.slice(13,ddl.indexOf(' ('))); }
export async function imagePublicationBudget(tx: relationalStore.Transaction, documentId: string, chunks: number): Promise<void> {
  await parsedPublicationBudget(tx,'',chunks,'Image',documentId);
  if (!Number.isSafeInteger(chunks) || chunks < 0 || chunks > 2000) { throw new ImageKnowledgeFailure('ImageDocumentChunkBudget','publish'); }
  const docx: boolean = await docxVerifyExisting(tx);
  const rows: relationalStore.ResultSet = await tx.querySql('SELECT (SELECT COALESCE(SUM(chunks),0) FROM text_doc),(SELECT COALESCE(SUM(chunks),0) FROM kb_document WHERE tombstone=0),(SELECT COALESCE(SUM(chunks),0) FROM kb_image_document WHERE tombstone=0 AND id<>?)'+(docx ? ',(SELECT COALESCE(SUM(chunks),0) FROM kb_docx_document WHERE tombstone=0)' : ',0'),[documentId]);
  try {
    if (!rows.goToNextRow()) { throw new ImageKnowledgeFailure('PublicationBudgetIncomplete','publish'); }
    const text: number = rows.getLong(0); const pdf: number = rows.getLong(1); const image: number = rows.getLong(2)+chunks;
    const docxCount: number = rows.getLong(3);
    if (text < 0 || pdf < 0 || image < 0 || docxCount < 0 || text > 10000 || pdf > 10000 || image > 10000 || docxCount > 10000 || text+pdf+image+docxCount > 30000) { throw new ImageKnowledgeFailure('AllSourceChunkBudget','publish'); }
  } finally { rows.close(); }
}
// Called by the PDF opener too: recognize only the complete, committed extension.
export async function imageVerifyExisting(tx: relationalStore.Transaction): Promise<boolean> {
  const names: string[] = imageTableNames();
  const rows: relationalStore.ResultSet = await tx.querySql("SELECT name,sql FROM sqlite_master WHERE type='table' AND (name GLOB 'kb_image_*' OR name='kb_source_registry')");
  let count: number = 0;
  try { while (rows.goToNextRow()) {
    const at: number = names.indexOf(rows.getString(0));
    if (at < 0 || rows.getString(1) !== IMAGE_STORE_DDL[at]) { throw new ImageKnowledgeFailure('ImageLayoutMismatch', 'migration'); } count++;
  } } finally { rows.close(); }
  if (count === 0) { return false; }
  if (count !== names.length) { throw new ImageKnowledgeFailure('ImageLayoutIncomplete', 'migration'); }
  const docx: boolean = await docxVerifyExisting(tx);
  const meta: relationalStore.ResultSet = await tx.querySql('SELECT value FROM kb_image_meta WHERE id=?',['layout']);
  try { if (!meta.goToNextRow() || meta.getString(0) !== IMAGE_STORE_LAYOUT || meta.goToNextRow()) { throw new ImageKnowledgeFailure('ImageMigrationUncertain', 'migration'); } } finally { meta.close(); }
  const registry: relationalStore.ResultSet = await tx.querySql('SELECT kind,reader,state FROM kb_source_registry ORDER BY kind');
  let registryCount: number = 0;
  try { while (registry.goToNextRow()) {
    const kind: string = registry.getString(0); const reader: string = registry.getString(1);
    if ((kind !== 'Text' && kind !== 'Pdf' && kind !== 'Image' && !(kind === 'Docx' && docx)) || reader !== (kind === 'Docx' ? 'DOCX-NORMALIZED-1' : kind === 'Image' ? 'IMAGE-NORMALIZED-1' : kind === 'Pdf' ? 'PDF-NORMALIZED-1' : 'TEXT-SNAPSHOT-1') || registry.getString(2) !== 'Enabled') { throw new ImageKnowledgeFailure('UnknownSourceRegistration', 'migration'); } registryCount++;
  } } finally { registry.close(); }
  if (registryCount !== (docx ? 4 : 3)) { throw new ImageKnowledgeFailure('SourceRegistrationIncomplete', 'migration'); } return true;
}
