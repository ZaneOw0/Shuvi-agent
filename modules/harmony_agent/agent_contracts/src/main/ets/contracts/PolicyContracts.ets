import {
  AGENT_CONTRACT_SCHEMA_VERSION,
  CONTRACT_TYPE_AUTHORIZATION_DECISION,
  CONTRACT_TYPE_AUTHORIZATION_GRANT,
  CONTRACT_TYPE_POLICY_REQUEST
} from './Constants';
import { ContractId, Digest, IsoTimestamp, MoneyMicros } from './Common';
import { AuthorizationDecisionType, RiskLevel, SideEffect } from './Enums';

export class PolicyRequest {
  schemaVersion: string = AGENT_CONTRACT_SCHEMA_VERSION;
  contractType: string = CONTRACT_TYPE_POLICY_REQUEST;
  requestId: ContractId = '';
  userId: ContractId = '';
  taskId: ContractId = '';
  stepId: ContractId = '';
  operationId: ContractId = '';
  toolId: ContractId = '';
  toolIdentityVersion: string = '';
  providerId: ContractId = '';
  schemaDigest: Digest = '';
  argumentsDigest: Digest = '';
  riskLevel: RiskLevel = RiskLevel.LOW;
  sideEffect: SideEffect = SideEffect.NONE;
  estimatedCostMicros: MoneyMicros = 0;
  requestedAt: IsoTimestamp = '';
  expiresAt: IsoTimestamp = '';
  expiresAtMs: number = 0;
}

export class AuthorizationDecision {
  schemaVersion: string = AGENT_CONTRACT_SCHEMA_VERSION;
  contractType: string = CONTRACT_TYPE_AUTHORIZATION_DECISION;
  commandId: ContractId = '';
  policyRequestId: ContractId = '';
  userId: ContractId = '';
  taskId: ContractId = '';
  decision: AuthorizationDecisionType = AuthorizationDecisionType.DENIED;
  denialReasonCode?: string;
  decidedAt: IsoTimestamp = '';
  decidedAtMs: number = 0;
}

export class AuthorizationGrant {
  schemaVersion: string = AGENT_CONTRACT_SCHEMA_VERSION;
  contractType: string = CONTRACT_TYPE_AUTHORIZATION_GRANT;
  grantId: ContractId = '';
  policyRequestId: ContractId = '';
  decisionCommandId: ContractId = '';
  userId: ContractId = '';
  taskId: ContractId = '';
  stepId: ContractId = '';
  operationId: ContractId = '';
  toolId: ContractId = '';
  toolIdentityVersion: string = '';
  schemaDigest: Digest = '';
  argumentsDigest: Digest = '';
  budgetReservationId: ContractId = '';
  policyVersion: string = '';
  issuedAt: IsoTimestamp = '';
  expiresAt: IsoTimestamp = '';
  issuedAtMs: number = 0;
  expiresAtMs: number = 0;
}
