import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * 局域网自动发现电脑端桥接服务。
 * 手机往 255.255.255.255:8765 广播暗号，运行中的电脑端桥接服务回一份 JSON
 * （host/port/mac/name/version/need_token），2 秒窗口内收集去重。
 * 替代手动填 IP——用户在设置页点一下扫描，列表里点哪台用哪台。
 */

export interface DiscoveredPc {
  host: string;
  port: string;
  mac: string;
  name: string;
  /** 电脑端开了「只允许已配对设备」：这台必须扫码拿令牌，点选直连会被拒 */
  needToken: boolean;
}

const DISCOVER_MAGIC = 'PCREMOTE_DISCOVER_V1';
const DISCOVER_PORT = 8765;

/** 电脑端 UDP 应答的原始 JSON 结构 */
interface DiscoverReply {
  ok: boolean;
  service?: string;
  host?: string;
  port?: number;
  mac?: string;
  name?: string;
  need_token?: boolean;
}

/** 广播扫描；waitMs 是收应答的窗口时长（毫秒） */
export function discoverPcs(waitMs: number): Promise<DiscoveredPc[]> {
  return new Promise<DiscoveredPc[]>((resolve) => {
    const found: Map<string, DiscoveredPc> = new Map();
    let udp: socket.UDPSocket | null = null;
    let done = false;

    const finish = () => {
      if (done) {
        return;
      }
      done = true;
      try {
        udp?.close();
      } catch (e) {
        // 关闭失败不影响结果
      }
      resolve(Array.from(found.values()));
    };

    try {
      udp = socket.constructUDPSocketInstance();
      udp.bind({ address: '0.0.0.0', port: 0, family: 1 }).then(() => {
        if (done) {
          return;
        }
        try {
          udp!.setExtraOptions({ broadcast: true }).catch(() => {});
        } catch (e) {
          // 个别系统版本不支持广播选项：继续发，可能只有本机收到
        }

        udp!.on('message', (value: socket.SocketMessageInfo) => {
          try {
            const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
            const text: string = decoder.decodeToString(new Uint8Array(value.message));
            const obj: DiscoverReply = JSON.parse(text) as DiscoverReply;
            if (obj && obj.service === 'pc-remote' && obj.host && obj.host.length > 0) {
              const pc: DiscoveredPc = {
                host: obj.host!,
                port: String(obj.port ?? '8765'),
                mac: obj.mac ?? '',
                name: obj.name ?? '',
                needToken: obj.need_token === true
              };
              found.set(pc.host, pc);
            }
          } catch (e) {
            // 非本服务应答，忽略
          }
        });

        // 全网广播 + 192.168.1 网段直连广播双保险
        // （部分路由器会拦 255.255.255.255，但放行网段定向广播）
        const targets: string[] = ['255.255.255.255', '192.168.1.255'];
        for (const t of targets) {
          try {
            udp!.send({
              data: DISCOVER_MAGIC,
              address: { address: t, port: DISCOVER_PORT, family: 1 }
            }, () => {});
          } catch (e) {
            hilog.error(0x0000, 'RemoteUI', 'discover send %{public}s failed', t);
          }
        }

        setTimeout(finish, waitMs);
      }).catch((e: BusinessError) => {
        hilog.error(0x0000, 'RemoteUI', 'discover bind failed %{public}s', e.message ?? '');
        finish();
      });
    } catch (e) {
      finish();
    }
  });
}
