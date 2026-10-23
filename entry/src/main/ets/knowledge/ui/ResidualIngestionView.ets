import { ResidualIngestionFixture } from '../platformtests/ResidualIngestionFixture';
import { PdfIngestionView } from './PdfIngestionView';
import { KnowledgeCallbackListener } from '../domain/KnowledgePorts';
@Component
export struct ResidualIngestionView {
  fixture: ResidualIngestionFixture | undefined = undefined;
  onBack: () => void = (): void => {};
  @State outcome: string = 'Ready'; @State currentJob: string = '';
  private listener = new KnowledgeCallbackListener((): void => { this.currentJob = this.fixture?.service.state.job?.id ?? ''; });
  aboutToAppear(): void { this.fixture?.service.subscribe(this.listener); }
  aboutToDisappear(): void { this.fixture?.service.unsubscribe(this.listener); }
  private async action(kind: string): Promise<void> {
    if (this.fixture === undefined) { return; }
    try { if (kind === 'A' || kind === 'B') { await this.fixture.start(kind); }
      else if (kind === 'failB') { this.fixture.failNext(); await this.fixture.start('B'); }
      else if (kind === 'block') { this.fixture.blockPublish(); }
      else if (kind === 'release') { this.fixture.releasePublish(); }
      else if (kind === 'delete') { await this.fixture.deleteCurrent(); }
      else if (kind === 'retire') { await this.fixture.retireOld(); }
      else { await this.fixture.remember(kind); }
      this.currentJob = this.fixture.service.state.job?.id ?? ''; this.outcome = `PASS ${kind}`;
    } catch { this.outcome = `FAIL ${kind}`; }
  }
  build() {
    Column({ space: 10 }) {
      Text(this.outcome).id('r2-r007-status')
      Text(this.currentJob).id('r2-r007-current-job')
      Row() { Button('准备 A').id('r2-r007-A').onClick((): void => { this.action('A'); }); Button('准备 B（首读失败）').id('r2-r007-failB').onClick((): void => { this.action('failB'); }); Button('准备 B').id('r2-r007-B').onClick((): void => { this.action('B'); }) }
      Row() { Button('核初次发布').id('r2-r007-initial').onClick((): void => { this.action('initial'); }); Button('核旧活动保留').id('r2-r007-candidate').onClick((): void => { this.action('candidate'); }); Button('核切换').id('r2-r007-switched').onClick((): void => { this.action('switched'); }) }
      Button('核恢复不重复').id('r2-r007-resumed').onClick((): void => { this.action('resumed'); })
      Row() { Button('阻塞下次提交').id('r2-r007-block').onClick((): void => { this.action('block'); }); Button('释放提交').id('r2-r007-release').onClick((): void => { this.action('release'); }); Button('删除本样例').id('r2-r007-delete').onClick((): void => { this.action('delete'); }) }
      Row() { Button('清理旧 Retained').id('r2-r007-retire').onClick((): void => { this.action('retire'); }); Button('核放弃与来源').id('r2-r007-abandoned').onClick((): void => { this.action('abandoned'); }); Button('核删除竞争').id('r2-r007-race').onClick((): void => { this.action('race'); }) }
      Button('核发布后删除').id('r2-r007-deletedAfter').onClick((): void => { this.action('deletedAfter'); })
      Button('返回诊断').id('r2-r007-back').onClick(this.onBack)
      PdfIngestionView({ service: this.fixture?.service,lifecycle: this.fixture?.lifecycle,onBack: this.onBack })
    }.width('100%')
  }
}
