/*
 * Original entry template Copyright (c) 2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
import { KeyboardAvoidMode } from '@kit.ArkUI';
import { Theme } from '../components/Theme';
import { AssistantWelcome, CalendarDraftCard, ChatIcon } from '../components/ChatVisuals';
import { WorkbenchPage, KnowledgePage, ProfilePage } from '../components/FeaturePages';
import {
  AssistantService, CalendarDraft, ChatMessage, DEMO_SCENARIOS, DemoScenario,
  OperationResult, OperationState, RequestState
} from '../model/AssistantModels';
import { MockAssistantService } from '../mock/MockAssistantService';

@Entry
@Component
struct Index {
  @State tab: number = 0;
  @State calendarOpen: boolean = false;
  @State input: string = '';
  @State messages: ChatMessage[] = [];
  @State draft: CalendarDraft | undefined = undefined;
  @State result: OperationResult | undefined = undefined;
  @State records: OperationResult[] = [];
  @State generating: boolean = false;
  @State executing: boolean = false;
  @State requestState: RequestState = RequestState.Unsupported;
  @State scenario: DemoScenario = DemoScenario.Normal;
  @State showScenarios: boolean = false;
  @State drawerOpen: boolean = false;
  @State contentHeight: number = 0;
  private service: AssistantService = new MockAssistantService();
  private requestId: string = '';
  private operationId: string = '';
  private alive: boolean = true;
  private scroller: Scroller = new Scroller();
  private inputController: TextAreaController = new TextAreaController();
  private tabNames: string[] = ['助手', '工作台', '知识库', '我的'];
  private tabIcons: Resource[] = [
    $r('app.media.chat_chat'), $r('app.media.chat_grid'), $r('app.media.chat_book'), $r('app.media.chat_user')
  ];

  aboutToAppear(): void {
    this.alive = true;
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
  }

  aboutToDisappear(): void {
    this.alive = false;
    this.service.cancel(this.requestId);
  }

  onBackPress(): boolean {
    if (this.drawerOpen) {
      this.drawerOpen = false;
      return true;
    }
    if (this.showScenarios) {
      this.showScenarios = false;
      return true;
    }
    if (this.calendarOpen) {
      this.calendarOpen = false;
      return true;
    }
    if (this.tab !== 0) {
      this.changeTab(0);
      return true;
    }
    return false;
  }

  private notice(title: string, message: string): void {
    this.inputController.stopEditing();
    this.getUIContext().showAlertDialog({
      title: title, message: message,
      primaryButton: { value: '知道了', action: () => {} }
    });
  }

  private changeTab(index: number): void {
    if (index !== this.tab && this.generating) {
      this.cancelGeneration();
    }
    this.inputController.stopEditing();
    this.tab = index;
    this.calendarOpen = false;
    this.showScenarios = false;
    this.drawerOpen = false;
    this.scroller.scrollEdge(Edge.Top);
  }

  private addMessage(text: string, isUser: boolean = false): void {
    const message: ChatMessage = { id: this.service.nextId('message'), isUser: isUser, text: text };
    this.messages = this.messages.concat([message]);
  }

  private blocked(): boolean {
    return this.generating || this.executing || this.draft !== undefined;
  }

  private useSample(): void {
    if (this.blocked()) {
      return;
    }
    this.input = this.service.sampleText;
    this.scroller.scrollEdge(Edge.Bottom);
  }

  private async send(): Promise<void> {
    if (this.blocked() || this.input.trim().length === 0 || this.input.length > 500) {
      return;
    }
    const id = this.service.nextId('request');
    this.requestId = id;
    this.result = undefined;
    this.generating = true;
    this.requestState = RequestState.Unsupported;
    this.inputController.stopEditing();
    this.addMessage(this.input, true);
    const selected = this.scenario;
    // Execution scenarios remain selected until confirmation.
    if (selected === DemoScenario.ModelFailure || selected === DemoScenario.InvalidDraft ||
      selected === DemoScenario.Clarification || selected === DemoScenario.GenerationTimeout) {
      this.scenario = DemoScenario.Normal;
    }
    try {
      const reply = await this.service.generate(id, this.input, selected);
      if (!this.alive || this.requestId !== id) {
        return;
      }
      this.generating = false;
      this.requestState = reply.state;
      this.draft = reply.draft;
      this.operationId = reply.draft ? this.service.nextId('operation') : '';
      this.addMessage(reply.message);
      this.scroller.scrollEdge(Edge.Bottom);
    } catch {
      if (this.alive && this.requestId === id) {
        this.generating = false;
        this.requestState = RequestState.Failed;
        this.addMessage('生成失败，输入已保留，请重试。');
      }
    }
  }

  private cancelGeneration(): void {
    this.service.cancel(this.requestId);
    this.requestId = '';
    this.generating = false;
    this.requestState = RequestState.Cancelled;
    this.addMessage('已取消生成，没有创建日程。');
  }

  private cancelDraft(rephrase: boolean = false): void {
    if (this.draft && !this.executing) {
      this.service.discard(this.draft.draftId);
      this.draft = undefined;
      this.result = undefined;
      this.operationId = '';
      if (!rephrase) {
        this.input = '';
      }
      this.addMessage('已取消草稿，没有新增演示日程。你可以修改输入后重新发送。');
    }
  }

  private openScenarios(): void {
    if (this.generating || this.executing) {
      return;
    }
    this.drawerOpen = false;
    this.inputController.stopEditing();
    this.showScenarios = !this.showScenarios;
    this.scroller.scrollEdge(Edge.Top);
  }

  private newConversation(): void {
    if (this.blocked()) {
      return;
    }
    this.inputController.stopEditing();
    if (this.messages.length === 0 && this.input.length === 0) {
      this.resetConversation();
      return;
    }
    this.getUIContext().showAlertDialog({
      title: '开始新对话？',
      message: '将清空当前对话和未发送文字，已确认的演示日程会保留。',
      primaryButton: { value: '继续当前对话', action: () => {} },
      secondaryButton: { value: '开始新对话', action: () => this.resetConversation() }
    });
  }

  private resetConversation(): void {
    if (this.blocked()) {
      return;
    }
    this.service.cancel(this.requestId);
    this.requestId = '';
    this.operationId = '';
    this.messages = [];
    this.input = '';
    this.result = undefined;
    this.requestState = RequestState.Unsupported;
    this.scenario = DemoScenario.Normal;
    this.changeTab(0);
  }

  private attachments(): void {
    this.inputController.stopEditing();
    this.getUIContext().showAlertDialog({
      title: '添加内容', message: '图片与文件输入待接入，本次不会读取设备内容。',
      primaryButton: { value: '图片 · 待接入', action: () => this.notice('图片输入待接入', '本次不会打开相册或读取图片。') },
      secondaryButton: { value: '文件 · 待接入', action: () => this.notice('文件输入待接入', '本次不会打开文件选择器或读取文件。') }
    });
  }

  private async confirm(): Promise<void> {
    if (!this.draft || this.executing) {
      return;
    }
    this.executing = true;
    const selected = this.scenario;
    this.scenario = DemoScenario.Normal;
    try {
      const outcome = await this.service.confirm(this.draft, this.operationId, selected);
      if (!this.alive) {
        return;
      }
      this.result = outcome;
      this.records = this.service.records();
      if (outcome.calendarCreated) {
        this.draft = undefined;
        this.input = '';
      }
    } catch {
      if (this.alive) {
        this.notice('模拟操作失败', '草稿已保留，请使用原操作重试。');
      }
    } finally {
      if (this.alive) {
        this.executing = false;
      }
    }
  }

  private async retryReminder(operationId: string): Promise<void> {
    if (this.executing) {
      return;
    }
    this.executing = true;
    try {
      const outcome = await this.service.retryReminder(operationId);
      if (this.alive) {
        this.result = outcome;
        this.records = this.service.records();
      }
    } catch {
      if (this.alive) {
        this.notice('提醒重试失败', '演示日程仍保留，请稍后再试。');
      }
    } finally {
      if (this.alive) {
        this.executing = false;
      }
    }
  }


  @Builder
  header() {
    Stack() {
      Column({ space: 2 }) {
        if (this.tab !== 0) {
          Text(this.tabNames[this.tab]).fontSize(14).fontColor(Theme.ink).fontWeight(FontWeight.Medium)
        }
        Text('演示模式').fontSize(11).fontColor(Theme.muted)
          .padding({ left: 9, right: 9, top: 5, bottom: 5 }).backgroundColor('#F5F7F4').borderRadius(20)
      }.width('34%')
      Row() {
        Button({ type: ButtonType.Circle }) {
          ChatIcon({ source: $r('app.media.chat_menu'), size: 24 })
        }.width(44).height(44).backgroundColor(Theme.surface)
          .shadow({ radius: 16, color: '#0A26392C', offsetY: 3 })
          .accessibilityText('打开导航菜单').id('chat-menu')
          .onClick(() => {
            this.inputController.stopEditing();
            this.drawerOpen = true;
          })
        Blank()
        Row() {
          Button({ type: ButtonType.Circle }) {
            ChatIcon({ source: $r('app.media.chat_sliders') })
          }.width(44).height(44).backgroundColor(Color.Transparent)
            .accessibilityText(`演示场景设置，当前${this.scenario}`).id('chat-scenarios')
            .enabled(!this.generating && !this.executing).onClick(() => this.openScenarios())
          Button({ type: ButtonType.Circle }) {
            ChatIcon({ source: $r('app.media.chat_newchat') })
          }.width(44).height(44).backgroundColor(Color.Transparent)
            .accessibilityText(this.blocked() ? '开始新对话，请先处理当前任务' : '开始新对话')
            .id('chat-new').enabled(!this.blocked()).opacity(this.blocked() ? 0.4 : 1)
            .onClick(() => this.newConversation())
        }.padding({ left: 3, right: 3 }).borderRadius(28).backgroundColor(Theme.surface)
          .shadow({ radius: 16, color: '#0A26392C', offsetY: 3 })
      }.width('100%')
    }.width('100%').constraintSize({ minHeight: 68 }).padding({ left: 16, right: 16, top: 12, bottom: 12 })
  }

  @Builder
  assistant() {
    Column({ space: 16 }) {
      ForEach(this.messages, (message: ChatMessage) => {
        if (message.isUser) {
          Row() {
            Blank().width('8%')
            Text(message.text).fontSize(15).fontColor(Theme.ink).padding(15)
              .backgroundColor(Theme.bubble).borderRadius({ topLeft: 20, topRight: 20, bottomLeft: 20, bottomRight: 6 })
              .constraintSize({ maxWidth: '92%' }).accessibilityText(`你：${message.text}`)
          }.width('100%').justifyContent(FlexAlign.End)
        } else {
          Row({ space: 8 }) {
            Text('休').fontSize(22).fontColor(Theme.accent).accessibilityLevel('no')
            Text(message.text).fontSize(14).fontColor(Theme.ink).layoutWeight(1)
              .accessibilityText(`休比：${message.text}`)
          }.width('100%').alignItems(VerticalAlign.Top)
        }
      }, (message: ChatMessage) => message.id)
      if (this.generating) {
        Row({ space: 10 }) {
          LoadingProgress().width(22).height(22).color(Theme.accent)
          Text('正在生成演示草稿…').fontSize(14).fontColor(Theme.muted).layoutWeight(1)
          Button('取消').fontSize(13).constraintSize({ minHeight: 44 })
            .backgroundColor(Theme.soft).fontColor(Theme.accent).onClick(() => this.cancelGeneration())
        }.width('100%')
      }
      if (this.result && !this.result.calendarCreated) {
        this.resultCard(this.result)
      }
      if (this.draft) {
        CalendarDraftCard({ draft: this.draft, executing: this.executing,
          failed: this.result !== undefined && !this.result.calendarCreated })
      }
      if (this.result && this.result.calendarCreated) {
        this.resultCard(this.result)
      }
      if (!this.blocked() && this.requestState === RequestState.Failed) {
        Button('重试生成').fontColor(Theme.accent).backgroundColor(Theme.soft).onClick(() => this.send())
      }
      if (!this.blocked() && this.requestState === RequestState.Clarification) {
        Button('取消澄清，使用完整样例').fontColor(Theme.accent).backgroundColor(Theme.soft)
          .onClick(() => {
            this.requestState = RequestState.Cancelled;
            this.addMessage('已取消本次澄清，请重新发送完整样例。');
            this.useSample();
          })
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 14, bottom: 20 })
  }

  @Builder
  draftDetails(draft: CalendarDraft) {
    Text(draft.title).fontSize(22).fontWeight(FontWeight.Medium).fontColor(Theme.ink)
    Text(`${draft.startAt.substring(0, 10)}  ${draft.startAt.substring(11, 16)}—${draft.endAt.substring(11, 16)}`)
      .fontSize(15).fontColor(Theme.ink)
    Text(`${draft.timeZone} · 提前 ${draft.reminderMinutesBefore} 分钟提醒`)
      .fontSize(12).fontColor(Theme.muted)
  }

  @Builder
  confirmationDock() {
    Column({ space: 8 }) {
      Text(this.executing ? '正在模拟执行，请稍候' : '请先确认或取消，再继续对话')
        .fontSize(11).fontColor(Theme.muted).textAlign(TextAlign.Center).width('100%')
      Button(this.executing ? '处理中…' : (this.result ? '重试创建（演示）' : '确认（演示）'), { type: ButtonType.Normal })
        .width('100%').constraintSize({ minHeight: 48 }).padding(12).borderRadius(16)
        .fontSize(15).fontColor(Color.White).backgroundColor(Theme.accent).enabled(!this.executing)
        .id('chat-confirm').onClick(() => this.confirm())
      Row() {
        Button('取消草稿', { type: ButtonType.Normal }).fontSize(13).fontColor(Theme.muted)
          .layoutWeight(1).constraintSize({ minHeight: 44 }).backgroundColor(Color.Transparent)
          .enabled(!this.executing).onClick(() => this.cancelDraft())
        Divider().vertical(true).height(14).color(Theme.line)
        Button('重新描述', { type: ButtonType.Normal }).fontSize(13).fontColor(Theme.accent)
          .layoutWeight(1).constraintSize({ minHeight: 44 }).backgroundColor(Color.Transparent)
          .enabled(!this.executing).onClick(() => this.cancelDraft(true))
      }.width('100%')
    }.width('100%').padding({ left: 20, right: 20, top: 12, bottom: 8 })
      .backgroundColor(Theme.surface).border({ width: { top: 1 }, color: Theme.line })
  }

  @Builder
  resultCard(result: OperationResult) {
    Column({ space: 10 }) {
      Text(result.state === OperationState.Success ? '演示完成' :
        (result.state === OperationState.Partial ? '部分完成 · 提醒待重试' : '本次未完成'))
        .fontSize(16).fontWeight(FontWeight.Bold).fontColor(Theme.ink)
      if (result.calendarCreated && !this.calendarOpen) {
        this.draftDetails(result.draft)
      }
      Text(result.message).fontSize(13).lineHeight(21).fontColor(Theme.muted)
      Text(`日程：${result.calendarCreated ? '已模拟创建' : '未创建'}\n提醒：${result.reminderRegistered ? '已模拟注册，不会送达' : '未注册'}`)
        .fontSize(12).lineHeight(21).fontColor(Theme.muted)
      if (result.state === OperationState.Partial) {
        Button(this.executing ? '处理中…' : '重试提醒（演示）').fontSize(13)
          .fontColor(Theme.accent).backgroundColor(Theme.soft).enabled(!this.executing)
          .onClick(() => this.retryReminder(result.operationId))
      }
      if (result.calendarCreated && !this.calendarOpen) {
        Button('查看演示日程 →').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft)
          .onClick(() => {
            this.changeTab(1);
            this.calendarOpen = true;
          })
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(18)
      .backgroundColor(result.state === OperationState.Success ? Theme.soft : Theme.warning).borderRadius(16)
  }

  @Builder
  calendar() {
    Column({ space: 16 }) {
      Button('‹ 返回工作台').fontSize(13).fontColor(Theme.accent).backgroundColor(Color.Transparent)
        .onClick(() => this.calendarOpen = false)
      Text('演示日程').fontSize(28).fontWeight(FontWeight.Bold).fontColor(Theme.ink)
      Text('仅保留本次演示数据，退出重启后重置。').fontSize(12).fontColor(Theme.muted)
      if (this.records.length === 0) {
        Column({ space: 16 }) {
          Text('还没有安排').fontSize(20).fontColor(Theme.ink)
          Text('从一条样例开始，体验日程确认流程。').fontSize(13).fontColor(Theme.muted)
          Button('去助手创建').backgroundColor(Theme.accent).fontColor(Color.White)
            .onClick(() => {
              this.changeTab(0);
              if (!this.blocked()) {
                this.useSample();
              }
            })
        }.width('100%').padding({ top: 48, bottom: 48 })
      }
      ForEach(this.records, (record: OperationResult) => {
        Column({ space: 12 }) {
          this.draftDetails(record.draft)
          this.resultCard(record)
        }.width('100%').alignItems(HorizontalAlign.Start).padding(16)
          .backgroundColor(Theme.surface).borderRadius(18)
      }, (record: OperationResult) => `${record.operationId}-${record.reminderRegistered}`)
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ bottom: 24 })
  }

  @Builder
  scenarioPanel() {
    Column({ space: 10 }) {
      Text('选择下一次演示场景').fontSize(17).fontWeight(FontWeight.Bold).fontColor(Theme.ink)
      Text('仅模拟界面状态，不改变系统设置。场景执行后恢复正常；提醒重试默认成功。')
        .fontSize(12).fontColor(Theme.muted).lineHeight(20)
      ForEach(DEMO_SCENARIOS, (item: DemoScenario) => {
        Button(item === this.scenario ? `✓ ${item}` : item, { type: ButtonType.Normal })
          .width('100%').constraintSize({ minHeight: 44 }).fontSize(14).borderRadius(10)
          .backgroundColor(item === this.scenario ? Theme.accent : Theme.surface)
          .fontColor(item === this.scenario ? Color.White : Theme.ink)
          .onClick(() => {
            this.scenario = item;
            this.showScenarios = false;
          })
      }, (item: DemoScenario) => item)
      Button('返回页面').fontColor(Theme.accent).backgroundColor(Theme.soft)
        .onClick(() => this.showScenarios = false)
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ bottom: 20 })
  }

  @Builder
  composer() {
    Column({ space: 8 }) {
      Column({ space: 8 }) {
        TextArea({ text: this.input, placeholder: '发消息，或说说你的想法…', controller: this.inputController })
          .fontSize(15).fontColor(Theme.ink).placeholderColor(Theme.muted).backgroundColor(Color.Transparent)
          .height(64).width('100%').padding({ left: 6, right: 6, top: 4, bottom: 4 })
          .enabled(!this.blocked()).onChange((value: string) => this.input = value)
          .accessibilityText('写下想做的事，最多 500 字').id('chat-input')
        Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween, alignItems: ItemAlign.Center }) {
          Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
            Button({ type: ButtonType.Normal }) {
              Row({ space: 4 }) {
                ChatIcon({ source: $r('app.media.chat_calendar'), size: 16})
                Text('日程样例').fontSize(12).fontColor(Theme.accent)
              }.padding({ left: 8, right: 8, top: 9, bottom: 9 }).constraintSize({ minHeight: 44 })
            }.borderRadius(22).backgroundColor(Theme.soft).border({ width: 1, color: '#DCE9DF' })
              .margin({ right: 4, bottom: 4 }).enabled(!this.blocked()).onClick(() => this.useSample())
              .id('chat-sample').accessibilityText('日程样例，填入固定演示文字')
            Button({ type: ButtonType.Normal }) {
              Row({ space: 4 }) {
                ChatIcon({ source: $r('app.media.chat_globe'), size: 16})
                Text('搜索').fontSize(12).fontColor(Theme.muted)
              }.padding({ left: 8, right: 8, top: 9, bottom: 9 }).constraintSize({ minHeight: 44 })
            }.borderRadius(22).backgroundColor(Color.Transparent).border({ width: 1, color: Theme.line })
              .margin({ bottom: 4 }).accessibilityText('联网搜索，待接入')
              .onClick(() => this.notice('联网搜索待接入', '本次不会发起网络请求。请使用日程样例体验确认流程。'))
          }
          Row() {
            Button({ type: ButtonType.Circle }) {
              ChatIcon({ source: $r('app.media.chat_plus'), size: 26 })
            }.width(44).height(44).backgroundColor(Color.Transparent).onClick(() => this.attachments())
              .accessibilityText('添加图片或文件，待接入')
            if (this.input.trim().length > 0) {
              Button({ type: ButtonType.Circle }) {
                ChatIcon({ source: $r('app.media.chat_up'), size: 22})
              }.width(44).height(44).backgroundColor(Theme.accent).accessibilityText('发送消息').id('chat-send')
                .enabled(!this.blocked() && this.input.length <= 500).onClick(() => this.send())
            } else {
              Button({ type: ButtonType.Circle }) {
                ChatIcon({ source: $r('app.media.chat_wave'), size: 26 })
              }.width(44).height(44).backgroundColor(Color.Transparent).accessibilityText('语音输入，待接入')
                .onClick(() => this.notice('语音输入待接入', '本次不会开启麦克风或录音。请使用日程样例体验确认流程。'))
            }
          }.margin({ bottom: 4 })
        }.width('100%')
        if (this.input.length >= 400) {
          Text(`${this.input.length} / 500`).fontSize(11)
            .fontColor(this.input.length > 500 ? Theme.danger : Theme.muted).width('100%').textAlign(TextAlign.End)
        }
      }.width('100%').padding({ left: 10, right: 10, top: 12, bottom: 6 })
        .backgroundColor(Theme.inputSurface).borderRadius(26)
        .border({ width: 1, color: this.input.length > 500 ? Theme.danger : Theme.line })
      if (this.input.length > 500) {
        Text('最多 500 字，请缩短后发送。').fontSize(12).fontColor(Theme.danger).width('100%')
      }
      Text('演示数据 · 重启后重置 · 图片与语音待接入').fontSize(10).fontColor(Theme.muted)
        .textAlign(TextAlign.Center).width('100%')
    }.padding({ left: 12, right: 12, top: 8, bottom: 12 }).width('100%').backgroundColor(Theme.surface)
  }

  @Builder
  navigationDrawer() {
    Column() {
      Row({ space: 8 }) {
        Column({ space: 6 }) {
          Text('Shuvi 休比').fontSize(22).fontWeight(FontWeight.Medium).fontColor(Theme.ink)
          Text('个人助理 · 演示模式').fontSize(12).fontColor(Theme.muted)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button('×', { type: ButtonType.Circle }).width(44).height(44).fontSize(28)
          .fontColor(Theme.muted).backgroundColor(Color.Transparent).accessibilityText('关闭导航菜单')
          .onClick(() => this.drawerOpen = false)
      }.width('100%').padding({ bottom: 24 })
      Scroll() {
        Column({ space: 8 }) {
          ForEach(this.tabNames, (name: string, index: number) => {
            Button({ type: ButtonType.Normal }) {
              Row({ space: 12 }) {
                ChatIcon({ source: this.tabIcons[index]})
                Text(name).fontSize(16).fontColor(this.tab === index ? Theme.accent : Theme.muted).layoutWeight(1)
                if (index === 0 && this.draft !== undefined) {
                  Text(this.executing ? '处理中' : '待确认').fontSize(11).fontColor(Theme.amber)
                }
                if (index === 1 && this.records.length > 0) {
                  Text(`${this.records.length}`).fontSize(12).fontColor(Theme.accent)
                    .accessibilityText(`${this.records.length} 条演示日程`)
                }
              }.width('100%').padding(14).constraintSize({ minHeight: 52 })
            }.width('100%').borderRadius(15).backgroundColor(this.tab === index ? Theme.soft : Color.Transparent)
              .accessibilityText(`${name}${this.tab === index ? '，已选中' : ''}`).onClick(() => this.changeTab(index))
          }, (name: string) => name)
        }.width('100%')
      }.width('100%').layoutWeight(1).align(Alignment.Top).scrollBar(BarState.Auto)
      Button('演示场景设置  ›', { type: ButtonType.Normal }).width('100%').constraintSize({ minHeight: 44 })
        .fontSize(13).fontColor(Theme.accent).backgroundColor(Color.Transparent)
        .enabled(!this.generating && !this.executing).onClick(() => this.openScenarios())
      Text('当前仅支持固定样例\n演示数据会在重启后重置').fontSize(11).fontColor(Theme.muted)
        .width('100%').padding({ top: 16 })
    }.width('100%').height('100%').padding({ left: 18, right: 18, top: 28, bottom: 24 })
      .backgroundColor(Theme.inputSurface).borderRadius({ topRight: 26, bottomRight: 26 })
  }

  @Builder
  pageContent() {
    Column() {
      this.header()
      if (this.scenario !== DemoScenario.Normal) {
        Text(`下一次演示：${this.scenario}`).fontSize(12).fontColor(Theme.amber)
          .width('100%').textAlign(TextAlign.Center).padding({ left: 16, right: 16, bottom: 8 })
      }
      Scroll(this.scroller) {
        Column() {
          if (this.showScenarios) {
            this.scenarioPanel()
          } else if (this.tab === 0) {
            if (this.messages.length === 0) {
              AssistantWelcome()
            } else {
              this.assistant()
            }
          } else if (this.tab === 1) {
            if (this.calendarOpen) {
              this.calendar()
            } else {
              WorkbenchPage({ recordCount: this.records.length,
                onCalendar: () => this.calendarOpen = true,
                onNotice: (title: string, message: string) => this.notice(title, message) })
            }
          } else if (this.tab === 2) {
            KnowledgePage({ onNotice: (title: string, message: string) => this.notice(title, message) })
          } else {
            ProfilePage({ onNotice: (title: string, message: string) => this.notice(title, message) })
          }
        }.width('100%').constraintSize({ maxWidth: 640,
          minHeight: this.tab === 0 && this.messages.length === 0 && !this.showScenarios ? this.contentHeight : 0 })
          .justifyContent(FlexAlign.Center).padding({ left: 20, right: 20 })
      }.width('100%').layoutWeight(1).align(Alignment.Top).scrollBar(BarState.Auto)
        .onAreaChange((_oldArea: Area, area: Area) => this.contentHeight = Number(area.height))
      if (this.tab === 0 && !this.showScenarios) {
        if (this.draft) {
          this.confirmationDock()
        } else {
          this.composer()
        }
      }
    }.width('100%').height('100%').backgroundColor(Theme.paper)
  }

  build() {
    SideBarContainer(SideBarContainerType.Overlay) {
      Column() {
        this.navigationDrawer()
      }
      Stack() {
        Column() {
          this.pageContent()
        }.width('100%').height('100%').enabled(!this.drawerOpen)
          .accessibilityLevel(this.drawerOpen ? 'no-hide-descendants' : 'auto')
        if (this.drawerOpen) {
          Button({ type: ButtonType.Normal }) {
            Row().width('100%').height('100%')
          }.width('100%').height('100%').backgroundColor('#33232E28').borderRadius(0)
            .accessibilityText('关闭导航菜单').onClick(() => this.drawerOpen = false)
        }
      }
    }.width('100%').height('100%').showSideBar(this.drawerOpen).showControlButton(false)
      .sideBarWidth('84%').minSideBarWidth(200).maxSideBarWidth(320).minContentWidth(0)
      .divider({ strokeWidth: 0 }).onChange((visible: boolean) => this.drawerOpen = visible)
      .backgroundColor(Theme.paper)
  }
}
