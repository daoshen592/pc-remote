import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Theme } from '../common/UiConfig';
import { AppIcon, IconName } from '../components/AppIcon';

/** 电脑端 /apps 返回的应用项 */
interface AppItem {
  name: string;
  path: string;
}

interface AppsResp {
  ok: boolean;
  count: number;
  apps: AppItem[];
}

/** 头像底色盘（按应用名哈希取色，柔和浅色系） */
const AVATAR_COLORS: string[] = ['#E8F0FF', '#FFF0E4', '#E6F6EC', '#FDECEC', '#F3EDFF', '#E4F5F7'];

/**
 * 应用启动器页面：显示电脑开始菜单里的全部程序（.lnk + UWP），
 * 点宫格 → POST /key {"action":"launch_app","name":"程序名"} 电脑端启动。
 */
@Component
export struct Apps {
  @StorageLink('remote.hostIp') hostIp: string = '192.168.1.168';
  @StorageLink('remote.port') port: string = '8765';
  @StorageLink('remote.token') token: string = '';
  @State private apps: AppItem[] = [];
  @State private keyword: string = '';
  @State private statusText: string = '正在获取电脑应用列表…';
  @State private loading: boolean = false;
  private httpClient: http.HttpRequest = http.createHttp();

  aboutToAppear(): void {
    this.loadApps(false);
  }

  aboutToDisappear(): void {
    this.httpClient.destroy();
  }

  /** 请求头：带设备令牌 */
  private reqHeader(): Record<string, string> {
    const h: Record<string, string> = { 'Content-Type': 'application/json' };
    if (this.token.length > 0) {
      h['X-PC-Token'] = this.token;
    }
    return h;
  }

  /** 拉取应用列表；refresh=true 时让电脑重新扫描开始菜单 */
  private loadApps(refresh: boolean): void {
    const ip = this.hostIp.trim();
    if (ip.length === 0) {
      this.statusText = '请先到设置页填写电脑 IP';
      return;
    }
    const url: string = 'http://' + ip + ':' + this.port.trim() + '/apps' + (refresh ? '?refresh=1' : '');
    this.loading = true;
    hilog.info(0x0000, 'RemoteUI', 'GET %{public}s', url);
    try {
      this.httpClient.request(url, {
        method: http.RequestMethod.GET,
        header: this.reqHeader(),
        connectTimeout: 4000,
        // refresh 时电脑要重扫开始菜单（含 Get-StartApps），放宽到 40 秒
        readTimeout: refresh ? 40000 : 8000
      }, (err: BusinessError, data: http.HttpResponse) => {
        this.loading = false;
        if (err) {
          this.statusText = '获取失败 · 检查电脑 IP / 防火墙';
          hilog.error(0x0000, 'RemoteUI', 'apps GET failed %{public}s', err.message ?? '');
          return;
        }
        if (data.responseCode !== 200) {
          this.statusText = '电脑返回 HTTP ' + data.responseCode;
          return;
        }
        try {
          const body: string = typeof data.result === 'string' ? data.result : JSON.stringify(data.result);
          const obj: AppsResp = JSON.parse(body) as AppsResp;
          this.apps = obj.apps ?? [];
          this.statusText = '电脑共 ' + this.apps.length + ' 个应用，点击即可打开';
          hilog.info(0x0000, 'RemoteUI', 'apps loaded %{public}d', this.apps.length);
        } catch (e) {
          this.statusText = '数据解析失败';
        }
      });
    } catch (error) {
      this.loading = false;
      this.statusText = '请求异常 · 检查网络';
    }
  }

  /** 关键词过滤（忽略大小写） */
  private filtered(): AppItem[] {
    const kw = this.keyword.trim().toLowerCase();
    if (kw.length === 0) {
      return this.apps;
    }
    const out: AppItem[] = [];
    for (const a of this.apps) {
      if (a.name.toLowerCase().includes(kw)) {
        out.push(a);
      }
    }
    return out;
  }

  private avatarColor(name: string): string {
    let hash: number = 0;
    for (let i = 0; i < name.length; i++) {
      hash = (hash * 31 + name.charCodeAt(i)) % 997;
    }
    return AVATAR_COLORS[hash % AVATAR_COLORS.length];
  }

  private avatarChar(name: string): string {
    const first = name.length > 0 ? name.charAt(0) : '?';
    return first.toUpperCase();
  }

  /** 点击宫格 → 电脑启动该程序 */
  private launch(app: AppItem): void {
    const ip = this.hostIp.trim();
    if (ip.length === 0) {
      this.statusText = '请先到设置页填写电脑 IP';
      return;
    }
    const url: string = 'http://' + ip + ':' + this.port.trim() + '/key';
    this.statusText = '正在打开 ' + app.name + ' …';
    try {
      this.httpClient.request(url, {
        method: http.RequestMethod.POST,
        header: this.reqHeader(),
        extraData: JSON.stringify({ action: 'launch_app', name: app.name }),
        connectTimeout: 3000,
        readTimeout: 8000
      }, (err: BusinessError, data: http.HttpResponse) => {
        if (err) {
          this.statusText = '打开失败 · 电脑无响应';
          return;
        }
        try {
          const body: string = typeof data.result === 'string' ? data.result : JSON.stringify(data.result);
          const obj: Record<string, Object> = JSON.parse(body) as Record<string, Object>;
          const ok: boolean = obj['ok'] === true;
          const detail: string = typeof obj['detail'] === 'string' ? obj['detail'] as string : '';
          this.statusText = ok ? '已打开 ' + app.name : '打开失败：' + detail.slice(0, 40);
        } catch (e) {
          this.statusText = data.responseCode === 200 ? '已打开 ' + app.name : '电脑返回 ' + data.responseCode;
        }
        hilog.info(0x0000, 'RemoteUI', 'launch %{public}s resp=%{public}d', app.name, data.responseCode);
      });
    } catch (error) {
      this.statusText = '请求异常 · 检查网络';
    }
  }

  @Builder gridItem(app: AppItem) {
    Column({ space: 6 }) {
      Text(this.avatarChar(app.name))
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.TEXT)
        .width(46)
        .height(46)
        .textAlign(TextAlign.Center)
        .backgroundColor(this.avatarColor(app.name))
        .borderRadius(14)
      Text(app.name)
        .fontSize(11)
        .fontColor(Theme.TEXT)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
        .height(28)
    }
    .width('100%')
    .padding({ top: 8, bottom: 6, left: 2, right: 2 })
    .borderRadius(12)
    .onClick(() => {
      this.launch(app);
    })
  }

  build() {
    Column({ space: 10 }) {
      // 顶部标题 + 刷新
      Row({ space: 8 }) {
        Column({ space: 2 }) {
          Text('应用启动器')
            .fontSize(16)
            .fontColor(Theme.TITLE)
            .fontWeight(FontWeight.Bold)
          Text(this.statusText)
            .fontSize(10)
            .fontColor(Theme.SUB_TEXT)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Button() {
          Text(this.loading ? '扫描中' : '刷新')
            .fontSize(12)
            .fontColor(Theme.ACCENT)
        }
        .backgroundColor(Theme.ACCENT_SOFT)
        .borderRadius(14)
        .height(30)
        .padding({ left: 12, right: 12 })
        .enabled(!this.loading)
        .onClick(() => {
          this.loadApps(true);
        })
      }
      .width('100%')

      // 搜索框
      TextInput({ placeholder: '搜索程序名…', text: this.keyword })
        .width('100%')
        .height(38)
        .fontSize(13)
        .backgroundColor(Theme.CARD)
        .borderRadius(12)
        .onChange((value: string) => {
          this.keyword = value;
        })

      // 应用宫格
      if (this.filtered().length === 0) {
        Column({ space: 8 }) {
          AppIcon({ name: IconName.APPS, iconSize: 40, color: Theme.SUB_TEXT, lineWidth: 1.6 })
          Text(this.loading ? '正在扫描电脑应用…' : this.statusText)
            .fontSize(12)
            .fontColor(Theme.SUB_TEXT)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Grid() {
          ForEach(this.filtered(), (app: AppItem) => {
            GridItem() {
              this.gridItem(app)
            }
          }, (app: AppItem) => app.path)
        }
        .columnsTemplate('1fr 1fr 1fr 1fr')
        .columnsGap(4)
        .rowsGap(6)
        .scrollBar(BarState.Auto)
        .width('100%')
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 12, right: 12, top: 12, bottom: 10 })
    .backgroundColor(Theme.BG_BOTTOM)
  }
}
