import { describe, expect, it } from '@ohos/hypium';
import { McpClientError, McpErrorCode } from '../main/ets/mcp/Errors';
import { McpClientManager } from '../main/ets/mcp/McpClientManager';
import {
  McpCapabilityKind,
  McpInvocationContext,
  McpInvocationPolicy,
  McpManagerOptions,
  McpProtocolMode,
  McpServerProfile
} from '../main/ets/mcp/Types';
import {
  McpProtocolClient,
  McpProtocolClientOptions
} from '../main/ets/mcp/internal/ProtocolClient';
import {
  McpTransport,
  McpTransportRequest,
  McpTransportResponse
} from '../main/ets/mcp/internal/Transport';

class ManagerQueueTransport implements McpTransport {
  readonly requests: McpTransportRequest[] = [];
  private readonly responses: McpTransportResponse[];

  constructor(responses: McpTransportResponse[]) {
    this.responses = responses;
  }

  send(request: McpTransportRequest): Promise<McpTransportResponse> {
    this.requests.push(request);
    const next: McpTransportResponse | undefined = this.responses.shift();
    if (next === undefined) {
      return Promise.reject(new Error('No queued manager response'));
    }
    return Promise.resolve(next);
  }

  close(): void {
  }
}

class InjectedManager extends McpClientManager {
  private readonly transports: Map<string, McpTransport>;

  constructor(options: McpManagerOptions, transports: Map<string, McpTransport>) {
    super(options);
    this.transports = transports;
  }

  protected createProtocolClient(profile: McpServerProfile,
    protocolOptions: McpProtocolClientOptions): McpProtocolClient {
    const transport: McpTransport | undefined = this.transports.get(profile.id);
    if (transport === undefined) {
      throw new Error(`Missing transport for ${profile.id}`);
    }
    return new McpProtocolClient(profile, protocolOptions, transport);
  }
}

class ThrowingPolicy implements McpInvocationPolicy {
  authorize(_context: McpInvocationContext): Promise<never> {
    return Promise.reject(new Error('policy unavailable'));
  }
}

function rpcResponse(statusCode: number, body: string): McpTransportResponse {
  const headers: Record<string, string> = {};
  headers['content-type'] = 'application/json';
  return { statusCode: statusCode, headers: headers, body: body };
}

function discover(id: number): McpTransportResponse {
  return rpcResponse(200, `{"jsonrpc":"2.0","id":${id},"result":{` +
    '"supportedVersions":["2026-07-28"],"capabilities":{"tools":{}},"_meta":{}}}');
}

function tools(id: number, name: string): McpTransportResponse {
  return rpcResponse(200, `{"jsonrpc":"2.0","id":${id},"result":{"tools":[` +
    `{"name":"${name}","inputSchema":{"type":"object"}}]}}`);
}

function emptyTools(id: number): McpTransportResponse {
  return rpcResponse(200, `{"jsonrpc":"2.0","id":${id},"result":{"tools":[]}}`);
}

function serverProfile(id: string): McpServerProfile {
  return {
    id: id,
    endpoint: `http://127.0.0.1/${id}`,
    protocolMode: McpProtocolMode.MODERN,
    allowInsecureHttp: true
  };
}

export default function managerTest(): void {
  describe('McpClientManager', () => {
    it('keepsSameNameToolsDistinctAndIsolatesFailedServer', 0, async () => {
      const first: ManagerQueueTransport = new ManagerQueueTransport([discover(1), tools(2, 'same-name')]);
      const second: ManagerQueueTransport = new ManagerQueueTransport([discover(1), tools(2, 'same-name')]);
      const broken: ManagerQueueTransport = new ManagerQueueTransport([rpcResponse(500, '{}')]);
      const transports: Map<string, McpTransport> = new Map<string, McpTransport>();
      transports.set('first', first);
      transports.set('second', second);
      transports.set('broken', broken);
      const manager: InjectedManager = new InjectedManager({ debugBuild: true }, transports);
      manager.registerServer(serverProfile('first'));
      manager.registerServer(serverProfile('second'));
      manager.registerServer(serverProfile('broken'));

      const connections = await manager.connectAll();
      expect(connections.items.length).assertEqual(2);
      expect(connections.errors.length).assertEqual(1);
      expect(connections.errors[0].serverId).assertEqual('broken');

      const catalog = await manager.listTools();
      expect(catalog.items.length).assertEqual(2);
      expect(catalog.errors.length).assertEqual(1);
      expect(catalog.items[0].name).assertEqual('same-name');
      expect(catalog.items[1].name).assertEqual('same-name');
      expect(catalog.items[0].ref.serverId === catalog.items[1].ref.serverId).assertFalse();
      await manager.disconnectAll();
    });

    it('cachesCatalogAndDeniesBeforeSendingWithoutPolicy', 0, async () => {
      const transport: ManagerQueueTransport = new ManagerQueueTransport([
        discover(1), tools(2, 'guarded'), tools(3, 'guarded')
      ]);
      const transports: Map<string, McpTransport> = new Map<string, McpTransport>();
      transports.set('guarded', transport);
      const manager: InjectedManager = new InjectedManager({ debugBuild: true }, transports);
      manager.registerServer(serverProfile('guarded'));
      await manager.connect('guarded');
      await manager.listTools();
      await manager.listTools();
      expect(transport.requests.length).assertEqual(2);

      let code: string = '';
      try {
        await manager.callTool({
          serverId: 'guarded', kind: McpCapabilityKind.TOOL, name: 'guarded'
        }, JSON.parse('{}'));
      } catch (error) {
        code = error instanceof McpClientError ? error.code : '';
      }
      expect(code).assertEqual(McpErrorCode.POLICY_DENIED);
      expect(transport.requests.length).assertEqual(2);

      await manager.refreshServer('guarded');
      expect(transport.requests.length).assertEqual(3);
      await manager.disconnectAll();
    });

    it('cachesEmptyCatalogUntilExplicitRefresh', 0, async () => {
      const transport: ManagerQueueTransport = new ManagerQueueTransport([
        discover(1), emptyTools(2), emptyTools(3)
      ]);
      const transports: Map<string, McpTransport> = new Map<string, McpTransport>();
      transports.set('empty', transport);
      const manager: InjectedManager = new InjectedManager({ debugBuild: true }, transports);
      manager.registerServer(serverProfile('empty'));
      await manager.connect('empty');
      const first = await manager.listTools();
      const second = await manager.listTools();
      expect(first.items.length).assertEqual(0);
      expect(second.items.length).assertEqual(0);
      expect(transport.requests.length).assertEqual(2);
      await manager.refreshServer('empty');
      expect(transport.requests.length).assertEqual(3);
      await manager.disconnectAll();
    });

    it('failsClosedWhenPolicyThrowsWithoutSendingToolCall', 0, async () => {
      const transport: ManagerQueueTransport = new ManagerQueueTransport([
        discover(1), tools(2, 'guarded')
      ]);
      const transports: Map<string, McpTransport> = new Map<string, McpTransport>();
      transports.set('throwing-policy', transport);
      const manager: InjectedManager = new InjectedManager({
        debugBuild: true,
        invocationPolicy: new ThrowingPolicy()
      }, transports);
      manager.registerServer(serverProfile('throwing-policy'));
      await manager.connect('throwing-policy');
      await manager.listTools();

      let code: string = '';
      try {
        await manager.callTool({
          serverId: 'throwing-policy', kind: McpCapabilityKind.TOOL, name: 'guarded'
        }, JSON.parse('{}'));
      } catch (error) {
        code = error instanceof McpClientError ? error.code : '';
      }
      expect(code).assertEqual(McpErrorCode.POLICY_DENIED);
      expect(transport.requests.length).assertEqual(2);
      await manager.disconnectAll();
    });
  });
}
