# -*- coding: utf-8 -*-
"""WOL 魔术包构造与广播发送自测（模拟手机端行为）。"""
import socket

MAC = 'A0-AD-9F-18-C2-42'


def build_magic(mac):
    mac_hex = ''.join(c for c in mac if c.isalnum()).lower()
    assert len(mac_hex) == 12, 'MAC 格式错误: %s' % mac_hex
    pkt = b'\xff' * 6
    for _ in range(16):
        for j in range(6):
            pkt += bytes([int(mac_hex[j * 2:j * 2 + 2], 16)])
    assert len(pkt) == 102, '包长错误'
    return pkt


def main():
    pkt = build_magic(MAC)
    print('魔术包 %d 字节，前 16 字节: %s' % (len(pkt), pkt[:16].hex()))
    for addr in ('192.168.1.255', '255.255.255.255'):
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        s.sendto(pkt, (addr, 9))
        s.close()
        print('已广播到 %s:9' % addr)
    print('自测通过（电脑开着无法验证真唤醒，真唤醒要电脑睡眠后用手机试）')


if __name__ == '__main__':
    main()
