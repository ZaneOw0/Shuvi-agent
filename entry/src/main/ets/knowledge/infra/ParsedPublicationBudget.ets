import { relationalStore } from '@kit.ArkData';
import { ParsedFailure, ParsedLimits } from '../domain/ParsedDocumentModels';

export async function parsedPublicationBudget(tx: relationalStore.Transaction, unifiedDocument: string, incoming: number, legacyKind: string = '', legacyDocument: string = '', proxyOwner: string = ''): Promise<void> {
  const rows: relationalStore.ResultSet = await tx.querySql("SELECT name FROM sqlite_master WHERE type='table' AND name IN ('upd_document','upd_chunk','upd_legacy_link','upd_index_binding','text_doc','kb_document','kb_image_document','kb_docx_document')");
  const names: string[] = []; try { while (rows.goToNextRow()) { names.push(rows.getString(0)); } } finally { rows.close(); }
  if (names.indexOf('upd_document') < 0) { if (unifiedDocument.length > 0) { throw new ParsedFailure('UnifiedPublicationLayoutUnavailable','budget'); } return; }
  if (names.indexOf('upd_chunk') < 0 || names.indexOf('upd_legacy_link') < 0) { throw new ParsedFailure('UnifiedPublicationLayoutIncomplete','budget'); }
  let total: number = incoming;
  if (names.indexOf('upd_index_binding')>=0) {
    const proxies: relationalStore.ResultSet=await tx.querySql("SELECT COALESCE(SUM(expected),0) FROM upd_index_binding WHERE namespace='upd-image' AND state<>'Invalid' AND owner<>?",[proxyOwner]);
    try { if (!proxies.goToNextRow()) { throw new ParsedFailure('ProxyCountUnavailable','budget'); } total+=proxies.getLong(0); } finally { proxies.close(); }
  }
  const current: relationalStore.ResultSet = await tx.querySql('SELECT count(*) FROM upd_chunk c JOIN upd_document d ON d.id=c.doc AND d.active=c.generation WHERE d.tombstone=0 AND d.id<>?',[unifiedDocument]);
  try { if (!current.goToNextRow()) { throw new ParsedFailure('CurrentInputCountUnavailable','budget'); } total += current.getLong(0); } finally { current.close(); }
  const kinds: string[] = ['Text','Pdf','Image','Docx']; const tables: string[] = ['text_doc','kb_document','kb_image_document','kb_docx_document'];
  for (let at: number = 0; at < kinds.length; at++) {
    if (names.indexOf(tables[at]) < 0) { continue; }
    const count: relationalStore.ResultSet = await tx.querySql(`SELECT COALESCE(SUM(chunks),0) FROM ${tables[at]} old WHERE `+(kinds[at] === 'Text' ? '1=1' : 'old.tombstone=0')+
      ' AND NOT EXISTS(SELECT 1 FROM upd_legacy_link l JOIN upd_document d ON d.id=l.doc WHERE l.namespace=? AND l.legacy_id=old.id AND l.state=? AND (d.active=l.generation OR d.id=?))'+(kinds[at] === legacyKind ? ' AND old.id<>?' : ''),kinds[at] === legacyKind ? [kinds[at],'Committed',unifiedDocument,legacyDocument] : [kinds[at],'Committed',unifiedDocument]);
    try { if (!count.goToNextRow() || count.getLong(0) < 0) { throw new ParsedFailure('LegacyCountUnavailable','budget'); } total += count.getLong(0); } finally { count.close(); }
  }
  if (!Number.isSafeInteger(total) || incoming < 0 || total > ParsedLimits.currentInputs) { throw new ParsedFailure('AllCurrentInputBudget','budget'); }
}
