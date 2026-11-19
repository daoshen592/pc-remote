import { webSocket } from '@kit.NetworkKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { display } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * 单条 WebSocket 长连接。
 *
 * 以前每条指令都是一次独立的 HTTP 请求，触控盘 30Hz 就等于每秒 30 次
 * 拨号（TCP 三次握手）+ 关闭；现在拨一次，之后所有指令都在同一条
 * TCP 上收发，每帧只有十几个字节。
 *
 * 特性：
 *  - 断线自动重连（0.8s 起，指数退避，最长 8 秒一次）
 *  - 地址/令牌变化时自动重新拨号
 *  - 未连上时 send() 返回 false，调用方决定是丢弃还是走 HTTP 兜底
 */

export type NetState = 'idle' | 'connecting' | 'open' | 'closed';

export class NetClient {
  private sock: webSocket.WebSocket | null = null;
  private host: string = '';
  private port: string = '';
  private token: string = '';
  private state: NetState = 'idle';
  private retry: number = 0;
  private retryTimer: number = 0;
  private manualClose: boolean = false;

  /** 连接状态变化回调 */
  onState: (state: NetState) => void = () => {
  };
  /** 收到服务端回包（JSON 文本） */
  onText: (text: string) => void = () => {
  };

  isOpen(): boolean {
    return this.state === 'open';
  }

  getState(): NetState {
    return this.state;
  }

  /** 连接（地址与令牌都没变且链路活着时不会重复拨号） */
  connect(host: string, port: string, token: string): void {
    const h: string = (host ?? '').trim();
    const p: string = (port ?? '').trim();
    if (h.length === 0 || p.length === 0) {
      return;
    }
    const tk: string = token ?? '';
    // 地址或令牌任一变化都要重新拨号：重连循环里存的是拨号那一刻的令牌，
    // 电脑端踢掉设备后重新扫码，若不重拨就会一直拿被吊销的旧令牌撞 401
    const same: boolean = h === this.host && p === this.port && tk === this.token;
    if (same && (this.state === 'open' || this.state === 'connecting')) {
      return;
    }
    this.host = h;
    this.port = p;
    this.token = tk;
    this.manualClose = false;
    this.retry = 0;
    this.clearRetry();          // 撤掉挂着的重拨定时器，避免旧参数再拨一次
    this.closeSocket();
    this.open();
  }

  /** 主动断开（退出页面/换电脑时用） */
  close(): void {
    this.manualClose = true;
    this.clearRetry();
    this.closeSocket();
    this.setState('idle');
  }

  /** 发送一条指令；未连接返回 false */
  send(obj: Object): boolean {
    const s: webSocket.WebSocket | null = this.sock;
    if (s === null || this.state !== 'open') {
      return false;
    }
    try {
      s.send(JSON.stringify(obj), (err: BusinessError) => {
        if (err) {
          hilog.error(0x0000, 'RemoteUI', 'ws send failed %{public}s', err.message ?? '');
        }
      });
      return true;
    } catch (error) {
      hilog.error(0x0000, 'RemoteUI', 'ws send exception');
      return false;
    }
  }

  private open(): void {
    this.setState('connecting');
    // 令牌放 URL 查询串里：WS 握手就是一次 HTTP GET，服务端从 query 取即可，
    // 比塞自定义请求头省事（ArkTS 对带连字符的头部键名限制较多）
    let url: string = 'ws://' + this.host + ':' + this.port + '/ws';
    if (this.token.length > 0) {
      url = url + '?token=' + encodeURIComponent(this.token);
    }
    let sock: webSocket.WebSocket | null = null;
    try {
      sock = webSocket.createWebSocket();
    } catch (error) {
      this.scheduleRetry();
      return;
    }
    const self: NetClient = this;
    this.sock = sock;
    sock.on('open', (err: BusinessError) => {
      if (err) {
        self.onSockError(sock, 'open ' + (err.message ?? ''));
        return;
      }
      self.retry = 0;
      self.setState('open');
      hilog.info(0x0000, 'RemoteUI', 'ws open %{public}s', url);
      // 连上就报一次本机信息：电脑控制台「手机」卡显示（未配对也能显示状态）
      let resStr = '';
      try {
        const dsp = display.getDefaultDisplaySync();
        resStr = `${dsp.width}x${dsp.height}`;
      } catch (e) {
        // 个别设备取不到屏幕参数，留空即可
      }
      const ann: Record<string, Object> = {
        'path': '/announce',
        'model': (deviceInfo.marketName ?? '') as Object,
        'os': (deviceInfo.osFullName ?? '') as Object,
        'res': resStr as Object,
      };
      self.send(ann);
    });
    sock.on('message', (err: BusinessError, data: string | ArrayBuffer) => {
      if (err || typeof data !== 'string') {
        return;
      }
      self.onText(data as string);
    });
    sock.on('close', () => {
      if (self.sock !== sock) {
        return;                       // 旧连接的回调，忽略，避免误触发重连
      }
      self.sock = null;
      self.setState('closed');
      self.scheduleRetry();
    });
    sock.on('error', (err: BusinessError) => {
      self.onSockError(sock, err?.message ?? 'ws error');
    });
    try {
      sock.connect(url, (err: BusinessError) => {
        if (err) {
          self.onSockError(sock, 'connect ' + (err.message ?? ''));
        }
      });
    } catch (error) {
      self.onSockError(sock, 'connect exception');
    }
  }

  private onSockError(sock: webSocket.WebSocket | null, detail: string): void {
    if (this.sock !== sock) {
      return;
    }
    hilog.error(0x0000, 'RemoteUI', 'ws error %{public}s', detail);
    this.sock = null;
    this.setState('closed');
    this.scheduleRetry();
  }

  private scheduleRetry(): void {
    if (this.manualClose || this.host.length === 0) {
      return;
    }
    this.clearRetry();
    const base: number = this.retry === 0 ? 800 : 800 * Math.pow(2, Math.min(this.retry, 4));
    const delay: number = Math.min(8000, base);
    this.retry++;
    const self: NetClient = this;
    this.retryTimer = setTimeout(() => {
      self.retryTimer = 0;
      if (!self.manualClose && self.host.length > 0) {
        self.open();
      }
    }, delay);
  }

  private clearRetry(): void {
    if (this.retryTimer !== 0) {
      clearTimeout(this.retryTimer);
      this.retryTimer = 0;
    }
  }

  private closeSocket(): void {
    const s: webSocket.WebSocket | null = this.sock;
    this.sock = null;
    if (s !== null) {
      try {
        s.close((err: BusinessError) => {
        });
      } catch (error) {
        // 已经断了就忽略
      }
    }
  }

  private setState(next: NetState): void {
    if (this.state !== next) {
      this.state = next;
      this.onState(next);
    }
  }
}

export const net: NetClient = new NetClient();
