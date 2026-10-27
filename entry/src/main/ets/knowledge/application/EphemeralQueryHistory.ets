import { UnifiedQueryHistoryPort } from '../domain/UnifiedQueryPorts';
import { UnifiedSearchHistoryPage } from '../domain/UnifiedQueryModels';

/**
 * History port for chat RAG queries: questions and excerpts stay in the chat view and the answer journal,
 * and are never appended to the knowledge page search history.
 */
export class EphemeralQueryHistory implements UnifiedQueryHistoryPort {
  async append(_page: UnifiedSearchHistoryPage): Promise<void> {}
  async list(_offset: number, _limit: number): Promise<UnifiedSearchHistoryPage[]> { return []; }
}
