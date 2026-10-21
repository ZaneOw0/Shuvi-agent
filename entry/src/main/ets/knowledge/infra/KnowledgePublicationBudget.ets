import { relationalStore } from '@kit.ArkData';
import { KnowledgeFailure } from '../domain/PdfKnowledgeModels';
import { parsedPublicationBudget } from './ParsedPublicationBudget';

// All publishers share the 30000 total. Absent extensions are not silently queried as empty tables.
export async function knowledgePublicationBudget(tx: relationalStore.Transaction, kind: string, document: string, chunks: number): Promise<void> {
  await parsedPublicationBudget(tx,'',chunks,kind,document);
  if (!Number.isSafeInteger(chunks) || chunks < 0 || chunks > 10000 || ['Text','Pdf','Image','Docx'].indexOf(kind) < 0) { throw new KnowledgeFailure('PublicationInputBudget','publish'); }
  const names: string[] = []; const tables = await tx.querySql("SELECT name FROM sqlite_master WHERE type='table' AND name IN ('text_doc','kb_document','kb_image_document','kb_docx_document')");
  try { while (tables.goToNextRow()) { names.push(tables.getString(0)); } } finally { tables.close(); }
  const kinds: string[] = ['Text','Pdf','Image','Docx']; const tableNames: string[] = ['text_doc','kb_document','kb_image_document','kb_docx_document']; let total: number = 0;
  for (let at: number = 0; at < kinds.length; at++) {
    if (names.indexOf(tableNames[at]) < 0) { if (kinds[at] === kind) { throw new KnowledgeFailure('PublicationSourceTableMissing','publish'); } continue; }
    const current: boolean = kind === kinds[at]; const rows = await tx.querySql(`SELECT COALESCE(SUM(chunks),0) FROM ${tableNames[at]}`+(kinds[at] === 'Text' ? ' WHERE 1=1' : ' WHERE tombstone=0')+(current ? ' AND id<>?' : ''),current ? [document] : []);
    try { if (!rows.goToNextRow()) { throw new KnowledgeFailure('PublicationCountIncomplete','publish'); } const count: number = rows.getLong(0)+(current ? chunks : 0); if (!Number.isSafeInteger(count) || count < 0 || count > 10000) { throw new KnowledgeFailure('SourceChunkBudget','publish'); } total += count; } finally { rows.close(); }
  }
  if (total > 30000) { throw new KnowledgeFailure('AllSourceChunkBudget','publish'); }
}
