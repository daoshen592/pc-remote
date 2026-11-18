import { Theme } from '../common/UiConfig';
import { AppIcon, IconName } from './AppIcon';

/**
 * 触控鼠标指针移动盘（方形）。
 * 交互（参考 LocalTV Remote 触屏触控板）：
 * - 单指滑动：相对位移 → onMove（按盘面宽度归一化，不同屏幕手感一致）
 * - 轻点：onTap（左键单击）  双击：onDoubleTap
 * - 长按：onLongPress（右键）
 * - 双指上下滑：onScroll（滚轮，按手机端位移累积，30ms 批量发）
 * - 双指轻点：onRightClick（右键，等效笔记本触控板）
 * - 「拖拽」开关：点一下按住左键，再点一下放开 → onDragLock（拖窗口/选文字）
 */
@Component
export struct MousePad {
  @Prop diameter: number = 220;
  @Prop sensitivity: number = 1.0;
  /** 相对位移回调，单位已归一化 */
  onMove: (dx: number, dy: number) => void = () => {};
  /** 滚轮回调：正=上滚、负=下滚 */
  onScroll: (dy: number) => void = () => {};
  onTap: () => void = () => {};
  onDoubleTap: () => void = () => {};
  onLongPress: () => void = () => {};
  /** 双指轻点 = 右键 */
  onRightClick: () => void = () => {};
  /** 拖拽锁定：true=已按住左键，false=已释放 */
  onDragLock: (locked: boolean) => void = () => {};
  onInteracting: (active: boolean) => void = () => {};

  @State private active: boolean = false;
  @State private dragging: boolean = false;
  /** 盘面实际宽度，用于按比例计算中心图标；由 onAreaChange 回填 */
  @State private padWidth: number = 0;
  /** 本组件拿到的容器实际尺寸（父容器按屏幕比例分配，这里只负责适配） */
  @State private boxW: number = 0;
  @State private boxH: number = 0;

  /** 工具条（左键/右键/双击/拖拽）高度 + 与盘面的间距，从可用高度里扣掉。
   *  含 1px 描边与 9px 间距，横屏矮容器时才不会把工具条挤出卡片。 */
  private static readonly TOOLBAR_H: number = 37;

  /**
   * 盘面宽度：取「容器宽」和「(容器高 - 工具条) × 1.8」里小的那个。
   * 不能只按宽度定高（width 100% + aspectRatio）——横屏时容器高度变小，
   * 按宽算出来的高会顶出容器，这正是横屏溢出的根因。
   */
  private padW(): number {
    const w: number = this.boxW > 0 ? this.boxW : this.diameter;
    const h: number = this.boxH > 0 ? this.boxH : this.diameter * 0.6;
    const avail: number = Math.max(60, h - MousePad.TOOLBAR_H);
    return Math.max(80, Math.min(w, avail * 1.8));
  }

  private padH(): number {
    return this.padW() / 1.8;
  }

  private lastPanX: number = 0;
  private lastPanY: number = 0;
  private pendingX: number = 0;
  private pendingY: number = 0;
  private pendingScroll: number = 0;
  private flushTimer: number = 0;
  private moved: boolean = false;
  private downTime: number = 0;

  /** 本次触摸序列的最大手指数 / 是否滚动过 / 双指中点 Y */
  private maxTouches: number = 1;
  private scrollUsed: boolean = false;
  private scrollLastY: number = 0;
  private touchCount: number = 0;

  private longTimer: number = 0;
  private clickTimer: number = 0;
  private longFired: boolean = false;
  private lastTapTime: number = 0;

  aboutToAppear(): void {
    // 12ms 合帧：把一帧内的多次触摸位移合成一条再发。原来是 30ms，
    // 网络侧（WebSocket）单帧只花 0.03ms 后，这 30ms 成了全链路最大延迟项，
    // 平均要多等 15ms；降到 12ms 后平均只多等 6ms，手感更跟手。
    this.flushTimer = setInterval(() => {
      this.flush();
    }, 12);
  }

  aboutToDisappear(): void {
    if (this.flushTimer !== 0) {
      clearInterval(this.flushTimer);
      this.flushTimer = 0;
    }
    if (this.longTimer !== 0) { clearTimeout(this.longTimer); this.longTimer = 0; }
    if (this.clickTimer !== 0) { clearTimeout(this.clickTimer); this.clickTimer = 0; }
    if (this.dragging) { this.dragging = false; this.onDragLock(false); }
    this.onInteracting(false);
  }

  private flush(): void {
    if (this.pendingX !== 0 || this.pendingY !== 0) {
      const dx = this.pendingX;
      const dy = this.pendingY;
      this.pendingX = 0;
      this.pendingY = 0;
      this.onMove(dx, dy);
    }
    // 滚动阈值：太小会把 Windows 滚轮刷屏，累计到 1/4 格再发
    if (Math.abs(this.pendingScroll) >= 30) {
      const s = Math.round(this.pendingScroll);
      this.pendingScroll = 0;
      this.onScroll(s);
    }
  }

  private cancelLong(): void {
    if (this.longTimer !== 0) {
      clearTimeout(this.longTimer);
      this.longTimer = 0;
    }
  }

  /** 归一化系数：把盘面像素位移换算成固定的“虚拟盘宽度 320”，保证横竖屏/大小屏一致 */
  private normK(): number {
    const w = this.padWidth > 0 ? this.padWidth : this.diameter;
    return (320 / (w > 1 ? w : 320)) * this.sensitivity;
  }

  private onDown(event: TouchEvent): void {
    this.active = true;
    this.moved = false;
    // 修复：每次按下都重置长按标志。否则长按右键触发过一次后 longFired 永远为 true，
    // 后续 onUp 里的 `if (longFired || moved) return` 会把所有单击/双击全部吞掉。
    this.longFired = false;
    this.downTime = new Date().getTime();
    this.onInteracting(true);
    this.maxTouches = event.touches.length;
    this.scrollUsed = false;
    this.scrollLastY = 0;
    this.touchCount = event.touches.length;
    // 修复：清掉上一次单击残留的延迟定时器，避免新触摸序列里冒出一个孤立单击
    if (this.clickTimer !== 0) {
      clearTimeout(this.clickTimer);
      this.clickTimer = 0;
    }

    // 长按 500ms 触发右键
    this.cancelLong();
    this.longTimer = setTimeout(() => {
      if (!this.moved && this.maxTouches < 2) {
        this.longFired = true;
        this.active = false;
        this.lastTapTime = 0;  // 长按后清连击窗口，避免紧跟的点击被误判成双击
        this.onLongPress();
      }
      this.longTimer = 0;
    }, 500);
  }

  /** 手势驱动的增量位移：offset 为本次手势起点到当前的累计偏移，取差值即为增量 */
  private onPanUpdate(event: GestureEvent): void {
    // 双指一旦出现就锁住光标（maxTouches 是粘性的），避免滚动时指针跟着漂
    if (this.touchCount >= 2 || this.maxTouches >= 2) {
      return;
    }
    const k = this.normK();
    const dx = (event.offsetX - this.lastPanX) * k;
    const dy = (event.offsetY - this.lastPanY) * k;
    this.lastPanX = event.offsetX;
    this.lastPanY = event.offsetY;
    if (Math.abs(dx) > 0.1 || Math.abs(dy) > 0.1) {
      this.moved = true;
      // 移动后清连击窗口：光标移动过就不该再和上一次轻点凑成双击
      this.lastTapTime = 0;
      this.cancelLong();
      this.pendingX += dx;
      this.pendingY += dy;
    }
  }

  private onPanStart(): void {
    this.lastPanX = 0;
    this.lastPanY = 0;
    this.onInteracting(true);
  }

  /** 双指滚动：取两指中点 Y 的增量，正=手指下滑=页面上滚 */
  private onTwoFingerMove(event: TouchEvent): void {
    const ts = event.touches;
    if (ts.length < 2) {
      return;
    }
    const cy = (ts[0].y + ts[1].y) / 2;
    if (this.scrollLastY > 0) {
      const d = cy - this.scrollLastY;
      if (Math.abs(d) > 0.4) {
        this.scrollUsed = true;
        this.pendingScroll += d * 2.2;
      }
    }
    this.scrollLastY = cy;
    this.maxTouches = 2;
    this.moved = true;
    this.active = true;
    this.cancelLong();
  }

  private onUp(event: TouchEvent): void {
    this.active = false;
    this.flush();
    this.cancelLong();
    this.onInteracting(false);

    const now: number = new Date().getTime();

    // 双指轻点（没滑动过、时间短）= 右键
    if (this.maxTouches >= 2) {
      if (!this.scrollUsed && now - this.downTime < 320) {
        this.onRightClick();
      }
      this.maxTouches = 1;
      this.scrollLastY = 0;
      this.scrollUsed = false;
      return;
    }

    this.maxTouches = 1;
    this.scrollLastY = 0;

    if (this.longFired || this.moved) {
      return;
    }

    // 轻点/双击判定：300ms 内第二次轻点视为双击，单击延迟 280ms 触发
    if (now - this.lastTapTime < 300) {
      if (this.clickTimer !== 0) {
        clearTimeout(this.clickTimer);
        this.clickTimer = 0;
      }
      this.lastTapTime = 0;
      this.onDoubleTap();
    } else {
      this.lastTapTime = now;
      this.clickTimer = setTimeout(() => {
        this.clickTimer = 0;
        this.onTap();
      }, 280);
    }
  }

  /** 工具条按钮：等宽胶囊，材质与右侧圆键完全一致（#F7F9FD + 同色描边），激活态实心蓝 */
  @Builder
  toolBtn(label: string, active: boolean, onClick: () => void) {
    Text(label)
      .fontSize(10)
      .fontColor(active ? '#FFFFFF' : Theme.ACCENT)
      .fontWeight(FontWeight.Medium)
      .layoutWeight(1)
      .textAlign(TextAlign.Center)
      .padding({ top: 6, bottom: 6 })
      .borderRadius(10)
      .backgroundColor(active ? Theme.ACCENT : Theme.KEY_UNIFIED)
      .border({ width: 1, color: active ? Theme.ACCENT : Theme.KEY_UNIFIED_BORDER })
      .onClick(() => { onClick(); })
  }

  build() {
    Column({ space: 9 }) {
      // ── 触控盘：浅色主题（华为蓝白），与卡片/按键统一 ──
      // 宽高都由容器实测值算出来（见 padW/padH），横竖屏都不会顶出容器
      Stack({ alignContent: Alignment.Center }) {
        // 盘面底：浅灰白，激活时泛蓝
        Column()
          .width('100%')
          .height('100%')
          .borderRadius(24)
          .backgroundColor(this.active ? Theme.ACCENT_SOFT : '#F7F9FD')
          .border({ width: 1.5, color: this.active ? Theme.ACCENT : Theme.CARD_BORDER })
          .shadow({ radius: 14, color: Theme.CARD_SHADOW, offsetY: 3 })

        // 十字定位线：极淡的视觉引导
        Stack({ alignContent: Alignment.Center }) {
          Row()
            .width('58%')
            .height(1)
            .backgroundColor(this.active ? '#BFD4FF' : Theme.CARD_BORDER)
          Column()
            .width(1)
            .height('58%')
            .backgroundColor(this.active ? '#BFD4FF' : Theme.CARD_BORDER)
        }
        .width('100%')
        .height('100%')

        // 中心光标：浅色光晕 + 蓝色实心圆 + 白色指针，固定不随手指移动
        Stack({ alignContent: Alignment.Center }) {
          // 光晕环
          Column()
            .width('100%')
            .aspectRatio(1)
            .borderRadius('50%')
            .backgroundColor(this.active ? '#0A59F72E' : '#0A59F714')
          // 蓝色内圆
          Column()
            .width('74%')
            .aspectRatio(1)
            .borderRadius('50%')
            .backgroundColor(this.active ? Theme.ACCENT_PRESSED : Theme.ACCENT)
            .shadow({ radius: 10, color: '#400A59F7', offsetY: 2 })
          AppIcon({
            name: IconName.CURSOR,
            iconSize: (this.padWidth > 0 ? this.padWidth : this.diameter) * 0.105,
            color: '#FFFFFF',
            accent: '#FFFFFF',
            lineWidth: 1.8
          })
        }
        .width((this.padWidth > 0 ? this.padWidth : this.diameter) * 0.23)
        .aspectRatio(1)
      }
      .width(this.padW())
      .height(this.padH())
      .onAreaChange((oldValue: Area, newValue: Area) => {
        this.padWidth = Number(newValue.width);
      })
      .onTouch((event: TouchEvent) => {
        this.touchCount = event.touches.length;
        if (event.type === TouchType.Down) {
          this.onDown(event);
        } else if (event.type === TouchType.Move) {
          if (event.touches.length >= 2) {
            this.onTwoFingerMove(event);
          }
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.onUp(event);
        }
      })
      // 手势锁定 + 移动采集合一：高优先级平移手势抢先"认领"触摸序列，
      // 父容器（页面滚动/Tabs 翻页）永远抢不走，盘内操作绝不外溢
      .priorityGesture(
        PanGesture({ fingers: 1, direction: PanDirection.All, distance: 1 })
          .onActionStart(() => { this.onPanStart(); })
          .onActionUpdate((event: GestureEvent) => { this.onPanUpdate(event); })
          .onActionEnd(() => {
            this.flush();
            this.onInteracting(false);
          })
      )

      // 工具条：一排等宽胶囊 = 左键 / 右键 / 双击 / 拖拽锁定
      Row({ space: 6 }) {
        this.toolBtn('左键', false, () => { this.onTap(); })
        this.toolBtn('右键', false, () => { this.onRightClick(); })
        this.toolBtn('双击', false, () => { this.onDoubleTap(); })
        this.toolBtn(this.dragging ? '松开' : '拖拽', this.dragging, () => {
          this.dragging = !this.dragging;
          this.onDragLock(this.dragging);
        })
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
    // 容器尺寸由外层按屏幕比例分配好，这里只测量、不反推
    .onAreaChange((oldValue: Area, newValue: Area) => {
      const w: number = Number(newValue.width);
      const h: number = Number(newValue.height);
      if (Math.abs(w - this.boxW) > 0.5) {
        this.boxW = w;
      }
      if (Math.abs(h - this.boxH) > 0.5) {
        this.boxH = h;
      }
    })
  }
}
