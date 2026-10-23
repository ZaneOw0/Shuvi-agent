import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { KnowledgeStorageScope } from '../domain/KnowledgeStorageScope';
import { KnowledgeStoreHost } from '../infra/KnowledgeStoreHost';
import { TextRdbRepository } from '../infra/TextRdbRepository';
import { PdfKnowledgeRepository } from '../infra/PdfKnowledgeRepository';
import { PdfAssetAdapter } from '../infra/PdfAssetAdapter';
import { PdfKnowledgeDocument, KnowledgeCleanupIntent, KnowledgeFailure } from '../domain/PdfKnowledgeModels';
export async function knowledgeCleanupOwnedFailures(context: common.Context): Promise<number> {
  let completed: number = 0;
  for (const run of ['000001a1451848c5','000001a14526622c']) {
    const scope: KnowledgeStorageScope = KnowledgeStorageScope.isolated(run); scope.requireTestOwner(run);
    const host: KnowledgeStoreHost = KnowledgeStoreHost.forContext(context,scope); const text: TextRdbRepository = new TextRdbRepository(context,host); const pdf: PdfKnowledgeRepository = new PdfKnowledgeRepository(host); const assets: PdfAssetAdapter = new PdfAssetAdapter(context.filesDir,context.cacheDir,pdf,scope);
    await text.open(); await pdf.open();
    try {
      const docs: PdfKnowledgeDocument[] = await pdf.list();
      if (docs.some((doc: PdfKnowledgeDocument): boolean => doc.sourceKey !== `fixture-${run}` && doc.sourceKey !== `mapping-${run}`)) { throw new KnowledgeFailure('CleanupOwnerMismatch','test'); }
      await pdf.reconcile(`cleanup-${run}`);
      for (const doc of docs) { await pdf.deleteDocument(doc.id); }
      for (const intent of await pdf.cleanups()) { const claim: KnowledgeCleanupIntent | undefined = await pdf.claimCleanup(intent.id); if (claim === undefined) { throw new KnowledgeFailure('CleanupStillLeased','test'); } await assets.remove(claim); await pdf.finishCleanup(claim,''); }
      if ((await pdf.assetIds()).length !== 0) { throw new KnowledgeFailure('CleanupAssetsRemain','test'); }
    } finally { await pdf.close(); await text.close(); }
    scope.requireTestOwner(run); const config: relationalStore.StoreConfig = { name: scope.databaseName,securityLevel: relationalStore.SecurityLevel.S3,vector: false }; await relationalStore.deleteRdbStore(context,config); completed++;
  } return completed;
}
