import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { KnowledgeStoreHost } from './KnowledgeStoreHost';
import { TextRdbRepository } from './TextRdbRepository';
import { KnowledgePlatformIdentity } from './KnowledgeAssembly';
import { pdfCodecUtf8 } from '../pipeline/PdfSnapshotCodec';
import { KnowledgeFailure, PdfBudget } from '../domain/PdfKnowledgeModels';
import { documentHashFile, documentAssetPath } from './DocumentFileOperations';
import { DocumentParseCancellation } from '../domain/DocumentParseModels';

export class KnowledgePublicAuditResult { m1: string = ''; parse: string = ''; originals: number = 0; results: number = 0; history: number = 0; originalVerified: boolean = false; zipVerified: boolean = false; }
async function knowledgeAuditRows(store: relationalStore.RdbStore, sql: string, columns: number): Promise<string[]> {
  const rows: relationalStore.ResultSet = await store.querySql(sql); const output: string[] = [];
  try { while (rows.goToNextRow()) { if (output.length >= 20000) { throw new KnowledgeFailure('AuditRowBudget','audit'); } const fields: string[] = []; for (let at: number = 0; at < columns; at++) { fields.push(rows.getString(at)); } output.push(fields.map((field: string): string => encodeURIComponent(field)).join('|')); } } finally { rows.close(); } return output;
}
export async function knowledgePublicAudit(context: common.Context): Promise<KnowledgePublicAuditResult> {
  const host: KnowledgeStoreHost = KnowledgeStoreHost.forContext(context); const text: TextRdbRepository = new TextRdbRepository(context,host);
  const result: KnowledgePublicAuditResult = new KnowledgePublicAuditResult(); const identity: KnowledgePlatformIdentity = new KnowledgePlatformIdentity();
  await text.open();
  try {
    const docs: string[] = await knowledgeAuditRows(host.requireStore(),'SELECT id,asset,hash,bytes,version,active,archived,stage,chunks FROM text_doc ORDER BY id',9);
    const history: string[] = await knowledgeAuditRows(host.requireStore(),'SELECT id,created FROM text_query ORDER BY id',2); result.history = history.length;
    result.m1 = await identity.hash(pdfCodecUtf8(docs.concat(history).join('\n')));
  } finally { await text.close(); }
  const config: relationalStore.StoreConfig = { name: 'shuvi_parse_stage_v1.db',securityLevel: relationalStore.SecurityLevel.S3 };
  const store: relationalStore.RdbStore = await relationalStore.getRdbStore(context,config);
  try {
    const originals: string[] = await knowledgeAuditRows(store,'SELECT id,asset,hash,bytes,version,pages FROM original ORDER BY id',6);
    const results: string[] = await knowledgeAuditRows(store,'SELECT asset,task_id,data_id,original_hash,version,bytes,hash,status,complete,signature FROM result ORDER BY asset',10);
    const tasks: string[] = await knowledgeAuditRows(store,'SELECT id,original,data_id,hash,version,stage,checkpoint,remote FROM task ORDER BY id',8);
    result.originals = originals.length; result.results = results.length; result.parse = await identity.hash(pdfCodecUtf8(originals.concat(results).concat(tasks).join('\n')));
    const binding: relationalStore.ResultSet = await store.querySql('SELECT o.asset,o.hash,r.asset,r.hash FROM original o JOIN task t ON t.original=o.id JOIN result r ON r.task_id=t.id WHERE o.id=? AND t.id=?',['m2-731441b8eec54bdecc16effb0192c2c2','m2-7eaa150e269374313fd776f12a2ae9fa']);
    let originalAsset: string = ''; let originalHash: string = ''; let zipAsset: string = ''; let zipHash: string = '';
    try { if (!binding.goToNextRow()) { throw new KnowledgeFailure('AuthorizedSourceNotRegistered','audit'); } originalAsset = binding.getString(0); originalHash = binding.getString(1); zipAsset = binding.getString(2); zipHash = binding.getString(3); } finally { binding.close(); }
    const root: string = `${context.filesDir}/knowledge_parse_v1`; const cancel: DocumentParseCancellation = new DocumentParseCancellation();
    result.originalVerified = await documentHashFile(documentAssetPath(root,originalAsset),PdfBudget.originalBytes,cancel) === originalHash;
    result.zipVerified = zipHash === '548162c5bb0f6a93d0fe76d4a5a17399f87b0a882c84d4510e7c2ead5fc12a05' && await documentHashFile(documentAssetPath(root,zipAsset),PdfBudget.zipBytes,cancel) === zipHash;
  } finally { await store.close(); }
  return result;
}
