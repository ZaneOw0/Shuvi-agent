import util from '@ohos.util';
import { DEBUG } from 'BuildProfile';
import { Theme } from './Theme';
import { ShuviRuntimeService } from '../services/model/ShuviRuntimeService';
import { ShuviRuntimeState } from '../services/model/ShuviRuntimeController';
import { runtimeStartupFactory } from '../services/model/RuntimeStartupAssembly';

@Component
export struct RuntimeStartupCheck {
  @State apiKey: string = '';
  @State state: ShuviRuntimeState = ShuviRuntimeState.IDLE;
  @State message: string = '尚未启动。';

  aboutToAppear(): void {
    ShuviRuntimeService.session.attach((state: ShuviRuntimeState): void => {
      this.apiKey = '';
      this.state = state;
      this.message = this.describe(state);
    });
  }
  aboutToDisappear(): void {
    this.apiKey = '';
    ShuviRuntimeService.session.detach();
    void ShuviRuntimeService.session.stop().catch((): void => {});
  }
  private describe(state: ShuviRuntimeState): string {
    switch (state) {
      case ShuviRuntimeState.STARTING: return '正在打开加密库、连接搜索服务并创建 Runtime…';
      case ShuviRuntimeState.READY: return '启动检查通过：加密库、搜索工具目录与 Runtime 已就绪。尚未验证 Key 或执行任务。';
      case ShuviRuntimeState.STOPPING: return '正在关闭会话并清除凭据…';
      case ShuviRuntimeState.STOPPED: return '会话已关闭；再次检查需要重新输入 Key。';
      case ShuviRuntimeState.FAILED: return '启动失败。请检查搜索服务和 HDC 转发；若连接检查通过，再排查数据库与模块配置。';
      case ShuviRuntimeState.BLOCKED: return '资源关闭失败，已禁止重新启动。请重启应用后排查，不要删除数据库。';
      default: return '尚未启动。';
    }
  }
  private canStart(): boolean {
    return this.state === ShuviRuntimeState.IDLE || this.state === ShuviRuntimeState.STOPPED ||
      this.state === ShuviRuntimeState.FAILED;
  }
  private async start(): Promise<void> {
    const key = new util.TextEncoder().encodeInto(this.apiKey);
    this.apiKey = '';
    try {
      const context = this.getUIContext().getHostContext();
      if (context === undefined || !DEBUG) {
        this.message = '无法获取调试宿主上下文，未启动。';
        return;
      }
      await ShuviRuntimeService.session.start(runtimeStartupFactory(context, DEBUG), key);
    } catch (error) {
      this.state = ShuviRuntimeService.session.lifecycleState();
      this.message = this.describe(this.state);
    } finally { key.fill(0); }
  }
  build() {
    Column({ space: 12 }) {
      Text('Agent 会话启动检查 · 调试').fontSize(16).fontWeight(FontWeight.Medium).fontColor(Theme.ink)
      Text('模型配置：deepseek-flash；搜索服务：本机 8787 端口。请先启动搜索服务并完成 HDC 转发。')
        .fontSize(13).fontColor(Theme.muted).width('100%')
      Text('点击后会打开专用加密库、读取恢复记录并连接 MCP。仅发现工具，不调用模型、不执行搜索、不自动续跑旧任务。首页仍为演示。')
        .fontSize(13).fontColor(Theme.muted).width('100%')
      TextInput({ text: this.apiKey, placeholder: '会话凭据，可输入无敏感性的测试值' })
        .type(InputType.Password).showPasswordIcon(false).copyOption(CopyOptions.None)
        .selectionMenuHidden(false).enableAutoFill(false).enablePreviewText(false).maxLength(2048)
        .enabled(this.canStart()).onChange((value: string): void => { this.apiKey = value; })
        .accessibilityText('启动检查用会话凭据，允许测试值，密码输入').id('runtime-startup-key')
      Text('本次不校验 Key 有效性，可填 startup-check-only，无需真实 Key。凭据不落盘；提交后清空输入，离开本页或退后台关闭会话。搜索结算与任务授权接入完成前，本入口禁止提交任务。')
        .fontSize(12).fontColor(Theme.muted).width('100%')
      Text(this.message).fontSize(13).fontColor(Theme.ink).width('100%').id('runtime-startup-status')
      if (this.canStart()) {
        Button('同意连接并检查启动').backgroundColor(Theme.accent).fontColor(Color.White)
          .constraintSize({ minHeight: 44 }).enabled(this.apiKey.length > 0)
          .onClick(() => { void this.start(); }).id('runtime-startup-start')
      } else if (this.state === ShuviRuntimeState.STARTING || this.state === ShuviRuntimeState.READY) {
        Button('关闭会话').backgroundColor(Theme.soft).fontColor(Theme.accent)
          .constraintSize({ minHeight: 44 }).onClick(() => {
            void ShuviRuntimeService.session.stop().catch((): void => {});
          }).id('runtime-startup-stop')
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(16)
      .backgroundColor(Theme.surface).borderRadius(16).border({ width: 1, color: Theme.line })
  }
}
