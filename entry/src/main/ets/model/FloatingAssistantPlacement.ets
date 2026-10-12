// 页面内的坐标状态；只记住吸附侧和可用高度比例，不写持久化存储。
export class FloatingAssistantPlacement {
  static readonly size: number = 60;
  static readonly margin: number = 20;
  x: number = 0;
  y: number = 0;
  canPlace: boolean = false;
  dragging: boolean = false;
  private dockRight: boolean = true;
  private yRatio: number = 1;
  private width: number = 0;
  private height: number = 0;
  private headerHeight: number = 0;
  private left: number = 0;
  private right: number = 0;
  private top: number = 0;
  private bottom: number = 0;
  private startX: number = 0;
  private startY: number = 0;

  resize(width: number, height: number, headerHeight: number): void {
    if (!Number.isFinite(width) || !Number.isFinite(height) || !Number.isFinite(headerHeight) ||
      width < 0 || height < 0 || headerHeight < 0 ||
      (width === this.width && height === this.height && headerHeight === this.headerHeight)) {
      return;
    }
    this.width = width;
    this.height = height;
    this.headerHeight = headerHeight;
    this.left = FloatingAssistantPlacement.margin;
    this.right = width - FloatingAssistantPlacement.size - FloatingAssistantPlacement.margin;
    this.top = headerHeight + 12;
    this.bottom = height - FloatingAssistantPlacement.size - FloatingAssistantPlacement.margin;
    this.canPlace = this.right >= this.left && this.bottom >= this.top;
    // 尺寸变化终止当前拖动，迟到的更新和松手不再改变已保存的位置。
    this.dragging = false;
    this.restorePosition();
  }

  beginDrag(): void {
    if (!this.canPlace) {
      return;
    }
    this.startX = this.x;
    this.startY = this.y;
    this.dragging = true;
  }

  moveDrag(offsetX: number, offsetY: number): void {
    if (!this.dragging || !Number.isFinite(offsetX) || !Number.isFinite(offsetY)) {
      return;
    }
    this.x = Math.min(this.right, Math.max(this.left, this.startX + offsetX));
    this.y = Math.min(this.bottom, Math.max(this.top, this.startY + offsetY));
  }

  finishDrag(): void {
    if (!this.dragging) {
      return;
    }
    const midpoint: number = (this.left + this.right) / 2;
    if (this.x !== midpoint) {
      this.dockRight = this.x > midpoint;
    }
    if (this.bottom > this.top) {
      this.yRatio = (this.y - this.top) / (this.bottom - this.top);
    }
    this.dragging = false;
    this.restorePosition();
  }

  cancelDrag(): void {
    if (this.dragging) {
      this.dragging = false;
      this.restorePosition();
    }
  }

  private restorePosition(): void {
    if (!this.canPlace) {
      this.x = 0;
      this.y = 0;
      return;
    }
    this.x = this.dockRight ? this.right : this.left;
    this.y = this.top + (this.bottom - this.top) * this.yRatio;
  }
}
