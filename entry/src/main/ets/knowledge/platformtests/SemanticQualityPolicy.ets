import { BoundedDocumentJson, PdfJsonNode } from '../pipeline/BoundedDocumentJson';
import { pdfCodecUtf8 } from '../pipeline/PdfSnapshotCodec';
import { KnowledgeCancellation, KnowledgeFailure } from '../domain/PdfKnowledgeModels';
import { KnowledgeHit, KnowledgeSourceKind, KnowledgeChannel } from '../domain/KnowledgeSearchModels';
import { prepareTextQuery, textKeywordScore } from '../pipeline/QueryPreparation';
import { knowledgeFuse } from '../pipeline/KnowledgeRetrievalPolicy';

export class QualityRule { id: string = ''; text: string = ''; }
export class QualityQuestion { id: string = ''; kind: string = ''; text: string = ''; gold: string[] = []; forbidden: string[] = []; }
export class QualityManifest { rules: QualityRule[] = []; questions: QualityQuestion[] = []; }
export class QualityAttemptBudget {
  private seen: string[] = [];
  claim(id: string, document: boolean): void {
    const valid: boolean = document ? new RegExp('^F0[1-8]$').test(id) : new RegExp('^(P0[1-8]|N0[1-4]|A0[1-4])$').test(id);
    if (!valid || this.seen.includes(id) || this.seen.length >= 24 || (!document && this.seen.filter((item: string): boolean => item.startsWith('F')).length !== 8)) { throw new KnowledgeFailure('QualityAttemptCapOrDuplicate','quality'); }
    this.seen.push(id);
  }
}
export class QualityCaseResult {
  id: string = ''; gold: string[] = []; keyword: string[] = []; vector: string[] = []; hybrid: string[] = [];
  distances: number[] = []; keywordRank: number = 0; vectorRank: number = 0; hybridRank: number = 0;
  forbiddenRank: number = 0; kind: string = ''; noAnswer: boolean = false; goldDistance: number = -1;
}
export function qualityManifest(rulesText: string, goldText: string): QualityManifest {
  const result = new QualityManifest(); const sections: string[] = rulesText.split('\n## ');
  for (const section of sections.slice(1)) { const lines: string[] = section.split('\n'); const item = new QualityRule(); item.id = lines[0]; item.text = lines.slice(1).join('\n').trim(); if (!new RegExp('^F0[1-8]$').test(item.id) || item.text.length === 0 || item.text.includes('##') || result.rules.some((old: QualityRule): boolean => old.id === item.id)) { throw new KnowledgeFailure('QualityRulesShape','quality'); } result.rules.push(item); }
  const root = new BoundedDocumentJson(pdfCodecUtf8(goldText),new KnowledgeCancellation()).read();
  if (root.required('version').string() !== 'R2-SEMANTIC-MANUAL-1') { throw new KnowledgeFailure('QualityGoldVersion','quality'); }
  for (const node of root.required('cases').array()) { const item = new QualityQuestion(); item.id = node.required('id').string(); item.kind = node.required('kind').string(); item.text = node.required('question').string(); item.gold = node.required('sources').array().map((source: PdfJsonNode): string => source.string()); item.forbidden = node.optional('forbiddenSources')?.array().map((source: PdfJsonNode): string => source.string()) ?? []; if (prepareTextQuery(item.text).actualInput !== item.text || result.questions.some((old: QualityQuestion): boolean => old.id === item.id) || item.gold.concat(item.forbidden).some((source: string): boolean => !result.rules.some((rule: QualityRule): boolean => rule.id === source))) { throw new KnowledgeFailure('QualityQuestionShape','quality'); } result.questions.push(item); }
  if (result.rules.length !== 8 || result.questions.length !== 16 || result.questions.filter((q: QualityQuestion): boolean => q.kind === 'paraphrase').length !== 8 || result.questions.filter((q: QualityQuestion): boolean => q.kind === 'negation').length !== 4 || result.questions.filter((q: QualityQuestion): boolean => q.kind === 'no-answer').length !== 4 || result.questions.some((q: QualityQuestion): boolean => (q.kind === 'no-answer') !== (q.gold.length === 0))) { throw new KnowledgeFailure('QualityFrozenCounts','quality'); } return result;
}
export function qualityHit(rule: QualityRule, space: string, generation: string): KnowledgeHit {
  const hit = new KnowledgeHit(); hit.id = rule.id; hit.chunkId = rule.id; hit.documentId = rule.id; hit.generation = generation; hit.snapshotHash = generation; hit.originalHash = generation; hit.sourceKind = KnowledgeSourceKind.Pdf; hit.spaceId = space; hit.text = rule.text; hit.retrievalText = rule.text; return hit;
}
export function qualityEvaluate(question: QualityQuestion, rules: QualityRule[], vectors: KnowledgeHit[]): QualityCaseResult {
  const input = prepareTextQuery(question.text); const keyword: KnowledgeHit[] = [];
  for (const rule of rules) { const hit = qualityHit(rule,'',vectors[0]?.generation ?? ''); hit.channels = [KnowledgeChannel.Keyword]; hit.keywordScore = textKeywordScore(rule.text,input.terms); if (hit.keywordScore > 0) { keyword.push(hit); } }
  keyword.sort((a: KnowledgeHit,b: KnowledgeHit): number => b.keywordScore-a.keywordScore || a.id.localeCompare(b.id));
  const result = new QualityCaseResult(); result.id = question.id; result.kind = question.kind; result.gold = question.gold; result.noAnswer = question.kind === 'no-answer'; result.keyword = keyword.slice(0,5).map((hit: KnowledgeHit): string => hit.id); result.vector = vectors.slice(0,5).map((hit: KnowledgeHit): string => hit.id); result.distances = vectors.slice(0,5).map((hit: KnowledgeHit): number => hit.vectorDistance ?? -1);
  result.hybrid = knowledgeFuse(keyword,vectors).map((hit: KnowledgeHit): string => hit.id);
  result.goldDistance = vectors.find((hit: KnowledgeHit): boolean => question.gold.includes(hit.id))?.vectorDistance ?? -1;
  const rank = (ids: string[], gold: string[]): number => { const at: number = ids.findIndex((id: string): boolean => gold.includes(id)); return at < 0 ? 0 : at+1; };
  result.keywordRank = rank(result.keyword,question.gold); result.vectorRank = rank(result.vector,question.gold); result.hybridRank = rank(result.hybrid,question.gold); result.forbiddenRank = rank(result.hybrid,question.forbidden); return result;
}
