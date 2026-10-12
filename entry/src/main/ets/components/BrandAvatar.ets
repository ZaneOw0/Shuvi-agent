interface BrandAvatarOptions {
  size: number;
}

// 品牌图片与功能图标分开；相邻文字或外层按钮提供语义。
@Builder
export function BrandAvatar($$: BrandAvatarOptions) {
  Image($r('app.media.shuvi_logo')).width($$.size).height($$.size)
    .objectFit(ImageFit.Contain).borderRadius($$.size * 0.28).clip(true)
    .accessibilityLevel('no')
}
