import {
  ContractValidationResult,
  ContractValidator,
  IdempotencyMode,
  SideEffect,
  WorkflowGraph,
  WorkflowInputBinding,
  WorkflowStep,
  WorkflowStepKind
} from '@harmony_agent/agent-contracts';
import { GraphValidationResult } from './CoreTypes';

export class WorkflowGraphValidator {
  static validate(graph: WorkflowGraph): GraphValidationResult {
    const result: GraphValidationResult = new GraphValidationResult();
    const shape: ContractValidationResult = ContractValidator.validateWorkflowGraphShape(graph);
    for (let i: number = 0; i < shape.issues.length; i++) {
      result.issues.push(shape.issues[i]);
    }

    WorkflowGraphValidator.validateStepIds(graph, result);
    WorkflowGraphValidator.validateEntries(graph, result);
    WorkflowGraphValidator.validateDependenciesAndBindings(graph, result);
    WorkflowGraphValidator.validateAcyclic(graph, result);
    result.valid = result.issues.length === 0;
    return result;
  }

  private static validateStepIds(graph: WorkflowGraph, result: GraphValidationResult): void {
    for (let i: number = 0; i < graph.steps.length; i++) {
      const step: WorkflowStep = graph.steps[i];
      if (WorkflowGraphValidator.findStepIndexBefore(graph, step.stepId, i) >= 0) {
        result.issues.push('steps[' + i.toString() + '].stepId must be unique');
      }
      if (!WorkflowGraphValidator.isJsonObjectText(step.expectedOutputSchemaJson)) {
        result.issues.push('steps[' + i.toString() + '].expectedOutputSchemaJson must be a JSON object');
      }
      if (step.kind !== WorkflowStepKind.JOIN && step.timeoutMs <= 0) {
        result.issues.push('steps[' + i.toString() + '].timeoutMs must be greater than zero');
      }
      if (step.sideEffect !== SideEffect.NONE && step.idempotencyMode === IdempotencyMode.NONE) {
        result.issues.push('steps[' + i.toString() + '] with side effects must declare idempotency');
      }
      if (step.kind === WorkflowStepKind.TOOL && step.capabilityRequirements.length === 0) {
        result.issues.push('steps[' + i.toString() + '].capabilityRequirements must not be empty for tool steps');
      }
    }
  }

  private static validateEntries(graph: WorkflowGraph, result: GraphValidationResult): void {
    if (graph.entryStepIds.length === 0) {
      result.issues.push('entryStepIds must not be empty');
    }
    for (let i: number = 0; i < graph.entryStepIds.length; i++) {
      const entryId: string = graph.entryStepIds[i];
      const index: number = WorkflowGraphValidator.findStepIndex(graph, entryId);
      if (index < 0) {
        result.issues.push('entryStepIds[' + i.toString() + '] does not reference a step');
      } else if (graph.steps[index].dependencies.length > 0) {
        result.issues.push('entry step ' + entryId + ' must not have dependencies');
      }
      for (let previous: number = 0; previous < i; previous++) {
        if (graph.entryStepIds[previous] === entryId) {
          result.issues.push('entryStepIds must be unique');
        }
      }
    }
    for (let stepIndex: number = 0; stepIndex < graph.steps.length; stepIndex++) {
      const step: WorkflowStep = graph.steps[stepIndex];
      if (step.dependencies.length === 0 && !WorkflowGraphValidator.contains(graph.entryStepIds, step.stepId)) {
        result.issues.push('zero-dependency step ' + step.stepId + ' must be an entry step');
      }
    }
  }

  private static validateDependenciesAndBindings(graph: WorkflowGraph, result: GraphValidationResult): void {
    for (let i: number = 0; i < graph.steps.length; i++) {
      const step: WorkflowStep = graph.steps[i];
      for (let dependencyIndex: number = 0; dependencyIndex < step.dependencies.length; dependencyIndex++) {
        const dependencyId: string = step.dependencies[dependencyIndex];
        if (dependencyId === step.stepId) {
          result.issues.push('step ' + step.stepId + ' must not depend on itself');
        }
        if (WorkflowGraphValidator.findStepIndex(graph, dependencyId) < 0) {
          result.issues.push('step ' + step.stepId + ' has unknown dependency ' + dependencyId);
        }
        for (let previous: number = 0; previous < dependencyIndex; previous++) {
          if (step.dependencies[previous] === dependencyId) {
            result.issues.push('step ' + step.stepId + ' has duplicate dependency ' + dependencyId);
          }
        }
      }
      for (let bindingIndex: number = 0; bindingIndex < step.inputBindings.length; bindingIndex++) {
        WorkflowGraphValidator.validateBinding(step, step.inputBindings[bindingIndex], bindingIndex, graph, result);
      }
    }
  }

  private static validateBinding(step: WorkflowStep, binding: WorkflowInputBinding, bindingIndex: number,
    graph: WorkflowGraph, result: GraphValidationResult): void {
    const path: string = 'step ' + step.stepId + ' inputBindings[' + bindingIndex.toString() + ']';
    if (binding.name.trim().length === 0) {
      result.issues.push(path + '.name must not be empty');
    }
    const hasSource: boolean = binding.sourceStepId !== undefined && binding.sourceStepId.trim().length > 0;
    const hasLiteral: boolean = binding.literalJson !== undefined && binding.literalJson.trim().length > 0;
    if (hasSource === hasLiteral) {
      result.issues.push(path + ' must declare exactly one source or literal');
      return;
    }
    if (hasSource) {
      const sourceId: string = binding.sourceStepId as string;
      if (WorkflowGraphValidator.findStepIndex(graph, sourceId) < 0) {
        result.issues.push(path + ' references unknown source step ' + sourceId);
      }
      if (!WorkflowGraphValidator.contains(step.dependencies, sourceId)) {
        result.issues.push(path + ' source step must be a declared dependency');
      }
      if (binding.sourceOutputPath === undefined || binding.sourceOutputPath.trim().length === 0) {
        result.issues.push(path + '.sourceOutputPath must not be empty');
      }
    } else if (!WorkflowGraphValidator.isJsonText(binding.literalJson as string)) {
      result.issues.push(path + '.literalJson must be valid JSON');
    }
  }

  private static validateAcyclic(graph: WorkflowGraph, result: GraphValidationResult): void {
    const remainingDependencies: number[] = [];
    const processed: boolean[] = [];
    for (let i: number = 0; i < graph.steps.length; i++) {
      remainingDependencies.push(graph.steps[i].dependencies.length);
      processed.push(false);
    }
    let processedCount: number = 0;
    let advanced: boolean = true;
    while (advanced) {
      advanced = false;
      for (let i: number = 0; i < graph.steps.length; i++) {
        if (!processed[i] && remainingDependencies[i] === 0) {
          processed[i] = true;
          processedCount++;
          advanced = true;
          for (let target: number = 0; target < graph.steps.length; target++) {
            if (!processed[target] && WorkflowGraphValidator.contains(graph.steps[target].dependencies,
              graph.steps[i].stepId)) {
              remainingDependencies[target]--;
            }
          }
        }
      }
    }
    if (processedCount !== graph.steps.length) {
      result.issues.push('workflow graph must be acyclic');
    }
  }

  private static findStepIndex(graph: WorkflowGraph, stepId: string): number {
    for (let i: number = 0; i < graph.steps.length; i++) {
      if (graph.steps[i].stepId === stepId) {
        return i;
      }
    }
    return -1;
  }

  private static findStepIndexBefore(graph: WorkflowGraph, stepId: string, before: number): number {
    for (let i: number = 0; i < before; i++) {
      if (graph.steps[i].stepId === stepId) {
        return i;
      }
    }
    return -1;
  }

  private static contains(values: string[], target: string): boolean {
    for (let i: number = 0; i < values.length; i++) {
      if (values[i] === target) {
        return true;
      }
    }
    return false;
  }

  private static isJsonObjectText(value: string): boolean {
    const trimmed: string = value.trim();
    if (trimmed.length < 2 || trimmed.charAt(0) !== '{' || trimmed.charAt(trimmed.length - 1) !== '}') {
      return false;
    }
    return WorkflowGraphValidator.isJsonText(value);
  }

  private static isJsonText(value: string): boolean {
    try {
      JSON.parse(value);
      return true;
    } catch (error) {
      return false;
    }
  }
}
