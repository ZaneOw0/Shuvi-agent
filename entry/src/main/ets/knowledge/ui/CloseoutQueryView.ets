import { CloseoutQueryFixture } from '../platformtests/CloseoutQueryFixture';
import { TextViewState } from '../domain/TextKnowledgeModels';
import { KnowledgeView } from './KnowledgeView';
@Component
export struct CloseoutQueryView {
  fixture: CloseoutQueryFixture | undefined = undefined;
  onBack: () => void = (): void => {};
  @State textState: TextViewState = new TextViewState();
  @State outcome: string = 'NotChecked';
  private async audit(): Promise<void> { try { if (this.fixture === undefined) { return; } await this.fixture.audit(); this.outcome = 'NoRequestPASS'; } catch { this.outcome = 'NoRequestFAIL'; } }
  build() {
    Column({ space: 12 }) {
      Button('核验无新增授权与调用').id('r2-consent-ui-audit').onClick((): void => { this.audit(); })
      Text(this.outcome).id('r2-consent-ui-summary')
      Button('返回诊断').id('r2-consent-ui-back').onClick(this.onBack)
      if (this.fixture !== undefined) { KnowledgeView({ service: this.fixture.search,embedding: this.fixture.embedding,semantic: this.fixture.workflow,documentsPort: this.fixture.source.pdf,textState: this.textState,initialTrialJob: this.fixture.job,initialSpace: this.fixture.space }) }
    }.width('100%')
  }
}
