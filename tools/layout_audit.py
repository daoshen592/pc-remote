# -*- coding: utf-8 -*-
"""分析 uitest dumpLayout：找出子元素超出父容器的位置。"""
import json
import re
import sys

PATH = sys.argv[1] if len(sys.argv) > 1 else '/tmp/land.json'


def parse_bounds(s):
    m = re.match(r'\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]', s or '')
    if not m:
        return None
    x1, y1, x2, y2 = [int(v) for v in m.groups()]
    return x1, y1, x2, y2


def inside(child, parent):
    cx1, cy1, cx2, cy2 = child
    px1, py1, px2, py2 = parent
    return cx1 >= px1 - 1 and cy1 >= py1 - 1 and cx2 <= px2 + 1 and cy2 <= py2 + 1


rows = []
with open(PATH, 'r', encoding='utf-8', errors='replace') as f:
    root = json.load(f)


def walk(node, depth, parent_bounds, parent_desc):
    a = node.get('attributes', {})
    t = a.get('text') or ''
    ty = a.get('type') or ''
    b = parse_bounds(a.get('bounds'))
    desc = (ty + (' "' + t[:12] + '"' if t else ''))
    flag = ''
    if b and parent_bounds and not inside(b, parent_bounds):
        flag = '  <<< 超出父容器 ' + str(parent_bounds)
    rows.append((depth, desc, a.get('bounds', ''), flag))
    for c in node.get('children', []):
        walk(c, depth + 1, b if b else parent_bounds, desc)


walk(root, 0, None, '')
for depth, desc, bounds, flag in rows:
    print('  ' * depth + desc.ljust(30) + bounds + flag)
print('\n总节点数:', len(rows))
print('越界节点数:', sum(1 for r in rows if r[3]))
