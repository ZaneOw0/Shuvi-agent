import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { KnowledgeIdentityPort } from '../domain/KnowledgePorts';
import { ImageKnowledgeFailure } from '../domain/ImageKnowledgeModels';

export class ImageWorkerIdentity implements KnowledgeIdentityPort {
  id(): string { throw new ImageKnowledgeFailure('WorkerIdentityAllocationForbidden','image-worker'); }
  async hash(bytes: Uint8Array): Promise<string> {
    const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
    const blob: cryptoFramework.DataBlob = { data: bytes };
    await md.update(blob);
    let hex: string = '';
    for (const byte of (await md.digest()).data) { hex += byte.toString(16).padStart(2,'0'); }
    return hex;
  }
}
