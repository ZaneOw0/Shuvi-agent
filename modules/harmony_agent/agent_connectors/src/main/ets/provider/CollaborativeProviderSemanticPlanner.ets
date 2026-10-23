import {
  ClarificationResponse,
  CollaborationMode,
  ContractCodec,
  TaskFrame,
  WorkflowGraph
} from '@harmony_agent/agent-contracts';
import {
  CollaborationPlan,
  CollaborationPlanValidator,
  CollaborationRoleAssignment,
  PlanningRequest,
  PlanningResult,
  PlanningStatus,
  SemanticPlannerPort
} from '@harmony_agent/agent-runtime';
import {
  ProviderPlanningPhase,
  ProviderSemanticPlanner
} from './ProviderSemanticPlanner';

function copyFrame(source: TaskFrame): TaskFrame {
  const value: TaskFrame = new TaskFrame();
  value.schemaVersion = source.schemaVersion;
  value.taskId = source.taskId;
  value.goal = source.goal;
  value.constraints = source.constraints.slice();
  value.capabilityCategories = source.capabilityCategories.slice();
  value.riskLevel = source.riskLevel;
  value.canParallelize = source.canParallelize;
  value.featuresJson = source.featuresJson;
  return value;
}

function copyRole(source: CollaborationRoleAssignment): CollaborationRoleAssignment {
  const value: CollaborationRoleAssignment = new CollaborationRoleAssignment();
  value.roleId = source.roleId;
  value.roleVersion = source.roleVersion;
  value.roleRegistryDigest = source.roleRegistryDigest;
  return value;
}

function copyPlan(source: CollaborationPlan): CollaborationPlan {
  const value: CollaborationPlan = new CollaborationPlan();
  value.planVersion = source.planVersion;
  value.taskId = source.taskId;
  value.mode = source.mode;
  value.roleRegistryDigest = source.roleRegistryDigest;
  value.decisionDigest = source.decisionDigest;
  for (let i: number = 0; i < source.assignments.length; i++) {
    value.assignments.push(copyRole(source.assignments[i]));
  }
  return value;
}

function copyRequest(source: PlanningRequest): PlanningRequest {
  const value: PlanningRequest = new PlanningRequest();
  value.envelope = ContractCodec.parseTaskEnvelope(ContractCodec.stringify(source.envelope));
  value.frame = copyFrame(source.frame);
  value.collaborationMode = source.collaborationMode;
  if (source.collaborationPlan !== undefined) value.collaborationPlan = copyPlan(source.collaborationPlan);
  if (source.previousWorkflow !== undefined) {
    value.previousWorkflow = ContractCodec.parseWorkflowGraph(ContractCodec.stringify(source.previousWorkflow));
  }
  value.affectedStepIds = source.affectedStepIds.slice();
  return value;
}

function refinementRequest(source: PlanningRequest, workflow: WorkflowGraph): PlanningRequest {
  const value: PlanningRequest = copyRequest(source);
  value.previousWorkflow = ContractCodec.parseWorkflowGraph(ContractCodec.stringify(workflow));
  value.affectedStepIds = [];
  for (let i: number = 0; i < workflow.steps.length; i++) {
    value.affectedStepIds.push(workflow.steps[i].stepId);
  }
  return value;
}

/**
 * Executes one independent Provider planning request per registered role.
 * Later roles receive the previous typed workflow and refine it through the
 * existing replan validator. The class remains an internal Planner adapter;
 * callers still control tasks only through AgentRuntimeFacade.
 */
export class CollaborativeProviderSemanticPlanner implements SemanticPlannerPort {
  private readonly planner: ProviderSemanticPlanner;

  constructor(planner: ProviderSemanticPlanner) {
    this.planner = planner;
  }

  async plan(request: PlanningRequest): Promise<PlanningResult> {
    return await this.execute(ProviderPlanningPhase.PLAN, request);
  }

  async resume(request: PlanningRequest, response: ClarificationResponse): Promise<PlanningResult> {
    return await this.execute(ProviderPlanningPhase.RESUME, request, response);
  }

  async replan(request: PlanningRequest): Promise<PlanningResult> {
    return await this.execute(ProviderPlanningPhase.REPLAN, request);
  }

  interrupt(taskId: string): boolean {
    return this.planner.interrupt(taskId);
  }

  private async execute(phase: ProviderPlanningPhase, request: PlanningRequest,
    response?: ClarificationResponse): Promise<PlanningResult> {
    const plan: CollaborationPlan | undefined = request.collaborationPlan;
    if (plan === undefined) {
      if (request.collaborationMode === CollaborationMode.MULTI) {
        return this.rejected('COLLABORATION_PLAN_REQUIRED');
      }
      return await this.invokeLegacy(phase, request, response);
    }
    if (!CollaborationPlanValidator.validate(plan, request.frame,
      request.envelope.executionBudget.maxAgentActivations).valid ||
      plan.mode !== request.collaborationMode) {
      return this.rejected('COLLABORATION_PLAN_INVALID');
    }
    const budgetCode: string = this.planner.collaborativeBudgetRejectionCode(request,
      plan.assignments.length);
    if (budgetCode.length > 0) return this.rejected(budgetCode);

    let current: PlanningRequest = copyRequest(request);
    let result: PlanningResult = new PlanningResult();
    for (let i: number = 0; i < plan.assignments.length; i++) {
      const role: CollaborationRoleAssignment = plan.assignments[i];
      if (i === 0) {
        result = await this.invokeFirst(phase, current, role, response);
      } else {
        if (result.status !== PlanningStatus.READY || result.workflow === undefined) return result;
        current = refinementRequest(request, result.workflow);
        result = await this.planner.replanForRole(current, role);
      }
      if (result.status !== PlanningStatus.READY) return result;
    }
    return result;
  }

  private async invokeFirst(phase: ProviderPlanningPhase, request: PlanningRequest,
    role: CollaborationRoleAssignment, response?: ClarificationResponse): Promise<PlanningResult> {
    if (phase === ProviderPlanningPhase.PLAN) return await this.planner.planForRole(request, role);
    if (phase === ProviderPlanningPhase.RESUME && response !== undefined) {
      return await this.planner.resumeForRole(request, response, role);
    }
    return await this.planner.replanForRole(request, role);
  }

  private async invokeLegacy(phase: ProviderPlanningPhase, request: PlanningRequest,
    response?: ClarificationResponse): Promise<PlanningResult> {
    if (phase === ProviderPlanningPhase.PLAN) return await this.planner.plan(request);
    if (phase === ProviderPlanningPhase.RESUME && response !== undefined) {
      return await this.planner.resume(request, response);
    }
    return await this.planner.replan(request);
  }

  private rejected(code: string): PlanningResult {
    const value: PlanningResult = new PlanningResult();
    value.status = PlanningStatus.REJECTED;
    value.rejectionCode = code;
    return value;
  }
}
