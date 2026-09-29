#!/usr/bin/env python3
"""生成 Wattup 的应用图标：绿色圆角方块 + 白色闪电，与菜单栏药丸同一套配色。"""
import math
import os
import subprocess
import sys

from PIL import Image, ImageDraw

GREEN_TOP = (0x2B, 0xE8, 0x5C)
GREEN_BOTTOM = (0x00, 0xA3, 0x2B)

# 与菜单栏闪电同一形状，归一化到 0...1
BOLT = [(0.62, 0.06), (0.20, 0.56), (0.46, 0.56), (0.38, 0.96),
        (0.82, 0.44), (0.54, 0.44)]


def make(size: int) -> Image.Image:
    # 先 4 倍超采样再缩回来，边缘才干净
    ss = 4
    s = size * ss
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))

    # 圆角方块：macOS 的 squircle 近似半径约 22.4%
    radius = int(s * 0.224)
    mask = Image.new("L", (s, s), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, s - 1, s - 1], radius=radius, fill=255)

    grad = Image.new("RGBA", (s, s))
    gd = ImageDraw.Draw(grad)
    for y in range(s):
        t = y / max(1, s - 1)
        r = int(GREEN_TOP[0] + (GREEN_BOTTOM[0] - GREEN_TOP[0]) * t)
        g = int(GREEN_TOP[1] + (GREEN_BOTTOM[1] - GREEN_TOP[1]) * t)
        b = int(GREEN_TOP[2] + (GREEN_BOTTOM[2] - GREEN_TOP[2]) * t)
        gd.line([(0, y), (s, y)], fill=(r, g, b, 255))

    img.paste(grad, (0, 0), mask)

    # 白色闪电，居中，留 30% 边距
    bolt = Image.new("L", (s, s), 0)
    bd = ImageDraw.Draw(bolt)
    pad = s * 0.30
    box = s - pad * 2
    pts = [(pad + x * box, pad + y * box) for x, y in BOLT]
    bd.polygon(pts, fill=255)
    img.paste(Image.new("RGBA", (s, s), (255, 255, 255, 255)), (0, 0), bolt)

    return img.resize((size, size), Image.LANCZOS)


def main(out_icns: str):
    work = "/tmp/wattup.iconset"
    os.makedirs(work, exist_ok=True)
    for base in (16, 32, 64, 128, 256, 512):
        make(base).save(f"{work}/icon_{base}x{base}.png")
        make(base * 2).save(f"{work}/icon_{base}x{base}@2x.png")
    os.makedirs(os.path.dirname(out_icns), exist_ok=True)
    subprocess.run(["iconutil", "-c", "icns", work, "-o", out_icns], check=True)
    print("已生成", out_icns, os.path.getsize(out_icns), "bytes")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "/tmp/AppIcon.icns")
