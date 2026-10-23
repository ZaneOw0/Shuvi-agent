import { ArtifactManifest } from '@harmony_agent/agent-contracts';
import {
  ArtifactCompatibilityResult,
  ArtifactRuntimeEnvironment
} from './ArtifactRegistryTypes';

function validText(value: string): boolean {
  return value.trim().length > 0;
}

function validEnvironment(value: ArtifactRuntimeEnvironment): boolean {
  if (!/^\d+\.\d+\.\d+$/.test(value.runtimeVersion) ||
    !Number.isSafeInteger(value.apiVersion) || value.apiVersion <= 0 ||
    value.supportedFeatureSchemaVersions.length === 0) return false;
  for (let i: number = 0; i < value.supportedFeatureSchemaVersions.length; i++) {
    if (!validText(value.supportedFeatureSchemaVersions[i])) return false;
    for (let j: number = 0; j < i; j++) {
      if (value.supportedFeatureSchemaVersions[i] === value.supportedFeatureSchemaVersions[j]) return false;
    }
  }
  return true;
}

function parseVersion(value: string): number[] | undefined {
  if (!/^\d+\.\d+\.\d+$/.test(value)) return undefined;
  const parts: string[] = value.split('.');
  const result: number[] = [];
  for (let i: number = 0; i < parts.length; i++) {
    const part: number = Number(parts[i]);
    if (!Number.isSafeInteger(part) || part < 0) return undefined;
    result.push(part);
  }
  return result;
}

function versionAtLeast(actual: string, minimum: string): boolean {
  const left: number[] | undefined = parseVersion(actual);
  const right: number[] | undefined = parseVersion(minimum);
  if (left === undefined || right === undefined) return false;
  for (let i: number = 0; i < 3; i++) {
    if (left[i] > right[i]) return true;
    if (left[i] < right[i]) return false;
  }
  return true;
}

function includes(values: string[], expected: string): boolean {
  for (let i: number = 0; i < values.length; i++) {
    if (values[i] === expected) return true;
  }
  return false;
}

export class ArtifactRuntimeCompatibilityEvaluator {
  static evaluate(manifest: ArtifactManifest,
    environment: ArtifactRuntimeEnvironment): ArtifactCompatibilityResult {
    const result: ArtifactCompatibilityResult = new ArtifactCompatibilityResult();
    if (!validEnvironment(environment)) {
      result.issues.push('runtime environment is invalid');
      return result;
    }
    if (!includes(environment.supportedFeatureSchemaVersions, manifest.featureSchemaVersion)) {
      result.issues.push('feature schema is not supported');
    }
    let runtimeConstraintSeen: boolean = false;
    let apiConstraintSeen: boolean = false;
    for (let i: number = 0; i < manifest.runtimeCompatibility.length; i++) {
      const requirement: string = manifest.runtimeCompatibility[i];
      const runtimePrefix: string = 'harmony_agent-runtime>=';
      const apiPrefix: string = 'api>=';
      if (requirement.startsWith(runtimePrefix)) {
        runtimeConstraintSeen = true;
        const minimum: string = requirement.substring(runtimePrefix.length);
        if (!versionAtLeast(environment.runtimeVersion, minimum)) {
          result.issues.push('runtime version does not satisfy ' + requirement);
        }
      } else if (requirement.startsWith(apiPrefix)) {
        apiConstraintSeen = true;
        const minimumApi: number = Number(requirement.substring(apiPrefix.length));
        if (!Number.isSafeInteger(minimumApi) || minimumApi <= 0 || environment.apiVersion < minimumApi) {
          result.issues.push('api version does not satisfy ' + requirement);
        }
      } else {
        result.issues.push('runtime compatibility requirement is not supported: ' + requirement);
      }
    }
    if (!runtimeConstraintSeen) result.issues.push('runtime compatibility must constrain harmony_agent-runtime');
    if (!apiConstraintSeen) result.issues.push('runtime compatibility must constrain api');
    result.compatible = result.issues.length === 0;
    return result;
  }
}
