import { UnifiedTextInput, UnifiedInputKind, UNIFIED_TEXT_POLICY } from '../domain/UnifiedKnowledgeModels';
import { ParsedIdentityPort } from '../domain/ParsedDocumentPorts';
import { ParsedFailure } from '../domain/ParsedDocumentModels';
import { parsedUtf8 } from './ParsedDocumentCodec';
export function unifiedProxyText(description: string, tags: string[]): string {
  const fields: string[] = []; if (description.trim().length>0) { fields.push(description.trim()); }
  const seen: string[] = []; for (const tag of tags) { const text: string = tag.trim(); if (text.length>0 && seen.indexOf(text)<0) { seen.push(text); } }
  fields.push(...seen); return fields.join('\n');
}
export async function unifiedProxyInputs(document: string, lineage: string, version: string, text: string, identity: ParsedIdentityPort): Promise<UnifiedTextInput[]> {
  const inputs: UnifiedTextInput[] = []; let start: number = 0;
  while (start<text.length) {
    let end: number = start; let count: number = 0; let bytes: number = 0;
    while (end<text.length && count<512) { const cp: number = text.codePointAt(end) ?? 0; const n: number = cp<128?1:cp<2048?2:cp<65536?3:4; if (bytes+n>2048) { break; } bytes+=n; count++; end+=cp>65535?2:1; }
    if (end<=start || inputs.length>=2000) { throw new ParsedFailure('ProxyInputBudget','text'); }
    const actual: string = text.slice(start,end);
    if (actual.trim().length>0) { const input: UnifiedTextInput = new UnifiedTextInput(); input.id = `${version}-t${inputs.length}`; input.documentKey = document; input.ownerNamespace = 'upd-image'; input.ownerId = lineage; input.version = version; input.kind = UnifiedInputKind.ImageProxy; input.ordinal = inputs.length; input.actualText = actual; input.inputHash = await identity.hash(parsedUtf8(actual)); input.start = start; input.end = end; input.policy = UNIFIED_TEXT_POLICY; inputs.push(input); }
    start=end;
  }
  return inputs;
}
