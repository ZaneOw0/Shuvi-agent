import { SingleAgentHostResourcePort } from '@harmony_agent/agent-runtime';
import { McpClientManager } from '@harmony_agent/mcp-client';
import { McpProviderRegistry } from './McpProviderRegistry';
import { McpReadOnlyToolPolicyRegistry } from './McpToolPolicyRegistry';
import {
  SHUVI_WEB_SEARCH_SERVER_ID,
  ShuviWebSearchMcpConfig,
  connectShuviWebSearchMcp
} from './ShuviWebSearch';

/** Owns search discovery/registration for the Ability host resource stack. */
export class ShuviWebSearchMcpHostResource implements SingleAgentHostResourcePort {
  private readonly manager: McpClientManager;
  private readonly providers: McpProviderRegistry;
  private readonly policies: McpReadOnlyToolPolicyRegistry;
  private readonly config: ShuviWebSearchMcpConfig;
  private opened: boolean = false;

  constructor(manager: McpClientManager, providers: McpProviderRegistry,
    policies: McpReadOnlyToolPolicyRegistry, config: ShuviWebSearchMcpConfig) {
    this.manager = manager;
    this.providers = providers;
    this.policies = policies;
    this.config = config;
  }

  async open(): Promise<void> {
    if (this.opened) return;
    await connectShuviWebSearchMcp(this.manager, this.providers, this.policies, this.config);
    this.opened = true;
  }

  async close(): Promise<void> {
    if (!this.opened) return;
    try {
      await this.manager.unregisterServer(SHUVI_WEB_SEARCH_SERVER_ID);
    } finally {
      this.opened = false;
    }
  }
}
