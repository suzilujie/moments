# -*- coding: utf-8 -*-
"""
时刻（Moments）App 图标生成器 —— 零第三方依赖（只用标准库 zlib / struct）

设计来源：用户手绘稿「近黑方块 + 青柠绿、笔画很粗的字母 E」

  · 形态：字母 E 用"三笔加脊线"的块面写法 —— 由「横带 ∪ 三条腿 ∪ 四处填角」
    纯并集构成（缺口顶端因此是半圆，而不是直角）
  · 朝向：几何一律先按"横放"（脊线在上、三笔朝下）构造，再决定是否转置成正立。
    转置（transpose，x↔y 互换）是它自己的逆运算，于是"正立 E"不需要另一套几何，
    只多一次坐标交换。
  · 手绘感：解析式几何的边是数学直线与正圆，干净得不像手画。这里用三重手段拿回手感：
      ① 低频噪声位移（wobble）：按平滑随机场把采样点挪开，边界就成了手抖的曲线
      ② 圆头笔端 + 腿长微差（手绘时三条腿不可能等长）
      ③ 整体微倾 2°（手写几乎不可能完全水平）
    三者都是参数：抖动 14 px / 倾斜 2° 是 2026-09-24 定稿时选定的力道
    （更轻则像纯几何，更重则在 60 px 首页尺寸下边缘发毛）。
    随机场固定种子，因此同一参数每次输出的图完全一致 —— 可复现是脚本绘制的核心价值。

为什么不用图像模型生成：模型出的图带「AI生成 WORKBUDDY」水印，且烘焙在像素里、
裁不掉，做正式 App 图标直接不合格；且模型每次输出的几何不可控、不可复现。

用法：python make_icon.py
产物：本目录下 1024×1024 PNG 若干 + 首页尺寸预览图
"""

import math
import os
import struct
import zlib

# ---------------------------------------------------------------- 画布与配色

CANVAS = 1024
SS = 4  # 超采样倍数（super-sampling，用于抗锯齿 anti-aliasing）

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

# 正立时的整体放大系数：横放形态转置后变成"瘦高"（占画布宽由 56% 降到 48%），
# 不放大一点会显得比横放版单薄。
UPRIGHT_SCALE = 1.08

# ------------------------------------------------------------- 手绘参数（抖动）

GRID_STEP = 4.0  # 位移场的网格步长（1024 画布单位）
GRID_N = int(CANVAS / GRID_STEP) + 2  # 网格边长

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


def _hash01(ix, iy, seed):
    """把整数格点散列成 [0,1) 的随机数（不依赖 random 模块，便于保证可复现）。"""
    n = (ix * 374761393 + iy * 668265263 + seed * 1013904223) & 0xFFFFFFFF
    n = ((n ^ (n >> 13)) * 1274126177) & 0xFFFFFFFF
    return ((n ^ (n >> 16)) & 0xFFFF) * (1.0 / 65535.0)


def _noise(x, y, seed):
    """值噪声（value noise）：格点随机值 + 平滑插值，得到连续可导的平滑随机场。"""
    ix = int(math.floor(x))
    iy = int(math.floor(y))
    fx = x - ix
    fy = y - iy
    u = fx * fx * (3.0 - 2.0 * fx)  # smoothstep：让场在格点处导数为 0，避免出现网格棱
    v = fy * fy * (3.0 - 2.0 * fy)
    a = _hash01(ix, iy, seed)
    b = _hash01(ix + 1, iy, seed)
    c = _hash01(ix, iy + 1, seed)
    d = _hash01(ix + 1, iy + 1, seed)
    ab = a + (b - a) * u
    cd = c + (d - c) * u
    return ab + (cd - ab) * v


def _fbm(x, y, seed):
    """
    两个倍频叠加的随机场，返回约 [-1, 1]。
    低频（波长 260）负责"整条边缓慢起伏"，高频（波长 96）负责"笔触的细小不规则"。
    只放这两个倍频：再加更高频就成了毛边噪点，缩到 60 px 时会先变成脏点。
    """
    n = (_noise(x / 260.0, y / 260.0, seed) - 0.5) * 1.30
    n += (_noise(x / 96.0, y / 96.0, seed + 31) - 0.5) * 0.70
    return n


def _build_warp_field(seed):
    """
    把位移场预先算到一张 4 px 网格上。

    这一步是性能关键：直接在每个子采样点上算噪声，1024 画布要算约 460 万次，
    每次两路 fbm（各 2 次噪声、每次 4 个格点散列），纯 Python 下要一两分钟。
    先算到网格（约 6.6 万个点）再双线性插值，快一个数量级，而位移场本身是平滑的，
    插值带来的差别远小于 1 个像素。
    """
    gx = []
    gy = []
    for iy in range(GRID_N):
        row_x = []
        row_y = []
        yy = iy * GRID_STEP
        for ix in range(GRID_N):
            xx = ix * GRID_STEP
            row_x.append(_fbm(xx, yy, seed))
            row_y.append(_fbm(xx, yy, seed + 977))  # 另一路独立的场，避免位移只剩一个方向
        gx.append(row_x)
        gy.append(row_y)
    return gx, gy


def build_mark_test(size, geom, rt_ratio=0.0, rb_ratio=0.0, upright=False,
                    tilt_deg=0.0, rough=0.0, seed=7, leg_jitter=(0.0, 0.0, 0.0)):
    """
    构造「点是否在标记内」的判定函数。

    形状的关键在于**只做并集、不做减法**：
      材质 = 顶部横带 ∪ 三条腿 ∪ 四处填角（fillet）
    缺口本身不需要"挖"，它天然是三者之外的空白；而缺口顶端要成半圆，靠的是
    左右各补一块「被四分之一圆切掉一角的方块」——这就是填角的全部作用。
    曾经漏掉填角，结果缺口顶端是直角，与手稿的圆头不符；这类"少了一块"的几何
    错误不报错、不崩溃，只能靠看图发现。

    size       : 画布边长
    geom       : (笔画粗细, 缺口宽度, 标记总高)，按 1024 画布给出，内部等比缩放
    rt_ratio   : 横带两角圆角 / 笔画粗细（转置后即正立 E 的脊线两端）
    rb_ratio   : 腿末端圆角 / 笔画粗细（0 = 平切实笔，0.5 = 完全圆头 = 手绘笔端）
    upright    : 是否转置成正立 E
    tilt_deg   : 整体倾斜角（手绘的"摆不正"）
    rough      : 手抖位移幅度（1024 画布下的像素数），0 表示纯几何
    seed       : 随机场种子（固定则输出可复现）
    leg_jitter : 三条腿的长度微差（1024 画布单位，手绘时腿不可能等长）
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

    legs = []
    for i in range(3):
        lx0 = x0 + i * (t + g)
        legs.append((lx0, lx0 + t, y1 + leg_jitter[i] * s))

    counters = []
    for i in range(2):
        gx0 = x0 + t + i * (t + g)
        counters.append((gx0, gx0 + g))

    band_bottom = y0 + t  # 横带下沿
    rt = t * rt_ratio
    rb = t * rb_ratio

    # ---- 采样点的三个反向变换（倾斜 → 转置 → 手抖），顺序与显示时的正向变换相反 ----
    inv_s = CANVAS / float(size)
    cos_t = math.cos(math.radians(tilt_deg))
    sin_t = math.sin(math.radians(tilt_deg))
    mid = size / 2.0
    amp = rough * s
    field = _build_warp_field(seed) if amp > 0.0 else None

    def inside(px, py):
        # ① 反向倾斜：把采样点转回"未倾斜"的坐标系
        if tilt_deg != 0.0:
            dx = px - mid
            dy = py - mid
            px = mid + dx * cos_t + dy * sin_t
            py = mid - dx * sin_t + dy * cos_t
        # ② 反向转置：正立 E 就是横放形态的转置（转置自逆，所以同一个操作来回都成立）
        if upright:
            px, py = py, px
        # ③ 反向手抖位移：网格上双线性插值取位移量，把采样点挪开
        if field is not None:
            gx = px * inv_s / GRID_STEP
            gy = py * inv_s / GRID_STEP
            i = int(gx)
            j = int(gy)
            if i < 0:
                i = 0
            elif i > GRID_N - 2:
                i = GRID_N - 2
            if j < 0:
                j = 0
            elif j > GRID_N - 2:
                j = GRID_N - 2
            ux = gx - i
            uy = gy - j
            row0 = field[0][j]
            row1 = field[0][j + 1]
            a = row0[i] + (row0[i + 1] - row0[i]) * ux
            b = row1[i] + (row1[i + 1] - row1[i]) * ux
            wx = a + (b - a) * uy
            row0 = field[1][j]
            row1 = field[1][j + 1]
            a = row0[i] + (row0[i + 1] - row0[i]) * ux
            b = row1[i] + (row1[i + 1] - row1[i]) * ux
            wy = a + (b - a) * uy
            px -= wx * amp
            py -= wy * amp

        # 1) 顶部横带
        if in_rect(px, py, x0, y0, x1, band_bottom, rt, 0.0):
            return True
        # 2) 三条腿
        for lx0, lx1, ly1 in legs:
            if in_rect(px, py, lx0, y0, lx1, ly1, 0.0, rb):
                return True
        # 3) 缺口顶端的填角：方块减掉四分之一圆，补上后缺口顶端才是半圆
        for gx0, gx1 in counters:
            r = (gx1 - gx0) / 2.0
            cy = band_bottom + r
            if py < band_bottom or py > cy:
                continue
            if gx0 <= px <= gx0 + r:
                if (px - (gx0 + r)) ** 2 + (py - cy) ** 2 > r * r:
                    return True
            if gx1 - r <= px <= gx1:
                if (px - (gx1 - r)) ** 2 + (py - cy) ** 2 > r * r:
                    return True
        return False

    # 外接框（先按显示朝向取正，再按手抖与倾斜的余量外扩），用于跳过明显在标记外的像素
    ax0, ay0, ax1, ay1 = x0, y0, x1, y1
    if upright:
        ax0, ay0, ax1, ay1 = y0, x0, y1, x1
    margin = 2.0 * amp + size * 0.035 + 2.0
    bbox = (int(ax0 - margin) - 1, int(ay0 - margin) - 1,
            int(ax1 + margin) + 2, int(ay1 + margin) + 2)
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

    注意宽高必须分别传入：曾把两个字段写成同一个值，于是预览图被声明成 940×940
    而像素数据只有 420 行，解码后下半张全黑 —— 这类错误不抛异常，只是"图不对"。
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
PREVIEW_ROW_H = 300
PREVIEW_TOP = 20
PREVIEW_ITEMS = [(256, 40), (180, 340), (120, 556), (60, 710)]  # (边长, 左上角 x)


def rounded_mask_ratio():
    """iOS 图标蒙版是超椭圆（squircle），用 0.2237 的圆角矩形近似即可。"""
    return 0.2237


def in_round_corner(x, y, size, radius):
    if x < 0 or y < 0 or x > size or y > size:
        return False
    cx = min(max(x, radius), size - radius)
    cy = min(max(y, radius), size - radius)
    return (x - cx) ** 2 + (y - cy) ** 2 <= radius * radius


def compose_preview(configs, path):
    """
    把若干方案按行排开，每行给 256 / 180 / 120 / 60 px 四个尺寸。

    这张图比 1024 原图更能说明问题：图标最终只有拇指大小，
    缩小后能不能认出来才算数，手绘抖动是否"发毛"也只能在这里判断。
    """
    r = rounded_mask_ratio()
    height = PREVIEW_TOP * 2 + PREVIEW_ROW_H * len(configs)
    canvas = bytearray(bytes(PREVIEW_BG) * (PREVIEW_W * height))

    for row, cfg in enumerate(configs):
        row_top = PREVIEW_TOP + row * PREVIEW_ROW_H
        for size, ox in PREVIEW_ITEMS:
            oy = row_top + (PREVIEW_ROW_H - size) // 2
            radius = size * r
            # 每个尺寸都要按自己的边长重建几何：曾把 1024 画布算出的判定函数与
            # 外接框直接套到 256 上，结果全部落在框外，图标渲染成一块纯背景色。
            inside, bbox = build_mark_test(
                size, cfg["geom"], cfg.get("rt", 0.0), cfg.get("rb", 0.0),
                cfg.get("upright", False), cfg.get("tilt", 0.0),
                cfg.get("rough", 0.0), cfg.get("seed", 7), cfg.get("leg_jitter", (0.0, 0.0, 0.0)),
            )
            icon = render(size, inside, bbox, cfg.get("mark", LIME_SOFT))
            stride = size * 3 + 1  # render 的输出每行带 1 字节过滤器前缀
            for y in range(size):
                row_start = y * stride + 1
                cy = y + 0.5
                dest_row = ((oy + y) * PREVIEW_W + ox) * 3
                for x in range(size):
                    if not in_round_corner(x + 0.5, cy, size, radius):
                        continue
                    src = row_start + x * 3
                    dst = dest_row + x * 3
                    canvas[dst] = icon[src]
                    canvas[dst + 1] = icon[src + 1]
                    canvas[dst + 2] = icon[src + 2]

    raw = bytearray()
    for y in range(height):
        raw.append(0)
        raw += canvas[y * PREVIEW_W * 3:(y + 1) * PREVIEW_W * 3]
    return write_png(path, PREVIEW_W, height, raw)


# ---------------------------------------------------------------- 渲染方案表


def scaled(geom, k):
    return (geom[0] * k, geom[1] * k, geom[2] * k)


GEOM_UPRIGHT = scaled(GEOM_BOLD, UPRIGHT_SCALE)

RENDERS = [
    # ── 当前候选（2026-09-24 改版：正立 E + 手绘感）──
    dict(name="AppIcon-upright-drawn.png", geom=GEOM_UPRIGHT, mark=LIME_SOFT,
         rt=0.5, rb=0.5, upright=True, tilt=2.0, rough=14.0,
         leg_jitter=(0.0, -10.0, -3.0),
         desc="正立 E + 手绘【定稿】（抖动 14 px、圆头笔端、微倾 2°、腿长微差）"),
    dict(name="AppIcon-upright-clean.png", geom=GEOM_UPRIGHT, mark=LIME_SOFT,
         rt=0.5, rb=0.5, upright=True,
         desc="正立 E + 纯几何（对照组：不抖、不倾、腿等长）"),

    # ── 早先的横放方案（保留，便于对照与随时回退）──
    dict(name="AppIcon-1024.png", geom=GEOM_BOLD, mark=LIME_SOFT,
         desc="横放 E + 粗笔画（早先定稿）"),
    dict(name="AppIcon-1024-sketch.png", geom=GEOM_SKETCH, mark=LIME_SOFT,
         desc="横放 E + 宽缺口"),
    dict(name="AppIcon-1024-rounded.png", geom=GEOM_BOLD, mark=LIME_SOFT, rt=0.5, rb=0.5,
         desc="横放 E + 圆头笔端"),
    dict(name="AppIcon-1024-vivid.png", geom=GEOM_BOLD, mark=LIME_VIVID,
         desc="横放 E + 高饱和青柠绿"),
]

PREVIEW_NAME = "preview-upright.png"
PREVIEW_ROWS = ["AppIcon-upright-drawn.png", "AppIcon-upright-clean.png"]


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    by_name = {}

    for cfg in RENDERS:
        inside, bbox = build_mark_test(
            CANVAS, cfg["geom"], cfg.get("rt", 0.0), cfg.get("rb", 0.0),
            cfg.get("upright", False), cfg.get("tilt", 0.0),
            cfg.get("rough", 0.0), cfg.get("seed", 7), cfg.get("leg_jitter", (0.0, 0.0, 0.0)),
        )
        raw = render(CANVAS, inside, bbox, cfg["mark"])
        n = write_png(os.path.join(here, cfg["name"]), CANVAS, CANVAS, raw)
        by_name[cfg["name"]] = cfg
        print("wrote %-30s %8d bytes  %s" % (cfg["name"], n, cfg["desc"]))

    rows = [by_name[name] for name in PREVIEW_ROWS]
    n = compose_preview(rows, os.path.join(here, PREVIEW_NAME))
    print("wrote %-30s %8d bytes  首页尺寸预览（上：手绘 / 下：纯几何）" % (PREVIEW_NAME, n))


if __name__ == "__main__":
    main()
