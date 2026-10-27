import { ClarificationResponse, PrivacyClass, WorkflowGraph, WorkflowStep, WorkflowStepKind, WorkflowInputBinding,
  PolicyRequest, ToolInvocation } from '@harmony_agent/agent-contracts';
import { PlanningRequest, PlanningResult, PlanningStatus, PreparedToolDispatch, RuntimeIdGeneratorPort,
  SemanticPlannerPort, ToolInvocationPreparerPort, ToolRegistry } from '@harmony_agent/agent-runtime';
import { AgentHostDigest } from '../model/AgentHostDigest';
import { CALENDAR_TOOL_ID, CalendarToolPreviews, parseCalendarToolArguments } from './CalendarToolContract';

export class CalendarToolPlanner implements SemanticPlannerPort, ToolInvocationPreparerPort {
  private readonly registry: ToolRegistry;
  private readonly digest: AgentHostDigest;
  private readonly ids: RuntimeIdGeneratorPort;
  private readonly previews: CalendarToolPreviews;
  constructor(registry: ToolRegistry, digest: AgentHostDigest, ids: RuntimeIdGeneratorPort, previews: CalendarToolPreviews) {
    this.registry = registry; this.digest = digest; this.ids = ids; this.previews = previews;
  }
  async plan(request: PlanningRequest): Promise<PlanningResult> {
    const result = new PlanningResult(); const tool = this.registry.activeEntries().find((entry): boolean => entry.descriptor.toolId === CALENDAR_TOOL_ID);
    if (tool === undefined || request.envelope.privacyClass !== PrivacyClass.PERSONAL ||
      parseCalendarToolArguments(request.envelope.userIntent, Date.now()) === undefined) return result;
    const step = new WorkflowStep(); step.stepId = 'calendar-create'; step.kind = WorkflowStepKind.TOOL;
    step.goal = '用户确认后创建本次日程并核对'; step.timeoutMs = 25000;
    step.sideEffect = tool.descriptor.sideEffect; step.riskLevel = tool.descriptor.riskLevel;
    step.idempotencyMode = tool.descriptor.idempotencyMode;
    step.capabilityRequirements = tool.descriptor.capabilityTags; step.permissionRequirements = tool.descriptor.permissionRequirements;
    step.expectedOutputSchemaJson = '{"type":"object"}'; step.retryPolicyRef = 'no-retry'; step.verificationPolicyRef = 'calendar-readback-v1';
    const input = new WorkflowInputBinding(); input.name = 'draft'; input.literalJson = request.envelope.userIntent; step.inputBindings = [input];
    const graph = new WorkflowGraph(); graph.taskId = request.envelope.taskId; graph.workflowId = 'calendar-' + graph.taskId;
    graph.workflowVersion = '1'; graph.createdAt = new Date().toISOString(); graph.steps = [step]; graph.entryStepIds = [step.stepId];
    result.status = PlanningStatus.READY; result.workflow = graph; return result;
  }
  prepare(request: PlanningRequest, step: WorkflowStep, now: number): PreparedToolDispatch {
    const result = new PreparedToolDispatch();
    const entry = this.registry.activeEntries().find((item): boolean => item.descriptor.toolId === CALENDAR_TOOL_ID);
    if (entry === undefined || step.kind !== WorkflowStepKind.TOOL || step.stepId !== 'calendar-create' ||
      step.inputBindings.length !== 1 || step.inputBindings[0].name !== 'draft' ||
      step.inputBindings[0].literalJson !== request.envelope.userIntent ||
      parseCalendarToolArguments(request.envelope.userIntent, now) === undefined) return result;
    const tool = entry.descriptor; const policy = new PolicyRequest();
    policy.requestId = this.ids.nextId('policy', request.envelope.requestId); policy.userId = request.envelope.userId;
    policy.taskId = request.envelope.taskId; policy.stepId = step.stepId;
    policy.operationId = this.ids.nextId('shuvi-calendar', policy.taskId); policy.toolId = tool.toolId;
    policy.toolIdentityVersion = tool.toolIdentityVersion; policy.providerId = tool.providerId; policy.schemaDigest = tool.schemaDigest;
    policy.argumentsDigest = this.digest.digest(request.envelope.userIntent); policy.riskLevel = tool.riskLevel; policy.sideEffect = tool.sideEffect;
    policy.requestedAt = new Date(now).toISOString(); policy.expiresAtMs = now + 120000; policy.expiresAt = new Date(policy.expiresAtMs).toISOString();
    const invocation = new ToolInvocation(); invocation.invocationId = this.ids.nextId('invocation', policy.taskId);
    invocation.attemptId = this.ids.nextId('attempt', policy.taskId); invocation.taskId = policy.taskId; invocation.stepId = policy.stepId;
    invocation.operationId = policy.operationId; invocation.toolId = policy.toolId; invocation.toolIdentityVersion = policy.toolIdentityVersion;
    invocation.idempotencyKey = policy.operationId;
    invocation.schemaDigest = policy.schemaDigest; invocation.argumentsDigest = policy.argumentsDigest;
    invocation.argumentsJson = request.envelope.userIntent; invocation.timeoutMs = step.timeoutMs; invocation.createdAt = policy.requestedAt;
    result.policyRequest = policy; result.invocation = invocation;
    return this.previews.capture(result, this.digest) ? result : new PreparedToolDispatch();
  }
  async resume(_request: PlanningRequest, _response: ClarificationResponse): Promise<PlanningResult> { return new PlanningResult(); }
  async replan(_request: PlanningRequest): Promise<PlanningResult> { return new PlanningResult(); }
  interrupt(_taskId: string): boolean { return false; }
}
