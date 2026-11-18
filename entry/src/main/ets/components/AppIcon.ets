import { Theme } from '../common/UiConfig';

/** 自绘图标名称 */
export class IconName {
  static readonly POWER: string = 'power';
  static readonly VOICE: string = 'voice';
  static readonly UP: string = 'up';
  static readonly DOWN: string = 'down';
  static readonly LEFT: string = 'left';
  static readonly RIGHT: string = 'right';
  static readonly BACK: string = 'back';
  static readonly HOME: string = 'home';
  static readonly MENU: string = 'menu';
  static readonly VOL_UP: string = 'vol_up';
  static readonly VOL_DOWN: string = 'vol_down';
  static readonly MUTE: string = 'mute';
  static readonly TV: string = 'tv';
  static readonly PLAY: string = 'play';
  static readonly REWIND: string = 'rewind';
  static readonly FORWARD: string = 'forward';
  static readonly MOUSE_LEFT: string = 'mouse_left';
  static readonly MOUSE_RIGHT: string = 'mouse_right';
  static readonly CURSOR: string = 'cursor';
  static readonly PREV_TRACK: string = 'prev_track';
  static readonly NEXT_TRACK: string = 'next_track';
  static readonly SWITCH_WINDOW: string = 'switch_window';
  static readonly CLOSE_WINDOW: string = 'close_window';
  static readonly PASTE: string = 'paste';
  static readonly SETTINGS: string = 'settings';
  static readonly CHECK: string = 'check';
  static readonly REMOTE: string = 'remote';
  static readonly APPS: string = 'apps';
  static readonly KEYBOARD: string = 'keyboard';
}

/**
 * 自绘矢量图标（Canvas 2D 命令式绘制）。
 *
 * 为什么不用声明式 Path：API 12 上 Path.commands + .scale() 会把
 * 圆弧/贝塞尔渲染成小点或方块（实测电源成点、麦克风成水滴、菜单成块）。
 * Canvas 2D 用标准 transform，坐标完全可控，任何设备都清晰一致。
 *
 * 所有图标在 24x24 逻辑坐标绘制，再按 iconSize/24 缩放到实际尺寸。
 */
@Component
export struct AppIcon {
  @Prop @Watch('onPropChanged') name: string = IconName.HOME;
  @Prop @Watch('onPropChanged') iconSize: number = 24;
  @Prop @Watch('onPropChanged') color: string = Theme.TEXT;
  @Prop @Watch('onPropChanged') accent: string = Theme.ACCENT;
  @Prop @Watch('onPropChanged') lineWidth: number = 2;

  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private context: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private ready: boolean = false;

  aboutToAppear(): void {
    // 属性在 aboutToAppear 已就绪，Canvas onReady 时再绘制
  }

  /** 属性变化（如 Tab 选中变色）时即时重绘 */
  private onPropChanged(propName: string): void {
    if (this.ready) {
      this.draw();
    }
  }

  private draw(): void {
    const ctx = this.context;
    const size = this.iconSize;
    ctx.clearRect(0, 0, size, size);
    ctx.save();
    const ratio = size / 24;
    ctx.scale(ratio, ratio);
    ctx.lineWidth = this.lineWidth;
    ctx.lineCap = 'round';
    ctx.lineJoin = 'round';
    ctx.strokeStyle = this.color;
    ctx.fillStyle = this.color;
    this.drawByName(ctx, this.name);
    ctx.restore();
  }

  private speaker(ctx: CanvasRenderingContext2D): void {
    ctx.beginPath();
    ctx.moveTo(4, 9);
    ctx.lineTo(7.5, 9);
    ctx.lineTo(12.5, 5);
    ctx.lineTo(12.5, 19);
    ctx.lineTo(7.5, 15);
    ctx.lineTo(4, 15);
    ctx.closePath();
    ctx.stroke();
  }

  private mouseBody(ctx: CanvasRenderingContext2D): void {
    ctx.beginPath();
    ctx.moveTo(12, 3);
    ctx.bezierCurveTo(7.5, 3, 5.5, 6, 5.5, 10);
    ctx.lineTo(5.5, 14);
    ctx.bezierCurveTo(5.5, 18, 7.5, 21, 12, 21);
    ctx.bezierCurveTo(16.5, 21, 18.5, 18, 18.5, 14);
    ctx.lineTo(18.5, 10);
    ctx.bezierCurveTo(18.5, 6, 16.5, 3, 12, 3);
    ctx.closePath();
    ctx.stroke();
    ctx.beginPath();
    ctx.moveTo(12, 3);
    ctx.lineTo(12, 11);
    ctx.moveTo(5.5, 11);
    ctx.lineTo(18.5, 11);
    ctx.stroke();
  }

  private drawByName(ctx: CanvasRenderingContext2D, name: string): void {
    switch (name) {
      case IconName.POWER:
        ctx.beginPath();
        ctx.arc(12, 12.5, 8, -Math.PI * 0.35, Math.PI * 1.35);
        ctx.stroke();
        ctx.beginPath();
        ctx.moveTo(12, 3.2);
        ctx.lineTo(12, 11.5);
        ctx.stroke();
        break;

      case IconName.VOICE:
        ctx.beginPath();
        ctx.moveTo(9, 11);
        ctx.lineTo(9, 7);
        ctx.arc(12, 7, 3, Math.PI, 0);
        ctx.lineTo(15, 11);
        ctx.arc(12, 11, 3, 0, Math.PI);
        ctx.closePath();
        ctx.stroke();
        ctx.beginPath();
        ctx.moveTo(12, 14);
        ctx.lineTo(12, 17);
        ctx.moveTo(8.5, 17.5);
        ctx.lineTo(15.5, 17.5);
        ctx.stroke();
        break;

      case IconName.UP:
        ctx.beginPath();
        ctx.moveTo(5, 15);
        ctx.lineTo(12, 8);
        ctx.lineTo(19, 15);
        ctx.stroke();
        break;

      case IconName.DOWN:
        ctx.beginPath();
        ctx.moveTo(5, 9);
        ctx.lineTo(12, 16);
        ctx.lineTo(19, 9);
        ctx.stroke();
        break;

      case IconName.LEFT:
        ctx.beginPath();
        ctx.moveTo(15, 5);
        ctx.lineTo(8, 12);
        ctx.lineTo(15, 19);
        ctx.stroke();
        break;

      case IconName.RIGHT:
        ctx.beginPath();
        ctx.moveTo(9, 5);
        ctx.lineTo(16, 12);
        ctx.lineTo(9, 19);
        ctx.stroke();
        break;

      case IconName.BACK:
        ctx.beginPath();
        ctx.moveTo(11, 6);
        ctx.lineTo(4.5, 12);
        ctx.lineTo(11, 18);
        ctx.moveTo(4.5, 12);
        ctx.lineTo(15, 12);
        ctx.stroke();
        break;

      case IconName.HOME:
        ctx.beginPath();
        ctx.moveTo(3, 11);
        ctx.lineTo(12, 4);
        ctx.lineTo(21, 11);
        ctx.moveTo(5.5, 9.5);
        ctx.lineTo(5.5, 20);
        ctx.lineTo(18.5, 20);
        ctx.lineTo(18.5, 9.5);
        ctx.moveTo(10, 20);
        ctx.lineTo(10, 14);
        ctx.lineTo(14, 14);
        ctx.lineTo(14, 20);
        ctx.stroke();
        break;

      case IconName.MENU:
        ctx.beginPath();
        ctx.moveTo(4, 6.5);
        ctx.lineTo(20, 6.5);
        ctx.moveTo(4, 12);
        ctx.lineTo(20, 12);
        ctx.moveTo(4, 17.5);
        ctx.lineTo(20, 17.5);
        ctx.stroke();
        break;

      case IconName.VOL_UP:
        this.speaker(ctx);
        ctx.beginPath();
        ctx.arc(12.5, 12, 3.5, -Math.PI / 3, Math.PI / 3);
        ctx.stroke();
        ctx.beginPath();
        ctx.arc(12.5, 12, 6.5, -Math.PI / 3, Math.PI / 3);
        ctx.stroke();
        break;

      case IconName.VOL_DOWN:
        this.speaker(ctx);
        ctx.beginPath();
        ctx.moveTo(16, 12);
        ctx.lineTo(20, 12);
        ctx.stroke();
        break;

      case IconName.MUTE:
        this.speaker(ctx);
        ctx.beginPath();
        ctx.moveTo(16, 9);
        ctx.lineTo(20, 15);
        ctx.moveTo(20, 9);
        ctx.lineTo(16, 15);
        ctx.stroke();
        break;

      case IconName.TV:
        ctx.beginPath();
        ctx.rect(3, 5, 18, 12);
        ctx.stroke();
        ctx.beginPath();
        ctx.moveTo(8, 21);
        ctx.lineTo(16, 21);
        ctx.moveTo(12, 17);
        ctx.lineTo(12, 21);
        ctx.stroke();
        break;

      case IconName.PLAY:
        ctx.beginPath();
        ctx.moveTo(8, 5);
        ctx.lineTo(19, 12);
        ctx.lineTo(8, 19);
        ctx.closePath();
        ctx.fill();
        break;

      case IconName.REWIND:
        ctx.beginPath();
        ctx.moveTo(11, 5);
        ctx.lineTo(4, 12);
        ctx.lineTo(11, 19);
        ctx.closePath();
        ctx.moveTo(20, 5);
        ctx.lineTo(13, 12);
        ctx.lineTo(20, 19);
        ctx.closePath();
        ctx.fill();
        break;

      case IconName.FORWARD:
        ctx.beginPath();
        ctx.moveTo(13, 5);
        ctx.lineTo(20, 12);
        ctx.lineTo(13, 19);
        ctx.closePath();
        ctx.moveTo(4, 5);
        ctx.lineTo(11, 12);
        ctx.lineTo(4, 19);
        ctx.closePath();
        ctx.fill();
        break;

      case IconName.MOUSE_LEFT:
        this.mouseBody(ctx);
        ctx.fillStyle = this.accent;
        ctx.beginPath();
        ctx.moveTo(12, 3);
        ctx.lineTo(12, 11);
        ctx.lineTo(5.5, 11);
        ctx.lineTo(5.5, 10);
        ctx.bezierCurveTo(5.5, 6, 7.5, 3, 12, 3);
        ctx.closePath();
        ctx.fill();
        break;

      case IconName.MOUSE_RIGHT:
        this.mouseBody(ctx);
        ctx.fillStyle = this.accent;
        ctx.beginPath();
        ctx.moveTo(12, 3);
        ctx.lineTo(12, 11);
        ctx.lineTo(18.5, 11);
        ctx.lineTo(18.5, 10);
        ctx.bezierCurveTo(18.5, 6, 16.5, 3, 12, 3);
        ctx.closePath();
        ctx.fill();
        break;

      case IconName.CURSOR:
        ctx.beginPath();
        ctx.moveTo(5, 3);
        ctx.lineTo(5, 19);
        ctx.lineTo(9.5, 14.5);
        ctx.lineTo(12.5, 21);
        ctx.lineTo(15.5, 19.5);
        ctx.lineTo(12.5, 13);
        ctx.lineTo(19, 12.5);
        ctx.closePath();
        ctx.fill();
        break;

      case IconName.PREV_TRACK:
        // 上一集：竖线 + 左向双三角
        ctx.beginPath();
        ctx.moveTo(5, 5);
        ctx.lineTo(5, 19);
        ctx.stroke();
        ctx.beginPath();
        ctx.moveTo(19, 6);
        ctx.lineTo(10, 12);
        ctx.lineTo(19, 18);
        ctx.closePath();
        ctx.fill();
        break;

      case IconName.NEXT_TRACK:
        // 下一集：右向双三角 + 竖线
        ctx.beginPath();
        ctx.moveTo(19, 5);
        ctx.lineTo(19, 19);
        ctx.stroke();
        ctx.beginPath();
        ctx.moveTo(5, 6);
        ctx.lineTo(14, 12);
        ctx.lineTo(5, 18);
        ctx.closePath();
        ctx.fill();
        break;

      case IconName.SWITCH_WINDOW:
        // 切换窗口（Alt+Tab）：两个错开的窗口框
        ctx.strokeRect(3, 3, 13, 11);
        ctx.beginPath();
        ctx.moveTo(8, 10);
        ctx.lineTo(21, 10);
        ctx.lineTo(21, 21);
        ctx.lineTo(8, 21);
        ctx.closePath();
        ctx.stroke();
        break;

      case IconName.CLOSE_WINDOW:
        // 关闭窗口（Alt+F4）：窗口框 + 叉
        ctx.beginPath();
        ctx.moveTo(4, 5);
        ctx.lineTo(20, 5);
        ctx.lineTo(20, 19);
        ctx.lineTo(4, 19);
        ctx.closePath();
        ctx.moveTo(4, 8);
        ctx.lineTo(20, 8);
        ctx.stroke();
        ctx.beginPath();
        ctx.moveTo(9, 12);
        ctx.lineTo(15, 17);
        ctx.moveTo(15, 12);
        ctx.lineTo(9, 17);
        ctx.stroke();
        break;

      case IconName.PASTE:
        // 粘贴（Ctrl+V）：剪贴板 + 纸
        ctx.beginPath();
        ctx.moveTo(8, 4);
        ctx.lineTo(16, 4);
        ctx.lineTo(16, 6);
        ctx.lineTo(18, 6);
        ctx.lineTo(18, 20);
        ctx.lineTo(6, 20);
        ctx.lineTo(6, 6);
        ctx.lineTo(8, 6);
        ctx.closePath();
        ctx.stroke();
        ctx.beginPath();
        ctx.moveTo(9, 4);
        ctx.lineTo(15, 4);
        ctx.lineTo(15, 6);
        ctx.lineTo(9, 6);
        ctx.closePath();
        ctx.fill();
        break;

      case IconName.SETTINGS: {
        // 齿轮：主环 + 8 根短齿 + 中心孔
        // 光学框与遥控器严格一致：齿尖外径 r8.4（纵向 3.6~20.4），同为细线描边
        ctx.beginPath();
        ctx.arc(12, 12, 6.5, 0, Math.PI * 2);
        ctx.stroke();
        ctx.beginPath();
        for (let i = 0; i < 8; i++) {
          const angle: number = (i * Math.PI) / 4 + Math.PI / 8;
          ctx.moveTo(12 + Math.cos(angle) * 6.5, 12 + Math.sin(angle) * 6.5);
          ctx.lineTo(12 + Math.cos(angle) * 8.4, 12 + Math.sin(angle) * 8.4);
        }
        ctx.stroke();
        ctx.beginPath();
        ctx.arc(12, 12, 2.6, 0, Math.PI * 2);
        ctx.stroke();
        break;
      }

      case IconName.APPS: {
        // 应用宫格：四宫格方块（细线描边）
        // 光学框 3.6~20.4，与齿轮/遥控器严格一致：块 7.4 + 间距 2
        ctx.strokeRect(3.6, 3.6, 7.4, 7.4);
        ctx.strokeRect(13, 3.6, 7.4, 7.4);
        ctx.strokeRect(3.6, 13, 7.4, 7.4);
        ctx.strokeRect(13, 13, 7.4, 7.4);
        break;
      }

      case IconName.CHECK:
        // 对勾：连接成功
        ctx.beginPath();
        ctx.moveTo(4, 12);
        ctx.lineTo(9.5, 17.5);
        ctx.lineTo(20, 6);
        ctx.stroke();
        break;

      case IconName.KEYBOARD: {
        // 键盘：圆角机身（光学框与其它 tab 图标一致 3.6~20.4）+ 两排键点 + 空格条
        ctx.beginPath();
        ctx.moveTo(6.1, 7.2);
        ctx.lineTo(17.9, 7.2);
        ctx.arc(17.9, 9.2, 2, -Math.PI / 2, 0);
        ctx.lineTo(19.9, 15.8);
        ctx.arc(17.9, 15.8, 2, 0, Math.PI / 2);
        ctx.lineTo(6.1, 17.8);
        ctx.arc(6.1, 15.8, 2, Math.PI / 2, Math.PI);
        ctx.lineTo(4.1, 9.2);
        ctx.arc(6.1, 9.2, 2, Math.PI, Math.PI * 1.5);
        ctx.closePath();
        ctx.stroke();
        // 两排按键小方块
        for (let row = 0; row < 2; row++) {
          for (let col = 0; col < 4; col++) {
            ctx.strokeRect(7.4 + col * 2.9, 10.1 + row * 2.4, 1.5, 1.1);
          }
        }
        // 空格条
        ctx.beginPath();
        ctx.moveTo(9.4, 15.4);
        ctx.lineTo(14.6, 15.4);
        ctx.stroke();
        break;
      }

      case IconName.REMOTE: {
        // 遥控器：圆角机身 + 顶部屏线 + 中央确认键 + 底部两点
        // 光学框与齿轮严格一致：纵向 3.6~20.4，横向居中，同为细线描边
        ctx.beginPath();
        ctx.moveTo(9.35, 3.6);
        ctx.lineTo(14.65, 3.6);
        ctx.arc(14.65, 6.2, 2.6, -Math.PI / 2, 0);
        ctx.lineTo(17.25, 17.8);
        ctx.arc(14.65, 17.8, 2.6, 0, Math.PI / 2);
        ctx.lineTo(9.35, 20.4);
        ctx.arc(9.35, 17.8, 2.6, Math.PI / 2, Math.PI);
        ctx.lineTo(6.75, 6.2);
        ctx.arc(9.35, 6.2, 2.6, Math.PI, Math.PI * 1.5);
        ctx.closePath();
        ctx.stroke();
        // 顶部屏幕
        ctx.beginPath();
        ctx.moveTo(9.3, 7.2);
        ctx.lineTo(14.7, 7.2);
        ctx.stroke();
        // 中央确认键
        ctx.beginPath();
        ctx.arc(12, 12.4, 2.4, 0, Math.PI * 2);
        ctx.stroke();
        // 底部两个功能点
        ctx.beginPath();
        ctx.arc(10.7, 16.9, 0.8, 0, Math.PI * 2);
        ctx.fill();
        ctx.beginPath();
        ctx.arc(13.3, 16.9, 0.8, 0, Math.PI * 2);
        ctx.fill();
        break;
      }

      default:
        break;
    }
  }

  build() {
    Canvas(this.context)
      .width(this.iconSize)
      .height(this.iconSize)
      .onReady(() => {
        this.ready = true;
        this.draw();
      })
  }
}
