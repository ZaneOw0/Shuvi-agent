import asset from '@ohos.security.asset';
import util from '@ohos.util';
import { ProviderCredential, ProviderCredentialPort } from './ProviderContracts';

export const ASSET_CREDENTIAL_STORE_VERSION: string = '1.0';

export enum AssetCredentialHeaderKind {
  AUTHORIZATION_BEARER = 'authorizationBearer',
  X_API_KEY = 'xApiKey'
}

export class AssetCredentialBinding {
  providerId: string = '';
  scope: string = '';
  alias: string = '';
  headerKind: AssetCredentialHeaderKind = AssetCredentialHeaderKind.AUTHORIZATION_BEARER;
}

export interface AssetSecretQueryPort {
  querySecret(alias: string): Promise<Uint8Array>;
}

export interface AssetSecretMutationPort {
  provisionSecret(alias: string, secret: Uint8Array, overwrite: boolean): Promise<void>;
  rotateSecret(alias: string, secret: Uint8Array): Promise<void>;
  removeSecret(alias: string): Promise<void>;
}

export class AssetCredentialProtectionPolicy {
  accessibility: asset.Accessibility = asset.Accessibility.DEVICE_FIRST_UNLOCKED;
  requirePasswordSet: boolean = false;
}

function validIdentifier(value: string): boolean {
  if (value.length === 0 || value.length > 128 || value !== value.trim()) return false;
  return !value.includes('\r') && !value.includes('\n') && !value.includes('\u0000');
}

function clearBytes(value: Uint8Array): void {
  for (let index: number = 0; index < value.length; index += 1) value[index] = 0;
}

function copyAndClear(value: Uint8Array): Uint8Array {
  const copied: Uint8Array = new Uint8Array(value.length);
  copied.set(value);
  clearBytes(value);
  return copied;
}

export class HarmonyAssetSecretQueryPort implements AssetSecretQueryPort {
  async querySecret(alias: string): Promise<Uint8Array> {
    if (!validIdentifier(alias)) throw new Error('Credential asset alias is invalid');
    const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    const encodedAlias: Uint8Array = new util.TextEncoder('utf-8').encodeInto(alias);
    query.set(asset.Tag.ALIAS, encodedAlias);
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    query.set(asset.Tag.RETURN_LIMIT, 1);
    let records: asset.AssetMap[];
    try {
      records = await asset.query(query);
    } catch (error) {
      throw new Error('Credential asset resolution failed');
    }
    if (records.length !== 1) throw new Error('Credential asset resolution failed');
    const secret: asset.Value | undefined = records[0].get(asset.Tag.SECRET);
    if (!(secret instanceof Uint8Array) || secret.length === 0) {
      throw new Error('Credential asset resolution failed');
    }
    return copyAndClear(secret);
  }
}

/** API 26 AssetStore mutations used only by the product host's provisioning path. */
export class HarmonyAssetSecretMutationPort implements AssetSecretMutationPort {
  private readonly policy: AssetCredentialProtectionPolicy;

  constructor(policy: AssetCredentialProtectionPolicy = new AssetCredentialProtectionPolicy()) {
    if (policy.accessibility !== asset.Accessibility.DEVICE_POWERED_ON &&
      policy.accessibility !== asset.Accessibility.DEVICE_FIRST_UNLOCKED &&
      policy.accessibility !== asset.Accessibility.DEVICE_UNLOCKED) {
      throw new Error('Credential asset protection policy is invalid');
    }
    this.policy = new AssetCredentialProtectionPolicy();
    this.policy.accessibility = policy.accessibility;
    this.policy.requirePasswordSet = policy.requirePasswordSet;
  }

  async provisionSecret(alias: string, secret: Uint8Array, overwrite: boolean): Promise<void> {
    const attributes: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    const encodedAlias: Uint8Array = new util.TextEncoder('utf-8').encodeInto(alias);
    try {
      attributes.set(asset.Tag.ALIAS, encodedAlias);
      attributes.set(asset.Tag.SECRET, secret);
      attributes.set(asset.Tag.ACCESSIBILITY, this.policy.accessibility);
      attributes.set(asset.Tag.REQUIRE_PASSWORD_SET, this.policy.requirePasswordSet);
      attributes.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER);
      attributes.set(asset.Tag.CONFLICT_RESOLUTION, overwrite ?
        asset.ConflictResolution.OVERWRITE : asset.ConflictResolution.THROW_ERROR);
      try {
        await asset.add(attributes);
      } catch (error) {
        throw new Error('Credential asset mutation failed');
      }
    } finally {
      clearBytes(encodedAlias);
    }
  }

  async rotateSecret(alias: string, secret: Uint8Array): Promise<void> {
    const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    const update: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    const encodedAlias: Uint8Array = new util.TextEncoder('utf-8').encodeInto(alias);
    try {
      query.set(asset.Tag.ALIAS, encodedAlias);
      update.set(asset.Tag.SECRET, secret);
      try {
        await asset.update(query, update);
      } catch (error) {
        throw new Error('Credential asset mutation failed');
      }
    } finally {
      clearBytes(encodedAlias);
    }
  }

  async removeSecret(alias: string): Promise<void> {
    const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    const encodedAlias: Uint8Array = new util.TextEncoder('utf-8').encodeInto(alias);
    try {
      query.set(asset.Tag.ALIAS, encodedAlias);
      try {
        await asset.remove(query);
      } catch (error) {
        throw new Error('Credential asset mutation failed');
      }
    } finally {
      clearBytes(encodedAlias);
    }
  }
}

/**
 * Narrow write-side service for credential provisioning and rotation. Secret
 * buffers are consumed and zeroed after the platform operation completes.
 */
export class AssetStoreCredentialManager {
  private readonly mutations: AssetSecretMutationPort;

  constructor(mutations: AssetSecretMutationPort = new HarmonyAssetSecretMutationPort()) {
    this.mutations = mutations;
  }

  async provision(alias: string, secret: Uint8Array, overwrite: boolean = false): Promise<void> {
    validateSecretInput(alias, secret);
    try {
      await this.mutations.provisionSecret(alias, secret, overwrite);
    } catch (error) {
      throw new Error('Credential asset provisioning failed');
    } finally {
      clearBytes(secret);
    }
  }

  async rotate(alias: string, secret: Uint8Array): Promise<void> {
    validateSecretInput(alias, secret);
    try {
      await this.mutations.rotateSecret(alias, secret);
    } catch (error) {
      throw new Error('Credential asset rotation failed');
    } finally {
      clearBytes(secret);
    }
  }

  async remove(alias: string): Promise<void> {
    if (!validIdentifier(alias)) throw new Error('Credential asset alias is invalid');
    try {
      await this.mutations.removeSecret(alias);
    } catch (error) {
      throw new Error('Credential asset removal failed');
    }
  }
}

function validateSecretInput(alias: string, secret: Uint8Array): void {
  if (!validIdentifier(alias)) {
    clearBytes(secret);
    throw new Error('Credential asset alias is invalid');
  }
  if (secret.length === 0 || secret.length > 4096) {
    clearBytes(secret);
    throw new Error('Credential secret is invalid');
  }
  for (let index: number = 0; index < secret.length; index += 1) {
    if (secret[index] < 0x21 || secret[index] > 0x7e) {
      clearBytes(secret);
      throw new Error('Credential secret is invalid');
    }
  }
}

function validateBindings(bindings: AssetCredentialBinding[]): void {
  if (bindings.length === 0) throw new Error('At least one credential binding is required');
  for (let index: number = 0; index < bindings.length; index += 1) {
    const current: AssetCredentialBinding = bindings[index];
    if (!validIdentifier(current.providerId) || !validIdentifier(current.scope) ||
      !validIdentifier(current.alias)) {
      throw new Error('Credential binding is invalid');
    }
    if (current.headerKind !== AssetCredentialHeaderKind.AUTHORIZATION_BEARER &&
      current.headerKind !== AssetCredentialHeaderKind.X_API_KEY) {
      throw new Error('Credential binding header kind is invalid');
    }
    for (let priorIndex: number = 0; priorIndex < index; priorIndex += 1) {
      const prior: AssetCredentialBinding = bindings[priorIndex];
      if (prior.providerId === current.providerId && prior.scope === current.scope) {
        throw new Error('Credential binding provider and scope must be unique');
      }
      if (prior.alias === current.alias) {
        throw new Error('Credential asset alias must be unique');
      }
    }
  }
}

function copyBindings(bindings: AssetCredentialBinding[]): AssetCredentialBinding[] {
  const copied: AssetCredentialBinding[] = [];
  for (let index: number = 0; index < bindings.length; index += 1) {
    const source: AssetCredentialBinding = bindings[index];
    const target: AssetCredentialBinding = new AssetCredentialBinding();
    target.providerId = source.providerId;
    target.scope = source.scope;
    target.alias = source.alias;
    target.headerKind = source.headerKind;
    copied.push(target);
  }
  return copied;
}

function decodeSecret(secretBytes: Uint8Array): string {
  if (secretBytes.length === 0) throw new Error('Credential resolution failed');
  let secret: string = '';
  for (let index: number = 0; index < secretBytes.length; index += 1) {
    const value: number = secretBytes[index];
    if (value < 0x21 || value > 0x7e) throw new Error('Credential resolution failed');
    secret += String.fromCharCode(value);
  }
  return secret;
}

export class AssetStoreProviderCredentialPort implements ProviderCredentialPort {
  private readonly bindings: AssetCredentialBinding[];
  private readonly secrets: AssetSecretQueryPort;

  constructor(bindings: AssetCredentialBinding[], secrets: AssetSecretQueryPort) {
    validateBindings(bindings);
    this.bindings = copyBindings(bindings);
    this.secrets = secrets;
  }

  async resolve(providerId: string, scope: string): Promise<ProviderCredential> {
    let binding: AssetCredentialBinding | undefined = undefined;
    for (let index: number = 0; index < this.bindings.length; index += 1) {
      const candidate: AssetCredentialBinding = this.bindings[index];
      if (candidate.providerId === providerId && candidate.scope === scope) {
        binding = candidate;
        break;
      }
    }
    if (binding === undefined) throw new Error('Credential binding not found');

    let secretBytes: Uint8Array;
    try {
      secretBytes = await this.secrets.querySecret(binding.alias);
    } catch (error) {
      throw new Error('Credential resolution failed');
    }
    try {
      const secret: string = decodeSecret(secretBytes);
      const credential: ProviderCredential = new ProviderCredential();
      if (binding.headerKind === AssetCredentialHeaderKind.AUTHORIZATION_BEARER) {
        credential.headers.Authorization = 'Bearer ' + secret;
      } else {
        credential.headers['x-api-key'] = secret;
      }
      return credential;
    } finally {
      clearBytes(secretBytes);
    }
  }
}
