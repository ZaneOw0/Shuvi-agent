import { ImageHeaderReader } from '../main/ets/knowledge/domain/ImageKnowledgePorts';
import { ImageKnowledgeFailure, ImageLimits } from '../main/ets/knowledge/domain/ImageKnowledgeModels';
import { KnowledgeCancellation } from '../main/ets/knowledge/domain/PdfKnowledgeModels';
import { imageInspectHeader } from '../main/ets/knowledge/pipeline/ImageHeaderPolicy';

export class ImageTestReader implements ImageHeaderReader {
  length: number; bytes: Uint8Array; largestRead: number = 0;
  constructor(bytes: Uint8Array) { this.bytes = bytes; this.length = bytes.length; }
  async read(offset: number, length: number): Promise<Uint8Array> {
    if (length > ImageLimits.readBytes) { throw new ImageKnowledgeFailure('ReadAllocationBudget','test'); }
    this.largestRead = Math.max(this.largestRead,length); return this.bytes.slice(offset,offset+length);
  }
}
export async function imageRejects(bytes: Uint8Array, suffix: string): Promise<boolean> {
  try { await imageInspectHeader(new ImageTestReader(bytes),suffix,new KnowledgeCancellation()); return false; } catch { return true; }
}
