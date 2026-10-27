import { AgentErrorClass } from '@harmony_agent/agent-contracts';
import {
  ConnectorDigestPort, GenericModelProvider, ProviderCatalog, ProviderCredentialPort,
  ProviderErrorCode, ProviderOperationRunner, ProviderPriceSnapshot, ProviderTimerPort,
  ProviderTransportError, RegisteredModelProvider, SystemProviderTimer, ModelTransportPort
} from '@harmony_agent/agent-connectors';
import { DeepSeekHttpClientPort, DeepSeekModelTransport, DeepSeekProfile, createDeepSeekModelProfile } from './DeepSeekProtocol';
import { ArkTsDeepSeekHttpClient } from './DeepSeekHttpClient';

export class DeepSeekProviderBundle {
  readonly registered: RegisteredModelProvider;
  readonly provider: GenericModelProvider;
  constructor(registered: RegisteredModelProvider, provider: GenericModelProvider) {
    this.registered = registered;
    this.provider = provider;
  }
}

// No provider calls or credential reads occur until generate() is explicitly invoked.
export function createDeepSeekProvider(profile: DeepSeekProfile, price: ProviderPriceSnapshot,
  digest: ConnectorDigestPort, credentials: ProviderCredentialPort,
  client: DeepSeekHttpClientPort = new ArkTsDeepSeekHttpClient(),
  timer: ProviderTimerPort = new SystemProviderTimer(), transport?: ModelTransportPort): DeepSeekProviderBundle {
  if (!profile.available || price.inputMicrosPerMillionTokens <= 0 || price.outputMicrosPerMillionTokens <= 0) {
    throw new ProviderTransportError(ProviderErrorCode.CONFIGURATION, AgentErrorClass.CONFIGURATION,
      'DeepSeek requires an enabled profile and a reviewed nonzero price snapshot');
  }
  const catalog: ProviderCatalog = new ProviderCatalog(digest);
  const model = createDeepSeekModelProfile(profile);
  if (!catalog.registerModel(model, price)) {
    throw new ProviderTransportError(ProviderErrorCode.CONFIGURATION, AgentErrorClass.CONFIGURATION,
      'DeepSeek model or price registration failed');
  }
  const registered: RegisteredModelProvider | undefined = catalog.getModel(model.registryModelId);
  if (registered === undefined) {
    throw new ProviderTransportError(ProviderErrorCode.CONFIGURATION, AgentErrorClass.CONFIGURATION,
      'DeepSeek registered model is unavailable');
  }
  return new DeepSeekProviderBundle(registered, new GenericModelProvider(registered,
    transport === undefined ? new DeepSeekModelTransport(profile, client) : transport, new ProviderOperationRunner(credentials, timer)));
}
