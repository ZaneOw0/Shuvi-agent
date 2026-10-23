import {
  ContractCodec,
  DataBoundary,
  IdempotencyMode,
  PrivacyClass,
  SideEffect,
  ToolDescriptor,
  ToolSourceType
} from '@harmony_agent/agent-contracts';
import { ModelRegistryEntry, ToolRegistryEntry } from '@harmony_agent/agent-runtime';
import { canonicalJson, parseJsonObject } from '../mcp/CanonicalJson';
import { ConnectorDigestPort } from '../mcp/McpConnectorTypes';
import {
  ProviderCapabilityKind,
  ProviderPriceSnapshot,
  RemoteApiProfile
} from './ProviderContracts';

export class ModelProviderProfile {
  registryModelId: string = '';
  providerId: string = '';
  providerModelId: string = '';
  modelVersion: string = '';
  region: string = '';
  capabilityKind: ProviderCapabilityKind = ProviderCapabilityKind.MODEL;
  capabilityTags: string[] = [];
  privacyClasses: PrivacyClass[] = [];
  maxInputTokens: number = 0;
  maxOutputTokens: number = 0;
  qualityTier: number = 0;
  credentialScope: string = '';
  available: boolean = false;
}

function validText(value: string): boolean {
  return value.trim().length > 0;
}

function validCount(value: number): boolean {
  return Number.isSafeInteger(value) && value >= 0;
}

function estimateTokenCost(price: ProviderPriceSnapshot, inputTokens: number, outputTokens: number): number {
  return Math.ceil((inputTokens * price.inputMicrosPerMillionTokens +
    outputTokens * price.outputMicrosPerMillionTokens) / 1000000) + price.fixedCostMicros;
}

function copyPrice(source: ProviderPriceSnapshot): ProviderPriceSnapshot {
  const result: ProviderPriceSnapshot = new ProviderPriceSnapshot();
  result.snapshotId = source.snapshotId;
  result.providerId = source.providerId;
  result.capabilityId = source.capabilityId;
  result.capabilityVersion = source.capabilityVersion;
  result.region = source.region;
  result.currency = source.currency;
  result.inputMicrosPerMillionTokens = source.inputMicrosPerMillionTokens;
  result.outputMicrosPerMillionTokens = source.outputMicrosPerMillionTokens;
  result.fixedCostMicros = source.fixedCostMicros;
  result.effectiveAt = source.effectiveAt;
  result.snapshotDigest = source.snapshotDigest;
  return result;
}

function copyModelProfile(source: ModelProviderProfile): ModelProviderProfile {
  const result: ModelProviderProfile = new ModelProviderProfile();
  result.registryModelId = source.registryModelId;
  result.providerId = source.providerId;
  result.providerModelId = source.providerModelId;
  result.modelVersion = source.modelVersion;
  result.region = source.region;
  result.capabilityKind = source.capabilityKind;
  result.capabilityTags = source.capabilityTags.slice();
  result.privacyClasses = source.privacyClasses.slice();
  result.maxInputTokens = source.maxInputTokens;
  result.maxOutputTokens = source.maxOutputTokens;
  result.qualityTier = source.qualityTier;
  result.credentialScope = source.credentialScope;
  result.available = source.available;
  return result;
}

function copyRemoteProfile(source: RemoteApiProfile): RemoteApiProfile {
  const result: RemoteApiProfile = new RemoteApiProfile();
  result.providerId = source.providerId;
  result.capabilityName = source.capabilityName;
  result.capabilityVersion = source.capabilityVersion;
  result.regions = source.regions.slice();
  result.inputSchemaJson = source.inputSchemaJson;
  result.outputSchemaJson = source.outputSchemaJson;
  result.capabilityTags = source.capabilityTags.slice();
  result.permissionRequirements = source.permissionRequirements.slice();
  result.riskLevel = source.riskLevel;
  result.sideEffect = source.sideEffect;
  result.dataBoundary = source.dataBoundary;
  result.idempotencyMode = source.idempotencyMode;
  result.latencyClass = source.latencyClass;
  result.costClass = source.costClass;
  result.displayName = source.displayName;
  result.description = source.description;
  result.credentialScope = source.credentialScope;
  result.available = source.available;
  return result;
}

export class RegisteredModelProvider {
  private readonly profileValue: ModelProviderProfile;
  private readonly priceValue: ProviderPriceSnapshot;
  readonly registryDigest: string;

  constructor(profile: ModelProviderProfile, price: ProviderPriceSnapshot, registryDigest: string) {
    this.profileValue = copyModelProfile(profile);
    this.priceValue = copyPrice(price);
    this.registryDigest = registryDigest;
  }

  registryEntry(estimatedInputTokens: number, estimatedOutputTokens: number): ModelRegistryEntry {
    const result: ModelRegistryEntry = new ModelRegistryEntry();
    result.modelId = this.profileValue.registryModelId;
    result.providerId = this.profileValue.providerId;
    result.modelVersion = this.profileValue.modelVersion;
    result.registryDigest = this.registryDigest;
    result.capabilityTags = this.profileValue.capabilityTags.slice();
    result.regions = [this.profileValue.region];
    result.privacyClasses = this.profileValue.privacyClasses.slice();
    result.maxInputTokens = this.profileValue.maxInputTokens;
    result.maxOutputTokens = this.profileValue.maxOutputTokens;
    result.estimatedCostMicros = estimateTokenCost(this.priceValue, estimatedInputTokens, estimatedOutputTokens);
    result.qualityTier = this.profileValue.qualityTier;
    result.available = this.profileValue.available;
    return result;
  }

  profileSnapshot(): ModelProviderProfile {
    return copyModelProfile(this.profileValue);
  }

  priceSnapshot(): ProviderPriceSnapshot {
    return copyPrice(this.priceValue);
  }

  modelId(): string {
    return this.profileValue.registryModelId;
  }
}

export class RegisteredRemoteApiProvider {
  private readonly profileValue: RemoteApiProfile;
  private readonly priceValue: ProviderPriceSnapshot;
  private readonly entryValue: ToolRegistryEntry;

  constructor(profile: RemoteApiProfile, price: ProviderPriceSnapshot, entry: ToolRegistryEntry) {
    this.profileValue = copyRemoteProfile(profile);
    this.priceValue = copyPrice(price);
    this.entryValue = this.copyEntry(entry);
  }

  profileSnapshot(): RemoteApiProfile {
    return copyRemoteProfile(this.profileValue);
  }

  priceSnapshot(): ProviderPriceSnapshot {
    return copyPrice(this.priceValue);
  }

  registryEntry(): ToolRegistryEntry {
    return this.copyEntry(this.entryValue);
  }

  toolId(): string {
    return this.entryValue.descriptor.toolId;
  }

  private copyEntry(source: ToolRegistryEntry): ToolRegistryEntry {
    const result: ToolRegistryEntry = new ToolRegistryEntry();
    result.descriptor = ContractCodec.parseToolDescriptor(ContractCodec.stringify(source.descriptor));
    result.registryVersion = source.registryVersion;
    result.registryDigest = source.registryDigest;
    result.descriptionDigest = source.descriptionDigest;
    result.retrievalRelationVersion = source.retrievalRelationVersion;
    result.estimatedCostMicros = source.estimatedCostMicros;
    result.requiresNetwork = source.requiresNetwork;
    result.enabled = source.enabled;
    return result;
  }
}

export class ProviderCatalog {
  private readonly digestPort: ConnectorDigestPort;
  private readonly models: RegisteredModelProvider[] = [];
  private readonly remoteApis: RegisteredRemoteApiProvider[] = [];

  constructor(digestPort: ConnectorDigestPort) {
    this.digestPort = digestPort;
  }

  registerModel(profile: ModelProviderProfile, price: ProviderPriceSnapshot): boolean {
    if (!this.validModel(profile) || !this.validPrice(price) || price.providerId !== profile.providerId ||
      price.capabilityId !== profile.providerModelId || price.capabilityVersion !== profile.modelVersion ||
      price.region !== profile.region) {
      return false;
    }
    const digest: string = this.digestPort.digest('model-provider-v1|' + canonicalJson(profile as Object) +
      '|' + canonicalJson(price as Object));
    const registered: RegisteredModelProvider = new RegisteredModelProvider(profile, price, digest);
    const index: number = this.findModel(profile.registryModelId);
    if (index >= 0) this.models[index] = registered; else this.models.push(registered);
    return true;
  }

  registerRemoteApi(profile: RemoteApiProfile, price: ProviderPriceSnapshot): boolean {
    if (!this.validRemote(profile) || !this.validPrice(price) || price.providerId !== profile.providerId ||
      price.capabilityId !== profile.capabilityName || price.capabilityVersion !== profile.capabilityVersion ||
      profile.regions.indexOf(price.region) < 0) {
      return false;
    }
    let inputSchemaJson: string;
    let outputSchemaJson: string | undefined;
    try {
      const inputSchema: Object = parseJsonObject(profile.inputSchemaJson);
      inputSchemaJson = canonicalJson(inputSchema);
      outputSchemaJson = profile.outputSchemaJson === undefined ? undefined :
        canonicalJson(parseJsonObject(profile.outputSchemaJson));
    } catch (error) {
      return false;
    }
    const schemaDigest: string = this.digestPort.digest('remote-schema-v1|' + inputSchemaJson + '|' +
      (outputSchemaJson === undefined ? '' : outputSchemaJson));
    const identity: string = this.digestPort.digest('remote-api-identity-v1|' + profile.providerId + '|' +
      profile.capabilityName + '|' + profile.capabilityVersion + '|' + price.region + '|' + schemaDigest);
    const descriptor: ToolDescriptor = new ToolDescriptor();
    descriptor.toolId = 'remote://' + encodeURIComponent(profile.providerId) + '/api/' +
      encodeURIComponent(profile.capabilityName) + '@' + encodeURIComponent(price.region);
    descriptor.sourceType = ToolSourceType.REMOTE_API;
    descriptor.providerId = profile.providerId;
    descriptor.capabilityName = profile.capabilityName;
    descriptor.capabilityVersion = profile.capabilityVersion;
    descriptor.toolIdentityVersion = identity;
    descriptor.displayName = profile.displayName;
    descriptor.description = profile.description;
    descriptor.inputSchemaJson = inputSchemaJson;
    descriptor.outputSchemaJson = outputSchemaJson;
    descriptor.schemaDigest = schemaDigest;
    descriptor.capabilityTags = profile.capabilityTags.slice();
    descriptor.riskLevel = profile.riskLevel;
    descriptor.sideEffect = profile.sideEffect;
    descriptor.permissionRequirements = profile.permissionRequirements.slice();
    descriptor.dataBoundary = profile.dataBoundary;
    descriptor.availability = profile.available ? 'available' : 'unavailable';
    descriptor.latencyClass = profile.latencyClass;
    descriptor.costClass = profile.costClass;
    descriptor.idempotencyMode = profile.idempotencyMode;
    descriptor.adapterRef = 'remote:' + profile.providerId + ':' + price.region;
    const entry: ToolRegistryEntry = new ToolRegistryEntry();
    entry.descriptor = descriptor;
    entry.registryVersion = identity;
    entry.descriptionDigest = this.digestPort.digest(profile.description);
    entry.registryDigest = this.digestPort.digest('remote-registry-v1|' + identity + '|' +
      entry.descriptionDigest + '|' + canonicalJson(price as Object));
    entry.retrievalRelationVersion = identity;
    entry.estimatedCostMicros = price.fixedCostMicros;
    entry.requiresNetwork = true;
    entry.enabled = profile.available;
    const registered: RegisteredRemoteApiProvider = new RegisteredRemoteApiProvider(profile, price, entry);
    const index: number = this.findRemote(entry.descriptor.toolId);
    if (index >= 0) this.remoteApis[index] = registered; else this.remoteApis.push(registered);
    return true;
  }

  getModel(modelId: string): RegisteredModelProvider | undefined {
    const index: number = this.findModel(modelId);
    return index < 0 ? undefined : this.models[index];
  }

  getRemoteApi(toolId: string): RegisteredRemoteApiProvider | undefined {
    const index: number = this.findRemote(toolId);
    return index < 0 ? undefined : this.remoteApis[index];
  }

  private validModel(profile: ModelProviderProfile): boolean {
    return validText(profile.registryModelId) && validText(profile.providerId) &&
      validText(profile.providerModelId) && validText(profile.modelVersion) && validText(profile.region) &&
      validText(profile.credentialScope) && profile.capabilityTags.length > 0 &&
      profile.privacyClasses.length > 0 && validCount(profile.maxInputTokens) &&
      validCount(profile.maxOutputTokens) && validCount(profile.qualityTier);
  }

  private validRemote(profile: RemoteApiProfile): boolean {
    return validText(profile.providerId) && validText(profile.capabilityName) &&
      validText(profile.capabilityVersion) && profile.regions.length > 0 &&
      validText(profile.inputSchemaJson) && profile.capabilityTags.length > 0 &&
      validText(profile.latencyClass) && validText(profile.costClass) && validText(profile.credentialScope) &&
      (profile.sideEffect === SideEffect.NONE || profile.idempotencyMode !== IdempotencyMode.NONE);
  }

  private validPrice(price: ProviderPriceSnapshot): boolean {
    return validText(price.snapshotId) && validText(price.providerId) && validText(price.capabilityId) &&
      validText(price.capabilityVersion) && validText(price.region) && validText(price.currency) &&
      validText(price.effectiveAt) && validText(price.snapshotDigest) &&
      validCount(price.inputMicrosPerMillionTokens) && validCount(price.outputMicrosPerMillionTokens) &&
      validCount(price.fixedCostMicros);
  }

  private findModel(modelId: string): number {
    for (let index: number = 0; index < this.models.length; index++) {
      if (this.models[index].modelId() === modelId) return index;
    }
    return -1;
  }

  private findRemote(toolId: string): number {
    for (let index: number = 0; index < this.remoteApis.length; index++) {
      if (this.remoteApis[index].toolId() === toolId) return index;
    }
    return -1;
  }
}
