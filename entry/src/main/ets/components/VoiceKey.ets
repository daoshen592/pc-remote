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
  /** 标签下的补充小字（如「按住说话」），与返回/电源的 subLabel 保持同高，避免键看起来下沉 */
  @Prop subLabel: string = '';
  /**
   * 描边色：与返回/电源的 1vp 描边同规格。
   * 实体橙键若无描边，边缘对比更强、视觉直径会显得比淡红键大一圈，
   * 三个键排在一起就"看着不齐"——统一描边后视觉尺寸一致。
   */
  @Prop ringColor: string = '#FFD8BE';
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
        .border({ width: 1, color: this.ringColor })
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .scale({ x: this.holding ? 0.92 : 1, y: this.holding ? 0.92 : 1 })
        .animation({ duration: 90, curve: Curve.EaseOut })
        // 静置时与返回/电源用同一套中性阴影（radius 9 / offsetY 3）；
        // 只有按住时才散橙色光晕，避免静置光圈把键"撑大"显得不齐
        .shadow({
          radius: this.holding ? 18 : 9,
          color: this.holding ? '#55FF7A29' : Theme.CARD_SHADOW,
          offsetY: this.holding ? 2 : 3
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
        Column({ space: 1 }) {
          // 按住时显示「松开识别」4 个字，键径只有 40 出头，11fp 会挤成两行——
          // 用自适应字号（11→9）保证单行放下，且盒子高度始终按 11fp 算，
          // 下方「按住说话」小字不会因为换状态而跳动
          Text(this.holding ? '松开识别' : '语音')
            .fontColor(this.holding ? Theme.VOICE : Theme.SUB_TEXT)
            .maxFontSize(11)
            .minFontSize(9)
            .maxLines(1)
            .textAlign(TextAlign.Center)
            .width('100%')
          if (this.subLabel.length > 0) {
            Text(this.subLabel)
              .fontSize(8)
              .fontColor(Theme.SUB_TEXT)
              .opacity(0.75)
              .maxLines(1)
              .textAlign(TextAlign.Center)
          }
        }
        .alignItems(HorizontalAlign.Center)
      }
    }
    .width(this.diameter)
    .alignItems(HorizontalAlign.Center)
  }
}
