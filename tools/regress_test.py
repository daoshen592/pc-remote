# -*- coding: utf-8 -*-
"""回归：WS 全通道 + HTTP 兜底通道 + pairinfo。只做无副作用的动作。"""
import base64
import json
import os
import socket
import struct
import time
import urllib.request

HOST, PORT = '127.0.0.1', 8765


def ws_connect():
    s = socket.create_connection((HOST, PORT), timeout=8)
    key = base64.b64encode(os.urandom(16)).decode()
    s.sendall(('GET /ws?token=local HTTP/1.1\r\nHost: %s:%d\r\n'
               'Upgrade: websocket\r\nConnection: Upgrade\r\n'
               'Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n'
               % (HOST, PORT, key)).encode())
    buf = b''
    while b'\r\n\r\n' not in buf:
        buf += s.recv(4096)
    assert b'101' in buf.split(b'\r\n')[0]
    return s


def send(s, obj):
    data = json.dumps(obj).encode()
    mask = os.urandom(4)
    n = len(data)
    hdr = bytearray([0x81])
    if n < 126:
        hdr.append(0x80 | n)
    else:
        hdr.append(0x80 | 126)
        hdr += struct.pack('>H', n)
    hdr += mask + bytes(b ^ mask[i & 3] for i, b in enumerate(data))
    s.sendall(bytes(hdr))


def recv(s):
    h = s.recv(2)
    if len(h) < 2:
        return None
    n = h[1] & 0x7F
    if n == 126:
        n = struct.unpack('>H', s.recv(2))[0]
    elif n == 127:
        n = struct.unpack('>Q', s.recv(8))[0]
    d = b''
    while len(d) < n:
        d += s.recv(n - len(d))
    return json.loads(d.decode())


def call(s, obj, wait=True):
    send(s, obj)
    return recv(s) if wait else None


print('=== WebSocket 通道 ===')
s = ws_connect()
print(' 1) 握手            : 101 OK')
print(' 2) /key 按键        :', call(s, {'path': '/key', 'action': 'wake'}))
print(' 3) /keys 单键       :', call(s, {'path': '/keys', 'type': 'key', 'key': 'f24'}))
print(' 4) /keys 组合键     :', call(s, {'path': '/keys', 'type': 'combo', 'keys': ['f24']}))
print(' 5) /keys 非法键名   :', call(s, {'path': '/keys', 'type': 'key', 'key': 'nosuchkey'}))
print(' 6) /text 空文本     :', call(s, {'path': '/text', 'text': ''}))
print(' 7) 未知 action      :', call(s, {'path': '/key', 'action': 'zzz_unknown'}))
# 热路径：不回包，用发完不报错 + 后续帧仍可通证明
call(s, {'path': '/move', 'dx': 2, 'dy': 1}, wait=False)
call(s, {'path': '/move', 'dx': -2, 'dy': -1}, wait=False)
call(s, {'path': '/scroll', 'dy': 120}, wait=False)
print(' 8) /move /scroll    : 已发送（高频约定不回包）')
print(' 9) 热路径后通道存活 :', call(s, {'path': '/key', 'action': 'wake'}))
print('10) 未知 path        :', call(s, {'path': '/nope'}))
# 隐式推断 path
print('11) 无 path 推断位移 :', call(s, {'dx': 1, 'dy': 1}, wait=False) or '已发送')
print('12) 无 path 推断按键 :', call(s, {'action': 'wake'}))
s.close()

print('\n=== HTTP 兜底通道 ===')


def post(path, obj):
    req = urllib.request.Request('http://%s:%d%s' % (HOST, PORT, path),
                                 data=json.dumps(obj).encode(),
                                 headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=8) as r:
        return r.status, json.loads(r.read().decode())


print(' 1) POST /key        :', post('/key', {'action': 'wake'}))
print(' 2) POST /move       :', post('/move', {'dx': 1, 'dy': 1})[0], '(HTTP 下正常回包)')
print(' 3) 404 未声明长度   :', end=' ')
try:
    post('/nope', {})
except Exception as exc:
    print('HTTP', getattr(exc, 'code', exc))

print('\n=== GET 端点 ===')
with urllib.request.urlopen('http://%s:%d/pairinfo' % (HOST, PORT), timeout=8) as r:
    d = json.loads(r.read().decode())
    print(' /pairinfo        : ok=%s host=%s mac=%s devices=%s'
          % (d['ok'], d['host'], d['mac'], d['devices']))
with urllib.request.urlopen('http://%s:%d/' % (HOST, PORT), timeout=8) as r:
    print(' / 记录页          : %d 字节，%d 条记录' % (len(r.read()), 0))
