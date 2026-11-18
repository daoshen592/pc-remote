import { Theme } from '../common/UiConfig';
import { AppIcon } from './AppIcon';

/**
 * 通用遥控器按键（HarmonyOS 卡片风格）。
 * - 自绘矢量图标（AppIcon），支持文字兜底（如 OK）
 * - 浅色圆角按钮 + 轻阴影，按下时缩放并高亮
 * - 支持单击、可选长按（电源键短按关屏 / 长按关机重启菜单）
 * - 只负责 UI 与抛 action ID，不含通信逻辑
 */
@Component
export struct RemoteKey {
  @Prop glyph: string = '';          // 文字图标（仅 OK 用）
  @Prop icon: string = '';           // 自绘图标名（IconName）
  @Prop label: string = '';
  @Prop action: string = '';
  @Prop diameter: number = 56;
  @Prop bg: string = Theme.KEY;
  @Prop pressedBg: string = Theme.KEY_PRESSED;
  @Prop glyphColor: string = Theme.TEXT;
  @Prop glyphSize: number = 24;
  @Prop labelSize: number = 11;
  @Prop showLabel: boolean = true;
  @Prop supportLongPress: boolean = false;
  @Prop keyBorderColor: string = Theme.KEY_BORDER;
  @Prop elevation: number = 3;
  @Prop useTextGlyph: boolean = false;

  onKey: (action: string) => void = () => {};
  onLongPress: (action: string) => void = () => {};

  @State private isPressed: boolean = false;
  private longTimer: number = 0;
  private longFired: boolean = false;

  aboutToDisappear(): void {
    if (this.longTimer !== 0) {
      clearTimeout(this.longTimer);
      this.longTimer = 0;
    }
  }

  build() {
    Column({ space: this.showLabel ? 7 : 0 }) {
      Stack() {
        Column()
          .width(this.diameter)
          .height(this.diameter)
          .borderRadius(this.diameter / 2)
          .backgroundColor(this.bg)
          .shadow({
            radius: this.isPressed ? 2 : this.elevation * 3,
            color: this.elevation > 4 ? '#2A0A59F7' : Theme.CARD_SHADOW,
            offsetY: this.isPressed ? 0 : this.elevation
          })

        Column() {
          if (this.useTextGlyph) {
            Text(this.glyph)
              .fontSize(this.glyphSize)
              .fontColor(this.glyphColor)
              .fontWeight(FontWeight.Bold)
              .maxLines(1)
              .textAlign(TextAlign.Center)
          } else if (this.icon.length > 0) {
            AppIcon({
              name: this.icon,
              iconSize: this.glyphSize,
              color: this.glyphColor,
              accent: this.glyphColor,
              lineWidth: 1.8
            })
          }
        }
        .width(this.diameter)
        .height(this.diameter)
        .borderRadius(this.diameter / 2)
        .backgroundColor(this.isPressed ? this.pressedBg : Color.Transparent)
        .border({ width: 1, color: this.keyBorderColor })
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .scale({ x: this.isPressed ? 0.9 : 1, y: this.isPressed ? 0.9 : 1 })
        .animation({ duration: 90, curve: Curve.EaseOut })
        .onTouch((event: TouchEvent) => {
          if (event.type === TouchType.Down) {
            this.isPressed = true;
            this.longFired = false;
            if (this.supportLongPress) {
              this.longTimer = setTimeout(() => {
                this.longFired = true;
                this.isPressed = false;
                this.onLongPress(this.action);
              }, 550);
            }
          } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
            this.isPressed = false;
            if (this.longTimer !== 0) {
              clearTimeout(this.longTimer);
              this.longTimer = 0;
            }
            if (event.type === TouchType.Up && !this.longFired) {
              this.onKey(this.action);
            }
          }
        })
      }
      .width(this.diameter)
      .height(this.diameter)

      if (this.showLabel && this.label.length > 0) {
        Text(this.label)
          .fontSize(this.labelSize)
          .fontColor(Theme.SUB_TEXT)
          .maxLines(1)
          .textAlign(TextAlign.Center)
      }
    }
    // 列宽 = 键径 + 10（左右各 5）：媒体行 5 个键要挤进一屏，留 16 会白占宽度把键压小；
    // 最长的「播放/暂停」在 11fp 下约 50vp，键径 50 时列宽 60 仍然放得下
    .width(this.diameter + 10)
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Start)
  }
}
