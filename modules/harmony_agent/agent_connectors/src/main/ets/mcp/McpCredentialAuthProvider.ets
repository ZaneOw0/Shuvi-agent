import {
  McpAuthProvider,
  McpClientError,
  McpErrorCode,
  McpServerProfile
} from '@harmony_agent/mcp-client';
import { ProviderCredential, ProviderCredentialPort } from '../provider/ProviderContracts';

export class McpCredentialBinding {
  serverId: string = '';
  credentialScope: string = '';
}

function validText(value: string): boolean {
  return value.trim().length > 0;
}

/** Resolves MCP bearer or x-api-key headers at call time without storing secrets in profiles. */
export class McpCredentialAuthProvider implements McpAuthProvider {
  private readonly credentials: ProviderCredentialPort;
  private readonly bindings: McpCredentialBinding[] = [];

  constructor(credentials: ProviderCredentialPort) {
    this.credentials = credentials;
  }

  register(binding: McpCredentialBinding): boolean {
    if (!validText(binding.serverId) || !validText(binding.credentialScope)) return false;
    for (let index: number = 0; index < this.bindings.length; index++) {
      if (this.bindings[index].serverId === binding.serverId) return false;
    }
    const copy: McpCredentialBinding = new McpCredentialBinding();
    copy.serverId = binding.serverId;
    copy.credentialScope = binding.credentialScope;
    this.bindings.push(copy);
    return true;
  }

  async getHeaders(profile: McpServerProfile, _operation: string): Promise<Record<string, string>> {
    const binding: McpCredentialBinding | undefined = this.find(profile.id);
    if (binding === undefined) return {};
    const credential: ProviderCredential = await this.credentials.resolve(profile.id, binding.credentialScope);
    const keys: string[] = Object.keys(credential.headers);
    if (keys.length !== 1 || (keys[0] !== 'Authorization' && keys[0] !== 'x-api-key')) {
      throw new McpClientError(McpErrorCode.AUTHENTICATION,
        'MCP credential provider returned an unsupported header set', profile.id);
    }
    const value: string = credential.headers[keys[0]];
    if (!validText(value) || /[\r\n]/.test(value) ||
      (keys[0] === 'Authorization' && !value.startsWith('Bearer '))) {
      throw new McpClientError(McpErrorCode.AUTHENTICATION,
        'MCP credential provider returned an invalid credential', profile.id);
    }
    const headers: Record<string, string> = {};
    headers[keys[0]] = value;
    return headers;
  }

  private find(serverId: string): McpCredentialBinding | undefined {
    for (let index: number = 0; index < this.bindings.length; index++) {
      if (this.bindings[index].serverId === serverId) return this.bindings[index];
    }
    return undefined;
  }
}
