import { CollaborationMode, TaskFrame } from '@harmony_agent/agent-contracts';
import {
  COLLABORATION_PLAN_VERSION,
  CollaborationPlan,
  CollaborationRoleAssignment
} from './OrchestrationTypes';

export class CollaborationPlanValidationResult {
  valid: boolean = false;
  issues: string[] = [];

  addIssue(issue: string): void {
    this.issues.push(issue);
  }
}

function text(value: string): boolean {
  return value.trim().length > 0;
}

function fullSha256(value: string): boolean {
  const prefix: string = 'sha256:';
  if (!value.startsWith(prefix) || value.length !== prefix.length + 64) return false;
  const body: string = value.substring(prefix.length).toLowerCase();
  for (let i: number = 0; i < body.length; i++) {
    const character: string = body.charAt(i);
    if ('0123456789abcdef'.indexOf(character) < 0) return false;
  }
  return true;
}

function contains(values: string[], value: string): boolean {
  for (let i: number = 0; i < values.length; i++) {
    if (values[i] === value) return true;
  }
  return false;
}

export class CollaborationPlanValidator {
  static validate(value: CollaborationPlan, frame: TaskFrame,
    maxAgentActivations: number): CollaborationPlanValidationResult {
    const result: CollaborationPlanValidationResult = new CollaborationPlanValidationResult();
    if (value.planVersion !== COLLABORATION_PLAN_VERSION) result.addIssue('planVersion is unsupported');
    if (!text(value.taskId) || value.taskId !== frame.taskId) result.addIssue('taskId is not bound to frame');
    if (!fullSha256(value.roleRegistryDigest)) result.addIssue('roleRegistryDigest is invalid');
    if (!fullSha256(value.decisionDigest)) result.addIssue('decisionDigest is invalid');
    if (!Number.isSafeInteger(maxAgentActivations) || maxAgentActivations <= 0) {
      result.addIssue('maxAgentActivations is invalid');
    }
    if (value.mode !== CollaborationMode.SINGLE && value.mode !== CollaborationMode.MULTI) {
      result.addIssue('mode is invalid');
    }
    if (value.mode === CollaborationMode.SINGLE && value.assignments.length !== 1) {
      result.addIssue('single collaboration requires exactly one role');
    }
    if (value.mode === CollaborationMode.MULTI && value.assignments.length < 2) {
      result.addIssue('multi collaboration requires at least two roles');
    }
    if (value.assignments.length > maxAgentActivations) {
      result.addIssue('assignments exceed maxAgentActivations');
    }
    const roleIds: string[] = [];
    for (let i: number = 0; i < value.assignments.length; i++) {
      const assignment: CollaborationRoleAssignment = value.assignments[i];
      if (!text(assignment.roleId) || !text(assignment.roleVersion) ||
        !fullSha256(assignment.roleRegistryDigest)) {
        result.addIssue('assignments[' + i.toString() + '] identity is invalid');
      }
      if (contains(roleIds, assignment.roleId)) {
        result.addIssue('assignments contain duplicate roleId');
      }
      roleIds.push(assignment.roleId);
    }
    result.valid = result.issues.length === 0;
    return result;
  }
}
