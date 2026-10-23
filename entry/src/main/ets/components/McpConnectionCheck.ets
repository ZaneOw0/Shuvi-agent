import { Theme } from './Theme';
import { McpProbeResult, McpProbeState } from '../services/McpProbeSession';
import { McpConnectionCheckService } from '../services/McpConnectionCheckService';

@Component
export struct McpConnectionCheck {
  @State result: McpProbeResult = new McpProbeResult();

  aboutToAppear(): void {
    McpConnectionCheckService.session.attach((result: McpProbeResult) => {
      this.result = result;
    });
  }

  aboutToDisappear(): void {
    McpConnectionCheckService.session.detach();
  }

  build() {
    Column({ space: 12 }) {
      Text('搜索服务连接 · 调试').fontSize(16).fontWeight(FontWeight.Medium).fontColor(Theme.ink)
      Text(this.result.message).fontSize(13).fontColor(Theme.muted).width('100%')
        .id('mcp-probe-status').accessibilityText(this.result.message)
      if (this.result.protocolVersion.length > 0) {
        Text(`协议 ${this.result.protocolVersion} · 未执行搜索`).fontSize(12).fontColor(Theme.muted)
      }
      if (this.result.state === McpProbeState.Checking || this.result.state === McpProbeState.Stopping) {
        Button(this.result.state === McpProbeState.Stopping ? '正在释放连接' : '停止检查')
          .enabled(this.result.state === McpProbeState.Checking)
          .onClick(() => McpConnectionCheckService.session.cancel())
          .id('mcp-probe-stop').backgroundColor(Theme.soft).fontColor(Theme.accent)
      } else {
        Button('检查连接').backgroundColor(Theme.accent).fontColor(Color.White)
          .id('mcp-probe-start')
          .onClick(() => { McpConnectionCheckService.session.run(); })
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(16)
      .backgroundColor(Theme.surface).borderRadius(16).border({ width: 1, color: Theme.line })
  }
}
