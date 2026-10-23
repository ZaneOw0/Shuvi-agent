import { taskpool } from '@kit.ArkTS';
import { ImageWorkerIdentity } from './ImageWorkerSupport';
import { ImageOriginal, ImageSnapshot, ImageWorkerResult, ImageKnowledgeFailure } from '../domain/ImageKnowledgeModels';
import { ImageContentPort } from '../domain/ImageKnowledgePorts';
import { KnowledgeCancellation, KnowledgeFailure } from '../domain/PdfKnowledgeModels';
import { imageNormalizeContent, IMAGE_TEXT_PROFILE } from '../pipeline/ImageContentNormalizer';
import { imageReadOriginal, imageDecodeSnapshot, imageSealSnapshot, imageVerifySnapshot } from '../pipeline/ImageSnapshotCodec';
import { BoundedDocumentJson } from '../pipeline/BoundedDocumentJson';
import { pdfCodecUtf8 } from '../pipeline/PdfSnapshotCodec';

@Concurrent
async function imageNormalizeWorker(originalBytes: Uint8Array, bytes: Uint8Array, profile: string, generation: string): Promise<ImageWorkerResult> {
  const output: ImageWorkerResult = new ImageWorkerResult(); output.operation = 'Normalize';
  try {
    const cancel: KnowledgeCancellation = new KnowledgeCancellation();
    if (taskpool.Task.isCanceled()) { throw new ImageKnowledgeFailure('Canceled','image-worker'); }
    const original: ImageOriginal = imageReadOriginal(new BoundedDocumentJson(originalBytes,cancel).read());
    const snapshot: ImageSnapshot = imageNormalizeContent(original,bytes,profile,generation,cancel); const identity: ImageWorkerIdentity = new ImageWorkerIdentity();
    snapshot.resultHash = profile === IMAGE_TEXT_PROFILE ? snapshot.projection.zipHash : await identity.hash(bytes); await imageSealSnapshot(snapshot,identity,cancel);
    output.payload = pdfCodecUtf8(JSON.stringify(snapshot)); if (output.payload.length > 8388608) { throw new ImageKnowledgeFailure('ImageWorkerPayloadBudget','image-worker'); }
    if (taskpool.Task.isCanceled()) { throw new ImageKnowledgeFailure('Canceled','image-worker'); } output.status = 'Success';
  } catch (error) {
    output.status = 'Rejected'; output.payload = new Uint8Array(0); output.category = error instanceof ImageKnowledgeFailure ? error.category : error instanceof KnowledgeFailure ? 'ImageTextJsonInvalidOrBudget' : 'NormalizeFailed'; output.stage = 'image-normalize';
  } return output;
}
export class ImageProcessingAdapter implements ImageContentPort {
  private task: taskpool.GenericsTask<[Uint8Array,Uint8Array,string,string],ImageWorkerResult> | undefined = undefined;
  cancel(): void { if (this.task !== undefined) { try { taskpool.cancel(this.task); } catch { /* Running native work is not hard killed. */ } } }
  async normalize(original: ImageOriginal, bytes: Uint8Array, profile: string, generation: string, cancel: KnowledgeCancellation): Promise<ImageSnapshot> {
    cancel.check(); if (this.task !== undefined || bytes.length > 8388608) { throw new ImageKnowledgeFailure('ImageProcessingBusyOrBudget','image-worker'); }
    this.task = new taskpool.GenericsTask<[Uint8Array,Uint8Array,string,string],ImageWorkerResult>(imageNormalizeWorker,pdfCodecUtf8(JSON.stringify(original)),bytes,profile,generation);
    try {
      const result: ImageWorkerResult = await taskpool.execute<[Uint8Array,Uint8Array,string,string],ImageWorkerResult>(this.task); cancel.check();
      if (result.wire !== 'IMAGE-WORKER-RESULT-1' || result.operation !== 'Normalize' || !(result.payload instanceof Uint8Array) || result.payload.length > 8388608 || result.code !== 0) { throw new ImageKnowledgeFailure('ImageWorkerEnvelopeInvalid','image-worker'); }
      if (result.status !== 'Success') {
        const allowed: string[] = ['UnknownImageProfile','DocvortexSchemaMismatch','DocvortexCoverageOrProducerMissing','DocvortexNativeBlocksOutsideTextProjectionUseMarkdownMember','ImageProjectionBinding','ImageProjectionNodeBudget','ImageTextJsonInvalidOrBudget','UnsupportedProfileField','ControlledSourceOrCoverageMismatch','ImageNodeBudgetOrIdentity','ImageBlockIdentityOrOrder','EmptyBlockHasText','TextBlockEmpty','ExplicitEmptyEvidenceRequired','ImageWorkerPayloadBudget','Canceled','NormalizeFailed'];
        throw new ImageKnowledgeFailure(allowed.indexOf(result.category) >= 0 ? result.category : 'ImageWorkerRejected','image-worker');
      }
      if (result.category.length !== 0 || result.stage.length !== 0) { throw new ImageKnowledgeFailure('ImageWorkerSuccessConflict','image-worker'); }
      const snapshot: ImageSnapshot = imageDecodeSnapshot(result.payload,cancel); await imageVerifySnapshot(snapshot,new ImageWorkerIdentity(),cancel); return snapshot;
    } finally { this.task = undefined; }
  }
}
