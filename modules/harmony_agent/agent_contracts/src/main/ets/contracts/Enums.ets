export enum PrivacyClass {
  PUBLIC = 'public',
  PERSONAL = 'personal',
  SENSITIVE = 'sensitive',
  RESTRICTED = 'restricted'
}

export enum RiskLevel {
  LOW = 'low',
  MEDIUM = 'medium',
  HIGH = 'high',
  CRITICAL = 'critical'
}

export enum SideEffect {
  NONE = 'none',
  REVERSIBLE = 'reversible',
  IRREVERSIBLE = 'irreversible'
}

export enum IdempotencyMode {
  NONE = 'none',
  PROVIDER_KEY = 'providerKey',
  RECONCILE = 'reconcile'
}

export enum WorkflowStepKind {
  LLM = 'llm',
  TOOL = 'tool',
  VERIFY = 'verify',
  JOIN = 'join',
  USER_CONFIRMATION = 'userConfirmation'
}

export enum RouterKind {
  COLLABORATION = 'collaboration',
  MODEL = 'model',
  CONTEXT = 'context',
  TOOL_SET = 'toolSet'
}

export enum CollaborationMode {
  SINGLE = 'single',
  MULTI = 'multi'
}

export enum ToolSourceType {
  NATIVE = 'native',
  MCP = 'mcp',
  REMOTE_API = 'remoteApi'
}

export enum DataBoundary {
  DEVICE_ONLY = 'deviceOnly',
  APP_SANDBOX = 'appSandbox',
  REMOTE_ALLOWED = 'remoteAllowed'
}

export enum ToolOutcomeStatus {
  SUCCEEDED = 'succeeded',
  FAILED = 'failed',
  DENIED = 'denied',
  CANCELLED = 'cancelled',
  UNKNOWN_OUTCOME = 'unknownOutcome'
}

export enum AuthorizationDecisionType {
  APPROVED = 'approved',
  DENIED = 'denied'
}

export enum TaskControlAction {
  CANCEL = 'cancel',
  PAUSE = 'pause',
  RESUME = 'resume'
}

export enum AgentTaskStatus {
  RECEIVED = 'received',
  WAITING_INPUT = 'waitingInput',
  WAITING_AUTHORIZATION = 'waitingAuthorization',
  RUNNING = 'running',
  PAUSED = 'paused',
  WAITING_RECONCILIATION = 'waitingReconciliation',
  COMPLETED = 'completed',
  FAILED = 'failed',
  CANCELLED = 'cancelled'
}

export enum AgentRuntimeEventType {
  TASK_ACCEPTED = 'taskAccepted',
  TASK_STATE_CHANGED = 'taskStateChanged',
  CLARIFICATION_REQUIRED = 'clarificationRequired',
  AUTHORIZATION_REQUIRED = 'authorizationRequired',
  RECONCILIATION_REQUIRED = 'reconciliationRequired',
  RESULT_UPDATED = 'resultUpdated',
  TASK_COMPLETED = 'taskCompleted',
  TASK_FAILED = 'taskFailed',
  TASK_CANCELLED = 'taskCancelled'
}

export enum ReconciliationStatus {
  CONFIRMED_SUCCEEDED = 'confirmedSucceeded',
  CONFIRMED_FAILED = 'confirmedFailed',
  NOT_EXECUTED = 'notExecuted',
  STILL_UNKNOWN = 'stillUnknown'
}

export enum AgentErrorClass {
  INVALID_INPUT = 'invalidInput',
  CONFIGURATION = 'configuration',
  NETWORK = 'network',
  TIMEOUT = 'timeout',
  AUTHENTICATION = 'authentication',
  PERMISSION_DENIED = 'permissionDenied',
  POLICY_DENIED = 'policyDenied',
  SCHEMA_MISMATCH = 'schemaMismatch',
  BUDGET_EXHAUSTED = 'budgetExhausted',
  CANCELLED = 'cancelled',
  PROVIDER = 'provider',
  VERIFICATION_FAILED = 'verificationFailed',
  UNKNOWN = 'unknown'
}

export enum ArtifactLifecycleStatus {
  DISABLED = 'disabled',
  SHADOW = 'shadow',
  CANARY = 'canary',
  ACTIVE = 'active',
  ROLLED_BACK = 'rolledBack'
}

export enum ArtifactKind {
  CHECKPOINT = 'checkpoint',
  POLICY = 'policy',
  WORKFLOW = 'workflow'
}

export enum ArtifactApprovalStatus {
  UNREVIEWED = 'unreviewed',
  APPROVED = 'approved',
  REJECTED = 'rejected'
}
