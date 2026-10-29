import { relationalStore } from '@kit.ArkData';
import { KnowledgeLexicalSearchPort, KnowledgeLexicalRequest, KnowledgeLexicalResult, KnowledgeLexicalCapabilities, KNOWLEDGE_LEXICAL_POLICY } from '../domain/KnowledgeLexicalPorts';
import { ParsedCancellation, ParsedFailure, ParsedTextChunk } from '../domain/ParsedDocumentModels';
import { ParsedIdentityPort } from '../domain/ParsedDocumentPorts';
import { UnifiedQueryScope, UnifiedQueryTextSource, UnifiedQueryImageSource, UnifiedSearchCard, UnifiedSearchReason } from '../domain/UnifiedQueryModels';
import { KnowledgeStoreHost } from './KnowledgeStoreHost';
import { ParsedDocumentRepository } from './ParsedDocumentRepository';
import { parsedUtf8 } from '../pipeline/ParsedDocumentCodec';
import { unifiedProxyText } from '../pipeline/UnifiedTextPolicy';
import { unifiedBodyCard, unifiedImageCard, unifiedMergeCard } from '../pipeline/KnowledgeRetrievalPolicy';
import { knowledgeLexicalTerms, knowledgeLexicalFts, knowledgeLexicalLiteral, knowledgeLexicalRanges } from '../pipeline/KnowledgeLexicalPolicy';

// Separate derived namespace: ParsedDocumentStoreLayout owns the immutable upd_* layout.
// A durable revision trigger commits with the authoritative write; FTS is maintained afterwards.
const LEXICAL_STATE: string = 'CREATE TABLE IF NOT EXISTS klex_state (id INTEGER PRIMARY KEY CHECK(id=1),policy TEXT NOT NULL,revision INTEGER NOT NULL,indexed INTEGER NOT NULL,state TEXT NOT NULL,phase TEXT NOT NULL,cursor TEXT NOT NULL)';
const LEXICAL_FTS: string = 'CREATE VIRTUAL TABLE IF NOT EXISTS klex_fts USING fts5(kind UNINDEXED,id UNINDEXED,version UNINDEXED,hash UNINDEXED,body,tokenize=customtokenizer)';
const LEXICAL_BATCH: number = 256;
const LEXICAL_BYTES: number = 2097152;
class KnowledgeLexicalCheckpoint {
  revision: string = ''; indexed: string = ''; state: string = 'NotBuilt'; phase: string = 'body'; cursor: string = '';
}
class KnowledgeLexicalCursor {
  phase: string = 'fts'; after: string = ''; offset: number = 0; revision: string = ''; binding: string = ''; fallback: string = '';
}
class KnowledgeLexicalRow {
  kind: string = 'body'; id: string = ''; version: string = ''; hash: string = ''; text: string = ''; chunk?: ParsedTextChunk; image?: UnifiedQueryImageSource;
}
export class KnowledgeLexicalRepository implements KnowledgeLexicalSearchPort {
  private host: KnowledgeStoreHost;
  private repository: ParsedDocumentRepository;
  private identity: ParsedIdentityPort;
  private unavailable: boolean = false;
  private failureReason: string = 'TokenizerUnavailable';
  private prepared?: relationalStore.RdbStore;
  constructor(host: KnowledgeStoreHost, repository: ParsedDocumentRepository, identity: ParsedIdentityPort) { this.host=host; this.repository=repository; this.identity=identity; }
  private store(): relationalStore.RdbStore { if (!this.repository.ready()) { throw new ParsedFailure('LexicalStoreUnavailable','lexical'); } return this.host.requireStore(); }
  private async checkpoint(): Promise<KnowledgeLexicalCheckpoint> {
    const rows=await this.store().querySql('SELECT policy,revision,indexed,state,phase,cursor FROM klex_state WHERE id=1');
    try {
      if (!rows.goToNextRow() || rows.getString(0)!==KNOWLEDGE_LEXICAL_POLICY) { throw new ParsedFailure('LexicalLayoutUnknown','lexical'); }
      const state: KnowledgeLexicalCheckpoint=new KnowledgeLexicalCheckpoint(); state.revision=String(rows.getLong(1)); state.indexed=String(rows.getLong(2)); state.state=rows.getString(3); state.phase=rows.getString(4); state.cursor=rows.getString(5); return state;
    } finally { rows.close(); }
  }
  private async initialize(): Promise<void> {
    if (this.prepared===this.store()) { return; }
    await this.store().executeSql(LEXICAL_STATE);
    await this.store().executeSql("INSERT OR IGNORE INTO klex_state VALUES(1,?,1,0,'NotBuilt','body','')",[KNOWLEDGE_LEXICAL_POLICY]);
    await this.checkpoint();
    await this.host.transaction(async (tx: relationalStore.Transaction): Promise<void> => {
      for (const table of ['upd_document','upd_chunk','upd_image_occurrence','upd_annotation','upd_tag','upd_asset']) {
        for (const operation of ['INSERT','UPDATE','DELETE']) {
          let condition: string='';
          if (table==='upd_asset') {
            // History, manifests and other derived files share upd_asset. Only assets
            // referenced by a current image occurrence can change the readable corpus.
            // Replace the previously shipped broad triggers atomically on reopening.
            await tx.execute(`DROP TRIGGER IF EXISTS klex_${table}_${operation}`);
            const reference: string=operation==='DELETE'?'o.asset=OLD.id':operation==='UPDATE'?'(o.asset=OLD.id OR o.asset=NEW.id)':'o.asset=NEW.id';
            condition=` WHEN EXISTS (SELECT 1 FROM upd_image_occurrence o JOIN upd_document d ON d.id=o.doc AND d.active=o.generation WHERE ${reference} AND d.tombstone=0)`;
          }
          await tx.execute(`CREATE TRIGGER IF NOT EXISTS klex_${table}_${operation} AFTER ${operation} ON ${table}${condition} BEGIN UPDATE klex_state SET revision=revision+1,state='Stale' WHERE id=1; END`);
        }
      }
    });
    if (this.unavailable) { this.prepared=this.store(); return; }
    try {
      // Real create/write/query/readback/update/delete probe, not only an API boolean.
      await this.store().executeSql('CREATE VIRTUAL TABLE IF NOT EXISTS klex_probe USING fts5(body,tokenize=customtokenizer)');
      await this.store().executeSql('DELETE FROM klex_probe');
      await this.store().executeSql('INSERT INTO klex_probe(body) VALUES(?)',['知识库 检索 alpha 2026 标点，词']);
      for (const term of ['知识库','alpha','2026','标点']) {
        const rows=await this.store().querySql('SELECT body FROM klex_probe WHERE klex_probe MATCH ?',[knowledgeLexicalFts([term])]);
        try { if (!rows.goToNextRow() || rows.getString(0)!=='知识库 检索 alpha 2026 标点，词') { throw new ParsedFailure('LexicalTokenizerProbe','lexical'); } } finally { rows.close(); }
      }
      await this.store().executeSql('UPDATE klex_probe SET body=?',['updated']);
      const updated=await this.store().querySql('SELECT body FROM klex_probe WHERE klex_probe MATCH ?',['"updated"']);
      try { if (!updated.goToNextRow() || updated.getString(0)!=='updated') { throw new ParsedFailure('LexicalMaintenanceProbe','lexical'); } } finally { updated.close(); }
      await this.store().executeSql('DELETE FROM klex_probe');
      const existing=await this.store().querySql("SELECT name FROM sqlite_master WHERE type='table' AND name='klex_fts'"); let found: boolean=false;
      try { found=existing.goToNextRow(); } finally { existing.close(); }
      await this.store().executeSql(LEXICAL_FTS);
      if (!found) { await this.store().executeSql("UPDATE klex_state SET state='NotBuilt',phase='body',cursor='' WHERE id=1"); }
    } catch { this.unavailable=true; }
    this.prepared=this.store();
  }
  capabilities(): Promise<KnowledgeLexicalCapabilities> {
    return this.host.enqueue<KnowledgeLexicalCapabilities>(async (): Promise<KnowledgeLexicalCapabilities> => {
      await this.initialize(); const state=await this.checkpoint(); const result: KnowledgeLexicalCapabilities=new KnowledgeLexicalCapabilities();
      result.state=this.unavailable?'Unavailable':state.state; result.revision=state.revision; result.directReady=true; return result;
    });
  }
  private async scope(archived: boolean, cancel: ParsedCancellation): Promise<UnifiedQueryScope> {
    const scope: UnifiedQueryScope=new UnifiedQueryScope(); scope.includeArchived=archived;
    // Metadata only: no normal-path full-body capture/hash or dependency on numeric readiness.
    for (const document of await this.repository.list()) { cancel.check(); if (!document.tombstone && (archived || !document.archived) && document.activeGeneration.length>0) { const source: UnifiedQueryTextSource=new UnifiedQueryTextSource(); source.document=document; scope.texts.push(source); } }
    for (const record of await this.repository.queryImageRecords(archived)) { cancel.check(); const image: UnifiedQueryImageSource=new UnifiedQueryImageSource(); image.record=record; image.annotation=await this.repository.annotation(record.effectiveId); scope.images.push(image); }
    if (scope.texts.length>30000 || scope.images.length>30000) { throw new ParsedFailure('LexicalMetadataBudget','lexical'); }
    for (const source of scope.texts) { const binding=await this.repository.binding('upd-body',source.document.id); if (binding?.state!=='Synced' || binding.version!==source.document.activeGeneration) { scope.unupgraded++; } }
    for (const image of scope.images) { const binding=await this.repository.binding('upd-image',image.record.lineage); if (binding?.state!=='Synced' || binding.version!==image.record.effectiveId) { scope.unupgraded++; } }
    scope.complete=true; return scope;
  }
  private async bodies(after: string, limit: number, archived: boolean, id: string=''): Promise<KnowledgeLexicalRow[]> {
    const sql: string='SELECT c.* FROM upd_chunk c JOIN upd_document d ON d.id=c.doc AND d.active=c.generation WHERE d.tombstone=0'+(archived?'':' AND d.archived=0')+(id.length>0?' AND c.id=?':' AND c.id>?')+' ORDER BY c.id LIMIT ?';
    const rows=await this.store().querySql(sql,[id.length>0?id:after,limit]); const out: KnowledgeLexicalRow[]=[];
    try { while (rows.goToNextRow()) { const c: ParsedTextChunk=new ParsedTextChunk(); c.id=rows.getString(0); c.documentKey=rows.getString(1); c.generation=rows.getString(2); c.ordinal=rows.getLong(3); c.text=rows.getString(4); c.inputHash=rows.getString(5); c.blockId=rows.getString(6); c.occurrenceId=rows.getString(7); c.evidence=rows.getString(8); c.start=rows.getLong(9); c.end=rows.getLong(10); const row: KnowledgeLexicalRow=new KnowledgeLexicalRow(); row.id=c.id; row.hash=c.inputHash; row.text=c.text; row.chunk=c; out.push(row); } } finally { rows.close(); } return out;
  }
  private imageRows(scope: UnifiedQueryScope, after: string): KnowledgeLexicalRow[] {
    const out: KnowledgeLexicalRow[]=[];
    for (const image of scope.images) { if (image.record.occurrenceId<=after || image.annotation===undefined) { continue; } const row: KnowledgeLexicalRow=new KnowledgeLexicalRow(); row.kind='image'; row.id=image.record.occurrenceId; row.hash=image.annotation.textHash; row.text=image.annotation.description; row.image=image; out.push(row); }
    out.sort((a: KnowledgeLexicalRow,b: KnowledgeLexicalRow): number => a.id<b.id?-1:a.id>b.id?1:0); return out;
  }
  private async verify(row: KnowledgeLexicalRow, cancel: ParsedCancellation): Promise<void> {
    cancel.check(); const actual: string=row.image?.annotation===undefined?row.text:unifiedProxyText(row.image.annotation.description,row.image.annotation.tags);
    if (await this.identity.hash(parsedUtf8(actual))!==row.hash || row.image!==undefined && row.image.record.imageHash!==row.image.annotation?.imageHash) { throw new ParsedFailure('LexicalReadbackHash','lexical'); } cancel.check();
  }
  private async maintain(cancel: ParsedCancellation): Promise<void> {
    if (this.unavailable) { return; }
    let state=await this.checkpoint();
    if (state.state==='Ready' && state.indexed===state.revision) { return; }
    if (state.state!=='Building') {
      await this.store().executeSql("UPDATE klex_state SET state='NotBuilt',phase='body',cursor='',indexed=0 WHERE id=1");
      await this.store().executeSql('DELETE FROM klex_fts'); state=await this.checkpoint();
      await this.store().executeSql("UPDATE klex_state SET state='Building' WHERE id=1");
    }
    const started: number=Date.now(); let bytes: number=0; let processed: number=0;
    const all: UnifiedQueryScope=state.phase==='image'?await this.scope(true,cancel):new UnifiedQueryScope();
    const rows: KnowledgeLexicalRow[]=state.phase==='body'?await this.bodies(state.cursor,LEXICAL_BATCH,true):this.imageRows(all,state.cursor).slice(0,LEXICAL_BATCH);
    for (const row of rows) {
      cancel.check(); if (processed>0 && (bytes+parsedUtf8(row.text).length>LEXICAL_BYTES || Date.now()-started>1000)) { break; }
      await this.verify(row,cancel); await this.repository.ensureCapacity(parsedUtf8(row.text).length*3+4096);
      // Idempotent restart if a process exits between FTS write and checkpoint.
      const rowid: number=Number.parseInt((await this.identity.hash(parsedUtf8(row.kind+':'+row.id))).slice(0,12),16);
      const prior=await this.store().querySql('SELECT kind,id FROM klex_fts WHERE rowid=?',[rowid]);
      try { if (prior.goToNextRow() && (prior.getString(0)!==row.kind || prior.getString(1)!==row.id)) { throw new ParsedFailure('LexicalRowIdentityCollision','lexical'); } } finally { prior.close(); }
      await this.store().executeSql('DELETE FROM klex_fts WHERE rowid=?',[rowid]);
      await this.store().executeSql('INSERT INTO klex_fts(rowid,kind,id,version,hash,body) VALUES(?,?,?,?,?,?)',[rowid,row.kind,row.id,row.chunk?.generation ?? row.image?.record.effectiveId ?? '',row.hash,row.text]);
      const readback=await this.store().querySql('SELECT hash,body FROM klex_fts WHERE rowid=?',[rowid]);
      try { if (!readback.goToNextRow() || readback.getString(0)!==row.hash || readback.getString(1)!==row.text) { throw new ParsedFailure('LexicalIndexReadback','lexical'); } } finally { readback.close(); }
      await this.store().executeSql('UPDATE klex_state SET cursor=? WHERE id=1',[row.id]); bytes+=parsedUtf8(row.text).length; processed++;
    }
    if (processed===rows.length && rows.length<LEXICAL_BATCH) {
      if (state.phase==='body') { await this.store().executeSql("UPDATE klex_state SET phase='image',cursor='' WHERE id=1"); await this.maintain(cancel); }
      else { await this.store().executeSql("UPDATE klex_state SET state='Ready',indexed=revision,cursor='' WHERE id=1"); }
    }
  }
  search(request: KnowledgeLexicalRequest, cancel: ParsedCancellation): Promise<KnowledgeLexicalResult> {
    const terms: string[]=knowledgeLexicalTerms(request);
    return this.host.enqueue<KnowledgeLexicalResult>(async (): Promise<KnowledgeLexicalResult> => {
      cancel.check(); await this.initialize();
      try { await this.maintain(cancel); } catch { cancel.check(); this.unavailable=true; this.failureReason='IndexMaintenanceFailed'; }
      const state=await this.checkpoint(); const result: KnowledgeLexicalResult=new KnowledgeLexicalResult(); result.scopeRevision=state.revision; result.indexState=this.unavailable?'Unavailable':state.state;
      const binding: string=await this.identity.hash(parsedUtf8(JSON.stringify([request.query,terms,request.intent,request.includeArchived])));
      let cursor: KnowledgeLexicalCursor=new KnowledgeLexicalCursor(); cursor.revision=state.revision; cursor.binding=binding;
      if (request.scopeRevision.length>0 && request.scopeRevision!==state.revision) { throw new ParsedFailure('LexicalScopeChanged','lexical'); }
      if (request.cursor.length>0) {
        if (request.cursor.length>2048) { throw new ParsedFailure('LexicalCursorInvalid','lexical'); }
        cursor=JSON.parse(request.cursor);
        if (cursor===null || !['fts','body','image','done'].includes(cursor.phase) || typeof cursor.after!=='string' || cursor.after.length>256 || !Number.isSafeInteger(cursor.offset) || cursor.offset<0 || cursor.revision!==state.revision || cursor.binding!==binding || typeof cursor.fallback!=='string') { throw new ParsedFailure('LexicalCursorInvalid','lexical'); }
      }
      result.scope=await this.scope(request.includeArchived,cancel); result.scope.localHash=state.revision; result.scope.hash=state.revision; result.readableDocuments=result.scope.texts.length;
      const count=await this.store().querySql('SELECT COUNT(*) FROM upd_chunk c JOIN upd_document d ON d.id=c.doc AND d.active=c.generation WHERE d.tombstone=0'+(request.includeArchived?'':' AND d.archived=0'));
      try { if (count.goToNextRow()) { result.coverage.readableBodies=count.getLong(0); } } finally { count.close(); }
      result.coverage.readableImages=result.scope.images.length;
      if (result.coverage.readableBodies>30000) { throw new ParsedFailure('LexicalCorpusBudget','lexical'); }
      const literal: boolean=knowledgeLexicalLiteral(request); const actualTerms: string[]=literal?[request.query.trim().replace(new RegExp('^["“]|["”]$','g'),'')]:terms;
      if (request.cursor.length===0 && (literal || terms.some((term: string): boolean=>term.length===1) || this.unavailable || state.state!=='Ready')) { cursor.phase='body'; cursor.fallback=literal?'LiteralIntent':this.unavailable?this.failureReason:state.state!=='Ready'?'IndexRecovering':'ShortTermProbe'; }
      if (cursor.phase==='fts') {
        try {
          const rows=await this.store().querySql('SELECT kind,id,hash,version FROM klex_fts WHERE klex_fts MATCH ? ORDER BY rank,rowid LIMIT ? OFFSET ?',[knowledgeLexicalFts(terms),LEXICAL_BATCH+1,cursor.offset]);
          const candidates: KnowledgeLexicalRow[]=[]; try { while (rows.goToNextRow()) { const row: KnowledgeLexicalRow=new KnowledgeLexicalRow(); row.kind=rows.getString(0); row.id=rows.getString(1); row.hash=rows.getString(2); row.version=rows.getString(3); candidates.push(row); } } finally { rows.close(); }
          result.engine='fts5';
          for (const candidate of candidates.slice(0,LEXICAL_BATCH)) {
            cancel.check(); let row: KnowledgeLexicalRow | undefined;
            if (candidate.kind==='body') { row=(await this.bodies('',1,request.includeArchived,candidate.id))[0]; }
            else { row=this.imageRows(result.scope,'').find((item: KnowledgeLexicalRow): boolean=>item.id===candidate.id); }
            if (row===undefined) { continue; } if (row.hash!==candidate.hash || (row.chunk?.generation ?? row.image?.record.effectiveId)!==candidate.version) { throw new ParsedFailure('LexicalCandidateStale','lexical'); }
            await this.verify(row,cancel); result.readback++; this.add(result,row,actualTerms,true,cursor.offset+result.readback);
          }
          cursor.offset+=Math.min(candidates.length,LEXICAL_BATCH);
          if (candidates.length>LEXICAL_BATCH) { result.hasMore=true; }
          else if (cursor.offset===0) { cursor.phase='body'; cursor.fallback='ZeroCandidatesProbe'; }
          else { cursor.phase='done'; }
        } catch { cancel.check(); cursor.phase='body'; cursor.fallback='FtsQueryFailed'; result.engine='literal-scan'; this.prepared=undefined; await this.store().executeSql("UPDATE klex_state SET state='Stale' WHERE id=1"); }
      }
      if (cursor.phase==='body' || cursor.phase==='image') {
        if (result.cards.length===0) { result.engine='literal-scan'; }
        result.fallbackReason=cursor.fallback; const started: number=Date.now(); let bytes: number=0;
        const rows: KnowledgeLexicalRow[]=cursor.phase==='body'?await this.bodies(cursor.after,LEXICAL_BATCH+1,request.includeArchived):this.imageRows(result.scope,cursor.after).slice(0,LEXICAL_BATCH+1);
        for (const row of rows.slice(0,LEXICAL_BATCH)) {
          cancel.check(); if (result.scanned>0 && (bytes+parsedUtf8(row.text).length>LEXICAL_BYTES || Date.now()-started>1000)) { break; }
          await this.verify(row,cancel); result.scanned++; bytes+=parsedUtf8(row.text).length; cursor.after=row.id; this.add(result,row,actualTerms,false);
        }
        if (result.scanned===rows.length && rows.length<=LEXICAL_BATCH) { cursor.phase=cursor.phase==='body'?'image':'done'; cursor.after=''; }
        result.hasMore=cursor.phase!=='done';
      }
      cancel.check(); result.cursor=JSON.stringify(cursor); result.status=result.hasMore && result.engine!=='fts5'?'partial':result.cards.length>0?'ok':'empty';
      result.coverage.scanned=result.scanned; result.coverage.candidateReadback=result.readback; result.coverage.complete=!result.hasMore; result.coverage.indexed=!this.unavailable && state.state==='Ready'?result.coverage.readableBodies+result.scope.images.filter((image: UnifiedQueryImageSource): boolean=>image.annotation!==undefined).length:0;
      result.cards.sort((a: UnifiedSearchCard,b: UnifiedSearchCard): number=>Number(b.reasons.some((r: UnifiedSearchReason): boolean=>r.matchKind==='Literal'))-Number(a.reasons.some((r: UnifiedSearchReason): boolean=>r.matchKind==='Literal')) || b.reasons.reduce((n: number,r: UnifiedSearchReason): number=>n+r.matchedTerms.length,0)-a.reasons.reduce((n: number,r: UnifiedSearchReason): number=>n+r.matchedTerms.length,0) || (a.reasons[0]?.rank ?? 0)-(b.reasons[0]?.rank ?? 0) || a.key.localeCompare(b.key));
      return result;
    });
  }
  private add(result: KnowledgeLexicalResult,row: KnowledgeLexicalRow,terms: string[],fts: boolean,rank: number=0): void {
    const evidence: string=row.chunk?.evidence ?? 'AiDescription'; const ranges=knowledgeLexicalRanges(row.text,terms,evidence); if (!fts && ranges.length===0) { return; }
    const card: UnifiedSearchCard=row.chunk===undefined && row.image!==undefined?unifiedImageCard(row.image,result.scope):row.chunk!==undefined?unifiedBodyCard(row.chunk,result.scope):new UnifiedSearchCard();
    const reason: UnifiedSearchReason=new UnifiedSearchReason(); reason.rank=rank; reason.id='lexical:'+row.kind+':'+row.id; reason.route='Keyword'; reason.text=row.text; reason.version=row.chunk?.generation ?? row.image?.record.effectiveId ?? ''; reason.inputId=row.chunk?.id ?? ''; reason.occurrenceId=row.chunk?.occurrenceId ?? row.id; reason.engine=fts?'fts5':'literal-scan'; reason.matchKind=ranges.length>0?'Literal':'Keyword'; reason.evidenceType=evidence; reason.ranges=ranges; reason.matchedTerms=terms.filter((term: string): boolean=>knowledgeLexicalRanges(row.text,[term],evidence).length>0); card.reasons=[reason];
    const old=result.cards.find((item: UnifiedSearchCard): boolean=>item.key===card.key); if (old===undefined) { result.cards.push(card); } else { unifiedMergeCard(old,card); }
  }
  validate(cards: UnifiedSearchCard[], archived: boolean,cancel: ParsedCancellation): Promise<boolean> {
    return this.host.enqueue<boolean>(async (): Promise<boolean> => {
      const scope=cards.some((card: UnifiedSearchCard): boolean=>card.kind==='Image')?await this.scope(archived,cancel):new UnifiedQueryScope();
      for (const card of cards) { cancel.check(); for (const reason of card.reasons.filter((item: UnifiedSearchReason): boolean=>item.route==='Keyword')) {
        let row: KnowledgeLexicalRow | undefined;
        if (reason.inputId.length>0) { row=(await this.bodies('',1,archived,reason.inputId))[0]; if (row?.chunk?.generation!==reason.version) { return false; } }
        else { row=this.imageRows(scope,'').find((item: KnowledgeLexicalRow): boolean=>item.id===reason.occurrenceId && item.image?.record.effectiveId===reason.version); }
        if (row===undefined || row.text!==reason.text) { return false; } await this.verify(row,cancel);
      } } return true;
    });
  }
}
