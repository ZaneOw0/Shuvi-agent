import { randomUUID } from 'node:crypto';
import { z } from 'zod';

export const inputSchema = z.strictObject({
  query: z.string().trim().min(1).refine(value => [...value].length <= 500,
    'query must not exceed 500 Unicode code points'),
  maxResults: z.number().int().min(1).max(10).default(5)
});

const sourceSchema = z.object({
  title: z.string().trim().min(1).max(512),
  url: z.string().max(2048).url().refine(value => {
    const url = new URL(value);
    return ['http:', 'https:'].includes(url.protocol) && !url.username && !url.password;
  }),
  content: z.string().max(8000)
});
const responseSchema = z.object({ results: z.array(sourceSchema) });
export const outputSchema = z.strictObject({
  schemaVersion: z.literal('1.0'),
  requestId: z.string().uuid(),
  provider: z.literal('tavily'),
  query: z.string(),
  searchedAt: z.string().datetime(),
  results: z.array(z.strictObject({
    title: z.string(), url: z.string().url(), snippet: z.string()
  })).max(10)
});
export type SearchInput = z.infer<typeof inputSchema>;
export type SearchOutput = z.infer<typeof outputSchema>;
export const failureSchema = z.strictObject({
  schemaVersion: z.literal('1.0'), requestId: z.string().uuid(),
  error: z.strictObject({ code: z.string(), message: z.string() })
});
export const toolResultSchema = z.union([outputSchema, failureSchema]);
export type SearchCode = 'INVALID_ARGUMENT' | 'CONFIGURATION' | 'AUTHENTICATION' |
  'RATE_LIMITED' | 'QUOTA_EXCEEDED' | 'NETWORK' | 'TIMEOUT' | 'CANCELLED' |
  'INVALID_RESPONSE' | 'RESPONSE_TOO_LARGE' | 'UPSTREAM';

const messages: Record<SearchCode, string> = {
  INVALID_ARGUMENT: '搜索参数无效，请检查关键词和结果数量。',
  CONFIGURATION: '搜索服务尚未配置有效的 Tavily 凭据。',
  AUTHENTICATION: '搜索供应商认证失败，请检查服务端凭据。',
  RATE_LIMITED: '搜索请求过于频繁，请稍后主动重试。',
  QUOTA_EXCEEDED: '搜索供应商额度不足，请检查账户额度。',
  NETWORK: '无法连接搜索供应商，请稍后主动重试。',
  TIMEOUT: '搜索超时，请稍后主动重试。',
  CANCELLED: '搜索已取消。',
  INVALID_RESPONSE: '搜索供应商返回了无法识别的数据。',
  RESPONSE_TOO_LARGE: '搜索响应超过本服务允许的大小。',
  UPSTREAM: '搜索供应商暂时无法完成请求。'
};

export class SearchError extends Error {
  constructor(readonly code: SearchCode) {
    super(messages[code]);
    this.name = 'SearchError';
  }
}

export interface SearchOptions {
  apiKey: string;
  fetcher?: typeof fetch;
  timeoutMs?: number;
}

// Injectable transport is for deterministic tests; production always uses the fixed HTTPS URL.
export function createSearch(options: SearchOptions) {
  const fetcher = options.fetcher ?? fetch;
  const timeoutMs = options.timeoutMs ?? 15_000;
  if (!Number.isInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 60_000) {
    throw new Error('Invalid search timeout configuration');
  }
  return async (input: SearchInput, cancellation: AbortSignal): Promise<SearchOutput> => {
    const parsed = inputSchema.safeParse(input);
    if (!parsed.success) throw new SearchError('INVALID_ARGUMENT');
    if (cancellation.aborted) throw new SearchError('CANCELLED');
    if (!options.apiKey.trim() || /[\r\n]/.test(options.apiKey)) throw new SearchError('CONFIGURATION');
    const deadline = new AbortController();
    const signal = AbortSignal.any([cancellation, deadline.signal]);
    const timer = setTimeout(() => deadline.abort(), timeoutMs);
    try {
      const response = await fetcher('https://api.tavily.com/search', {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${options.apiKey}`,
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({
          query: parsed.data.query,
          max_results: parsed.data.maxResults,
          search_depth: 'basic', topic: 'general', auto_parameters: false,
          include_answer: false, include_raw_content: false, include_images: false
        }),
        redirect: 'error',
        signal
      });
      if (!response.ok) {
        await response.body?.cancel();
        if ([401, 403].includes(response.status)) throw new SearchError('AUTHENTICATION');
        if (response.status === 429) throw new SearchError('RATE_LIMITED');
        if ([432, 433].includes(response.status)) throw new SearchError('QUOTA_EXCEEDED');
        throw new SearchError('UPSTREAM');
      }
      const reader = response.body?.getReader();
      if (!reader) throw new SearchError('INVALID_RESPONSE');
      const parts: Uint8Array[] = [];
      let length = 0;
      try {
        for (;;) {
          signal.throwIfAborted();
          const chunk = await reader.read();
          if (chunk.done) break;
          length += chunk.value.byteLength;
          if (length > 1_048_576) throw new SearchError('RESPONSE_TOO_LARGE');
          parts.push(chunk.value);
        }
      } finally {
        await reader.cancel().catch(() => {});
        reader.releaseLock();
      }
      signal.throwIfAborted();
      // Validate parsed provider data immediately; never trust TypeScript declarations alone.
      const decoded = responseSchema.safeParse(JSON.parse(Buffer.concat(parts).toString('utf8')));
      if (!decoded.success) throw new SearchError('INVALID_RESPONSE');
      const result: SearchOutput = {
        schemaVersion: '1.0', requestId: randomUUID(), provider: 'tavily',
        query: parsed.data.query, searchedAt: new Date().toISOString(),
        results: decoded.data.results.slice(0, parsed.data.maxResults).map(item => ({
          title: item.title, url: item.url, snippet: item.content
        }))
      };
      if (Buffer.byteLength(JSON.stringify(result)) > 196_608) throw new SearchError('RESPONSE_TOO_LARGE');
      return result;
    } catch (error) {
      if (cancellation.aborted) throw new SearchError('CANCELLED');
      if (deadline.signal.aborted) throw new SearchError('TIMEOUT');
      if (error instanceof SearchError) throw error;
      if (error instanceof SyntaxError) throw new SearchError('INVALID_RESPONSE');
      // Do not forward provider errors, request headers, URLs with secrets, or response bodies.
      throw new SearchError('NETWORK');
    } finally {
      clearTimeout(timer);
    }
  };
}

export type Search = ReturnType<typeof createSearch>;
