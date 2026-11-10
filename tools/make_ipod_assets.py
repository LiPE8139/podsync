#!/usr/bin/env python3
"""生成 App 里用的 iPod 设备剪影图（项目原创，CC0-1.0）。

不依赖任何第三方素材：全部用 Pillow 画圆角矩形/圆形/文字。
输出：gui/assets/ipod_black.png、ipod_silver.png、ipod.png（1200x2000，透明背景）
用法：python3 tools/make_ipod_assets.py
"""
from PIL import Image, ImageDraw, ImageFont
import os

W, H = 1200, 2000
HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(HERE, "gui", "assets")


def rr(draw, box, radius, fill, outline=None, width=1):
    draw.rounded_rectangle(box, radius=radius, fill=fill, outline=outline, width=width)


def draw_ipod(body, body_edge, screen_bg, wheel, wheel_edge, button, screen_art, screen_line):
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    # 机身
    m = 90
    rr(d, (m, 70, W - m, H - 70), 120, body, body_edge, 8)

    # 屏幕
    sx0, sy0, sx1, sy1 = m + 70, 190, W - m - 70, 760
    rr(d, (sx0, sy0, sx1, sy1), 34, screen_bg, None)
    # 屏幕内容：封面 + 两行信息 + 进度条
    art = 200
    ax, ay = sx0 + 40, sy0 + 46
    rr(d, (ax, ay, ax + art, ay + art), 12, screen_art)
    d.ellipse((ax + art // 2 - 42, ay + art // 2 - 42,
               ax + art // 2 + 42, ay + art // 2 + 42), outline=(150, 120, 80), width=3)
    d.ellipse((ax + art // 2 - 12, ay + art // 2 - 12,
               ax + art // 2 + 12, ay + art // 2 + 12), fill=(120, 96, 64))

    lx = ax + art + 46
    lw = sx1 - lx - 50
    d.rounded_rectangle((lx, ay + 24, lx + lw, ay + 48), 12, fill=screen_line)
    d.rounded_rectangle((lx, ay + 84, lx + int(lw * 0.74), ay + 108), 12, fill=screen_line)
    d.rounded_rectangle((lx, ay + 144, lx + int(lw * 0.52), ay + 164), 10, fill=screen_line)

    # 进度条
    px0, px1 = sx0 + 46, sx1 - 46
    py = sy1 - 80
    d.rounded_rectangle((px0, py, px1, py + 16), 8, fill=(60, 62, 66))
    d.rounded_rectangle((px0, py, px0 + int((px1 - px0) * 0.42), py + 16), 8, fill=screen_line)

    # 转盘
    cx, cy = W // 2, 1360
    r = 430
    d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=wheel, outline=wheel_edge, width=6)
    r2 = 240
    d.ellipse((cx - r2, cy - r2, cx + r2, cy + r2), fill=button, outline=wheel_edge, width=4)

    # 转盘上的四个标记（MENU / 上一首 / 下一首 / 播放暂停），刻意不画 Apple logo
    try:
        font = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 78)
    except Exception:
        try:
            font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 78)
        except Exception:
            font = ImageFont.load_default()
    label = "MENU"
    tb = d.textbbox((0, 0), label, font=font)
    d.text((cx - (tb[2] - tb[0]) / 2, cy - r + 44), label, fill=screen_line, font=font)

    # 上一首 / 下一首（双三角）
    for dx in (-r + 150, r - 150):
        d.polygon([(cx + dx - 26, cy - 46), (cx + dx - 26, cy + 46), (cx + dx + 20, cy)],
                  fill=screen_line)
        d.polygon([(cx + dx + 26, cy - 46), (cx + dx + 26, cy + 46), (cx + dx + 72, cy)],
                  fill=screen_line)
    # 播放/暂停
    d.polygon([(cx - 26, cy + r - 110), (cx - 26, cy + r - 30), (cx + 26, cy + r - 70)],
              fill=screen_line)
    d.rounded_rectangle((cx + 40, cy + r - 108, cx + 52, cy + r - 32), 4, fill=screen_line)
    d.rounded_rectangle((cx + 66, cy + r - 108, cx + 78, cy + r - 32), 4, fill=screen_line)
    return img


def main():
    os.makedirs(OUT, exist_ok=True)
    black = draw_ipod(
        body=(30, 31, 34, 255), body_edge=(84, 86, 92, 255),
        screen_bg=(14, 15, 17, 255), wheel=(24, 25, 28, 255),
        wheel_edge=(70, 72, 78, 255), button=(36, 37, 40, 255),
        screen_art=(122, 96, 62, 255), screen_line=(228, 214, 190, 255))
    silver = draw_ipod(
        body=(214, 215, 219, 255), body_edge=(158, 160, 166, 255),
        screen_bg=(18, 19, 22, 255), wheel=(232, 233, 236, 255),
        wheel_edge=(168, 170, 176, 255), button=(208, 209, 213, 255),
        screen_art=(122, 96, 62, 255), screen_line=(228, 214, 190, 255))
    black.save(os.path.join(OUT, "ipod_black.png"))
    black.save(os.path.join(OUT, "ipod.png"))
    silver.save(os.path.join(OUT, "ipod_silver.png"))
    print("写入:", OUT)


if __name__ == "__main__":
    main()
