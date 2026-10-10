interface AppIconOptions {
  source: Resource;
  size?: number;
}

// 装饰图标不单独朗读；可点击入口由外层 Button 提供名称与点击区域。
// SVG 自带描边颜色，避免 fillColor 将空心图标填成实心。
@Builder
export function AppIcon($$: AppIconOptions) {
  Image($$.source).width($$.size ?? 22).height($$.size ?? 22)
    .objectFit(ImageFit.Contain).accessibilityLevel('no')
}
