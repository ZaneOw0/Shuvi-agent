import { describe, expect, it } from '@ohos/hypium';
import { McpClientError, McpErrorCode } from '../main/ets/mcp/Errors';
import { McpCancellationSource } from '../main/ets/mcp/Cancellation';
import { SseEvent, SseParser } from '../main/ets/mcp/SseParser';
import {
  McpAuthProvider,
  McpProtocolEra,
  McpProtocolMode,
  McpServerProfile
} from '../main/ets/mcp/Types';
import { JsonRpcCodec, McpJsonRpcOutcome } from '../main/ets/mcp/internal/JsonRpc';
import { McpProtocolClient, McpProtocolClientOptions } from '../main/ets/mcp/internal/ProtocolClient';
import {
  McpTransport,
  McpTransportRequest,
  McpTransportResponse,
  McpResponseBuffer
} from '../main/ets/mcp/internal/Transport';

class QueueTransport implements McpTransport {
  readonly requests: McpTransportRequest[] = [];
  private readonly responses: McpTransportResponse[];
  private readonly failureCalls: Set<number>;
  private readonly failureCode: McpErrorCode;
  closed: boolean = false;

  constructor(responses: McpTransportResponse[], failureCalls?: number[],
    failureCode: McpErrorCode = McpErrorCode.NETWORK) {
    this.responses = responses;
    this.failureCalls = new Set<number>(failureCalls === undefined ? [] : failureCalls);
    this.failureCode = failureCode;
  }

  send(request: McpTransportRequest): Promise<McpTransportResponse> {
    this.requests.push(request);
    if (this.failureCalls.has(this.requests.length)) {
      return Promise.reject(new McpClientError(this.failureCode, 'transient'));
    }
    const response: McpTransportResponse | undefined = this.responses.shift();
    if (response === undefined) {
      return Promise.reject(new Error('No queued response'));
    }
    return Promise.resolve(response);
  }

  close(): void {
    this.closed = true;
  }
}

class CancellableTransport implements McpTransport {
  readonly requests: McpTransportRequest[] = [];
  private cancelled: boolean = false;

  async send(request: McpTransportRequest): Promise<McpTransportResponse> {
    this.requests.push(request);
    if (this.requests.length === 1) {
      return response(200,
        '{"jsonrpc":"2.0","id":1,"result":{"supportedVersions":["2026-07-28"],' +
        '"capabilities":{"resources":{}},"_meta":{}}}');
    }
    while (!this.cancelled) {
      await Promise.resolve();
    }
    throw new McpClientError(McpErrorCode.CANCELLED, 'cancelled');
  }

  close(): void {
    this.cancelled = true;
  }
}

class SignalAwareTransport implements McpTransport {
  readonly requests: McpTransportRequest[] = [];
  cancelled: boolean = false;

  send(request: McpTransportRequest): Promise<McpTransportResponse> {
    this.requests.push(request);
    if (this.requests.length === 1) {
      return Promise.resolve(response(200,
        '{"jsonrpc":"2.0","id":1,"result":{"supportedVersions":["2026-07-28"],' +
        '"capabilities":{"tools":{}},"_meta":{}}}'));
    }
    if (this.requests.length === 2) {
      return Promise.resolve(response(200, '{"jsonrpc":"2.0","id":2,"result":{"tools":[' +
        '{"name":"slow","inputSchema":{"type":"object"}}]}}'));
    }
    return new Promise<McpTransportResponse>((_resolve, reject): void => {
      if (request.cancellation === undefined) {
        reject(new Error('Cancellation signal missing'));
        return;
      }
      request.cancellation.subscribe((): void => {
        this.cancelled = true;
        reject(new McpClientError(McpErrorCode.CANCELLED, 'cancelled'));
      });
    });
  }

  close(): void {
  }
}

class SecretThrowingAuthProvider implements McpAuthProvider {
  getHeaders(_profile: McpServerProfile, _operation: string): Promise<Record<string, string>> {
    return Promise.reject(new Error('Bearer fixture-secret-must-not-leak'));
  }
}

function response(statusCode: number, body: string, contentType: string = 'application/json',
  sessionId?: string): McpTransportResponse {
  const headers: Record<string, string> = {};
  headers['content-type'] = contentType;
  if (sessionId !== undefined) {
    headers['mcp-session-id'] = sessionId;
  }
  return { statusCode: statusCode, headers: headers, body: body };
}

function profile(mode: McpProtocolMode = McpProtocolMode.MODERN): McpServerProfile {
  return {
    id: 'fixture',
    endpoint: 'http://127.0.0.1:30777/mcp',
    protocolMode: mode,
    allowInsecureHttp: true
  };
}

function options(): McpProtocolClientOptions {
  return { clientName: 'harmony_agent Test', clientVersion: '0.1.0', debugBuild: true };
}

export default function protocolTest(): void {
  describe('SseParser', () => {
    it('parsesChunkedMultiLineEvents', 0, () => {
      const parser: SseParser = new SseParser();
      const first: SseEvent[] = parser.push('event: message\r\ndata: {"part":1}\r');
      const second: SseEvent[] = parser.push('\ndata: {"part":2}\r\n\r\ndata: done\n\n');
      const events: SseEvent[] = first.concat(second).concat(parser.finish());
      expect(events.length).assertEqual(2);
      expect(events[0].data).assertEqual('{"part":1}\n{"part":2}');
      expect(events[1].data).assertEqual('done');
    });

    it('ignoresCommentsAndUnknownFields', 0, () => {
      const parser: SseParser = new SseParser();
      const events: SseEvent[] = parser.push(': heartbeat\nretry: 1000\ndata: payload\n\n');
      expect(events.length).assertEqual(1);
      expect(events[0].data).assertEqual('payload');
    });
  });

  describe('JsonRpcCodec', () => {
    it('selectsMatchingResponseFromOutOfOrderSse', 0, () => {
      const body: string = 'data: {"jsonrpc":"2.0","method":"notifications/tools/list_changed"}\n\n' +
        'data: {"jsonrpc":"2.0","id":9,"result":{"wrong":true}}\n\n' +
        'data: {"jsonrpc":"2.0","id":7,"result":{"ok":true}}\n\n';
      const outcome: McpJsonRpcOutcome = JsonRpcCodec.decode(
        response(200, body, 'text/event-stream'), 7);
      expect(outcome.notifications.length).assertEqual(1);
      const result: Record<string, Object> = outcome.result as Record<string, Object>;
      expect(result['ok']).assertTrue();
    });

    it('decodesStructuredError', 0, () => {
      const outcome: McpJsonRpcOutcome = JsonRpcCodec.decode(response(400,
        '{"jsonrpc":"2.0","id":4,"error":{"code":-32601,"message":"not found"}}'), 4);
      expect(outcome.error?.code).assertEqual(-32601);
      expect(outcome.error?.message).assertEqual('not found');
    });

    it('rejectsMalformedMessage', 0, () => {
      let rejected: boolean = false;
      try {
        JsonRpcCodec.decode(response(200, '{"id":1,"result":{}}'), 1);
      } catch (error) {
        rejected = error instanceof McpClientError && error.code === McpErrorCode.PROTOCOL;
      }
      expect(rejected).assertTrue();
    });

    it('rejectsMalformedSseData', 0, () => {
      let rejected: boolean = false;
      try {
        JsonRpcCodec.decode(response(200, 'data: {not-json}\n\n', 'text/event-stream'), 1);
      } catch (error) {
        rejected = error instanceof McpClientError && error.code === McpErrorCode.PROTOCOL;
      }
      expect(rejected).assertTrue();
    });
  });

  describe('McpResponseBuffer', () => {
    it('acceptsExactLimitAndRejectsOversizedResponse', 0, () => {
      const buffer: McpResponseBuffer = new McpResponseBuffer(4);
      buffer.append(new ArrayBuffer(4));
      let code: string = '';
      try {
        buffer.append(new ArrayBuffer(1));
      } catch (error) {
        code = error instanceof McpClientError ? error.code : '';
      }
      expect(code).assertEqual(McpErrorCode.RESPONSE_TOO_LARGE);
    });
  });

  describe('McpProtocolClient', () => {
    it('rejectsNonPositiveTransportLimits', 0, () => {
      let rejected: boolean = false;
      try {
        const invalid: McpServerProfile = profile();
        invalid.maxResponseBytes = 0;
        new McpProtocolClient(invalid, options(), new QueueTransport([]));
      } catch (error) {
        rejected = error instanceof McpClientError && error.code === McpErrorCode.CONFIGURATION;
      }
      expect(rejected).assertTrue();
    });

    it('fallsBackOnlyForConfirmedLegacyServer', 0, async () => {
      const transport: QueueTransport = new QueueTransport([
        response(400, '{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"unknown"}}'),
        response(200, '{"jsonrpc":"2.0","id":2,"result":{"protocolVersion":"2025-11-25",' +
          '"capabilities":{"tools":{}},"serverInfo":{"name":"legacy","version":"1"}}}',
        'application/json', 'session-1'),
        response(202, '')
      ]);
      const client: McpProtocolClient = new McpProtocolClient(profile(McpProtocolMode.AUTO), options(), transport);
      const info = await client.connect();
      expect(info.era).assertEqual(McpProtocolEra.LEGACY);
      expect(transport.requests.length).assertEqual(3);
      expect(transport.requests[2].headers['MCP-Session-Id']).assertEqual('session-1');
    });

    it('fallsBackWhenDiscoveryAdvertisesOnlyLegacyVersion', 0, async () => {
      const transport: QueueTransport = new QueueTransport([
        response(200, '{"jsonrpc":"2.0","id":1,"result":{' +
          '"supportedVersions":["2025-11-25"],"capabilities":{},"_meta":{}}}'),
        response(200, '{"jsonrpc":"2.0","id":2,"result":{"protocolVersion":"2025-11-25",' +
          '"capabilities":{},"serverInfo":{"name":"legacy","version":"1"}}}',
        'application/json', 'session-version'),
        response(202, '')
      ]);
      const client: McpProtocolClient = new McpProtocolClient(
        profile(McpProtocolMode.AUTO), options(), transport);
      const info = await client.connect();
      expect(info.era).assertEqual(McpProtocolEra.LEGACY);
      expect(transport.requests.length).assertEqual(3);
    });

    it('doesNotFallbackOnAuthenticationFailure', 0, async () => {
      const transport: QueueTransport = new QueueTransport([response(401, '')]);
      const client: McpProtocolClient = new McpProtocolClient(profile(McpProtocolMode.AUTO), options(), transport);
      let code: string = '';
      try {
        await client.connect();
      } catch (error) {
        code = error instanceof McpClientError ? error.code : '';
      }
      expect(code).assertEqual(McpErrorCode.AUTHENTICATION);
      expect(transport.requests.length).assertEqual(1);
    });

    it('doesNotFallbackOnForbiddenServerOrMalformedFailure', 0, async () => {
      const statuses: number[] = [403, 500];
      const expected: McpErrorCode[] = [McpErrorCode.FORBIDDEN, McpErrorCode.NETWORK];
      for (let index: number = 0; index < statuses.length; index++) {
        const transport: QueueTransport = new QueueTransport([response(statuses[index], '{}')]);
        const client: McpProtocolClient = new McpProtocolClient(
          profile(McpProtocolMode.AUTO), options(), transport);
        let code: string = '';
        try {
          await client.connect();
        } catch (error) {
          code = error instanceof McpClientError ? error.code : '';
        }
        expect(code).assertEqual(expected[index]);
        expect(transport.requests.length).assertEqual(1);
      }

      const malformedTransport: QueueTransport = new QueueTransport([
        response(200, '{"jsonrpc":"2.0","id":1,"result":[]}')
      ]);
      const malformedClient: McpProtocolClient = new McpProtocolClient(
        profile(McpProtocolMode.AUTO), options(), malformedTransport);
      let malformedCode: string = '';
      try {
        await malformedClient.connect();
      } catch (error) {
        malformedCode = error instanceof McpClientError ? error.code : '';
      }
      expect(malformedCode).assertEqual(McpErrorCode.PROTOCOL);
      expect(malformedTransport.requests.length).assertEqual(1);
    });

    it('doesNotFallbackOnNetworkOrTimeoutFailure', 0, async () => {
      const networkTransport: QueueTransport = new QueueTransport([], [1]);
      const networkClient: McpProtocolClient = new McpProtocolClient(
        profile(McpProtocolMode.AUTO), options(), networkTransport);
      let networkCode: string = '';
      try {
        await networkClient.connect();
      } catch (error) {
        networkCode = error instanceof McpClientError ? error.code : '';
      }
      expect(networkCode).assertEqual(McpErrorCode.NETWORK);
      expect(networkTransport.requests.length).assertEqual(1);

      const timeoutTransport: QueueTransport = new QueueTransport([], [1], McpErrorCode.TIMEOUT);
      const timeoutClient: McpProtocolClient = new McpProtocolClient(
        profile(McpProtocolMode.AUTO), options(), timeoutTransport);
      let timeoutCode: string = '';
      try {
        await timeoutClient.connect();
      } catch (error) {
        timeoutCode = error instanceof McpClientError ? error.code : '';
      }
      expect(timeoutCode).assertEqual(McpErrorCode.TIMEOUT);
      expect(timeoutTransport.requests.length).assertEqual(1);
    });

    it('classifiesAuthProviderFailureWithoutLeakingMessage', 0, async () => {
      const transport: QueueTransport = new QueueTransport([]);
      const authOptions: McpProtocolClientOptions = options();
      authOptions.authProvider = new SecretThrowingAuthProvider();
      const client: McpProtocolClient = new McpProtocolClient(profile(), authOptions, transport);
      let code: string = '';
      let message: string = '';
      try {
        await client.connect();
      } catch (error) {
        if (error instanceof McpClientError) {
          code = error.code;
          message = error.message;
        }
      }
      expect(code).assertEqual(McpErrorCode.AUTHENTICATION);
      expect(message.indexOf('fixture-secret')).assertEqual(-1);
      expect(transport.requests.length).assertEqual(0);
    });

    it('collectsPagesAndRejectsRepeatedCursor', 0, async () => {
      const pagedTransport: QueueTransport = new QueueTransport([
        response(200, '{"jsonrpc":"2.0","id":1,"result":{"supportedVersions":["2026-07-28"],' +
          '"capabilities":{"tools":{}},"_meta":{}}}'),
        response(200, '{"jsonrpc":"2.0","id":2,"result":{"tools":[' +
          '{"name":"first","inputSchema":{"type":"object"}}],"nextCursor":"page-2"}}'),
        response(200, '{"jsonrpc":"2.0","id":3,"result":{"tools":[' +
          '{"name":"second","inputSchema":{"type":"object"}}]}}')
      ]);
      const pagedClient: McpProtocolClient = new McpProtocolClient(profile(), options(), pagedTransport);
      await pagedClient.connect();
      const tools = await pagedClient.listTools();
      expect(tools.length).assertEqual(2);
      expect(tools[0].name).assertEqual('first');
      expect(tools[1].name).assertEqual('second');

      const repeatedTransport: QueueTransport = new QueueTransport([
        response(200, '{"jsonrpc":"2.0","id":1,"result":{"supportedVersions":["2026-07-28"],' +
          '"capabilities":{"resources":{}},"_meta":{}}}'),
        response(200, '{"jsonrpc":"2.0","id":2,"result":{"resources":[],"nextCursor":"again"}}'),
        response(200, '{"jsonrpc":"2.0","id":3,"result":{"resources":[],"nextCursor":"again"}}')
      ]);
      const repeatedClient: McpProtocolClient = new McpProtocolClient(profile(), options(), repeatedTransport);
      await repeatedClient.connect();
      let repeatedCode: string = '';
      try {
        await repeatedClient.listResources();
      } catch (error) {
        repeatedCode = error instanceof McpClientError ? error.code : '';
      }
      expect(repeatedCode).assertEqual(McpErrorCode.PROTOCOL);
    });

    it('parsesResourcesTemplatesAndPrompts', 0, async () => {
      const transport: QueueTransport = new QueueTransport([
        response(200, '{"jsonrpc":"2.0","id":1,"result":{"supportedVersions":["2026-07-28"],' +
          '"capabilities":{"resources":{},"prompts":{}},"_meta":{}}}'),
        response(200, '{"jsonrpc":"2.0","id":2,"result":{"resourceTemplates":[' +
          '{"uriTemplate":"fixture://documents/{id}","name":"document",' +
          '"mimeType":"application/json"}]}}'),
        response(200, '{"jsonrpc":"2.0","id":3,"result":{"prompts":[' +
          '{"name":"summarize","description":"Summary","arguments":[' +
          '{"name":"topic","required":true}]}]}}'),
        response(200, '{"jsonrpc":"2.0","id":4,"result":{"contents":[' +
          '{"type":"resource","resource":{"uri":"fixture://welcome","text":"welcome"}}]}}'),
        response(200, '{"jsonrpc":"2.0","id":5,"result":{"description":"Fixture prompt",' +
          '"messages":[{"role":"user","content":{"type":"text","text":"Summarize MCP"}}]}}')
      ]);
      const client: McpProtocolClient = new McpProtocolClient(profile(), options(), transport);
      await client.connect();
      const templates = await client.listResourceTemplates();
      const prompts = await client.listPrompts();
      const resource = await client.readResource('fixture://welcome');
      const prompt = await client.getPrompt('summarize', JSON.parse('{"topic":"MCP"}'));
      expect(templates.length).assertEqual(1);
      expect(templates[0].uriTemplate).assertEqual('fixture://documents/{id}');
      expect(prompts.length).assertEqual(1);
      expect(prompts[0].arguments?.[0].required).assertTrue();
      const embedded: Record<string, Object> = resource.contents[0].resource as Record<string, Object>;
      expect(embedded['text']).assertEqual('welcome');
      expect(prompt.messages[0].role).assertEqual('user');
      expect(prompt.messages[0].content.text).assertEqual('Summarize MCP');
    });

    it('filtersInvalidHeaderToolsAndMirrorsValidArguments', 0, async () => {
      const transport: QueueTransport = new QueueTransport([
        response(200, '{"jsonrpc":"2.0","id":1,"result":{"supportedVersions":["2026-07-28"],' +
          '"capabilities":{"tools":{}},"_meta":{"io.modelcontextprotocol/serverInfo":' +
          '{"name":"modern","version":"1"}}}}'),
        response(200, '{"jsonrpc":"2.0","id":2,"result":{"tools":[' +
          '{"name":"route","inputSchema":{"type":"object","properties":{' +
          '"region":{"type":"string","x-mcp-header":"Region"},' +
          '"scope":{"type":"object","properties":{"tenant":{"type":"integer",' +
          '"x-mcp-header":"Tenant"}}}}}},' +
          '{"name":"invalid","inputSchema":{"type":"object","properties":{' +
          '"ratio":{"type":"number","x-mcp-header":"Ratio"}}}}]}}'),
        response(200, '{"jsonrpc":"2.0","id":3,"result":{"content":[' +
          '{"type":"text","text":"complete"},' +
          '{"type":"image","data":"aW1hZ2U=","mimeType":"image/png"},' +
          '{"type":"audio","data":"YXVkaW8=","mimeType":"audio/mpeg"},' +
          '{"type":"resource_link","uri":"fixture://linked","name":"linked"},' +
          '{"type":"resource","resource":{"uri":"fixture://embedded","text":"embedded"}},' +
          '{"type":"future-extension","fixture":true}],"structuredContent":{"ok":true}}}')
      ]);
      const client: McpProtocolClient = new McpProtocolClient(profile(), options(), transport);
      await client.connect();
      const tools = await client.listTools();
      expect(tools.length).assertEqual(1);
      const argumentsValue: Object = JSON.parse('{"region":"华北","scope":{"tenant":42}}');
      const result = await client.callTool(tools[0], argumentsValue);
      expect(result.isError).assertFalse();
      expect(transport.requests[2].headers['Mcp-Param-Region'].startsWith('=?base64?')).assertTrue();
      expect(transport.requests[2].headers['Mcp-Param-Tenant']).assertEqual('42');
      expect(transport.requests[2].headers['Mcp-Method']).assertEqual('tools/call');
      expect(transport.requests[2].headers['Mcp-Name']).assertEqual('route');
      expect(result.content.length).assertEqual(6);
      expect(result.content[0].text).assertEqual('complete');
      expect(result.content[1].mimeType).assertEqual('image/png');
      expect(result.content[2].mimeType).assertEqual('audio/mpeg');
      expect(result.content[3].uri).assertEqual('fixture://linked');
      const embedded: Record<string, Object> = result.content[4].resource as Record<string, Object>;
      expect(embedded['text']).assertEqual('embedded');
      expect(result.content[5].type).assertEqual('future-extension');
      const raw: Record<string, Object> = result.content[5].raw as Record<string, Object>;
      expect(raw['fixture']).assertTrue();
      const structured: Record<string, Object> = result.structuredContent as Record<string, Object>;
      expect(structured['ok']).assertTrue();
    });

    it('retriesSafeQueryOnceButNeverToolCall', 0, async () => {
      const transport: QueueTransport = new QueueTransport([
        response(200, '{"jsonrpc":"2.0","id":1,"result":{"supportedVersions":["2026-07-28"],' +
          '"capabilities":{"resources":{}},"_meta":{}}}'),
        response(200, '{"jsonrpc":"2.0","id":3,"result":{"resources":[]}}')
      ], [2]);
      const client: McpProtocolClient = new McpProtocolClient(profile(), options(), transport);
      await client.connect();
      const resources = await client.listResources();
      expect(resources.length).assertEqual(0);
      expect(transport.requests.length).assertEqual(3);
    });

    it('doesNotRetrySafeQueryAfterHttpResponse', 0, async () => {
      const transport: QueueTransport = new QueueTransport([
        response(200, '{"jsonrpc":"2.0","id":1,"result":{"supportedVersions":["2026-07-28"],' +
          '"capabilities":{"resources":{}},"_meta":{}}}'),
        response(503, '{}')
      ]);
      const client: McpProtocolClient = new McpProtocolClient(profile(), options(), transport);
      await client.connect();
      let code: string = '';
      try {
        await client.listResources();
      } catch (error) {
        code = error instanceof McpClientError ? error.code : '';
      }
      expect(code).assertEqual(McpErrorCode.NETWORK);
      expect(transport.requests.length).assertEqual(2);
    });

    it('doesNotRetryToolCalls', 0, async () => {
      const transport: QueueTransport = new QueueTransport([
        response(200, '{"jsonrpc":"2.0","id":1,"result":{"supportedVersions":["2026-07-28"],' +
          '"capabilities":{"tools":{}},"_meta":{}}}'),
        response(200, '{"jsonrpc":"2.0","id":2,"result":{"tools":[' +
          '{"name":"write","inputSchema":{"type":"object","properties":{}}}]}}')
      ], [3]);
      const client: McpProtocolClient = new McpProtocolClient(profile(), options(), transport);
      await client.connect();
      const tools = await client.listTools();
      let code: string = '';
      try {
        await client.callTool(tools[0], JSON.parse('{}'));
      } catch (error) {
        code = error instanceof McpClientError ? error.code : '';
      }
      expect(code).assertEqual(McpErrorCode.NETWORK);
      expect(transport.requests.length).assertEqual(3);
    });

    it('reinitializesOneReadOnlyToolCallAfterConfiguredSessionExpiry', 0, async () => {
      const transport: QueueTransport = new QueueTransport([
        response(200, '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25",' +
          '"capabilities":{"tools":{}},"serverInfo":{"name":"search","version":"1"}}}',
        'application/json', 'session-old'),
        response(202, ''),
        response(200, '{"jsonrpc":"2.0","id":2,"result":{"tools":[' +
          '{"name":"web_search","inputSchema":{"type":"object"}}]}}'),
        response(404, '{"error":"Session expired"}'),
        response(200, '{"jsonrpc":"2.0","id":4,"result":{"protocolVersion":"2025-11-25",' +
          '"capabilities":{"tools":{}},"serverInfo":{"name":"search","version":"1"}}}',
        'application/json', 'session-new'),
        response(202, ''),
        response(200, '{"jsonrpc":"2.0","id":5,"result":{"content":[],' +
          '"structuredContent":{"ok":true}}}')
      ]);
      const legacy: McpServerProfile = profile(McpProtocolMode.LEGACY);
      legacy.retryToolCallOnExpiredSession = true;
      const client: McpProtocolClient = new McpProtocolClient(legacy, options(), transport);
      await client.connect();
      const tools = await client.listTools();
      const result = await client.callTool(tools[0], JSON.parse('{"query":"ArkUI"}'));
      expect(result.isError).assertFalse();
      expect(transport.requests.length).assertEqual(7);
      expect(transport.requests[6].headers['MCP-Session-Id']).assertEqual('session-new');
    });

    it('cancelsOnlyTheSelectedToolRequestThroughItsSignal', 0, async () => {
      const transport: SignalAwareTransport = new SignalAwareTransport();
      const client: McpProtocolClient = new McpProtocolClient(profile(), options(), transport);
      await client.connect();
      const tools = await client.listTools();
      const cancellation: McpCancellationSource = new McpCancellationSource();
      const pending = client.callTool(tools[0], JSON.parse('{}'), cancellation);
      cancellation.cancel();
      let code: string = '';
      try {
        await pending;
      } catch (error) {
        code = error instanceof McpClientError ? error.code : '';
      }
      expect(code).assertEqual(McpErrorCode.CANCELLED);
      expect(transport.cancelled).assertTrue();
      expect(transport.requests.length).assertEqual(3);
    });

    it('cancelsPendingRequestWhenClosed', 0, async () => {
      const transport: CancellableTransport = new CancellableTransport();
      const client: McpProtocolClient = new McpProtocolClient(profile(), options(), transport);
      await client.connect();
      const pending: Promise<Object> = client.listResources();
      await client.close();
      let code: string = '';
      try {
        await pending;
      } catch (error) {
        code = error instanceof McpClientError ? error.code : '';
      }
      expect(code).assertEqual(McpErrorCode.CANCELLED);
      expect(transport.requests.length).assertEqual(2);
    });
  });
}
