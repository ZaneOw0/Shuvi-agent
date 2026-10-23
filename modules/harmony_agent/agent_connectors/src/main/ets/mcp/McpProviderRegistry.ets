import { McpServerProfile } from '@harmony_agent/mcp-client';
import { canonicalJson } from './CanonicalJson';
import { ConnectorDigestPort, McpProviderRegistration } from './McpConnectorTypes';

function validText(value: string): boolean {
  return value.trim().length > 0;
}

function copyProfile(source: McpServerProfile): McpServerProfile {
  return {
    id: source.id,
    endpoint: source.endpoint,
    displayName: source.displayName,
    protocolMode: source.protocolMode,
    connectTimeoutMs: source.connectTimeoutMs,
    requestTimeoutMs: source.requestTimeoutMs,
    maxResponseBytes: source.maxResponseBytes,
    allowInsecureHttp: source.allowInsecureHttp,
    retryToolCallOnExpiredSession: source.retryToolCallOnExpiredSession
  };
}

function copyRegistration(source: McpProviderRegistration): McpProviderRegistration {
  const result: McpProviderRegistration = new McpProviderRegistration();
  result.profile = copyProfile(source.profile);
  result.profileVersion = source.profileVersion;
  result.profileDigest = source.profileDigest;
  return result;
}

export class McpProviderRegistry {
  private readonly digestPort: ConnectorDigestPort;
  private readonly registrations: McpProviderRegistration[] = [];

  constructor(digestPort: ConnectorDigestPort) {
    this.digestPort = digestPort;
  }

  register(profile: McpServerProfile, profileVersion: string): boolean {
    if (!validText(profile.id) || !validText(profile.endpoint) || !validText(profileVersion)) {
      return false;
    }
    const entry: McpProviderRegistration = new McpProviderRegistration();
    entry.profile = copyProfile(profile);
    entry.profileVersion = profileVersion;
    entry.profileDigest = this.digestPort.digest(canonicalJson(copyProfile(profile) as Object));
    const index: number = this.find(profile.id);
    if (index >= 0) this.registrations[index] = entry; else this.registrations.push(entry);
    return true;
  }

  get(serverId: string): McpProviderRegistration | undefined {
    const index: number = this.find(serverId);
    return index < 0 ? undefined : copyRegistration(this.registrations[index]);
  }

  private find(serverId: string): number {
    for (let index: number = 0; index < this.registrations.length; index++) {
      if (this.registrations[index].profile.id === serverId) return index;
    }
    return -1;
  }
}
