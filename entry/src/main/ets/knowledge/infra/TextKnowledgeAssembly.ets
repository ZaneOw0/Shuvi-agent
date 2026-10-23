import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { TextStateListener } from '../domain/TextKnowledgePorts';
import { TextKnowledgeService } from '../application/TextKnowledgeService';
import { TextFileAdapter } from './TextFileAdapter';
import { TextProcessingAdapter } from './TextProcessingAdapter';
import { TextRdbRepository } from './TextRdbRepository';
import { KnowledgeStoreHost } from './KnowledgeStoreHost';

export class TextKnowledgeAssembly implements TextStateListener {
  service: TextKnowledgeService;
  repository: TextRdbRepository;
  private onChanged: () => void;
  constructor(context: common.Context, onChanged: () => void, host: KnowledgeStoreHost = KnowledgeStoreHost.forContext(context)) {
    const assets: TextFileAdapter = new TextFileAdapter(context,host);
    const repository: TextRdbRepository = new TextRdbRepository(context, host); this.repository = repository;
    this.service = new TextKnowledgeService(assets, assets, new TextProcessingAdapter(), repository);
    this.onChanged = onChanged; this.service.subscribe(this);
  }
  changed(): void { this.onChanged(); }
  async initialize(deferRecovery: boolean = false): Promise<void> {
    try { await this.service.initialize(deferRecovery); hilog.info(0xD002, 'TextKnowledge', 'session initialized; local L0 only'); }
    catch { hilog.error(0xD002, 'TextKnowledge', 'session initialization failed; no data reset'); throw new Error('用户知识库打开失败，资料未清理'); }
  }
  async close(): Promise<void> { this.service.unsubscribe(this); await this.service.close(); }
}
