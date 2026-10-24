import { describe, expect, it } from '@ohos/hypium';
import {
  AssetCredentialBinding,
  AssetCredentialHeaderKind,
  AssetSecretMutationPort,
  AssetSecretQueryPort,
  AssetStoreCredentialManager,
  AssetStoreProviderCredentialPort
} from '../main/ets/provider/AssetStoreProviderCredentialPort';
import { ProviderCredential } from '../main/ets/provider/ProviderContracts';

class FixtureAssetSecretQueryPort implements AssetSecretQueryPort {
  calls: number = 0;
  alias: string = '';
  bytes: Uint8Array = new Uint8Array();
  fail: boolean = false;

  constructor(secret: string = 'fixture-token') {
    this.bytes = new Uint8Array(secret.length);
    for (let index: number = 0; index < secret.length; index += 1) {
      this.bytes[index] = secret.charCodeAt(index);
    }
  }

  querySecret(alias: string): Promise<Uint8Array> {
    this.calls += 1;
    this.alias = alias;
    if (this.fail) return Promise.reject(new Error('fixture secret must not leak'));
    return Promise.resolve(this.bytes);
  }
}

class FixtureAssetSecretMutationPort implements AssetSecretMutationPort {
  operation: string = '';
  alias: string = '';
  overwrite: boolean = false;
  secret: Uint8Array = new Uint8Array();
  fail: boolean = false;

  provisionSecret(alias: string, secret: Uint8Array, overwrite: boolean): Promise<void> {
    this.operation = 'provision';
    this.alias = alias;
    this.overwrite = overwrite;
    this.secret = secret;
    return this.fail ? Promise.reject(new Error('fixture secret must not leak')) : Promise.resolve();
  }

  rotateSecret(alias: string, secret: Uint8Array): Promise<void> {
    this.operation = 'rotate';
    this.alias = alias;
    this.secret = secret;
    return this.fail ? Promise.reject(new Error('fixture secret must not leak')) : Promise.resolve();
  }

  removeSecret(alias: string): Promise<void> {
    this.operation = 'remove';
    this.alias = alias;
    return this.fail ? Promise.reject(new Error('fixture secret must not leak')) : Promise.resolve();
  }
}

function binding(providerId: string, scope: string, alias: string,
  headerKind: AssetCredentialHeaderKind): AssetCredentialBinding {
  const result: AssetCredentialBinding = new AssetCredentialBinding();
  result.providerId = providerId;
  result.scope = scope;
  result.alias = alias;
  result.headerKind = headerKind;
  return result;
}

function allZero(value: Uint8Array): boolean {
  for (let index: number = 0; index < value.length; index += 1) {
    if (value[index] !== 0) return false;
  }
  return true;
}

async function errorMessage(action: () => Promise<ProviderCredential>): Promise<string> {
  try {
    await action();
    return '';
  } catch (error) {
    return error instanceof Error ? error.message : String(error);
  }
}

function constructorMessage(bindings: AssetCredentialBinding[]): string {
  try {
    new AssetStoreProviderCredentialPort(bindings, new FixtureAssetSecretQueryPort());
    return '';
  } catch (error) {
    return error instanceof Error ? error.message : String(error);
  }
}

export default function assetStoreProviderCredentialPortTest(): void {
  describe('AssetStoreProviderCredentialPort', (): void => {
    it('resolvesBearerCredentialForExactProviderAndScopeAndClearsBytes', 0, async () => {
      const secrets: FixtureAssetSecretQueryPort = new FixtureAssetSecretQueryPort('live-token');
      const configured: AssetCredentialBinding = binding('local-ai-gateway', 'gateway.invoke',
        'shuvi.gateway.invoke', AssetCredentialHeaderKind.AUTHORIZATION_BEARER);
      const port: AssetStoreProviderCredentialPort = new AssetStoreProviderCredentialPort([
        configured
      ], secrets);
      configured.scope = 'mutated.scope';
      configured.alias = 'mutated.alias';

      const credential: ProviderCredential = await port.resolve('local-ai-gateway', 'gateway.invoke');

      expect(credential.headers.Authorization).assertEqual('Bearer live-token');
      expect(secrets.calls).assertEqual(1);
      expect(secrets.alias).assertEqual('shuvi.gateway.invoke');
      expect(allZero(secrets.bytes)).assertTrue();
    });

    it('resolvesApiKeyWithoutAddingBearerPrefix', 0, async () => {
      const secrets: FixtureAssetSecretQueryPort = new FixtureAssetSecretQueryPort('api-key-value');
      const port: AssetStoreProviderCredentialPort = new AssetStoreProviderCredentialPort([
        binding('remote-search', 'search.invoke', 'shuvi.search.invoke', AssetCredentialHeaderKind.X_API_KEY)
      ], secrets);

      const credential: ProviderCredential = await port.resolve('remote-search', 'search.invoke');

      expect(credential.headers['x-api-key']).assertEqual('api-key-value');
      expect(credential.headers.Authorization === undefined).assertTrue();
      expect(allZero(secrets.bytes)).assertTrue();
    });

    it('rejectsUnknownScopeBeforeAssetQuery', 0, async () => {
      const secrets: FixtureAssetSecretQueryPort = new FixtureAssetSecretQueryPort();
      const port: AssetStoreProviderCredentialPort = new AssetStoreProviderCredentialPort([
        binding('local-ai-gateway', 'gateway.invoke', 'shuvi.gateway.invoke',
          AssetCredentialHeaderKind.AUTHORIZATION_BEARER)
      ], secrets);

      const message: string = await errorMessage((): Promise<ProviderCredential> =>
        port.resolve('local-ai-gateway', 'admin'));

      expect(message).assertEqual('Credential binding not found');
      expect(secrets.calls).assertEqual(0);
    });

    it('rejectsDuplicateScopeAndAliasAtConstruction', 0, () => {
      const first: AssetCredentialBinding = binding('provider-a', 'model.invoke', 'asset-a',
        AssetCredentialHeaderKind.AUTHORIZATION_BEARER);
      const duplicateScope: AssetCredentialBinding = binding('provider-a', 'model.invoke', 'asset-b',
        AssetCredentialHeaderKind.X_API_KEY);
      const duplicateAlias: AssetCredentialBinding = binding('provider-b', 'search.invoke', 'asset-a',
        AssetCredentialHeaderKind.X_API_KEY);

      expect(constructorMessage([first, duplicateScope])).assertEqual(
        'Credential binding provider and scope must be unique');
      expect(constructorMessage([first, duplicateAlias])).assertEqual('Credential asset alias must be unique');
    });

    it('rejectsMalformedSecretAndDoesNotExposeSecretInErrors', 0, async () => {
      const malformed: FixtureAssetSecretQueryPort = new FixtureAssetSecretQueryPort('line-one\r\nline-two');
      const port: AssetStoreProviderCredentialPort = new AssetStoreProviderCredentialPort([
        binding('provider-a', 'model.invoke', 'asset-a', AssetCredentialHeaderKind.AUTHORIZATION_BEARER)
      ], malformed);

      const message: string = await errorMessage((): Promise<ProviderCredential> =>
        port.resolve('provider-a', 'model.invoke'));

      expect(message).assertEqual('Credential resolution failed');
      expect(message.includes('line-one')).assertFalse();
      expect(allZero(malformed.bytes)).assertTrue();

      const unavailable: FixtureAssetSecretQueryPort = new FixtureAssetSecretQueryPort();
      unavailable.fail = true;
      const unavailablePort: AssetStoreProviderCredentialPort = new AssetStoreProviderCredentialPort([
        binding('provider-a', 'model.invoke', 'asset-a', AssetCredentialHeaderKind.AUTHORIZATION_BEARER)
      ], unavailable);
      const unavailableMessage: string = await errorMessage((): Promise<ProviderCredential> =>
        unavailablePort.resolve('provider-a', 'model.invoke'));
      expect(unavailableMessage.includes('fixture secret')).assertFalse();
    });

    it('provisionsRotatesAndRemovesThroughNarrowMutationPort', 0, async () => {
      const mutations: FixtureAssetSecretMutationPort = new FixtureAssetSecretMutationPort();
      const manager: AssetStoreCredentialManager = new AssetStoreCredentialManager(mutations);
      const provisioned: Uint8Array = new FixtureAssetSecretQueryPort('initial-token').bytes;

      await manager.provision('provider.token', provisioned, true);

      expect(mutations.operation).assertEqual('provision');
      expect(mutations.alias).assertEqual('provider.token');
      expect(mutations.overwrite).assertTrue();
      expect(allZero(provisioned)).assertTrue();

      const rotated: Uint8Array = new FixtureAssetSecretQueryPort('rotated-token').bytes;
      await manager.rotate('provider.token', rotated);
      expect(mutations.operation).assertEqual('rotate');
      expect(allZero(rotated)).assertTrue();

      await manager.remove('provider.token');
      expect(mutations.operation).assertEqual('remove');
    });

    it('clearsRejectedSecretsAndSanitizesMutationFailures', 0, async () => {
      const mutations: FixtureAssetSecretMutationPort = new FixtureAssetSecretMutationPort();
      mutations.fail = true;
      const manager: AssetStoreCredentialManager = new AssetStoreCredentialManager(mutations);
      const failed: Uint8Array = new FixtureAssetSecretQueryPort('sensitive-token').bytes;

      const failedMessage: string = await mutationMessage((): Promise<void> =>
        manager.rotate('provider.token', failed));

      expect(failedMessage).assertEqual('Credential asset rotation failed');
      expect(failedMessage.includes('sensitive-token')).assertFalse();
      expect(allZero(failed)).assertTrue();

      const malformed: Uint8Array = new Uint8Array([0x61, 0x0a, 0x62]);
      const malformedMessage: string = await mutationMessage((): Promise<void> =>
        manager.provision('provider.token', malformed));
      expect(malformedMessage).assertEqual('Credential secret is invalid');
      expect(allZero(malformed)).assertTrue();
    });
  });
}

async function mutationMessage(action: () => Promise<void>): Promise<string> {
  try {
    await action();
    return '';
  } catch (error) {
    return error instanceof Error ? error.message : String(error);
  }
}
