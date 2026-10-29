/** Window-level navigation and content limits, in vp. No device, service or persistent state is owned here. */
export class ResponsiveLayoutPolicy {
  static readonly mediumWidth: number = 600;
  static readonly expandedWidth: number = 840;

  static embedded(windowWidth: number): boolean {
    return Number.isFinite(windowWidth) && windowWidth >= ResponsiveLayoutPolicy.expandedWidth;
  }

  static sideWidth(windowWidth: number): number {
    if (!ResponsiveLayoutPolicy.embedded(windowWidth)) return 240;
    return Math.min(280, Math.max(240, windowWidth * 0.22));
  }

  static contentLimit(windowWidth: number, conversation: boolean): number {
    if (!Number.isFinite(windowWidth) || windowWidth < ResponsiveLayoutPolicy.mediumWidth) return 640;
    if (!ResponsiveLayoutPolicy.embedded(windowWidth)) return 720;
    return conversation ? 840 : 960;
  }

  static compactActions(contentWidth: number): boolean {
    return !Number.isFinite(contentWidth) || contentWidth < 480;
  }
}
