import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { KnowledgeStorageScope } from '../domain/KnowledgeStorageScope';
import { EmbeddingSpace, KnowledgeVectorRow } from '../domain/EmbeddingModels';
import { KnowledgeCancellation, KnowledgeFailure } from '../domain/PdfKnowledgeModels';
import { VectorRdbRepository } from '../infra/VectorRdbRepository';
import { PdfNativeCaseResult, PdfNativeSuiteResult } from './PdfNativeSuite';

export async function knowledgeVectorRestartCase(context: common.Context, prepare: boolean): Promise<PdfNativeSuiteResult> {
  const scope: KnowledgeStorageScope = KnowledgeStorageScope.isolated('a220261016000001'); scope.requireTestOwner(scope.key);
  const result: PdfNativeSuiteResult = new PdfNativeSuiteResult(); result.run = scope.key; result.version = 'R2-VECTOR-2';
  const row: PdfNativeCaseResult = new PdfNativeCaseResult(); row.id = prepare ? 'process-prepare' : 'process-reopen';
  const repository: VectorRdbRepository = new VectorRdbRepository(context,scope);
  const space: EmbeddingSpace = new EmbeddingSpace(); space.id = 'kb-'+scope.key.repeat(2); space.dimension = 3; space.fingerprint = 'R2-PROCESS-RESTART-1';
  const empty: EmbeddingSpace = new EmbeddingSpace(); empty.id = 'kb-'+scope.key+'e'.repeat(16); empty.dimension = 3; empty.fingerprint = 'R2-EMPTY-PROCESS-1';
  const planned: EmbeddingSpace = new EmbeddingSpace(); planned.id = 'kb-'+scope.key+'d'.repeat(16); planned.dimension = 3; planned.fingerprint = 'R2-DDL-PROCESS-1';
  try {
    await repository.open();
    if (prepare) { await repository.register(space); await repository.register(empty); repository.injectFault(scope.key,'AfterDdl'); let interrupted: boolean = false; try { await repository.register(planned); } catch { interrupted = true; } if (!interrupted) { throw new KnowledgeFailure('DdlInterruptMissing','vector-suite'); } const input: KnowledgeVectorRow = new KnowledgeVectorRow(); input.spaceId = space.id; input.documentId = 'fixture-process'; input.contentGeneration = 'fixture-content'; input.vectorGeneration = 'fixture-vector'; input.chunkId = 'fixture-restart'; input.inputHash = '1'.repeat(64); input.epoch = 4; input.eligible = true; input.values = new Float32Array([1,0,0]); await repository.put(input); }
    else { const read = await repository.read(space.id,'fixture-restart','fixture-vector'); const hits = await repository.knn(space,new Float32Array([1,0,0]),1,new KnowledgeCancellation()); if (read === undefined || read.documentId !== 'fixture-process' || read.contentGeneration !== 'fixture-content' || read.inputHash !== '1'.repeat(64) || read.epoch !== 4 || hits.length !== 1 || hits[0].distance !== 0 || repository.spaceFailure(empty.id).length > 0 || repository.spaceFailure(planned.id).length > 0 || await repository.read(empty.id,'none','none') !== undefined || await repository.read(planned.id,'none','none') !== undefined) { throw new KnowledgeFailure('ProcessReopenMismatch','vector-suite'); } }
    row.passed = true; row.reason = 'ok';
  } catch (error) { const native: BusinessError = error; row.reason = error instanceof KnowledgeFailure ? error.category : 'PlatformApiRejected'; row.code = typeof native.code === 'number' ? native.code : 0; }
  finally { await repository.close(); if (!prepare && row.passed) { const config: relationalStore.StoreConfig = { name: scope.vectorDatabaseName,securityLevel: relationalStore.SecurityLevel.S3,vector: true }; await relationalStore.deleteRdbStore(context,config); } }
  result.cases = [row]; return result;
}
