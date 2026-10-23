import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { KnowledgeIdentityPort } from '../domain/KnowledgePorts';
import { ParsedIdentityPort } from '../domain/ParsedDocumentPorts';
import { documentDigestHex } from './DocumentFileOperations';

export class KnowledgePlatformIdentity implements KnowledgeIdentityPort, ParsedIdentityPort {
  id(): string { return 'kb-' + documentDigestHex(cryptoFramework.createRandom().generateRandomSync(16).data); }
  async hash(bytes: Uint8Array): Promise<string> {
    const digest: cryptoFramework.Md = cryptoFramework.createMd('SHA256'); const blob: cryptoFramework.DataBlob = { data: bytes };
    // Md.update is optional; native update rejects an empty DataBlob.
    if (bytes.length > 0) { await digest.update(blob); } return documentDigestHex((await digest.digest()).data);
  }
}
