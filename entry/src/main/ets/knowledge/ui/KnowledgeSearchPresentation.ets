import { UnifiedSearchCard, UnifiedSearchReason, UnifiedSearchHistoryPage } from '../domain/UnifiedQueryModels';

export const KNOWLEDGE_RESULT_PAGE_SIZE: number = 5;

/** Route filters keep the existing retrieval evidence and source identity intact. */
export function knowledgeSearchTabCards(direct: UnifiedSearchCard[], related: UnifiedSearchCard[], tab: number): UnifiedSearchCard[] {
  if (tab === 0) { return direct.slice(); }
  const route: string = tab === 1 ? 'Tag' : 'Vector';
  const seen: Set<string> = new Set<string>();
  const cards: UnifiedSearchCard[] = [];
  for (const card of direct.concat(related)) {
    if (!seen.has(card.key) && card.reasons.some((reason: UnifiedSearchReason): boolean => reason.route === route)) { seen.add(card.key); cards.push(card); }
  }
  if (tab === 2) { cards.sort((left: UnifiedSearchCard, right: UnifiedSearchCard): number => left.vectorRank - right.vectorRank || left.key.localeCompare(right.key)); }
  return cards;
}
export function knowledgeSearchPage(cards: UnifiedSearchCard[], page: number): UnifiedSearchCard[] {
  const current: number = Math.max(0, Math.min(Math.floor(page), Math.max(0, Math.ceil(cards.length / KNOWLEDGE_RESULT_PAGE_SIZE) - 1)));
  return cards.slice(current * KNOWLEDGE_RESULT_PAGE_SIZE, (current + 1) * KNOWLEDGE_RESULT_PAGE_SIZE);
}
export function knowledgeHistoryTags(pages: UnifiedSearchHistoryPage[]): UnifiedSearchHistoryPage[] {
  const seen: Set<string> = new Set<string>(); const result: UnifiedSearchHistoryPage[] = [];
  for (const page of pages) {
    const question: string = page.question.trim();
    if (question.length > 0 && !seen.has(question)) { seen.add(question); result.push(page); }
  }
  return result;
}
