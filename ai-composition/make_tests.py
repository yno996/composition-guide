# -*- coding: utf-8 -*-
"""
生成模拟好/坏构图的测试图片（合成图，便于先验证规则引擎逻辑是否正确）
用法：python make_tests.py
"""
from pathlib import Path

from PIL import Image, ImageDraw

SIZE = (900, 1200)  # 竖版 3:4，模拟手机拍摄
OUT = Path(__file__).parent / "tests"
OUT.mkdir(parents=True, exist_ok=True)


def new(dark=False):
    color = (40, 40, 40) if dark else (235, 235, 230)
    img = Image.new("RGB", SIZE, color)
    return img, ImageDraw.Draw(img)


def circle_at(cx, cy, r=90, fill=(30, 60, 120)):
    img, d = new()
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=fill)
    return img


# 1. 主体在正中间（坏：违反三分法）
circle_at(SIZE[0] // 2, SIZE[1] // 2).save(OUT / "01_center_bad.png")

# 2. 主体在右上三分点（好）
circle_at(int(SIZE[0] * 2 / 3), int(SIZE[1] / 3)).save(OUT / "02_thirds_good.png")

# 3. 地平线在正中间（坏：上下等分）
img, d = new(dark=False)
d.rectangle([0, SIZE[1] // 2, SIZE[0], SIZE[1]], fill=(120, 110, 90))
d.rectangle([380, SIZE[1] // 2 - 160, 520, SIZE[1] // 2], fill=(60, 50, 40))  # 远处房子
img.save(OUT / "03_horizon_mid_bad.png")

# 4. 地平线在上三分线（好：地面留大面积）
img, d = new(dark=False)
d.rectangle([0, SIZE[1] // 3, SIZE[0], SIZE[1]], fill=(120, 110, 90))
d.rectangle([380, SIZE[1] // 3 - 160, 520, SIZE[1] // 3], fill=(60, 50, 40))
img.save(OUT / "04_horizon_third_good.png")

# 5. 地平线明显倾斜（坏）
img, d = new(dark=False)
d.polygon([(0, 620), (SIZE[0], 480), (SIZE[0], SIZE[1]), (0, SIZE[1])], fill=(120, 110, 90))
img.save(OUT / "05_tilt_bad.png")

print("测试图已生成到:", OUT.resolve())
for f in sorted(OUT.glob("*.png")):
    print(" -", f.name)
