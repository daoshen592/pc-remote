# 电脑遥控器（PC-Remote）

用手机遥控 Windows 电脑：**触控鼠标 / 键盘 / 媒体与系统控制 / 语音指令**。
鸿蒙（HarmonyOS）原生 App + PC 桥接服务，**局域网直连，无需公网、无需注册账号**。

## 功能

- **触控鼠标**：手机屏幕当触摸板，滑动即移动光标，支持左右键、双击、滚轮
- **键盘输入**：方向/回车/快捷键面板 + 文字直输
- **媒体/系统控制**：音量、播放、锁屏、关显示器、任务管理器等 30+ 动作
- **语音指令**（按住说话，系统语音识别）：
  - 内置 90+ 条：「打开微信」「音量加大」「锁屏」「不要关机」（否定句拦截）…
  - **自定义指令**：一句话触发一串动作，如「上课」= 打开课件 + F5 放映；支持等待延时、别名、回话
  - **LLM 兜底**（可选开关，默认关）：本地没听懂时交给大模型拆成动作，如「把记事本内容全选复制」→ Ctrl+A → Ctrl+C
- **局域网自动发现**（v1.1.1）：手机打开设置页自动扫描，点一下即连，无需手填 IP / 端口 / MAC
- **多台电脑**：保存多台并起名，列表一点即切换（v1.1.1）
- **多设备**：扫码配对，支持多台手机；可开启「仅已配对设备可控制」
- **网络唤醒（WOL）**：电脑睡眠/关机后可远程开机（需 BIOS 开启网卡唤醒）
- **自适应布局**：手机竖/横屏、折叠屏、平板、2in1 全形态适配（实测 5 种分辨率）

## 下载

| 端 | 获取方式 |
|---|---|
| PC 端（Windows） | [Releases](../../releases) 下载 `PCRemote-PC-1.1.2.exe`，双击即用（单文件，免安装） |
| 手机端（HarmonyOS） | Releases 下载 `PCRemotePhone-1.1.2-com.pc.remotecontrol.hap`，或用 DevEco Studio 从源码构建 |

首次运行 exe 时 Windows 可能弹 SmartScreen 提示（未做代码签名），点「更多信息 → 仍要运行」即可。

## 快速开始

1. PC 端双击 exe，托盘出现图标
2. 托盘右键 →「显示配对二维码」（或 Ctrl+Alt+Q）
3. 手机 App 扫码配对 → 连接成功即可遥控
4. 连不上时点托盘「放行防火墙」

默认端口：遥控服务 `8765`，管理控制台 `http://127.0.0.1:8766`（仅本机）。

## 安全说明

- 所有通信限于局域网，不出公网
- 支持配对令牌（pair token）校验，控制台可一键开启「只允许已配对设备」
- 语音的关机/重启/睡眠可单独关闭（防误触）
- 所有按键/指令留有本地记录，管理页可查

## 源码结构

```
entry/          鸿蒙 App（ArkTS / ArkUI）
tools/          PC 端桥接服务（Python）
  bridge_server.py   主服务：HTTP + WebSocket、语音理解、指令执行、托盘
  assets/admin.html  管理控制台（单文件 HTML）
```

### 构建手机端

1. 复制 `build-profile.json5.example` 为 `build-profile.json5`
2. DevEco Studio 打开项目，File → Project Structure → Signing Configs 自动生成调试签名
3. `File → Sync` 后正常 Build / 运行

### 构建 PC 端 exe

```bash
cd tools
pyinstaller --onefile --noconsole --name 电脑遥控器 \
  --icon assets/app_icon.ico --add-data "assets;assets" \
  bridge_server.py
```

PC 端运行依赖：`pystray`、`Pillow`、`qrcode`、`pypinyin`、`pywin32`。

## 更新检查

PC 端启动 8 秒后会后台检查 GitHub Releases 是否有新版本（仅提示，不自动安装）。
仓库地址在管理控制台 → 设置 → 版本与更新 里配置。

## License

MIT
