import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { Theme, PcEntry } from '../common/UiConfig';
import { AppIcon, IconName } from '../components/AppIcon';
import { scanPairCode, registerDevice, PairInfo } from '../common/PcPair';
import { discoverPcs, DiscoveredPc } from '../common/Discovery';
import { saveStore } from '../common/Store';

/** 电脑端程序下载页（GitHub Releases 最新版） */
const DOWNLOAD_URL: string = 'https://github.com/daoshen592/pc-remote/releases/latest';
/** 展示用的短链接（不带协议，省宽度） */
const DOWNLOAD_URL_SHORT: string = 'github.com/daoshen592/pc-remote';

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
  @StorageLink('remote.hostIp') hostIp: string = '';
  @StorageLink('remote.port') port: string = '8765';
  @StorageLink('remote.sensitivity') sensitivity: number = 1.4;
  @StorageLink('remote.pcMac') pcMac: string = '';
  @StorageLink('remote.pcList') pcListStr: string = '[]';
  @StorageLink('remote.token') token: string = '';
  @State private testText: string = '';  // 空=不显示测试结果行
  @State private testing: boolean = false;
  // 保存 / 已保存电脑（集成在电脑连接卡片里）
  @State private pcEntries: PcEntry[] = [];
  @State private newPcName: string = '';
  @State private scanStatus: string = '';
  @State private scanning: boolean = false;
  // 局域网自动发现
  @State private foundPcs: DiscoveredPc[] = [];
  @State private discovering: boolean = false;
  @State private discoverText: string = '';
  // 使用说明弹窗（与主页面共享：系统返回键要先关弹窗）
  @StorageLink('ui.showHelp') showHelp: boolean = false;
  @State private downloadTip: string = '';
  private httpClient: http.HttpRequest = http.createHttp();

  aboutToAppear(): void {
    this.reloadPcList();
    // 当前连接若已是保存过的电脑，把名字带回输入框，便于改名后直接「更新保存」
    if (this.newPcName.trim().length === 0 && this.currentPcName().length > 0) {
      this.newPcName = this.currentPcName();
    }
    // 还没连过电脑时自动扫一次：新用户打开设置页就能直接看到可用的电脑
    if (this.hostIp.trim().length === 0) {
      this.startDiscover();
    }
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
    // 立即落盘，不等自动保存的 1 秒节拍
    saveStore();
  }

  /** 当前控制的是列表里的哪台（按 host+port 匹配），没有则显示 IP */
  private currentPcName(): string {
    for (const p of this.pcEntries) {
      if (this.isCurrent(p)) {
        return p.name;
      }
    }
    return '';
  }

  /** 这条记录是不是当前连接的那台（按 host+port，不能用名字：两台可能同名） */
  private isCurrent(p: PcEntry): boolean {
    return p.host === this.hostIp.trim() && p.port === this.port.trim();
  }

  private selectPc(entry: PcEntry): void {
    this.hostIp = entry.host;
    this.port = entry.port;
    if (entry.mac.length > 0) {
      this.pcMac = entry.mac;
    }
    this.token = entry.token ?? '';
    this.newPcName = entry.name;
    this.scanStatus = '已切换到「' + entry.name + '」';
    hilog.info(0x0000, 'RemoteUI', 'switch pc -> %{public}s (%{public}s)', entry.name, entry.host);
  }

  /** 把当前连接配置保存为列表里的一台电脑（同名覆盖） */
  private saveCurrentPc(): void {
    if (this.hostIp.trim().length === 0) {
      this.scanStatus = '还没有选择电脑，先扫描或扫码配对';
      return;
    }
    const name = this.newPcName.trim();
    if (name.length === 0) {
      this.scanStatus = '请先给电脑起个名字（如：书房台式机）';
      return;
    }
    // 当前已有令牌（比如刚重新扫码）就以新的为准；没有才回退用列表里的旧令牌
    let keepToken: string = this.token;
    if (keepToken.length === 0) {
      for (const p of this.pcEntries) {
        if (p.host === this.hostIp.trim() && p.port === this.port.trim() && (p.token ?? '').length > 0) {
          keepToken = p.token;
          break;
        }
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
    const p: PcEntry = this.pcEntries[index];
    const others: PcEntry[] = this.pcEntries.filter((_: PcEntry, i: number) => i !== index);
    this.savePcList(others);
    // 删的是当前正在用的这台：连当前连接一起清空，重启后不再显示
    if (p.host === this.hostIp.trim() && p.port === this.port.trim()) {
      this.hostIp = '';
      this.pcMac = '';
      this.token = '';
      this.newPcName = '';
      this.testText = '';
      this.scanStatus = '已删除「' + p.name + '」，当前连接已清空';
    } else {
      this.scanStatus = '已删除「' + p.name + '」';
    }
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
      if (this.newPcName.trim().length === 0 && info.name.length > 0) {
        this.newPcName = info.name;
      }
      this.scanStatus = '已扫码：' + shown + '，正在登记本机…';
      hilog.info(0x0000, 'RemoteUI', 'pair scanned %{public}s %{public}s', info.name, info.host);
      // 用配对票据换设备令牌（电脑端开启「只允许已配对设备」时必需）
      const portStr: string = info.port.length > 0 ? info.port : '8765';
      registerDevice(info.host, portStr, info.ticket, deviceInfo.marketName ?? '鸿蒙手机')
        .then((tk: string) => {
          this.token = tk;
          if (tk.length > 0) {
            this.scanStatus = '已配对：' + shown + '，点下方「保存」记住这台电脑';
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

  /**
   * 局域网自动发现：UDP 广播，运行中的电脑端桥接服务应答。
   * 不再手动填 IP/端口/MAC——扫出来点哪台用哪台。
   */
  private startDiscover(): void {
    if (this.discovering) {
      return;
    }
    this.discovering = true;
    this.discoverText = '正在扫描局域网…';
    this.foundPcs = [];
    discoverPcs(2200).then((list: DiscoveredPc[]) => {
      this.discovering = false;
      this.foundPcs = list;
      if (list.length === 0) {
        this.discoverText = '没找到电脑：确认电脑端程序在运行、手机和电脑连同一个 Wi-Fi，或改用扫码配对';
      } else {
        this.discoverText = '找到 ' + list.length + ' 台，点击即可使用';
      }
    });
  }

  /** 点选一台发现的电脑：写入连接信息并立即测试连通 */
  private useDiscoveredPc(pc: DiscoveredPc): void {
    const pcPort: string = pc.port.length > 0 ? pc.port : '8765';
    if (pc.needToken) {
      // 电脑端开了「只允许已配对设备」：之前配对过（列表里有这台的令牌）可直接用
      let saved: PcEntry | null = null;
      for (const p of this.pcEntries) {
        if (p.host === pc.host && p.port === pcPort && (p.token ?? '').length > 0) {
          saved = p;
          break;
        }
      }
      if (saved === null) {
        this.discoverText = '「' + (pc.name || pc.host) + '」开启了设备校验，请点「扫码配对电脑」完成配对';
        return;
      }
      this.hostIp = saved.host;
      this.port = saved.port;
      if (saved.mac.length > 0) {
        this.pcMac = saved.mac;
      }
      this.token = saved.token ?? '';
      this.newPcName = saved.name;
      this.discoverText = '已选择：' + saved.name + '（使用之前保存的配对）';
      this.testConnection();
      return;
    }
    this.hostIp = pc.host;
    this.port = pcPort;
    // MAC 只在拿到时才覆盖，避免空应答把已有的 WOL 地址清掉
    if (pc.mac.length > 0) {
      this.pcMac = pc.mac;
    }
    if (this.newPcName.trim().length === 0 && pc.name.length > 0) {
      this.newPcName = pc.name;
    }
    this.discoverText = '已选择：' + (pc.name || pc.host) + '，可起名保存，下次直接切换';
    this.testConnection();
  }

  /** GET 桥接服务首页，200 即视为连通（只读、无副作用） */
  private testConnection(): void {
    const ip = this.hostIp.trim();
    const port = this.port.trim();
    if (ip.length === 0) {
      this.testText = '请先选择电脑';
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

  /** 清空连接信息（令牌/命名残留一并清；已保存的电脑列表保留，端口固定 8765） */
  private resetDefaults(): void {
    this.hostIp = '';
    this.pcMac = '';
    this.token = '';
    this.newPcName = '';
    this.sensitivity = 1.4;
    this.foundPcs = [];
    this.discoverText = '';
    this.testText = '';
    this.scanStatus = '已清空连接信息（已保存的电脑列表保留）';
  }

  /** 跳系统浏览器打开电脑端下载页 */
  private openDownloadPage(): void {
    const ctx: common.Context | undefined = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      this.downloadTip = '无法打开浏览器，请手动复制链接到电脑下载';
      return;
    }
    (ctx as common.UIAbilityContext).openLink(DOWNLOAD_URL)
      .then(() => {
        this.downloadTip = '';
        hilog.info(0x0000, 'RemoteUI', 'open download page ok');
      })
      .catch((e: BusinessError) => {
        this.downloadTip = '打开浏览器失败，请复制链接后在电脑上打开下载';
        hilog.error(0x0000, 'RemoteUI', 'openLink failed %{public}s', e.message ?? '');
      });
  }

  /** 复制下载链接到剪贴板（发给微信/QQ 都方便） */
  private copyDownloadLink(): void {
    const data: pasteboard.PasteData =
      pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, DOWNLOAD_URL);
    pasteboard.getSystemPasteboard().setData(data).then(() => {
      this.downloadTip = '链接已复制，可粘贴发给电脑';
    }).catch((e: BusinessError) => {
      this.downloadTip = '复制失败：' + DOWNLOAD_URL;
      hilog.error(0x0000, 'RemoteUI', 'copy link failed %{public}s', e.message ?? '');
    });
  }

  @Builder sectionTitle(text: string) {
    Row({ space: 6 }) {
      Column()
        .width(3)
        .height(12)
        .borderRadius(2)
        .backgroundColor(Theme.ACCENT)
      Text(text)
        .fontSize(13)
        .fontColor(Theme.SUB_TEXT)
        .fontWeight(FontWeight.Medium)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .margin({ top: 4, bottom: 2 })
  }

  build() {
    Stack() {
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
          // 连接设置：自动发现 + 扫码配对（不再手动填 IP/端口/MAC）
          Column({ space: 10 }) {
            this.sectionTitle('电脑连接')

            if (this.hostIp.trim().length > 0) {
              Text('当前电脑：' + (this.currentPcName().length > 0
                ? this.currentPcName() + '（' + this.hostIp + ':' + this.port + '）'
                : this.hostIp + ':' + this.port)
                + (this.token.length > 0 ? ' · 已配对' : ''))
                .fontSize(12)
                .fontColor(Theme.SUB_TEXT)
                .width('100%')
            }

            Button(this.discovering ? '扫描中…' : '自动扫描局域网')
              .fontSize(14)
              .width('100%')
              .height(42)
              .backgroundColor(Theme.ACCENT)
              .borderRadius(10)
              .enabled(!this.discovering)
              .onClick(() => { this.startDiscover(); })

            if (this.foundPcs.length > 0) {
              ForEach(this.foundPcs, (pc: DiscoveredPc) => {
                Row({ space: 8 }) {
                  Column({ space: 2 }) {
                    Text(pc.name.length > 0 ? pc.name : pc.host)
                      .fontSize(14)
                      .fontColor(Theme.TEXT)
                      .maxLines(1)
                    Text(pc.host + (pc.needToken ? ' · 需扫码配对' : ''))
                      .fontSize(11)
                      .fontColor(Theme.SUB_TEXT)
                      .maxLines(1)
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)

                  AppIcon({ name: IconName.RIGHT, iconSize: 13, color: Theme.ACCENT, lineWidth: 2 })
                }
                .width('100%')
                .padding({ top: 9, bottom: 9, left: 10, right: 10 })
                .backgroundColor('#F7F9FD')
                .borderRadius(9)
                .onClick(() => { this.useDiscoveredPc(pc); })
              }, (pc: DiscoveredPc) => pc.host + ':' + pc.port)
            }

            if (this.discoverText.length > 0) {
              Text(this.discoverText)
                .fontSize(12)
                .fontColor(Theme.SUB_TEXT)
                .width('100%')
            }

            Row() {
              Text('扫码配对')
                .fontSize(13)
                .fontColor(Theme.SUB_TEXT)
                .layoutWeight(1)
              Button('扫码配对电脑')
                .fontSize(13)
                .height(34)
                .backgroundColor(Theme.ACCENT_SOFT)
                .fontColor(Theme.ACCENT)
                .borderRadius(8)
                .enabled(!this.scanning)
                .onClick(() => { this.startPairScan(); })
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)

            if (this.scanStatus.length > 0) {
              Text(this.scanStatus)
                .fontSize(12)
                .fontColor(Theme.ACCENT)
                .width('100%')
            }

            if (this.testText.length > 0) {
              Text(this.testText)
                .fontSize(12)
                .fontColor(Theme.SUB_TEXT)
                .width('100%')
                .maxLines(2)
            }

            // 保存当前连接（扫描 / 扫码出结果后直接起名保存）
            if (this.hostIp.trim().length > 0) {
              Row({ space: 8 }) {
                TextInput({ text: this.newPcName, placeholder: '给这台电脑起名（如：书房台式机）' })
                  .maxLength(20)
                  .fontSize(13)
                  .fontColor(Theme.TEXT)
                  .placeholderColor(Theme.SUB_TEXT)
                  .backgroundColor('#F7F9FD')
                  .height(40)
                  .borderRadius(8)
                  .layoutWeight(1)
                  .onChange((value: string) => { this.newPcName = value; })
                Button(this.currentPcName().length > 0 ? '更新保存' : '保存')
                  .fontSize(13)
                  .height(40)
                  .backgroundColor(Theme.ACCENT)
                  .borderRadius(8)
                  .onClick(() => { this.saveCurrentPc(); })
              }
              .width('100%')
            }

            // 已保存的电脑：点选切换，右滑删除文字直接删
            if (this.pcEntries.length > 0) {
              Text('已保存 ' + this.pcEntries.length + ' 台 · 点击切换')
                .fontSize(11)
                .fontColor(Theme.SUB_TEXT)
                .width('100%')
                .margin({ top: 2 })
              ForEach(this.pcEntries, (p: PcEntry, index: number) => {
                Row({ space: 8 }) {
                  AppIcon({
                    name: this.isCurrent(p) ? IconName.CHECK : IconName.REMOTE,
                    iconSize: 16,
                    color: this.isCurrent(p) ? Theme.ACCENT : Theme.SUB_TEXT,
                    lineWidth: 2
                  })
                  Column({ space: 2 }) {
                    Text(p.name)
                      .fontSize(14)
                      .fontColor(Theme.TEXT)
                      .fontWeight(FontWeight.Medium)
                      .maxLines(1)
                    Text(p.host + ':' + p.port + ((p.token ?? '').length > 0 ? ' · 已配对' : ''))
                      .fontSize(11)
                      .fontColor(Theme.SUB_TEXT)
                      .maxLines(1)
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)

                  Text('删除')
                    .fontSize(12)
                    .fontColor(Theme.DANGER)
                    .padding({ left: 6, right: 6, top: 6, bottom: 6 })
                    .onClick(() => {
                      this.deletePc(index);
                    })
                }
                .width('100%')
                .padding({ top: 6, bottom: 6, left: 10, right: 10 })
                .backgroundColor(this.isCurrent(p) ? '#F0F6FF' : '#F7F9FD')
                .borderRadius(9)
                .onClick(() => {
                  this.selectPc(p);
                })
              }, (p: PcEntry) => p.host + ':' + p.port + ':' + p.name)
            }
          }
          .cardStyle()

          // 下载电脑端程序
          Column({ space: 8 }) {
            this.sectionTitle('下载电脑端程序')
            Text('电脑还没装遥控器服务？到 GitHub 下载最新版电脑端（单个 exe，免安装，双击即用）：')
              .fontSize(12)
              .fontColor(Theme.SUB_TEXT)
              .width('100%')
            Text(DOWNLOAD_URL_SHORT)
              .fontSize(14)
              .fontColor(Theme.ACCENT)
              .fontWeight(FontWeight.Medium)
              .width('100%')
              .copyOption(CopyOptions.LocalDevice)
            Row({ space: 8 }) {
              Button('打开下载页')
                .fontSize(13)
                .height(36)
                .layoutWeight(1)
                .backgroundColor(Theme.ACCENT)
                .borderRadius(8)
                .onClick(() => { this.openDownloadPage(); })
              Button('复制链接')
                .fontSize(13)
                .height(36)
                .layoutWeight(1)
                .backgroundColor(Theme.ACCENT_SOFT)
                .fontColor(Theme.ACCENT)
                .borderRadius(8)
                .onClick(() => { this.copyDownloadLink(); })
            }
            .width('100%')

            if (this.downloadTip.length > 0) {
              Text(this.downloadTip)
                .fontSize(12)
                .fontColor(Theme.ACCENT)
                .width('100%')
            }
          }
          .cardStyle()

          // 操控设置
          Column({ space: 10 }) {
            this.sectionTitle('鼠标操控')
            Row() {
              Text('灵敏度')
                .fontSize(14)
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
                .fontSize(14)
                .fontColor(Theme.ACCENT)
                .width(38)
                .textAlign(TextAlign.End)
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)

            Text('数值越大，滑动同样距离电脑光标移动越远。')
              .fontSize(11)
              .fontColor(Theme.SUB_TEXT)
              .width('100%')
          }
          .cardStyle()

          // 使用说明：入口行，点击弹窗看完整说明（含语音指令大全）
          Column({ space: 8 }) {
            this.sectionTitle('使用说明')
            Row({ space: 8 }) {
              Column({ space: 3 }) {
                Text('查看完整使用说明')
                  .fontSize(14)
                  .fontColor(Theme.TEXT)
                  .fontWeight(FontWeight.Medium)
                Text('连接配对 · 手势操作 · 语音指令大全')
                  .fontSize(11)
                  .fontColor(Theme.SUB_TEXT)
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              AppIcon({ name: IconName.RIGHT, iconSize: 14, color: Theme.ACCENT, lineWidth: 2 })
            }
            .width('100%')
            .padding({ top: 10, bottom: 10, left: 4, right: 4 })
            .onClick(() => { this.showHelp = true; })
          }
          .cardStyle()

          Button('清空连接信息')
            .fontSize(14)
            .fontColor(Theme.SUB_TEXT)
            .backgroundColor(Theme.CARD)
            .border({ width: 1, color: Theme.CARD_BORDER })
            .width('100%')
            .height(42)
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

      // 使用说明弹窗（浮在整页之上）
      if (this.showHelp) {
        this.buildHelpDialog()
      }
    }
  }

  // ---------- 使用说明弹窗 ----------
  @Builder helpSection(title: string) {
    Text(title)
      .fontSize(14)
      .fontColor(Theme.ACCENT)
      .fontWeight(FontWeight.Bold)
      .width('100%')
      .margin({ top: 10 })
  }

  @Builder helpItem(text: string) {
    Text(text)
      .fontSize(12)
      .fontColor(Theme.TEXT)
      .lineHeight(18)
      .width('100%')
  }

  @Builder helpItemSub(text: string) {
    Text(text)
      .fontSize(11)
      .fontColor(Theme.SUB_TEXT)
      .lineHeight(16)
      .width('100%')
      .padding({ left: 10 })
  }

  @Builder buildHelpDialog() {
    Stack({ alignContent: Alignment.Center }) {
      // 遮罩：点击空白关闭
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#990F1B2A')
        .onClick(() => { this.showHelp = false; })

      Column() {
        // 标题栏
        Row() {
          Text('使用说明')
            .fontSize(18)
            .fontColor(Theme.TITLE)
            .fontWeight(FontWeight.Bold)
            .layoutWeight(1)
          Text('关闭')
            .fontSize(14)
            .fontColor(Theme.ACCENT)
            .padding({ left: 10, right: 2, top: 4, bottom: 4 })
            .onClick(() => { this.showHelp = false; })
        }
        .width('100%')

        Scroll() {
          Column() {
            this.helpSection('一、准备工作')
            this.helpItem('1. 电脑上双击运行「电脑遥控器.exe」（免安装，监听 TCP 8765），任务栏出现橙色图标即就绪。')
            this.helpItem('2. 手机和电脑连同一个 Wi-Fi。')
            this.helpItem('3. 配对方式：本页点「自动扫描局域网」，发现电脑后点击即可使用；或点「扫码配对电脑」扫电脑上的二维码。电脑开启设备校验时必须扫码配对。MAC 地址会自动获取，无需手填。连上后在下方给电脑起个名字点「保存」，多台电脑可保存并随时点击切换；不需要的电脑点「删除」即可。')
            this.helpItem('4. 电脑睡眠后说「唤醒电脑」可发魔术包远程开机（MAC 自动获取；需主板 BIOS 开启网络唤醒，见常见问题）。')

            this.helpSection('二、操控盘手势')
            this.helpItem('· 滑动：移动鼠标光标（灵敏度在本页调整）')
            this.helpItem('· 轻点一下 = 鼠标左键')
            this.helpItem('· 连续快点两下 = 双击')
            this.helpItem('· 长按不动 = 鼠标右键')
            this.helpItem('· 双指同时滑动 = 滚轮滚动')

            this.helpSection('三、实体按键')
            this.helpItem('· 返回：短按智能返回（网页后退 / 关弹窗 / 退全屏自动判断），长按强制后退')
            this.helpItem('· 电源：短按关闭显示器；长按弹出菜单（锁屏 / 睡眠 / 关机 / 重启 / 唤醒电脑）')
            this.helpItem('· 语音：按住说话，松手识别执行')

            this.helpSection('四、语音指令大全（按住语音键直接说）')
            this.helpItem('【媒体播放】')
            this.helpItemSub('播放 / 暂停 / 继续播放 / 上一首 / 下一首 / 快进 / 快退')
            this.helpItem('【音量】')
            this.helpItemSub('音量加大 / 音量减小 / 静音')
            this.helpItem('【屏幕与系统】')
            this.helpItemSub('关闭显示器 / 黑屏 / 锁屏 / 睡眠 / 关机 / 重启电脑 / 主页 / 显示桌面')
            this.helpItem('【打开应用】')
            this.helpItemSub('打开微信 / 启动QQ音乐 / 开一下记事本 / 用网易云放歌 / 任务管理器')
            this.helpItem('【网页与搜索】')
            this.helpItemSub('搜索一下天气 / 百度一下炖排骨 / 打开 baidu.com / 打开B站')
            this.helpItem('【文件操作】')
            this.helpItemSub('在D盘建个文件夹叫资料 / 上课（打开电脑上指定的文件）')
            this.helpItem('【文字输入】')
            this.helpItemSub('打字：你好，今天下午三点开会')
            this.helpItem('【开关机】')
            this.helpItemSub('打开电脑 / 唤醒电脑（电脑关机或睡眠时发魔术包远程唤醒）')

            this.helpSection('五、语音进阶')
            this.helpItem('· 一句话可以带多个步骤，如「打开B站搜一下周深」')
            this.helpItem('· 没听懂的会原样当成打字内容上屏，不会误操作')
            this.helpItem('· 自定义指令：在电脑端管理页（http://电脑IP:8765）配置，如「上课」= 打开课件并全屏')
            this.helpItem('· 智能兜底（可选）：电脑端管理页开启后，听不懂的话交给大模型理解（需电脑能上网）')
            this.helpItem('· 安全限制：自定义指令和大模型兜底都不能执行关机 / 重启 / 睡眠，只能做白名单动作；内置语音的关机/重启/睡眠受电脑端「允许电源操作」开关控制')

            this.helpSection('六、常见问题')
            this.helpItem('· 连不上：检查电脑 exe 是否在运行、手机电脑是否同一 Wi-Fi；重新点「自动扫描」即可发现新地址（路由器重新分配 IP 也不怕）')
            this.helpItem('· 唤醒不了：MAC 必须填电脑有线网卡地址；主板 BIOS 里要开启「网络唤醒 / Wake On LAN」（通常在电源管理或网卡设置里，部分主板还要在系统网卡属性勾选“允许此设备唤醒计算机”）')
            this.helpItem('· 语音无反应：首次使用需允许麦克风权限；说话时按住不放，说完再松手')
          }
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 16 })
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.On)
        .edgeEffect(EdgeEffect.Spring)
      }
      .width('92%')
      .height('86%')
      .backgroundColor(Theme.CARD)
      .borderRadius(16)
      .padding({ left: 16, right: 16, top: 14, bottom: 6 })
      .justifyContent(FlexAlign.Start)
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
  }
}
