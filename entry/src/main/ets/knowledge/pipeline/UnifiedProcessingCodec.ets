import { PdfJsonNode } from './BoundedDocumentJson';
import { parsedJson, parsedUtf8 } from './ParsedDocumentCodec';
import { ParsedCancellation, ParsedFailure } from '../domain/ParsedDocumentModels';
import { UnifiedEffectiveAnnotation, UnifiedAnnotationAuto, UnifiedAnnotationOverlay, UnifiedTextInput, UnifiedInputKind, UnifiedProcessingAttempt } from '../domain/UnifiedKnowledgeModels';
export function unifiedStored(raw: string): PdfJsonNode { return parsedJson(parsedUtf8(raw),new ParsedCancellation()); }
export function unifiedStrings(n: PdfJsonNode, key: string): string[] { return n.required(key).array().map((v: PdfJsonNode): string => v.string()); }
export function unifiedAuto(n: PdfJsonNode): UnifiedAnnotationAuto {
  const a: UnifiedAnnotationAuto = new UnifiedAnnotationAuto(); a.id=n.required('id').string(); a.cacheKey=n.required('cacheKey').string(); a.imageHash=n.required('imageHash').string(); a.description=n.required('description').string(); a.tags=unifiedStrings(n,'tags');
  a.recipient=n.required('recipient').string(); a.model=n.required('model').string(); a.promptVersion=n.required('promptVersion').string(); a.schemaVersion=n.required('schemaVersion').string(); a.parametersVersion=n.required('parametersVersion').string(); a.receipt=n.required('receipt').string(); return a;
}
export function unifiedAnnotation(raw: string): UnifiedEffectiveAnnotation {
  const n: PdfJsonNode=unifiedStored(raw); const a: UnifiedEffectiveAnnotation=new UnifiedEffectiveAnnotation(); a.id=n.required('id').string(); a.lineage=n.required('lineage').string(); a.revision=n.required('revision').integer(); a.autoId=n.required('autoId').string(); a.imageHash=n.required('imageHash').string(); a.description=n.required('description').string(); a.tags=unifiedStrings(n,'tags'); a.textHash=n.required('textHash').string();
  const overlay: PdfJsonNode=n.required('overlay'); a.overlay.lineage=overlay.required('lineage').string(); a.overlay.revision=overlay.required('revision').integer(); a.overlay.description=overlay.optional('description')?.string(); if (overlay.optional('tags')!==undefined) { a.overlay.tags=unifiedStrings(overlay,'tags'); } a.overlay.suppressedTags=unifiedStrings(overlay,'suppressedTags'); a.overlay.deleted=overlay.required('deleted').kind==='true';
  a.kind=n.optional('kind')?.string() ?? 'Effective'; const auto: PdfJsonNode | undefined=n.optional('automatic'); if (auto!==undefined) { a.automatic=unifiedAuto(auto); } return a;
}
export function unifiedInput(n: PdfJsonNode): UnifiedTextInput {
  const i: UnifiedTextInput=new UnifiedTextInput(); i.id=n.required('id').string(); i.documentKey=n.required('documentKey').string(); i.ownerNamespace=n.required('ownerNamespace').string(); i.ownerId=n.required('ownerId').string(); i.version=n.required('version').string();
  const kind: string=n.required('kind').string(); if (kind===UnifiedInputKind.Body) { i.kind=UnifiedInputKind.Body; } else if (kind===UnifiedInputKind.Ocr) { i.kind=UnifiedInputKind.Ocr; } else if (kind===UnifiedInputKind.ImageProxy) { i.kind=UnifiedInputKind.ImageProxy; } else { throw new ParsedFailure('InputKind','codec'); }
  i.ordinal=n.required('ordinal').integer(); i.actualText=n.required('actualText').string(); i.inputHash=n.required('inputHash').string(); i.blockId=n.required('blockId').string(); i.occurrenceId=n.required('occurrenceId').string(); i.start=n.required('start').integer(); i.end=n.required('end').integer(); i.policy=n.required('policy').string(); return i;
}
export function unifiedAttempt(raw: string): UnifiedProcessingAttempt {
  const n: PdfJsonNode=unifiedStored(raw); const a: UnifiedProcessingAttempt=new UnifiedProcessingAttempt(); a.id=n.required('id').string(); a.jobId=n.required('jobId').string(); a.inputHash=n.required('inputHash').string(); a.settingsRevision=n.required('settingsRevision').integer(); a.costRevision=n.required('costRevision').integer(); a.launched=n.required('launched').kind==='true'; a.outcome=n.required('outcome').string(); a.receipt=n.required('receipt').string(); a.usageState=n.required('usageState').string(); return a;
}
