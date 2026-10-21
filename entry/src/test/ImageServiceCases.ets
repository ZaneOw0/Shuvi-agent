import { ImageParseConsent, ImageOriginal } from '../main/ets/knowledge/domain/ImageKnowledgeModels';
import { imageConsentReason } from '../main/ets/knowledge/pipeline/ImageContentNormalizer';
import { ImageIngestionService } from '../main/ets/knowledge/application/ImageIngestionService';

export function imageConsentBoundary(original: ImageOriginal, consent: ImageParseConsent, now: number, session: string, revision: number): string {
  return imageConsentReason(original,consent,now,session,revision);
}
export async function imageRestoreCheckpointCase(service: ImageIngestionService, jobId: string): Promise<void> {
  await service.pauseCheckpoint(); await service.initialize(); await service.resumeReview(jobId);
}
export async function imageArchiveRestoreCase(service: ImageIngestionService, documentId: string): Promise<void> {
  await service.archive(documentId,true); await service.archive(documentId,false);
}
