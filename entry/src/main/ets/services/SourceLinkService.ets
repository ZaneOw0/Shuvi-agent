import { common } from '@kit.AbilityKit';
import { safeSearchUrl } from './model/SearchTaskSupport';

// 由 EntryAbility 注入已有的强类型上下文，页面不做 as 断言或持有 Ability。
// API 12+ UIAbilityContext.openLink：前台显式点击打开外部链接，不新增权限。
export class SourceLinkService {
  private static context: common.UIAbilityContext | undefined = undefined;

  static bind(context: common.UIAbilityContext): void {
    SourceLinkService.context = context;
  }

  static release(): void {
    SourceLinkService.context = undefined;
  }

  static async open(url: string): Promise<void> {
    // 当前仅允许三条固定公开样例；真实来源接线需另行实现 URL 运行时校验。
    if (url !== 'https://developer.huawei.com/consumer/cn/arkui' &&
      url !== 'https://developer.huawei.com/consumer/cn/arkui/devstart' &&
      url !== 'https://developer.huawei.com/consumer/cn/doc') {
      throw new Error('SOURCE_URL_NOT_ALLOWED');
    }
    const context = SourceLinkService.context;
    if (!context) {
      throw new Error('SOURCE_CONTEXT_UNAVAILABLE');
    }
    await context.openLink(url, { appLinkingOnly: false });
  }

  static async openSearchSource(url: string): Promise<void> {
    if (!safeSearchUrl(url)) throw new Error('SOURCE_URL_NOT_ALLOWED');
    const context = SourceLinkService.context;
    if (context === undefined) throw new Error('SOURCE_CONTEXT_UNAVAILABLE');
    await context.openLink(url, { appLinkingOnly: false });
  }
}
