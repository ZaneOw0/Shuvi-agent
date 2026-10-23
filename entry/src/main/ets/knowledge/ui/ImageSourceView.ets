import { image } from '@kit.ImageKit';
import { ImageSourceSession } from '../infra/ImageSourceSession';
import { KnowledgeCallbackListener } from '../domain/KnowledgePorts';

@Component
export struct ImageSourceView {
  session: ImageSourceSession | undefined = undefined;
  onBack: () => void = (): void => {};
  private currentPixels: image.PixelMap | undefined = undefined;
  @State private hasPixels: boolean = false;
  @State private statusText: string = '';
  @State private metadataText: string = '';
  @State private paragraphText: string = '';
  private listener: KnowledgeCallbackListener | undefined = undefined;
  private update(): void { this.statusText = this.session?.message ?? '来源不可用'; this.metadataText = this.session?.metadata ?? ''; this.paragraphText = this.session?.paragraph ?? ''; }
  aboutToAppear(): void { this.listener = new KnowledgeCallbackListener((): void => { this.update(); }); this.session?.subscribe(this.listener,(pixels: image.PixelMap | undefined): void => { this.currentPixels = pixels; this.hasPixels = pixels !== undefined; }); this.currentPixels = this.session?.pixels(); this.hasPixels = this.currentPixels !== undefined; this.update(); }
  aboutToDisappear(): void { this.currentPixels = undefined; this.hasPixels = false; this.session?.displayDetached(); if (this.listener !== undefined) { this.session?.unsubscribe(this.listener); this.listener = undefined; } this.session?.close().catch((): void => {}); }
  build() {
    Column({ space: 10 }) {
      Button('返回').id('m3-source-back').onClick((): void => { this.currentPixels = undefined; this.hasPixels = false; this.onBack(); })
      Text(this.statusText).id('m3-source-status')
      Text(this.metadataText).id('m3-source-metadata').fontSize(12).width('100%')
       if (this.hasPixels && this.currentPixels !== undefined) { Image(this.currentPixels).id('m3-source-original').width('100%').height(280).objectFit(ImageFit.Contain).backgroundColor('#EEEEEE').onDisAppear((): void => { this.session?.displayDetached(); }) }
       Scroll() { Text(this.paragraphText).id('m3-source-paragraph').fontSize(14).width('100%') }.layoutWeight(1)
      Button('重试释放').id('m3-source-release-retry').onClick((): void => { this.currentPixels = undefined; this.hasPixels = false; this.session?.retry().catch((): void => {}); })
    }.padding(16).width('100%').height('100%')
  }
}
