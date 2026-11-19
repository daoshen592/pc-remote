import { mediaquery, window } from '@kit.ArkUI';
import { common, abilityAccessCtrl } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { Theme, Glyph, Action, Breakpoint, PcEntry } from '../common/UiConfig';
import { RemoteKey } from '../components/RemoteKey';
import { MousePad } from '../components/MousePad';
import { VoiceKey } from '../components/VoiceKey';
import { AppIcon, IconName } from '../components/AppIcon';
import { Settings } from './Settings';
import { Apps } from './Apps';
import { SpeechAssistant } from '../common/SpeechAssistant';
import { sendMagicPacket } from '../common/WakeOnLan';
import { scanPairCode, registerDevice, PairInfo } from '../common/PcPair';
import { net, NetState } from '../common/Net';
import { saveStore } from '../common/Store';

/** WebSocket 指令包：path 决定电脑端走哪个处理分支 */
interface CmdMsg {
  path: string;
  action?: string;
  dx?: number;
  dy?: number;
  type?: string;
  text?: string;
  key?: string;
  keys?: string[];
}

/** 电脑端回包 */
interface CmdReply {
  ok?: boolean;
  say?: string;
  detail?: string;
  msg?: string;
}

/** 统一卡片外观扩展 */
@Extend(Column)
function cardStyle() {
  .width('100%')
  .padding({ left: 14, right: 14, top: 10, bottom: 12 })
  .backgroundColor(Theme.CARD)
  .borderRadius(16)
  .border({ width: 1, color: Theme.CARD_BORDER })
  .shadow({ radius: 12, color: Theme.CARD_SHADOW, offsetY: 3 })
}

/**
 * 手机遥控器主界面（HarmonyOS 卡片风格）。
 * 按键 → WebSocket 长连接（ws://电脑:8765/ws）→ 电脑端桥接服务 → NeoShell API / SendInput。
 * 一条 TCP 常连接跑所有实时指令，不再每条指令单独建连。
 * 自适应：竖屏单列、横屏/平板双栏，断点 xs/sm/md/lg/xl。
 */
@Entry
@Component
struct Index {
  @State private isPortrait: boolean = true;
  @State private breakpoint: Breakpoint = Breakpoint.SM;
  @State private lastAction: string = '';
  @State private voiceText: string = '按住语音键说话（说指令或打字）';
  @State private log: string[] = [];
  private speech: SpeechAssistant = new SpeechAssistant(
    (text: string) => { this.onSpeechResult(text); },
    (msg: string) => { this.onSpeechError(msg); }
  );
  @StorageLink('remote.hostIp') @Watch('onEndpointChanged') hostIp: string = '';
  @StorageLink('remote.port') @Watch('onEndpointChanged') port: string = '8765';
  @StorageLink('remote.sensitivity') sensitivity: number = 1.4;
  @StorageLink('remote.pcMac') pcMac: string = '';
  @StorageLink('remote.pcList') pcListStr: string = '[]';
  @StorageLink('remote.token') token: string = '';
  @State private connState: string = '未配置电脑地址';
  @State private showPowerMenu: boolean = false;
  @State private showPcMenu: boolean = false;
  /** 键盘输入面板：直接往电脑打字 / 发功能键与组合键 */
  @State private showKeyboard: boolean = false;
  @State private kbText: string = '';
  /** 媒体卡片模式：false=媒体控制，true=演示控制（翻页笔） */
  @StorageLink('remote.presentMode') presentMode: boolean = false;
  /** 设置页「使用说明」弹窗是否打开（跨组件共享，返回键要先关它） */
  @StorageLink('ui.showHelp') showHelp: boolean = false;
  @State private currentTab: number = 0;
  private tabsController: TabsController = new TabsController();
  /** 手指在鼠标盘上操作时锁住外层滚动，保证整个界面不动 */
  @State private padInteracting: boolean = false;
  /** 屏幕可用区域（vp 单位），按钮和操控盘按比例自适应，保证一屏 */
  @State private screenW: number = 360;
  @State private screenH: number = 780;
  /** 媒体/系统卡片内容区的「实测」尺寸（onAreaChange 回填），键径据此反推 */
  @State private mediaBodyW: number = 0;
  @State private mediaBodyH: number = 0;
  @State private sysBodyW: number = 0;
  @State private sysBodyH: number = 0;
  /** 按键标签文字的实际高度（vp），由 measureText 实测，跟随系统字体大小 */
  @State private labelTextH: number = 15;

  private listeners: mediaquery.MediaQueryListener[] = [];
  private httpClient: http.HttpRequest = http.createHttp();
  /** 电脑端在线探测：定时 GET /pairinfo，任一次成功即视为"已连接" */
  private pingTimer: number = -1;
  private pinging: boolean = false;
  private appWindow: window.Window | null = null;
  private windowSizeCallback: (size: window.Size) => void = (size: window.Size) => {
    this.updateOrientationByWindow(size.width, size.height);
  };

  aboutToAppear(): void {
    // 先建 WebSocket 长连接（所有实时指令走它），再兜底做一次在线探测
    this.startNet();
    this.startHealthCheck();
    this.measureLabelHeight();
    this.watch('(orientation: portrait)', (matched: boolean) => {
      hilog.info(0x0000, 'RemoteUI', 'mq portrait=%{public}s', matched ? 'true' : 'false');
      this.isPortrait = matched;
    });
    // 主监听：按窗口实际宽高判断，兼容不触发 orientation 查询的机型
    try {
      const ctx: common.Context | undefined = this.getUIContext().getHostContext();
      if (ctx === undefined) {
        hilog.error(0x0000, 'RemoteUI', 'getHostContext undefined');
        return;
      }
      window.getLastWindow(ctx).then((win: window.Window) => {
        this.appWindow = win;
        const props = win.getWindowProperties();
        this.updateOrientationByWindow(props.windowRect.width, props.windowRect.height);
        win.on('windowSizeChange', this.windowSizeCallback);
        hilog.info(0x0000, 'RemoteUI', 'windowSize listening %{public}d x %{public}d',
          props.windowRect.width, props.windowRect.height);
      }).catch((e: BusinessError) => {
        hilog.error(0x0000, 'RemoteUI', 'getLastWindow failed %{public}s', e.message ?? '');
      });
    } catch (error) {
      hilog.error(0x0000, 'RemoteUI', 'window listen exception');
    }
    this.watch('(max-width: 359vp)', (matched: boolean) => {
      if (matched) { this.breakpoint = Breakpoint.XS; }
    });
    this.watch('(min-width: 360vp) and (max-width: 599vp)', (matched: boolean) => {
      if (matched) { this.breakpoint = Breakpoint.SM; }
    });
    this.watch('(min-width: 600vp) and (max-width: 839vp)', (matched: boolean) => {
      if (matched) { this.breakpoint = Breakpoint.MD; }
    });
    this.watch('(min-width: 840vp) and (max-width: 1279vp)', (matched: boolean) => {
      if (matched) { this.breakpoint = Breakpoint.LG; }
    });
    this.watch('(min-width: 1280vp)', (matched: boolean) => {
      if (matched) { this.breakpoint = Breakpoint.XL; }
    });
  }

  aboutToDisappear(): void {
    this.stopHealthCheck();
    for (const listener of this.listeners) {
      listener.off('change');
    }
    this.listeners.splice(0);
    if (this.appWindow !== null) {
      this.appWindow.off('windowSizeChange', this.windowSizeCallback);
      this.appWindow = null;
    }
    this.speech.release();
    this.httpClient.destroy();
  }

  onPageShow(): void {
    // 从后台切回来：确保长连接还在（断了会立刻重拨），状态立刻反映真实情况
    this.startNet();
    this.startHealthCheck();
  }

  onPageHide(): void {
    this.stopHealthCheck();
  }

  /**
   * 系统返回键 / 返回手势：逐层关闭弹层，在主页面上再按一次直接退出应用。
   * 默认行为只是把应用丢到后台（进程还活着、长连接还挂着），这里改成彻底退出。
   */
  onBackPress(): boolean {
    if (this.showHelp) {
      this.showHelp = false;
      return true;
    }
    if (this.showKeyboard) {
      this.showKeyboard = false;
      return true;
    }
    if (this.showPowerMenu) {
      this.showPowerMenu = false;
      return true;
    }
    if (this.showPcMenu) {
      this.showPcMenu = false;
      return true;
    }
    if (this.currentTab !== 0) {
      // 在设置/应用页时，返回先回遥控器主页
      this.currentTab = 0;
      this.tabsController.changeIndex(0);
      return true;
    }
    // 主页面：先落盘配置，再主动结束 Ability（而不是留在后台）
    saveStore();
    const ctx: common.Context | undefined = this.getUIContext().getHostContext();
    if (ctx !== undefined) {
      hilog.info(0x0000, 'RemoteUI', 'back on home -> terminate app');
      (ctx as common.UIAbilityContext).terminateSelf();
    }
    return true;
  }

  // ---------- WebSocket 长连接 ----------

  /**
   * 建立长连接，并把连接状态映射成界面上的状态文字。
   * 幂等：同一个地址重复调用不会重复拨号（NetClient 内部判断）。
   */
  private startNet(): void {
    net.onState = (s: NetState) => {
      if (s === 'open') {
        this.connState = '已连接 · ' + this.hostIp;
      } else if (s === 'connecting') {
        if (!this.connState.startsWith('已连接')) {
          this.connState = '连接中 · ' + this.hostIp;
        }
      } else if (s === 'closed') {
        this.connState = '离线 · 检查电脑端是否运行';
      } else {
        this.connState = '未配置电脑地址';
      }
    };
    net.onText = (text: string) => {
      this.onNetText(text);
    };
    net.connect(this.hostIp, this.port, this.token);
  }

  /** 电脑端回应：只有语音指令会带 say 回话，其余只用来反馈失败原因 */
  private onNetText(text: string): void {
    let reply: CmdReply | null = null;
    try {
      reply = JSON.parse(text) as CmdReply;
    } catch (error) {
      return;
    }
    if (reply === null) {
      return;
    }
    const say: string = reply.say ?? '';
    if (say.length > 0) {
      this.voiceText = say;
      this.addLog('执行反馈: ' + say);
      return;
    }
    const detail: string = reply.detail ?? '';
    if (reply.ok === false && detail.length > 0) {
      this.addLog('电脑端: ' + detail.slice(0, 40));
    }
  }

  /** HTTP 兜底：长连接还没就绪时（刚打开 App 的头一两秒）用它发这一条 */
  private postHttp(path: string, body: string, onFail?: () => void): void {
    if (this.hostIp.trim().length === 0) {
      return;
    }
    const url: string = 'http://' + this.hostIp.trim() + ':' + this.port.trim() + path;
    try {
      this.httpClient.request(url, {
        method: http.RequestMethod.POST,
        header: this.reqHeader(),
        extraData: body,
        connectTimeout: 3000,
        readTimeout: 5000
      }, (err: BusinessError, data: http.HttpResponse) => {
        if (err) {
          hilog.error(0x0000, 'RemoteUI', 'fallback POST failed %{public}s', err.message ?? '');
          if (onFail !== undefined) {
            onFail();
          }
          return;
        }
        hilog.info(0x0000, 'RemoteUI', 'fallback POST %{public}s resp=%{public}d',
          path, data.responseCode);
      });
    } catch (error) {
      hilog.error(0x0000, 'RemoteUI', 'fallback POST exception');
      if (onFail !== undefined) {
        onFail();
      }
    }
  }

  /** 启动在线探测（幂等）：立即探一次，之后每 8 秒一次 */
  private startHealthCheck(): void {
    this.pingOnce();
    if (this.pingTimer < 0) {
      this.pingTimer = setInterval(() => {
        this.pingOnce();
      }, 8000);
    }
  }

  private stopHealthCheck(): void {
    if (this.pingTimer >= 0) {
      clearInterval(this.pingTimer);
      this.pingTimer = -1;
    }
  }

  /** 切换电脑后立刻重拨长连接，不必等下一轮心跳 */
  private onEndpointChanged(): void {
    // 空地址（新用户未配置）不去拨号，直接给出指引
    if (this.hostIp.trim().length === 0) {
      this.connState = '未配置电脑地址 · 去设置页扫码或手动填写';
      return;
    }
    this.connState = '检测中 · ' + this.hostIp.trim();
    net.connect(this.hostIp, this.port, this.token);
    this.pingOnce();
  }

  /**
   * 兜底探测：WebSocket 长连接没建起来时，用一次轻量 HTTP 判断电脑端在不在。
   * 长连接正常时直接跳过——连接状态由 WebSocket 的 open/close 事件驱动，
   * 不需要再轮询（这也是"电脑端在跑却显示未连接"的根治办法）。
   */
  private pingOnce(): void {
    if (net.isOpen()) {
      return;
    }
    const host: string = this.hostIp.trim();
    const port: string = this.port.trim();
    if (host.length === 0 || port.length === 0 || this.pinging) {
      return;
    }
    this.pinging = true;
    const url: string = 'http://' + host + ':' + port + '/pairinfo';
    this.httpClient.request(url, {
      method: http.RequestMethod.GET,
      connectTimeout: 2500,
      readTimeout: 2500
    }).then((data: http.HttpResponse) => {
      this.pinging = false;
      if (data.responseCode === 200) {
        this.connState = '已连接 · ' + host;
      } else if (this.connState.startsWith('已连接')) {
        this.connState = '电脑异常 · HTTP ' + data.responseCode;
      }
    }).catch((err: BusinessError) => {
      this.pinging = false;
      // 只在状态还停在"已连接/检测中"时降级，避免覆盖刚发生的一次具体错误提示
      if (this.connState.startsWith('已连接') || this.connState.startsWith('检测中')) {
        this.connState = '离线 · 检查电脑端是否运行';
      }
      hilog.info(0x0000, 'RemoteUI', 'health ping failed %{public}s', err.message ?? '');
    });
  }

  /** 按窗口实际宽高判断横竖屏（px 单位，只看比例），并把可用区域换算成 vp 供布局自适应 */
  private updateOrientationByWindow(w: number, h: number): void {
    const portrait: boolean = h >= w;
    try {
      this.screenW = this.getUIContext().px2vp(w);
      this.screenH = this.getUIContext().px2vp(h);
    } catch (error) {
      // px2vp 不可用时沿用上次值
    }
    hilog.info(0x0000, 'RemoteUI', 'window %{public}d x %{public}d -> %{public}s (%{public}s x %{public}s vp)',
      w, h, portrait ? 'portrait' : 'landscape',
      String(Math.round(this.screenW)), String(Math.round(this.screenH)));
    if (this.isPortrait !== portrait) {
      this.isPortrait = portrait;
    }
  }

  private watch(condition: string, callback: (matched: boolean) => void): void {
    try {
      const listener: mediaquery.MediaQueryListener =
        this.getUIContext().getMediaQuery().matchMediaSync(condition);
      callback(listener.matches);
      listener.on('change', (result: mediaquery.MediaQueryResult) => {
        callback(result.matches);
      });
      this.listeners.push(listener);
    } catch (error) {
      // 个别设备不支持的条件跳过即可，不影响主体渲染
    }
  }

  /**
   * 按键下方标签占用的高度（vp）：11fp 文字 × 1.35 行高 + 7vp 间距。
   * 跟随系统字体缩放，用户把字体调大时按钮会自动让位，不会把标签挤出卡片。
   */
  /**
   * 实测按键标签的**文字高度**（vp）。
   * 不再按「11fp × 固定行高」猜：系统字体调大时 fp 会跟着放大，
   * 猜小了会把标签挤出卡片。测不到就退回 15vp。
   */
  private measureLabelHeight(): void {
    try {
      const sz: SizeOptions = this.getUIContext().getMeasureUtils().measureTextSize({
        textContent: '播放/暂停',
        fontSize: 11,
        fontWeight: FontWeight.Normal,
        maxLines: 1
      });
      const h: number = this.getUIContext().px2vp(Number(sz.height));
      if (h > 8 && h < 60) {
        this.labelTextH = h;
      }
    } catch (error) {
      hilog.info(0x0000, 'RemoteUI', 'measureLabelHeight fallback 15vp');
    }
  }

  private labelH(): number {
    return this.landscapeCompact() ? 0 : this.labelTextH + 7;
  }

  /**
   * 统一键径：媒体 8 键与系统 3 键用**同一个直径**。
   * 全部由「容器实测尺寸」反推，不猜屏幕、不猜卡片高度：
   *   媒体宽 5×(d+10) + 4×0.14d ≤ W  →  (W-50)/5.56
   *   媒体高 2×(d+label) + 行距10 ≤ H  →  (H-10-2label)/2
   *   系统宽 2×(d+10) + d + 2×0.85d ≤ W  →  (W-20)/4.7
   *   系统高 d + label ≤ H  →  H-label
   */
  private keyD(): number {
    const wm: number = this.mediaBodyW > 0 ? this.mediaBodyW : Math.max(120, this.screenW - 52);
    const hm: number = this.mediaBodyH > 0 ? this.mediaBodyH : 140;
    const ws: number = this.sysBodyW > 0 ? this.sysBodyW : wm;
    const hs: number = this.sysBodyH > 0 ? this.sysBodyH : 80;
    const labelH: number = this.labelH();
    const mediaByW: number = (wm - 50) / 5.56;
    const mediaByH: number = (hm - 10 - labelH * 2) / 2;
    const sysByW: number = (ws - 20) / 4.7;
    // subLabel 小字只出现在返回/电源（标签下方 +10vp），横屏紧凑模式隐藏
    const sysByH: number = hs - labelH - (labelH > 0 ? 10 : 0);
    // 上限只防异常值（正常手机上永远由上面四式决定），下限防容器还没量出来时算出 0
    return Math.max(22, Math.min(120, Math.min(Math.min(mediaByW, mediaByH), Math.min(sysByW, sysByH))));
  }

  /** 媒体键径 = 统一键径（保留函数名，调用点不用改） */
  private mediaD(): number {
    return this.keyD();
  }

  /** 系统键径 = 统一键径 */
  private sysD(): number {
    return this.keyD();
  }

  /**
   * 是否隐藏按键下方的小字。
   * 判据是「系统卡内容区的**实测高度**带标签后还能不能放下一个点得准的键（44vp）」，
   * 不是拿屏幕高度猜——不同分辨率、不同刘海、不同 DPI 下同一句话会得出错误结论。
   */
  private landscapeCompact(): boolean {
    if (this.isPortrait) {
      return false;
    }
    const h: number = this.sysBodyH;
    if (h <= 0) {
      return false;                    // 容器还没量出来，先按完整样式渲染
    }
    return h - 22 < 44;                // 22 = 标签高；带标签后键不到 44 就牺牲标签换键径
  }

  /**
   * 盘面首帧占位直径。真正的尺寸由 MousePad 用**父容器实测宽高**算出来（padW/padH），
   * 这里只防首帧 boxW=0 时算出 0，不做任何布局决策。
   */
  private padSize(): number {
    return Math.max(120, Math.min(this.screenW, this.screenH) * 0.82);
  }

  private isLarge(): boolean {
    return this.breakpoint === Breakpoint.LG || this.breakpoint === Breakpoint.XL;
  }

  /** 解析已保存的电脑列表 */
  private pcEntries(): PcEntry[] {
    try {
      const arr: PcEntry[] = JSON.parse(this.pcListStr) as PcEntry[];
      return Array.isArray(arr) ? arr : [];
    } catch (e) {
      return [];
    }
  }

  /** 当前控制的电脑名（按 host+port 匹配保存列表，没有则显示 IP） */
  private currentPcName(): string {
    for (const p of this.pcEntries()) {
      if (p.host === this.hostIp.trim() && p.port === this.port.trim()) {
        return p.name;
      }
    }
    return this.hostIp.trim();
  }

  /** 状态胶囊：已连接 / 检测中 / 未配置 / 未连接 */
  private connLabel(): string {
    if (this.connState.startsWith('已连接')) {
      return '已连接';
    }
    if (this.connState.startsWith('检测中')) {
      return '检测中';
    }
    if (this.hostIp.trim().length === 0) {
      return '未配置';
    }
    return '未连接';
  }

  private connColor(): string {
    if (this.connState.startsWith('已连接')) {
      return '#2EAD5B';
    }
    if (this.connState.startsWith('检测中')) {
      return Theme.ACCENT;
    }
    if (this.hostIp.trim().length === 0) {
      return Theme.SUB_TEXT;
    }
    return Theme.VOICE;
  }

  private connBg(): string {
    if (this.connState.startsWith('已连接')) {
      return '#E6F6EC';
    }
    if (this.connState.startsWith('检测中')) {
      return Theme.ACCENT_SOFT;
    }
    if (this.hostIp.trim().length === 0) {
      return Theme.KEY_SECONDARY;
    }
    return Theme.VOICE_SOFT;
  }

  private connGlow(): string {
    if (this.connState.startsWith('已连接')) {
      return '#662EAD5B';
    }
    if (this.connState.startsWith('检测中')) {
      return '#334A90FF';
    }
    if (this.hostIp.trim().length === 0) {
      return '#338A97A8';
    }
    return '#66FF7A29';
  }

  private switchPc(entry: PcEntry): void {
    this.hostIp = entry.host;
    this.port = entry.port;
    if (entry.mac.length > 0) {
      this.pcMac = entry.mac;
    }
    // 每台电脑各自一枚令牌，切换时必须跟着换，否则会被电脑端判为未配对
    this.token = entry.token ?? '';
    this.connState = '默认 IP · ' + entry.host;
    this.showPcMenu = false;
    this.addLog('已切换到 ' + entry.name);
  }

  /** 请求头：带设备令牌（电脑端开启「只允许已配对设备」时必需） */
  private reqHeader(): Record<string, string> {
    const h: Record<string, string> = { 'Content-Type': 'application/json' };
    if (this.token.length > 0) {
      h['X-PC-Token'] = this.token;
    }
    return h;
  }

  /** 扫码配对新电脑：解析后自动记住并切换（主页菜单入口） */
  private scanNewPc(): void {
    const ctx: common.Context | undefined = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      this.addLog('扫码暂不可用');
      return;
    }
    this.showPcMenu = false;
    this.voiceText = '对准电脑屏幕上的配对二维码…';
    scanPairCode(ctx).then((info: PairInfo) => {
      const name: string = info.name.length > 0 ? info.name : '电脑-' + info.host;
      const portStr: string = info.port.length > 0 ? info.port : '8765';
      this.voiceText = '正在向电脑登记本机…';
      // 用配对票据换一枚设备令牌（电脑端开了「只允许已配对设备」时必需）
      registerDevice(info.host, portStr, info.ticket, deviceInfo.marketName ?? '鸿蒙手机')
        .then((tk: string) => {
          const entry: PcEntry = {
            name: name, host: info.host, port: portStr, mac: info.mac, token: tk
          };
          const list: PcEntry[] = this.pcEntries()
            .filter((p: PcEntry) => !(p.host === entry.host && p.port === entry.port));
          list.push(entry);
          this.pcListStr = JSON.stringify(list);
          this.switchPc(entry);
          this.voiceText = tk.length > 0 ? ('已配对并切换到 ' + name) : ('已保存 ' + name + '（未取到令牌）');
          this.addLog('扫码配对成功：' + name + '（' + entry.host + '）');
        });
    }).catch((e: BusinessError) => {
      const msg: string = (e instanceof Error) ? (e as Error).message : '扫码失败';
      this.voiceText = msg;
      this.addLog(msg);
    });
  }

  private two(n: number): string {
    return n < 10 ? '0' + n.toString() : n.toString();
  }

  private labelOf(action: string): string {
    if (action === Action.POWER) { return '电源（短按：关闭显示器）'; }
    if (action === Action.POWER + '_long') { return '电源（长按：弹出电源菜单）'; }
    if (action === Action.VOICE) { return '语音（按住说话）'; }
    if (action === Action.UP) { return '方向上'; }
    if (action === Action.DOWN) { return '方向下'; }
    if (action === Action.LEFT) { return '方向左'; }
    if (action === Action.RIGHT) { return '方向右'; }
    if (action === Action.OK) { return 'OK 确认'; }
    if (action === Action.BACK) { return '返回'; }
    if (action === Action.HOME) { return '主页'; }
    if (action === Action.MENU) { return '菜单'; }
    if (action === Action.VOL_UP) { return '音量 +'; }
    if (action === Action.VOL_DOWN) { return '音量 −'; }
    if (action === Action.TV) { return 'TV 键'; }
    if (action === Action.PLAY_PAUSE) { return '播放/暂停'; }
    if (action === Action.REWIND) { return '快退'; }
    if (action === Action.FORWARD) { return '快进'; }
    if (action === Action.MUTE) { return '静音'; }
    if (action === Action.MOUSE_LEFT) { return '鼠标左键'; }
    if (action === Action.MOUSE_RIGHT) { return '鼠标右键'; }
    if (action === Action.MOUSE_DOUBLE) { return '鼠标双击'; }
    if (action === Action.PREV_TRACK) { return '上一集'; }
    if (action === Action.NEXT_TRACK) { return '下一集'; }
    if (action === Action.ALT_TAB) { return '切换窗口 Alt+Tab'; }
    if (action === Action.ALT_F4) { return '关闭窗口 Alt+F4'; }
    if (action === Action.CTRL_V) { return '粘贴 Ctrl+V'; }
    return action;
  }

  private addLog(text: string): void {
    const date: Date = new Date();
    const stamp: string = this.two(date.getHours()) + ':' + this.two(date.getMinutes()) + ':' + this.two(date.getSeconds());
    this.log = [stamp + '  ' + text].concat(this.log.slice(0, 5));
  }

  /** POST 失败时的兜底：给电脑发 WOL 唤醒包，稍后重试原操作 */
  private wakeAndRetry(retry: () => void): void {
    const mac = this.pcMac.trim();
    if (mac.length === 0) {
      this.connState = '连接失败 · 未配置电脑MAC，无法唤醒';
      return;
    }
    this.connState = '电脑无响应 · 发送唤醒包…';
    sendMagicPacket(mac, this.hostIp.trim()).then((ok: boolean) => {
      if (!ok) {
        this.connState = '唤醒包发送失败 · 检查设置里的电脑MAC';
        return;
      }
      this.connState = '唤醒包已发出 · 等待电脑开机（约12秒后重试）…';
      setTimeout(() => {
        retry();
      }, 12000);
    });
  }

  /** 语音"唤醒/开机电脑"且电脑无响应时：只发唤醒包，不重试指令 */
  private wakeOnly(): void {
    const mac = this.pcMac.trim();
    if (mac.length === 0) {
      this.voiceText = '未配置电脑MAC，无法唤醒（去设置页填）';
      return;
    }
    this.voiceText = '电脑无响应 · 已发送唤醒包，正在开机…';
    sendMagicPacket(mac, this.hostIp.trim()).then((ok: boolean) => {
      this.voiceText = ok ? '唤醒包已发出，电脑正在开机，稍等片刻即可遥控' : '唤醒包发送失败，检查设置里的电脑MAC';
      this.addLog('WOL: ' + (ok ? '已发送' : '发送失败'));
    });
  }

  /** 把 Action 发到电脑端：走长连接，未就绪时用一次 HTTP 兜底 */
  private sendAction(action: string, isRetry: boolean = false): void {
    this.lastAction = action;
    if (!isRetry) {
      this.wakeRetries = 0;          // 用户新操作，重置重试计数
      this.addLog(this.labelOf(action));
    }
    if (this.hostIp.trim().length === 0) {
      return;
    }
    const msg: CmdMsg = { path: '/key', action: action };
    if (net.send(msg)) {
      hilog.info(0x0000, 'RemoteUI', 'ws action=%{public}s', action);
      return;
    }
    hilog.info(0x0000, 'RemoteUI', 'fallback POST /key action=%{public}s', action);
    // 电脑可能在睡眠：HTTP 也失败时发魔术包唤醒并重试一次；再失败就停。
    // 不能无限重试——电脑真关机时，这里以前会每 12 秒发一次 WOL 包永远循环下去。
    this.postHttp('/key', JSON.stringify({ action: action }), () => {
      if (this.wakeRetries >= 1) {
        hilog.error(0x0000, 'RemoteUI', 'give up after retry: %{public}s', action);
        this.connState = '电脑无响应 · 请确认电脑已开机且与手机在同一网络';
        return;
      }
      this.wakeRetries++;
      this.wakeAndRetry(() => {
        this.sendAction(action, true);
      });
    });
  }

  /** 唤醒重试计数：0=还没重试过，1=已重试过一次（再失败就放弃） */
  private wakeRetries: number = 0;

  /** 触控盘相对位移：走长连接，高频事件丢了就丢了，不做重试 */
  private sendMove(dx: number, dy: number): void {
    if (this.hostIp.trim().length === 0 || !net.isOpen()) {
      return;
    }
    const msg: CmdMsg = { path: '/move', dx: dx, dy: dy };
    net.send(msg);
  }

  /** 双指滚动：dy>0 手指下滑=页面上滚（与触控板方向一致） */
  private sendScroll(dy: number): void {
    if (this.hostIp.trim().length === 0 || !net.isOpen()) {
      return;
    }
    const msg: CmdMsg = { path: '/scroll', dy: dy };
    net.send(msg);
  }

  private handleKey(action: string): void {
    this.sendAction(action);
  }

  private handleLongKey(action: string): void {
    this.showPowerMenu = true;
    this.addLog('电源长按 → 弹出电源菜单');
  }

  private micGranted: boolean = false;

  private onVoiceDown(): void {
    this.voiceText = '聆听中…松开识别';
    this.startSpeech();
  }

  /**
   * 按需申请麦克风权限后开始识别。
   * 审核合规要求：麦克风属敏感权限，必须在用户触发语音功能时申请，
   * 禁止应用启动即弹授权弹窗。
   */
  private startSpeech(): void {
    if (this.micGranted) {
      this.speech.start();
      return;
    }
    try {
      const ctx: common.Context | undefined = this.getUIContext().getHostContext();
      if (ctx === undefined) {
        this.voiceText = '语音暂不可用';
        return;
      }
      const atManager = abilityAccessCtrl.createAtManager();
      atManager.requestPermissionsFromUser(ctx, ['ohos.permission.MICROPHONE'])
        .then((result) => {
          this.micGranted = result.authResults.length > 0 && result.authResults[0] === 0;
          if (this.micGranted) {
            this.speech.start();
          } else {
            this.voiceText = '需允许麦克风权限才能语音';
          }
          hilog.info(0x0000, 'RemoteUI', 'mic permission granted=%{public}s', String(this.micGranted));
        })
        .catch((e: BusinessError) => {
          this.voiceText = '麦克风权限申请失败';
          hilog.error(0x0000, 'RemoteUI', 'mic perm request failed %{public}s', e.message ?? '');
        });
    } catch (error) {
      hilog.error(0x0000, 'RemoteUI', 'mic perm exception');
    }
  }

  private onVoiceUp(): void {
    this.voiceText = '识别中…';
    this.speech.stop();
  }

  /** 识别成功：显示文字并 POST /text 交给电脑执行（指令或打字） */
  private onSpeechResult(text: string): void {
    this.voiceText = '「' + text + '」';
    this.addLog('语音识别: ' + text);
    this.sendText(text);
  }

  private onSpeechError(msg: string): void {
    this.voiceText = msg;
    this.addLog('语音: ' + msg);
  }

  /** 语音识别结果 → 电脑端（走长连接，回话通过 onNetText 回来） */
  private sendText(text: string): void {
    if (this.hostIp.trim().length === 0) {
      return;
    }
    const msg: CmdMsg = { path: '/text', text: text };
    if (net.send(msg)) {
      hilog.info(0x0000, 'RemoteUI', 'ws text=%{public}s', text);
      return;
    }
    // 长连接未就绪：走 HTTP，这条路径自带回话解析与唤醒重试
    this.postTextHttp(text);
  }

  /** HTTP 版语音：只在长连接没建起来时用 */
  private postTextHttp(text: string): void {
    const url: string = 'http://' + this.hostIp.trim() + ':' + this.port.trim() + '/text';
    hilog.info(0x0000, 'RemoteUI', 'fallback POST %{public}s text=%{public}s', url, text);
    try {
      this.httpClient.request(url, {
        method: http.RequestMethod.POST,
        header: this.reqHeader(),
        extraData: JSON.stringify({ text: text }),
        connectTimeout: 3000,
        // 大模型理解需要联网调用，留足 12 秒读取时间
        readTimeout: 12000
      }, (err: BusinessError, data: http.HttpResponse) => {
        if (err) {
          this.connState = '连接失败 · ' + (err.message ?? '检查 IP/防火墙');
          // 电脑没响应：唤醒类指令只发魔术包；其余指令唤醒后重试一次
          if (/唤醒|叫醒|开机|打开电脑/.test(text)) {
            this.wakeOnly();
          } else {
            this.voiceText = '电脑无响应 · 尝试唤醒电脑…';
            this.wakeAndRetry(() => {
              this.voiceText = '电脑已唤醒 · 重试指令…';
              this.sendText(text);
            });
          }
          return;
        }
        this.connState = data.responseCode === 200 ? '已连接 · ' + this.hostIp : '电脑返回 ' + data.responseCode;
        // 显示电脑端大模型理解后的执行反馈，避免"没反应"错觉
        try {
          const body: string = typeof data.result === 'string' ? data.result : JSON.stringify(data.result);
          const obj: Record<string, Object> = JSON.parse(body) as Record<string, Object>;
          const say: string = typeof obj['say'] === 'string' ? obj['say'] as string : '';
          const cmdDetail: string = typeof obj['detail'] === 'string' ? obj['detail'] as string : '';
          if (say.length > 0) {
            this.voiceText = say;
            this.addLog('执行反馈: ' + say);
          } else if (cmdDetail.length > 0) {
            this.voiceText = '已执行';
            this.addLog('执行: ' + cmdDetail.slice(0, 60));
          }
        } catch (e) {
          hilog.info(0x0000, 'RemoteUI', 'parse /text resp failed');
        }
      });
    } catch (error) {
      this.connState = '发送失败 · 检查网络';
    }
  }

  // ---------- 键盘输入 ----------
  /** 统一发到 /keys：type=text 打字 / key 单键 / combo 组合键 */
  private postKeys(payload: Record<string, Object>): void {
    if (this.hostIp.trim().length === 0) {
      this.addLog('未配置电脑 IP，去设置页填写');
      return;
    }
    if (net.send(payload)) {
      return;
    }
    this.postHttp('/keys', JSON.stringify(payload));
  }

  /** 发送输入框文字（走电脑端剪贴板粘贴，中文和长文本都稳） */
  private sendKbText(): void {
    const txt: string = this.kbText;
    if (txt.length === 0) {
      return;
    }
    this.postKeys({ 'path': '/keys', 'type': 'text', 'text': txt });
    this.addLog('键盘输入: ' + (txt.length > 14 ? txt.substring(0, 14) + '…' : txt));
    this.kbText = '';
  }

  private tapKbKey(label: string, key: string): void {
    this.postKeys({ 'path': '/keys', 'type': 'key', 'key': key });
    this.addLog('键盘: ' + label);
  }

  private sendKbCombo(label: string, keysCsv: string): void {
    const keys: string[] = keysCsv.split(',');
    this.postKeys({ 'path': '/keys', 'type': 'combo', 'keys': keys });
    this.addLog('快捷键: ' + label);
  }

  /** 键盘页的普通功能键 */
  @Builder kbKeyBtn(label: string, key: string) {
    Text(label)
      .fontSize(13)
      .fontColor(Theme.TEXT)
      .textAlign(TextAlign.Center)
      .width('23%')
      .height(38)
      .borderRadius(9)
      .backgroundColor(Theme.KEY_UNIFIED)
      .border({ width: 1, color: Theme.KEY_UNIFIED_BORDER })
      .margin({ bottom: 8 })
      .onClick(() => { this.tapKbKey(label, key); })
  }

  /** 键盘页的组合键 */
  @Builder kbComboBtn(label: string, keysCsv: string) {
    Text(label)
      .fontSize(12)
      .fontColor(Theme.ACCENT)
      .fontWeight(FontWeight.Medium)
      .textAlign(TextAlign.Center)
      .width('31%')
      .height(34)
      .borderRadius(9)
      .backgroundColor(Theme.ACCENT_SOFT)
      .margin({ bottom: 8 })
      .onClick(() => { this.sendKbCombo(label, keysCsv); })
  }

  /** 操控盘标题右侧的「键盘」入口 */
  @Builder keyboardEntry() {
    Row({ space: 4 }) {
      AppIcon({ name: IconName.KEYBOARD, iconSize: 14, color: Theme.ACCENT, lineWidth: 1.8 })
      Text('键盘')
        .fontSize(11)
        .fontColor(Theme.ACCENT)
    }
    .padding({ left: 9, right: 9, top: 5, bottom: 5 })
    .backgroundColor(Theme.KEY_UNIFIED)
    .border({ width: 1, color: Theme.KEY_UNIFIED_BORDER })
    .borderRadius(10)
    .onClick(() => { this.showKeyboard = true; })
  }

  /** 媒体卡片标题 + 「媒体 / 演示」分段切换 */
  @Builder mediaCardHeader() {
    Row() {
      Text(this.presentMode ? '演示控制' : '媒体控制')
        .fontSize(14)
        .fontColor(Theme.TITLE)
        .fontWeight(FontWeight.Bold)
        .layoutWeight(1)

      Row() {
        Text('媒体')
          .fontSize(10)
          .fontColor(this.presentMode ? Theme.SUB_TEXT : '#FFFFFF')
          .backgroundColor(this.presentMode ? Color.Transparent : Theme.ACCENT)
          .width(42)
          .textAlign(TextAlign.Center)
          .padding({ top: 4, bottom: 4 })
          .borderRadius(8)
          .onClick(() => { this.presentMode = false; })
        Text('演示')
          .fontSize(10)
          .fontColor(this.presentMode ? '#FFFFFF' : Theme.SUB_TEXT)
          .backgroundColor(this.presentMode ? Theme.ACCENT : Color.Transparent)
          .width(42)
          .textAlign(TextAlign.Center)
          .padding({ top: 4, bottom: 4 })
          .borderRadius(8)
          .onClick(() => { this.presentMode = true; })
      }
      .padding(2)
      .backgroundColor(Theme.KEY_UNIFIED)
      .border({ width: 1, color: Theme.KEY_UNIFIED_BORDER })
      .borderRadius(10)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  /** 演示键：主标签 + 快捷键提示，两行等宽 */
  @Builder presentKey(label: string, hint: string, code: string, isCombo: boolean, primary: boolean) {
    Column({ space: 2 }) {
      Text(label)
        .fontSize(12)
        .fontColor(primary ? '#FFFFFF' : Theme.TEXT)
        .fontWeight(FontWeight.Medium)
      Text(hint)
        .fontSize(9)
        .fontColor(primary ? '#D8E6FF' : Theme.SUB_TEXT)
    }
    .layoutWeight(1)
    // 高度交给外层两个等分 Row（各占卡片剩余空间一半），切换模式时卡片不会变高变矮
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .borderRadius(12)
    .backgroundColor(primary ? Theme.ACCENT : Theme.KEY_UNIFIED)
    .border({ width: 1, color: primary ? Theme.ACCENT : Theme.KEY_UNIFIED_BORDER })
    .onClick(() => {
      if (isCombo) {
        this.sendKbCombo(label, code);
      } else {
        this.tapKbKey(label, code);
      }
    })
  }

  /**
   * 媒体卡片内容区：占满标题下方剩余高度。
   * 两套键组都在同一块区域里排，卡片高度由外层权重决定 → 切换模式尺寸完全一致。
   */
  @Builder mediaCardBody() {
    if (this.presentMode) {
      // 演示：两行等分剩余高度
      Column({ space: 10 }) {
        Row({ space: 8 }) {
          this.presentKey('上一页', 'PageUp', 'pageup', false, false)
          this.presentKey('下一页', 'PageDown', 'pagedown', false, true)
          this.presentKey('遮黑画面', 'B · 再按恢复', 'b', false, false)
          this.presentKey('遮白画面', 'W · 再按恢复', 'w', false, false)
        }
        .width('100%')
        .layoutWeight(1)

        Row({ space: 8 }) {
          this.presentKey('从头放映', 'F5', 'f5', false, false)
          this.presentKey('从本页放映', 'Shift+F5', 'shift,f5', true, false)
          this.presentKey('结束放映', 'Esc', 'esc', false, false)
        }
        .width('100%')
        .layoutWeight(1)
      }
      .width('100%')
      .layoutWeight(1)
    } else {
      // 媒体：两行按键同径，在剩余高度里居中
      Column({ space: 10 }) {
        Row({ space: this.mediaD() * 0.14 }) {
          this.mediaKey(IconName.PREV_TRACK, Action.PREV_TRACK, '上一集', false)
          this.mediaKey(IconName.REWIND, Action.REWIND, '快退', false)
          this.mediaKey(IconName.PLAY, Action.PLAY_PAUSE, '播放/暂停', true)
          this.mediaKey(IconName.FORWARD, Action.FORWARD, '快进', false)
          this.mediaKey(IconName.NEXT_TRACK, Action.NEXT_TRACK, '下一集', false)
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)

        // 音量行只有 3 个键，间距放大让左右留白与上排呼应，不显得挤在中间
        Row({ space: this.mediaD() * 0.55 }) {
          this.volKey(IconName.VOL_DOWN, Action.VOL_DOWN, '音量−')
          this.volKey(IconName.MUTE, Action.MUTE, '静音')
          this.volKey(IconName.VOL_UP, Action.VOL_UP, '音量+')
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      // 量出内容区真实可用尺寸，键径据此反推（横竖屏/不同分辨率都准）
      .onAreaChange((oldValue: Area, newValue: Area) => {
        const w: number = Number(newValue.width);
        const h: number = Number(newValue.height);
        if (Math.abs(w - this.mediaBodyW) > 0.5) {
          this.mediaBodyW = w;
        }
        if (Math.abs(h - this.mediaBodyH) > 0.5) {
          this.mediaBodyH = h;
        }
      })
    }
  }

  /** 系统控制卡片内容：三个键在剩余高度里垂直居中 */
  @Builder systemCardBody() {
    // 三键只占 2/3 卡宽时左右会空一大块，间距放宽到 0.85d 让排布舒展
    Row({ space: this.sysD() * 0.85 }) {
      this.funcKey(IconName.BACK, Action.BACK, '返回')
      VoiceKey({
        diameter: this.sysD(),
        showLabel: !this.landscapeCompact(),
        subLabel: '按住说话',
        onDown: () => { this.onVoiceDown(); },
        onUp: () => { this.onVoiceUp(); }
      })
      this.powerKey()
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .onAreaChange((oldValue: Area, newValue: Area) => {
      const w: number = Number(newValue.width);
      const h: number = Number(newValue.height);
      if (Math.abs(w - this.sysBodyW) > 0.5) {
        this.sysBodyW = w;
      }
      if (Math.abs(h - this.sysBodyH) > 0.5) {
        this.sysBodyH = h;
      }
    })
  }

  // ---------- 键盘输入面板 ----------
  @Builder buildKeyboardPanel() {
    Stack({ alignContent: Alignment.Bottom }) {
      // 遮罩：点空白处关闭
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#990F1B2A')
        .onClick(() => { this.showKeyboard = false; })

      Column({ space: 10 }) {
        Row() {
          Column({ space: 2 }) {
            Text('键盘输入')
              .fontSize(17)
              .fontColor(Theme.TITLE)
              .fontWeight(FontWeight.Bold)
            Text('打字会直接送到电脑当前窗口')
              .fontSize(10)
              .fontColor(Theme.SUB_TEXT)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Text('关闭')
            .fontSize(12)
            .fontColor(Theme.ACCENT)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .backgroundColor(Theme.ACCENT_SOFT)
            .borderRadius(10)
            .onClick(() => { this.showKeyboard = false; })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        TextArea({ text: this.kbText, placeholder: '在这里打字，支持中文' })
          .height(72)
          .fontSize(14)
          .fontColor(Theme.TEXT)
          .backgroundColor(Theme.KEY)
          .borderRadius(10)
          .border({ width: 1, color: Theme.KEY_BORDER })
          .onChange((value: string) => { this.kbText = value; })

        Row({ space: 8 }) {
          Button('发送到电脑')
            .layoutWeight(1)
            .height(38)
            .fontSize(14)
            .backgroundColor(Theme.ACCENT)
            .fontColor(Color.White)
            .borderRadius(10)
            .onClick(() => { this.sendKbText(); })
          Button('清空')
            .width(76)
            .height(38)
            .fontSize(13)
            .backgroundColor(Theme.KEY_SECONDARY)
            .fontColor(Theme.SUB_TEXT)
            .borderRadius(10)
            .onClick(() => { this.kbText = ''; })
        }
        .width('100%')

        Scroll() {
          Column() {
            Text('常用键')
              .fontSize(11)
              .fontColor(Theme.SUB_TEXT)
              .width('100%')
              .margin({ bottom: 6 })
            Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
              this.kbKeyBtn('Esc', 'esc')
              this.kbKeyBtn('Tab', 'tab')
              this.kbKeyBtn('⌫ 退格', 'backspace')
              this.kbKeyBtn('⏎ 回车', 'enter')
              this.kbKeyBtn('←', 'left')
              this.kbKeyBtn('↑', 'up')
              this.kbKeyBtn('↓', 'down')
              this.kbKeyBtn('→', 'right')
              this.kbKeyBtn('Home', 'home')
              this.kbKeyBtn('End', 'end')
              this.kbKeyBtn('PgUp', 'pageup')
              this.kbKeyBtn('PgDn', 'pagedown')
              this.kbKeyBtn('Win', 'win')
              this.kbKeyBtn('空格', 'space')
              this.kbKeyBtn('Del', 'delete')
              this.kbKeyBtn('F5', 'f5')
            }
            .width('100%')

            Text('组合键')
              .fontSize(11)
              .fontColor(Theme.SUB_TEXT)
              .width('100%')
              .margin({ top: 4, bottom: 6 })
            Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
              this.kbComboBtn('Ctrl+C', 'ctrl,c')
              this.kbComboBtn('Ctrl+V', 'ctrl,v')
              this.kbComboBtn('Ctrl+X', 'ctrl,x')
              this.kbComboBtn('Ctrl+Z', 'ctrl,z')
              this.kbComboBtn('Ctrl+A', 'ctrl,a')
              this.kbComboBtn('Ctrl+S', 'ctrl,s')
              this.kbComboBtn('Ctrl+F', 'ctrl,f')
              this.kbComboBtn('Alt+Tab', 'alt,tab')
              this.kbComboBtn('Alt+F4', 'alt,f4')
              this.kbComboBtn('Win+D', 'win,d')
              this.kbComboBtn('Win+E', 'win,e')
              this.kbComboBtn('Win+L', 'win,l')
            }
            .width('100%')
          }
          .width('100%')
        }
        .scrollBar(BarState.Off)
        .layoutWeight(1)
      }
      .padding({ left: 16, right: 16, top: 16, bottom: 12 })
      .width('100%')
      .backgroundColor(Theme.CARD)
      .borderRadius({ topLeft: 20, topRight: 20 })
      .constraintSize({ maxHeight: '88%' })
    }
    .width('100%')
    .height('100%')
  }

  /** 底部导航项：图标 + 文字，选中态高亮 */
  @Builder tabBarItem(icon: string, label: string, index: number) {
    Column({ space: 1 }) {
      AppIcon({
        name: icon,
        iconSize: 18,
        color: this.currentTab === index ? Theme.ACCENT : Theme.SUB_TEXT,
        lineWidth: 1.8
      })
      Text(label)
        .fontSize(9)
        .fontColor(this.currentTab === index ? Theme.ACCENT : Theme.SUB_TEXT)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Tabs({ barPosition: BarPosition.End, controller: this.tabsController }) {
        // Tab 1：遥控器
        TabContent() {
          Column() {
            this.buildHeader()

            if (this.isPortrait) {
              this.buildPortraitRemote()
            } else {
              this.buildLandscapeRemote()
            }
          }
          .width('100%')
          .height('100%')
          .backgroundColor(Theme.BG_BOTTOM)
        }
        .tabBar(this.tabBarItem(IconName.REMOTE, '遥控器', 0))

        // Tab 2：应用启动器（电脑开始菜单程序宫格）
        TabContent() {
          Apps()
        }
        .tabBar(this.tabBarItem(IconName.APPS, '应用', 1))

        // Tab 3：设置
        TabContent() {
          Settings()
        }
        .tabBar(this.tabBarItem(IconName.SETTINGS, '设置', 2))
      }
      .width('100%')
      .height('100%')
      .barHeight(44)
      .barBackgroundColor(Theme.CARD)
      // 关闭左右滑动切换：避免操控盘手势被误判成切到另一个 Tab；只允许点底部标签切换
      .scrollable(false)
      .onChange((index: number) => {
        this.currentTab = index;
      })

      if (this.showPowerMenu) {
        this.buildPowerMenu()
      }
      if (this.showPcMenu) {
        this.buildPcMenu()
      }
      if (this.showKeyboard) {
        this.buildKeyboardPanel()
      }
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 横屏系统卡标题：副标题在 builder 内部读状态。
   * @Builder 的参数是按值传递的（首帧 sysBodyH 还没量出来，传进来的字符串永远是空且不再刷新），
   * 所以「长按提示」不能当参数传，必须写成内部 if 才会跟着 landscapeCompact() 重新求值。
   */
  @Builder systemCardTitleLandscape() {
    Column({ space: 2 }) {
      Text('系统控制')
        .fontSize(14)
        .fontColor(Theme.TITLE)
        .fontWeight(FontWeight.Bold)
      if (this.landscapeCompact()) {
        Text('长按返回=强退 · 长按电源=菜单')
          .fontSize(9)
          .fontColor(Theme.SUB_TEXT)
          .maxLines(1)
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  // ---------- 卡片标题 ----------
  @Builder cardTitle(title: string, subtitle: string) {
    Column({ space: 2 }) {
      Text(title)
        .fontSize(14)
        .fontColor(Theme.TITLE)
        .fontWeight(FontWeight.Bold)
      if (subtitle.length > 0) {
        Text(subtitle)
          .fontSize(10)
          .fontColor(Theme.SUB_TEXT)
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  // ---------- 顶部：软件名与当前电脑并排 ----------
  @Builder buildHeader() {
    Row({ space: 8 }) {
      // 软件名（固定宽度，不参与压缩）
      Text('电脑遥控器')
        .fontSize(19)
        .fontColor(Theme.TITLE)
        .fontWeight(FontWeight.Bold)

      // 当前控制的电脑：与软件名同一行，点击弹出切换菜单；名字过长自动省略
      Row({ space: 3 }) {
        // 未配置电脑时不说"当前："（后面会空着），直接引导去设置页
        Text(this.hostIp.trim().length === 0 ? '添加电脑 · 去设置' : '当前：' + this.currentPcName())
          .fontSize(10)
          .fontColor(Theme.ACCENT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
        AppIcon({ name: IconName.DOWN, iconSize: 9, color: Theme.ACCENT, lineWidth: 2 })
      }
      .layoutWeight(1)
      .padding({ left: 8, right: 6, top: 4, bottom: 4 })
      .backgroundColor(Theme.ACCENT_SOFT)
      .borderRadius(11)
      .onClick(() => {
        if (this.hostIp.trim().length === 0) {
          // 还没配电脑：直接跳到设置页（扫码配对/手动填写都在那里）
          this.tabsController.changeIndex(2);
        } else {
          this.showPcMenu = true;
        }
      })

      // 连接状态胶囊
      Row({ space: 5 }) {
        Column()
          .width(7)
          .height(7)
          .borderRadius(4)
          .backgroundColor(this.connColor())
          .shadow({ radius: 6, color: this.connGlow() })
        Text(this.connLabel())
          .fontSize(10)
          .fontColor(this.connColor())
          .fontWeight(FontWeight.Medium)
      }
      .padding({ left: 9, right: 9, top: 5, bottom: 5 })
      .backgroundColor(this.connBg())
      .borderRadius(13)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: 18, right: 18, top: 10, bottom: 6 })
  }

  // ---------- 竖屏（三块容器按固定比例分配整屏高度） ----------
  @Builder buildPortraitRemote() {
    Column({ space: 6 }) {
      // 鼠标操控盘 1.9 / 4.4 ≈ 43%
      Column({ space: 4 }) {
        Stack({ alignContent: Alignment.End }) {
          this.cardTitle('鼠标操控盘', '')
          this.keyboardEntry()
        }
        .width('100%')
        Column() {
          this.buildMousePad()
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      }
      .cardStyle()
      .layoutWeight(1.9)

      // 媒体控制 / 演示控制 1.45 / 4.15 ≈ 35%（两种模式共用同一块高度）
      // 键径全 App 统一后，媒体卡要放两排满径键 → 从系统卡匀一部分高度过来
      Column({ space: 10 }) {
        this.mediaCardHeader()
        this.mediaCardBody()
      }
      .cardStyle()
      .layoutWeight(1.45)

      // 系统控制 0.8 / 4.15 ≈ 19%（一行三键，只需一个键高就够了，多给是浪费）
      Column({ space: 10 }) {
        this.cardTitle('系统控制', '')
        this.systemCardBody()
      }
      .cardStyle()
      .layoutWeight(0.8)
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 0, bottom: 6 })
    .layoutWeight(1)
  }

  // ---------- 横屏 / 平板：左栏鼠标盘，右栏上下媒体+系统（全部按固定权重分配） ----------
  @Builder buildLandscapeRemote() {
    Row({ space: 10 }) {
      // 左栏：鼠标操控盘，权重 1.15 / 2.15 ≈ 53.5%
      Column({ space: 4 }) {
        Stack({ alignContent: Alignment.End }) {
          this.cardTitle('鼠标操控盘', '')
          this.keyboardEntry()
        }
        .width('100%')
        Column() {
          this.buildMousePad()
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      }
      .layoutWeight(1.15)
      .cardStyle()

      // 右栏：媒体 1.45 : 系统 1.0
      // 比例必须跟着「内容需求」走——媒体两排 = 2d+行距，系统一排 = d。
      // 之前给系统 0.72 压得太狠，它的一键高反过来成了统一直径的天花板（实测被卡在 33vp）。
      Column({ space: 8 }) {
        Column({ space: 8 }) {
          this.mediaCardHeader()
          this.mediaCardBody()
        }
        .cardStyle()
        .layoutWeight(1.45)

        Column({ space: 8 }) {
          // 横屏紧凑时键下小字被隐藏，长按提示改由副标题承担
          this.systemCardTitleLandscape()
          this.systemCardBody()
        }
        .cardStyle()
        .layoutWeight(1.0)
      }
      .layoutWeight(1.0)
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: 12, right: 12, top: 2, bottom: 10 })
  }

  // ---------- 鼠标操控盘（仅方形盘，无独立左右键） ----------
  @Builder buildMousePad() {
    Column() {
      // 盘面吃掉除说明行以外的全部高度；MousePad 内部按容器实测尺寸自适配
      Column() {
        MousePad({
          diameter: this.padSize(),
          sensitivity: this.sensitivity,
          onMove: (dx: number, dy: number) => { this.sendMove(dx, dy); },
          onScroll: (dy: number) => { this.sendScroll(dy); },
          onTap: () => { this.handleKey(Action.MOUSE_LEFT); },
          onDoubleTap: () => { this.handleKey(Action.MOUSE_DOUBLE); },
          onLongPress: () => { this.handleKey(Action.MOUSE_RIGHT); },
          onRightClick: () => { this.handleKey(Action.MOUSE_RIGHT); },
          onDragLock: (locked: boolean) => { this.sendAction(locked ? 'mouse_down' : 'mouse_up'); },
          onInteracting: (active: boolean) => { this.padInteracting = active; }
        })
      }
      .width('100%')
      .layoutWeight(1)

      // 手势说明：一行小字贴在操控盘卡片最底部（盘面按剩余高度自适应缩小）
      Text('滑动移动光标 · 轻点左键 · 双击双击 · 长按右键 · 双指滑滚轮')
        .fontSize(9)
        .fontColor(Theme.SUB_TEXT)
        .maxLines(1)
        .textAlign(TextAlign.Center)
        .width('100%')
        .margin({ top: 2 })
    }
    .width('100%')
    .height('100%')
  }

  // ---------- 大屏日志面板 ----------
  @Builder buildLogPanel() {
    Column({ space: 4 }) {
      Row() {
        Text('操作记录')
          .fontSize(11)
          .fontColor(Theme.TEXT)
          .fontWeight(FontWeight.Medium)
        Blank()
        Text(this.voiceText)
          .fontSize(10)
          .fontColor(Theme.ACCENT)
      }
      .width('100%')
      ForEach(this.log, (item: string) => {
        Text(item)
          .fontSize(10)
          .fontColor(Theme.SUB_TEXT)
          .width('100%')
      }, (item: string) => item)
    }
    .width('100%')
    .padding({ left: 18, right: 18, top: 10, bottom: 12 })
    .backgroundColor(Theme.CARD)
    .borderRadius(14)
    .border({ width: 1, color: Theme.CARD_BORDER })
  }

  // ---------- 电源菜单 ----------
  @Builder buildPowerMenu() {
    Column() {
      Column({ space: 14 }) {
        Column({ space: 4 }) {
          Text('电源操作')
            .fontSize(18)
            .fontColor(Theme.TITLE)
            .fontWeight(FontWeight.Bold)
          Text('短按电源键=关闭显示器；关机/重启 10 秒后生效')
            .fontSize(11)
            .fontColor(Theme.SUB_TEXT)
        }
        .width('100%')

        Button('关闭显示器')
          .width('100%')
          .height(42)
          .fontSize(14)
          .backgroundColor(Theme.ACCENT_SOFT)
          .fontColor(Theme.ACCENT)
          .borderRadius(10)
          .onClick(() => {
            this.showPowerMenu = false;
            this.sendAction(Action.POWER);
          })
        Button('锁屏')
          .width('100%')
          .height(42)
          .fontSize(14)
          .backgroundColor(Theme.ACCENT_SOFT)
          .fontColor(Theme.ACCENT)
          .borderRadius(10)
          .onClick(() => {
            this.showPowerMenu = false;
            this.sendAction('lock');
          })
        Button('睡眠')
          .width('100%')
          .height(42)
          .fontSize(14)
          .backgroundColor(Theme.ACCENT_SOFT)
          .fontColor(Theme.ACCENT)
          .borderRadius(10)
          .onClick(() => {
            this.showPowerMenu = false;
            this.sendAction('power_sleep');
          })
        Button('关机')
          .width('100%')
          .height(42)
          .fontSize(14)
          .backgroundColor(Theme.DANGER_SOFT)
          .fontColor(Theme.DANGER)
          .borderRadius(10)
          .onClick(() => {
            this.showPowerMenu = false;
            this.sendAction('power_shutdown');
          })
        Button('重启')
          .width('100%')
          .height(42)
          .fontSize(14)
          .backgroundColor(Theme.DANGER_SOFT)
          .fontColor(Theme.DANGER)
          .borderRadius(10)
          .onClick(() => {
            this.showPowerMenu = false;
            this.sendAction('power_reboot');
          })
        Button('唤醒电脑（发魔术包）')
          .width('100%')
          .height(42)
          .fontSize(14)
          .backgroundColor(Theme.VOICE_SOFT)
          .fontColor(Theme.VOICE)
          .borderRadius(10)
          .onClick(() => {
            this.showPowerMenu = false;
            this.wakeOnly();
          })
        Button('取消')
          .width('100%')
          .height(40)
          .fontSize(13)
          .backgroundColor(Theme.BG_TOP)
          .fontColor(Theme.SUB_TEXT)
          .borderRadius(10)
          .onClick(() => {
            this.showPowerMenu = false;
          })
      }
      .padding(22)
      .width('82%')
      .backgroundColor(Theme.CARD)
      .borderRadius(20)
      .shadow({ radius: 24, color: '#33000000', offsetY: 8 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#990F1B2A')
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.showPowerMenu = false;
    })
  }

  // ---------- 电脑切换菜单 ----------
  @Builder buildPcMenu() {
    Column() {
      Column({ space: 12 }) {
        Column({ space: 4 }) {
          Text('选择要控制的电脑')
            .fontSize(18)
            .fontColor(Theme.TITLE)
            .fontWeight(FontWeight.Bold)
          Text('点击列表即切换；或点下方按钮扫码配对新电脑')
            .fontSize(11)
            .fontColor(Theme.SUB_TEXT)
        }
        .width('100%')

        if (this.pcEntries().length === 0) {
          Text('还没有保存的电脑\n点下方按钮扫码配对新电脑')
            .fontSize(12)
            .fontColor(Theme.SUB_TEXT)
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: 8, bottom: 8 })
        } else {
          ForEach(this.pcEntries(), (p: PcEntry) => {
            Row({ space: 10 }) {
              AppIcon({
                name: this.currentPcName() === p.name ? IconName.CHECK : IconName.REMOTE,
                iconSize: 20,
                color: this.currentPcName() === p.name ? Theme.ACCENT : Theme.SUB_TEXT,
                lineWidth: 2
              })
              Column({ space: 2 }) {
                Text(p.name)
                  .fontSize(14)
                  .fontColor(Theme.TEXT)
                  .fontWeight(FontWeight.Medium)
                Text(p.host + ':' + p.port)
                  .fontSize(10)
                  .fontColor(Theme.SUB_TEXT)
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
            }
            .width('100%')
            .padding(10)
            .borderRadius(10)
            .backgroundColor(this.currentPcName() === p.name ? Theme.ACCENT_SOFT : Theme.KEY)
            .onClick(() => {
              this.switchPc(p);
            })
          }, (p: PcEntry) => p.host + ':' + p.port + ':' + p.name)
        }

        Button('＋ 扫码配对新电脑')
          .width('100%')
          .height(44)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .backgroundColor(Theme.ACCENT_SOFT)
          .fontColor(Theme.ACCENT)
          .borderRadius(10)
          .onClick(() => {
            this.scanNewPc();
          })

        Button('关闭')
          .width('100%')
          .height(40)
          .fontSize(13)
          .backgroundColor(Theme.BG_TOP)
          .fontColor(Theme.SUB_TEXT)
          .borderRadius(10)
          .onClick(() => {
            this.showPcMenu = false;
          })
      }
      .padding(22)
      .width('82%')
      .backgroundColor(Theme.CARD)
      .borderRadius(20)
      .shadow({ radius: 24, color: '#33000000', offsetY: 8 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#990F1B2A')
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.showPcMenu = false;
    })
  }

  // ---------- 按键构造器 ----------
  @Builder powerKey() {
    RemoteKey({
      icon: IconName.POWER,
      label: '电源',
      action: Action.POWER,
      diameter: this.sysD(),
      glyphSize: this.sysD() * 0.46,
      // 淡红背景 + 红色图标：电源属警示类操作，与「返回」保持同一套警示材质
      glyphColor: Theme.DANGER,
      bg: Theme.DANGER_SOFT,
      pressedBg: Theme.DANGER_SOFT_PRESSED,
      keyBorderColor: Theme.KEY_UNIFIED_BORDER,
      subLabel: '长按菜单',
      // 横屏矮屏隐藏小字，把高度让给键径
      showLabel: !this.landscapeCompact(),
      supportLongPress: true,
      onKey: (action: string) => { this.handleKey(action); },
      onLongPress: (action: string) => { this.handleLongKey(action); }
    })
  }

  @Builder funcKey(iconName: string, action: string, label: string) {
    RemoteKey({
      icon: iconName,
      label: label,
      action: action,
      diameter: this.sysD(),
      glyphSize: this.sysD() * 0.44,
      // 淡红背景 + 红色图标：与「电源」同一套警示材质
      glyphColor: Theme.DANGER,
      bg: Theme.DANGER_SOFT,
      pressedBg: Theme.DANGER_SOFT_PRESSED,
      keyBorderColor: Theme.KEY_UNIFIED_BORDER,
      subLabel: action === Action.BACK ? '长按强退' : '',
      showLabel: !this.landscapeCompact(),
      // 返回键支持长按：短按=智能返回(自动选后退/关弹窗/退全屏)，长按=强制后退
      supportLongPress: action === Action.BACK,
      onLongPress: (a: string) => {
        if (a === Action.BACK) {
          this.handleKey('browser_back');
        } else {
          this.handleKey(a);
        }
      },
      onKey: (a: string) => { this.handleKey(a); }
    })
  }

  @Builder volKey(iconName: string, action: string, label: string) {
    RemoteKey({
      icon: iconName,
      label: label,
      action: action,
      diameter: this.mediaD(),
      glyphSize: this.mediaD() * 0.46,
      glyphColor: Theme.ACCENT,
      bg: Theme.KEY_UNIFIED,
      pressedBg: Theme.KEY_PRESSED,
      keyBorderColor: Theme.KEY_UNIFIED_BORDER,
      // 横屏矮屏隐藏小字，把高度让给图标
      showLabel: !this.landscapeCompact(),
      onKey: (a: string) => { this.handleKey(a); }
    })
  }

  /** 媒体键：与音量键**同径同色**，两排看起来就是一个整体；primary=主操作（播放/暂停）淡蓝提亮 */
  @Builder mediaKey(iconName: string, action: string, label: string, primary: boolean) {
    RemoteKey({
      icon: iconName,
      label: label,
      action: action,
      diameter: this.mediaD(),
      glyphSize: this.mediaD() * 0.42,
      glyphColor: primary ? Theme.ACCENT_PRESSED : Theme.ACCENT,
      bg: primary ? Theme.ACCENT_SOFT : Theme.KEY_UNIFIED,
      pressedBg: primary ? '#D3E3FF' : Theme.KEY_PRESSED,
      keyBorderColor: primary ? '#D5E3FF' : Theme.KEY_UNIFIED_BORDER,
      showLabel: !this.landscapeCompact(),
      onKey: (a: string) => { this.handleKey(a); }
    })
  }

  @Builder mouseKey(iconName: string, action: string, label: string) {
    RemoteKey({
      icon: iconName,
      label: label,
      action: action,
      diameter: this.sysD() * 0.9,
      glyphSize: this.sysD() * 0.46,
      glyphColor: Theme.ACCENT,
      bg: Theme.ACCENT_SOFT,
      pressedBg: '#D3E3FF',
      keyBorderColor: '#DCE8FF',
      showLabel: !this.landscapeCompact(),
      onKey: (a: string) => { this.handleKey(a); }
    })
  }
}
