import { ContractCodec, ContractValidator } from '@harmony_agent/agent-contracts';
import { WorkflowGraphValidator } from '@harmony_agent/agent-core';
import {
  ModelRegistryEntry,
  RegistrySnapshot,
  RegistryWriteCode,
  RegistryWriteResult,
  RoleRegistryEntry,
  ToolRegistryEntry,
  WorkflowRegistryEntry,
  copyModelEntry,
  copyRoleEntry,
  copyToolEntry,
  copyWorkflowEntry
} from './RegistryTypes';

function writeResult(accepted: boolean, duplicate: boolean, code: RegistryWriteCode): RegistryWriteResult {
  const result: RegistryWriteResult = new RegistryWriteResult();
  result.accepted = accepted;
  result.duplicate = duplicate;
  result.code = code;
  return result;
}

function validText(value: string): boolean {
  return value.trim().length > 0;
}

function validCount(value: number): boolean {
  return Number.isSafeInteger(value) && value >= 0;
}

function validStringList(values: string[], allowEmpty: boolean = false): boolean {
  if (!allowEmpty && values.length === 0) {
    return false;
  }
  for (let i: number = 0; i < values.length; i++) {
    if (!validText(values[i])) {
      return false;
    }
    for (let previous: number = 0; previous < i; previous++) {
      if (values[previous] === values[i]) {
        return false;
      }
    }
  }
  return true;
}

function stableSortModel(values: ModelRegistryEntry[]): ModelRegistryEntry[] {
  const result: ModelRegistryEntry[] = values.slice();
  for (let i: number = 0; i < result.length; i++) {
    for (let j: number = i + 1; j < result.length; j++) {
      if (result[j].modelId < result[i].modelId) {
        const temporary: ModelRegistryEntry = result[i];
        result[i] = result[j];
        result[j] = temporary;
      }
    }
  }
  return result;
}

function stableSortRole(values: RoleRegistryEntry[]): RoleRegistryEntry[] {
  const result: RoleRegistryEntry[] = values.slice();
  for (let i: number = 0; i < result.length; i++) {
    for (let j: number = i + 1; j < result.length; j++) {
      if (result[j].roleId < result[i].roleId) {
        const temporary: RoleRegistryEntry = result[i];
        result[i] = result[j];
        result[j] = temporary;
      }
    }
  }
  return result;
}

function stableSortTool(values: ToolRegistryEntry[]): ToolRegistryEntry[] {
  const result: ToolRegistryEntry[] = values.slice();
  for (let i: number = 0; i < result.length; i++) {
    for (let j: number = i + 1; j < result.length; j++) {
      if (result[j].descriptor.toolId < result[i].descriptor.toolId) {
        const temporary: ToolRegistryEntry = result[i];
        result[i] = result[j];
        result[j] = temporary;
      }
    }
  }
  return result;
}

function stableSortWorkflow(values: WorkflowRegistryEntry[]): WorkflowRegistryEntry[] {
  const result: WorkflowRegistryEntry[] = values.slice();
  for (let i: number = 0; i < result.length; i++) {
    for (let j: number = i + 1; j < result.length; j++) {
      if (result[j].workflow.workflowId < result[i].workflow.workflowId) {
        const temporary: WorkflowRegistryEntry = result[i];
        result[i] = result[j];
        result[j] = temporary;
      }
    }
  }
  return result;
}

export class ModelRegistry {
  private entries: ModelRegistryEntry[] = [];
  private version: number = 0;

  register(entry: ModelRegistryEntry): RegistryWriteResult {
    if (!validText(entry.modelId) || !validText(entry.providerId) || !validText(entry.modelVersion) ||
      !validText(entry.registryDigest) || !validStringList(entry.capabilityTags) ||
      !validStringList(entry.regions) || entry.privacyClasses.length === 0 ||
      !validCount(entry.maxInputTokens) || !validCount(entry.maxOutputTokens) ||
      !validCount(entry.estimatedCostMicros) || !validCount(entry.qualityTier)) {
      return writeResult(false, false, RegistryWriteCode.INVALID_ENTRY);
    }
    const index: number = this.find(entry.modelId);
    if (index >= 0 && this.entries[index].modelVersion === entry.modelVersion) {
      if (this.entries[index].registryDigest !== entry.registryDigest ||
        ContractCodec.stringify(this.entries[index]) !== ContractCodec.stringify(entry)) {
        return writeResult(false, false, RegistryWriteCode.VERSION_CONFLICT);
      }
      return writeResult(true, true, RegistryWriteCode.UNCHANGED);
    }
    const next: ModelRegistryEntry[] = this.entries.slice();
    if (index >= 0) {
      next[index] = copyModelEntry(entry);
    } else {
      next.push(copyModelEntry(entry));
    }
    this.entries = stableSortModel(next);
    this.version++;
    return writeResult(true, false, index >= 0 ? RegistryWriteCode.UPDATED : RegistryWriteCode.CREATED);
  }

  get(modelId: string): ModelRegistryEntry | undefined {
    const index: number = this.find(modelId);
    return index < 0 ? undefined : copyModelEntry(this.entries[index]);
  }

  activeEntries(): ModelRegistryEntry[] {
    const values: ModelRegistryEntry[] = [];
    for (let i: number = 0; i < this.entries.length; i++) {
      if (this.entries[i].available) {
        values.push(copyModelEntry(this.entries[i]));
      }
    }
    return values;
  }

  snapshot(): RegistrySnapshot {
    return this.makeSnapshot('model');
  }

  private makeSnapshot(kind: string): RegistrySnapshot {
    const value: RegistrySnapshot = new RegistrySnapshot();
    value.snapshotVersion = this.version;
    let identity: string = kind + ':' + this.version.toString();
    for (let i: number = 0; i < this.entries.length; i++) {
      identity += '|' + this.entries[i].modelId + '@' + this.entries[i].modelVersion +
        ':' + this.entries[i].registryDigest;
    }
    value.snapshotDigest = identity;
    return value;
  }

  private find(modelId: string): number {
    for (let i: number = 0; i < this.entries.length; i++) {
      if (this.entries[i].modelId === modelId) return i;
    }
    return -1;
  }
}

export class RoleRegistry {
  private entries: RoleRegistryEntry[] = [];
  private version: number = 0;

  register(entry: RoleRegistryEntry): RegistryWriteResult {
    if (!validText(entry.roleId) || !validText(entry.roleVersion) || !validText(entry.registryDigest) ||
      !validStringList(entry.capabilityTags)) {
      return writeResult(false, false, RegistryWriteCode.INVALID_ENTRY);
    }
    const index: number = this.find(entry.roleId);
    if (index >= 0 && this.entries[index].roleVersion === entry.roleVersion) {
      if (this.entries[index].registryDigest !== entry.registryDigest ||
        ContractCodec.stringify(this.entries[index]) !== ContractCodec.stringify(entry)) {
        return writeResult(false, false, RegistryWriteCode.VERSION_CONFLICT);
      }
      return writeResult(true, true, RegistryWriteCode.UNCHANGED);
    }
    const next: RoleRegistryEntry[] = this.entries.slice();
    if (index >= 0) next[index] = copyRoleEntry(entry); else next.push(copyRoleEntry(entry));
    this.entries = stableSortRole(next);
    this.version++;
    return writeResult(true, false, index >= 0 ? RegistryWriteCode.UPDATED : RegistryWriteCode.CREATED);
  }

  activeEntries(): RoleRegistryEntry[] {
    const values: RoleRegistryEntry[] = [];
    for (let i: number = 0; i < this.entries.length; i++) {
      if (this.entries[i].enabled) values.push(copyRoleEntry(this.entries[i]));
    }
    return values;
  }

  snapshot(): RegistrySnapshot {
    const value: RegistrySnapshot = new RegistrySnapshot();
    value.snapshotVersion = this.version;
    let identity: string = 'role:' + this.version.toString();
    for (let i: number = 0; i < this.entries.length; i++) {
      identity += '|' + this.entries[i].roleId + '@' + this.entries[i].roleVersion +
        ':' + this.entries[i].registryDigest;
    }
    value.snapshotDigest = identity;
    return value;
  }

  private find(roleId: string): number {
    for (let i: number = 0; i < this.entries.length; i++) {
      if (this.entries[i].roleId === roleId) return i;
    }
    return -1;
  }
}

export class ToolRegistry {
  private entries: ToolRegistryEntry[] = [];
  private version: number = 0;

  register(entry: ToolRegistryEntry): RegistryWriteResult {
    if (!ContractValidator.validateToolDescriptor(entry.descriptor).valid ||
      !validText(entry.registryVersion) || !validText(entry.registryDigest) ||
      !validText(entry.descriptionDigest) || !validText(entry.retrievalRelationVersion) ||
      !validCount(entry.estimatedCostMicros)) {
      return writeResult(false, false, RegistryWriteCode.INVALID_ENTRY);
    }
    const index: number = this.find(entry.descriptor.toolId);
    if (index >= 0 && this.entries[index].registryVersion === entry.registryVersion) {
      if (this.entries[index].registryDigest !== entry.registryDigest ||
        ContractCodec.stringify(this.entries[index]) !== ContractCodec.stringify(entry)) {
        return writeResult(false, false, RegistryWriteCode.VERSION_CONFLICT);
      }
      return writeResult(true, true, RegistryWriteCode.UNCHANGED);
    }
    const next: ToolRegistryEntry[] = this.entries.slice();
    if (index >= 0) next[index] = copyToolEntry(entry); else next.push(copyToolEntry(entry));
    this.entries = stableSortTool(next);
    this.version++;
    return writeResult(true, false, index >= 0 ? RegistryWriteCode.UPDATED : RegistryWriteCode.CREATED);
  }

  activeEntries(): ToolRegistryEntry[] {
    const values: ToolRegistryEntry[] = [];
    for (let i: number = 0; i < this.entries.length; i++) {
      if (this.entries[i].enabled) values.push(copyToolEntry(this.entries[i]));
    }
    return values;
  }

  snapshot(): RegistrySnapshot {
    const value: RegistrySnapshot = new RegistrySnapshot();
    value.snapshotVersion = this.version;
    let identity: string = 'tool:' + this.version.toString();
    for (let i: number = 0; i < this.entries.length; i++) {
      identity += '|' + this.entries[i].descriptor.toolId + '@' + this.entries[i].registryVersion +
        ':' + this.entries[i].registryDigest;
    }
    value.snapshotDigest = identity;
    return value;
  }

  private find(toolId: string): number {
    for (let i: number = 0; i < this.entries.length; i++) {
      if (this.entries[i].descriptor.toolId === toolId) return i;
    }
    return -1;
  }
}

export class WorkflowRegistry {
  private entries: WorkflowRegistryEntry[] = [];
  private version: number = 0;

  register(entry: WorkflowRegistryEntry): RegistryWriteResult {
    if (!WorkflowGraphValidator.validate(entry.workflow).valid || !validText(entry.registryDigest) ||
      !validStringList(entry.capabilityTags, true)) {
      return writeResult(false, false, RegistryWriteCode.INVALID_ENTRY);
    }
    const index: number = this.find(entry.workflow.workflowId);
    if (index >= 0 && this.entries[index].workflow.workflowVersion === entry.workflow.workflowVersion) {
      if (this.entries[index].registryDigest !== entry.registryDigest ||
        ContractCodec.stringify(this.entries[index]) !== ContractCodec.stringify(entry)) {
        return writeResult(false, false, RegistryWriteCode.VERSION_CONFLICT);
      }
      return writeResult(true, true, RegistryWriteCode.UNCHANGED);
    }
    const next: WorkflowRegistryEntry[] = this.entries.slice();
    if (index >= 0) next[index] = copyWorkflowEntry(entry); else next.push(copyWorkflowEntry(entry));
    this.entries = stableSortWorkflow(next);
    this.version++;
    return writeResult(true, false, index >= 0 ? RegistryWriteCode.UPDATED : RegistryWriteCode.CREATED);
  }

  activeEntries(): WorkflowRegistryEntry[] {
    const values: WorkflowRegistryEntry[] = [];
    for (let i: number = 0; i < this.entries.length; i++) {
      if (this.entries[i].enabled) values.push(copyWorkflowEntry(this.entries[i]));
    }
    return values;
  }

  snapshot(): RegistrySnapshot {
    const value: RegistrySnapshot = new RegistrySnapshot();
    value.snapshotVersion = this.version;
    let identity: string = 'workflow:' + this.version.toString();
    for (let i: number = 0; i < this.entries.length; i++) {
      identity += '|' + this.entries[i].workflow.workflowId + '@' +
        this.entries[i].workflow.workflowVersion + ':' + this.entries[i].registryDigest;
    }
    value.snapshotDigest = identity;
    return value;
  }

  private find(workflowId: string): number {
    for (let i: number = 0; i < this.entries.length; i++) {
      if (this.entries[i].workflow.workflowId === workflowId) return i;
    }
    return -1;
  }
}
