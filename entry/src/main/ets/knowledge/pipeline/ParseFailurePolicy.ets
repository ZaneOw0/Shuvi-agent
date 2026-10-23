import { DocumentParseFailure, ParseFailureDetail, ParseFailureKind } from '../domain/DocumentParseModels';

export function parseSafeCode(raw: string): string { return new RegExp('^[A-Za-z0-9_.-]{1,64}$').test(raw) ? raw : ''; }
export function parseSanitizedReason(raw: string): string {
  return raw.slice(0,4096).replace(/[\x00-\x1f\x7f\u2028\u2029]/g,' ')
    .replace(/https?:\/\/[^\s<>"']+/gi,'[地址已隐藏]')
    .replace(/authorization\s*[:=]\s*(?:basic|bearer)?\s*[^\s,;]+/gi,'[认证已隐藏]')
    .replace(/(?:authorization\s*[:=]?\s*)?(?:bearer\s+)[^\s,;]+/gi,'[认证已隐藏]')
    .replace(/(?:token|api[_-]?key|secret|signature|password)\s*[:=]\s*[^\s,;]+/gi,'[认证字段已隐藏]')
    .replace(/\s+/g,' ').trim().slice(0,300);
}
export function parseDetailedFailure(kind: ParseFailureKind, stage: string, reason: string): DocumentParseFailure {
  const failure: DocumentParseFailure = new DocumentParseFailure(kind,stage);
  failure.detail.kind = kind; failure.detail.stage = stage.slice(0,100); failure.detail.sanitizedReason = parseSanitizedReason(reason); return failure;
}
export function parseHttpFailure(status: number, retryAfter: string | undefined): DocumentParseFailure {
  const kind: ParseFailureKind = status === 401 || status === 403 ? ParseFailureKind.Auth : status === 429 ? ParseFailureKind.RateLimit : status >= 500 ? ParseFailureKind.Service : ParseFailureKind.Unknown;
  const failure: DocumentParseFailure = parseDetailedFailure(kind,'HTTP',status === 429 ? '服务限频；不推定余额不足，不自动重试' : `HTTP ${status}；按原任务身份核对`);
  failure.detail.httpStatus = status;
  if (retryAfter !== undefined && new RegExp('^[0-9]{1,6}$').test(retryAfter)) { failure.detail.retryAfter = `${Math.min(900,Math.max(5,Number(retryAfter)))}`; }
  return failure;
}
export function parseProviderFailure(code: string, reason: string, stage: string): DocumentParseFailure {
  const safe: string = parseSanitizedReason(reason); let kind: ParseFailureKind = ParseFailureKind.Service;
  // Classify explicit words only; no undocumented numeric/A-code map.
  if (new RegExp('unsupported (?:image |file |input )?format|invalid (?:image|file) format|corrupt(?:ed)? (?:image|file)|不支持.{0,12}格式|(?:图片|文件).{0,8}(?:损坏|格式错误)','i').test(safe)) { kind = ParseFailureKind.Format; }
  else if (new RegExp('quota (?:exceeded|exhausted)|insufficient (?:balance|credits)|额度.{0,6}(?:不足|耗尽)|余额不足','i').test(safe)) { kind = ParseFailureKind.Quota; }
  else if (new RegExp('rate limit|too many requests|请求.{0,6}频繁|限频','i').test(safe)) { kind = ParseFailureKind.RateLimit; }
  else if (new RegExp('unauthorized|invalid (?:access )?token|access denied|鉴权失败|无权访问','i').test(safe)) { kind = ParseFailureKind.Auth; }
  const failure: DocumentParseFailure = parseDetailedFailure(kind,stage,safe || '服务报告失败，未提供明确原因');
  failure.serviceCode = parseSafeCode(code); failure.detail.providerCode = failure.serviceCode; return failure;
}
export function parseSdkFailure(code: number | undefined, stage: string, outcomeUnknown: boolean): DocumentParseFailure {
  // API26 @hms.collaboration.rcp.d.ts Session.fetch @throws; local IO is never network.
  const network: number[] = [1007900005,1007900006,1007900007,1007900028,1007900035,1007900052,1007900055,1007900056,1007900060,1007900097,1007900986];
  const local: number[] = [1007900023,1007900026,1007900027,1007900037,1007900058,1007900065,1007900070,1007900077,1007900985,1007900987,1007900988,1007900990];
  const kind: ParseFailureKind = code !== undefined && network.indexOf(code) >= 0 ? ParseFailureKind.Network : code !== undefined && local.indexOf(code) >= 0 ? ParseFailureKind.Artifact : ParseFailureKind.Unknown;
  const failure: DocumentParseFailure = parseDetailedFailure(kind,stage,kind === ParseFailureKind.Network ? '连接、DNS、TLS 或请求超时；只核对原任务' : kind === ParseFailureKind.Artifact ? '本机文件、回调或资源处理失败；保留已完成阶段' : 'SDK 返回未分类错误；原因未确定');
  failure.detail.sdkCode = code !== undefined && Number.isSafeInteger(code) ? `${code}` : ''; failure.serviceCode = failure.detail.sdkCode; failure.detail.outcomeUnknown = outcomeUnknown; return failure;
}
export function parseFailureSummary(detail: ParseFailureDetail): string {
  return `${detail.kind} · ${detail.stage} · HTTP ${detail.httpStatus || '未提供'} · SDK ${detail.sdkCode || '未提供'} · provider ${detail.providerCode || '未提供'}${detail.retryAfter.length > 0 ? ' · Retry-After '+detail.retryAfter+'s' : ''}\n${detail.sanitizedReason || '原因未确定'}${detail.outcomeUnknown ? '；请求结果未知，只核对原任务，不重新上传' : ''}`;
}
