import { Theme } from '../common/UiConfig';
import { AppIcon, IconName } from './AppIcon';

/**
 * 语音键（Push-to-Talk）：按住说话、松手识别。
 * 暖橙实心键，按住时扩散光晕 + 缩放反馈。
 */
@Component
export struct VoiceKey {
  @Prop diameter: number = 60;
  /** 横屏矮屏可关掉下方小字，把高度让给键径 */
  @Prop showLabel: boolean = true;
  onDown: () => void = () => {};
  onUp: () => void = () => {};

  @State private holding: boolean = false;

  build() {
    Column({ space: this.showLabel ? 7 : 0 }) {
      Stack({ alignContent: Alignment.Center }) {
        if (this.holding) {
          Column()
            .width(this.diameter * 1.35)
            .height(this.diameter * 1.35)
            .borderRadius(this.diameter * 1.35 / 2)
            .backgroundColor(Theme.VOICE_SOFT)
        }
        Column() {
          AppIcon({
            name: IconName.VOICE,
            iconSize: this.diameter * 0.46,
            color: '#FFFFFF',
            lineWidth: 1.9
          })
        }
        .width(this.diameter)
        .height(this.diameter)
        .borderRadius(this.diameter / 2)
        .backgroundColor(this.holding ? Theme.VOICE_PRESSED : Theme.VOICE)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .scale({ x: this.holding ? 0.92 : 1, y: this.holding ? 0.92 : 1 })
        .animation({ duration: 90, curve: Curve.EaseOut })
        .shadow({
          radius: this.holding ? 18 : 10,
          color: this.holding ? '#55FF7A29' : '#35FF7A29',
          offsetY: this.holding ? 2 : 4
        })
        .onTouch((event: TouchEvent) => {
          if (event.type === TouchType.Down) {
            this.holding = true;
            this.onDown();
          } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
            this.holding = false;
            if (event.type === TouchType.Up) {
              this.onUp();
            }
          }
        })
      }
      // 占位只按键径算；按住时的光晕（1.35 倍）由 Stack 居中绘制溢出，不参与布局，
      // 否则每个语音键都要多占 36% 的高度，卡片里就放不下更大的键
      .width(this.diameter)
      .height(this.diameter)

      if (this.showLabel) {
        Text(this.holding ? '松开识别' : '语音')
          .fontSize(11)
          .fontColor(this.holding ? Theme.VOICE : Theme.SUB_TEXT)
      }
    }
    .width(this.diameter)
    .alignItems(HorizontalAlign.Center)
  }
}
