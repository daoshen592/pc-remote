import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { Theme, PcEntry } from '../common/UiConfig';
import { AppIcon, IconName } from '../components/AppIcon';
import { scanPairCode, registerDevice, PairInfo } from '../common/PcPair';

/** 统一卡片外观扩展（设置页复用主页面风格） */
@Extend(Column)
function cardStyle() {
  .width('100%')
  .padding({ left: 14, right: 14, top: 12, bottom: 14 })
  .backgroundColor(Theme.CARD)
  .borderRadius(16)
  .border({ width: 1, color: Theme.CARD_BORDER })
  .shadow({ radius: 12, color: Theme.CARD_SHADOW, offsetY: 3 })
}

/**
 * 设置页面：电脑连接参数 + 操控参数。
 * 配置写入 AppStorage，主页面通过 @StorageLink 实时读取，返回即生效。
 */
@Component
export struct Settings {
  @StorageLink('remote.hostIp') hostIp: string = '192.168.1.168';
  @StorageLink('remote.port') port: string = '8765';
  @StorageLink('remote.sensitivity') sensitivity: number = 1.4;
  @StorageLink('remote.pcMac') pcMac: string = 'A0-AD-9F-18-C2-42';
  @StorageLink('remote.pcList') pcListStr: string = '[]';
  @StorageLink('remote.token') token: string = '';
  @State private testText: string = '点击测试与电脑桥接服务的连接';
  @State private testing: boolean = false;
  // 电脑管理（多台记忆）
  @State private pcEntries: PcEntry[] = [];
  @State private newPcName: string = '';
  @State private scanStatus: string = '';
  @State private scanning: boolean = false;
  private httpClient: http.HttpRequest = http.createHttp();

  aboutToAppear(): void {
    this.reloadPcList();
  }

  aboutToDisappear(): void {
    this.httpClient.destroy();
  }

  // ---------- 电脑管理 ----------
  private reloadPcList(): void {
    try {
      const arr: PcEntry[] = JSON.parse(this.pcListStr) as PcEntry[];
      this.pcEntries = Array.isArray(arr) ? arr : [];
    } catch (e) {
      this.pcEntries = [];
    }
  }

  private savePcList(entries: PcEntry[]): void {
    this.pcEntries = entries;
    this.pcListStr = JSON.stringify(entries);
  }

  /** 当前控制的是列表里的哪台（按 host+port 匹配），没有则显示 IP */
  private currentPcName(): string {
    for (const p of this.pcEntries) {
      if (p.host === this.hostIp.trim() && p.port === this.port.trim()) {
        return p.name;
      }
    }
    return this.hostIp.trim();
  }

  private selectPc(entry: PcEntry): void {
    this.hostIp = entry.host;
    this.port = entry.port;
    if (entry.mac.length > 0) {
      this.pcMac = entry.mac;
    }
    this.token = entry.token ?? '';
    this.scanStatus = '已切换到「' + entry.name + '」';
    hilog.info(0x0000, 'RemoteUI', 'switch pc -> %{public}s (%{public}s)', entry.name, entry.host);
  }

  /** 把当前连接配置保存为列表里的一台电脑（同名覆盖） */
  private saveCurrentPc(): void {
    const name = this.newPcName.trim();
    if (name.length === 0) {
      this.scanStatus = '请先给电脑起个名字（如：书房台式机）';
      return;
    }
    let keepToken: string = this.token;
    for (const p of this.pcEntries) {
      if (p.host === this.hostIp.trim() && p.port === this.port.trim() && (p.token ?? '').length > 0) {
        keepToken = p.token;
      }
    }
    const entry: PcEntry = {
      name: name,
      host: this.hostIp.trim(),
      port: this.port.trim(),
      mac: this.pcMac.trim(),
      token: keepToken
    };
    const others: PcEntry[] =
      this.pcEntries.filter((p: PcEntry) => !(p.host === entry.host && p.port === entry.port));
    others.push(entry);
    this.savePcList(others);
    this.newPcName = '';
    this.scanStatus = '已保存「' + name + '」，共 ' + others.length + ' 台';
  }

  private deletePc(index: number): void {
    const name: string = this.pcEntries[index].name;
    const others: PcEntry[] = this.pcEntries.filter((_: PcEntry, i: number) => i !== index);
    this.savePcList(others);
    this.scanStatus = '已删除「' + name + '」';
  }

  /**
   * 扫码配对：电脑端浏览器打开 http://<电脑IP>:8765/pair 显示二维码，
   * 手机这里扫码解析 pc-remote://pair?host=&port=&mac=&name= 自动填写。
   * 相机权限与扫码逻辑统一在 common/PcPair.ets。
   */
  private startPairScan(): void {
    const ctx: common.Context | undefined = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      this.scanStatus = '扫码暂不可用';
      return;
    }
    this.scanning = true;
    this.scanStatus = '对准电脑屏幕上的二维码…';
    scanPairCode(ctx).then((info: PairInfo) => {
      this.scanning = false;
      this.hostIp = info.host;
      if (info.port.length > 0) {
        this.port = info.port;
      }
      if (info.mac.length > 0) {
        this.pcMac = info.mac;
      }
      const shown: string = info.name.length > 0 ? info.name : info.host;
      this.scanStatus = '已扫码：' + shown + '，正在登记本机…';
      hilog.info(0x0000, 'RemoteUI', 'pair scanned %{public}s %{public}s', info.name, info.host);
      // 用配对票据换设备令牌（电脑端开启「只允许已配对设备」时必需）
      const portStr: string = info.port.length > 0 ? info.port : '8765';
      registerDevice(info.host, portStr, info.ticket, deviceInfo.marketName ?? '鸿蒙手机')
        .then((tk: string) => {
          this.token = tk;
          if (tk.length > 0) {
            this.scanStatus = '已配对：' + shown + '，起名后点"保存当前配置"记住它';
          } else {
            this.scanStatus = '已扫码：' + shown + '（未取到令牌，电脑端若开了强校验需重新扫码）';
          }
        });
    }).catch((e: BusinessError) => {
      this.scanning = false;
      const msg: string = (e instanceof Error) ? (e as Error).message : '扫码失败';
      this.scanStatus = msg;
    });
  }

  /** GET 桥接服务首页，200 即视为连通（只读、无副作用） */
  private testConnection(): void {
    const ip = this.hostIp.trim();
    const port = this.port.trim();
    if (ip.length === 0) {
      this.testText = '请先填写电脑 IP';
      return;
    }
    // 用 /pairinfo 而不是首页：首页现在要设备令牌，未配对时会 401
    const url = 'http://' + ip + ':' + port + '/pairinfo';
    this.testing = true;
    this.testText = '正在连接 ' + url + ' …';
    try {
      this.httpClient.request(url, {
        method: http.RequestMethod.GET,
        connectTimeout: 3000,
        readTimeout: 3000
      }, (err: BusinessError, data: http.HttpResponse) => {
        this.testing = false;
        if (err) {
          this.testText = '连接失败：' + (err.message ?? '检查 IP / 端口 / 防火墙');
          hilog.error(0x0000, 'RemoteUI', 'settings test failed %{public}s', err.message ?? '');
          return;
        }
        if (data.responseCode === 200) {
          this.testText = '连接成功 · 电脑桥接服务已就绪';
        } else {
          this.testText = '电脑返回 HTTP ' + data.responseCode;
        }
        hilog.info(0x0000, 'RemoteUI', 'settings test resp=%{public}d', data.responseCode);
      });
    } catch (error) {
      this.testing = false;
      this.testText = '连接失败：请求异常';
    }
  }

  private resetDefaults(): void {
    this.hostIp = '192.168.1.168';
    this.port = '8765';
    this.sensitivity = 1.4;
    this.pcMac = 'A0-AD-9F-18-C2-42';
    this.testText = '已恢复默认设置';
  }

  @Builder sectionTitle(text: string) {
    Row({ space: 6 }) {
      Column()
        .width(3)
        .height(12)
        .borderRadius(2)
        .backgroundColor(Theme.ACCENT)
      Text(text)
        .fontSize(12)
        .fontColor(Theme.SUB_TEXT)
        .fontWeight(FontWeight.Medium)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .margin({ top: 4, bottom: 2 })
  }

  build() {
    Column() {
      // 顶部标题栏（作为 Tab 页，无需返回按钮）
      Row() {
        Text('设置')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.TITLE)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 10 })

      Scroll() {
        Column({ space: 10 }) {
          // 连接设置
          Column({ space: 10 }) {
            this.sectionTitle('电脑连接')
            Row() {
              Text('电脑 IP')
                .fontSize(13)
                .fontColor(Theme.TEXT)
                .width(76)
              TextInput({ text: this.hostIp, placeholder: '192.168.1.168' })
                .fontSize(13)
                .fontColor(Theme.TEXT)
                .placeholderColor(Theme.SUB_TEXT)
                .backgroundColor('#F7F9FD')
                .height(36)
                .borderRadius(8)
                .layoutWeight(1)
                .onChange((value: string) => { this.hostIp = value; })
            }
            .width('100%')

            Row() {
              Text('端口')
                .fontSize(13)
                .fontColor(Theme.TEXT)
                .width(76)
              TextInput({ text: this.port, placeholder: '8765' })
                .fontSize(13)
                .fontColor(Theme.TEXT)
                .placeholderColor(Theme.SUB_TEXT)
                .backgroundColor('#F7F9FD')
                .height(36)
                .borderRadius(8)
                .width(120)
                .onChange((value: string) => { this.port = value; })
            }
            .width('100%')

            Row() {
              Text('电脑MAC')
                .fontSize(13)
                .fontColor(Theme.TEXT)
                .width(76)
              TextInput({ text: this.pcMac, placeholder: 'A0-AD-9F-18-C2-42' })
                .fontSize(13)
                .fontColor(Theme.TEXT)
                .placeholderColor(Theme.SUB_TEXT)
                .backgroundColor('#F7F9FD')
                .height(36)
                .borderRadius(8)
                .layoutWeight(1)
                .onChange((value: string) => { this.pcMac = value; })
            }
            .width('100%')

            Text('电脑睡眠/关机后说"唤醒电脑"，手机自动发魔术包唤醒（默认已填本机有线网卡MAC）')
              .fontSize(10)
              .fontColor(Theme.SUB_TEXT)
              .width('100%')

            Row({ space: 8 }) {
              Text(this.testText)
                .fontSize(11)
                .fontColor(Theme.SUB_TEXT)
                .layoutWeight(1)
                .maxLines(2)
              Button(this.testing ? '测试中' : '测试连接')
                .fontSize(12)
                .height(32)
                .enabled(!this.testing)
                .onClick(() => { this.testConnection(); })
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
          }
          .cardStyle()

          // 电脑管理（多台记忆 + 扫码配对）
          Column({ space: 10 }) {
            this.sectionTitle('电脑管理（多台记忆）')

            if (this.pcEntries.length === 0) {
              Text('还没有保存的电脑。可扫码配对，或填好上方连接信息后点"保存当前配置"。')
                .fontSize(11)
                .fontColor(Theme.SUB_TEXT)
                .width('100%')
            } else {
              ForEach(this.pcEntries, (p: PcEntry, index: number) => {
                Row({ space: 8 }) {
                  AppIcon({
                    name: this.currentPcName() === p.name ? IconName.CHECK : IconName.REMOTE,
                    iconSize: 18,
                    color: this.currentPcName() === p.name ? Theme.ACCENT : Theme.SUB_TEXT,
                    lineWidth: 2
                  })
                  Column({ space: 2 }) {
                    Text(p.name)
                      .fontSize(13)
                      .fontColor(Theme.TEXT)
                      .fontWeight(FontWeight.Medium)
                    Text(p.host + ':' + p.port)
                      .fontSize(10)
                      .fontColor(Theme.SUB_TEXT)
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                  .onClick(() => {
                    this.selectPc(p);
                  })

                  Text('删除')
                    .fontSize(11)
                    .fontColor(Theme.DANGER)
                    .padding(6)
                    .onClick(() => {
                      this.deletePc(index);
                    })
                }
                .width('100%')
                .padding({ top: 6, bottom: 6 })
                .onClick(() => {
                  this.selectPc(p);
                })
              }, (p: PcEntry) => p.host + ':' + p.port + ':' + p.name)
            }

            Row({ space: 8 }) {
              TextInput({ text: this.newPcName, placeholder: '电脑名字（如：书房台式机）' })
                .fontSize(12)
                .fontColor(Theme.TEXT)
                .placeholderColor(Theme.SUB_TEXT)
                .backgroundColor('#F7F9FD')
                .height(36)
                .borderRadius(8)
                .layoutWeight(1)
                .onChange((value: string) => { this.newPcName = value; })
              Button('保存当前配置')
                .fontSize(12)
                .height(36)
                .backgroundColor(Theme.ACCENT)
                .borderRadius(8)
                .onClick(() => { this.saveCurrentPc(); })
            }
            .width('100%')

            Button(this.scanning ? '扫码中…' : '扫码配对电脑')
              .fontSize(13)
              .width('100%')
              .height(40)
              .backgroundColor(Theme.ACCENT_SOFT)
              .fontColor(Theme.ACCENT)
              .borderRadius(10)
              .enabled(!this.scanning)
              .onClick(() => { this.startPairScan(); })

            if (this.scanStatus.length > 0) {
              Text(this.scanStatus)
                .fontSize(11)
                .fontColor(Theme.ACCENT)
                .width('100%')
            }

            Text('扫码前先在电脑浏览器打开 http://电脑IP:8765/pair 显示二维码；选中的电脑立即生效（顶部也会显示当前电脑名）。')
              .fontSize(10)
              .fontColor(Theme.SUB_TEXT)
              .width('100%')
          }
          .cardStyle()

          // 操控设置
          Column({ space: 10 }) {
            this.sectionTitle('鼠标操控')
            Row() {
              Text('灵敏度')
                .fontSize(13)
                .fontColor(Theme.TEXT)
                .width(76)
              Slider({
                value: this.sensitivity,
                min: 0.4,
                max: 3.0,
                step: 0.1,
                style: SliderStyle.OutSet
              })
                .width('100%')
                .layoutWeight(1)
                .onChange((value: number, mode: SliderChangeMode) => {
                  this.sensitivity = Math.round(value * 10) / 10;
                })
              Text(this.sensitivity.toFixed(1) + '×')
                .fontSize(13)
                .fontColor(Theme.ACCENT)
                .width(38)
                .textAlign(TextAlign.End)
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)

            Text('数值越大，滑动同样距离电脑光标移动越远。')
              .fontSize(10)
              .fontColor(Theme.SUB_TEXT)
              .width('100%')
          }
          .cardStyle()

          // 说明
          Column({ space: 8 }) {
            this.sectionTitle('使用说明')
            Text('· 电脑需先运行桥接服务（TCP 8765）')
              .fontSize(11).fontColor(Theme.TEXT).width('100%')
            Text('· 滑动操控盘移动鼠标，轻点左键、双击双击、长按右键')
              .fontSize(11).fontColor(Theme.TEXT).width('100%')
            Text('· 修改设置后返回主页面立即生效')
              .fontSize(11).fontColor(Theme.TEXT).width('100%')
          }
          .cardStyle()

          Button('恢复默认设置')
            .fontSize(13)
            .fontColor(Theme.SUB_TEXT)
            .backgroundColor(Theme.CARD)
            .border({ width: 1, color: Theme.CARD_BORDER })
            .width('100%')
            .height(40)
            .onClick(() => { this.resetDefaults(); })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 4, bottom: 20 })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG_BOTTOM)
  }
}
