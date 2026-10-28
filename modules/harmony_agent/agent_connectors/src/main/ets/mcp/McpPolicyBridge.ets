import { ToolInvocation } from '@harmony_agent/agent-contracts';
import {
  McpAuthorizationDecision,
  McpCapabilityKind,
  McpCapabilityRef,
  McpInvocationContext,
  McpInvocationPolicy
} from '@harmony_agent/mcp-client';
import { canonicalJson } from './CanonicalJson';
import { ConnectorDigestPort } from './McpConnectorTypes';

class InvocationTicket {
  invocationId: string = '';
  grantId: string = '';
  serverId: string = '';
  toolName: string = '';
  argumentsDigest: string = '';
  schemaDigest?: string;
  profileDigest?: string;
}

class BridgeDecision implements McpAuthorizationDecision {
  allowed: boolean = false;
  reason?: string;
}

export class McpInvocationPolicyBridge implements McpInvocationPolicy {
  private readonly digestPort: ConnectorDigestPort;
  private readonly tickets: InvocationTicket[] = [];

  constructor(digestPort: ConnectorDigestPort) {
    this.digestPort = digestPort;
  }

  arm(invocation: ToolInvocation, ref: McpCapabilityRef, argumentsValue: Object,
    profileDigest?: string): boolean {
    if (ref.kind !== McpCapabilityKind.TOOL || invocation.authorizationGrantId.trim().length === 0 ||
      invocation.argumentsDigest !== this.digestPort.digest(canonicalJson(argumentsValue))) {
      return false;
    }
    this.disarm(invocation.invocationId);
    const ticket: InvocationTicket = new InvocationTicket();
    ticket.invocationId = invocation.invocationId;
    ticket.grantId = invocation.authorizationGrantId;
    ticket.serverId = ref.serverId;
    ticket.toolName = ref.name;
    ticket.argumentsDigest = invocation.argumentsDigest;
    ticket.schemaDigest = invocation.schemaDigest;
    ticket.profileDigest = profileDigest;
    this.tickets.push(ticket);
    return true;
  }

  disarm(invocationId: string): void {
    for (let index: number = this.tickets.length - 1; index >= 0; index--) {
      if (this.tickets[index].invocationId === invocationId) this.tickets.splice(index, 1);
    }
  }

  authorize(context: McpInvocationContext): Promise<McpAuthorizationDecision> {
    const argumentsDigest: string = this.digestPort.digest(canonicalJson(context.arguments));
    const schemaDigest: string = this.digestPort.digest('mcp-schema-v1|' + canonicalJson(context.tool.inputSchema) +
      '|' + (context.tool.outputSchema === undefined ? '' : canonicalJson(context.tool.outputSchema)));
    const profileDigest: string = this.digestPort.digest(canonicalJson(context.profile as Object));
    for (let index: number = 0; index < this.tickets.length; index++) {
      const ticket: InvocationTicket = this.tickets[index];
      if (ticket.serverId === context.profile.id && ticket.toolName === context.tool.name &&
        ticket.argumentsDigest === argumentsDigest && ticket.schemaDigest === schemaDigest &&
        (ticket.profileDigest === undefined || ticket.profileDigest === profileDigest)) {
        this.tickets.splice(index, 1);
        const allowed: BridgeDecision = new BridgeDecision();
        allowed.allowed = true;
        return Promise.resolve(allowed);
      }
    }
    const denied: BridgeDecision = new BridgeDecision();
    denied.reason = 'No matching runtime-authorized invocation ticket';
    return Promise.resolve(denied);
  }
}
