import { ImageIntegrationSuite } from '../platformtests/ImageIntegrationSuite';
import { ImageIngestionView } from './ImageIngestionView';
import { ImageSourceView } from './ImageSourceView';
import { KnowledgeView } from './KnowledgeView';
import { TextViewState } from '../domain/TextKnowledgeModels';
import { ImageDocument } from '../domain/ImageKnowledgeModels';
import { KnowledgeHit } from '../domain/KnowledgeSearchModels';

@Component
export struct ImageIntegrationView {
  @Require fixture: ImageIntegrationSuite;
  onBack: () => void = (): void => {};
  @State private mode: string = 'ingestion';
  @State private statusText: string = '';
  @State private serviceEpoch: number = 0;
  @State private emptyTextState: TextViewState = new TextViewState();
  @State private vectorConsent: boolean = false;
  private async action(name: string): Promise<void> {
    try {
      if (name === 'ocr') { await this.fixture.controlled(); } else if (name === 'empty') { await this.fixture.controlled(true); }
      else if (name === 'invalid') { await this.fixture.controlled(false,true); } else if (name === 'conflict') { await this.fixture.conflictNext(); }
      else if (name === 'valid') { await this.fixture.validNext(); } else if (name === 'reopen') { await this.fixture.reopen(); this.serviceEpoch++; }
       else if (name === 'restore') { await this.fixture.restoreReport(); } else if (name === 'pause') { this.fixture.service.pause(); }
       else if (name === 'parse-error') { await this.fixture.injectParseFailure(); }
      else if (name === 'vectors') { const consent: boolean = this.vectorConsent; this.vectorConsent = false; await this.fixture.controlledVectors(consent); }
      else if (name === 'hold') { this.fixture.holdNext(); } else if (name === 'release') { this.fixture.releaseLate(); }
      this.statusText = this.fixture.status;
    } catch { this.statusText = 'Fixture action rejected; existing state retained'; }
  }
  private async source(document: ImageDocument, hit?: KnowledgeHit): Promise<void> { this.mode = 'source'; try { await this.fixture.openSource(document,hit); } catch { this.statusText = 'Source failed or pending release'; } }
  private async openHit(hit: KnowledgeHit): Promise<void> { const document = await this.fixture.images.get(hit.documentId); if (document !== undefined) { await this.source(document,hit); } }
  aboutToDisappear(): void { this.fixture.service.pause(); this.fixture.workflow.pause(); this.fixture.source.pause(); this.fixture.source.close().catch((): void => {}); }
  build() {
    Column({ space: 8 }) {
      Text(`${this.fixture.caseId} · 隔离机制 fixture · OCR/向量非质量证据`).fontSize(14)
       Text(this.statusText).id('m3-fixture-status')
       Button('注入隔离解析错误').id('image-happy-inject-error').onClick((): void => { this.action('parse-error'); })
      Row({ space: 6 }) {
        Button('关闭').id('m3-fixture-close').onClick((): void => { this.onBack(); })
        Button('导入与管理').id('m3-fixture-ingestion').onClick((): void => { this.mode = 'ingestion'; })
        Button('检索与历史').id('m3-fixture-search').onClick((): void => { this.mode = 'search'; })
      }
      Row({ space: 8 }) {
        Checkbox().id('m3-fixture-vector-consent').select(this.vectorConsent).onChange((checked: boolean): void => { this.vectorConsent = checked; })
        Text('仅本机受控文本向量').fontSize(12)
        Button('核向量读回').id('m3-fixture-vectors').onClick((): void => { this.action('vectors'); })
      }
      Row({ space: 6 }) {
        Button('有效输入').id('m3-fixture-valid').onClick((): void => { this.action('valid'); })
        Button('冲突输入').id('m3-fixture-conflict').onClick((): void => { this.action('conflict'); })
        Button('受控文字').id('m3-fixture-ocr').onClick((): void => { this.action('ocr'); })
        Button('受控无字').id('m3-fixture-empty').onClick((): void => { this.action('empty'); })
      }
      Row({ space: 6 }) {
        Button('非法覆盖').id('m3-fixture-invalid').onClick((): void => { this.action('invalid'); })
        Button('暂停').id('m3-fixture-pause').onClick((): void => { this.action('pause'); })
        Button('重建服务').id('m3-fixture-reopen').onClick((): void => { this.action('reopen'); })
        Button('恢复报告').id('m3-fixture-restore').onClick((): void => { this.action('restore'); })
      }
      Row({ space: 8 }) { Button('延后下次规范化').id('m3-fixture-hold-next').onClick((): void => { this.action('hold'); }); Button('释放晚到工作').id('m3-fixture-release-late').onClick((): void => { this.action('release'); }) }
      if (this.mode === 'source') { ImageSourceView({ session: this.fixture.source, onBack: (): void => { this.mode = 'ingestion'; } }) }
      else if (this.mode === 'search') { KnowledgeView({ textState: this.emptyTextState, service: this.fixture.search, embedding: this.fixture.embedding, semantic: this.fixture.workflow, initialSpace: this.fixture.selectedSpace, isolated: true, onOpenHit: (hit: KnowledgeHit): void => { this.openHit(hit); } }) }
      else if (this.serviceEpoch%2 === 0) { ImageIngestionView({ service: this.fixture.service, embedding: this.fixture.embedding, onOriginal: (document: ImageDocument): void => { this.source(document); }, onBack: (): void => { this.onBack(); } }) }
      else { ImageIngestionView({ service: this.fixture.service, embedding: this.fixture.embedding, onOriginal: (document: ImageDocument): void => { this.source(document); }, onBack: (): void => { this.onBack(); } }) }
    }.width('100%')
  }
}
