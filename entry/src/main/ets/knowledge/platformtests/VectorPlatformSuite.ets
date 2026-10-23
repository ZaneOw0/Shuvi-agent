import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { KnowledgeStorageScope } from '../domain/KnowledgeStorageScope';
import { VectorRdbRepository } from '../infra/VectorRdbRepository';
import { EmbeddingSpace, KnowledgeVectorRow, KnowledgeVectorCandidate } from '../domain/EmbeddingModels';
import { KnowledgeCancellation, KnowledgeFailure } from '../domain/PdfKnowledgeModels';
import { PdfNativeSuiteResult, PdfNativeCaseResult } from './PdfNativeSuite';

function vectorAssert(condition: boolean, reason: string): void { if (!condition) { throw new KnowledgeFailure(reason,'vector-suite'); } }
export async function knowledgeRunVectorSuite(context: common.Context, scope: KnowledgeStorageScope): Promise<PdfNativeSuiteResult> {
  scope.requireTestOwner(scope.key); const result: PdfNativeSuiteResult = new PdfNativeSuiteResult(); result.run = scope.key; result.version = 'R2-VECTOR-1';
  let repository: VectorRdbRepository = new VectorRdbRepository(context,scope);
  const first: EmbeddingSpace = new EmbeddingSpace(); first.id = 'kb-'+scope.key.repeat(2); first.fingerprint = `fixture-${scope.key}`; first.dimension = 3; first.requestedModel = 'test-only'; first.returnedModel = 'test-only';
  const second: EmbeddingSpace = new EmbeddingSpace(); second.id = 'kb-'+scope.key+'f'.repeat(16); second.fingerprint = first.fingerprint+'-other'; second.dimension = 3;
  const row: KnowledgeVectorRow = new KnowledgeVectorRow(); row.spaceId = first.id; row.chunkId = 'fixture-c0'; row.documentId = 'fixture-doc'; row.contentGeneration = 'fixture-content'; row.vectorGeneration = 'fixture-vector'; row.inputHash = 'a'.repeat(64); row.epoch = 7; row.eligible = true; row.values = new Float32Array([1,0,0]);
  try {
    for (const name of ['supported','open','sql-minimal','sql-composite','fixed-n-register','insert-read-all-identity','wrong-dimension','same-dimension-other-space','composite-key','transaction-rollback','cosine-knn','new-object-reopen','descriptor-copy','readonly-dimension','registration-rollback','close-retry','empty-space-reopen','ddl-before-recover','ddl-after-recover','missing-table-reject','production-session-open']) {
      const item: PdfNativeCaseResult = new PdfNativeCaseResult(); item.id = name;
      try {
        if (name === 'supported') { vectorAssert(relationalStore.isVectorSupported(),'VectorUnsupported'); }
        else if (name === 'open') { await repository.open(); vectorAssert(repository.capability() === 'Available','VectorOpen'); }
        else if (name.startsWith('sql-')) {
          const config: relationalStore.StoreConfig = { name: scope.vectorDatabaseName,securityLevel: relationalStore.SecurityLevel.S3,vector: true }; const store: relationalStore.RdbStore = await relationalStore.getRdbStore(context,config);
          try {
            if (name === 'sql-minimal') { await store.execute('CREATE TABLE probe_minimal (id TEXT PRIMARY KEY,repr FLOATVECTOR(3))'); }
            else if (name === 'sql-composite') { await store.execute('CREATE TABLE probe_composite (chunk TEXT,generation TEXT,embedding FLOATVECTOR(3),PRIMARY KEY(chunk,generation))'); }
            else {
              let found: boolean = false;
              for (const sql of ['PRAGMA table_info(probe_minimal)','SELECT name,sql FROM sqlite_master','SELECT name,sql FROM GS_SYS_TABLES','SELECT name,sql FROM SYS_TABLES']) {
                try { const rows = await store.querySql(sql); try { let count: number = 0; while (rows.goToNextRow()) { count++; const fields: string[] = []; for (let at: number = 0; at < rows.columnCount; at++) { fields.push(rows.getString(at)); } hilog.info(0x0001,'SHUVI_R2','R2_VECTOR_ERROR phase=Schema code=0 detail=%{public}s',encodeURIComponent(sql+'|'+fields.join('|'))); } found = found || count > 0; } finally { rows.close(); } } catch (error) { const native: BusinessError = error; hilog.info(0x0001,'SHUVI_R2','R2_VECTOR_ERROR phase=Schema code=%{public}d detail=%{public}s',native.code,encodeURIComponent(sql)); }
              }
              vectorAssert(found,'SchemaRowMissing');
            }
          } finally { await store.close(); }
        }
        else if (name === 'fixed-n-register') { await repository.register(first); await repository.register(first); vectorAssert(repository.registeredSpaces().length === 1,'RegistryMissing'); }
        else if (name === 'insert-read-all-identity') { await repository.put(row); const read = await repository.read(first.id,row.chunkId,row.vectorGeneration); vectorAssert(read?.documentId === row.documentId && read.contentGeneration === row.contentGeneration && read.epoch === 7 && read.inputHash === row.inputHash && read.eligible && read.values[0] === 1,'ReadbackIdentity'); }
        else if (name === 'wrong-dimension') { row.values = new Float32Array([1,0]); let rejected: boolean = false; try { await repository.put(row); } catch { rejected = true; } row.values = new Float32Array([1,0,0]); vectorAssert(rejected,'WrongDimensionAccepted'); }
        else if (name === 'same-dimension-other-space') { await repository.register(second); vectorAssert(await repository.read(second.id,row.chunkId,row.vectorGeneration) === undefined,'SpaceLeak'); row.spaceId = second.id; await repository.put(row); row.spaceId = first.id; }
        else if (name === 'composite-key') { row.vectorGeneration = 'fixture-vector-next'; row.values = new Float32Array([0,1,0]); await repository.put(row); vectorAssert((await repository.read(first.id,row.chunkId,'fixture-vector'))?.values[0] === 1,'CompositeKeyOverwritten'); }
        else if (name === 'transaction-rollback') { row.chunkId = 'rolled-back'; repository.injectFault(scope.key,'Put'); let rejected: boolean = false; try { await repository.put(row); } catch { rejected = true; } vectorAssert(rejected && await repository.read(first.id,row.chunkId,row.vectorGeneration) === undefined,'RollbackFailed'); row.chunkId = 'fixture-c0'; }
        else if (name === 'cosine-knn') { const candidates: KnowledgeVectorCandidate[] = await repository.knn(first,new Float32Array([1,0,0]),20,new KnowledgeCancellation()); hilog.info(0x0001,'SHUVI_R2','R2_VECTOR_ERROR phase=Knn code=0 detail=%{public}s',encodeURIComponent(candidates.map((item: KnowledgeVectorCandidate): string => item.row.vectorGeneration+':'+item.distance).join('|') || 'empty')); vectorAssert(candidates.length === 2 && candidates[0].row.vectorGeneration === 'fixture-vector' && Math.abs(candidates[0].distance) < 0.00001 && Math.abs(candidates[1].distance-1) < 0.00001,'CosineOrder'); }
        else if (name === 'new-object-reopen') { await repository.close(); repository = new VectorRdbRepository(context,scope); await repository.open(); vectorAssert(repository.registeredSpaces().length === 2 && (await repository.read(first.id,row.chunkId,'fixture-vector'))?.epoch === 7,'ReopenFailed'); }
        else if (name === 'descriptor-copy') { const copies: EmbeddingSpace[] = repository.registeredSpaces(); copies[0].dimension = 99; vectorAssert(repository.registeredSpaces()[0].dimension === 3,'MutableRegistry'); const wrong: EmbeddingSpace = new EmbeddingSpace(); wrong.id = first.id; wrong.fingerprint = first.fingerprint; wrong.dimension = 4; let rejected: boolean = false; try { await repository.knn(wrong,new Float32Array([1,0,0,0]),1,new KnowledgeCancellation()); } catch { rejected = true; } vectorAssert(rejected,'CallerDimensionTrusted'); }
        else if (name === 'readonly-dimension') {
          await repository.close(); const config: relationalStore.StoreConfig = { name: scope.vectorDatabaseName,securityLevel: relationalStore.SecurityLevel.S3,vector: true,isReadOnly: true }; const store = await relationalStore.getRdbStore(context,config); let rejected: boolean = false;
          try { try { const rows = await store.querySql(`SELECT embedding <=> ? FROM v_${first.id.slice(3)}`,[new Float32Array([1,0,0,0])]); try { rejected = !rows.goToNextRow() || rows.isColumnNull(0) || !Number.isFinite(rows.getDouble(0)); } finally { rows.close(); } } catch { rejected = true; } vectorAssert(rejected,'ReadOnlyWrongDimensionAccepted'); } finally { await store.close(); } await repository.open();
        }
        else if (name === 'registration-rollback') { const space: EmbeddingSpace = new EmbeddingSpace(); space.id = 'kb-'+scope.key+'e'.repeat(16); space.fingerprint = 'rollback'; space.dimension = 3; repository.injectFault(scope.key,'Register'); let rejected: boolean = false; try { await repository.register(space); } catch { rejected = true; } vectorAssert(rejected && !repository.registeredSpaces().some((item: EmbeddingSpace): boolean => item.id === space.id),'RegistrationRollbackFailed'); }
        else if (name === 'close-retry') { repository.injectFault(scope.key,'Close'); let rejected: boolean = false; try { await repository.close(); } catch { rejected = true; } vectorAssert(rejected && repository.capability() === 'Releasing','CloseFailureHidden'); await repository.close(); await repository.open(); }
        else if (name === 'empty-space-reopen') { const empty: EmbeddingSpace = new EmbeddingSpace(); empty.id = 'kb-'+scope.key+'d'.repeat(16); empty.fingerprint = 'empty'; empty.dimension = 3; await repository.register(empty); await repository.close(); repository = new VectorRdbRepository(context,scope); await repository.open(); vectorAssert(repository.spaceFailure(empty.id) === '' && await repository.read(empty.id,'none','none') === undefined,'EmptySpaceReopenFailed'); vectorAssert((await repository.knn(empty,new Float32Array([1,0,0]),20,new KnowledgeCancellation())).length === 0,'ProbeCommitted'); }
        else if (name === 'ddl-before-recover' || name === 'ddl-after-recover') { const space: EmbeddingSpace = new EmbeddingSpace(); space.id = 'kb-'+scope.key+(name === 'ddl-before-recover' ? 'b' : 'c').repeat(16); space.dimension = 3; space.fingerprint = name; repository.injectFault(scope.key,name === 'ddl-before-recover' ? 'BeforeDdl' : 'AfterDdl'); let failed: boolean = false; try { await repository.register(space); } catch { failed = true; } vectorAssert(failed,'DdlFaultNotObserved'); await repository.close(); repository = new VectorRdbRepository(context,scope); await repository.open(); vectorAssert(repository.spaceFailure(space.id) === '' && await repository.read(space.id,'none','none') === undefined,'DdlRecoveryFailed'); }
        else if (name === 'missing-table-reject') { await repository.close(); const config: relationalStore.StoreConfig = { name: scope.vectorDatabaseName,securityLevel: relationalStore.SecurityLevel.S3,vector: true }; const store = await relationalStore.getRdbStore(context,config); try { await store.execute(`DROP TABLE v_${second.id.slice(3)}`); } finally { await store.close(); } repository = new VectorRdbRepository(context,scope); await repository.open(); let rejected: boolean = false; try { await repository.read(second.id,'fixture-c0','fixture-vector'); } catch { rejected = true; } vectorAssert(rejected && repository.spaceFailure(second.id).length > 0,'MissingTableRecreated'); }
        else if (name === 'production-session-open') { const production = new VectorRdbRepository(context); try { await production.open(); vectorAssert(production.capability() === 'Available','ProductionSelfCheckFailed'); } finally { await production.close(); } }
        item.passed = true; item.reason = 'ok';
      } catch (error) { const native: BusinessError = error; item.code = typeof native.code === 'number' ? native.code : 0; item.reason = error instanceof KnowledgeFailure ? error.category : 'PlatformApiRejected'; }
      result.cases.push(item);
    }
  } finally { await repository.close(); if (result.cases.every((item: PdfNativeCaseResult): boolean => item.passed)) { const config: relationalStore.StoreConfig = { name: scope.vectorDatabaseName,securityLevel: relationalStore.SecurityLevel.S3,vector: true }; await relationalStore.deleteRdbStore(context,config); } }
  return result;
}
