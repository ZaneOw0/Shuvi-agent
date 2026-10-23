import http from '@ohos.net.http';
import util from '@ohos.util';
import { McpClientError, McpErrorCode } from '../Errors';
import { McpCancellationSignal, McpCancellationSubscription } from '../Types';

export enum McpHttpMethod {
  POST = 'POST',
  DELETE = 'DELETE'
}

export interface McpTransportRequest {
  endpoint: string;
  method: McpHttpMethod;
  headers: Record<string, string>;
  body?: string;
  connectTimeoutMs: number;
  requestTimeoutMs: number;
  maxResponseBytes: number;
  cancellation?: McpCancellationSignal;
}

export interface McpTransportResponse {
  statusCode: number;
  headers: Record<string, string>;
  body: string;
}

export interface McpTransport {
  send(request: McpTransportRequest): Promise<McpTransportResponse>;
  close(): void;
}

class ActiveHttpRequest {
  readonly request: http.HttpRequest;
  readonly cancel: () => void;
  cancellation?: McpCancellationSubscription;

  constructor(request: http.HttpRequest, cancel: () => void) {
    this.request = request;
    this.cancel = cancel;
  }
}

export class McpResponseBuffer {
  private readonly maxResponseBytes: number;
  private readonly chunks: ArrayBuffer[] = [];
  private receivedBytes: number = 0;

  constructor(maxResponseBytes: number) {
    this.maxResponseBytes = maxResponseBytes;
  }

  append(data: ArrayBuffer): void {
    if (this.receivedBytes + data.byteLength > this.maxResponseBytes) {
      throw new McpClientError(McpErrorCode.RESPONSE_TOO_LARGE,
        `MCP response exceeded ${this.maxResponseBytes} bytes`);
    }
    this.receivedBytes += data.byteLength;
    this.chunks.push(data);
  }

  decode(): string {
    const bytes: Uint8Array = new Uint8Array(this.receivedBytes);
    let offset: number = 0;
    for (let index: number = 0; index < this.chunks.length; index++) {
      const part: Uint8Array = new Uint8Array(this.chunks[index]);
      bytes.set(part, offset);
      offset += part.byteLength;
    }
    const decoder: util.TextDecoder = new util.TextDecoder('utf-8', { fatal: true, ignoreBOM: true });
    try {
      return decoder.decodeToString(bytes);
    } catch (error) {
      throw new McpClientError(McpErrorCode.PROTOCOL,
        `Response is not valid UTF-8: ${String(error)}`);
    }
  }
}

export class ArkTsHttpTransport implements McpTransport {
  private activeRequests: ActiveHttpRequest[] = [];

  send(request: McpTransportRequest): Promise<McpTransportResponse> {
    return new Promise<McpTransportResponse>((resolve, reject) => {
      const httpRequest: http.HttpRequest = http.createHttp();
      const responseBuffer: McpResponseBuffer = new McpResponseBuffer(request.maxResponseBytes);
      let statusCode: number = 0;
      let streamEnded: boolean = false;
      let settled: boolean = false;
      let responseHeaders: Record<string, string> = {};
      let cancellation: McpCancellationSubscription | undefined = undefined;

      if (request.cancellation !== undefined && request.cancellation.isCancellationRequested()) {
        httpRequest.destroy();
        reject(new McpClientError(McpErrorCode.CANCELLED, 'MCP request was cancelled'));
        return;
      }

      const removeActive = (): void => {
        for (let index: number = 0; index < this.activeRequests.length; index++) {
          if (this.activeRequests[index].request === httpRequest) {
            this.activeRequests.splice(index, 1);
            return;
          }
        }
      };

      const fail = (error: McpClientError): void => {
        if (settled) {
          return;
        }
        settled = true;
        removeActive();
        if (cancellation !== undefined) cancellation.dispose();
        httpRequest.destroy();
        reject(error);
      };

      const cancel = (): void => {
        fail(new McpClientError(McpErrorCode.CANCELLED, 'MCP request was cancelled'));
      };
      const active: ActiveHttpRequest = new ActiveHttpRequest(httpRequest, cancel);
      this.activeRequests.push(active);

      const complete = (): void => {
        if (settled || !streamEnded || statusCode === 0) {
          return;
        }
        settled = true;
        removeActive();
        if (cancellation !== undefined) cancellation.dispose();
        let body: string = '';
        try {
          body = responseBuffer.decode();
        } catch (error) {
          httpRequest.destroy();
          reject(error);
          return;
        }
        httpRequest.destroy();
        resolve({
          statusCode: statusCode,
          headers: responseHeaders,
          body: body
        });
      };

      httpRequest.on('headersReceive', (headers: Object): void => {
        responseHeaders = this.normalizeHeaders(headers);
      });
      httpRequest.on('dataReceive', (data: ArrayBuffer): void => {
        if (settled) {
          return;
        }
        try {
          responseBuffer.append(data);
        } catch (error) {
          if (error instanceof McpClientError) {
            fail(error);
          } else {
            fail(new McpClientError(McpErrorCode.PROTOCOL,
              `Unable to buffer MCP response: ${String(error)}`));
          }
        }
      });
      httpRequest.on('dataEnd', (): void => {
        streamEnded = true;
        complete();
      });

      const options: http.HttpRequestOptions = {
        method: request.method === McpHttpMethod.POST ? http.RequestMethod.POST : http.RequestMethod.DELETE,
        header: request.headers,
        body: request.body,
        connectTimeout: request.connectTimeoutMs,
        readTimeout: request.requestTimeoutMs,
        usingCache: false,
        expectDataType: http.HttpDataType.ARRAY_BUFFER
      };

      if (request.cancellation !== undefined) {
        cancellation = request.cancellation.subscribe(cancel);
        active.cancellation = cancellation;
        if (settled) return;
      }

      httpRequest.requestInStream(request.endpoint, options).then((code: number): void => {
        statusCode = code;
        complete();
      }).catch((error: Error): void => {
        const message: string = error.message === undefined ? String(error) : error.message;
        const timeout: boolean = message.indexOf('2300028') >= 0 || message.toLowerCase().indexOf('timeout') >= 0;
        fail(new McpClientError(timeout ? McpErrorCode.TIMEOUT : McpErrorCode.NETWORK,
          `HTTP request failed: ${message}`));
      });
    });
  }

  close(): void {
    const requests: ActiveHttpRequest[] = this.activeRequests.slice();
    this.activeRequests = [];
    for (let index: number = 0; index < requests.length; index++) {
      requests[index].cancel();
    }
  }

  private normalizeHeaders(headers: Object): Record<string, string> {
    const result: Record<string, string> = {};
    const source: Record<string, Object> = headers as Record<string, Object>;
    const keys: string[] = Object.keys(source);
    for (let index: number = 0; index < keys.length; index++) {
      const key: string = keys[index];
      result[key.toLowerCase()] = String(source[key]);
    }
    return result;
  }
}

