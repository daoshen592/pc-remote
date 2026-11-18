import socket from '@ohos.net.socket';

/**
 * Wake-on-LAN：手机向睡眠/关机的电脑发魔术包，唤醒开机。
 * 用法：sendMagicPacket('A0-AD-9F-18-C2-42', '192.168.1.168')
 */

/** 构造魔术包：6 字节 0xFF + 目标 MAC 重复 16 次，共 102 字节 */
function buildMagicPacket(macHex: string): ArrayBuffer {
  const bytes = new Uint8Array(102);
  for (let i = 0; i < 6; i++) {
    bytes[i] = 0xFF;
  }
  for (let i = 0; i < 16; i++) {
    for (let j = 0; j < 6; j++) {
      bytes[6 + i * 6 + j] = parseInt(macHex.substr(j * 2, 2), 16);
    }
  }
  return bytes.buffer;
}

/** 由电脑 IP 推导子网广播地址（192.168.1.168 -> 192.168.1.255），推导不出用全网广播 */
function broadcastAddr(ip: string): string {
  const parts: string[] = ip.split('.');
  if (parts.length === 4) {
    let valid = true;
    for (let i = 0; i < 4; i++) {
      const v: number = parseInt(parts[i], 10);
      if (parts[i].length === 0 || isNaN(v) || v < 0 || v > 255) {
        valid = false;
        break;
      }
    }
    if (valid) {
      return parts[0] + '.' + parts[1] + '.' + parts[2] + '.255';
    }
  }
  return '255.255.255.255';
}

/**
 * 发送 WOL 魔术包（UDP 广播，子网广播 + 全网广播各连发 2 次）。
 * mac 支持冒号/横线/空格分隔，也支持裸 12 位十六进制。
 * 返回 true 表示广播已发出；电脑是否真醒由调用方重试连接判断。
 */
export function sendMagicPacket(mac: string, hostIp: string): Promise<boolean> {
  const macHex: string = mac.replace(/[:\-\s]/g, '').toLowerCase();
  if (macHex.length !== 12 || !/^[0-9a-f]+$/.test(macHex)) {
    return Promise.resolve(false);
  }
  const packet: ArrayBuffer = buildMagicPacket(macHex);
  const udp: socket.UDPSocket = socket.constructUDPSocketInstance();
  const primary: string = broadcastAddr(hostIp.trim());
  const sendOnce = (addr: string): Promise<void> => {
    const target: socket.NetAddress = { address: addr, port: 9, family: 1 };
    return udp.send({ data: packet, address: target }).then(() => undefined);
  };
  const sendBoth = (): Promise<void> => {
    return sendOnce(primary)
      .catch(() => sendOnce('255.255.255.255').catch(() => undefined));
  };
  return new Promise<boolean>((resolve: (v: boolean) => void) => {
    udp.bind({ address: '0.0.0.0', port: 0, family: 1 }).then(() => {
      return udp.setExtraOptions({ broadcast: true });
    }).then(() => {
      return sendBoth();
    }).then(() => {
      // 隔 500ms 再发一遍，防单包丢包
      return new Promise<void>((r: () => void) => setTimeout(r, 500));
    }).then(() => {
      return sendBoth();
    }).then(() => {
      return udp.close().catch(() => undefined);
    }).then(() => {
      resolve(true);
    }).catch(() => {
      udp.close().catch(() => undefined);
      resolve(false);
    });
  });
}
