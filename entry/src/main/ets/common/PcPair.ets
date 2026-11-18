import { common, abilityAccessCtrl } from '@kit.AbilityKit';
import { scanBarcode, scanCore } from '@kit.ScanKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { deviceInfo } from '@kit.BasicServicesKit';

/**
 * 扫码配对公共逻辑（设置页与主页菜单共用）。
 * 配对码格式：pc-remote://pair?host=&port=&mac=&name=&pt=
 * 由电脑端 GET /pair 页二维码提供；pt 是配对票据，用来向电脑端换一枚设备令牌。
 */

export interface PairInfo {
  host: string;
  port: string;
  mac: string;
  name: string;
  ticket: string;
}

/** 解析配对码；非法或缺少 host 返回 null */
export function parsePairCode(raw: string): PairInfo | null {
  const code: string = (raw ?? '').trim();
  if (!code.startsWith('pc-remote://pair')) {
    return null;
  }
  const query: string = code.indexOf('?') >= 0 ? code.substring(code.indexOf('?') + 1) : '';
  const info: PairInfo = { host: '', port: '', mac: '', name: '', ticket: '' };
  const parts: string[] = query.split('&');
  for (const part of parts) {
    const i: number = part.indexOf('=');
    if (i <= 0) {
      continue;
    }
    const key: string = part.substring(0, i);
    const val: string = decodeURIComponent(part.substring(i + 1));
    if (key === 'host') {
      info.host = val;
    } else if (key === 'port') {
      info.port = val;
    } else if (key === 'mac') {
      info.mac = val;
    } else if (key === 'name') {
      info.name = val;
    } else if (key === 'pt') {
      info.ticket = val;
    }
  }
  if (info.host.length === 0) {
    return null;
  }
  return info;
}

export interface RegisterResp {
  ok: boolean;
  token?: string;
  msg?: string;
}

/**
 * 用配对票据换设备令牌：POST /pair/register。
 * 电脑端若开了「只允许已配对设备」，没这枚令牌的请求会一律 401。
 * 拿不到令牌（旧版电脑端没有这个接口）时返回空串，保持老行为也能用。
 */
export function registerDevice(host: string, port: string, ticket: string,
  deviceName: string): Promise<string> {
  return new Promise<string>((resolve) => {
    const client = http.createHttp();
    const url: string = 'http://' + host + ':' + port + '/pair/register';
    const body: string = JSON.stringify({
      ticket: ticket,
      name: deviceName,
      model: deviceInfo.marketName ?? 'HarmonyOS'
    });
    try {
      client.request(url, {
        method: http.RequestMethod.POST,
        header: { 'Content-Type': 'application/json' },
        extraData: body,
        connectTimeout: 4000,
        readTimeout: 6000
      }, (err: BusinessError, data: http.HttpResponse) => {
        client.destroy();
        if (err) {
          hilog.error(0x0000, 'RemoteUI', 'register failed %{public}s', err.message ?? '');
          resolve('');
          return;
        }
        if (data.responseCode !== 200) {
          resolve('');
          return;
        }
        try {
          const text: string = typeof data.result === 'string' ? data.result : JSON.stringify(data.result);
          const obj: RegisterResp = JSON.parse(text) as RegisterResp;
          hilog.info(0x0000, 'RemoteUI', 'register ok tokenLen=%{public}d', (obj.token ?? '').length);
          resolve(obj.token ?? '');
        } catch (e) {
          resolve('');
        }
      });
    } catch (error) {
      client.destroy();
      resolve('');
    }
  });
}

/**
 * 申请相机权限并拉起系统扫码（ScanKit），成功 resolve PairInfo。
 * 摄像头属敏感权限，调用时才申请。
 */
export function scanPairCode(ctx: common.Context): Promise<PairInfo> {
  return new Promise<PairInfo>((resolve, reject) => {
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      atManager.requestPermissionsFromUser(ctx, ['ohos.permission.CAMERA'])
        .then((result) => {
          const granted: boolean = result.authResults.length > 0 && result.authResults[0] === 0;
          if (!granted) {
            reject(new Error('需允许相机权限才能扫码'));
            return;
          }
          const options: scanBarcode.ScanOptions = {
            scanTypes: [scanCore.ScanType.QR_CODE]
          };
          scanBarcode.startScan(options).then((res: scanBarcode.ScanResult) => {
            const info: PairInfo | null = parsePairCode(res.originalValue);
            if (info === null) {
              reject(new Error('不是本应用的配对码'));
              return;
            }
            resolve(info);
          }).catch((e: BusinessError) => {
            hilog.error(0x0000, 'RemoteUI', 'scan failed %{public}s', e.message ?? '');
            reject(new Error('扫码未完成：' + (e.message ?? '').slice(0, 30)));
          });
        })
        .catch((e: BusinessError) => {
          hilog.error(0x0000, 'RemoteUI', 'camera perm failed %{public}s', e.message ?? '');
          reject(new Error('相机权限申请失败'));
        });
    } catch (error) {
      reject(new Error('扫码异常'));
    }
  });
}
