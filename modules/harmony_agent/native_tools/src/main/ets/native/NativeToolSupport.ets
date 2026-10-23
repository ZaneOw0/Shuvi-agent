import {
  ContractCodec,
  ToolDescriptor
} from '@harmony_agent/agent-contracts';
import { ToolRegistryEntry } from '@harmony_agent/agent-runtime';
import {
  NativeCapabilityProbePort,
  NativeClockPort
} from './NativeToolContracts';

function compareText(left: string, right: string): number {
  if (left < right) return -1;
  if (left > right) return 1;
  return 0;
}

function encode(value: Object): string {
  if (value === null) return 'null';
  if (typeof value === 'string' || typeof value === 'boolean' || typeof value === 'number') {
    const encoded: string | undefined = JSON.stringify(value);
    if (encoded === undefined) throw new Error('value is not JSON serializable');
    return encoded;
  }
  if (Array.isArray(value)) {
    const items: Object[] = value as Object[];
    let output: string = '[';
    for (let index: number = 0; index < items.length; index++) {
      if (index > 0) output += ',';
      output += encode(items[index]);
    }
    return output + ']';
  }
  const record: Record<string, Object> = value as Record<string, Object>;
  const keys: string[] = Object.keys(record).sort(compareText);
  let output: string = '{';
  let written: number = 0;
  for (let index: number = 0; index < keys.length; index++) {
    const child: Object = record[keys[index]];
    if (child === undefined) continue;
    if (written > 0) output += ',';
    output += JSON.stringify(keys[index]) + ':' + encode(child);
    written++;
  }
  return output + '}';
}

export function nativeCanonicalJson(value: Object): string {
  return encode(value);
}

export function parseNativeArguments(value: string): Object {
  const parsed: Object = JSON.parse(value) as Object;
  if (parsed === null || typeof parsed === 'string' || typeof parsed === 'number' || typeof parsed === 'boolean' ||
    Array.isArray(parsed)) {
    throw new Error('native tool arguments must be a JSON object');
  }
  return parsed;
}

export function copyNativeToolEntry(source: ToolRegistryEntry): ToolRegistryEntry {
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

export class SystemNativeCapabilityProbe implements NativeCapabilityProbePort {
  isAvailable(systemCapability: string): boolean {
    return canIUse(systemCapability);
  }
}

export class SystemNativeClock implements NativeClockPort {
  nowIso(): string {
    return new Date().toISOString();
  }
}

export function copyNativeDescriptor(source: ToolDescriptor): ToolDescriptor {
  return ContractCodec.parseToolDescriptor(ContractCodec.stringify(source));
}
