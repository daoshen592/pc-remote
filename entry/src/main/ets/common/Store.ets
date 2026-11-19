import { preferences } from '@kit.ArkData';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'RemoteUI';
/** 配置库文件名（应用私有目录，卸载即清） */
const STORE_NAME: string = 'remote_cfg';

/** 配置键（与 AppStorage 完全同名，UI 侧仍用 @StorageLink 即可） */
const KEY_HOST: string = 'remote.hostIp';
const KEY_PORT: string = 'remote.port';
const KEY_SENS: string = 'remote.sensitivity';
const KEY_MAC: string = 'remote.pcMac';
const KEY_LIST: string = 'remote.pcList';
const KEY_TOKEN: string = 'remote.token';
const KEY_PRESENT: string = 'remote.presentMode';

let pref: preferences.Preferences | undefined = undefined;

/**
 * 启动时把落盘配置读进 AppStorage。
 * 不用 PersistentStorage：实测该 API 只写不读（文件有值，重启后 onCreate 拿到的仍是默认值）。
 * 这里用 preferences 同步接口，onCreate 里调完，loadContent 之前的 UI 就能拿到正确值。
 */
export function initStore(context: common.Context): void {
  try {
    const p: preferences.Preferences = preferences.getPreferencesSync(context, { name: STORE_NAME });
    pref = p;
    // 首次升级：把旧 PersistentStorage 文件里的值搬过来（一次性）
    if (!p.hasSync(KEY_LIST) && !p.hasSync(KEY_HOST)) {
      migrateLegacy(context, p);
    }
    AppStorage.setOrCreate(KEY_HOST, p.getSync(KEY_HOST, '') as string);
    AppStorage.setOrCreate(KEY_PORT, p.getSync(KEY_PORT, '8765') as string);
    AppStorage.setOrCreate(KEY_SENS, p.getSync(KEY_SENS, 1.4) as number);
    AppStorage.setOrCreate(KEY_MAC, p.getSync(KEY_MAC, '') as string);
    AppStorage.setOrCreate(KEY_LIST, p.getSync(KEY_LIST, '[]') as string);
    AppStorage.setOrCreate(KEY_TOKEN, p.getSync(KEY_TOKEN, '') as string);
    AppStorage.setOrCreate(KEY_PRESENT, p.getSync(KEY_PRESENT, false) as boolean);
    hilog.info(DOMAIN, TAG, 'store init hostIp=%{public}s pcList=%{public}s',
      String(AppStorage.get<string>(KEY_HOST)), String(AppStorage.get<string>(KEY_LIST)));
  } catch (e) {
    hilog.error(DOMAIN, TAG, 'store init failed %{public}s', JSON.stringify(e));
  }
}

/** 把 AppStorage 当前配置全部写盘（同步写 + 异步 flush） */
export function saveStore(): void {
  const p: preferences.Preferences | undefined = pref;
  if (p === undefined) {
    return;
  }
  try {
    p.putSync(KEY_HOST, AppStorage.get<string>(KEY_HOST) ?? '');
    p.putSync(KEY_PORT, AppStorage.get<string>(KEY_PORT) ?? '8765');
    p.putSync(KEY_SENS, AppStorage.get<number>(KEY_SENS) ?? 1.4);
    p.putSync(KEY_MAC, AppStorage.get<string>(KEY_MAC) ?? '');
    p.putSync(KEY_LIST, AppStorage.get<string>(KEY_LIST) ?? '[]');
    p.putSync(KEY_TOKEN, AppStorage.get<string>(KEY_TOKEN) ?? '');
    p.putSync(KEY_PRESENT, AppStorage.get<boolean>(KEY_PRESENT) ?? false);
    p.flush().catch((e: Error) => {
      hilog.error(DOMAIN, TAG, 'store flush failed %{public}s', e.message ?? '');
    });
  } catch (e) {
    hilog.error(DOMAIN, TAG, 'store save failed %{public}s', JSON.stringify(e));
  }
}

/** 当前配置的快照串，用来判断有没有变化（自动保存用） */
export function storeSnapshot(): string {
  const parts: string[] = [
    AppStorage.get<string>(KEY_HOST) ?? '',
    AppStorage.get<string>(KEY_PORT) ?? '8765',
    String(AppStorage.get<number>(KEY_SENS) ?? 1.4),
    AppStorage.get<string>(KEY_MAC) ?? '',
    AppStorage.get<string>(KEY_LIST) ?? '[]',
    AppStorage.get<string>(KEY_TOKEN) ?? '',
    String(AppStorage.get<boolean>(KEY_PRESENT) ?? false)
  ];
  return JSON.stringify(parts);
}

// ---------- 旧 PersistentStorage 文件迁移 ----------

function decodeXml(s: string): string {
  return s.replace(/&quot;/g, '"')
    .replace(/&apos;/g, '\'')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&amp;/g, '&');
}

/** 旧文件路径：<filesDir>/persistent_storage（ArkUI PersistentStorage 用的就是这个） */
function migrateLegacy(context: common.Context, p: preferences.Preferences): void {
  const path: string = context.filesDir + '/persistent_storage';
  try {
    const text: string = fs.readTextSync(path);
    const re: RegExp = /<(string|boolean|number) key="([^"]+)">([\s\S]*?)<\/\1>/g;
    let moved: number = 0;
    let m: RegExpExecArray | null = re.exec(text);
    while (m !== null) {
      const raw: string = decodeXml(m[3]);
      const key: string = m[2];
      const type: string = m[1];
      try {
        if (type === 'string') {
          const v: string = JSON.parse(raw) as string;
          if (typeof v === 'string' && v.length > 0) {
            p.putSync(key, v);
            moved++;
          }
        } else if (type === 'number') {
          p.putSync(key, Number(raw));
          moved++;
        } else {
          p.putSync(key, raw === 'true');
          moved++;
        }
      } catch (e) {
        // 单个键解析失败不影响其它键
      }
      m = re.exec(text);
    }
    p.flush().catch(() => {
    });
    hilog.info(DOMAIN, TAG, 'store migrated %{public}d keys from legacy file', moved);
  } catch (e) {
    hilog.info(DOMAIN, TAG, 'store no legacy file, start fresh');
  }
}
