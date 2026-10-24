import { ContractCodec, WorkflowGraph, WorkflowStep } from '@harmony_agent/agent-contracts';
import {
  GraphValidationResult,
  WorkflowGraphValidator,
  WorkflowRuntimeSnapshot,
  WorkflowStepState
} from '@harmony_agent/agent-core';
import { ReplanResult } from './OrchestrationTypes';

export class WorkflowReplanController {
  static replaceAffectedSubgraph(current: WorkflowGraph, replacement: WorkflowGraph,
    affectedStepIds: string[], runtime: WorkflowRuntimeSnapshot): ReplanResult {
    const result: ReplanResult = new ReplanResult();
    if (affectedStepIds.length === 0 || current.taskId !== replacement.taskId ||
      current.workflowId !== replacement.workflowId || current.workflowVersion === replacement.workflowVersion) {
      result.code = 'INVALID_REPLAN_IDENTITY';
      return result;
    }
    for (let i: number = 0; i < affectedStepIds.length; i++) {
      const state: WorkflowStepState | undefined = WorkflowReplanController.stateFor(runtime, affectedStepIds[i]);
      if (state === undefined) {
        result.code = 'AFFECTED_STEP_NOT_FOUND';
        return result;
      }
      if (state === WorkflowStepState.SUCCEEDED || state === WorkflowStepState.UNKNOWN_OUTCOME ||
        state === WorkflowStepState.RUNNING || state === WorkflowStepState.VERIFYING) {
        result.code = 'AFFECTED_STEP_IS_PROTECTED';
        return result;
      }
    }

    const merged: WorkflowGraph = ContractCodec.parseWorkflowGraph(ContractCodec.stringify(current));
    merged.workflowVersion = replacement.workflowVersion;
    merged.createdAt = replacement.createdAt;
    const nextSteps: WorkflowStep[] = [];
    for (let i: number = 0; i < merged.steps.length; i++) {
      if (!WorkflowReplanController.contains(affectedStepIds, merged.steps[i].stepId)) {
        nextSteps.push(merged.steps[i]);
      }
    }
    for (let i: number = 0; i < replacement.steps.length; i++) {
      if (WorkflowReplanController.contains(affectedStepIds, replacement.steps[i].stepId)) {
        nextSteps.push(replacement.steps[i]);
      }
    }
    merged.steps = nextSteps;
    merged.entryStepIds = [];
    for (let i: number = 0; i < merged.steps.length; i++) {
      if (merged.steps[i].dependencies.length === 0) {
        merged.entryStepIds.push(merged.steps[i].stepId);
      }
    }
    const validation: GraphValidationResult = WorkflowGraphValidator.validate(merged);
    if (!validation.valid) {
      result.code = 'INVALID_REPLACEMENT:' + validation.issues.join('|');
      return result;
    }
    result.accepted = true;
    result.code = 'REPLANNED';
    result.workflow = merged;
    return result;
  }

  private static stateFor(runtime: WorkflowRuntimeSnapshot, stepId: string): WorkflowStepState | undefined {
    for (let i: number = 0; i < runtime.steps.length; i++) {
      if (runtime.steps[i].stepId === stepId) {
        return runtime.steps[i].state;
      }
    }
    return undefined;
  }

  private static contains(values: string[], value: string): boolean {
    for (let i: number = 0; i < values.length; i++) {
      if (values[i] === value) {
        return true;
      }
    }
    return false;
  }
}
