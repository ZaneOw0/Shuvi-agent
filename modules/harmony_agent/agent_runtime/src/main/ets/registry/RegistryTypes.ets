import {
  ContractCodec,
  PrivacyClass,
  ToolDescriptor,
  WorkflowGraph
} from '@harmony_agent/agent-contracts';

export enum RegistryWriteCode {
  CREATED = 'CREATED',
  UPDATED = 'UPDATED',
  UNCHANGED = 'UNCHANGED',
  INVALID_ENTRY = 'INVALID_ENTRY',
  VERSION_CONFLICT = 'VERSION_CONFLICT'
}

export class RegistryWriteResult {
  accepted: boolean = false;
  duplicate: boolean = false;
  code: RegistryWriteCode = RegistryWriteCode.INVALID_ENTRY;
}

export class ModelRegistryEntry {
  modelId: string = '';
  providerId: string = '';
  modelVersion: string = '';
  registryDigest: string = '';
  capabilityTags: string[] = [];
  regions: string[] = [];
  privacyClasses: PrivacyClass[] = [];
  maxInputTokens: number = 0;
  maxOutputTokens: number = 0;
  estimatedCostMicros: number = 0;
  qualityTier: number = 0;
  available: boolean = false;
}

export class RoleRegistryEntry {
  roleId: string = '';
  roleVersion: string = '';
  registryDigest: string = '';
  capabilityTags: string[] = [];
  enabled: boolean = false;
}

export class ToolRegistryEntry {
  descriptor: ToolDescriptor = new ToolDescriptor();
  registryVersion: string = '';
  registryDigest: string = '';
  descriptionDigest: string = '';
  retrievalRelationVersion: string = '';
  estimatedCostMicros: number = 0;
  requiresNetwork: boolean = false;
  enabled: boolean = false;
}

export class WorkflowRegistryEntry {
  workflow: WorkflowGraph = new WorkflowGraph();
  registryDigest: string = '';
  capabilityTags: string[] = [];
  enabled: boolean = false;
}

export class RegistrySnapshot {
  snapshotVersion: number = 0;
  snapshotDigest: string = '';
}

export function copyModelEntry(source: ModelRegistryEntry): ModelRegistryEntry {
  const value: ModelRegistryEntry = new ModelRegistryEntry();
  value.modelId = source.modelId;
  value.providerId = source.providerId;
  value.modelVersion = source.modelVersion;
  value.registryDigest = source.registryDigest;
  value.capabilityTags = source.capabilityTags.slice();
  value.regions = source.regions.slice();
  value.privacyClasses = source.privacyClasses.slice();
  value.maxInputTokens = source.maxInputTokens;
  value.maxOutputTokens = source.maxOutputTokens;
  value.estimatedCostMicros = source.estimatedCostMicros;
  value.qualityTier = source.qualityTier;
  value.available = source.available;
  return value;
}

export function copyRoleEntry(source: RoleRegistryEntry): RoleRegistryEntry {
  const value: RoleRegistryEntry = new RoleRegistryEntry();
  value.roleId = source.roleId;
  value.roleVersion = source.roleVersion;
  value.registryDigest = source.registryDigest;
  value.capabilityTags = source.capabilityTags.slice();
  value.enabled = source.enabled;
  return value;
}

export function copyToolEntry(source: ToolRegistryEntry): ToolRegistryEntry {
  const value: ToolRegistryEntry = new ToolRegistryEntry();
  value.descriptor = ContractCodec.parseToolDescriptor(ContractCodec.stringify(source.descriptor));
  value.registryVersion = source.registryVersion;
  value.registryDigest = source.registryDigest;
  value.descriptionDigest = source.descriptionDigest;
  value.retrievalRelationVersion = source.retrievalRelationVersion;
  value.estimatedCostMicros = source.estimatedCostMicros;
  value.requiresNetwork = source.requiresNetwork;
  value.enabled = source.enabled;
  return value;
}

export function copyWorkflowEntry(source: WorkflowRegistryEntry): WorkflowRegistryEntry {
  const value: WorkflowRegistryEntry = new WorkflowRegistryEntry();
  value.workflow = ContractCodec.parseWorkflowGraph(ContractCodec.stringify(source.workflow));
  value.registryDigest = source.registryDigest;
  value.capabilityTags = source.capabilityTags.slice();
  value.enabled = source.enabled;
  return value;
}
