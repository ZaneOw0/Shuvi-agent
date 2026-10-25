import { DEBUG } from 'BuildProfile';
import {
  McpClientManager, McpClientError, McpErrorCode, McpProtocolMode,
  McpConnectionState, McpCapabilityKind, McpManagerOptions, McpServerProfile
} from '@harmony_agent/mcp-client';
import { McpProbeFactory, McpProbeSession, McpProbeTransport } from './McpProbeSession';
import { validSearchProbeSchema } from './McpProbeContract';

const SERVER_ID: string = 'shuvi-web-search';

function publicFailure(error: Error): Error {
  if (error instanceof McpClientError) {
    if (error.code === McpErrorCode.NETWORK || error.code === McpErrorCode.TIMEOUT) {
      return new Error(`无法连接搜索服务（${error.code}），请检查电脑服务和 HDC 转发。`);
    }
    return new Error(`连接检查失败（${error.code}），请核对服务版本与工具契约。`);
  }
  return new Error('连接检查失败（INTERNAL），请核对服务配置。');
}

class DeviceMcpProbe implements McpProbeTransport {
  private readonly manager: McpClientManager;
  private registered: boolean = false;

  constructor() {
    if (!DEBUG) throw new Error('正式版本不允许本机 HTTP 连接检查。');
    const options: McpManagerOptions = {
      debugBuild: DEBUG, clientName: 'shuvi-connection-check', clientVersion: '1.0.0'
    };
    this.manager = new McpClientManager(options);
  }

  async connect(): Promise<string> {
    const profile: McpServerProfile = {
      id: SERVER_ID, endpoint: 'http://127.0.0.1:8787/mcp', protocolMode: McpProtocolMode.LEGACY,
      allowInsecureHttp: DEBUG, connectTimeoutMs: 5000, requestTimeoutMs: 5000,
      maxResponseBytes: 524288, retryToolCallOnExpiredSession: false
    };
    try {
      this.manager.registerServer(profile);
      this.registered = true;
      const snapshot = await this.manager.connect(SERVER_ID);
      if (snapshot.state !== McpConnectionState.READY || snapshot.protocolVersion === undefined) {
        throw new McpClientError(McpErrorCode.NEGOTIATION, 'Invalid connection state');
      }
      return snapshot.protocolVersion;
    } catch (error) {
      throw publicFailure(error);
    }
  }

  async discover(): Promise<void> {
    try {
      const catalog = await this.manager.listTools();
      if (catalog.errors.length !== 0 || catalog.items.length !== 1) {
        throw new McpClientError(McpErrorCode.SCHEMA_MISMATCH, 'Invalid catalog');
      }
      const tool = catalog.items[0];
      if (tool.name !== 'web_search' || tool.ref.name !== tool.name ||
        tool.ref.serverId !== SERVER_ID || tool.ref.kind !== McpCapabilityKind.TOOL ||
        tool.outputSchema === undefined || tool.outputSchema === null ||
        typeof tool.outputSchema !== 'object' || Array.isArray(tool.outputSchema) ||
        !validSearchProbeSchema(JSON.stringify(tool.inputSchema))) {
        throw new McpClientError(McpErrorCode.SCHEMA_MISMATCH, 'Invalid search tool');
      }
    } catch (error) {
      throw publicFailure(error);
    }
  }

  async interrupt(): Promise<void> {
    if (this.registered) await this.manager.disconnect(SERVER_ID);
  }

  async close(): Promise<void> {
    if (this.registered) {
      await this.manager.unregisterServer(SERVER_ID);
      this.registered = false;
    }
  }
}

class DeviceMcpProbeFactory implements McpProbeFactory {
  create(): McpProbeTransport {
    return new DeviceMcpProbe();
  }
}

// One Ability-owned check; the UI receives status only, not the MCP manager.
export class McpConnectionCheckService {
  static readonly session: McpProbeSession = new McpProbeSession(new DeviceMcpProbeFactory(), DEBUG);
}
