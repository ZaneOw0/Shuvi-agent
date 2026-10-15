import { common } from '@kit.AbilityKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { DocumentParseService } from '../application/DocumentParseService';
import { DocumentParseStateListener, DocumentParseFailure } from '../domain/DocumentParseModels';
import { DocumentParseClockPort } from '../domain/DocumentParsePorts';
import { MineruCredentialStore } from './MineruCredentialStore';
import { DocumentFileAdapter } from './DocumentFileAdapter';
import { documentDigestHex } from './DocumentFileOperations';
import { DocumentPdfPreflight } from './DocumentPdfPreflight';
import { DocumentParseRepository } from './DocumentParseRepository';
import { MineruTransportAdapter } from './MineruTransportAdapter';

class DocumentPlatformClock implements DocumentParseClockPort {
  now(): number { return Date.now(); }
  id(): string { return 'm2-' + documentDigestHex(cryptoFramework.createRandom().generateRandomSync(16).data); }
  async sleep(ms: number): Promise<void> { await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, ms); }); }
}
export class DocumentParseAssembly implements DocumentParseStateListener {
  service: DocumentParseService;
  private onChanged: () => void;
  private static sessions: DocumentParseAssembly[] = [];
  constructor(context: common.Context, changed: () => void) {
    const credential: MineruCredentialStore = new MineruCredentialStore(context.filesDir);
    const assets: DocumentFileAdapter = new DocumentFileAdapter(context);
    this.service = new DocumentParseService(credential, new DocumentParseRepository(context));
    this.service.state.resultDirectory = `${context.filesDir}/knowledge_parse_v1`;
    this.service.attachLocal(assets, assets, new DocumentPdfPreflight(context.filesDir));
    this.service.attachRemote(new MineruTransportAdapter(credential, assets, context.filesDir), new DocumentPlatformClock());
    this.onChanged = changed; this.service.subscribe(this); DocumentParseAssembly.sessions.push(this);
  }
  changed(): void { this.onChanged(); }
  async initialize(): Promise<void> {
    try { await this.service.initialize(); }
    catch { this.service.state.message = '解析准备库或安全能力不可用，M1未修改；没有重置库'; this.changed(); throw new DocumentParseFailure('M2初始化失败', '装配'); }
  }
  static background(): void {
    for (const session of DocumentParseAssembly.sessions) {
      session.service.pauseImmediate(); session.service.pause().catch((_error: Error): void => {});
    }
  }
  async close(): Promise<void> {
    DocumentParseAssembly.sessions = DocumentParseAssembly.sessions.filter((s: DocumentParseAssembly): boolean => s !== this);
    await this.service.close();
  }
}
