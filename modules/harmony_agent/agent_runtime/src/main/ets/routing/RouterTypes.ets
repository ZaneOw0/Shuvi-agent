import {
  CollaborationMode,
  DataBoundary,
  PrivacyClass,
  RiskLevel,
  RouterDecision,
  RouterRequest,
  SideEffect,
  TaskFrame,
  WorkflowStep
} from '@harmony_agent/agent-contracts';

export class DeterministicRouterConfig {
  policyVersion: string = '';
  artifactDigest: string = '';
  learnedEnabled: boolean = false;
  minimumLearnedConfidence: number = 0.8;
}

export interface LearnedRouterPort {
  route(request: RouterRequest): RouterDecision;
}

export class RouterResult {
  accepted: boolean = false;
  code: string = '';
  decision?: RouterDecision;
}

export class ModelRouteRequest {
  requestId: string = '';
  taskId: string = '';
  requiredCapabilityTags: string[] = [];
  region: string = '';
  privacyClass: PrivacyClass = PrivacyClass.PERSONAL;
  estimatedInputTokens: number = 0;
  maxCostMicros: number = 0;
  inputFeatureDigest: string = '';
  createdAt: string = '';
}

export class ToolRouteRequest {
  requestId: string = '';
  taskId: string = '';
  step: WorkflowStep = new WorkflowStep();
  allowedToolIds: string[] = [];
  allowedProviderIds: string[] = [];
  allowedSideEffects: SideEffect[] = [];
  allowedDataBoundaries: DataBoundary[] = [];
  availablePermissions: string[] = [];
  maxRiskLevel: RiskLevel = RiskLevel.LOW;
  maxCostMicros: number = 0;
  maxTools: number = 1;
  networkAvailable: boolean = false;
  inputFeatureDigest: string = '';
  createdAt: string = '';
}

export enum ContextSourceKind {
  SYSTEM = 'system',
  USER = 'user',
  DEPENDENCY = 'dependency',
  SHORT_TERM = 'shortTerm',
  MEMORY = 'memory',
  OPTIONAL = 'optional'
}

export class ContextCandidate {
  contextId: string = '';
  sourceKind: ContextSourceKind = ContextSourceKind.OPTIONAL;
  tokenCount: number = 0;
  relevanceScore: number = 0;
  freshnessScore: number = 0;
  verified: boolean = false;
  privacyAllowed: boolean = false;
  contentDigest: string = '';
}

export class ContextRouteRequest {
  requestId: string = '';
  taskId: string = '';
  stepId: string = '';
  tokenBudget: number = 0;
  candidates: ContextCandidate[] = [];
  inputFeatureDigest: string = '';
  createdAt: string = '';
}

export class ContextRouteResult extends RouterResult {
  totalTokens: number = 0;
}

export class CollaborationRouteRequest {
  requestId: string = '';
  taskId: string = '';
  frame: TaskFrame = new TaskFrame();
  maxAgentActivations: number = 1;
  inputFeatureDigest: string = '';
  createdAt: string = '';
}

export class CollaborationRouteResult extends RouterResult {
  mode: CollaborationMode = CollaborationMode.SINGLE;
  selectedRoleIds: string[] = [];
}
