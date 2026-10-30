import http from '@ohos.net.http';
import util from '@ohos.util';
import { BusinessError } from '@kit.BasicServicesKit';

/** The only origin the phone sends a Tavily key to. Never configurable from tool arguments. */
export const TAVILY_SEARCH_ENDPOINT: string = 'https://api.tavily.com/search';

export class TavilyHttpRequest {
  authorization: string = '';
  body: string = '';
  timeoutMs: number = 15000;
  connectTimeoutMs: number = 10000;
  maxResponseBytes: number = 1048576;
}
export class TavilyHttpResponse {
  statusCode: number = 0;
  /** Decoded only for 2xx responses; error bodies are never read or forwarded. */
  body: string = '';
}
/** Transport-level failures; the codes match the search tool's public failure codes. */
export class TavilyTransportError extends Error {
  readonly code: string;
  constructor(code: string) { super('TAVILY_' + code); this.code = code; }
}
export interface TavilyHttpOperation {
  readonly result: Promise<TavilyHttpResponse>;
  cancel(): void;
}
export interface TavilyHttpClientPort {
  start(request: TavilyHttpRequest): TavilyHttpOperation;
}

interface TavilyHeaders {
  Authorization: string;
  'Content-Type': string;
  Accept: string;
}

class NativeTavilyOperation implements TavilyHttpOperation {
  readonly result: Promise<TavilyHttpResponse>;
  private readonly stop: () => void;
  constructor(result: Promise<TavilyHttpResponse>, stop: () => void) { this.result = result; this.stop = stop; }
  cancel(): void { this.stop(); }
}

/** HTTPS POST to the fixed Tavily origin: no redirects, no cache, bounded time and size, cancellable. */
export class ArkTsTavilyHttpClient implements TavilyHttpClientPort {
  start(request: TavilyHttpRequest): TavilyHttpOperation {
    if (!Number.isSafeInteger(request.timeoutMs) || request.timeoutMs <= 0 || request.timeoutMs > 60000 ||
      !Number.isSafeInteger(request.connectTimeoutMs) || request.connectTimeoutMs <= 0 ||
      request.connectTimeoutMs > request.timeoutMs || !Number.isSafeInteger(request.maxResponseBytes) ||
      request.maxResponseBytes <= 0 || request.maxResponseBytes > 4194304 ||
      !/^Bearer [\x21-\x7e]+$/.test(request.authorization)) {
      throw new TavilyTransportError('CONFIGURATION');
    }
    const nativeRequest: http.HttpRequest = http.createHttp();
    let cancel: () => void = (): void => {};
    const result: Promise<TavilyHttpResponse> = new Promise<TavilyHttpResponse>((resolve, reject) => {
      let settled: boolean = false;
      let ended: boolean = false;
      let status: number = 0;
      let size: number = 0;
      let timer: number = -1;
      const chunks: Uint8Array[] = [];
      const cleanup = (): void => {
        if (timer >= 0) clearTimeout(timer);
        chunks.length = 0;
        try { nativeRequest.destroy(); } catch (error) { /* Preserve the original result. */ }
      };
      const fail = (code: string): void => {
        if (settled) return;
        settled = true;
        cleanup();
        reject(new TavilyTransportError(code));
      };
      cancel = (): void => fail('CANCELLED');
      const complete = (): void => {
        if (settled || !ended || status === 0) return;
        try {
          const response: TavilyHttpResponse = new TavilyHttpResponse();
          response.statusCode = status;
          if (status >= 200 && status < 300) {
            const bytes: Uint8Array = new Uint8Array(size);
            let offset: number = 0;
            for (const chunk of chunks) {
              bytes.set(chunk, offset);
              offset += chunk.length;
            }
            response.body = new util.TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decodeToString(bytes);
          }
          settled = true;
          cleanup();
          resolve(response);
        } catch (error) {
          fail('INVALID_RESPONSE');
        }
      };
      timer = setTimeout((): void => fail('TIMEOUT'), request.timeoutMs);
      try {
        nativeRequest.on('dataReceive', (data: ArrayBuffer): void => {
          if (settled) return;
          if (size + data.byteLength > request.maxResponseBytes) {
            fail('RESPONSE_TOO_LARGE');
            return;
          }
          size += data.byteLength;
          const copy: Uint8Array = new Uint8Array(data.byteLength);
          copy.set(new Uint8Array(data));
          chunks.push(copy);
        });
        nativeRequest.on('dataEnd', (): void => { ended = true; complete(); });
        const headers: TavilyHeaders = {
          Authorization: request.authorization, 'Content-Type': 'application/json', Accept: 'application/json'
        };
        // Keep the credential on the fixed HTTPS origin: never follow redirects.
        const options: http.HttpRequestOptions = {
          method: http.RequestMethod.POST, header: headers, extraData: request.body,
          connectTimeout: request.connectTimeoutMs, readTimeout: request.timeoutMs,
          usingCache: false, maxRedirects: 0, expectDataType: http.HttpDataType.ARRAY_BUFFER
        };
        nativeRequest.requestInStream(TAVILY_SEARCH_ENDPOINT, options).then((code: number): void => {
          if (settled) return;
          status = code;
          complete();
        }).catch((error: BusinessError): void => {
          fail(error.code === 2300028 ? 'TIMEOUT' : 'NETWORK');
        });
      } catch (error) {
        fail('NETWORK');
      }
    });
    return new NativeTavilyOperation(result, (): void => cancel());
  }
}
