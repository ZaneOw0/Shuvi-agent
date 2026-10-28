import { DataBoundary, IdempotencyMode, RiskLevel, SideEffect } from '@harmony_agent/agent-contracts';
import { McpToolPolicy } from './McpConnectorTypes';

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

function copyPolicy(source: McpToolPolicy): McpToolPolicy {
  const result: McpToolPolicy = new McpToolPolicy();
  result.serverId = source.serverId;
  result.toolName = source.toolName;
  result.capabilityTags = source.capabilityTags.slice();
  result.permissionRequirements = source.permissionRequirements.slice();
  result.riskLevel = source.riskLevel;
  result.dataBoundary = source.dataBoundary;
  result.latencyClass = source.latencyClass;
  result.costClass = source.costClass;
  result.estimatedCostMicros = source.estimatedCostMicros;
  result.sideEffect = source.sideEffect;
  result.idempotencyMode = source.idempotencyMode;
  result.idempotencyKeyArgument = source.idempotencyKeyArgument;
  result.operationIdArgument = source.operationIdArgument;
  result.receiptField = source.receiptField;
  return result;
}

function validField(value: string | undefined): boolean {
  return value !== undefined && /^[A-Za-z_][A-Za-z0-9_]*$/.test(value) &&
    value !== '__proto__' && value !== 'constructor' && value !== 'prototype';
}

export class McpToolPolicyRegistry {
  private readonly policies: McpToolPolicy[] = [];

  register(policy: McpToolPolicy): boolean {
    if (!validText(policy.serverId) || !validText(policy.toolName) ||
      !validList(policy.capabilityTags) || !validText(policy.latencyClass) ||
      !validText(policy.costClass) || !Number.isSafeInteger(policy.estimatedCostMicros) ||
      policy.estimatedCostMicros < 0 ||
      [RiskLevel.LOW, RiskLevel.MEDIUM, RiskLevel.HIGH, RiskLevel.CRITICAL].indexOf(policy.riskLevel) < 0 ||
      [DataBoundary.APP_SANDBOX, DataBoundary.DEVICE_ONLY, DataBoundary.REMOTE_ALLOWED].indexOf(policy.dataBoundary) < 0 ||
      [SideEffect.NONE, SideEffect.REVERSIBLE, SideEffect.IRREVERSIBLE].indexOf(policy.sideEffect) < 0 ||
      [IdempotencyMode.NONE, IdempotencyMode.PROVIDER_KEY, IdempotencyMode.RECONCILE].indexOf(policy.idempotencyMode) < 0 ||
      (policy.idempotencyKeyArgument !== undefined && !validField(policy.idempotencyKeyArgument)) ||
      (policy.operationIdArgument !== undefined && !validField(policy.operationIdArgument)) ||
      (policy.receiptField !== undefined && !validField(policy.receiptField)) ||
      (policy.idempotencyKeyArgument !== undefined && policy.idempotencyKeyArgument === policy.operationIdArgument)) {
      return false;
    }
    if (policy.sideEffect === SideEffect.NONE) {
      if (policy.idempotencyMode !== IdempotencyMode.NONE || policy.idempotencyKeyArgument !== undefined ||
        policy.operationIdArgument !== undefined || policy.receiptField !== undefined) return false;
    } else if (!validField(policy.receiptField) ||
      policy.idempotencyMode === IdempotencyMode.NONE ||
      (policy.idempotencyMode === IdempotencyMode.PROVIDER_KEY && !validField(policy.idempotencyKeyArgument)) ||
      (policy.idempotencyMode === IdempotencyMode.RECONCILE && !validField(policy.operationIdArgument))) {
      return false;
    }
    const index: number = this.find(policy.serverId, policy.toolName);
    if (index >= 0) this.policies[index] = copyPolicy(policy); else this.policies.push(copyPolicy(policy));
    return true;
  }

  get(serverId: string, toolName: string): McpToolPolicy | undefined {
    const index: number = this.find(serverId, toolName);
    return index < 0 ? undefined : copyPolicy(this.policies[index]);
  }

  unregister(serverId: string, toolName: string): boolean {
    const index: number = this.find(serverId, toolName);
    if (index < 0) return false;
    this.policies.splice(index, 1);
    return true;
  }

  private find(serverId: string, toolName: string): number {
    for (let index: number = 0; index < this.policies.length; index++) {
      if (this.policies[index].serverId === serverId && this.policies[index].toolName === toolName) return index;
    }
    return -1;
  }
}

/** Existing consumers remain strictly read-only, even if passed a mutable policy subclass. */
export class McpReadOnlyToolPolicyRegistry extends McpToolPolicyRegistry {
  register(policy: McpToolPolicy): boolean {
    return policy.sideEffect === SideEffect.NONE && super.register(policy);
  }
}
