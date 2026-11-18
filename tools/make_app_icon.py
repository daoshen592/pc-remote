# -*- coding: utf-8 -*-
"""按 HarmonyOS 图标规范生成 PC遥控器 应用图标。

规范要点：
- 1024x1024 全幅背景（系统自动裁切为圆角方形/圆形）
- 主体图形放在中央安全区内（约 512x512 为关键内容区）
- 图标内容简洁、无文字、高对比
产出：
- AppScope/resources/base/media/app_icon.png     启动器图标
- entry/src/main/resources/base/media/startIcon.png 启动页图标
- tools/assets/app_icon_512.png                  AGC 上传用
- tools/assets/icon_foreground_1024.png / icon_background_1024.png  分层图标素材
"""
import os
from PIL import Image, ImageDraw, ImageFilter

S = 1024
F = 2                      # 超采样倍数
W = S * F
BASE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(BASE)


def lerp(a, b, t):
    return int(a + (b - a) * t)


def make_background():
    """斜向渐变：左上亮蓝 -> 右下深蓝，叠一层左上柔光"""
    c1 = (77, 141, 255)     # #4D8DFF
    c2 = (10, 63, 191)      # #0A3FBF
    img = Image.new('RGB', (W, W))
    d = ImageDraw.Draw(img)
    # 逐行斜向渐变（对角线方向）
    for y in range(W):
        t = y / (W - 1)
        # 每行再叠加水平方向的轻微变化，形成对角渐变
        for_x0 = (lerp(c1[0], c2[0], t * 0.75),
                  lerp(c1[1], c2[1], t * 0.75),
                  lerp(c1[2], c2[2], t * 0.75))
        d.line([(0, y), (W, y)], fill=for_x0)
    # 左上柔光
    glow = Image.new('L', (W, W), 0)
    gd = ImageDraw.Draw(glow)
    gd.ellipse([-W * 0.35, -W * 0.45, W * 0.65, W * 0.45], fill=70)
    glow = glow.filter(ImageFilter.GaussianBlur(W // 6))
    white = Image.new('RGB', (W, W), (255, 255, 255))
    img = Image.composite(white, img, glow.point(lambda v: int(v * 0.55)))
    return img


def rrect(draw, box, r, fill=255):
    draw.rounded_rectangle(box, radius=r, fill=fill)


def make_glyph_mask():
    """白色遥控器图形 + 镂空细节，返回 L 模式 alpha 蒙版"""
    body = Image.new('L', (W, W), 0)
    bd = ImageDraw.Draw(body)

    # 机身：中央竖直圆角矩形（宽 228，高 560，居中偏上一点的视觉中心）
    bw = int(W * 0.222)                 # 约 227
    bh = int(W * 0.548)                 # 约 561
    cx = W // 2
    top = (W - bh) // 2
    box = [cx - bw // 2, top, cx + bw // 2, top + bh]
    rrect(bd, box, r=int(bw * 0.30))

    # 细节镂空（黑）
    holes = Image.new('L', (W, W), 0)
    hd = ImageDraw.Draw(holes)

    # 顶部屏幕：横向圆角条
    sw = int(bw * 0.56)
    sh = int(bw * 0.17)
    sy = top + int(bh * 0.115)
    rrect(hd, [cx - sw // 2, sy, cx + sw // 2, sy + sh], r=int(sh * 0.35))

    # 中央确认键：圆环
    ring_r = int(bw * 0.225)
    ring_w = int(bw * 0.095)
    cy = top + int(bh * 0.50)
    hd.ellipse([cx - ring_r, cy - ring_r, cx + ring_r, cy + ring_r], fill=255)
    hd.ellipse([cx - ring_r + ring_w, cy - ring_r + ring_w,
                cx + ring_r - ring_w, cy + ring_r - ring_w], fill=0)

    # 底部两个小圆点
    dot_r = int(bw * 0.062)
    dy = top + int(bh * 0.795)
    dx = int(bw * 0.18)
    hd.ellipse([cx - dx - dot_r, dy - dot_r, cx - dx + dot_r, dy + dot_r], fill=255)
    hd.ellipse([cx + dx - dot_r, dy - dot_r, cx + dx + dot_r, dy + dot_r], fill=255)

    # 机身减掉细节 = 最终图形
    from PIL import ImageChops
    alpha = ImageChops.subtract(body, holes)
    return alpha


def build():
    bg = make_background()
    fg = make_glyph_mask()

    icon = bg.copy()
    icon.paste(Image.new('RGB', (W, W), (255, 255, 255)), (0, 0), fg)

    icon = icon.resize((S, S), Image.LANCZOS)

    targets = [
        (os.path.join(ROOT, 'AppScope', 'resources', 'base', 'media', 'app_icon.png'), 1024),
        (os.path.join(ROOT, 'entry', 'src', 'main', 'resources', 'base', 'media', 'startIcon.png'), 1024),
        (os.path.join(BASE, 'assets', 'app_icon_512.png'), 512),
    ]
    for path, size in targets:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        img = icon if size == 1024 else icon.resize((size, size), Image.LANCZOS)
        img.save(path, 'PNG')
        print('saved', path, img.size)

    # AGC 分层素材：前景（透明底白色图形）+ 背景
    fg_rgb = Image.new('RGBA', (W, W), (255, 255, 255, 0))
    white = Image.new('RGBA', (W, W), (255, 255, 255, 255))
    fg_rgb.paste(white, (0, 0), fg)
    fg_path = os.path.join(BASE, 'assets', 'icon_foreground_1024.png')
    fg_rgb.resize((S, S), Image.LANCZOS).save(fg_path, 'PNG')
    bg_path = os.path.join(BASE, 'assets', 'icon_background_1024.png')
    bg.save(bg_path, 'PNG')
    print('saved', fg_path)
    print('saved', bg_path)


if __name__ == '__main__':
    build()
