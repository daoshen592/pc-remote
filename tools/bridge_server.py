# -*- coding: utf-8 -*-
"""
遥控器桥接服务（电脑端，Windows）。

作用：接收鸿蒙 App 发来的 Action，翻译成 Windows 本机动作。
  - 检测到同目录有 NeoShell 的 .neoshell/config.json 时，
    电源/媒体/音量/启动应用走 NeoShell 的系统级 API（更稳）；
  - 没有 NeoShell 时自动降级：电源走系统命令，其余走 SendInput，
    因此不装 NeoShell 也能独立测试。

用法：
  python bridge_server.py            正常执行
  python bridge_server.py --dry      只打印映射结果，不真的执行（安全自测）

网络：
  监听 TCP 8765：
    POST /key   {"action":"ok"}            按键/电源/媒体指令
    POST /move  {"dx":10,"dy":-5}          触控盘相对位移（鼠标指针移动）
  响应 {"ok":true,"action":"...","detail":"..."}
  GET  /apps  应用启动器：返回开始菜单应用列表（?refresh=1 强制重扫）
  手机浏览器开 http://<电脑IP>:8765 看按键记录页。

防火墙：放行 TCP 8765（仅专用网络）。
安全：本服务无鉴权，只应在局域网用；如需外网务必套 VPN（Tailscale），
      不要裸映射到公网。
"""

import base64
import hashlib
import io
import json
import os
import re
import socket
import struct
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
import uuid
from datetime import datetime
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 8765
DISCOVER_MAGIC = 'PCREMOTE_DISCOVER_V1'   # 手机端局域网发现广播的暗号
DRY = '--dry' in sys.argv
# PyInstaller 单文件 exe 运行时 __file__ 在临时解压目录，配置文件应放在 exe 旁边
if getattr(sys, 'frozen', False):
    BASE_DIR = Path(sys.executable).resolve().parent
else:
    BASE_DIR = Path(__file__).resolve().parent
RECORDS = []            # 兼容老记录页：纯文本行
KEY_LOG = []            # 结构化按键/动作记录（管理界面用）
VOICE_LOG = []          # 语音记录：原话 -> 解析 -> 回话
LOG_LOCK = threading.Lock()

# ---------- 按键/语音记录落盘（exe 同目录 records.json，各留最近 100 条） ----------
RECORDS_FILE = BASE_DIR / 'records.json'
RECORD_CAP = 100


def load_records():
    """启动时把上次的按键/语音记录读回来（各最多 100 条）。"""
    try:
        if RECORDS_FILE.exists():
            data = json.loads(RECORDS_FILE.read_text(encoding='utf-8'))
            with LOG_LOCK:
                KEY_LOG.extend([r for r in (data.get('key') or [])
                                if isinstance(r, dict)][-RECORD_CAP:])
                VOICE_LOG.extend([r for r in (data.get('voice') or [])
                                  if isinstance(r, dict)][-RECORD_CAP:])
    except Exception:
        pass


def save_records():
    """把当前记录写回 records.json（触发频繁时也只是几 KB 的小写入）。"""
    try:
        with LOG_LOCK:
            data = {'key': list(KEY_LOG)[-RECORD_CAP:],
                    'voice': list(VOICE_LOG)[-RECORD_CAP:]}
        RECORDS_FILE.write_text(json.dumps(data, ensure_ascii=False), encoding='utf-8')
    except Exception:
        pass
STATS = {'key': 0, 'key_fail': 0, 'voice': 0, 'voice_miss': 0, 'move': 0,
         'start_ts': datetime.now(), 'last_seen': ''}
LOCK = threading.Lock()
_LAST_SEEN_TS = [0.0]        # STATS['last_seen'] 上次格式化的时间（高频事件节流）

# ---------- 设置项（存在 exe 同目录 settings.json） ----------
SETTINGS_FILE = BASE_DIR / 'settings.json'
UPDATE_REPO_DEFAULT = 'daoshen592/pc-remote'   # 更新检查仓库（界面不暴露，写死）
DEFAULT_SETTINGS = {
    'port': 8765,             # 遥控服务端口（手机连这个）
    'admin_port': 8766,       # 管理界面端口（只绑本机 127.0.0.1）
    'autostart': False,       # 开机自动启动（写 HKCU Run）
    'start_hidden': False,    # 启动时不显示黑色控制台窗口
    'allow_power': True,      # 允许手机执行关机/重启/睡眠（防误触可关）
    'voice_reply': True,      # 手机是否显示/播报回话
    'require_token': False,   # 只允许已配对设备控制（默认关，配好手机后到控制台一键开启）
    'hotkeys': True,          # 全局热键：Ctrl+Alt+Q 二维码 / Ctrl+Alt+S 启停服务
    'fw_asked': False,        # 是否已经提示过防火墙放行（避免每次启动都弹）
    'update_check': True,     # 启动后检查 GitHub 是否有新版本（不下载，只提示）
    'update_repo': UPDATE_REPO_DEFAULT,   # 更新检查用的 GitHub 仓库（界面已去掉，写死）
    'win_x': 140,             # 控制台窗口位置/大小（关闭时自动记住，下次原位打开）
    'win_y': 60,
    'win_w': 1120,
    'win_h': 780,
}
SETTINGS = dict(DEFAULT_SETTINGS)

# ---------- 版本与更新检查 ----------
APP_VERSION = '1.1.2'
UPDATE = {'checked': False, 'latest': '', 'url': '', 'notes': '',
          'newer': False, 'ts': 0, 'error': ''}
UPDATE_LOCK = threading.Lock()


def _ver_tuple(s):
    """'v1.2.3' -> (1, 2, 3)，无法解析返回 (0,)。"""
    nums = re.findall(r'\d+', str(s))
    return tuple(int(x) for x in nums[:4]) if nums else (0,)


def check_update(timeout=8):
    """查 GitHub 最新版本：先 Releases API，失败退 raw version.json。结果写 UPDATE。"""
    repo = str(SETTINGS.get('update_repo') or '').strip().strip('/') or UPDATE_REPO_DEFAULT
    if not repo or '/' not in repo:
        return {'ok': False, 'msg': '未配置 update_repo（settings.json 里填 yourname/仓库名）'}
    tag = url = notes = ''
    err = ''
    try:
        req = urllib.request.Request(
            'https://api.github.com/repos/%s/releases/latest' % repo,
            headers={'User-Agent': 'pc-remote', 'Accept': 'application/vnd.github+json'})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            d = json.loads(resp.read().decode('utf-8', 'replace'))
        tag = str(d.get('tag_name') or '')
        url = str(d.get('html_url') or ('https://github.com/%s/releases' % repo))
        notes = str(d.get('body') or '')[:300]
    except Exception as exc:
        err = str(exc)[:80]
        try:   # 兜底：仓库根目录放 version.json {"version":"1.1.0","url":"..."}
            req = urllib.request.Request(
                'https://raw.githubusercontent.com/%s/main/version.json' % repo,
                headers={'User-Agent': 'pc-remote'})
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                d = json.loads(resp.read().decode('utf-8', 'replace'))
            tag = str(d.get('version') or '')
            url = str(d.get('url') or ('https://github.com/%s/releases' % repo))
            notes = str(d.get('notes') or '')[:300]
        except Exception as exc2:
            err = str(exc2)[:80]
    newer = bool(tag) and _ver_tuple(tag) > _ver_tuple(APP_VERSION)
    with UPDATE_LOCK:
        UPDATE.update({'checked': bool(tag or err), 'latest': tag, 'url': url,
                       'notes': notes, 'newer': newer,
                       'ts': time.time(), 'error': '' if tag else err})
    if newer:
        print('[update] 发现新版本 %s（当前 %s）: %s' % (tag, APP_VERSION, url or repo))
        if _TRAY_ICON[0] is not None:
            try:
                _TRAY_ICON[0].notify('发现新版本 %s（当前 %s），请到 GitHub 下载'
                                     % (tag, APP_VERSION), '电脑遥控器')
            except Exception:
                pass
    return {'ok': bool(tag), 'newer': newer, 'latest': tag, 'url': url, 'error': err}


def _update_worker():
    """启动 8 秒后后台检查更新，绝不让网络拖慢启动。"""
    time.sleep(8)
    if SETTINGS.get('update_check'):
        check_update()


def load_settings():
    global SETTINGS, PORT, DRY
    try:
        if SETTINGS_FILE.exists():
            data = json.loads(SETTINGS_FILE.read_text(encoding='utf-8'))
            if isinstance(data, dict):
                for k in DEFAULT_SETTINGS:
                    if k in data:
                        SETTINGS[k] = data[k]
    except Exception as exc:
        print('[cfg] 读取设置失败（用默认值）:', exc)
    PORT = int(SETTINGS.get('port') or 8765)
    return SETTINGS


def save_settings(patch):
    global SETTINGS, PORT, DRY
    for k, v in (patch or {}).items():
        if k in DEFAULT_SETTINGS:
            if isinstance(DEFAULT_SETTINGS[k], bool):
                SETTINGS[k] = bool(v)
            elif isinstance(DEFAULT_SETTINGS[k], int):
                try:
                    SETTINGS[k] = max(1, int(v))
                except Exception:
                    pass
            else:
                SETTINGS[k] = v
    try:
        SETTINGS_FILE.write_text(json.dumps(SETTINGS, ensure_ascii=False, indent=2),
                                 encoding='utf-8')
    except Exception as exc:
        print('[cfg] 保存设置失败:', exc)
    PORT = int(SETTINGS.get('port') or 8765)
    DRY = '--dry' in sys.argv
    return SETTINGS


def _push_log(bucket, row):
    limit = RECORD_CAP                   # 记录固定留最近 100 条（落盘 records.json）
    with LOG_LOCK:
        bucket.append(row)
        if len(bucket) > limit:
            del bucket[0:len(bucket) - limit]
    save_records()                        # 记录落盘（各留最近 100 条，重启不丢）


def _autostart_cmd():
    """开机自启命令：exe 直接跑；脚本模式用 pythonw 跑本文件。"""
    if getattr(sys, 'frozen', False):
        return '"%s" --min' % sys.executable
    pyw = sys.executable.replace('python.exe', 'pythonw.exe')
    return '"%s" "%s" --min' % (pyw, os.path.abspath(__file__))


def set_autostart(enable):
    """写/删 HKCU\\...\\Run（不用 COM，标准库 winreg 足够）。"""
    try:
        import winreg
        key = winreg.OpenKey(winreg.HKEY_CURRENT_USER,
                             r'Software\Microsoft\Windows\CurrentVersion\Run',
                             0, winreg.KEY_SET_VALUE)
        try:
            if enable:
                winreg.SetValueEx(key, 'PCRemoteServer', 0, winreg.REG_SZ, _autostart_cmd())
            else:
                try:
                    winreg.DeleteValue(key, 'PCRemoteServer')
                except FileNotFoundError:
                    pass
        finally:
            winreg.CloseKey(key)
        return True, ('已设置开机自动启动' if enable else '已取消开机自动启动')
    except Exception as exc:
        return False, '设置开机启动失败：%s' % exc


# ---------- 配对令牌 / 已配对设备（2026-11-18 安全加固） ----------
# 模型：电脑端持有「配对票据」ticket（写在 devices.json，跟着二维码走）。
# 手机扫码后拿 ticket 换一枚自己的 device token，之后每个请求带 X-PC-Token。
# 撤销某台设备的 token 即可把它踢下线；重置 ticket 则所有设备都要重新扫码。
DEVICES_FILE = BASE_DIR / 'devices.json'
DEVICES = {'ticket': '', 'devices': []}
TOKENS = {}                       # token -> device dict（鉴权走内存，避免高频读盘）
_DEV_LOCK = threading.Lock()
_DEV_SAVE_TS = [0.0]
_DEV_STR_TS = {}                  # dev_id -> 上次格式化 last 的时间（节流用，不落盘）
MAX_DEVICES = 12


def _rand_hex(n=16):
    import secrets
    return secrets.token_hex(n)


def load_devices():
    global DEVICES, TOKENS
    data = None
    try:
        if DEVICES_FILE.exists():
            data = json.loads(DEVICES_FILE.read_text(encoding='utf-8'))
    except Exception as exc:
        print('[dev] 读取设备表失败（重建）:', exc)
    if isinstance(data, dict):
        DEVICES = {'ticket': str(data.get('ticket') or ''),
                   'devices': list(data.get('devices') or [])}
    if not DEVICES['ticket']:
        DEVICES['ticket'] = _rand_hex(8)
        save_devices()
    TOKENS.clear()
    for dev in DEVICES['devices']:
        tk = dev.get('token')
        if tk:
            TOKENS[tk] = dev
    print('[dev] 已配对设备 %d 台' % len(DEVICES['devices']))
    return DEVICES


def save_devices():
    try:
        DEVICES_FILE.write_text(json.dumps(DEVICES, ensure_ascii=False, indent=2),
                                encoding='utf-8')
    except Exception as exc:
        print('[dev] 保存设备表失败:', exc)


def pair_ticket():
    return DEVICES.get('ticket') or ''


def register_device(ticket, name, model, ip):
    """手机扫码后换 token。返回 (token, err)。票据必须匹配，空票据一律拒绝，
    否则局域网内任何设备不发 ticket 就能领到控制令牌。"""
    ticket = str(ticket or '').strip()
    if not ticket:
        return '', '缺少配对票据，请扫描电脑端二维码完成配对'
    if ticket != pair_ticket():
        return '', '配对票据不匹配（电脑端可能重置过配对，请重新扫码）'
    nm = (str(name or '').strip() or '未命名设备')[:24]
    token = _rand_hex()
    dev = {
        'id': _rand_hex(3),
        'name': nm,
        'model': str(model or '')[:40],
        'token': token,
        'ip': ip or '',
        'created': datetime.now().strftime('%Y-%m-%d %H:%M'),
        'last': datetime.now().strftime('%H:%M:%S'),
        'last_ts': time.time(),
        'count': 0,
    }
    with _DEV_LOCK:
        # 同机同名重配：顶掉旧记录，避免列表里堆一堆重复项
        kept = [d for d in DEVICES['devices']
                if not (d.get('name') == nm and d.get('ip') == dev['ip'])]
        if len(kept) >= MAX_DEVICES:
            return '', '已配对设备太多（上限 %d 台），请先到控制台踢掉不用的' % MAX_DEVICES
        kept.append(dev)
        DEVICES['devices'] = kept
        TOKENS[token] = dev
    save_devices()
    print('[dev] 新设备登记: %s (%s)' % (nm, dev['ip']))
    return token, ''


def revoke_device(dev_id):
    with _DEV_LOCK:
        hit = [d for d in DEVICES['devices'] if d.get('id') == dev_id]
        if not hit:
            return False, '没找到这台设备'
        DEVICES['devices'] = [d for d in DEVICES['devices'] if d.get('id') != dev_id]
        for d in hit:
            TOKENS.pop(d.get('token'), None)
    save_devices()
    for d in hit:
        kick_token(d.get('token'))      # 马上断开这条连接，手机端立刻感知被移除
    return True, '已踢下线：%s（该手机需要重新扫码）' % hit[0].get('name', '')


def rename_device(dev_id, new_name):
    with _DEV_LOCK:
        for d in DEVICES['devices']:
            if d.get('id') == dev_id:
                d['name'] = (str(new_name or '').strip() or d.get('name'))[:24]
                break
        else:
            return False, '没找到这台设备'
    save_devices()
    return True, '已重命名'


def reset_ticket():
    """换新配对票据：所有手机都得重新扫码（设备列表一并清空）。"""
    global DEVICES
    with _DEV_LOCK:
        dead = list(TOKENS.keys())
        DEVICES['ticket'] = _rand_hex(8)
        DEVICES['devices'] = []
        TOKENS.clear()
    save_devices()
    for t in dead:
        kick_token(t)
    return True, '配对票据已重置，所有手机需要重新扫码'


def auth_request(handler, payload=None):
    """返回 (ok, dev_id)。本机回环地址免鉴权（控制台/调试用）。"""
    ip = ''
    try:
        ip = handler.client_address[0]
    except Exception:
        pass
    if ip in ('127.0.0.1', '::1'):
        return True, 'local'
    if not SETTINGS.get('require_token', False):
        if ip and ip not in ('127.0.0.1', '::1'):
            with _OPEN_SEEN_LOCK:
                seen = OPEN_SEEN.get(ip)
                if seen:
                    seen['last_ts'] = time.time()   # 有动作就续上「在线」状态
        return True, 'open'
    token = ''
    try:
        token = handler.headers.get('X-PC-Token') or ''
    except Exception:
        pass
    if not token and isinstance(payload, dict):
        token = str(payload.get('token') or '')
    dev = TOKENS.get(token)
    if dev is None:
        return False, ''
    now = time.time()
    dev['last_ts'] = now
    dev['count'] = int(dev.get('count') or 0) + 1
    # 触控盘每秒几十帧，每帧都 strftime 只是为了托盘上那个"最后活动时间"。
    # 每秒最多格式化一次，显示精度不变，省掉热路径上的字符串分配。
    did = dev.get('id') or ''
    if now - _DEV_STR_TS.get(did, 0.0) >= 1.0:
        _DEV_STR_TS[did] = now
        dev['last'] = datetime.now().strftime('%H:%M:%S')
    if ip:
        dev['ip'] = ip
    if now - _DEV_SAVE_TS[0] > 5:
        _DEV_SAVE_TS[0] = now
        save_devices()
    return True, did


ONLINE_WINDOW = 120          # 这么多秒内有动作算「在线」

# 未配对手机的临时名单（开放模式）：手机 WS 连上会发 /announce 报型号，
# 按 IP 记录。配对开关关着时手机不注册也有档案，控制台「手机」卡能显示状态。
OPEN_SEEN = {}               # ip -> {'model','os','last_ts'}
_OPEN_SEEN_LOCK = threading.Lock()


def online_devices(window=ONLINE_WINDOW):
    """最近 window 秒内有请求的设备（给托盘/控制台显示在线台数）。"""
    now = time.time()
    out = []
    with _DEV_LOCK:
        for d in DEVICES.get('devices') or []:
            ts = float(d.get('last_ts') or 0)
            if ts and now - ts <= window:
                out.append(d)
    return out


def connected_devices():
    """真正「连接着」的设备 = WS 长连接还挂着，或最近有操作。

    只看 last_ts 会把"连着但闲着"的手机显示成离线（手机不开操控盘时
    不发任何请求，连接却是活的），所以把 WS 活连接也算进来。"""
    with _WS_LIVE_LOCK:
        live = set(_WS_LIVE.keys())
    now = time.time()
    out = []
    with _DEV_LOCK:
        for d in DEVICES.get('devices') or []:
            ts = float(d.get('last_ts') or 0)
            if (d.get('token') or '') in live or (ts and now - ts <= ONLINE_WINDOW):
                out.append(d)
    return out


def phone_list():
    """手机卡数据：已配对设备 + 开放模式下的未配对手机，在线的排前面。"""
    with _WS_LIVE_LOCK:
        live = set(_WS_LIVE.keys())
    now = time.time()
    rows = []
    paired_ips = set()
    with _DEV_LOCK:
        for d in DEVICES.get('devices') or []:
            tok = d.get('token') or ''
            ts = float(d.get('last_ts') or 0)
            online = tok in live or bool(ts and now - ts <= ONLINE_WINDOW)
            if d.get('ip'):
                paired_ips.add(d['ip'])
            rows.append({'name': d.get('name'), 'model': d.get('model'),
                         'os': d.get('os') or '', 'res': d.get('res') or '',
                         'ip': d.get('ip'), 'last': d.get('last'), 'online': online})
    # 开放模式下没配对的手机：WS 活着或最近有动作都算在线
    with _OPEN_SEEN_LOCK:
        seen_items = list(OPEN_SEEN.items())
    stale = []
    for ip, v in seen_items:
        if ip in paired_ips:
            continue
        age = now - float(v.get('last_ts') or 0)
        if age > 86400:
            stale.append(ip)             # 超过一天没动静的临时记录直接清掉
            continue
        online = ('open:' + ip) in live or age <= ONLINE_WINDOW
        rows.append({'name': '未配对手机', 'model': v.get('model') or '',
                     'os': v.get('os') or '', 'res': v.get('res') or '',
                     'ip': ip,
                     'last': datetime.fromtimestamp(float(v.get('last_ts') or now)).strftime('%H:%M:%S'),
                     'online': online})
    if stale:
        with _OPEN_SEEN_LOCK:
            for ip in stale:
                OPEN_SEEN.pop(ip, None)
    rows.sort(key=lambda x: (not x['online'], x.get('name') or ''))
    return rows


def tray_status_text():
    """托盘状态行：运行状态 + 端口 + 在线台数。"""
    if not service_running():
        return '○ 服务已停止'
    n = len(connected_devices())
    tail = (' · %d 台在线' % n) if n else ' · 无设备连接'
    return '● 运行中 · 端口 %d%s' % (PORT, tail)


def autostart_enabled():
    try:
        key = winreg.OpenKey(winreg.HKEY_CURRENT_USER,
                             r'Software\Microsoft\Windows\CurrentVersion\Run',
                             0, winreg.KEY_QUERY_VALUE)
        try:
            winreg.QueryValueEx(key, 'PCRemoteServer')
            return True
        except FileNotFoundError:
            return False
        finally:
            winreg.CloseKey(key)
    except Exception:
        return False

# ---------- Windows 防火墙放行（手机连不上的头号原因） ----------
FW_RULE = 'PCRemotePort'          # 用纯 ASCII 规则名，避免 cmd 传中文变乱码
_FW_CACHE = {'ts': 0.0, 'ok': None, 'action': ''}


def _run_hidden(args):
    """静默跑命令（不闪黑窗），返回 (returncode, 输出文本)。"""
    flags = 0x08000000 if os.name == 'nt' else 0   # CREATE_NO_WINDOW
    try:
        r = subprocess.run(args, capture_output=True, creationflags=flags)
    except Exception as exc:
        return -1, str(exc)
    raw = (r.stdout or b'') + (r.stderr or b'')
    for enc in ('gbk', 'utf-8'):
        try:
            return r.returncode, raw.decode(enc)
        except Exception:
            continue
    return r.returncode, raw.decode('utf-8', 'replace')


def _fw_info():
    """把缓存状态整理成给界面看的对象（缓存命中时也要带 msg）。"""
    info = dict(_FW_CACHE)
    if info.get('ok') and info.get('action') == 'allow':
        info['msg'] = '已放行 TCP %d' % PORT
    elif info.get('ok'):
        info['msg'] = '规则存在但状态是「阻止」'
    else:
        info['msg'] = '未发现放行规则（手机可能连不上）'
    return info


def firewall_check(force=False, ttl=60):
    """看遥控端口有没有被放行。返回 {ok, action, msg, ts}。

    ok=True + action='allow' 才算真的放行；action='block' 说明有同名阻止规则。
    """
    now = time.time()
    if not force and _FW_CACHE['ok'] is not None and now - _FW_CACHE['ts'] < ttl:
        return _fw_info()
    rc, out = _run_hidden(['netsh', 'advfirewall', 'firewall', 'show', 'rule',
                           'name=%s' % FW_RULE])
    exists = (rc == 0) and (FW_RULE in out)
    action = ''
    if exists:
        low = out.lower()
        action = 'block' if ('block' in low or '阻止' in out) else 'allow'
    _FW_CACHE.update({'ts': now, 'ok': exists, 'action': action})
    return _fw_info()


def firewall_add():
    """提权添加放行规则（弹 UAC）。顺带删掉之前误点「取消」留下的阻止规则。"""
    cmd = (
        'netsh advfirewall firewall delete rule name="PCRemoteServer.exe" >nul 2>&1 & '
        'netsh advfirewall firewall delete rule name="PCRemoteServer" >nul 2>&1 & '
        'netsh advfirewall firewall delete rule name="%s" >nul 2>&1 & '
        'netsh advfirewall firewall add rule name="%s" dir=in action=allow '
        'protocol=TCP localport=%d profile=any & '
        'netsh advfirewall firewall add rule name="%s" dir=in action=allow '
        'protocol=UDP localport=%d profile=any'
    ) % (FW_RULE, FW_RULE, PORT, FW_RULE, PORT)
    try:
        import ctypes
        rc = ctypes.windll.shell32.ShellExecuteW(None, 'runas', 'cmd.exe',
                                                 '/c ' + cmd, None, 0)
    except Exception as exc:
        return False, '调用提权失败：%s' % exc
    if rc <= 32:
        return False, '已取消：改防火墙需要管理员权限'
    _FW_CACHE['ok'] = None
    return True, '已发起，请在系统弹窗点「是」；3 秒后回来看状态即可'


# ---------- NeoShell 可选接入 ----------
NEO_CONFIG = BASE_DIR / '.neoshell' / 'config.json'
NS_KEY = ''
NS_PORT = 8000
NS_AVAILABLE = False


# ---------- 扫码配对 ----------
PAIR_PAGE_HTML = (
    '<!doctype html><meta charset="utf-8">'
    '<meta name="viewport" content="width=device-width,initial-scale=1">'
    '<title>PC遥控器 配对</title>'
    '<style>body{font-family:sans-serif;background:#F2F5FA;display:flex;'
    'flex-direction:column;align-items:center;padding:32px 16px}'
    'h1{font-size:20px;color:#0F1B2A}#qr{background:#fff;padding:16px;'
    'border-radius:16px;box-shadow:0 4px 16px #140A1B2A}code{margin-top:16px;'
    'background:#fff;padding:8px 12px;border-radius:8px;font-size:12px;'
    'color:#0A59F7;word-break:break-all;max-width:90%%}p{color:#8A97A8;font-size:13px}</style>'
    '<h1>PC遥控器 · 扫码配对</h1>'
    '<div id="qr">%s</div>'
    '<code>%s</code>'
    '<p>用手机 App 扫描此二维码（主页点电脑名 → 扫码配对新电脑）<br>二维码内容为配对指令（仅局域网地址，不含密码）</p>'
)


def _qr_img_html(text):
    """服务端直接生成二维码 PNG（内嵌 base64），不依赖外网 CDN。"""
    try:
        import base64
        import io
        import qrcode
        img = qrcode.make(text, box_size=8, border=2)
        buf = io.BytesIO()
        img.save(buf, format='PNG')
        b64 = base64.b64encode(buf.getvalue()).decode('ascii')
        return '<img alt="配对二维码" src="data:image/png;base64,%s" width="280" height="280">' % b64
    except Exception:
        return '<p style="color:#C0392B">二维码生成失败，请把下方地址复制到手机手动配对</p>'


_IP_CACHE = {'v': '', 'ts': 0.0}
_MAC_CACHE = {'v': '', 'ts': 0.0}
# 网卡信息缓存 60 秒：/pairinfo 是手机心跳接口（每 8 秒一次），
# 原来每次都现算 MAC（要拉起 PowerShell 的 Get-NetAdapter，约 2.4 秒），
# 比手机端 2.5 秒超时还长，心跳必然超时 → 界面一直显示"未连接"。
NETINFO_TTL = 60.0


def _local_lan_ip():
    """探测本机局域网 IP（UDP connect 不发真实流量）。失败回退 127.0.0.1。"""
    now = time.time()
    if _IP_CACHE['v'] and now - _IP_CACHE['ts'] < NETINFO_TTL:
        return _IP_CACHE['v']
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    ip = '127.0.0.1'
    try:
        s.connect(('8.8.8.8', 80))
        ip = s.getsockname()[0]
    except Exception:
        ip = '127.0.0.1'
    finally:
        s.close()
    _IP_CACHE['v'] = ip
    _IP_CACHE['ts'] = now
    return ip


def _primary_mac():
    """取本机通用 MAC，带 60 秒缓存（详见 _probe_mac 的耗时说明）。"""
    now = time.time()
    if _MAC_CACHE['v'] and now - _MAC_CACHE['ts'] < NETINFO_TTL:
        return _MAC_CACHE['v']
    mac = _probe_mac()
    # 探测失败（空串）也缓存，避免每 8 秒心跳都去拉一次 PowerShell
    _MAC_CACHE['v'] = mac
    _MAC_CACHE['ts'] = now
    return mac


def _probe_mac():
    """取本机通用 MAC（第一字节最低位=0 表示厂商分配的真实地址）。
    Win11 常开随机化 MAC，uuid.getnode 会拿到随机地址，此时回退
    用 Get-NetAdapter 按局域网 IP 反查真实网卡 MAC。失败返回空串。
    注意：PowerShell 冷启动 + NetAdapter 模块加载约 2.4 秒，
    只能在缓存未命中时调用，绝不能放进高频接口。"""
    try:
        node = uuid.getnode()
        if node and not (node >> 40) & 0x01:          # 本地管理位=0 才是真实地址
            return '-'.join('%02X' % ((node >> (8 * i)) & 0xFF) for i in range(5, -1, -1))
    except Exception:
        pass
    try:
        ip = _local_lan_ip()
        ps = ("(Get-NetAdapter | Where-Object {$_.Status -eq 'Up' -and "
              "$_.ifIndex -in (Get-NetIPAddress -AddressFamily IPv4 | "
              "Where-Object {$_.IPAddress -eq '%s'} | "
              "Select-Object -ExpandProperty InterfaceIndex)}).MacAddress" % ip)
        r = subprocess.run(['powershell', '-NoProfile', '-Command', ps],
                           capture_output=True, text=True, timeout=20,
                           encoding='gbk', errors='replace',
                           creationflags=0x08000000 if os.name == 'nt' else 0)
        mac = (r.stdout or '').strip().strip('"')
        # 形如 A0-AD-9F-18-C2-42；简单校验
        if re.fullmatch(r'[0-9A-Fa-f]{2}(-[0-9A-Fa-f]{2}){5}', mac or ''):
            return mac.upper()
    except Exception as exc:
        print('[warn] mac probe failed:', exc)
    return ''


def pair_url():
    """配对指令 URL：手机扫码后解析出 host/port/mac/name，并用 pt 换设备令牌。"""
    name = socket.gethostname()
    qs = urllib.parse.urlencode({'host': _local_lan_ip(), 'port': PORT,
                                 'mac': _primary_mac(), 'name': name,
                                 'pt': pair_ticket()})
    return 'pc-remote://pair?' + qs


def pair_page_url():
    """配对二维码网页地址（浏览器打开用；注意不是 pair_url 的 pc-remote 指令）。"""
    return 'http://127.0.0.1:%d/pair' % PORT


def load_neoshell():
    global NS_KEY, NS_PORT, NS_AVAILABLE
    try:
        if NEO_CONFIG.exists():
            cfg = json.loads(NEO_CONFIG.read_text(encoding='utf-8'))
            NS_KEY = str(cfg.get('secret_key', ''))
            NS_PORT = int(cfg.get('port', 8000))
            NS_AVAILABLE = bool(NS_KEY)
    except Exception as exc:
        print('[warn] NeoShell config read failed:', exc)
    print('[mode] NeoShell API:', 'ON' if NS_AVAILABLE else 'OFF (standalone)')


def ns_call(path, params=None, payload=None):
    """调用 NeoShell 的 POST API，返回 (ok, detail)。"""
    query = {'key': NS_KEY}
    if params:
        query.update(params)
    url = 'http://127.0.0.1:%d%s?%s' % (NS_PORT, path, urllib.parse.urlencode(query))
    data = json.dumps(payload or {}).encode('utf-8')
    req = urllib.request.Request(url, data=data, method='POST',
                                 headers={'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=4) as resp:
            body = resp.read().decode('utf-8', 'replace')
        obj = json.loads(body) if body else {}
        return bool(obj.get('success', True)), body[:120]
    except Exception as exc:
        return False, str(exc)


# ---------- 本地规则语音理解（离线，替代云端大模型） ----------
# 思路：分句 -> 逐句参数提取（打开/播放/搜索/建文件夹/网址/打字/点控件）
#       -> 关键词表匹配 -> 没懂的原样打字上屏兜底。全程本机完成，断网可用、毫秒级响应。

# 视频站别名/同音词 -> play_media 的 site 参数（匹配时按词长优先，避免"腾讯"抢了"腾讯视频"）
SITE_WORDS = {
    '哔哩哔哩': 'bilibili', 'bilibili': 'bilibili', 'b站': 'bilibili',
    '必站': 'bilibili', '笔站': 'bilibili', '哔站': 'bilibili', '哔哩': 'bilibili',
    'bili': 'bilibili', '小破站': 'bilibili',
    '爱奇艺': 'iqiyi', '奇异': 'iqiyi', '爱艺': 'iqiyi', '爱奇异': 'iqiyi',
    '腾讯视频': 'tencent', '腾讯': 'tencent',
    '优酷': 'youku', '优库': 'youku',
    '芒果tv': 'mgtv', '芒果': 'mgtv',
}
SITE_CN = {'bilibili': 'B站', 'iqiyi': '爱奇艺', 'tencent': '腾讯视频',
           'youku': '优酷', 'mgtv': '芒果TV'}

# "打开XX"里的特殊目标（先于任意程序匹配）
SPECIAL_OPEN = [
    ('任务管理器', 'taskmgr'), ('我的电脑', 'open_pc'), ('此电脑', 'open_pc'),
    ('资源管理器', 'open_explorer'), ('文件管理器', 'open_explorer'),
    ('浏览器', 'open_browser'), ('记事本', 'open_notepad'),
    ('计算器', 'open_calc'), ('设置', 'open_settings'),
]

# 动作 -> 语音确认语
ACTION_SAY = {
    'play_pause': '好的', 'next_track': '已切到下一集', 'prev_track': '已切到上一集',
    'forward': '已快进', 'rewind': '已快退',
    'vol_up': '音量加大', 'vol_down': '音量减小', 'mute': '静音已切换',
    'home': '已回到桌面', 'back': '已返回', 'browser_back': '已后退',
    'ok': '已确认', 'menu': '已打开菜单', 'alt_tab': '已切换窗口',
    'alt_f4': '已关闭窗口', 'ctrl_v': '已粘贴',
    'power': '已关闭显示器', 'power_sleep': '已进入睡眠', 'lock': '已锁屏',
    'power_shutdown': '10 秒后关机', 'power_reboot': '10 秒后重启',
    'wake': '电脑已经是开着的',
    'taskmgr': '已打开任务管理器', 'open_pc': '已打开此电脑',
    'open_explorer': '已打开资源管理器', 'open_browser': '已打开浏览器',
    'open_notepad': '已打开记事本', 'open_calc': '已打开计算器',
    'open_settings': '已打开设置',
    'web_search': '已用浏览器搜索', 'open_url': '已打开网址',
    'type': '已输入文字', 'none': '好的',
}

_CLAUSE_SPLIT = re.compile(r'然后|再|接着|，|,|。|；|;|？|\?|！|!')


def _norm_text(text):
    """去空白、转小写（中文不受影响），便于匹配。"""
    return ''.join(ch for ch in str(text) if not ch.isspace()).lower()


# ---------- 拼音容错（补上大模型最实用的「同音错字纠正」） ----------
# 语音识别常把同音字听错：威信 -> 微信、记事簿 -> 记事本、庆鱼年 -> 庆余年。
# 走拼音比字面比对更贴近真实错误，且完全本地、毫秒级。
try:
    from pypinyin import lazy_pinyin
    HAS_PINYIN = True
except Exception:
    HAS_PINYIN = False
    print('[warn] pypinyin 未安装，同音字容错关闭（pip install pypinyin 可开启）')

_PY_CACHE = {}


def _py(s):
    """转无声调拼音串（拉丁字母/数字原样保留），带缓存。"""
    key = str(s)
    cached = _PY_CACHE.get(key)
    if cached is not None:
        return cached
    if not HAS_PINYIN:
        out = key.lower()
    else:
        try:
            out = ''.join(lazy_pinyin(key, errors='default')).lower()
        except Exception:
            out = key.lower()
    if len(_PY_CACHE) < 5000:
        _PY_CACHE[key] = out
    return out


def _lev(a, b):
    """编辑距离（短串 DP，够用）。"""
    if a == b:
        return 0
    if not a:
        return len(b)
    if not b:
        return len(a)
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def _py_sim(a, b):
    """按拼音算相似度 0~1（同音=1.0）。"""
    pa, pb = _py(a), _py(b)
    if not pa or not pb:
        return 0.0
    if pa == pb:
        return 1.0
    return 1.0 - float(_lev(pa, pb)) / max(len(pa), len(pb))


def _extract_site(s):
    """找句中的视频站别名，返回 (site, 去掉别名的句子) 或 (None, s)。"""
    for word in sorted(SITE_WORDS, key=len, reverse=True):
        if word in s:
            return SITE_WORDS[word], s.replace(word, '', 1)
    return None, s


# 否定词：语音里"不要关机/别锁屏"字面含动作词，直接走关键词会听反，做成相反动作。
# 策略（保守拦截）：句中有否定词、且去掉否定词后像一条动作 -> 一律不执行，只回话。
_NEG_RE = re.compile(r'不要|不用|甭|无需|没必要|勿|先别|别|不')
# "不"常作构词成分（不错/不但/忍不住），这些不算否定，否则"天气不错"会被误拦
_NEG_SOFT = ('不错', '不但', '不仅', '不过', '不好意思', '差不多', '不管', '不久',
             '不断', '不同', '不少', '不然', '不得不', '忍不住', '要不然', '不安')
_ACT_HEAD = re.compile(r'^(?:帮我|请|麻烦)?(打开|启动|运行|拉起|开|关|关闭|放|播|播放|看|搜|查|建|创建|输入|打字|点击|点)')


def _looks_like_action(t):
    """去掉否定词后，这句话是不是像要执行点什么。"""
    for kw, _a in VOICE_COMMANDS:
        if kw in t:
            return True
    for w in ('关机', '重启', '睡眠', '休眠', '锁屏', '关屏', '注销', '退出'):
        if w in t:
            return True
    return bool(_ACT_HEAD.match(t))


def _parse_clause(c):
    """解析单句，返回 (action, arg_dict, say) 或 None（没懂）。"""
    s = _norm_text(c)
    if not s:
        return None

    # 0) 否定句拦截：必须先于关键词匹配，否则"不要关机"会被当成"关机"
    m_neg = None
    for _m in _NEG_RE.finditer(s):
        if any(s[_m.start():_m.start() + 4].startswith(w) for w in _NEG_SOFT):
            continue
        m_neg = _m
        break
    if m_neg:
        s_pos = s[:m_neg.start()] + s[m_neg.end():]
        if _looks_like_action(s_pos):
            print('[neg] blocked: %s' % s)
            return 'none', {}, '好，没动'

    _has_neg = m_neg is not None

    # 0) 整句恰好是固定指令（优先，避免"播放暂停"被当成点播"暂停"）
    for kw, act in VOICE_COMMANDS:
        if s == _norm_text(kw):
            return act, {}, ACTION_SAY.get(act, '好的')

    # 1) 打字：帮我打字：XX / 输入XX / 打字XX
    m = re.match(r'(?:帮我)?(?:打字|输入|打上|写上)[：:是]?(.+)', s)
    if m and m.group(1):
        return 'type', {'text': m.group(1)}, ACTION_SAY['type']

    # 2) 唤醒电脑（"打开我的电脑"是开资源管理器，不在这）
    if s in ('打开电脑', '唤醒电脑', '开电脑', '开机', '把电脑打开', '电脑开机',
             '唤醒我的电脑', '叫醒电脑'):
        return 'wake', {}, ACTION_SAY['wake']

    # 3) 打开网址（句子里带域名）
    if re.search(r'\.(com|cn|net|org|tv|io|cc|top|vip)\b', s) and \
            re.search(r'打开|访问|网址|上一下|上网', s):
        hosts = re.findall(r'[a-z0-9\-]+(?:\.[a-z0-9\-]+)+', s)
        if hosts:
            url = max(hosts, key=len)
            if not url.startswith('http'):
                url = 'https://' + url
            return 'open_url', {'url': url}, ACTION_SAY['open_url']

    # 4) 带站名的点播/搜片：用B站播三体 / 在爱奇艺搜狂飙
    site, s2 = _extract_site(s)
    if site:
        # 「把 B 站弄出来 / 打开爱奇艺」——只要站点不要片名，直接开首页
        if re.search(r'打开|弄出来|叫出来|调出来|首页', s2) and not re.search(r'播|放|看|搜|找', s2):
            return ('open_url', {'url': MEDIA_SITES.get(site, '')},
                    '已打开' + SITE_CN[site])
        s2 = re.sub(r'^(用|上|去|在|到|帮我|给我)+', '', s2)
        q = re.sub(r'^(搜一下|播放一下|播放|搜|点播|看|放|播|找)+', '', s2)
        if q:
            if s2.startswith(('搜', '找')):
                return ('play_media', {'q': q, 'site': site},
                        '已打开%s搜索页' % SITE_CN[site])
            return ('auto_play', {'q': q, 'site': site},
                    '正在用%s播放%s' % (SITE_CN[site], q))

    # 4.5) 用XX放歌/听歌/放音乐 -> 打开对应程序
    m = re.match(r'^(?:用|上|去|打开|启动|开)(.+?)(?:放歌|听歌|唱歌|放音乐|听音乐|放个歌|听首歌|放视频)$', s)
    if m and m.group(1):
        return 'launch_app', {'name': m.group(1)}, '正在打开' + m.group(1)[:12]

    # 5) 没有站名的点播：播放庆余年 / 我想看三体 / 放个新闻联播
    m = re.match(r'^(?:我要|我想|给我|帮我|来)?(?:播放|播|看|放|点播)(?:一下|个)?(.+)$', s)
    if m and m.group(1):
        return ('auto_play', {'q': m.group(1), 'site': 'bilibili'},
                '正在用B站播放%s' % m.group(1))

    # 6) 网页搜索：搜一下怎么炖排骨 / 查一下天气
    m = re.match(r'^(?:帮我)?(?:搜索|搜一下|搜|百度一下|百度|查一下|查|查询)(?:一下)?(.+)$', s)
    if m and m.group(1):
        return 'web_search', {'q': m.group(1)}, ACTION_SAY['web_search']

    # 7) 新建文件夹：在D盘建个文件夹叫资料 / 新建文件夹资料
    if '文件夹' in s and re.search(r'建|创建|new', s):
        name = ''
        m = re.search(r'(?:叫|名为|名字是|名字叫|命名(?:为|成))[:：]?(.+)$', s)
        if m:
            name = m.group(1)
        else:
            m = re.search(r'文件夹(?:叫|为|名)?(.+)$', s)
            if m:
                name = m.group(1)
        name = name or '新建文件夹'
        path = ''
        m = re.search(r'(?:在|到)([cdef])盘', s)
        if m:
            path = m.group(1).upper() + ':\\'
        return 'new_folder', {'name': name, 'path': path}, '已新建文件夹' + name

    # 8) 打开程序：打开微信 / 启动PotPlayer / 开一下QQ音乐
    m = re.match(r'^(?:帮我|请)?(?:打开|启动|运行|拉起|开一下|开个|开)(?:一下)?(.+)$', s)
    if m and m.group(1):
        target = m.group(1)
        for kw, act in SPECIAL_OPEN:
            if kw in target:
                return act, {}, ACTION_SAY[act]
        # 同音字容错：任物管理器 -> 任务管理器（拼音全等最可靠）
        if len(target) >= 2:
            tp = _py(target)
            for kw, act in SPECIAL_OPEN:
                if _py(kw) == tp:
                    print('[open] pinyin equal: %s -> %s' % (target, kw))
                    return act, {}, ACTION_SAY[act]
            for kw, act in SPECIAL_OPEN:
                if _py_sim(target, kw) >= 0.9:
                    print('[open] pinyin fuzzy: %s -> %s' % (target, kw))
                    return act, {}, ACTION_SAY[act]
        return 'launch_app', {'name': target}, '正在打开' + target[:12]

    # 8.5) 倒装句：把微信打开 / 微信给我打开一下 / 把 B 站弄出来
    m = re.match(r'^(?:给我|帮我|请)?把?(.{2,12}?)(?:给我|帮我)?(?:打开|弄出来|叫出来|调出来)(?:一下|吧)?$', s)
    if m and m.group(1) and not re.search(r'屏幕|显示器|窗口|文件夹', m.group(1)):
        target = m.group(1).strip()
        for kw, act in SPECIAL_OPEN:
            if kw in target:
                return act, {}, ACTION_SAY[act]
        return 'launch_app', {'name': target}, '正在打开' + target[:12]

    # 9) 点控件：点击确定 / 点开记事本的文件菜单 / 在资源管理器点新建文件夹按钮
    name = ''
    ctx = ''
    m = re.match(r'^(?:帮我在|在)?(.{0,6}?)(?:帮我)?(?:点击|点一下|点开|点)(.+?)(?:按钮|菜单|选项|图标)$', s)
    if m:
        ctx, name = m.group(1) or '', m.group(2)
    else:
        m = re.match(r'^(?:点击|点一下|点开|点)(.+)$', s)
        if m:
            name = m.group(1)
    if name:
        app = ''
        for alias in APP_ALIAS:
            if alias in ctx:
                app = alias
                break
            if alias in name:
                app = alias
                name = name.replace(alias, '')
                break
        name = name.strip('的里里面外')
        if name:
            return 'uia_click', {'name': name, 'app': app}, '已点击' + name[:10]

    # 9.5) 电源类句式变化最多（把屏幕关掉省点电 / 屏幕给我关了），用「对象+动作」组合判断，
    #      不靠穷举说法。带否定词的一律跳过，避免「电脑关不了」被听成关机。
    if not _has_neg:
        if re.search(r'屏幕|显示器|显示屏|屏', s) and re.search(r'关|灭|黑|熄', s):
            return 'power', {}, ACTION_SAY['power']
        if re.search(r'屏幕|电脑', s) and re.search(r'锁', s):
            return 'lock', {}, ACTION_SAY['lock']
        # 「把电脑关了 / 我先走了电脑关了吧」：明确说了电脑 + 关，才走关机
        if re.search(r'电脑|主机', s) and re.search(r'关机|关了吧|关了|关掉|关闭', s):
            return 'power_shutdown', {}, ACTION_SAY['power_shutdown']

    # 10) 固定指令子串匹配（音量/媒体/电源/系统键等）
    for kw, act in VOICE_COMMANDS:
        if kw in s:
            return act, {}, ACTION_SAY.get(act, '好的')

    # 11) 问候/感谢 -> 不动作只回话
    if re.fullmatch(r'(你好|您好|哈喽|hello|嗨|hi)[啊呀哦哈呀]?', s):
        return 'none', {}, '你好'
    if '谢谢' in s or '辛苦' in s or '不错' in s:
        return 'none', {}, '不客气'

    return None


def local_understand(text):
    """离线把语音文字解析成 ([(action, arg), ...], say)。全没懂返回 None（调用方打字上屏兜底）。"""
    raw = str(text).strip()
    if not raw:
        return None
    clauses = [c.strip() for c in _CLAUSE_SPLIT.split(raw) if c.strip()]
    steps = []
    says = []
    unmatched = []
    for c in clauses:
        got = _parse_clause(c)
        if got is None:
            unmatched.append(c)
            continue
        act, arg, sub_say = got
        if act not in ('none',):
            steps.append((act, arg))
        if sub_say:
            says.append(sub_say)
    # 有懂的部分也有没懂的：没懂的部分打字上屏（与原兜底行为一致）
    if unmatched and steps:
        steps.append(('type', {'text': ''.join(unmatched)}))
        says.append('其余已打字上屏')
    elif unmatched and not steps:
        # 整句没懂 -> 原样打字上屏
        steps.append(('type', {'text': raw}))
        says.append('已输入文字')
    say = '；'.join(dict.fromkeys(says))[:60] if says else '好的'
    return steps, say


# ---------- LLM 兜底（设置里「语音 LLM 兜底」开关，默认关） ----------
# 本地规则整句没听懂时，把话交给大模型拆成动作步骤再执行；
# 模型说这不是指令（口述/闲聊）就维持原样打字上屏。
_LLM_PROMPT = """你是电脑遥控器的语音指令解析器。用户对着手机说了一句话，你把它解析成对 Windows 电脑的动作步骤。

可用动作（act 只能取下列值）：
- type {"text": "文字"} 把文字输入到电脑当前焦点位置
- keys {"keys": ["ctrl", "s"]} 组合键，键名只能是：ctrl alt shift win enter esc tab space backspace delete insert home end pageup pagedown up down left right a到z 0到9 f1到f12
- launch_app {"name": "微信"} 打开开始菜单里的应用
- open_url {"url": "https://..."} 打开网址
- web_search {"q": "关键词"} 搜索引擎搜索
- play_media {"q": "关键词", "site": "bilibili"} 到视频站搜索播放，site 可选 bilibili/youtube/youku/iqiyi
- open_pc 打开此电脑 / open_explorer 资源管理器 / open_browser 浏览器 / open_notepad 记事本 / open_calc 计算器 / open_settings 设置 / taskmgr 任务管理器
- alt_tab 切换窗口 / alt_f4 关闭窗口 / home 显示桌面 / menu 右键菜单 / ok 回车 / back 返回 / browser_back 网页后退
- vol_up 音量加 / vol_down 音量减 / mute 静音 / play_pause 播放暂停 / prev_track 上一首 / next_track 下一首 / rewind 快退 / forward 快进
- lock 锁屏 / mouse_left 单击 / mouse_right 右键 / mouse_double 双击 / new_folder {"name": "文件夹名"}

规则：
1. 用户只是在口述文字、闲聊或提问（并不想让电脑执行动作）→ is_command 填 false
2. 严禁输出关机、重启、睡眠类动作
3. say 是回给用户的口语，不超过 20 字
4. 只输出 JSON，不要任何解释或代码块标记
示例：{"is_command": true, "steps": [{"act": "launch_app", "arg": {"name": "微信"}}], "say": "好的"}"""


def _llm_chat(text, timeout):
    """调 DeepSeek 兼容接口，返回模型回复文本或 None。"""
    try:
        cfg = json.loads((BASE_DIR / 'llm_config.json').read_text(encoding='utf-8'))
    except Exception:
        return None
    if not cfg.get('enabled') or not cfg.get('api_key'):
        return None
    body = json.dumps({
        'model': cfg.get('model', ''),
        'messages': [
            {'role': 'system', 'content': _LLM_PROMPT},
            {'role': 'user', 'content': str(text)[:120]},
        ],
        'temperature': 0.1,
        'max_tokens': 300,
    }).encode('utf-8')
    req = urllib.request.Request(
        str(cfg.get('base_url', '')), data=body,
        headers={'Content-Type': 'application/json',
                 'Authorization': 'Bearer ' + str(cfg.get('api_key', ''))})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = json.loads(resp.read().decode('utf-8', 'replace'))
        return (data.get('choices') or [{}])[0].get('message', {}).get('content', '')
    except Exception as exc:
        print('[llm] failed: %s' % exc)
        return None


def llm_understand(text):
    """本地没懂时问大模型。返回 (steps, say) 或 None（调用方走打字兜底）。"""
    if not SETTINGS.get('llm_fallback'):
        return None
    raw = _llm_chat(text, min(int(SETTINGS.get('llm_timeout') or 8), 12))
    if not raw:
        return None
    m = re.search(r'\{.*\}', raw, re.S)   # 容忍模型包一层 ```json 围栏
    if not m:
        return None
    try:
        d = json.loads(m.group(0))
    except Exception:
        return None
    if not isinstance(d, dict) or not d.get('is_command'):
        return None
    steps = []
    for s in (d.get('steps') or [])[:6]:
        if not isinstance(s, dict):
            continue
        act = str(s.get('act', '')).strip()
        if act not in CUSTOM_ACTS or act == 'power':
            continue
        arg = s.get('arg') if isinstance(s.get('arg'), dict) else {}
        if act == 'keys':
            names = [str(k).lower() for k in (arg.get('keys') or [])]
            if not names or any(n not in VK for n in names):
                continue
            arg = {'keys': names}
        elif act == 'type':
            txt = _arg(arg, 'text')
            if not txt:
                continue
            arg = {'text': txt[:500]}
        elif act == 'delay':
            try:
                ms = int(float(str(arg.get('ms') or arg.get('text') or 0)))
            except (TypeError, ValueError):
                continue
            if ms < 100:
                continue
            arg = {'ms': min(ms, 10000)}   # LLM 给的等待最长 10 秒
        steps.append((act, arg))
    if not steps:
        return None
    say = str(d.get('say', '')).strip()[:40] or '好的'
    return steps, say



# ---------- Windows 按键注入 ----------
VK = {
    'up': 0x26, 'down': 0x28, 'left': 0x25, 'right': 0x27,
    'enter': 0x0D, 'esc': 0x1B, 'tab': 0x09, 'space': 0x20,
    'backspace': 0x08, 'delete': 0x2E, 'insert': 0x2D,
    'home': 0x24, 'end': 0x23, 'pageup': 0x21, 'pagedown': 0x22,
    'win': 0x5B, 'shift': 0x10, 'ctrl': 0x11, 'alt': 0x12,
    'vol_up': 0xAF, 'vol_down': 0xAE, 'mute': 0xAD,
    'playpause': 0xB3, 'next': 0xB0, 'prev': 0xB1,
}
# 字母 / 数字 / F1-F12：键盘页组合键（Ctrl+C、Win+D 等）要用，按码表批量补齐
for _i, _ch in enumerate('abcdefghijklmnopqrstuvwxyz'):
    VK[_ch] = 0x41 + _i
for _ch in '0123456789':
    VK[_ch] = 0x30 + int(_ch)
for _n in range(1, 13):
    VK['f%d' % _n] = 0x6F + _n

KEYEVENTF_KEYUP = 0x0002

# user32 句柄缓存：ctypes.windll 的属性查找会走加载器，鼠标/键盘是每秒几十次的
# 热路径，没必要每次都重新查一遍。
_U32 = None


def _u32():
    global _U32
    if _U32 is None:
        import ctypes
        _U32 = ctypes.windll.user32
    return _U32


def _keybd(vk, up=False):
    _u32().keybd_event(vk, 0, KEYEVENTF_KEYUP if up else 0, 0)


def tap(name):
    vk = VK[name]
    _keybd(vk)
    _keybd(vk, up=True)
    return 'tap ' + name


def combo(*names):
    for n in names:
        _keybd(VK[n])
    for n in reversed(names):
        _keybd(VK[n], up=True)
    return 'combo ' + '+'.join(names)


def mouse_click(button):
    """注入鼠标点击：left / right / double（左键双击）。统一返回 (detail, ok)。"""
    u = _u32()
    import time
    if button == 'right':
        u.mouse_event(0x0008, 0, 0, 0, 0)  # RIGHTDOWN
        u.mouse_event(0x0010, 0, 0, 0, 0)  # RIGHTUP
    elif button == 'double':
        # 两次左键单击，间隔 90ms，触发系统双击判定
        u.mouse_event(0x0002, 0, 0, 0, 0)
        u.mouse_event(0x0004, 0, 0, 0, 0)
        time.sleep(0.09)
        u.mouse_event(0x0002, 0, 0, 0, 0)
        u.mouse_event(0x0004, 0, 0, 0, 0)
    else:
        u.mouse_event(0x0002, 0, 0, 0, 0)  # LEFTDOWN
        u.mouse_event(0x0004, 0, 0, 0, 0)  # LEFTUP
    return 'mouse ' + button + ' click', True


def mouse_move(dx, dy):
    """相对移动鼠标光标：MOUSEEVENTF_MOVE=0x0001，dx/dy 为相对像素。"""
    _u32().mouse_event(0x0001, int(dx), int(dy), 0, 0)
    return 'mouse move %+d,%+d' % (dx, dy), True


def mouse_scroll(delta):
    """滚轮：正数上滚、负数下滚；Windows 一格 = 120。"""
    d = int(max(-1200, min(1200, delta)))
    if d == 0:
        return 'mouse scroll 0 (skip)', True
    _u32().mouse_event(0x0800, 0, 0, d, 0)
    return 'mouse scroll %+d' % d, True


def mouse_button(down, button='left'):
    """按下/抬起鼠标键（拖拽用）：left 0x0002/0x0004，right 0x0008/0x0010。"""
    if button == 'right':
        flag = 0x0008 if down else 0x0010
    elif button == 'middle':
        flag = 0x0020 if down else 0x0040
    else:
        flag = 0x0002 if down else 0x0004
    _u32().mouse_event(flag, 0, 0, 0, 0)
    return 'mouse %s %s' % (button, 'down' if down else 'up'), True


# ---------- 语音：文字 → 电脑 ----------
# 关键词 → Action 指令表（按优先级从长到短匹配，避免"下一集"被"下"截断）
VOICE_COMMANDS = [
    # 打开应用（放最前，避免被"打开"通用词截断）
    ('打开任务管理器', 'taskmgr'),
    ('打开我的电脑', 'open_pc'),
    ('打开此电脑', 'open_pc'),
    ('打开资源管理器', 'open_explorer'),
    ('打开文件管理器', 'open_explorer'),
    ('打开浏览器', 'open_browser'),
    ('打开记事本', 'open_notepad'),
    ('打开计算器', 'open_calc'),
    ('打开设置', 'open_settings'),
    ('切换到上一个窗口', 'alt_tab'),
    ('切换到下一个窗口', 'alt_tab'),
    ('关闭当前窗口', 'alt_f4'),
    ('关闭这个窗口', 'alt_f4'),
    ('关掉这个窗口', 'alt_f4'),
    ('切换窗口', 'alt_tab'),
    ('关掉窗口', 'alt_f4'),
    ('关闭窗口', 'alt_f4'),
    ('回到桌面', 'home'),
    ('显示桌面', 'home'),
    ('下一集', 'next_track'),
    ('上一集', 'prev_track'),
    ('下一个', 'next_track'),
    ('上一个', 'prev_track'),
    ('下一首', 'next_track'),
    ('上一首', 'prev_track'),
    ('播放暂停', 'play_pause'),
    ('暂停播放', 'play_pause'),
    ('继续播放', 'play_pause'),
    ('开始播放', 'play_pause'),
    ('音量加大', 'vol_up'),
    ('音量调大', 'vol_up'),
    ('声音大点', 'vol_up'),
    ('音量减小', 'vol_down'),
    ('音量调小', 'vol_down'),
    ('声音小点', 'vol_down'),
    ('切到下一首', 'next_track'),
    ('切到上一首', 'prev_track'),
    ('快进', 'forward'),
    ('快退', 'rewind'),
    ('静音', 'mute'),
    ('取消静音', 'mute'),
    ('确定', 'ok'),
    ('确认', 'ok'),
    ('回车', 'ok'),
    ('返回', 'back'),
    ('后退', 'browser_back'),
    ('网页后退', 'browser_back'),
    ('上一步', 'browser_back'),
    ('上一级', 'browser_back'),
    ('主页', 'home'),
    ('锁屏', 'lock'),
    ('关闭屏幕', 'power'),
    ('关掉屏幕', 'power'),
    ('关屏幕', 'power'),
    ('黑屏', 'power'),
    ('熄屏', 'power'),
    ('关闭显示器', 'power'),
    ('关掉显示器', 'power'),
    ('屏幕关了', 'power'),
    ('显示器关了', 'power'),
    ('睡眠', 'power_sleep'),
    ('关机', 'power_shutdown'),
    ('重启电脑', 'power_reboot'),
    ('播放', 'play_pause'),
    ('暂停', 'play_pause'),
]


def command_from_text(text):
    """文字里含有指令关键词则返回对应 action，否则返回 None。"""
    s = ''.join(ch for ch in str(text) if not ch.isspace()).lower()
    for keyword, action in VOICE_COMMANDS:
        if keyword in s:
            return action, keyword
    return None, None


# ---------- 自定义语音指令（管理界面配置，命中优先级高于固定关键词表） ----------
# 存在 exe/脚本同目录 voice_custom.json，改完即生效（按文件修改时间自动重载）。
CUSTOM_FILE = BASE_DIR / 'voice_custom.json'
CUSTOM = {'commands': []}
CUSTOM_MTIME = [0.0]

# 自定义指令 / LLM 兜底允许使用的动作白名单。
# 关机/重启/睡眠不在表里（太危险）；「power 关显示器」只允许自定义指令用，
# LLM 生成的步骤一律不给，防止它把「关机」误解成关显示器之类的意外动作。
CUSTOM_ACTS = {
    'type', 'keys', 'launch_app', 'open_url', 'web_search', 'play_media',
    'open_pc', 'open_explorer', 'open_browser', 'open_notepad', 'open_calc',
    'open_settings', 'taskmgr', 'alt_tab', 'alt_f4', 'home', 'menu', 'ok',
    'back', 'browser_back', 'vol_up', 'vol_down', 'mute', 'play_pause',
    'prev_track', 'next_track', 'rewind', 'forward', 'lock', 'power',
    'mouse_left', 'mouse_right', 'mouse_double', 'new_folder', 'delay',
}


def load_custom(force=False):
    """读 voice_custom.json，文件改动后自动重载（管理页保存 / 手改文件都生效）。"""
    try:
        st = CUSTOM_FILE.stat()
        if not force and st.st_mtime == CUSTOM_MTIME[0]:
            return
        CUSTOM_MTIME[0] = st.st_mtime
        data = json.loads(CUSTOM_FILE.read_text(encoding='utf-8'))
        cmds = data.get('commands') if isinstance(data, dict) else None
        CUSTOM['commands'] = [c for c in (cmds or []) if isinstance(c, dict)]
    except FileNotFoundError:
        CUSTOM_MTIME[0] = 0.0
        CUSTOM['commands'] = []
    except Exception as exc:
        print('[custom] load failed: %s' % exc)


def save_custom(commands):
    """清洗后写盘。返回保留的条数；非法短语/步骤/键名直接丢弃。"""
    clean = []
    for c in (commands or []):
        if not isinstance(c, dict):
            continue
        phrase = str(c.get('phrase', '')).strip()
        if not phrase:
            continue
        steps = []
        for s in (c.get('steps') or []):
            if not isinstance(s, dict):
                continue
            act = str(s.get('act', '')).strip()
            if act not in CUSTOM_ACTS:
                continue
            arg = s.get('arg') if isinstance(s.get('arg'), dict) else {}
            if act == 'keys':
                names = [str(k).lower() for k in (arg.get('keys') or [])]
                if not names or any(n not in VK for n in names):
                    continue
                arg = {'keys': names}
            elif act == 'type':
                txt = _arg(arg, 'text')
                if not txt:
                    continue
                arg = {'text': txt[:500]}
            elif act == 'delay':
                # 等待步骤：100ms ~ 60s；整条指令的等待合计 ≤ 90s，
                # 防止同步等待拖超过手机连接的 150s 看门狗。
                try:
                    ms = int(float(str(arg.get('ms') or arg.get('text') or 0)))
                except (TypeError, ValueError):
                    continue
                if ms < 100:
                    continue
                total = sum(int(s['arg'].get('ms', 0)) for s in steps if s['act'] == 'delay')
                if total >= 90000:
                    continue
                arg = {'ms': min(ms, 60000, 90000 - total)}
            steps.append({'act': act, 'arg': arg})
        if not steps:
            continue
        clean.append({
            'id': str(c.get('id') or ('c%d' % (int(time.time() * 1000) % 100000000))),
            'phrase': phrase[:20],
            'alias': [str(a).strip()[:20] for a in (c.get('alias') or [])
                      if str(a).strip()][:6],
            'say': str(c.get('say', '')).strip()[:40],
            'enabled': bool(c.get('enabled', True)),
            'steps': steps[:8],
        })
    clean = clean[:10]                    # 自定义指令最多 10 条，多余的丢弃
    CUSTOM_FILE.write_text(json.dumps({'commands': clean}, ensure_ascii=False, indent=2),
                           encoding='utf-8')
    load_custom(force=True)
    return len(clean)


def custom_match(text):
    """语音文字命中自定义指令则返回 (command, 命中的短语)。

    匹配规则：先找「整句恰好等于短语」，再找「句中包含短语/别名」；
    同为包含时取更长的短语（避免"上课"抢走"开始上课"）。
    """
    load_custom()
    s = _norm_text(text)
    if not s:
        return None, ''
    hits = []
    for c in CUSTOM['commands']:
        if not c.get('enabled', True):
            continue
        for kw in [c.get('phrase', '')] + list(c.get('alias') or []):
            kwn = _norm_text(kw)
            if kwn and kwn in s:
                hits.append((0 if s == kwn else 1, len(kwn), c, kw))
    if not hits:
        return None, ''
    hits.sort(key=lambda x: (x[0], -x[1]))
    return hits[0][2], hits[0][3]


def custom_steps(cmd):
    """把自定义指令转成执行步骤列表 [(act, arg), ...]。"""
    return [(str(s.get('act')), s.get('arg') if isinstance(s.get('arg'), dict) else {})
            for s in (cmd.get('steps') or [])]



def set_clipboard(text):
    """把文字写入 Windows 剪贴板（unicode），供 Ctrl+V 粘贴上屏。"""
    import ctypes
    from ctypes import wintypes
    CF_UNICODETEXT = 13
    GMEM_MOVEABLE = 0x0002
    u32 = ctypes.windll.user32
    k32 = ctypes.windll.kernel32
    k32.GlobalAlloc.restype = wintypes.HGLOBAL
    k32.GlobalLock.argtypes = [wintypes.HGLOBAL]
    k32.GlobalLock.restype = wintypes.LPVOID
    k32.GlobalUnlock.argtypes = [wintypes.HGLOBAL]
    u32.SetClipboardData.argtypes = [wintypes.UINT, wintypes.HANDLE]
    u32.SetClipboardData.restype = wintypes.HANDLE
    data = str(text).encode('utf-16-le') + b'\x00\x00'
    h = k32.GlobalAlloc(GMEM_MOVEABLE, len(data))
    if not h:
        return False, 'GlobalAlloc failed'
    ptr = k32.GlobalLock(h)
    if not ptr:
        k32.GlobalFree(h)
        return False, 'GlobalLock failed'
    ctypes.memmove(ptr, data, len(data))
    k32.GlobalUnlock(h)
    if not u32.OpenClipboard(0):
        k32.GlobalFree(h)
        return False, 'OpenClipboard failed'
    try:
        u32.EmptyClipboard()
        if not u32.SetClipboardData(CF_UNICODETEXT, h):
            k32.GlobalFree(h)
            return False, 'SetClipboardData failed'
        h = None  # 所有权已交给系统，不要释放
    finally:
        u32.CloseClipboard()
    return True, 'clipboard set'


def type_text(text):
    """听写：文字写入剪贴板后 Ctrl+V 上屏。返回 (detail, ok)。
    剪贴板常被其它程序短暂占用，写失败时重试几次（间隔递增）。"""
    import time
    ok, detail = False, ''
    for attempt in range(6):
        ok, detail = set_clipboard(text)
        if ok:
            break
        time.sleep(0.08 * (attempt + 1))  # 0.08/0.16/0.24... 秒
    if not ok:
        return 'clipboard error after retries: ' + detail, False
    # 给剪贴板一点时间稳定，再发 Ctrl+V
    time.sleep(0.05)
    _keybd(VK['ctrl'])
    _keybd(VK['v'])
    _keybd(VK['v'], up=True)
    _keybd(VK['ctrl'], up=True)
    return 'typed: ' + str(text)[:80], True


def run_cmd(cmd):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=12,
                           creationflags=0x08000000 if os.name == 'nt' else 0)
        return r.returncode == 0, (r.stdout.strip() or r.stderr.strip())[:120]
    except Exception as exc:
        return False, str(exc)


def open_app(target):
    """不阻塞地启动程序（notepad/calc 等前台程序会阻塞 run_cmd，故用 Popen）。
    shell 包装的 cmd 窗口隐藏（CREATE_NO_WINDOW），被启动的 GUI 程序自带窗口不受影响。"""
    try:
        subprocess.Popen(target, shell=True,
                         creationflags=0x08000000 if os.name == 'nt' else 0)
        return 'opened ' + target, True
    except Exception as exc:
        return 'open failed: ' + str(exc), False


def monitor_off():
    """关闭显示器（不锁屏）：广播 SC_MONITORPOWER=2。
    用 SendMessageTimeoutW 而不是 SendMessageW，防止个别窗口不响应把服务卡住。
    动鼠标/按键盘显示器即亮，Windows 可能要求登录密码（取决于系统锁屏策略）。"""
    import ctypes
    HWND_BROADCAST = 0xFFFF
    WM_SYSCOMMAND = 0x0112
    SC_MONITORPOWER = 0xF170
    SMTO_NORMAL = 0x0002
    u32 = ctypes.windll.user32
    result = ctypes.c_ulong()
    u32.SendMessageTimeoutW(HWND_BROADCAST, WM_SYSCOMMAND, SC_MONITORPOWER, 2,
                            SMTO_NORMAL, 1500, ctypes.byref(result))
    return True, 'monitor off broadcast sent'


# ---------- 应用启动器：扫描开始菜单快捷方式 ----------
# 不翻注册表"已安装程序"（那是卸载器列表，几百条还乱），
# 而是扫开始菜单的 .lnk（与 LapDeck / Unified Remote 等项目同一思路）。
# 启动直接 os.startfile(.lnk)，无需解析快捷方式目标，最稳。
APPS_CACHE = BASE_DIR / 'apps_cache.json'
APPS = []                       # [{"name": "腾讯视频", "path": "C:\\...\\xx.lnk"}]
APPS_LOCK = threading.Lock()

# 名字带这些词的快捷方式大概率不是要启动的应用（卸载器/帮助/更新器等）
APP_EXCLUDE_PAT = re.compile(
    r'卸载|uninstall|帮助|help|readme|license|许可|协议|配置向导|设置向导|config|'
    r'检查更新|更新|update|升级|修复|repair|版本说明|changelog|文档|documentation|'
    r'反馈|feedback|官方网站|website|打开主页|调试|debug|eula|隐私|privacy|terms|'
    r'回收站|命令提示符|command prompt|运行对话框')

# 开始菜单里"启动"文件夹是开机自启项，不算应用
APP_SKIP_DIRS = {'startup', '启动'}


def load_apps_cache():
    """启动时先读缓存，秒开；后台线程再重新扫描刷新。"""
    global APPS
    try:
        if APPS_CACHE.exists():
            data = json.loads(APPS_CACHE.read_text(encoding='utf-8'))
            if isinstance(data, list):
                with APPS_LOCK:
                    APPS = data
                print('[apps] cache loaded: %d apps' % len(APPS))
    except Exception as exc:
        print('[warn] apps cache read failed:', exc)


def _scan_uwp_apps():
    """用 Get-StartApps 拿 UWP/商店应用（记事本、计算器、设置等没有 .lnk）。
    返回 [{"name":..., "path":"shell:appsFolder\\<AUMID>"}]；失败返回空表。"""
    try:
        # PowerShell 5.1 控制台输出是 GBK（cp936），必须显式指定，否则中文应用名乱码
        r = subprocess.run(
            ['powershell', '-NoProfile', '-Command',
             'Get-StartApps | ConvertTo-Json -Compress'],
            capture_output=True, text=True, timeout=30,
            encoding='gbk', errors='replace',
            creationflags=0x08000000 if os.name == 'nt' else 0)
        obj = json.loads(r.stdout) if (r.stdout or '').strip() else []
        if isinstance(obj, dict):       # 只有一条时 PowerShell 返回对象
            obj = [obj]
    except Exception as exc:
        print('[warn] Get-StartApps failed:', exc)
        return []
    out = []
    for it in obj:
        name = str(it.get('Name', '')).strip()
        appid = str(it.get('AppID', '')).strip()
        if not name or not appid:
            continue
        # UWP 的 AppID 形如 Microsoft.WindowsNotepad_8wekyb3d8bbwe!AppX（含 !）；
        # 桌面程序是 exe 路径或 GUID（已有 .lnk 扫描覆盖，跳过避免重复/垃圾项）
        if '!' not in appid or appid.startswith('{'):
            continue
        if APP_EXCLUDE_PAT.search(name.lower()):
            continue
        out.append({'name': name, 'path': 'shell:appsFolder\\' + appid})
    return out


def scan_apps():
    """扫描开始菜单 .lnk + Get-StartApps UWP 应用，去重后写缓存。"""
    global APPS
    menu_dirs = []
    programdata = os.environ.get('PROGRAMDATA', r'C:\ProgramData')
    appdata = os.environ.get('APPDATA', '')
    for base in (Path(programdata) / 'Microsoft' / 'Windows' / 'Start Menu' / 'Programs',
                 Path(appdata) / 'Microsoft' / 'Windows' / 'Start Menu' / 'Programs'):
        try:
            if base.is_dir():
                menu_dirs.append(base)
        except Exception:
            continue
    found = {}
    for menu in menu_dirs:
        try:
            lnks = list(menu.rglob('*.lnk'))
        except Exception:
            continue
        for p in lnks:
            # 跳过"启动"自启目录
            try:
                if any(part.lower() in APP_SKIP_DIRS for part in p.parts):
                    continue
            except Exception:
                continue
            name = p.stem.strip()
            if not name or APP_EXCLUDE_PAT.search(name.lower()):
                continue
            key = name.lower()
            if key not in found:            # 同名先到先得（所有用户菜单优先扫）
                found[key] = {'name': name, 'path': str(p)}
    apps = sorted(found.values(), key=lambda a: a['name'].lower())
    # 合并 UWP 应用（.lnk 里没有的才加，.lnk 优先）
    with APPS_LOCK:
        existing = {a['name'].lower() for a in apps}
        for u in _scan_uwp_apps():
            if u['name'].lower() not in existing:
                apps.append(u)
                existing.add(u['name'].lower())
        apps.sort(key=lambda a: a['name'].lower())
        APPS = apps
    try:
        APPS_CACHE.write_text(json.dumps(apps, ensure_ascii=False), encoding='utf-8')
    except Exception as exc:
        print('[warn] apps cache write failed:', exc)
    print('[apps] scanned: %d apps' % len(apps))
    return len(apps)


def find_app(name):
    """按名字找应用：精确 > 前缀 > 包含 > 拼音同音 > 拼音近似（容错 ASR 错字）。"""
    q = str(name).strip().lower()
    q = re.sub(r'\s+', '', q)
    if not q:
        return None
    with APPS_LOCK:
        apps = list(APPS)
    for a in apps:
        if re.sub(r'\s+', '', a['name'].lower()) == q:
            return a
    for a in apps:
        if re.sub(r'\s+', '', a['name'].lower()).startswith(q):
            return a
    contains = [a for a in apps if q in re.sub(r'\s+', '', a['name'].lower())]
    if contains:
        return min(contains, key=lambda a: len(a['name']))

    # ---- 拼音容错：威信 -> 微信 / 记事簿 -> 记事本 / 网易云乐 -> 网易云音乐 ----
    if not HAS_PINYIN or len(q) < 2:
        return None
    qp = _py(q)
    same_py = [a for a in apps if _py(re.sub(r'\s+', '', a['name']).lower()) == qp]
    if same_py:
        best = min(same_py, key=lambda a: len(a['name']))
        print('[app] pinyin equal: %s -> %s' % (name, best['name']))
        return best
    best_app = None
    best_score = 0.0
    for a in apps:
        cand = re.sub(r'\s+', '', a['name']).lower()
        pc = _py(cand)
        if not pc:
            continue
        score = 1.0 - float(_lev(qp, pc)) / max(len(qp), len(pc))
        if score > best_score:
            best_app, best_score = a, score
    # 阈值：长度越长容忍度越高（3 字名允许错 1 字左右）
    need = 0.80 if len(q) <= 3 else 0.72
    if best_app is not None and best_score >= need:
        print('[app] pinyin fuzzy %.2f: %s -> %s' % (best_score, name, best_app['name']))
        return best_app
    return None


def launch_app(name):
    """启动应用或直接打开文件（os.startfile 后台线程执行，避免阻塞 HTTP 响应）。
    name 优先按已收录应用匹配；若写的是完整文件路径（含 \\ 或 /）且文件存在，则直接用系统默认程序打开。"""
    name = str(name).strip()
    if ('\\' in name or '/' in name):
        p = os.path.expandvars(name)
        if os.path.isfile(p):
            if DRY:
                return 'WOULD OPEN FILE %s' % p, True
            try:
                threading.Thread(target=os.startfile, args=(p,), daemon=True).start()
                return 'opened file ' + os.path.basename(p), True
            except Exception as exc:
                return 'open failed: ' + str(exc), False
        return 'file not found: %s' % name, False
    a = find_app(name)
    if a is None:
        return 'app not found: %s (已收录 %d 个应用，可让手机端刷新列表)' % (name, len(APPS)), False
    if DRY:
        return 'WOULD LAUNCH %s (%s)' % (a['name'], a['path']), True
    try:
        threading.Thread(target=os.startfile, args=(a['path'],), daemon=True).start()
        return 'launched ' + a['name'], True
    except Exception as exc:
        return 'launch failed: ' + str(exc), False


# ---------- 语音智能动作：搜索 / 建文件夹 / 视频站 ----------
def _arg(item, key, default=''):
    if isinstance(item, dict):
        return str(item.get(key, default)).strip()
    return default


def safe_filename(name):
    """清理文件名里的 Windows 非法字符，防止路径穿越。"""
    name = re.sub(r'[<>:"/\\|?*\x00-\x1F]', '', str(name)).strip()
    name = name.strip('. ')
    return name[:80]


def new_folder(name, path=''):
    """新建文件夹。给了 path 就建到指定位置，否则建在桌面。返回 (detail, ok)。"""
    name = safe_filename(name)
    if not name:
        return 'invalid folder name', False
    # 目标父目录：优先模型给的 path，否则桌面
    parent = None
    if path:
        raw = str(path).strip().strip('"')
        # 只接受盘符绝对路径，如 D:\  D:\工作  E:\资料
        m = re.match(r'^([A-Za-z]):\\?(.*)$', raw)
        if m:
            drive = m.group(1).upper() + ':\\'
            rest = m.group(2)
            parent = Path(drive) / rest if rest else Path(drive)
    if parent is None:
        parent = Path(os.path.expanduser('~')) / 'Desktop'
        if not parent.exists():
            parent = Path(os.path.expanduser('~')) / '桌面'
    if not parent.exists():
        return 'parent not found: ' + str(parent), False
    target = parent / name
    if target.exists():
        return 'folder already exists: ' + str(target), True
    try:
        target.mkdir(parents=True)
        return 'created folder: ' + str(target), True
    except Exception as exc:
        return 'mkdir failed: ' + str(exc), False


# 视频站搜索地址模板。site 由模型给出，但这里做白名单映射，绝不拼接任意 URL。
MEDIA_SITES = {
    'bilibili': ('B站', 'https://search.bilibili.com/all?keyword={q}'),
    'b站': ('B站', 'https://search.bilibili.com/all?keyword={q}'),
    'iqiyi': ('爱奇艺', 'https://so.iqiyi.com/so/q_{q}'),
    '爱奇艺': ('爱奇艺', 'https://so.iqiyi.com/so/q_{q}'),
    'tencent': ('腾讯视频', 'https://v.qq.com/x/search/?q={q}'),
    '腾讯': ('腾讯视频', 'https://v.qq.com/x/search/?q={q}'),
    'youku': ('优酷', 'https://so.youku.com/search_video/q_{q}'),
    '优酷': ('优酷', 'https://so.youku.com/search_video/q_{q}'),
    'mgtv': ('芒果TV', 'https://so.mgtv.com/so?k={q}'),
    '芒果': ('芒果TV', 'https://so.mgtv.com/so?k={q}'),
}


def open_web(url):
    """用系统默认浏览器打开网址。仅放行 http/https。返回 (detail, ok)。"""
    url = str(url).strip()
    if not url.lower().startswith(('http://', 'https://')):
        return 'blocked non-http url', False
    return open_app('start "" "%s"' % url.replace('"', ''))


def web_search(q):
    q = str(q).strip()
    if not q:
        return 'empty search query', False
    url = 'https://www.bing.com/search?q=' + urllib.parse.quote(q)
    detail, ok = open_web(url)
    return 'search "%s": %s' % (q, detail), ok


def play_media(q, site='bilibili'):
    q = str(q).strip()
    if not q:
        return 'empty media query', False
    label, template = MEDIA_SITES.get(str(site).strip().lower(), MEDIA_SITES['bilibili'])
    url = template.format(q=urllib.parse.quote(q))
    detail, ok = open_web(url)
    return '%s search "%s": %s' % (label, q, detail), ok


# ---------- 自动点播：agent-browser CDP 打开搜索页 -> 按元素 ref 点击 ----------
def auto_play_first(q, site='bilibili'):
    """自动点播：agent-browser DOM 级点击。失败如实报错（不再有云端视觉兜底）。"""
    detail, ok = ab_play(q, site)
    if not ok:
        print('[auto_play] agent-browser failed:', detail[:120])
    return detail, ok


# ---------- agent-browser：网页 DOM 级自动点播（CDP，按元素 ref 点，不猜坐标） ----------
def _ab(args, timeout=40):
    """执行一条 agent-browser 命令。返回 (输出文本, ok)。Windows 下须 shell=True 走 .cmd 垫片。"""
    import subprocess
    cmd = 'agent-browser ' + ' '.join(args)
    try:
        r = subprocess.run(cmd, capture_output=True, text=True,
                           encoding='utf-8', errors='replace',
                           timeout=timeout, shell=True,
                           creationflags=0x08000000 if os.name == 'nt' else 0)
        return ((r.stdout or '') + (r.stderr or '')).strip(), r.returncode == 0
    except Exception as exc:
        return '%s: %s' % (type(exc).__name__, str(exc)[:100]), False


def _pick_ref(snap, q):
    """从 snapshot -i 输出里挑最该点的 ref。优先级：立即观看 > 片名链接 > 选集 > 精确"播放"。"""
    lines = [l for l in snap.splitlines() if 'ref=' in l]

    def grab(l):
        return l.rsplit('ref=', 1)[1].split(']')[0].strip()

    # 1) "立即观看/立即播放"（官方剧集卡的直达按钮）
    for l in lines:
        if '立即观看' in l or '立即播放' in l:
            return grab(l)
    # 2) 文本含片名的链接（搜索结果第一条）
    for l in lines:
        if 'link' in l.lower() and q in l:
            return grab(l)
    # 3) 选集/第一集
    for l in lines:
        if '选集' in l or '第一集' in l or '第1集' in l:
            return grab(l)
    # 4) 精确叫"播放"的按钮（排除"最多播放"这类筛选排序项）
    for l in lines:
        if '播放' in l and not any(w in l for w in ('最多', '筛选', '排序', '弹幕', '收藏', '追')):
            return grab(l)
    return None


def ab_play(q, site='bilibili'):
    """agent-browser 链路：开搜索页 -> snapshot -> 按ref点 -> 读URL验证。"""
    label, template = MEDIA_SITES.get(str(site).strip().lower(), MEDIA_SITES['bilibili'])
    q = str(q).strip()
    if not q:
        return 'empty media query', False
    url = template.format(q=urllib.parse.quote(q))
    out, ok = _ab(['open', '--headed', url], timeout=45)
    if not ok:
        return 'agent-browser open failed: ' + out[:120], False
    time.sleep(4)
    snap, ok = _ab(['snapshot', '-i'], timeout=30)
    if not ok:
        return 'agent-browser snapshot failed: ' + out[:120], False
    ref = _pick_ref(snap, q)
    if not ref:
        return '%s 搜索页已打开，但没找到"立即观看/播放"类入口(refs=%d个)' % (label, snap.count('ref=')), False
    out, ok = _ab(['click', '@' + ref], timeout=30)
    if not ok:
        return '%s 点击 @%s 失败(被遮挡或已失效): %s' % (label, ref, out[:100]), False
    time.sleep(5)
    uout, _ = _ab(['get', 'url'], timeout=15)
    final = uout.splitlines()[-1].strip() if uout else ''
    # 验证：URL 离开了搜索页即视为已进入播放页（spm 来源参数可能含 search 字样，不能拿它判断）
    if final.startswith('http') and not final.startswith(url.split('?')[0]):
        return '%s 已自动进入播放页: %s' % (label, final[:80]), True
    return '%s 已点击结果，当前停在: %s' % (label, final[:80] or '未知页面'), False


# ---------- UIA：按控件名操作原生程序（读无障碍树，不猜坐标、不动鼠标） ----------
UIA_INTERACTIVE = (
    'ButtonControl', 'MenuItemControl', 'HyperlinkControl', 'ListItemControl',
    'TabItemControl', 'TreeItemControl', 'CheckBoxControl', 'ComboBoxControl',
    'RadioButtonControl', 'EditControl',
)

# 中文口语 -> 进程/窗口关键词（匹配 explorer.exe / notepad.exe 等）
APP_ALIAS = {
    '资源管理器': 'explorer', '文件管理器': 'explorer', '此电脑': 'explorer',
    '我的电脑': 'explorer', '回收站': 'explorer',
    '记事本': 'notepad', '浏览器': 'chrome', '谷歌浏览器': 'chrome',
    '微信': 'wechat', '腾讯': 'qq',
}


def _window_process_name(ctrl):
    """取窗口所属进程的可执行文件名（小写）。失败返回空串。"""
    try:
        import win32process
        import win32api
        hwnd = int(ctrl.NativeWindowHandle)
        _, pid = win32process.GetWindowThreadProcessId(hwnd)
        h = win32api.OpenProcess(0x1000, False, pid)  # QUERY_LIMITED_INFORMATION
        try:
            path = win32process.GetModuleFileNameEx(h, 0)
        finally:
            win32api.CloseHandle(h)
        return path.replace('\\', '/').rsplit('/', 1)[-1].lower()
    except Exception:
        return ''


# 任务栏/桌面也是 explorer.exe 托管的，按进程名匹配时必须排除
UIA_SKIP_CLASS = ('Shell_TrayWnd', 'Shell_SecondaryTrayWnd', 'Progman', 'WorkerW')


def uia_find_window(app=''):
    """按关键词找顶层窗口；app 为空取当前前台窗口。返回 (control, 描述)。"""
    import uiautomation as auto
    auto.SetGlobalSearchTimeout(2)
    root = auto.GetRootControl()
    if app:
        key = APP_ALIAS.get(str(app).strip(), str(app).strip().lower())
        for w in root.GetChildren():
            try:
                if (w.ClassName or '') in UIA_SKIP_CLASS:
                    continue
                blob = ((w.Name or '') + ' ' + (w.ClassName or '')).lower()
                proc = _window_process_name(w)
                if key in blob or (proc and key in proc):
                    return w, ((w.Name or proc or w.ClassName) or '?')[:30]
            except Exception:
                continue
        return None, 'no window matches "%s"' % app
    try:
        w = auto.GetFocusedControl().GetTopLevelControl()
        return w, ((w.Name or w.ClassName) or '前台窗口')[:30]
    except Exception:
        return None, 'no focused window'


def uia_click(name, app=''):
    """按控件名点击原生程序元素。Invoke 优先（headless），物理点击兜底。"""
    import uiautomation as auto
    name = str(name).strip()
    if not name:
        return 'empty control name', False
    w, wdesc = uia_find_window(app)
    if w is None:
        return wdesc, False

    key = name.lower()
    exact, fuzzy, sample = [], [], []
    try:
        for c, d in auto.WalkControl(w, includeTop=False, maxDepth=12):
            try:
                nm = (c.Name or '').strip()
                ct = c.ControlTypeName
                if not nm:
                    continue
                if ct not in UIA_INTERACTIVE:
                    continue
                nl = nm.lower()
                if nl == key:
                    exact.append((c, nm, ct))
                elif key in nl:
                    fuzzy.append((c, nm, ct))
                if len(sample) < 8 and ct != 'EditControl':
                    sample.append(nm[:14])
            except Exception:
                continue
    except Exception as exc:
        return 'walk failed: ' + str(exc)[:60], False

    hits = exact or fuzzy
    if not hits:
        return ('not found "%s" in %s；该窗口可点控件如: %s'
                % (name, wdesc, ', '.join(sample) or '无')), False

    c, nm, ct = hits[0]
    # Invoke：系统级调用，不动鼠标不抢焦点，最稳
    try:
        c.Invoke()
        return 'invoked %s "%s" in %s' % (ct.replace('Control', ''), nm[:20], wdesc), True
    except Exception:
        pass
    # 兜底：物理点击。先把窗口带到前台，避免点到遮挡在上面的其它窗口
    try:
        w.SetActive()
        time.sleep(0.3)
    except Exception:
        pass
    try:
        c.Click(simulateMove=False)
        return 'clicked %s "%s" in %s' % (ct.replace('Control', ''), nm[:20], wdesc), True
    except Exception as exc:
        return 'click failed on "%s": %s' % (nm[:20], str(exc)[:50]), False


BROWSER_PROCS = (
    'chrome', 'msedge', 'firefox', 'qqbrowser', '360se', '360chrome',
    'sogou_explorer', 'opera', 'brave', ' brow', 'iyf',
)


def _hwnd_process_name(hwnd):
    """取窗口所属进程名（小写，无扩展名）；失败返回空串。"""
    try:
        import win32process
        import win32api
        _, pid = win32process.GetWindowThreadProcessId(hwnd)
        h = win32api.OpenProcess(0x1000, False, pid)  # QUERY_LIMITED_INFORMATION
        try:
            path = win32process.GetModuleFileNameEx(h, 0)
        finally:
            win32api.CloseHandle(h)
        return os.path.basename(path).replace('.exe', '').lower()
    except Exception:
        return ''


def smart_back():
    """智能返回：按前台窗口上下文自动选键（纯本地判断，零延迟）。

    规则：
    - 对话框窗口（类名 #32770）        -> Esc 关掉弹窗
    - 浏览器全屏（窗口铺满主屏）        -> Esc 退出全屏
    - 浏览器普通浏览                    -> Alt+Left 网页后退
    - 资源管理器                        -> Alt+Left 上一级文件夹
    - 其他程序                          -> Esc（关弹层/取消，兜底）
    """
    import ctypes
    from ctypes import wintypes
    u = ctypes.windll.user32
    hwnd = u.GetForegroundWindow()
    if not hwnd:
        tap('esc')
        return 'smart back: no foreground window, sent Esc', True

    # 全屏检测
    fullscreen = False
    try:
        rect = wintypes.RECT()
        if u.GetWindowRect(hwnd, ctypes.byref(rect)):
            fullscreen = (rect.left <= 0 and rect.top <= 0 and
                          rect.right >= u.GetSystemMetrics(0) and
                          rect.bottom >= u.GetSystemMetrics(1))
    except Exception:
        pass

    # 窗口类名
    buf = ctypes.create_unicode_buffer(256)
    u.GetClassNameW(hwnd, buf, 256)
    cls = (buf.value or '').lower()

    proc = _hwnd_process_name(hwnd)

    if cls == '#32770':  # 系统对话框
        tap('esc')
        return 'smart back: dialog -> Esc', True
    if fullscreen:  # 任何程序全屏 -> 先退全屏
        tap('esc')
        return 'smart back: fullscreen -> Esc', True
    if proc in BROWSER_PROCS or 'browser' in proc:
        _combo('alt', 'left')
        return 'smart back: browser -> Alt+Left (后退)', True
    if cls == 'cabinetwclass' or proc == 'explorer':
        _combo('alt', 'left')
        return 'smart back: explorer -> Alt+Left (上一级)', True
    tap('esc')
    return 'smart back: %s -> Esc' % (proc or cls or 'unknown'), True


# ---------- Action 分发 ----------
def _res(call_result):
    """ns_call()/run_cmd() 返回 (ok, detail)，统一成 (detail, ok)。"""
    ok, detail = call_result
    return detail, bool(ok)


def _tap(name):
    """tap() 只返回描述串，包装成 (detail, ok)。"""
    return tap(name), True


def _combo(*names):
    return combo(*names), True


POWER_ACTIONS = ('power_shutdown', 'power_reboot', 'power_sleep')


def dispatch(action, item=None):
    """统一返回 (detail_string, ok)。item 是大模型给的参数对象（可选）。"""

    if action in POWER_ACTIONS and not SETTINGS.get('allow_power', True):
        return '已被设置禁止（管理界面 → 设置 → 允许关机/重启/睡眠）', False

    # 短按电源 = 关显示器（不锁屏，动鼠标即亮）；锁屏独立为 lock 动作
    if action == 'power':
        if DRY:
            return 'WOULD TURN OFF MONITOR (SC_MONITORPOWER)', True
        return _res(monitor_off())

    if action == 'lock':
        if NS_AVAILABLE:
            return _res(ns_call('/api/lock'))
        return _res(run_cmd('rundll32.exe user32.dll,LockWorkStation'))

    if action == 'power_sleep':
        if NS_AVAILABLE:
            return _res(ns_call('/api/sleep'))
        return _res(run_cmd('rundll32.exe powrprof.dll,SetSuspendState 0,1,0'))

    if action == 'wake':
        # 能收到这条请求说明电脑是开着的（真睡着时手机端会直接发 WOL 魔术包，走不到这里）
        return 'PC is already awake', True

    if action == 'power_shutdown':
        if NS_AVAILABLE:
            return _res(ns_call('/api/shutdown'))
        return _res(run_cmd('shutdown /s /t 10'))

    if action == 'power_reboot':
        if NS_AVAILABLE:
            return _res(ns_call('/api/reboot'))
        return _res(run_cmd('shutdown /r /t 10'))

    # 系统键
    if action == 'home':
        return _combo('win', 'd')
    if action == 'menu':
        return _combo('shift', 'f10')
    if action == 'ok':
        return _tap('enter')
    if action == 'back':
        return smart_back()
    if action == 'browser_back':
        _combo('alt', 'left')
        return 'browser back: Alt+Left (后退/上一级)', True

    # 方向键：NeoShell 无此 API，始终用 SendInput
    if action in ('dpad_up', 'dpad_down', 'dpad_left', 'dpad_right'):
        return _tap(action.split('_')[1])

    # 音量：NeoShell 的 set 需要绝对数值，相对调节用媒体键更直接
    if action == 'vol_up':
        return _tap('vol_up')
    if action == 'vol_down':
        return _tap('vol_down')
    if action == 'mute':
        if NS_AVAILABLE:
            return _res(ns_call('/api/volume/mute'))
        return _tap('mute')

    # 媒体：优先 NeoShell 的 SMTC 会话控制（比模拟媒体键稳）
    if action == 'play_pause':
        if NS_AVAILABLE:
            return _res(ns_call('/api/media/playpause'))
        return _tap('playpause')

    if action in ('prev_track', 'next_track'):
        path = '/api/media/prev' if action == 'prev_track' else '/api/media/next'
        if NS_AVAILABLE:
            return _res(ns_call(path))
        return _tap('prev' if action == 'prev_track' else 'next')

    # 快退/快进：Windows 无系统级快捷键，用 Ctrl+← / Ctrl+→，
    # 多数播放器（PotPlayer、爱奇艺、B站等）通用；个别客户端需用其自有快捷键。
    if action == 'rewind':
        return _combo('ctrl', 'left')
    if action == 'forward':
        return _combo('ctrl', 'right')

    # TV 键 / 启动应用：打开 NeoShellApps 文件夹让用户选
    if action == 'tv':
        if NS_AVAILABLE:
            return _res(ns_call('/api/open_apps_folder'))
        apps = BASE_DIR / 'NeoShellApps'
        apps.mkdir(exist_ok=True)
        return _res(run_cmd('explorer "%s"' % apps))

    # 鼠标左右键 / 双击：直接注入系统鼠标事件（与光标当前位置无关）
    if action == 'mouse_left':
        return mouse_click('left')
    if action == 'mouse_right':
        return mouse_click('right')
    if action == 'mouse_double':
        return mouse_click('double')
    # 拖拽：按下不动 → 移动 → 抬起（触控板"按住拖动"用）
    if action == 'mouse_down':
        return ('WOULD MOUSE LEFT DOWN', True) if DRY else mouse_button(True, 'left')
    if action == 'mouse_up':
        return ('WOULD MOUSE LEFT UP', True) if DRY else mouse_button(False, 'left')

    # 系统级快捷键：Alt+Tab 切换窗口 / Alt+F4 关闭窗口 / Ctrl+V 粘贴
    if action == 'alt_tab':
        return _combo('alt', 'tab')
    if action == 'alt_f4':
        return _combo('alt', 'f4')
    if action == 'ctrl_v':
        return _combo('ctrl', 'v')

    if action == 'keys':
        # 自定义指令 / 大模型用的通用组合键：{"keys": ["ctrl", "s"]}
        names = [str(k).lower() for k in ((item or {}).get('keys') or [])] \
            if isinstance(item, dict) else []
        bad = [n for n in names if n not in VK]
        if not names or bad:
            return 'bad keys: %s' % (bad or names), False
        if DRY:
            return 'WOULD COMBO ' + '+'.join(names), True
        return combo(*names), True

    if action == 'taskmgr':
        return _res(run_cmd('taskmgr.exe'))

    # 应用启动器：按名字启动开始菜单里的任意程序（手机宫格点选 / 语音"打开XX"）
    if action == 'launch_app':
        return launch_app(_arg(item, 'name'))

    # 语音：打开常用应用
    if action == 'open_pc':
        return open_app('explorer.exe')
    if action == 'open_explorer':
        return open_app('explorer.exe')
    if action == 'open_browser':
        return open_app('start msedge')
    if action == 'open_notepad':
        return open_app('start notepad')
    if action == 'open_calc':
        return open_app('start calc')
    if action == 'open_settings':
        return open_app('start ms-settings:')

    # 语音智能动作：搜索 / 建文件夹 / 视频站 / 开网址
    if action == 'new_folder':
        name = safe_filename(_arg(item, 'name'))
        path = _arg(item, 'path')
        if DRY:
            return 'WOULD CREATE FOLDER %s in %s' % (name or '<empty>', path or 'desktop'), True
        return new_folder(name, path)
    if action == 'web_search':
        return web_search(_arg(item, 'q'))
    if action == 'play_media':
        return play_media(_arg(item, 'q'), _arg(item, 'site', 'bilibili'))
    if action == 'auto_play' and not DRY:
        return auto_play_first(_arg(item, 'q'), _arg(item, 'site', 'bilibili'))
    if action == 'auto_play' and DRY:
        return 'WOULD auto_play %s @%s' % (_arg(item, 'q'), _arg(item, 'site', 'bilibili')), True
    if action == 'open_url':
        return open_web(_arg(item, 'url'))
    if action == 'uia_click':
        if DRY:
            return 'WOULD uia_click "%s" in %s' % (
                _arg(item, 'name'), _arg(item, 'app') or '前台窗口'), True
        return uia_click(_arg(item, 'name'), _arg(item, 'app'))

    if action == 'voice':
        return 'voice key (recognition done on phone)', True

    return 'unknown action: ' + action, False


def preview_dispatch(action, item=None):
    """dry-run 用：临时把执行函数换成描述器，走同一套映射但不真的执行。"""
    global ns_call, run_cmd, tap, combo, mouse_click, open_app, mouse_button
    original = (ns_call, run_cmd, tap, combo, mouse_click, open_app, mouse_button)

    def p_ns(path, params=None, payload=None):
        return 'WOULD CALL NeoShell ' + path, True

    def p_cmd(cmd):
        return 'WOULD RUN ' + cmd, True

    def p_tap(name):
        # 与真实 tap() 一致：返回描述串，由 _tap 包装成二元组
        return 'WOULD SEND KEY ' + name

    def p_combo(*names):
        # 与真实 combo() 一致：返回描述串，由 _combo 包装成二元组
        return 'WOULD SEND COMBO ' + '+'.join(names)

    def p_mouse(button):
        return 'WOULD MOUSE CLICK ' + button, True

    def p_open(target):
        return 'WOULD OPEN ' + target, True

    def p_button(down, button='left'):
        return 'WOULD MOUSE %s %s' % (button, 'DOWN' if down else 'UP'), True

    ns_call, run_cmd, tap, combo, mouse_click, open_app, mouse_button = (
        p_ns, p_cmd, p_tap, p_combo, p_mouse, p_open, p_button)
    try:
        return dispatch(action, item)
    finally:
        ns_call, run_cmd, tap, combo, mouse_click, open_app, mouse_button = original


# ---------- WebSocket ----------
# 复用同一个 8765 端口：普通 HTTP 请求走浏览器页面/配对页，带 Upgrade: websocket
# 的请求升级成长连接。手机端所有实时控制指令都走这条长连接，不再每帧建连。
WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'
WS_STATS = {'conn': 0, 'msg': 0, 'open': 0}
WS_LOCK = threading.Lock()

# token -> Handler 集合：撤销设备/重置配对时主动踢下线用（否则旧连接挂着，
# 手机界面还显示"已连接"，按什么都没反应，用户只会觉得"坏了"）
_WS_LIVE = {}
_WS_LIVE_LOCK = threading.Lock()


def _ws_register(token, handler):
    if token:
        with _WS_LIVE_LOCK:
            _WS_LIVE.setdefault(token, set()).add(handler)


def _ws_unregister(token, handler):
    if not token:
        return
    with _WS_LIVE_LOCK:
        conns = _WS_LIVE.get(token)
        if conns is not None:
            conns.discard(handler)
            if not conns:
                _WS_LIVE.pop(token, None)


def kick_token(token):
    """立即断开某令牌名下的全部 WS 连接。"""
    with _WS_LIVE_LOCK:
        conns = _WS_LIVE.pop(token or '', None) or set()
    for h in conns:
        try:
            h.connection.shutdown(socket.SHUT_RDWR)
        except Exception:
            pass
        try:
            h.connection.close()
        except Exception:
            pass


def ws_accept_key(client_key):
    """按 RFC6455 算握手应答：base64(sha1(key + GUID))。"""
    return base64.b64encode(hashlib.sha1((client_key + WS_GUID).encode('ascii')).digest()).decode('ascii')


def ws_send_frame(wfile, payload, opcode=0x1):
    """服务端发帧：FIN=1、不加掩码（RFC 规定服务端不得掩码）。"""
    if isinstance(payload, str):
        payload = payload.encode('utf-8')
    n = len(payload)
    hdr = bytearray([0x80 | opcode])
    if n < 126:
        hdr.append(n)
    elif n < 65536:
        hdr.append(126)
        hdr += struct.pack('>H', n)
    else:
        hdr.append(127)
        hdr += struct.pack('>Q', n)
    with WS_LOCK:
        wfile.write(bytes(hdr) + payload)
        wfile.flush()


class _WsReader(object):
    """WS 帧读取缓冲：直接读裸 socket，不用 socket.makefile 的文件对象。

    原因：makefile() 返回的 BufferedReader 在 settimeout 下超时后状态不可靠，
    下一次 read 可能直接返回 b''（看起来像对端关闭），把长连接无声掐断。
    自己缓冲的另一个好处是超时时已收到的字节不会丢，下一轮接着攒。"""

    def __init__(self, sock):
        self.sock = sock
        self.buf = bytearray()

    def read(self, n):
        buf = self.buf
        while len(buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                return b''            # 对端关闭
            buf += chunk
        out = bytes(buf[:n])
        del buf[:n]
        return out


def ws_read_frame(rfile):
    """读一帧，返回 (fin, opcode, payload)；连接结束返回 (False, None, b'')。"""
    head = rfile.read(2)
    if len(head) < 2:
        return False, None, b''
    b1, b2 = head[0], head[1]
    fin = bool(b1 & 0x80)
    opcode = b1 & 0x0F
    masked = bool(b2 & 0x80)
    length = b2 & 0x7F
    if length == 126:
        ext = rfile.read(2)
        if len(ext) < 2:
            return False, None, b''
        length = struct.unpack('>H', ext)[0]
    elif length == 127:
        ext = rfile.read(8)
        if len(ext) < 8:
            return False, None, b''
        length = struct.unpack('>Q', ext)[0]
    # 单条指令远小于 1MB，超过就视为异常，直接断开避免被撑爆内存
    if length > 1048576:
        return False, None, b''
    mask = rfile.read(4) if masked else b''
    data = rfile.read(length) if length else b''
    if len(data) < length:
        return False, None, b''
    if masked and len(mask) == 4:
        data = bytes(b ^ mask[i & 3] for i, b in enumerate(data))
    return fin, opcode, data


class _WsCtx(object):
    """把一条 WS 消息伪装成一次 HTTP POST，好直接复用 Handler.do_POST 的全部逻辑。

    这样按键/键盘/语音/移动/滚轮的行为在两条通道上完全一致，
    不会出现"WS 支持了但某个分支没跟上"的问题。

    注意：payload 已经是解析好的 dict，通过 prepared 直接交给 do_POST，
    不再序列化成 body 让它反解一遍 —— /move 每秒几十帧，那两步是白烧的。"""

    def __init__(self, path, payload, client_ip, token=''):
        self.path = path
        self.headers = _WsHeaders(token)
        self.rfile = io.BytesIO(b'')
        self.client_address = (client_ip, 0)
        self.result = None
        self.prepared = (path, payload)

    def reply_json(self, code, obj):
        self.result = (code, obj)

    # 仅 404/异常分支可能被调到，WS 下不需要真写 socket
    def send_response(self, *a, **kw):
        pass

    def send_header(self, *a, **kw):
        pass

    def end_headers(self):
        pass


class _WsHeaders(object):
    """最小 headers 容器：do_POST 只用到 get()。"""

    def __init__(self, token=''):
        self._d = {}
        if token:
            self._d['X-PC-Token'] = token

    def get(self, key, default=None):
        return self._d.get(key, default)


# ---------- HTTP ----------
POST_PATHS = ('/key', '/keys', '/move', '/text', '/scroll', '/pair/register', '/announce')


class Handler(BaseHTTPRequestHandler):
    # HTTP/1.1 + 长连接：手机上 http.createHttp 自带连接池，会复用同一条 TCP。
    # 原默认是 HTTP/1.0，服务端每个响应后主动关连接 —— 触控盘 30Hz 的 /move
    # 就变成每秒 30 次三次握手 + 30 次线程创建销毁，延迟抖动全从这里来。
    protocol_version = 'HTTP/1.1'
    # 空闲长连接最多挂 120 秒，避免手机异常掉线后线程永久滞留
    timeout = 120

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'POST, GET, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.end_headers()

    def do_POST(self):
        # WebSocket 通道已经把 path 和 payload 解析好了（_WsCtx.prepared），
        # 直接拿来用，省掉一次 urlparse 和一次 json.loads —— /move 每秒几十帧，
        # 这部分纯属重复劳动。
        prepared = getattr(self, 'prepared', None)
        if prepared is not None:
            path, payload = prepared
        else:
            path = urllib.parse.urlparse(self.path).path
            if path not in POST_PATHS:
                # HTTP/1.1 必须显式声明长度，否则客户端会一直等 body 导致连接卡死
                self.send_response(404)
                self.send_header('Content-Length', '0')
                self.end_headers()
                return
            try:
                length = int(self.headers.get('Content-Length', '0') or '0')
                payload = json.loads(self.rfile.read(length).decode('utf-8', 'replace'))
            except Exception:
                payload = {}

        # 扫码后换设备令牌：这一步之前还没有 token，所以放在鉴权前面
        if path == '/pair/register':
            tk, err = register_device(payload.get('ticket'), payload.get('name'),
                                      payload.get('model'),
                                      (self.client_address[0] if self.client_address else ''))
            if not tk:
                self.reply_json(400, {'ok': False, 'msg': err})
                return
            self.reply_json(200, {'ok': True, 'token': tk,
                                  'name': payload.get('name') or '', 'msg': '配对成功'})
            return

        # 手机连上后报一次本机信息：配对设备刷新档案，未配对的进临时名单
        if path == '/announce':
            model = str(payload.get('model') or '')[:40]
            os_name = str(payload.get('os') or '')[:40]
            res = str(payload.get('res') or '')[:20]
            ip = self.client_address[0] if self.client_address else ''
            ok_auth, dev_id = auth_request(self, payload)
            if dev_id not in ('', 'open', 'local'):
                with _DEV_LOCK:
                    for d in DEVICES.get('devices') or []:
                        if d.get('id') == dev_id:
                            if model:
                                d['model'] = model
                            if os_name:
                                d['os'] = os_name
                            if res:
                                d['res'] = res
                            if ip:
                                d['ip'] = ip
                            break
                save_devices()
            elif model and ip and ip not in ('127.0.0.1', '::1'):
                with _OPEN_SEEN_LOCK:
                    seen = OPEN_SEEN.get(ip) or {}
                    seen.update({'model': model, 'os': os_name, 'res': res,
                                 'last_ts': time.time()})
                    OPEN_SEEN[ip] = seen
            self.reply_json(200, {'ok': True})
            return

        # 配对令牌校验：局域网来的请求必须带 X-PC-Token（本机回环放行）
        ok_auth, _dev_id = auth_request(self, payload)
        if not ok_auth:
            self.reply_json(401, {'ok': False, 'need_pair': True,
                                  'msg': '未配对或已被移出设备列表，请重新扫码配对'})
            return

        say = ''
        voice_text = ''
        voice_steps = ''
        t0 = time.time()
        if path == '/text':
            # 语音识别结果：本地规则理解（分句+参数提取+关键词表，离线、毫秒级），
            # 没懂的部分原样打字上屏兜底。
            text = str(payload.get('text', '')).strip()
            voice_text = text
            # 1) 自定义指令优先：管理界面配置的短语/别名 → 多步动作序列
            cust, cust_kw = custom_match(text)
            if cust:
                understood = (custom_steps(cust), cust.get('say') or '好的')
            else:
                understood = local_understand(text)
            # 2) LLM 兜底：本地完全没当成指令（解析结果只剩打字上屏）时问大模型。
            #    「打字/输入」开头的口述不送 LLM，避免抢了用户本来就想打字的情况。
            if (understood and not cust
                    and all(a == 'type' for a, _ in understood[0])
                    and SETTINGS.get('llm_fallback')
                    and not re.match(r'^(?:帮我)?(?:打字|输入|打上|写上)', _norm_text(text))):
                llm = llm_understand(text)
                if llm:
                    understood = llm
                    cust_kw = ''   # 走 LLM 时 action 标成 llm
                    cust = {'__llm': True}
            if understood:
                steps, say = understood
                if cust:
                    action = 'llm' if cust.get('__llm') else 'custom'
                else:
                    action = 'local'
                details = []
                ok_count = 0
                fail_count = 0
                launch_actual = ''
                if not steps:
                    detail, ok = 'local: no action (闲聊/无法理解)', True
                for idx, (act, arg) in enumerate(steps):
                    # 多步动作之间留间隔，避免按键/剪贴板抢占（尤其连续打字）
                    if idx > 0:
                        time.sleep(0.15)
                    try:
                        if act == 'type':
                            txt = _arg(arg, 'text')
                            d, o = ('WOULD TYPE ' + txt[:80], True) if DRY else type_text(txt)
                        elif act == 'delay':
                            try:
                                ms = min(max(int(float(str(arg.get('ms') or 0))), 100), 60000)
                            except (TypeError, ValueError):
                                ms = 1000
                            if DRY:
                                d, o = ('WOULD DELAY %dms' % ms, True)
                            else:
                                time.sleep(ms / 1000.0)
                                d, o = ('delayed %dms' % ms, True)
                        elif act == 'none':
                            d, o = 'no-op', True
                        else:
                            d, o = preview_dispatch(act, arg) if DRY else dispatch(act, arg)
                        details.append(d)
                        if act == 'launch_app' and o:
                            # 同音容错命中时，回话里用真实程序名（用户能看出被纠正了）
                            mt = re.search(r'(?:launched|WOULD LAUNCH)\s+(.+?)(?:\s+\(|$)', d)
                            if mt:
                                launch_actual = mt.group(1).strip()
                        if o:
                            ok_count += 1
                        else:
                            fail_count += 1
                    except Exception as exc:
                        details.append('%s error: %s' % (act, exc))
                        fail_count += 1
                detail = 'local [%s] -> %s' % (','.join(a for a, _ in steps) or 'none', '; '.join(details))
                voice_steps = ' → '.join(a for a, _ in steps) or '无动作'
                # 只要有一步成功就算成功，避免个别步骤失败让整条看起来"没执行"
                ok = ok_count > 0 or fail_count == 0
                # 部分失败时在 say 里如实标注，机身反馈更可信
                if fail_count > 0 and ok_count > 0:
                    say = (say + '（部分步骤未成功）')[:60]
                # 程序名被同音纠正时，回话用真实名字
                if launch_actual and launch_actual not in say:
                    say = ('正在打开' + launch_actual)[:60]
            else:
                # 降级：本地关键词表
                cmd_action, keyword = command_from_text(text)
                if cmd_action:
                    action = cmd_action
                    voice_steps = '关键词:' + keyword
                    try:
                        detail, ok = preview_dispatch(action) if DRY else dispatch(action)
                        detail = 'voice cmd [%s] -> %s' % (keyword, detail)
                    except Exception as exc:
                        detail, ok = 'dispatch error: %s' % exc, False
                elif text:
                    action = 'type'
                    voice_steps = '整句打字（未识别为指令）'
                    if DRY:
                        detail, ok = 'WOULD TYPE ' + text[:80], True
                    else:
                        detail, ok = type_text(text)
                    say = '已输入：' + text[:30]
                else:
                    action, detail, ok = 'text', 'empty text', False

        elif path == '/keys':
            # 键盘页：三合一入口
            #   {"type":"text","text":"..."}        整段打字（走剪贴板+Ctrl+V，中文/长文本都稳）
            #   {"type":"key","key":"enter"}        单个功能键（Enter/Esc/Tab/方向键/F5…）
            #   {"type":"combo","keys":["ctrl","c"]} 组合键（Ctrl+C、Win+D、Alt+Tab…）
            kind = str(payload.get('type', 'text'))
            if kind == 'text':
                txt = str(payload.get('text', ''))
                action = 'kbd_type'
                if not txt:
                    detail, ok = 'empty text', False
                elif DRY:
                    detail, ok = 'WOULD TYPE ' + txt[:80], True
                else:
                    detail, ok = type_text(txt)
            elif kind == 'combo':
                action = 'kbd_combo'
                # 只允许码表内的键名，避免任意字符串导致 KeyError
                names = [str(k).lower() for k in (payload.get('keys') or [])]
                bad = [n for n in names if n not in VK]
                if not names or bad:
                    detail, ok = 'bad combo keys: %s' % (bad or names), False
                elif DRY:
                    detail, ok = 'WOULD COMBO ' + '+'.join(names), True
                else:
                    detail, ok = combo(*names), True
            else:
                action = 'kbd_key'
                name = str(payload.get('key', '')).lower()
                if name not in VK:
                    detail, ok = 'unknown key: %s' % name, False
                elif DRY:
                    detail, ok = 'WOULD TAP ' + name, True
                else:
                    detail, ok = tap(name), True

        elif path == '/move':
            # 触控盘相对位移：鼠标指针移动（高频，默认只记最近一条不刷屏）
            try:
                dx = float(payload.get('dx', 0))
                dy = float(payload.get('dy', 0))
            except Exception:
                dx, dy = 0.0, 0.0
            # 限幅，防止异常大值
            dx = max(-200, min(200, dx))
            dy = max(-200, min(200, dy))
            if DRY:
                detail, ok = 'WOULD MOVE mouse %+d,%+d' % (dx, dy), True
            else:
                detail, ok = mouse_move(dx, dy)
            action = 'move'
        elif path == '/scroll':
            # 双指滚动：dy>0 下滚、dy<0 上滚（学 LocalTV，按 120 一格累积）
            try:
                dy = float(payload.get('dy', payload.get('delta', 0)))
            except Exception:
                dy = 0.0
            dy = max(-1200, min(1200, dy))
            if DRY:
                detail, ok = 'WOULD SCROLL %+d' % dy, True
            else:
                detail, ok = mouse_scroll(int(dy))
            action = 'scroll'
        else:
            action = str(payload.get('action', ''))
            try:
                # 把整个 payload 作为 item 传入，支持带参数的动作（如 launch_app 的 name）
                detail, ok = preview_dispatch(action, payload) if DRY else dispatch(action, payload)
            except Exception as exc:
                detail, ok = 'dispatch error: %s' % exc, False

        # /move /scroll 是 80+ Hz 的连续事件。它们既不该进记录页（25 条记录
        # 一秒内就会被位移冲光，按键记录全丢），也不该每帧做时间格式化。
        hot = path in ('/move', '/scroll')
        now = datetime.now()
        if not hot:
            stamp = now.strftime('%H:%M:%S')
            line = '%s  %-18s %s  %s' % (stamp, action, 'OK' if ok else 'FAIL', detail)
            with LOCK:
                RECORDS.append(line)
                if len(RECORDS) > 200:
                    del RECORDS[0]
            print(line, flush=True)
        # 托盘/管理页要显示"最后活动时间"：每秒最多刷新一次就够
        now_ts = now.timestamp()
        if not hot or now_ts - _LAST_SEEN_TS[0] >= 1.0:
            _LAST_SEEN_TS[0] = now_ts
            STATS['last_seen'] = now.strftime('%H:%M:%S')

        # ---- 结构化记录（管理界面用）----
        if path == '/text':
            STATS['voice'] += 1
            if not ok:
                STATS['voice_miss'] += 1
            if not SETTINGS.get('voice_reply', True):
                say = ''          # 设置里关掉回话：手机端不显示也不播报
            _push_log(VOICE_LOG, {
                't': STATS['last_seen'], 'text': voice_text,
                'steps': voice_steps or '—', 'say': say, 'ok': bool(ok),
                'detail': str(detail)[:400],
                'ms': int((time.time() - t0) * 1000),
            })
        elif path in ('/key', '/keys'):
            STATS['key'] += 1
            if not ok:
                STATS['key_fail'] += 1
            _push_log(KEY_LOG, {
                't': STATS['last_seen'], 'action': action,
                'ok': bool(ok), 'detail': str(detail)[:200],
            })
        else:
            # 位移/滚轮单独计数，不再混进「按键」里把统计搅浑
            STATS['move'] += 1

        resp_obj = {'ok': ok, 'action': action, 'detail': detail}
        if say:
            resp_obj['say'] = say
        self.reply_json(200 if ok else 500, resp_obj)

    def _serve_ws(self):
        """升级成 WebSocket 长连接，之后所有指令都在这一条 TCP 上收发。"""
        key = self.headers.get('Sec-WebSocket-Key', '')
        if not key:
            self.reply_json(400, {'ok': False, 'msg': 'missing Sec-WebSocket-Key'})
            return
        # 配对令牌优先从 URL 查询串取（手机端这样传），其次才看请求头
        qs = urllib.parse.urlparse(self.path).query
        token = (urllib.parse.parse_qs(qs).get('token') or [''])[0]
        if not token:
            token = self.headers.get('X-PC-Token', '') or ''
        ip = self.client_address[0] if self.client_address else ''
        # 有令牌按令牌登记（踢下线用）；没令牌（开放模式）按 IP 登记，
        # 让控制台「手机」卡把连着但没配对的手机也算成在线
        _ws_register(token if token else 'open:' + ip, self)
        self.send_response(101, 'Switching Protocols')
        self.send_header('Upgrade', 'websocket')
        self.send_header('Connection', 'Upgrade')
        self.send_header('Sec-WebSocket-Accept', ws_accept_key(key))
        self.end_headers()
        self.wfile.flush()
        # 已升级，别再让基类按 HTTP 语义读下一个请求
        self.close_connection = True
        with WS_LOCK:
            WS_STATS['conn'] += 1
            WS_STATS['open'] += 1
        print('[ws] open from %s' % ip, flush=True)
        # 25 秒收不到任何帧就发个 ping 探活；连续 6 次都没回音（150 秒）才断开。
        # 阈值给得宽松，是因为手机切后台时可能长时间不回任何帧，断开太早会让
        # App 频繁重连。真正的死连接（对端 TCP 已断）会在 ping 写入时直接抛错。
        #
        # 读帧不能再用 self.rfile：它是 BufferedReader，在 socket 设了超时后
        # 一旦 read 抛过 timeout，内部状态就不可靠——下一次 read 会直接返回
        # b''（伪装成 EOF），连接被无声掐断。改用裸 socket 自己缓冲。
        left = b''
        try:
            self.connection.settimeout(0.001)
            left = self.rfile.read1(65536)     # 握手包可能和第一帧黏在同一段
        except (socket.timeout, OSError, ValueError):
            left = b''
        reader = _WsReader(self.connection)
        reader.buf += left
        self.connection.settimeout(25)
        buf = b''
        idle = 0
        why = 'client closed'
        try:
            while True:
                try:
                    fin, opcode, data = ws_read_frame(reader)
                except socket.timeout:
                    idle += 1
                    if idle >= 6:
                        why = 'idle 150s'
                        break
                    try:
                        ws_send_frame(self.wfile, b'', opcode=0x9)
                    except OSError as exc:
                        why = 'ping failed: %s' % exc
                        break
                    continue
                except OSError as exc:
                    why = 'socket: %s' % exc
                    break
                idle = 0
                if opcode is None:
                    why = 'eof'
                    break
                if opcode == 0x8:
                    why = 'close frame'
                    break
                if opcode == 0x9:
                    ws_send_frame(self.wfile, data, opcode=0xA)
                    continue
                if opcode == 0xA:
                    continue
                if opcode in (0x0, 0x1, 0x2):
                    buf = data if opcode else (buf + data)
                    if not fin:
                        continue                    # 分片未收完，继续攒
                    if len(buf) > 1048576:
                        why = 'frame too large'
                        buf = b''
                        break
                    raw, buf = buf, b''
                    self._ws_handle(raw.decode('utf-8', 'replace'), ip, token)
        except Exception as exc:
            why = 'error: %s' % exc
        finally:
            _ws_unregister(token if token else 'open:' + ip, self)
            with WS_LOCK:
                WS_STATS['open'] = max(0, WS_STATS['open'] - 1)
            print('[ws] closed %s (%s)' % (ip, why), flush=True)

    def _ws_drop(self):
        """立即断开这条 WS 连接（令牌失效时用）。"""
        try:
            self.connection.shutdown(socket.SHUT_RDWR)
        except Exception:
            pass
        try:
            self.connection.close()
        except Exception:
            pass

    def _ws_handle(self, text, ip, token):
        """把一条 WS 消息还原成 path + payload，交给 HTTP 那套逻辑执行。

        /move /scroll 是高频事件，执行完不回包（少一次往返）；其余指令回一条结果。
        """
        text = (text or '').strip()
        if not text:
            return
        try:
            payload = json.loads(text)
        except Exception:
            payload = {'action': text}          # 也允许直接发动作名
        if not isinstance(payload, dict):
            payload = {'action': str(payload)}
        path = str(payload.pop('path', '') or '')
        if not path:
            if 'dx' in payload or 'dy' in payload:
                path = '/move'
            elif 'keys' in payload or 'type' in payload:
                path = '/keys'
            else:
                path = '/key'
        if path not in POST_PATHS:
            ws_send_frame(self.wfile, json.dumps({'ok': False, 'msg': 'unknown path: ' + path}))
            return
        ctx = _WsCtx(path, payload, ip, token)
        try:
            Handler.do_POST(ctx)
        except Exception as exc:
            ws_send_frame(self.wfile, json.dumps({'ok': False, 'msg': str(exc)}))
            return
        with WS_LOCK:
            WS_STATS['msg'] += 1
        if path in ('/move', '/scroll'):
            if ctx.result and ctx.result[0] == 401:
                # 鉴权失败必须回包：触控盘平时不回包，不回的话手机端
                # 永远感知不到自己被踢，界面还停在"已连接"
                _, obj401 = ctx.result
                if isinstance(obj401, dict):
                    obj401 = dict(obj401)
                    obj401['ts'] = int(time.time() * 1000)
                ws_send_frame(self.wfile, json.dumps(obj401, ensure_ascii=False))
                self._ws_drop()
            return                              # 高频事件：不回包
        code, obj = ctx.result if ctx.result else (200, {'ok': True})
        if isinstance(obj, dict):
            obj = dict(obj)
            obj['ts'] = int(time.time() * 1000)
        ws_send_frame(self.wfile, json.dumps(obj, ensure_ascii=False))
        if code == 401:
            # 令牌已失效（设备被撤销/票据重置）：立刻断开，别让手机端
            # 抱着一条"看起来还活着"的死连接继续按无效指令
            self._ws_drop()

    def do_GET(self):
        # WebSocket 握手就伪装成一次 GET，所以要先于所有 HTTP 路由判断
        if 'websocket' in (self.headers.get('Upgrade', '') or '').lower():
            self._serve_ws()
            return
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == '/pairinfo':
            # 手机端配对信息（JSON，供调试/直连用）
            self.reply_json(200, {'ok': True, 'url': pair_url(),
                                  'host': _local_lan_ip(), 'port': PORT,
                                  'mac': _primary_mac(),
                                  'name': socket.gethostname(),
                                  'need_token': bool(SETTINGS.get('require_token')),
                                  'devices': len(DEVICES.get('devices') or [])})
            return
        if parsed.path == '/pair':
            # 配对二维码页：服务端生成二维码图片（离线可用），手机扫码
            url = pair_url()
            html = PAIR_PAGE_HTML % (_qr_img_html(url), urllib.parse.quote(url))
            data = html.encode('utf-8')
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        # 除配对信息/配对页外，其余 GET 都要令牌：应用列表和记录页都会泄露隐私
        ok_auth, _ = auth_request(self)
        if not ok_auth:
            self.reply_json(401, {'ok': False, 'need_pair': True,
                                  'msg': '未配对或已被移出设备列表，请重新扫码配对'})
            return
        if parsed.path == '/apps':
            # 手机端应用宫格：返回开始菜单应用列表；?refresh=1 强制重扫
            if 'refresh=1' in (parsed.query or ''):
                threading.Thread(target=scan_apps, daemon=True).start()
                self.reply_json(200, {'ok': True, 'count': len(APPS), 'apps': APPS,
                                      'refreshing': True})
                return
            if len(APPS) == 0:
                scan_apps()
            with APPS_LOCK:
                self.reply_json(200, {'ok': True, 'count': len(APPS),
                                      'apps': list(APPS)})
            return
        with LOCK:
            rows = ''.join('<li>' + r.replace('<', '&lt;') + '</li>'
                           for r in reversed(RECORDS[-25:]))
        html = (
            '<!doctype html><meta charset="utf-8">'
            '<title>遥控器桥接服务</title>'
            '<meta http-equiv="refresh" content="2">'
            '<style>body{font-family:sans-serif;background:#151922;color:#F3F5F9;'
            'padding:24px}li{padding:6px 0;border-bottom:1px solid #343D4B;'
            'font-family:monospace;font-size:13px}h1{font-size:20px}'
            'p{color:#9AA5B6}</style>'
            '<h1>遥控器桥接服务</h1>'
            '<p>NeoShell API: %s · %s · 每 2 秒刷新</p>'
            '<ul>%s</ul>'
        ) % ('ON' if NS_AVAILABLE else 'OFF (standalone)',
             'DRY-RUN' if DRY else 'LIVE',
             rows if rows else '<li>暂无记录</li>')
        data = html.encode('utf-8')
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def reply_json(self, code, obj):
        data = json.dumps(obj, ensure_ascii=False).encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        pass


# ---------- 服务启停（学 NeoShell：托盘里能 Start/Stop，不用退出进程） ----------
_SERVER = None
_SERVER_THREAD = None
_SERVER_LOCK = threading.Lock()


def service_running():
    return _SERVER is not None


def udp_discovery_loop():
    """局域网自动发现（手机设置页「自动扫描」用）。

    手机往 255.255.255.255:PORT 广播 DISCOVER_MAGIC，本进程回一份 JSON：
    host/port/mac/name/version/need_token。host 用 connect 技巧取
    「面对发起方的那块网卡」的 IP，双网卡机器也能回对地址。
    UDP 与 TCP 可共用同一端口号（协议不同，互不冲突）。
    """
    try:
        u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        u.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        u.bind(('0.0.0.0', PORT))
        u.settimeout(1.0)
        print('[discover] UDP listening on %d (broadcast)' % PORT, flush=True)
        magic = DISCOVER_MAGIC.encode()
        while True:
            try:
                data, addr = u.recvfrom(256)
            except socket.timeout:
                continue
            except OSError:
                break
            if magic not in data:
                continue
            try:
                tmp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                tmp.connect((addr[0], 9))
                face_ip = tmp.getsockname()[0]
                tmp.close()
            except Exception:
                face_ip = _local_lan_ip()
            info = {'ok': True, 'service': 'pc-remote',
                    'host': face_ip, 'port': PORT,
                    'mac': _primary_mac(), 'name': socket.gethostname(),
                    'version': APP_VERSION,
                    'need_token': bool(SETTINGS.get('require_token'))}
            try:
                u.sendto(json.dumps(info, ensure_ascii=False).encode('utf-8'), addr)
            except Exception:
                pass
    except Exception as exc:
        print('[discover] UDP server failed: %s' % exc, flush=True)


def service_start():
    """启动 HTTP 服务（幂等）。返回 (ok, msg)。"""
    global _SERVER, _SERVER_THREAD
    with _SERVER_LOCK:
        if _SERVER is not None:
            return True, '服务已在运行（端口 %d）' % PORT
        try:
            srv = ThreadingHTTPServer(('0.0.0.0', PORT), Handler)
        except OSError as exc:
            return False, '端口 %d 启动失败：%s' % (PORT, exc)
        _SERVER = srv
        _SERVER_THREAD = threading.Thread(target=srv.serve_forever, daemon=True)
        _SERVER_THREAD.start()
        threading.Thread(target=udp_discovery_loop, daemon=True,
                         name='udp-discover').start()
    print('[svc] started on %d' % PORT)
    return True, '服务已启动 · 端口 %d' % PORT


def service_stop():
    """停服务但保留进程（托盘还在，可再启动）。"""
    global _SERVER, _SERVER_THREAD
    with _SERVER_LOCK:
        if _SERVER is None:
            return True, '服务本来就没运行'
        srv = _SERVER
        _SERVER = None
        _SERVER_THREAD = None
    try:
        srv.shutdown()
        srv.server_close()
    except Exception as exc:
        print('[svc] stop error:', exc)
    print('[svc] stopped')
    return True, '服务已停止'


def service_toggle():
    return service_stop() if service_running() else service_start()


# ---------- 管理界面（本机 127.0.0.1 专用，不暴露到局域网） ----------
_ADMIN = None
_ADMIN_PORT = 0
_QR_CACHE = {'key': '', 'img': ''}


def _qr_data_url():
    """二维码 data URL，配对链接不变时复用，避免每次轮询都重新编码。"""
    import base64
    from io import BytesIO
    link = pair_url()
    if _QR_CACHE['key'] == link and _QR_CACHE['img']:
        return _QR_CACHE['img']
    try:
        import qrcode
        img = qrcode.make(link)
        buf = BytesIO()
        img.save(buf, format='PNG')
        url = 'data:image/png;base64,' + base64.b64encode(buf.getvalue()).decode('ascii')
        _QR_CACHE['key'] = link
        _QR_CACHE['img'] = url
        return url
    except Exception as exc:
        print('[qr] 生成失败:', exc)
        return ''


def _uptime_text():
    delta = datetime.now() - STATS['start_ts']
    sec = int(delta.total_seconds())
    h, m = sec // 3600, (sec % 3600) // 60
    return ('%d 小时 %d 分' % (h, m)) if h else ('%d 分 %d 秒' % (m, sec % 60))


def _state_obj():
    with LOG_LOCK:
        klog = list(KEY_LOG)
        vlog = list(VOICE_LOG)
    with APPS_LOCK:
        app_count = len(APPS)
    return {
        'ok': True,
        'running': service_running(),
        'version': APP_VERSION,
        'update': dict(UPDATE),
        'port': PORT,
        'admin_port': _ADMIN_PORT,
        'host': socket.gethostname(),
        'ip': _local_lan_ip(),
        'mac': _primary_mac(),
        'neoshell': NS_AVAILABLE,
        'dry': DRY,
        'apps': app_count,
        'uptime': _uptime_text(),
        'pair_url': pair_url(),
        'pair_page': pair_page_url(),
        'qr': _qr_data_url(),
        'settings': dict(SETTINGS),
        'autostart': autostart_enabled(),
        'devices': len(DEVICES.get('devices') or []),
        'online': sum(1 for p in phone_list() if p['online']),
        'phones': phone_list(),
        'firewall': firewall_check(),
        'hotkeys': {'on': bool(SETTINGS.get('hotkeys')) and HOTKEY_STATE['ok'],
                    'q': HOTKEY_NAMES['qr'], 's': HOTKEY_NAMES['toggle'],
                    'note': HOTKEY_STATE.get('note', '')},
        'require_token': bool(SETTINGS.get('require_token')),
        'stats': {
            'key': STATS['key'], 'key_fail': STATS['key_fail'],
            'voice': STATS['voice'], 'voice_miss': STATS['voice_miss'],
            'move': STATS['move'],
            'last_seen': STATS['last_seen'],
            'key_rows': len(klog), 'voice_rows': len(vlog),
        },
    }


class AdminHandler(BaseHTTPRequestHandler):
    """管理界面后端：只绑 127.0.0.1，普通手机/其它机器访问不到。"""

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        qs = urllib.parse.parse_qs(parsed.query or '')
        if path in ('/', '/index.html', '/admin'):
            page = _res_path('assets/admin.html')
            if not page:
                self.reply_text('管理界面文件缺失（assets/admin.html）', 500)
                return
            try:
                data = open(page, 'rb').read()
            except Exception as exc:
                self.reply_text('读取管理界面失败：%s' % exc, 500)
                return
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if path == '/api/voice-custom':
            load_custom()
            self.reply_json(200, {'ok': True, 'commands': CUSTOM['commands']})
            return
        if path == '/api/state':
            self.reply_json(200, _state_obj())
            return
        if path == '/api/logs':
            try:
                limit = max(1, min(1000, int(qs.get('limit', ['200'])[0])))
            except Exception:
                limit = 200
            with LOG_LOCK:
                klog = list(KEY_LOG)[-limit:]
                vlog = list(VOICE_LOG)[-limit:]
            self.reply_json(200, {'ok': True, 'key': klog, 'voice': vlog})
            return
        if path == '/api/devices':
            with _DEV_LOCK:
                devs = [{'id': d.get('id'), 'name': d.get('name'), 'model': d.get('model'),
                         'ip': d.get('ip'), 'created': d.get('created'),
                         'last': d.get('last'), 'count': d.get('count') or 0}
                        for d in DEVICES.get('devices') or []]
                paired_ips = {d.get('ip') for d in DEVICES.get('devices') or [] if d.get('ip')}
            devs.sort(key=lambda x: x.get('count') or 0, reverse=True)
            # 未配对但连接过的设备（开放模式下的临时连接记录，按 IP 记）
            with _WS_LIVE_LOCK:
                live = set(_WS_LIVE.keys())
            now = time.time()
            opens = []
            with _OPEN_SEEN_LOCK:
                for oip, v in OPEN_SEEN.items():
                    if oip in paired_ips:
                        continue
                    ts = float(v.get('last_ts') or 0)
                    if not ts or now - ts > 86400:
                        continue
                    opens.append({'ip': oip,
                                  'model': v.get('model') or '',
                                  'os': v.get('os') or '',
                                  'res': v.get('res') or '',
                                  'last': datetime.fromtimestamp(ts).strftime('%H:%M:%S'),
                                  'online': ('open:' + oip) in live or now - ts <= ONLINE_WINDOW})
            opens.sort(key=lambda x: (x['online'], x['last']), reverse=True)
            self.reply_json(200, {'ok': True, 'devices': devs, 'open': opens,
                                  'ticket': pair_ticket(),
                                  'require_token': bool(SETTINGS.get('require_token')),
                                  'max': MAX_DEVICES})
            return
        if path == '/api/open/forget':
            oip = str(payload.get('ip') or '')
            with _OPEN_SEEN_LOCK:
                OPEN_SEEN.pop(oip, None)
            self.reply_json(200, {'ok': True, 'msg': '已移除该连接记录'})
            return
        if path == '/api/export':
            kind = qs.get('type', ['voice'])[0]
            rows = VOICE_LOG if kind == 'voice' else KEY_LOG
            with LOG_LOCK:
                data = list(rows)
            body = '\n'.join(json.dumps(r, ensure_ascii=False) for r in data)
            fn = 'pcremote-%s-%s.txt' % (kind, datetime.now().strftime('%Y%m%d-%H%M%S'))
            raw = body.encode('utf-8-sig')
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain; charset=utf-8')
            self.send_header('Content-Disposition', 'attachment; filename="%s"' % fn)
            self.send_header('Content-Length', str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)
            return
        self.reply_text('not found', 404)

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        try:
            length = int(self.headers.get('Content-Length', '0') or '0')
            payload = json.loads(self.rfile.read(length).decode('utf-8', 'replace') or '{}')
        except Exception:
            payload = {}
        path = parsed.path
        if path == '/api/service':
            op = str(payload.get('op', 'toggle'))
            if op == 'start':
                ok, msg = service_start()
            elif op == 'stop':
                ok, msg = service_stop()
            elif op == 'restart':
                service_stop()
                ok, msg = service_start()
            else:
                ok, msg = service_toggle()
            print('[admin] %s -> %s' % (op, msg))
            self.reply_json(200, {'ok': ok, 'msg': msg, 'running': service_running()})
            return
        if path == '/api/voice-custom/save':
            try:
                n = save_custom(payload.get('commands') or [])
                self.reply_json(200, {'ok': True, 'msg': '已保存 %d 条自定义指令' % n,
                                      'commands': CUSTOM['commands']})
            except Exception as exc:
                self.reply_json(500, {'ok': False, 'msg': '保存失败：' + str(exc)})
            return
        if path == '/api/settings':
            patch = payload.get('patch') or {}
            changed_autostart = 'autostart' in patch and \
                bool(patch['autostart']) != bool(SETTINGS.get('autostart'))
            save_settings(patch)
            msg = '设置已保存'
            if changed_autostart:
                ok, m = set_autostart(bool(SETTINGS.get('autostart')))
                msg = m
            self.reply_json(200, {'ok': True, 'msg': msg, 'settings': dict(SETTINGS),
                                  'autostart': autostart_enabled()})
            return
        if path == '/api/check-update':
            r = check_update()
            with UPDATE_LOCK:
                cur = dict(UPDATE)
            self.reply_json(200, {'ok': r.get('ok', False), 'msg': '检查完成',
                                  'version': APP_VERSION, 'update': cur,
                                  'settings': dict(SETTINGS)})
            return
        if path == '/api/qr':
            threading.Thread(target=show_qr_window, daemon=True).start()
            self.reply_json(200, {'ok': True, 'msg': '扫码窗口已打开'})
            return
        if path == '/api/apps/rescan':
            threading.Thread(target=scan_apps, daemon=True).start()
            self.reply_json(200, {'ok': True, 'msg': '正在后台重新扫描应用'})
            return
        if path == '/api/firewall/check':
            self.reply_json(200, {'ok': True, 'firewall': firewall_check(force=True)})
            return
        if path == '/api/firewall/add':
            ok, msg = firewall_add()
            self.reply_json(200, {'ok': ok, 'msg': msg})
            return
        if path == '/api/devices/revoke':
            ok, msg = revoke_device(str(payload.get('id', '')))
            self.reply_json(200, {'ok': ok, 'msg': msg})
            return
        if path == '/api/devices/rename':
            ok, msg = rename_device(str(payload.get('id', '')), payload.get('name'))
            self.reply_json(200, {'ok': ok, 'msg': msg})
            return
        if path == '/api/devices/reset':
            ok, msg = reset_ticket()
            self.reply_json(200, {'ok': ok, 'msg': msg})
            return
        if path == '/api/logs/clear':
            kind = str(payload.get('type', 'key'))
            with LOG_LOCK:
                if kind in ('key', 'all'):
                    KEY_LOG.clear()
                if kind in ('voice', 'all'):
                    VOICE_LOG.clear()
            save_records()                # 清空同步写盘，重启后不会再冒出来
            self.reply_json(200, {'ok': True, 'msg': '记录已清空'})
            return
        if path == '/api/quit':
            self.reply_json(200, {'ok': True, 'msg': '正在退出'})
            threading.Timer(0.4, lambda: os._exit(0)).start()
            return
        self.reply_text('not found', 404)

    def reply_json(self, code, obj):
        data = json.dumps(obj, ensure_ascii=False).encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def reply_text(self, text, code=200):
        data = text.encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', 'text/plain; charset=utf-8')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        pass


def admin_start():
    """启动管理界面服务（只绑 127.0.0.1）。端口占用时自动往后找。"""
    global _ADMIN, _ADMIN_PORT
    if _ADMIN is not None:
        return True, '管理界面已在运行 · 端口 %d' % _ADMIN_PORT
    base = int(SETTINGS.get('admin_port') or 8766)
    last = ''
    for p in range(base, base + 6):
        try:
            srv = ThreadingHTTPServer(('127.0.0.1', p), AdminHandler)
        except OSError as exc:
            last = str(exc)
            continue
        _ADMIN = srv
        _ADMIN_PORT = p
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        print('[admin] http://127.0.0.1:%d  （管理界面，仅本机）' % p, flush=True)
        return True, '管理界面已启动 · http://127.0.0.1:%d' % p
    print('[admin] 启动失败:', last)
    return False, '管理界面启动失败：%s' % last


def admin_url():
    return 'http://127.0.0.1:%d' % _ADMIN_PORT


_WIN_TITLE = 'PC 遥控器 · 控制台'      # 控制台页面 <title>，Edge 应用窗口同名


def _find_console_hwnd():
    """按窗口标题找已打开的控制台窗口（Edge --app 窗口标题 = 页面标题）。"""
    try:
        import ctypes
        from ctypes import wintypes
        user32 = ctypes.windll.user32
        found = []
        enum_proc = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)

        def cb(hwnd, lparam):
            if not user32.IsWindowVisible(hwnd):
                return True
            if user32.GetWindowTextLengthW(hwnd) != len(_WIN_TITLE):
                return True
            buf = ctypes.create_unicode_buffer(len(_WIN_TITLE) + 1)
            user32.GetWindowTextW(hwnd, buf, len(_WIN_TITLE) + 1)
            if buf.value == _WIN_TITLE:
                found.append(hwnd)
                return False
            return True
        user32.EnumWindows(enum_proc(cb), 0)
        return found[0] if found else 0
    except Exception:
        return 0


def show_admin_window():
    """打开管理界面：已有窗口就聚焦（不再每次点托盘都新开一个），
    没有才用 Edge 应用模式开（无地址栏），位置记住上次的。"""
    hwnd = _find_console_hwnd()
    if hwnd:
        try:
            import ctypes
            user32 = ctypes.windll.user32
            if user32.IsIconic(hwnd):
                user32.ShowWindow(hwnd, 9)          # SW_RESTORE：最小化了就还原
            user32.SetForegroundWindow(hwnd)        # 提到最前
            return True
        except Exception:
            pass
    url = admin_url()
    x = int(SETTINGS.get('win_x') or 140)
    y = int(SETTINGS.get('win_y') or 60)
    w = int(SETTINGS.get('win_w') or 1120)
    h = int(SETTINGS.get('win_h') or 780)
    edge = _find_edge()
    if edge:
        try:
            subprocess.Popen([edge, '--app=' + url,
                              '--window-size=%d,%d' % (w, h),
                              '--window-position=%d,%d' % (x, y)])
            return True
        except Exception as exc:
            print('[admin] Edge 启动失败:', exc)
    _open_page(url)
    return True


def _track_console_window():
    """后台轮询记住控制台窗口的位置/大小：用户拖到哪，下次就在哪打开。"""
    try:
        import ctypes
        from ctypes import wintypes
        dwm = ctypes.windll.dwmapi
        while True:
            time.sleep(3)
            hwnd = _find_console_hwnd()
            if not hwnd:
                continue
            # DWM 扩展边界：Win11 下 GetWindowRect 会带上看不见的留白
            rect = wintypes.RECT()
            if dwm.DwmGetWindowAttribute(hwnd, 9, ctypes.byref(rect),
                                         ctypes.sizeof(rect)) != 0:
                continue
            x, y = rect.left, rect.top
            w, h = rect.right - rect.left, rect.bottom - rect.top
            if (x, y, w, h) != (SETTINGS.get('win_x'), SETTINGS.get('win_y'),
                                SETTINGS.get('win_w'), SETTINGS.get('win_h')):
                save_settings({'win_x': x, 'win_y': y, 'win_w': w, 'win_h': h})
    except Exception as exc:
        print('[admin] 窗口位置记忆已停:', exc)


# ---------- 扫码窗口（学 NeoShell：一屏看全二维码/地址/状态） ----------
# 本机 Python 没有 tkinter，故用 Edge 的应用模式（--app）开一个无地址栏独立小窗，
# 视觉效果与原生窗口一致，打包体积不增加；没有 Edge 时退回默认浏览器。
def _long_temp_dir():
    """优先用长路径的 %LOCALAPPDATA%\\Temp；短名路径（ADMINI~1）Edge 打不开。"""
    p = os.path.join(os.path.expanduser('~'), 'AppData', 'Local', 'Temp')
    if os.path.isdir(p):
        return p
    import tempfile
    return tempfile.gettempdir()


_QR_PAGE = os.path.join(_long_temp_dir(), 'pcremote_qr.html')
_QR_LAST = {'t': 0.0}

_QR_HTML = """<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<title>手机扫码配对</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:"Microsoft YaHei UI","Segoe UI",sans-serif;background:#F4F6FB;color:#1B1F2A;padding:16px}
.card{background:#fff;border-radius:16px;padding:16px;border:1px solid #E3E8F2}
h1{font-size:17px;font-weight:600;margin-bottom:4px}
.sub{font-size:12px;color:#6B7280;margin-bottom:14px;line-height:1.65}
.qr{width:100%;display:block;border-radius:12px;border:1px solid #E3E8F2}
.state{display:flex;align-items:center;gap:6px;font-size:12px;margin:13px 0 8px;color:#1B1F2A}
.dot{width:9px;height:9px;border-radius:50%;background:#9AA3B2;flex:none}
.dot.on{background:#16A34A}
.row{display:flex;justify-content:space-between;gap:10px;font-size:12px;padding:6px 0;border-top:1px solid #F0F3F9}
.k{color:#6B7280;flex:none}.v{font-family:Consolas,monospace;text-align:right;word-break:break-all}
.btn{width:100%;margin-top:12px;padding:9px;border:0;border-radius:10px;background:#2E6BE6;color:#fff;font-size:13px;cursor:pointer}
.tip{margin-top:11px;font-size:11px;color:#9AA3B2;line-height:1.7}
</style></head><body>
<div class="card">
<h1>手机扫码配对</h1>
<div class="sub">手机 App 右上角「＋ 扫码配对新电脑」<br>对准下面的二维码即可</div>
<img class="qr" src="__QR__" alt="配对二维码">
<div class="state"><span class="dot" id="dot"></span><span id="st">检测中…</span></div>
<div class="row"><span class="k">电脑名</span><span class="v">__NAME__</span></div>
<div class="row"><span class="k">地址</span><span class="v">__ADDR__</span></div>
<div class="row"><span class="k">端口</span><span class="v">__PORT__</span></div>
<button class="btn" id="cp">复制配对链接</button>
<div class="tip">关掉本窗口不会停止服务。启动/停止服务在托盘图标右键菜单里。</div>
</div>
<script>
const LINK = "__LINK__";
const dot = document.getElementById('dot'), st = document.getElementById('st');
async function ping(){
  try{
    const r = await fetch("__ADDR__/pairinfo", {cache:'no-store'});
    const j = await r.json();
    dot.classList.add('on');
    st.textContent = '服务运行中 · ' + (j.name || '') + ':' + j.port;
  }catch(e){
    dot.classList.remove('on');
    st.textContent = '服务未运行（托盘菜单点「启动服务」）';
  }
}
ping(); setInterval(ping, 2000);
document.getElementById('cp').onclick = async () => {
  const b = document.getElementById('cp');
  try{ await navigator.clipboard.writeText(LINK); b.textContent = '已复制配对链接'; }
  catch(e){ b.textContent = '复制失败，请手动输入地址'; }
};
</script></body></html>"""


def _find_edge():
    cands = [
        r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
        r'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
    ]
    for c in cands:
        if os.path.exists(c):
            return c
    import shutil
    return shutil.which('msedge') or ''


def _write_qr_page():
    """把二维码 + 地址 + 状态写成一张本地 HTML，每次打开都刷新内容。"""
    import base64
    import qrcode
    from io import BytesIO
    img = qrcode.make(pair_url())
    buf = BytesIO()
    img.save(buf, format='PNG')
    b64 = base64.b64encode(buf.getvalue()).decode('ascii')
    html = _QR_HTML
    html = html.replace('__QR__', 'data:image/png;base64,' + b64)
    html = html.replace('__NAME__', socket.gethostname())
    html = html.replace('__ADDR__', 'http://%s:%d' % (_local_lan_ip(), PORT))
    html = html.replace('__PORT__', str(PORT))
    html = html.replace('__LINK__', pair_url())
    with open(_QR_PAGE, 'w', encoding='utf-8') as f:
        f.write(html)
    return _QR_PAGE


def show_qr_window():
    """弹出一个独立小窗显示配对二维码（托盘的默认双击动作）。"""
    now = time.time()
    if now - _QR_LAST['t'] < 1.0:
        return
    _QR_LAST['t'] = now
    try:
        path = _write_qr_page()
    except Exception as exc:
        print('[qr] 生成扫码页失败:', exc)
        _open_page(pair_page_url())
        return
    url = 'file:///' + path.replace('\\', '/')
    edge = _find_edge()
    if edge:
        try:
            subprocess.Popen([edge, '--app=' + url, '--window-size=430,690',
                              '--window-position=120,80'])
            print('[qr] 扫码窗口已打开')
            return
        except Exception as exc:
            print('[qr] Edge 启动失败:', exc)
    _open_page(url)


# ---------- 托盘菜单 / 控制台菜单 ----------

def _res_path(rel):
    """PyInstaller onefile 时资源在 _MEIPASS 解压目录；脚本运行时在脚本目录。"""
    base = getattr(sys, '_MEIPASS', None)
    if base:
        cand = os.path.join(base, rel)
        if os.path.exists(cand):
            return cand
    cand = str(BASE_DIR / rel)
    return cand if os.path.exists(cand) else ''


def _open_page(url):
    try:
        threading.Thread(target=lambda: os.startfile(url), daemon=True).start()
    except Exception:
        pass


def _tray_exit(icon, item):
    try:
        icon.stop()
    finally:
        os._exit(0)


def _tray_img(running):
    """托盘图标 + 右下角状态点：绿=服务在跑，灰=已停（学 NeoShell 的状态灯）。"""
    from PIL import Image, ImageDraw
    path = _res_path('assets/app_icon.ico')
    img = None
    if path:
        try:
            img = Image.open(path).convert('RGBA').resize((64, 64))
        except Exception:
            img = None
    if img is None:
        img = Image.new('RGBA', (64, 64), (46, 107, 230, 255))
    d = ImageDraw.Draw(img)
    d.ellipse([44, 44, 62, 62], fill=(22, 163, 74, 255) if running else (154, 163, 178, 255),
              outline=(255, 255, 255, 255), width=2)
    return img


# ---------- 全局热键（Ctrl+Alt+Q 二维码 / Ctrl+Alt+S 启停服务） ----------
HOTKEYS = [(11, 'Q', 'qr'), (12, 'S', 'toggle')]
HOTKEY_NAMES = {'qr': 'Ctrl+Alt+Q', 'toggle': 'Ctrl+Alt+S'}
HOTKEY_STATE = {'ok': False, 'note': ''}
_TRAY_ICON = [None]


def _toast(msg, title='PC 遥控器'):
    """优先用托盘气泡提示，没有托盘就打印。"""
    ic = _TRAY_ICON[0]
    if ic is not None:
        try:
            ic.notify(msg, title)
            return
        except Exception:
            pass
    print('[tip]', msg)


def hotkey_loop():
    """独立线程跑 Windows 消息循环，接收全局热键。"""
    try:
        import ctypes
        from ctypes import wintypes
        u = ctypes.windll.user32
    except Exception as exc:
        HOTKEY_STATE['note'] = '当前系统不支持：%s' % exc
        print('[hot] ' + HOTKEY_STATE['note'])
        return
    MOD_ALT, MOD_CONTROL, MOD_NOREPEAT = 0x0001, 0x0002, 0x4000
    WM_HOTKEY = 0x0312
    ids = {}
    for hid, key, act in HOTKEYS:
        if u.RegisterHotKey(None, hid, MOD_CONTROL | MOD_ALT | MOD_NOREPEAT, ord(key)):
            ids[hid] = act
    if not ids:
        HOTKEY_STATE['note'] = '注册失败，可能被其它程序占用'
        print('[hot] ' + HOTKEY_STATE['note'])
        return
    HOTKEY_STATE['ok'] = True
    HOTKEY_STATE['note'] = '已启用 ' + ' / '.join(HOTKEY_NAMES[a] for a in ids.values())
    print('[hot] ' + HOTKEY_STATE['note'])
    msg = wintypes.MSG()
    while True:
        try:
            r = u.GetMessageW(ctypes.byref(msg), None, 0, 0)
        except Exception:
            break
        if r <= 0:
            break
        if msg.message != WM_HOTKEY:
            continue
        act = ids.get(int(msg.wParam))
        try:
            if act == 'qr':
                show_qr_window()
            elif act == 'toggle':
                ok, m = service_toggle()
                _toast(m)
                ic = _TRAY_ICON[0]
                if ic is not None:
                    ic.icon = _tray_img(service_running())
        except Exception as exc:
            print('[hot] 处理失败：', exc)


def _tray_watch(ic):
    """托盘状态每 10 秒自刷新：状态点跟着服务走，标题带在线台数。"""
    last_txt = ''
    last_run = None
    while True:
        time.sleep(10)
        try:
            run = service_running()
            txt = tray_status_text()
            if txt != last_txt:
                ic.title = ('PC 遥控器 · ' + txt)[:120]
                last_txt = txt
            if run != last_run:          # 只有状态变了才换图标，避免闪烁
                ic.icon = _tray_img(run)
                last_run = run
        except Exception:
            return


def run_tray():
    """右下角托盘：控制台 / 二维码 / 启停 / 防火墙 / 重扫 / 退出。"""
    try:
        import pystray
        menu = pystray.Menu(
            pystray.MenuItem(lambda it: tray_status_text(), None, enabled=False),
            pystray.MenuItem('打开控制台', lambda i, it: show_admin_window(), default=True),
            pystray.MenuItem('显示配对二维码  (Ctrl+Alt+Q)', lambda i, it: show_qr_window()),
            pystray.MenuItem(lambda it: '停止服务  (Ctrl+Alt+S)' if service_running()
                             else '启动服务  (Ctrl+Alt+S)', _tray_toggle),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem('放行防火墙（手机连不上时点这个）', _tray_firewall),
            pystray.MenuItem('重新扫描应用列表',
                             lambda i, it: threading.Thread(target=scan_apps, daemon=True).start()),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem('退出', _tray_exit),
        )
        ic = pystray.Icon('PCRemoteServer', _tray_img(service_running()),
                          'PC 遥控器 · ' + tray_status_text(), menu)
        _TRAY_ICON[0] = ic
        threading.Thread(target=_tray_watch, args=(ic,), daemon=True).start()
        ic.run()
        return True
    except Exception as exc:
        print('托盘不可用（%s），改用控制台菜单' % exc)
        return False


def _tray_toggle(icon, item):
    ok, msg = service_toggle()
    print('[tray]', msg)
    try:
        icon.icon = _tray_img(service_running())
        icon.title = ('PC 遥控器 · ' + tray_status_text())[:120]
    except Exception:
        pass


def _tray_firewall(icon, item):
    ok, msg = firewall_add()
    print('[tray]', msg)
    _toast(msg)
    if not ok:
        return

    def _later():
        time.sleep(7)
        info = firewall_check(force=True)
        _toast(info.get('msg', ''), '防火墙状态')
    threading.Thread(target=_later, daemon=True).start()



def console_menu():
    """托盘不可用时的兜底数字菜单。"""
    while True:
        print()
        print('──── 菜单 ────')
        print(' 1. 打开控制台（管理界面）')
        print(' 2. 显示配对二维码')
        print(' 3. %s' % ('停止服务' if service_running() else '启动服务'))
        print(' 4. 打开配对页（浏览器）')
        print(' 5. 打开按键记录页')
        print(' 6. 重新扫描应用列表')
        print(' 0. 退出')
        try:
            c = input('选择: ').strip()
        except (EOFError, KeyboardInterrupt):
            os._exit(0)
        if c == '1':
            show_admin_window()
        elif c == '2':
            show_qr_window()
        elif c == '3':
            print(service_toggle()[1])
        elif c == '4':
            os.startfile(pair_page_url())
        elif c == '5':
            os.startfile('http://127.0.0.1:%d' % PORT)
        elif c == '6':
            threading.Thread(target=scan_apps, daemon=True).start()
            print('已在后台重新扫描…')
        elif c == '0':
            os._exit(0)


def _already_running():
    """单实例守卫：Windows 命名互斥体，跨路径生效（C 盘/D 盘两份 exe 只能跑一个）。
    进程退出时互斥体由系统自动释放，不需要手动清理。"""
    try:
        import ctypes
        ctypes.windll.kernel32.CreateMutexW(None, False, 'PCRemote_SingleInstance')
        return int(ctypes.windll.kernel32.GetLastError()) == 183   # ERROR_ALREADY_EXISTS
    except Exception:
        return False


if __name__ == '__main__':
    load_settings()
    load_devices()
    load_records()
    # --min / 设置里勾了「启动时隐藏控制台」：开机自启时不弹黑窗
    if '--min' in sys.argv or SETTINGS.get('start_hidden'):
        try:
            import ctypes
            hwnd = ctypes.windll.kernel32.GetConsoleWindow()
            if hwnd:
                ctypes.windll.user32.ShowWindow(hwnd, 0)
        except Exception:
            pass
    # --qr：只是把扫码窗口调出来（可做桌面快捷方式，服务照旧在托盘程序里）
    if '--qr' in sys.argv:
        show_qr_window()
        time.sleep(2.5)
        sys.exit(0)
    # 单实例：任何路径的第二份程序不再启动服务，直接把已运行实例的控制台弹出来
    if _already_running():
        import webbrowser
        url = 'http://127.0.0.1:%d' % int(SETTINGS.get('admin_port') or 8766)
        print('程序已在运行，打开已有实例的控制台: %s' % url)
        webbrowser.open(url)
        time.sleep(1.0)
        sys.exit(0)
    load_neoshell()
    load_apps_cache()
    # 后台扫描开始菜单刷新应用列表（首次启动没有缓存时这里会补上）
    threading.Thread(target=scan_apps, daemon=True).start()
    print(service_start()[1])
    admin_start()
    threading.Thread(target=_track_console_window, daemon=True).start()
    # 启动后 8 秒后台检查更新（settings.json 里 update_check=false 可关）
    threading.Thread(target=_update_worker, daemon=True).start()
    print('手机 App 目标地址: http://<电脑IP>:%d/key' % PORT)
    print('管理控制台: %s  （只有本机能打开；托盘菜单也能进）' % admin_url())
    print('按键记录页: http://<电脑IP>:%d' % PORT)
    print('配对二维码页: %s  （浏览器打开后用手机扫码）' % pair_page_url())
    print('二维码内容: %s' % pair_url())
    print('语音理解: 本地规则（离线，无云端大模型依赖）')
    print('模式: %s' % ('DRY-RUN 安全测试' if DRY else 'LIVE 真实执行'))
    print('提示: 右下角托盘右键 → 打开控制台 / 显示配对二维码 / 启停服务 / 退出')
    # 全局热键（设置里可关）
    if SETTINGS.get('hotkeys'):
        threading.Thread(target=hotkey_loop, daemon=True).start()
        print('热键: Ctrl+Alt+Q 二维码 / Ctrl+Alt+S 启停服务')
    # 防火墙：只检测不打扰（不自动弹 UAC），没放行就给出提示
    _fw = firewall_check()
    if _fw.get('ok') and _fw.get('action') != 'allow':
        print('警告: 防火墙同名规则是「阻止」状态，手机连不上，请点托盘「放行防火墙」')
    elif not _fw.get('ok'):
        print('提示: 未发现防火墙放行规则；手机连不上时点托盘「放行防火墙」')
    if '--admin' in sys.argv:
        # 双击 exe 带 --admin：起来后直接把控制台窗口弹出来
        threading.Timer(1.5, show_admin_window).start()
    elif '--min' not in sys.argv and not SETTINGS.get('start_hidden'):
        # 默认启动（非开机自启 --min）也弹控制台：程序是给人用的，起来就要看得见
        threading.Timer(1.2, show_admin_window).start()
    if not run_tray():
        console_menu()
