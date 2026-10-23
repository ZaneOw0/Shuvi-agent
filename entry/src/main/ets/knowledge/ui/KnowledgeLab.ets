import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Theme } from '../../components/Theme';
import { SAMPLE_CORPUS } from '../domain/SampleCorpus';
import {
  CapabilityReport, DeleteOutcome, IndexOutcome, KnowledgeCounts, KnowledgeHit, ProbeStep
} from '../domain/KnowledgeTypes';
import { RdbKnowledgeStore } from '../infra/RdbKnowledgeStore';
import { probeCapabilities } from '../probe/KnowledgeProbe';

const DOMAIN: number = 0xD001;
const TAG: string = 'KnowledgeLab';
const DEFAULT_QUERY: string = '分块重叠';
const MISS_QUERY: string = '如何申请年假';
const DELETED_DOC_QUERY: string = '云空间版本';

@Component
export struct KnowledgeLab {
  @State busy: boolean = false;
  @State lines: string[] = [];
  @State query: string = DEFAULT_QUERY;
  private store: RdbKnowledgeStore | undefined = undefined;

  aboutToAppear(): void {
    this.runFlow('自检');
  }

  private log(line: string): void {
    this.lines = this.lines.concat([line]);
    hilog.info(DOMAIN, TAG, '%{public}s', line);
  }

  private async openStore(): Promise<RdbKnowledgeStore> {
    const existing: RdbKnowledgeStore | undefined = this.store;
    if (existing !== undefined) {
      return existing;
    }
    const context: common.Context | undefined = this.getUIContext().getHostContext();
    if (context === undefined) {
      throw new Error('host context is undefined');
    }
    const created: RdbKnowledgeStore = new RdbKnowledgeStore(context);
    await created.open();
    this.store = created;
    return created;
  }

  private async runFlow(label: string): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.lines = [];
    const context: common.Context | undefined = this.getUIContext().getHostContext();
    if (context === undefined) {
      this.log('失败：host context 为空');
      this.busy = false;
      return;
    }
    await this.runProbe(context);
    try {
      const store: RdbKnowledgeStore = await this.openStore();
      const steps = store.ddlSteps();
      for (let i = 0; i < steps.length; i++) {
        this.log(`DDL ${steps[i].ok ? 'OK ' : 'FAIL'} ${steps[i].name} ${steps[i].detail}`);
      }
      this.log(`存储 打开=${store.openedName()} 向量=${store.isVectorEnabled()} 倒排=${store.invertedMode()} 降级=${store.degraded().length > 0 ? store.degraded() : 'none'}`);
      if (label === '自检') {
        await store.clearAll();
        for (let i = 0; i < SAMPLE_CORPUS.length; i++) {
          const outcome: IndexOutcome = await store.ingest(SAMPLE_CORPUS[i]);
          this.log(`索引 ${outcome.title}：chunk=${outcome.chunkCount} vector=${outcome.vectorCount} doc=${outcome.documentId}`);
        }
        await this.reportCounts('导入后');
        const diagnosis: string = await store.invertedDiagnostics();
        this.log(`倒排诊断 ${diagnosis}`);
        const ftsSteps = store.ddlSteps();
        for (let i = 0; i < ftsSteps.length; i++) {
          if (ftsSteps[i].name === 'fts-write') {
            this.log(`倒排写入 ${ftsSteps[i].ok ? 'OK ' : 'FAIL'} ${ftsSteps[i].detail}`);
          }
        }
        await this.runQuery('命中题「分块重叠」', DEFAULT_QUERY);
        await this.runQuery('无答案题「如何申请年假」', MISS_QUERY);
        const ids: string[] = await store.listDocumentIds();
        if (ids.length > 0) {
          const target: string = ids[ids.length - 1];
          const outcome: DeleteOutcome = await store.deleteDocuments([target]);
          this.log(`删除 doc=${target}：documents=${outcome.documents} chunks=${outcome.chunks} fts=${outcome.invertedDirective}`);
          await this.reportCounts('删除后');
          await this.runQuery('删除后复查「云空间版本」', DELETED_DOC_QUERY);
          const orphans: number = await store.reconcile();
          this.log(`对账：回收孤儿块=${orphans}`);
        }
        this.log('S1 说明：向量为探测用伪向量，只验证机制，不作为检索质量结论');
      } else {
        await this.reportCounts('当前');
        await this.runQuery('查询', this.query);
      }
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      this.log(`链路失败 ${businessError.code} ${businessError.message}`);
      hilog.error(DOMAIN, TAG, '%{public}s', `pipeline failed ${businessError.code} ${businessError.message}`);
    }
    this.busy = false;
  }

  private async runProbe(context: common.Context): Promise<void> {
    try {
      const report: CapabilityReport = await probeCapabilities(context);
      for (let i = 0; i < report.steps.length; i++) {
        const step: ProbeStep = report.steps[i];
        this.log(`探测 ${step.ok ? 'OK ' : 'FAIL'} ${step.name} = ${step.detail}`);
      }
      this.log(`探测 检索降级路径 = ${report.searchPath}`);
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      this.log(`探测失败 ${businessError.code} ${businessError.message}`);
    }
  }

  private async reportCounts(label: string): Promise<void> {
    const store: RdbKnowledgeStore = await this.openStore();
    const counts: KnowledgeCounts = await store.counts();
    this.log(`统计[${label}] 文档=${counts.documents} 块=${counts.chunks} 倒排=${counts.invertedRows} 向量=${counts.vectorRows} 孤儿=${counts.orphans} 沙箱文件=${counts.sandboxFiles}`);
  }

  private async runQuery(label: string, query: string): Promise<void> {
    const store: RdbKnowledgeStore = await this.openStore();
    const hits: KnowledgeHit[] = await store.search(query, 3);
    this.log(`检索[${label}] hits=${hits.length}`);
    for (let i = 0; i < hits.length; i++) {
      const hit: KnowledgeHit = hits[i];
      const preview: string = hit.text.length > 40 ? hit.text.substring(0, 40) : hit.text;
      this.log(`  #${i + 1} ${hit.channel} rrf=${hit.rrfScore.toFixed(4)} distance=${hit.distance.toFixed(4)} ${hit.documentTitle} | ${preview}`);
    }
  }

  build() {
    Column({ space: 12 }) {
      Column({ space: 8 }) {
        Text('知识库链路验证').fontSize(22).fontWeight(FontWeight.Bold).fontColor(Theme.ink)
        Text('S1 机制验证：原文 → 文档 → 分块 → 索引；问题 → 检索 → 向量 → 片段。向量为探测用伪向量。')
          .fontSize(12).fontColor(Theme.muted).lineHeight(18)
      }.width('100%').alignItems(HorizontalAlign.Start).margin({ top: 12 })

      Row({ space: 8 }) {
        Button(this.busy ? '运行中' : '重跑自检', { type: ButtonType.Normal }).fontSize(13)
          .fontColor(Color.White).backgroundColor(Theme.accent).borderRadius(10)
          .constraintSize({ minHeight: 40 }).layoutWeight(1).enabled(!this.busy)
          .onClick(() => this.runFlow('自检'))
        Button('统计', { type: ButtonType.Normal }).fontSize(13).fontColor(Theme.accent)
          .backgroundColor(Theme.soft).borderRadius(10).constraintSize({ minHeight: 40 }).layoutWeight(1)
          .enabled(!this.busy).onClick(() => this.runFlow('统计'))
      }.width('100%')

      Row({ space: 8 }) {
        TextInput({ text: this.query, placeholder: '输入检索问题' })
          .fontSize(13).layoutWeight(1).backgroundColor(Theme.surface)
          .onChange((value: string) => {
            this.query = value;
          })
        Button('检索', { type: ButtonType.Normal }).fontSize(13).fontColor(Color.White)
          .backgroundColor(Theme.accent).borderRadius(10).constraintSize({ minHeight: 40 })
          .enabled(!this.busy).onClick(() => this.runFlow('查询'))
      }.width('100%')

      Column({ space: 6 }) {
        ForEach(this.lines, (line: string, index: number) => {
          Text(line).fontSize(12).fontColor(Theme.ink).lineHeight(18)
            .width('100%').textAlign(TextAlign.Start)
        }, (line: string, index: number) => `${index}-${line}`)
      }.width('100%').padding(12).backgroundColor(Theme.surface).borderRadius(12)

      Text('日志同时写入 hilog（domain 0xD001 / tag KnowledgeLab），可作为本次模拟器验证记录。')
        .fontSize(11).fontColor(Theme.muted).width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ bottom: 24 })
  }
}
