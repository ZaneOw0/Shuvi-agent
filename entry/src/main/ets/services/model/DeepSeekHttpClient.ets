import http from '@ohos.net.http';
import util from '@ohos.util';
import { BusinessError } from '@kit.BasicServicesKit';
import { AgentErrorClass } from '@harmony_agent/agent-contracts';
import { ProviderErrorCode, ProviderOperationHandle, ProviderTransportError } from '@harmony_agent/agent-connectors';
import {
  DEEPSEEK_CHAT_ENDPOINT, DeepSeekHttpClientPort, DeepSeekHttpRequest, DeepSeekHttpResponse
} from './DeepSeekProtocol';

interface DeepSeekHeaders {
  Authorization: string;
  'Content-Type': string;
  Accept: string;
}

class HttpOperation implements ProviderOperationHandle<DeepSeekHttpResponse> {
  readonly result: Promise<DeepSeekHttpResponse>;
  private readonly stop: () => void;
  constructor(result: Promise<DeepSeekHttpResponse>, stop: () => void) {
    this.result = result;
    this.stop = stop;
  }
  cancel(): void { this.stop(); }
}

export class ArkTsDeepSeekHttpClient implements DeepSeekHttpClientPort {
  start(request: DeepSeekHttpRequest): ProviderOperationHandle<DeepSeekHttpResponse> {
    if (!Number.isSafeInteger(request.timeoutMs) || request.timeoutMs <= 0 || request.timeoutMs > 180000 ||
      !Number.isSafeInteger(request.connectTimeoutMs) || request.connectTimeoutMs <= 0 ||
      request.connectTimeoutMs > request.timeoutMs || !Number.isSafeInteger(request.maxResponseBytes) ||
      request.maxResponseBytes <= 0 || request.maxResponseBytes > 8388608 ||
      !/^Bearer [\x21-\x7e]+$/.test(request.authorization)) {
      throw new ProviderTransportError(ProviderErrorCode.CONFIGURATION, AgentErrorClass.CONFIGURATION,
        'DeepSeek HTTP configuration is invalid');
    }
    const nativeRequest: http.HttpRequest = http.createHttp();
    let cancel: () => void = (): void => {};
    const result: Promise<DeepSeekHttpResponse> = new Promise<DeepSeekHttpResponse>((resolve, reject) => {
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
      const fail = (error: ProviderTransportError): void => {
        if (settled) return;
        settled = true;
        cleanup();
        reject(error);
      };
      cancel = (): void => fail(new ProviderTransportError(ProviderErrorCode.CANCELLED,
        AgentErrorClass.CANCELLED, 'DeepSeek request cancelled', true));
      const complete = (): void => {
        if (settled || !ended || status === 0) return;
        try {
          const response: DeepSeekHttpResponse = new DeepSeekHttpResponse();
          response.statusCode = status;
          if (status === 200) {
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
          fail(new ProviderTransportError(ProviderErrorCode.PROVIDER, AgentErrorClass.SCHEMA_MISMATCH,
            'DeepSeek response could not be decoded', true));
        }
      };
      timer = setTimeout((): void => fail(new ProviderTransportError(ProviderErrorCode.TIMEOUT,
        AgentErrorClass.TIMEOUT, 'DeepSeek request deadline exceeded', true)), request.timeoutMs);
      try {
        nativeRequest.on('dataReceive', (data: ArrayBuffer): void => {
          if (settled) return;
          if (size + data.byteLength > request.maxResponseBytes) {
            fail(new ProviderTransportError(ProviderErrorCode.RESPONSE_TOO_LARGE, AgentErrorClass.PROVIDER,
              'DeepSeek response exceeded the configured limit', true));
            return;
          }
          size += data.byteLength;
          const copy: Uint8Array = new Uint8Array(data.byteLength);
          copy.set(new Uint8Array(data));
          chunks.push(copy);
        });
        nativeRequest.on('dataEnd', (): void => { ended = true; complete(); });
        const headers: DeepSeekHeaders = {
          Authorization: request.authorization, 'Content-Type': 'application/json', Accept: 'application/json'
        };
        // API 26 SDK: maxRedirects is since 23. Keep credentials on the fixed HTTPS origin.
        const options: http.HttpRequestOptions = {
          method: http.RequestMethod.POST, header: headers, extraData: request.body,
          connectTimeout: request.connectTimeoutMs, readTimeout: request.timeoutMs,
          usingCache: false, maxRedirects: 0, expectDataType: http.HttpDataType.ARRAY_BUFFER
        };
        nativeRequest.requestInStream(DEEPSEEK_CHAT_ENDPOINT, options).then((code: number): void => {
          if (settled) return;
          status = code;
          complete();
        }).catch((error: BusinessError): void => {
          const timedOut: boolean = error.code === 2300028;
          fail(new ProviderTransportError(timedOut ? ProviderErrorCode.TIMEOUT : ProviderErrorCode.NETWORK,
            timedOut ? AgentErrorClass.TIMEOUT : AgentErrorClass.NETWORK,
            timedOut ? 'DeepSeek request timed out' : 'DeepSeek HTTPS request failed', true));
        });
      } catch (error) {
        fail(new ProviderTransportError(ProviderErrorCode.NETWORK, AgentErrorClass.NETWORK,
          'DeepSeek HTTPS request could not start', true));
      }
    });
    return new HttpOperation(result, (): void => cancel());
  }
}
