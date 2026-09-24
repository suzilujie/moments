# -*- coding: utf-8 -*-
"""
时刻（Moments）App 图标生成器 —— 零第三方依赖（只用标准库 zlib / struct）

设计来源：用户手绘稿「近黑方块 + 青柠绿、横放的字母 E」
  · 横放的 E = 正立 E 顺时针旋转 90°：竖脊成为顶部横带，三笔成为朝下的三条腿
  · 缺口（counter）顶端为半圆，外轮廓为直角 —— 忠实手稿那种块面感
  · 依用户确认：E 只作几何标记，不承载含义，因此不加任何声波/字幕暗示

为什么用脚本画而不是用图像模型生成：
  1) 模型生成的图会带「AI生成 WORKBUDDY」水印，且烘焙进像素、裁不掉，做正式
     App 图标直接不合格；
  2) 几何（笔画粗细 / 缺口宽度 / 圆角）需要可精确复现与微调，脚本只改几个数字；
  3) 颜色可从手稿取样固定，不依赖模型每次的情绪。

用法：python make_icon.py
产物：本目录下 1024×1024 PNG 若干 + 一张首页尺寸预览图
"""

import os
import struct
import zlib

# ---------------------------------------------------------------- 画布与配色

CANVAS = 1024
SS = 4  # 超采样倍数（超采样 supersampling，用于抗锯齿 anti-aliasing）

BG = (0x0B, 0x0C, 0x0E)  # 背景：近黑中性色，不用纯黑（纯黑在 OLED 上像个洞）
LIME_SOFT = (0xC6, 0xE8, 0x6B)  # 青柠绿：贴近手稿照片取样到的柔和黄绿
LIME_VIVID = (0xB9, 0xF0, 0x3C)  # 高饱和青柠绿：首页上更跳，但离手稿更远

# ------------------------------------------------------- 几何参数（按 1024 设计）

# 两组几何，差别只在「笔画与缺口谁更宽」—— 这是手稿里最难确定、也最影响气质的一处：
#   GEOM_BOLD   笔画 128 粗于缺口 96：厚重，像一块被镂空的 E，缩小后更稳
#   GEOM_SKETCH 缺口 124 宽于笔画 104：镂空感强、疏朗，更接近手绘稿的观感
# 每组三个数 = (笔画粗细, 缺口宽度, 标记总高)；总宽由 3×笔画 + 2×缺口 推出。
GEOM_BOLD = (128, 96, 494)
GEOM_SKETCH = (104, 124, 470)

PREVIEW_BG = (0x32, 0x37, 0x3E)  # 预览图底色（模拟手机壁纸的中间调）


# ------------------------------------------------------------ 基础判定函数


def in_rect(x, y, x0, y0, x1, y1, rt=0.0, rb=0.0):
    """矩形内判定。rt = 上方两角圆角半径，rb = 下方两角圆角半径（0 表示直角）。"""
    if x < x0 or x > x1 or y < y0 or y > y1:
        return False
    if y >= y0 + rt and y <= y1 - rb:
        return True  # 落在上下圆角之外的直边区间，横向无条件算在内
    if x >= x0 + max(rt, rb) and x <= x1 - max(rt, rb):
        return True  # 落在左右圆角之外的直边区间，纵向无条件算在内
    if y < y0 + rt:
        cx = min(max(x, x0 + rt), x1 - rt)
        return (x - cx) ** 2 + (y - (y0 + rt)) ** 2 <= rt * rt
    if y > y1 - rb:
        cx = min(max(x, x0 + rb), x1 - rb)
        return (x - cx) ** 2 + (y - (y1 - rb)) ** 2 <= rb * rb
    return True


def build_mark_test(size, geom, rt_ratio, rb_ratio):
    """
    构造「点是否在标记内」的判定函数。

    关键在于**只做并集、不做减法**：
      材质 = 顶部横带 ∪ 三条腿 ∪ 四处填角（fillet）
    缺口本身不需要"挖"，它天然是三者之外的空白；而缺口顶端要成半圆，靠的是
    左右各补一块「被圆弧切掉一角的方块」——这就是填角的全部作用。

    上一版把形状建成了「横带 ∪ 三条腿」而没有填角，于是缺口顶端是直角，
    与手稿的圆头不符。这类"少了一块"的几何错误不会报错，只能靠看图发现。

    size      : 画布边长
    geom      : (笔画粗细, 缺口宽度, 标记总高)，按 1024 画布给出，内部等比缩放
    rt_ratio  : 顶部横带两角圆角 / 笔画粗细
    rb_ratio  : 腿末端两角圆角 / 笔画粗细（0 = 平切实笔，0.5 = 完全圆头）
    """
    t_len, g_len, h_len = geom
    s = size / float(CANVAS)
    t = t_len * s
    g = g_len * s
    w = 3 * t + 2 * g
    h = h_len * s

    x0 = (size - w) / 2.0
    x1 = x0 + w
    y0 = (size - h) / 2.0
    y1 = y0 + h

    legs = [
        (x0, x0 + t),
        (x0 + t + g, x0 + 2 * t + g),
        (x0 + 2 * t + 2 * g, x1),
    ]
    counters = [
        (x0 + t, x0 + t + g),
        (x0 + 2 * t + g, x0 + 2 * t + 2 * g),
    ]
    band_bottom = y0 + t  # 横带下沿
    rt = t * rt_ratio
    rb = t * rb_ratio

    def inside(x, y):
        # 1) 顶部横带：脊线在上，两角是否圆角由 rt_ratio 决定
        if in_rect(x, y, x0, y0, x1, band_bottom, rt, 0.0):
            return True
        # 2) 三条腿：末端两角是否圆角由 rb_ratio 决定
        for lx0, lx1 in legs:
            if in_rect(x, y, lx0, y0, lx1, y1, 0.0, rb):
                return True
        # 3) 缺口顶端的填角：方块减掉四分之一圆，补上后缺口顶端才是半圆
        for gx0, gx1 in counters:
            r = (gx1 - gx0) / 2.0
            cy = band_bottom + r
            if y < band_bottom or y > cy:
                continue
            if gx0 <= x <= gx0 + r:
                if (x - (gx0 + r)) ** 2 + (y - cy) ** 2 > r * r:
                    return True
            if gx1 - r <= x <= gx1:
                if (x - (gx1 - r)) ** 2 + (y - cy) ** 2 > r * r:
                    return True
        return False

    # 外接框（像素取整并外扩 1 像素），用于跳过绝大多数明显在标记外的像素
    bbox = (
        int(x0) - 1,
        int(y0) - 1,
        int(x1) + 2,
        int(y1) + 2,
    )
    return inside, bbox


# ------------------------------------------------------------------ 光栅化


def render(size, inside, bbox, mark):
    """渲染成 RGB 字节串（每像素 3 字节），抗锯齿用 SS×SS 超采样。"""
    bx0, by0, bx1, by1 = bbox
    step = 1.0 / SS
    half = step / 2.0
    total = SS * SS
    bg_line = bytes(BG) * size

    out = bytearray()
    for py in range(size):
        out.append(0)  # PNG 行过滤器类型：0（None）
        if py < by0 or py > by1:
            out += bg_line
            continue
        for px in range(size):
            if px < bx0 or px > bx1:
                out += bytes(BG)
                continue
            n = 0
            for j in range(SS):
                sy = py + j * step + half
                for i in range(SS):
                    if inside(px + i * step + half, sy):
                        n += 1
            if n == 0:
                out += bytes(BG)
            elif n == total:
                out += bytes(mark)
            else:
                a = n / float(total)
                out += bytes(
                    (
                        int(round(BG[0] + (mark[0] - BG[0]) * a)),
                        int(round(BG[1] + (mark[1] - BG[1]) * a)),
                        int(round(BG[2] + (mark[2] - BG[2]) * a)),
                    )
                )
    return out


def write_png(path, width, height, raw):
    """
    写出 PNG。只用到 filter 0，因此不需要第三方图像库。

    注意宽高必须分别传入：上一版两个字段都写了同一个值，
    结果预览图被声明成 940×940，而像素数据只有 420 行，
    解码时下半张只能是黑的 —— 这类错误不会报错，只会"图不对"。
    """

    def chunk(tag, data):
        body = tag + data
        return (
            struct.pack(">I", len(data))
            + body
            + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)
        )

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)  # 8bit / truecolor RGB
    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + chunk(b"IEND", b"")
    )
    with open(path, "wb") as f:
        f.write(png)
    return len(png)


# ------------------------------------------------------------------ 预览图

PREVIEW_W = 940
PREVIEW_H = 420
PREVIEW_ITEMS = [(256, 40), (180, 340), (120, 556), (60, 710)]  # (边长, 左上角 x)


def rounded_mask_ratio():
    """iOS 图标蒙版是超椭圆（squircle），用 0.2237 的圆角矩形近似即可。"""
    return 0.2237


def compose_preview(mark, path, geom, rt_ratio, rb_ratio):
    r = rounded_mask_ratio()
    canvas = bytearray(bytes(PREVIEW_BG) * (PREVIEW_W * PREVIEW_H))

    for size, ox in PREVIEW_ITEMS:
        oy = (PREVIEW_H - size) // 2
        radius = size * r
        # 每种尺寸都要按自己的边长重建几何：
        # 上一版把 1024 画布算出的判定函数与外接框直接套到 256 上，
        # 结果全部落在框外，图标渲染成一块纯背景色 —— 预览图因此毫无意义。
        inside, bbox = build_mark_test(size, geom, rt_ratio, rb_ratio)
        icon = render(size, inside, bbox, mark)
        # render 的输出带每行 1 字节的过滤器前缀，读取时要按 3*size+1 跨过
        stride = size * 3 + 1
        for y in range(size):
            row_start = y * stride + 1
            cy = y + 0.5
            for x in range(size):
                if not in_round_corner(x + 0.5, cy, size, radius):
                    continue
                s = row_start + x * 3
                d = ((oy + y) * PREVIEW_W + (ox + x)) * 3
                canvas[d] = icon[s]
                canvas[d + 1] = icon[s + 1]
                canvas[d + 2] = icon[s + 2]

    raw = bytearray()
    for y in range(PREVIEW_H):
        raw.append(0)
        raw += canvas[y * PREVIEW_W * 3 : (y + 1) * PREVIEW_W * 3]
    return write_png(path, PREVIEW_W, PREVIEW_H, raw)


def in_round_corner(x, y, size, radius):
    if x < 0 or y < 0 or x > size or y > size:
        return False
    cx = min(max(x, radius), size - radius)
    cy = min(max(y, radius), size - radius)
    return (x - cx) ** 2 + (y - cy) ** 2 <= radius * radius


# ---------------------------------------------------------------------- 主流程

VARIANTS = [
    # (文件名, 几何, 标记颜色, 顶角圆角比例, 腿端圆角比例, 说明)
    ("AppIcon-1024.png", GEOM_BOLD, LIME_SOFT, 0.0, 0.0, "粗笔画 + 柔和青柠绿（推荐：厚重、缩小后最稳）"),
    ("AppIcon-1024-sketch.png", GEOM_SKETCH, LIME_SOFT, 0.0, 0.0, "宽缺口 + 柔和青柠绿（最接近手稿的疏朗感）"),
    ("AppIcon-1024-rounded.png", GEOM_BOLD, LIME_SOFT, 0.5, 0.5, "粗笔画 + 圆头笔端（更接近马克笔的手感）"),
    ("AppIcon-1024-vivid.png", GEOM_BOLD, LIME_VIVID, 0.0, 0.0, "粗笔画 + 高饱和青柠绿（首页更跳）"),
]


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    for name, geom, mark, rt, rb, desc in VARIANTS:
        inside, bbox = build_mark_test(CANVAS, geom, rt, rb)
        raw = render(CANVAS, inside, bbox, mark)
        path = os.path.join(here, name)
        n = write_png(path, CANVAS, CANVAS, raw)
        print("wrote %-28s %8d bytes  RGB(%d,%d,%d)  %s" % (name, n, mark[0], mark[1], mark[2], desc))

    for name, geom in (("preview.png", GEOM_BOLD), ("preview-sketch.png", GEOM_SKETCH)):
        n = compose_preview(LIME_SOFT, os.path.join(here, name), geom, 0.0, 0.0)
        print("wrote %-28s %8d bytes  首页尺寸预览（256/180/120/60 px）" % (name, n))


if __name__ == "__main__":
    main()
