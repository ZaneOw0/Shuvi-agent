import { AGENT_CONTRACT_SCHEMA_VERSION, CONTRACT_TYPE_TASK_ENVELOPE } from './Constants';
import { ContractId, Digest, DurationMs, IsoTimestamp, MoneyMicros, TokenCount } from './Common';
import { PrivacyClass, RiskLevel } from './Enums';

export class ExecutionBudget {
  maxWallTimeMs: DurationMs = 0;
  maxInputTokens: TokenCount = 0;
  maxOutputTokens: TokenCount = 0;
  maxMonetaryCostMicros: MoneyMicros = 0;
  maxToolCalls: number = 0;
  maxAgentActivations: number = 0;
  maxRetries: number = 0;
  maxReplans: number = 0;
  deadlineAt?: IsoTimestamp;
}

export class TaskInputRef {
  refId: ContractId = '';
  mediaType: string = '';
  digest: Digest = '';
  source: string = '';
}

export class ConsentContext {
  interactiveAllowed: boolean = true;
  grantedPolicyIds: string[] = [];
}

export class TaskEnvelope {
  schemaVersion: string = AGENT_CONTRACT_SCHEMA_VERSION;
  contractType: string = CONTRACT_TYPE_TASK_ENVELOPE;
  requestId: ContractId = '';
  conversationId?: ContractId;
  taskId: ContractId = '';
  sessionId: ContractId = '';
  userId: ContractId = '';
  userIntent: string = '';
  locale: string = '';
  timeZone: string = '';
  referenceTime: IsoTimestamp = '';
  privacyClass: PrivacyClass = PrivacyClass.PERSONAL;
  inputRefs: TaskInputRef[] = [];
  executionBudget: ExecutionBudget = new ExecutionBudget();
  consentContext: ConsentContext = new ConsentContext();
  deviceSnapshotRef?: ContractId;
  createdAt: IsoTimestamp = '';
}

export class TaskFrame {
  schemaVersion: string = AGENT_CONTRACT_SCHEMA_VERSION;
  taskId: ContractId = '';
  goal: string = '';
  constraints: string[] = [];
  capabilityCategories: string[] = [];
  riskLevel: RiskLevel = RiskLevel.LOW;
  canParallelize: boolean = false;
  featuresJson: string = '{}';
}
