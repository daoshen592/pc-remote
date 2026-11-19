/**
 * 遥控器界面统一设计令牌（HarmonyOS 设计语言）。
 * 配色参考华为蓝 #0A59F7、白卡片、16vp 圆角、8vp 间距栅格。
 * 图标用通用 Unicode 字符（配合中文标签），避免依赖系统 symbol 资源名，跨设备稳定。
 */

export class Theme {
  // 页面背景：浅色冷灰渐变
  static readonly BG_TOP: string = '#F2F5FA';
  static readonly BG_BOTTOM: string = '#E8EDF5';
  // 卡片
  static readonly CARD: string = '#FFFFFF';
  static readonly CARD_BORDER: string = '#E6EBF2';
  static readonly CARD_SHADOW: string = '#140A1B2A';
  // 文字层级
  static readonly TEXT: string = '#182230';
  static readonly SUB_TEXT: string = '#8A97A8';
  static readonly TITLE: string = '#0F1B2A';
  // 华为蓝强调色
  static readonly ACCENT: string = '#0A59F7';
  static readonly ACCENT_PRESSED: string = '#0848C4';
  static readonly ACCENT_SOFT: string = '#E8F0FF';
  // 通用按键（浅灰白）
  static readonly KEY: string = '#F5F7FB';
  static readonly KEY_PRESSED: string = '#E3ECFF';
  static readonly KEY_SECONDARY: string = '#EEF2F8';
  // 统一键材质：与触控盘盘面同一色同一描边，左右两区视觉一致
  static readonly KEY_UNIFIED: string = '#F7F9FD';
  static readonly KEY_UNIFIED_BORDER: string = '#E6EBF2';
  static readonly BODY_EDGE: string = '#E6EBF2';
  static readonly KEY_BORDER: string = '#E2E8F0';
  // OK 键（实心华为蓝）
  static readonly OK_BLUE: string = '#0A59F7';
  static readonly OK_BLUE_PRESSED: string = '#0848C4';
  // 语音键（暖橙）
  static readonly VOICE: string = '#FF7A29';
  static readonly VOICE_PRESSED: string = '#E5651A';
  static readonly VOICE_SOFT: string = '#FFF0E4';
  // 危险操作
  static readonly DANGER: string = '#E34A4A';
  static readonly DANGER_PRESSED: string = '#C93A3A';
  static readonly DANGER_SOFT: string = '#FDECEC';
  static readonly DANGER_SOFT_PRESSED: string = '#F8D7D7';
  // 兼容别名
  static readonly BODY: string = '#FFFFFF';
  static readonly BODY_BG: string = '#F2F5FA';
}

/** 精致图标字符：细箭头 + 标准符号，避免粗糙实心三角 */
export class Glyph {
  static readonly POWER: string = '⏻';
  static readonly VOICE: string = '✦';
  static readonly UP: string = '⌃';
  static readonly DOWN: string = '⌄';
  static readonly LEFT: string = '‹';
  static readonly RIGHT: string = '›';
  static readonly OK: string = 'OK';
  static readonly BACK: string = '↩';
  static readonly HOME: string = '⌂';
  static readonly MENU: string = '☰';
  static readonly VOL_UP: string = '+';
  static readonly VOL_DOWN: string = '−';
  static readonly TV: string = 'TV';
  static readonly PLAY_PAUSE: string = '▶';
  static readonly REWIND: string = '≪';
  static readonly FORWARD: string = '≫';
  static readonly MUTE: string = '⊘';
}

/** 按键动作 ID，通信层直接透传这些字符串（不可改动） */
export class Action {
  static readonly POWER: string = 'power';
  static readonly POWER_LONG: string = 'power_long';
  static readonly VOICE: string = 'voice';
  static readonly UP: string = 'dpad_up';
  static readonly DOWN: string = 'dpad_down';
  static readonly LEFT: string = 'dpad_left';
  static readonly RIGHT: string = 'dpad_right';
  static readonly OK: string = 'ok';
  static readonly BACK: string = 'back';
  static readonly HOME: string = 'home';
  static readonly MENU: string = 'menu';
  static readonly VOL_UP: string = 'vol_up';
  static readonly VOL_DOWN: string = 'vol_down';
  static readonly TV: string = 'tv';
  static readonly PLAY_PAUSE: string = 'play_pause';
  static readonly REWIND: string = 'rewind';
  static readonly FORWARD: string = 'forward';
  static readonly MUTE: string = 'mute';
  static readonly MOUSE_LEFT: string = 'mouse_left';
  static readonly MOUSE_RIGHT: string = 'mouse_right';
  static readonly MOUSE_DOUBLE: string = 'mouse_double';
  static readonly PREV_TRACK: string = 'prev_track';
  static readonly NEXT_TRACK: string = 'next_track';
  static readonly ALT_TAB: string = 'alt_tab';
  static readonly ALT_F4: string = 'alt_f4';
  static readonly CTRL_V: string = 'ctrl_v';
}

export enum Breakpoint {
  XS = 'xs',
  SM = 'sm',
  MD = 'md',
  LG = 'lg',
  XL = 'xl'
}

/** 一台已保存的电脑（多电脑记忆/扫码配对共用） */
export interface PcEntry {
  name: string;
  host: string;
  port: string;
  mac: string;
  /** 设备令牌：扫码配对时由电脑端下发，之后请求带 X-PC-Token（旧记录可能没有，读时用 ?? ''） */
  token: string;
}
