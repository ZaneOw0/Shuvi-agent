import { KnowledgeSemanticRuntimeSearchAdapter } from '../application/KnowledgeSemanticRuntimeSearchAdapter';
import {
  KnowledgeRagReadiness, KnowledgeRagSearchPort, KnowledgeRuntimeSearchRequest, KnowledgeRuntimeSearchResult
} from '../domain/KnowledgeRuntimePorts';
import { ParsedCancellation, ParsedFailure } from '../domain/ParsedDocumentModels';
import { KnowledgeAssembly } from './KnowledgeAssembly';

/** Owns one KnowledgeAssembly lease for the lifetime of a prepared chat RAG session. */
export class KnowledgeRagSessionAdapter implements KnowledgeRagSearchPort {
  private readonly assembly: KnowledgeAssembly;
  private readonly searcher: KnowledgeSemanticRuntimeSearchAdapter;
  private opened: boolean = false;
  private closing: Promise<void> | undefined = undefined;

  constructor(assembly: KnowledgeAssembly) {
    this.assembly = assembly;
    this.searcher = new KnowledgeSemanticRuntimeSearchAdapter(() => this.assembly.createRagQuerySession());
  }

  async open(): Promise<void> {
    const closing: Promise<void> | undefined = this.closing;
    if (closing !== undefined) { await closing; }
    if (!this.opened) { await this.assembly.acquire(); this.opened = true; }
  }

  async readiness(): Promise<KnowledgeRagReadiness> {
    const result: KnowledgeRagReadiness = new KnowledgeRagReadiness();
    if (!this.opened) { result.code = 'RagSessionClosed'; result.message = '知识库 RAG 会话尚未打开。'; return result; }
    try { return await this.assembly.ragReadiness(); }
    catch { result.code = 'RagReadinessFailed'; result.message = '知识库 RAG 就绪检查失败，未发送问题。'; return result; }
  }

  async search(request: KnowledgeRuntimeSearchRequest, cancel: ParsedCancellation): Promise<KnowledgeRuntimeSearchResult> {
    if (!this.opened) { throw new ParsedFailure('RuntimeRagSessionClosed', 'runtime-rag-search'); }
    return await this.searcher.search(request, cancel);
  }

  close(): Promise<void> {
    if (this.closing !== undefined) { return this.closing; }
    if (!this.opened) { return Promise.resolve(); }
    this.closing = this.closeOnce(); return this.closing;
  }

  private async closeOnce(): Promise<void> {
    try { await this.searcher.close(); await this.assembly.release(); this.opened = false; }
    finally { this.closing = undefined; }
  }
}
