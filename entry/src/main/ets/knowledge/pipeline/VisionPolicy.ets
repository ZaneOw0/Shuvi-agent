import { VisionResponse, VisionPolicyVersions, VisionFailure } from '../domain/VisionModels';
import { ParsedCancellation } from '../domain/ParsedDocumentModels';
import { ParsedIdentityPort } from '../domain/ParsedDocumentPorts';
import { parsedUtf8, parsedJson } from './ParsedDocumentCodec';
import { PdfJsonNode, PdfJsonField } from './BoundedDocumentJson';

export const VISION_ENDPOINT: string = 'https://api.deepseek.com/chat/completions';
export const VISION_PROMPT: string = '请仅观察当前图片，用中文客观描述可见内容，不猜测不可见信息。只输出 JSON 对象，且只有 description 和 tags 两个字段。description 为非空中文描述（不超过2000个字符）；tags 为自由标签字符串数组（可为空，最多20项，每项最多64个字符，中文为主，专名可保原文）。不要转写全文OCR，不输出代码围栏、置信度、分类、解释或其他字段。';
export class VisionLimits { static readonly request: number = 32*1024*1024; static readonly response: number = 1024*1024; static readonly ms: number = 120000; }
export function visionPayload(mime: string, base64: string): string {
  if (['image/jpeg','image/png','image/webp'].indexOf(mime)<0 || base64.length===0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(base64)) { throw new VisionFailure('ImageEncoding','request'); }
  const raw: string = `{"model":"${VisionPolicyVersions.model}","messages":[{"role":"user","content":[{"type":"text","text":${JSON.stringify(VISION_PROMPT)}},{"type":"image_url","image_url":{"url":${JSON.stringify(`data:${mime};base64,${base64}`)},"detail":"original"}}]}],"stream":false,"thinking":{"type":"disabled"},"max_tokens":2048,"response_format":{"type":"json_object"}}`;
  if (parsedUtf8(raw).length>VisionLimits.request) { throw new VisionFailure('RequestBudget','request'); } return raw;
}
export function visionTags(tags: string[]): string[] {
  if (tags.length>20) { throw new VisionFailure('TagsCount','response'); } const out: string[] = [];
  for (const tag of tags) { const text: string = tag.trim(); if (text.length===0 || Array.from(text).length>64) { throw new VisionFailure('TagLength','response'); } if (out.indexOf(text)<0) { out.push(text); } } return out;
}
export function visionDescription(text: string): string {
  const result: string = text.trim(); if (result.length===0 || Array.from(result).length>2000 || !/[\u3400-\u9fff]/.test(result)) { throw new VisionFailure('DescriptionChineseOrLength','response'); } return result;
}
export function visionDecode(raw: string): VisionResponse {
  const root: PdfJsonNode = parsedJson(parsedUtf8(raw),new ParsedCancellation(),VisionLimits.response);
  if (root.required('object').string()!=='chat.completion' || root.required('model').string()!==VisionPolicyVersions.model) { throw new VisionFailure('ModelOrObject','response'); }
  const choices: PdfJsonNode[] = root.required('choices').array(); if (choices.length!==1 || choices[0].required('index').integer()!==0) { throw new VisionFailure('ChoiceIndex','response'); }
  const finish: string = choices[0].required('finish_reason').string(); if (finish!=='stop') { throw new VisionFailure('Finish:'+finish,'response'); }
  const message: PdfJsonNode = choices[0].required('message'); if (message.required('role').string()!=='assistant' || (message.optional('tool_calls')?.array().length ?? 0)>0) { throw new VisionFailure('AssistantOrTools','response'); }
  const inner: PdfJsonNode = parsedJson(parsedUtf8(message.required('content').string()),new ParsedCancellation(),VisionLimits.response);
  if (inner.kind!=='object' || inner.fields.length!==2 || inner.fields.some((f: PdfJsonField): boolean => ['description','tags'].indexOf(f.key)<0)) { throw new VisionFailure('AnnotationFields','response'); }
  const result: VisionResponse = new VisionResponse(); result.description = visionDescription(inner.required('description').string()); result.tags = visionTags(inner.required('tags').array().map((v: PdfJsonNode): string => v.string()));
  result.model = VisionPolicyVersions.model; result.finishReason = finish; result.responseId = root.required('id').string(); const fingerprint: PdfJsonNode | undefined=root.optional('system_fingerprint'); result.fingerprint = fingerprint===undefined || fingerprint.kind==='null'?'':fingerprint.string();
  if (result.responseId.length===0 || result.responseId.length>512) { throw new VisionFailure('ResponseId','response'); }
  const usage: PdfJsonNode | undefined = root.optional('usage');
  if (usage!==undefined && usage.kind!=='null') {
    result.usage.promptTokens = usage.optional('prompt_tokens')?.integer(); result.usage.completionTokens = usage.optional('completion_tokens')?.integer(); result.usage.totalTokens = usage.optional('total_tokens')?.integer();
    for (const n of [result.usage.promptTokens,result.usage.completionTokens,result.usage.totalTokens]) { if (n!==undefined && n<0) { throw new VisionFailure('UsageNegative','response'); } }
    if (result.usage.promptTokens!==undefined && result.usage.completionTokens!==undefined && result.usage.totalTokens!==undefined && result.usage.totalTokens!==result.usage.promptTokens+result.usage.completionTokens) { throw new VisionFailure('UsageInconsistent','response'); }
    if (result.usage.promptTokens!==undefined || result.usage.completionTokens!==undefined || result.usage.totalTokens!==undefined) { result.usage.state = 'Reported'; }
  }
  return result;
}
export async function visionCacheKey(imageHash: string, identity: ParsedIdentityPort): Promise<string> {
  return identity.hash(parsedUtf8([imageHash,VISION_ENDPOINT,VisionPolicyVersions.model,VisionPolicyVersions.prompt,VisionPolicyVersions.schema,VisionPolicyVersions.parameters].join('\n')));
}
