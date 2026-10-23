import {
  AGENT_CONTRACT_SCHEMA_VERSION,
  CONTRACT_TYPE_ROUTER_DECISION,
  CONTRACT_TYPE_ROUTER_REQUEST
} from './Constants';
import { ContractId, DurationMs, IsoTimestamp, JsonText, MoneyMicros } from './Common';
import { ExecutionBudget } from './TaskContracts';
import { RouterKind } from './Enums';

export class RouterCandidate {
  candidateId: ContractId = '';
  metadataJson: JsonText = '{}';
}

export class RouterScore {
  candidateId: ContractId = '';
  score: number = 0;
}

export class RouterRequest {
  schemaVersion: string = AGENT_CONTRACT_SCHEMA_VERSION;
  contractType: string = CONTRACT_TYPE_ROUTER_REQUEST;
  requestId: ContractId = '';
  taskId: ContractId = '';
  stepId?: ContractId;
  routerKind: RouterKind = RouterKind.MODEL;
  candidates: RouterCandidate[] = [];
  featuresJson: JsonText = '{}';
  remainingBudget: ExecutionBudget = new ExecutionBudget();
  createdAt: IsoTimestamp = '';
}

export class RouterDecision {
  schemaVersion: string = AGENT_CONTRACT_SCHEMA_VERSION;
  contractType: string = CONTRACT_TYPE_ROUTER_DECISION;
  decisionId: ContractId = '';
  requestId: ContractId = '';
  routerKind: RouterKind = RouterKind.MODEL;
  policyVersion: string = '';
  artifactDigest: string = '';
  inputFeatureDigest: string = '';
  eligibleCandidateIds: ContractId[] = [];
  selectedCandidateIds: ContractId[] = [];
  scores: RouterScore[] = [];
  confidence: number = 0;
  fallbackUsed: boolean = false;
  fallbackReason?: string;
  latencyMs: DurationMs = 0;
  estimatedCostMicros: MoneyMicros = 0;
  createdAt: IsoTimestamp = '';
}
