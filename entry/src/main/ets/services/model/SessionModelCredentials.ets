import { ProviderCredential, ProviderCredentialPort } from '@harmony_agent/agent-connectors';
import { SingleAgentHostResourcePort } from '@harmony_agent/agent-runtime';

/** One explicitly configured session; never persists or logs the supplied key. */
export class SessionModelCredentials implements ProviderCredentialPort, SingleAgentHostResourcePort {
  private secret: Uint8Array = new Uint8Array(0);
  private active: boolean = false;

  // Consumes the caller's byte buffer, including on invalid input.
  configure(value: Uint8Array): void {
    try {
      if (this.active) throw new Error('MODEL_CREDENTIAL_SESSION_ACTIVE');
      this.secret.fill(0);
      this.secret = new Uint8Array(0);
      if (value.length === 0 || value.length > 4096) throw new Error('MODEL_CREDENTIAL_INVALID');
      for (let i: number = 0; i < value.length; i++) {
        if (value[i] < 33 || value[i] > 126) throw new Error('MODEL_CREDENTIAL_INVALID');
      }
      this.secret = new Uint8Array(value.length);
      this.secret.set(value);
    } finally {
      value.fill(0);
    }
  }

  open(): Promise<void> {
    if (this.secret.length === 0) return Promise.reject(new Error('MODEL_CREDENTIAL_REQUIRED'));
    this.active = true;
    return Promise.resolve();
  }

  resolve(providerId: string, scope: string): Promise<ProviderCredential> {
    if (!this.active || this.secret.length === 0 || providerId !== 'deepseek-direct' || scope !== 'deepseek.invoke') {
      return Promise.reject(new Error('MODEL_CREDENTIAL_UNAVAILABLE'));
    }
    let key: string = '';
    for (let i: number = 0; i < this.secret.length; i++) key += String.fromCharCode(this.secret[i]);
    const value: ProviderCredential = new ProviderCredential();
    const headers: Record<string, string> = { 'Authorization': 'Bearer ' + key };
    value.headers = headers;
    return Promise.resolve(value);
  }

  close(): Promise<void> {
    this.active = false;
    this.secret.fill(0);
    this.secret = new Uint8Array(0);
    return Promise.resolve();
  }
}
