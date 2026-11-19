import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { initStore, saveStore, storeSnapshot } from '../common/Store';

const DOMAIN: number = 0x5A01;
const TAG: string = 'RemoteUI';

export default class EntryAbility extends UIAbility {
  private lastSaved: string = '';
  private timerId: number = -1;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'onCreate');
    // 配置落盘：preferences 同步读取，必须在 loadContent 之前，UI 首帧就能拿到上次的电脑列表
    initStore(this.context);
    this.lastSaved = storeSnapshot();
    // 自动保存：每秒对比一次快照，有变化就写盘（任何页面改了配置都不会丢）
    this.timerId = setInterval(() => {
      const cur: string = storeSnapshot();
      if (cur !== this.lastSaved) {
        this.lastSaved = cur;
        saveStore();
      }
    }, 1000);
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

  onBackground(): void {
    // 切后台立刻落盘，防止被系统回收丢掉最后几秒的改动
    saveStore();
    this.lastSaved = storeSnapshot();
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onWindowStageDestroy');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onDestroy');
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
    saveStore();
  }
}
