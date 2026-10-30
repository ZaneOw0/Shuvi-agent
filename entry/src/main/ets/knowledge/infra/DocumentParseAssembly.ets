import { common } from '@kit.AbilityKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { DocumentParseService } from '../application/DocumentParseService';
import { DocumentParseStateListener, DocumentParseFailure } from '../domain/DocumentParseModels';
import { DocumentParseClockPort } from '../domain/DocumentParsePorts';
import { MineruCredentialStore } from './MineruCredentialStore';
import { DocumentFileAdapter } from './DocumentFileAdapter';
import { documentDigestHex } from './DocumentFileOperations';
import { DocumentParseRepository } from './DocumentParseRepository';
import { MineruTransportAdapter } from './MineruTransportAdapter';
import { KnowledgeAssembly } from './KnowledgeAssembly';
import { KnowledgeDerivedBudget } from './KnowledgeDerivedBudget';
import { ImageResultReader } from './ImageResultReader';
import { settingsInitializationTrace } from './SettingsInitializationTrace';

class DocumentPlatformClock implements DocumentParseClockPort {
  now(): number { return Date.now(); }
  id(): string { return 'm2-' + documentDigestHex(cryptoFramework.createRandom().generateRandomSync(16).data); }
  async sleep(ms: number): Promise<void> { await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, ms); }); }
}
export class DocumentParseAssembly implements DocumentParseStateListener {
  service: DocumentParseService;
  imageResults: ImageResultReader;
  private onChanged: () => void;
  private static sessions: DocumentParseAssembly[] = [];
  private knowledge: KnowledgeAssembly;
  private knowledgeLease: boolean = false;
  constructor(context: common.Context, changed: () => void) {
    const credential: MineruCredentialStore = new MineruCredentialStore(context.filesDir);
    const assets: DocumentFileAdapter = new DocumentFileAdapter(context);
    this.service = new DocumentParseService(credential, new DocumentParseRepository(context));
    this.imageResults = new ImageResultReader(context.filesDir,this.service);
    this.knowledge = KnowledgeAssembly.forContext(context);
    this.service.attachSourceProtection(this.knowledge.lifecycle);
    const budget: KnowledgeDerivedBudget = new KnowledgeDerivedBudget(context);
    this.service.attachLocalCapacity(async (bytes: number): Promise<void> => { const usage = await budget.usage(); if (usage.total()+bytes*2+1048576 > 524288000) { throw new DocumentParseFailure('共享资料预算不足','复制前'); } });
    this.service.state.resultDirectory = `${context.filesDir}/knowledge_parse_v1`;
    this.service.attachLocal(assets, assets);
    this.service.attachRemote(new MineruTransportAdapter(credential, assets, context.filesDir), new DocumentPlatformClock());
    this.onChanged = changed; this.service.subscribe(this); DocumentParseAssembly.sessions.push(this);
  }
  changed(): void { this.onChanged(); }
  async initialize(): Promise<void> {
    const started: number = Date.now(); settingsInitializationTrace('parse', 'knowledge-start', started);
    try { await this.knowledge.acquire(); this.knowledgeLease = true; } catch { /* The guard stays fail-closed; parsing remains independent. */ }
    settingsInitializationTrace('parse', 'knowledge-finished', started);
    try { await this.service.initialize(); }
    catch { this.service.state.message = '解析准备库或安全能力不可用，M1未修改；没有重置库'; this.changed(); throw new DocumentParseFailure('M2初始化失败', '装配'); }
    settingsInitializationTrace('parse', 'ready', started);
  }
  static background(): void {
    for (const session of DocumentParseAssembly.sessions) {
      session.service.pauseImmediate(); session.service.pause().catch((_error: Error): void => {});
    }
  }
  async close(): Promise<void> {
    DocumentParseAssembly.sessions = DocumentParseAssembly.sessions.filter((s: DocumentParseAssembly): boolean => s !== this);
    await this.service.close();
    if (this.knowledgeLease) { this.knowledgeLease = false; await this.knowledge.release(); }
  }
}
