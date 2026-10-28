import { ContractValidator, DataBoundary, IdempotencyMode, RiskLevel, SideEffect,
  ToolDescriptor, ToolSourceType } from '@harmony_agent/agent-contracts';
import { AgentFrontendAuthorizationPrompt, PreparedToolDispatch, ToolRegistry, ToolRegistryEntry } from '@harmony_agent/agent-runtime';
import { AgentHostDigest } from '../model/AgentHostDigest';
import { CalendarProbeDraft, calendarProbeDraftError } from './CalendarProbeSession';

export const CALENDAR_TOOL_ID: string = 'shuvi.calendar.create';
export const CALENDAR_PROVIDER: string = 'shuvi-calendar-native';
export const CALENDAR_POLICY: string = 'shuvi-calendar-tool-v1';
export const CALENDAR_OWNER: string = 'shuvi-local-owner-v1';

export function parseCalendarToolArguments(raw: string, now: number): CalendarProbeDraft | undefined {
  try {
    if (raw.length > 4000) return undefined;
    const draft: CalendarProbeDraft = JSON.parse(raw);
    if (draft === null || typeof draft !== 'object' || Array.isArray(draft) ||
      Object.keys(draft).length !== 5 || calendarProbeDraftError(draft, now)) return undefined;
    return draft;
  } catch { return undefined; }
}

export class CalendarToolResult {
  schemaVersion: string = '1.0';
  kind: string = 'calendarResult';
  operationId: string = '';
  eventId: number = -1;
  verified: boolean = false;
  reminderConfigured: boolean = false;
  message: string = '';
}
export function parseCalendarToolResult(raw: string): CalendarToolResult | undefined {
  try {
    if (raw.length > 5000) return undefined;
    const value: CalendarToolResult = JSON.parse(raw);
    if (value === null || typeof value !== 'object' || value.schemaVersion !== '1.0' || value.kind !== 'calendarResult' ||
      typeof value.operationId !== 'string' || !/^shuvi-calendar-[a-zA-Z0-9-]+$/.test(value.operationId) ||
      !Number.isSafeInteger(value.eventId) || (value.eventId !== -1 && value.eventId <= 0) ||
      typeof value.verified !== 'boolean' || typeof value.reminderConfigured !== 'boolean' ||
      (value.verified && value.eventId <= 0) || typeof value.message !== 'string' || value.message.length > 1000) return undefined;
    return value;
  } catch { return undefined; }
}

export function registerCalendarTool(registry: ToolRegistry, digest: AgentHostDigest): ToolDescriptor {
  const tool = new ToolDescriptor();
  tool.toolId = CALENDAR_TOOL_ID; tool.providerId = CALENDAR_PROVIDER; tool.sourceType = ToolSourceType.NATIVE;
  tool.capabilityName = 'create_calendar_event'; tool.capabilityVersion = '1.0'; tool.toolIdentityVersion = '1.0';
  tool.displayName = '创建系统日程'; tool.description = '用户确认后创建 Shuvi 日历事件并读回核查，不保证通知实际送达。';
  tool.inputSchemaJson = '{"type":"object","additionalProperties":false,"required":["title","startAt","endAt","timeZone","reminderMinutes"],"properties":{"title":{"type":"string","minLength":1,"maxLength":200},"startAt":{"type":"string"},"endAt":{"type":"string"},"timeZone":{"const":"Asia/Shanghai"},"reminderMinutes":{"type":"integer","minimum":0,"maximum":10080}}}';
  tool.outputSchemaJson = '{"type":"object"}'; tool.schemaDigest = digest.digest(tool.inputSchemaJson);
  tool.capabilityTags = ['calendar.create']; tool.permissionRequirements = ['ohos.permission.READ_CALENDAR', 'ohos.permission.WRITE_CALENDAR'];
  tool.riskLevel = RiskLevel.MEDIUM; tool.sideEffect = SideEffect.REVERSIBLE;
  tool.idempotencyMode = IdempotencyMode.RECONCILE; tool.dataBoundary = DataBoundary.DEVICE_ONLY;
  tool.adapterRef = 'native:calendar-kit'; tool.availability = 'available'; tool.latencyClass = 'interactive'; tool.costClass = 'local';
  const entry = new ToolRegistryEntry(); entry.descriptor = tool; entry.registryVersion = '1';
  entry.registryDigest = digest.digest(JSON.stringify(tool)); entry.descriptionDigest = digest.digest(tool.description);
  entry.retrievalRelationVersion = '1'; entry.enabled = true;
  if (!registry.register(entry).accepted) throw new Error('CALENDAR_REGISTRY_REJECTED');
  return tool;
}

export class CalendarToolPreview {
  requestId: string = '';
  taskId: string = '';
  operationId: string = '';
  expiresAt: string = '';
  draft: CalendarProbeDraft = new CalendarProbeDraft();
}
class CalendarPreviewEntry {
  prepared: PreparedToolDispatch;
  constructor(prepared: PreparedToolDispatch) { this.prepared = prepared; }
}
/** Binds the visible confirmation to the exact policy/invocation persisted by Runtime. */
export class CalendarToolPreviews {
  private entries: CalendarPreviewEntry[] = [];
  capture(prepared: PreparedToolDispatch, digest: AgentHostDigest): boolean {
    const policy = prepared.policyRequest; const invocation = prepared.invocation;
    if (!ContractValidator.validatePolicyRequest(policy).valid || policy.toolId !== CALENDAR_TOOL_ID ||
      invocation.toolId !== CALENDAR_TOOL_ID || policy.estimatedCostMicros !== 0 ||
      policy.providerId !== CALENDAR_PROVIDER || policy.userId !== CALENDAR_OWNER ||
      policy.sideEffect !== SideEffect.REVERSIBLE || policy.riskLevel !== RiskLevel.MEDIUM ||
      policy.argumentsDigest !== digest.digest(invocation.argumentsJson) || policy.argumentsDigest !== invocation.argumentsDigest ||
      policy.taskId !== invocation.taskId || policy.stepId !== invocation.stepId || policy.operationId !== invocation.operationId ||
      policy.toolIdentityVersion !== invocation.toolIdentityVersion || policy.schemaDigest !== invocation.schemaDigest ||
      parseCalendarToolArguments(invocation.argumentsJson, Date.now()) === undefined) return false;
    this.entries = this.entries.filter((item: CalendarPreviewEntry): boolean => item.prepared.policyRequest.expiresAtMs > Date.now());
    if (this.entries.length >= 32 || this.entries.some((item: CalendarPreviewEntry): boolean => item.prepared.policyRequest.requestId === policy.requestId)) return false;
    const copy: PreparedToolDispatch = JSON.parse(JSON.stringify(prepared)); this.entries.push(new CalendarPreviewEntry(copy)); return true;
  }
  resolve(prompt: AgentFrontendAuthorizationPrompt): CalendarToolPreview | undefined {
    const entry = this.entries.find((item: CalendarPreviewEntry): boolean => item.prepared.policyRequest.requestId === prompt.requestId);
    if (entry === undefined) return undefined;
    const policy = entry.prepared.policyRequest;
    if (prompt.taskId !== policy.taskId || prompt.toolId !== policy.toolId || prompt.providerId !== policy.providerId ||
      prompt.riskLevel !== policy.riskLevel || prompt.requestedAt !== policy.requestedAt || prompt.expiresAt !== policy.expiresAt ||
      prompt.estimatedCostMicros !== 0 || policy.expiresAtMs <= Date.now()) return undefined;
    const draft = parseCalendarToolArguments(entry.prepared.invocation.argumentsJson, Date.now());
    if (draft === undefined) return undefined;
    const preview = new CalendarToolPreview(); preview.requestId = policy.requestId; preview.taskId = policy.taskId;
    preview.operationId = policy.operationId; preview.expiresAt = policy.expiresAt; preview.draft = draft; return preview;
  }
  clear(): void { this.entries = []; }
}
