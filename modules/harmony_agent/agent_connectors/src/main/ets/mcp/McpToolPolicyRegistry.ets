import { McpReadOnlyToolPolicy } from './McpConnectorTypes';

function validText(value: string): boolean {
  return value.trim().length > 0;
}

function validList(values: string[]): boolean {
  if (values.length === 0) return false;
  for (let index: number = 0; index < values.length; index++) {
    if (!validText(values[index])) return false;
  }
  return true;
}

function copyPolicy(source: McpReadOnlyToolPolicy): McpReadOnlyToolPolicy {
  const result: McpReadOnlyToolPolicy = new McpReadOnlyToolPolicy();
  result.serverId = source.serverId;
  result.toolName = source.toolName;
  result.capabilityTags = source.capabilityTags.slice();
  result.permissionRequirements = source.permissionRequirements.slice();
  result.riskLevel = source.riskLevel;
  result.dataBoundary = source.dataBoundary;
  result.latencyClass = source.latencyClass;
  result.costClass = source.costClass;
  result.estimatedCostMicros = source.estimatedCostMicros;
  return result;
}

export class McpReadOnlyToolPolicyRegistry {
  private readonly policies: McpReadOnlyToolPolicy[] = [];

  register(policy: McpReadOnlyToolPolicy): boolean {
    if (!validText(policy.serverId) || !validText(policy.toolName) ||
      !validList(policy.capabilityTags) || !validText(policy.latencyClass) ||
      !validText(policy.costClass) || !Number.isSafeInteger(policy.estimatedCostMicros) ||
      policy.estimatedCostMicros < 0) {
      return false;
    }
    const index: number = this.find(policy.serverId, policy.toolName);
    if (index >= 0) this.policies[index] = copyPolicy(policy); else this.policies.push(copyPolicy(policy));
    return true;
  }

  get(serverId: string, toolName: string): McpReadOnlyToolPolicy | undefined {
    const index: number = this.find(serverId, toolName);
    return index < 0 ? undefined : copyPolicy(this.policies[index]);
  }

  private find(serverId: string, toolName: string): number {
    for (let index: number = 0; index < this.policies.length; index++) {
      if (this.policies[index].serverId === serverId && this.policies[index].toolName === toolName) return index;
    }
    return -1;
  }
}
