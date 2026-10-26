import cryptoFramework from '@ohos.security.cryptoFramework';
import util from '@ohos.util';
import { ConnectorDigestPort } from '@harmony_agent/agent-connectors';
import { MemoryDigestPort, MemorySnapshotIntegrityPort, SnapshotIntegrityPort } from '@harmony_agent/agent-storage';

/** SHA-256 checksum, not a keyed MAC. Upstream digest ports are synchronous. */
export class AgentHostDigest implements ConnectorDigestPort, MemoryDigestPort,
  MemorySnapshotIntegrityPort, SnapshotIntegrityPort {
  digest(value: string): string {
    // Bound synchronous work; oversized snapshots fail instead of being silently truncated.
    const maxBytes: number = 2 * 1024 * 1024;
    if (value.length > maxBytes) throw new Error('AGENT_DIGEST_INPUT_TOO_LARGE');
    const bytes: Uint8Array = new util.TextEncoder().encodeInto(value);
    if (bytes.length > maxBytes) {
      bytes.fill(0);
      throw new Error('AGENT_DIGEST_INPUT_TOO_LARGE');
    }
    try {
      const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
      md.updateSync({ data: bytes });
      const hash: Uint8Array = md.digestSync().data;
      if (hash.length !== 32) throw new Error('AGENT_DIGEST_FAILED');
      let result: string = '';
      for (let i: number = 0; i < hash.length; i++) result += hash[i].toString(16).padStart(2, '0');
      return result;
    } catch (error) {
      throw new Error('AGENT_DIGEST_FAILED');
    } finally {
      bytes.fill(0);
    }
  }
}
