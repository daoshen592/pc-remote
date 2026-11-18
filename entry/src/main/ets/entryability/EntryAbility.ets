import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';

const DOMAIN: number = 0x5A01;
const TAG: string = 'RemoteUI';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'onCreate');
    // 设置持久化：必须在 loadContent 之前注册，AppStorage 里这些键的值会落盘，
    // 重启后自动恢复（IP/端口/MAC/灵敏度不再丢失）
    PersistentStorage.persistProp('remote.hostIp', '192.168.1.168');
    PersistentStorage.persistProp('remote.port', '8765');
    PersistentStorage.persistProp('remote.sensitivity', 1.4);
    PersistentStorage.persistProp('remote.pcMac', 'A0-AD-9F-18-C2-42');
    // 多电脑记忆：JSON 数组 [{name,host,port,mac,token}]，扫码配对/手动保存都会写入
    PersistentStorage.persistProp('remote.pcList', '[]');
    // 当前电脑的设备令牌（扫码配对时由电脑端下发，之后每个请求都带上）
    PersistentStorage.persistProp('remote.token', '');
    // 媒体卡片模式：false=播放与音量，true=演示控制（翻页笔）；记住上次选择
    PersistentStorage.persistProp('remote.presentMode', false);
    hilog.info(DOMAIN, TAG, 'onCreate restored');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, 'onWindowStageCreate');
    // 跟随系统旋转，但受系统"旋转锁定"约束：系统锁竖屏时保持竖屏，解锁后才转横屏
    try {
      const win = windowStage.getMainWindowSync();
      win.setPreferredOrientation(window.Orientation.AUTO_ROTATION_RESTRICTED);
      hilog.info(DOMAIN, TAG, 'set AUTO_ROTATION_RESTRICTED ok');
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'set orientation failed %{public}s', JSON.stringify(e));
    }
    windowStage.loadContent('pages/Index', (err: BusinessError) => {
      // 成功时回调也会带 code=0 的对象，必须按 code 判断而非对象存在性
      if (err && err.code !== 0) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'loadContent success');
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onWindowStageDestroy');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onDestroy');
  }
}
