import { MCP_JSONRPC_VERSION } from '../Constants';
import { McpClientError, McpErrorCode } from '../Errors';
import { SseEvent, SseParser } from '../SseParser';
import { McpTransportResponse } from './Transport';

export interface McpJsonRpcErrorData {
  code: number;
  message: string;
  data?: Object;
}

export interface McpJsonRpcOutcome {
  result?: Object;
  error?: McpJsonRpcErrorData;
  notifications: Object[];
}

export class JsonRpcCodec {
  static request(id: number, method: string, params: Object): string {
    return JSON.stringify({
      jsonrpc: MCP_JSONRPC_VERSION,
      id: id,
      method: method,
      params: params
    });
  }

  static notification(method: string, params: Object): string {
    return JSON.stringify({
      jsonrpc: MCP_JSONRPC_VERSION,
      method: method,
      params: params
    });
  }

  static decode(response: McpTransportResponse, requestId: number): McpJsonRpcOutcome {
    if (response.body.trim().length === 0) {
      return { notifications: [] };
    }
    const contentType: string = response.headers['content-type'] === undefined ? '' : response.headers['content-type'];
    const messages: Object[] = contentType.toLowerCase().indexOf('text/event-stream') >= 0 ?
      JsonRpcCodec.decodeSse(response.body) : [JsonRpcCodec.parseObject(response.body)];
    const notifications: Object[] = [];
    let result: Object | undefined = undefined;
    let rpcError: McpJsonRpcErrorData | undefined = undefined;
    for (let index: number = 0; index < messages.length; index++) {
      const message: Record<string, Object> = messages[index] as Record<string, Object>;
      if (message['jsonrpc'] !== MCP_JSONRPC_VERSION) {
        throw new McpClientError(McpErrorCode.PROTOCOL, 'JSON-RPC response must use version 2.0');
      }
      if (message['id'] === undefined) {
        if (typeof message['method'] !== 'string') {
          throw new McpClientError(McpErrorCode.PROTOCOL,
            'JSON-RPC notification must contain a method');
        }
        notifications.push(messages[index]);
        continue;
      }
      if (String(message['id']) !== String(requestId)) {
        continue;
      }
      if (message['error'] !== undefined) {
        const error: Record<string, Object> = message['error'] as Record<string, Object>;
        if (typeof error['code'] !== 'number' || !Number.isInteger(error['code']) ||
          typeof error['message'] !== 'string') {
          throw new McpClientError(McpErrorCode.PROTOCOL, 'Malformed JSON-RPC error object');
        }
        rpcError = {
          code: Number(error['code']),
          message: String(error['message']),
          data: error['data']
        };
      } else if (message['result'] !== undefined) {
        result = message['result'];
      } else {
        throw new McpClientError(McpErrorCode.PROTOCOL,
          'JSON-RPC response must contain result or error');
      }
    }
    return { result: result, error: rpcError, notifications: notifications };
  }

  private static decodeSse(body: string): Object[] {
    const parser: SseParser = new SseParser();
    const events: SseEvent[] = parser.push(body).concat(parser.finish());
    const messages: Object[] = [];
    for (let index: number = 0; index < events.length; index++) {
      if (events[index].data.trim().length > 0) {
        messages.push(JsonRpcCodec.parseObject(events[index].data));
      }
    }
    return messages;
  }

  private static parseObject(value: string): Object {
    try {
      const parsed: Object = JSON.parse(value);
      if (parsed === null || Array.isArray(parsed)) {
        throw new McpClientError(McpErrorCode.PROTOCOL, 'Expected one JSON-RPC object');
      }
      return parsed;
    } catch (error) {
      if (error instanceof McpClientError) {
        throw error;
      }
      throw new McpClientError(McpErrorCode.PROTOCOL,
        `Invalid JSON-RPC response: ${String(error)}`);
    }
  }
}
