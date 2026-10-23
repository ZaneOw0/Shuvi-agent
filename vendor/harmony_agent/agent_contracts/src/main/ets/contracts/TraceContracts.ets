import { AGENT_CONTRACT_SCHEMA_VERSION, CONTRACT_TYPE_TRACE_EVENT } from './Constants';
import { ContractId, Digest, DurationMs, IsoTimestamp, JsonText, MoneyMicros, TokenCount } from './Common';
import { AgentErrorClass } from './Enums';

export class TraceEvent {
  schemaVersion: string = AGENT_CONTRACT_SCHEMA_VERSION;
  contractType: string = CONTRACT_TYPE_TRACE_EVENT;
  eventId: ContractId = '';
  taskId: ContractId = '';
  stepId?: ContractId;
  parentEventId?: ContractId;
  eventType: string = '';
  timestamp: IsoTimestamp = '';
  component: string = '';
  componentVersion: string = '';
  policyOrArtifactDigest?: Digest;
  budgetBeforeJson: JsonText = '{}';
  budgetAfterJson: JsonText = '{}';
  inputDigest?: Digest;
  outputDigest?: Digest;
  latencyMs: DurationMs = 0;
  inputTokens: TokenCount = 0;
  outputTokens: TokenCount = 0;
  monetaryCostMicros: MoneyMicros = 0;
  errorClass?: AgentErrorClass;
  recoveryAction?: string;
  privacyRedactionVersion: string = '';
}
