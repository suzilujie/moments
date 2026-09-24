# -*- coding: utf-8 -*-
"""
从用户手稿**原图**生成 App 图标 —— 零第三方依赖（复用 make_icon.py 的 PNG 写出）

与 make_icon.py 的根本差别：
  make_icon.py   用解析式几何"重画"一个 E，再用噪声模拟手抖
  from_sketch.py 直接**抠出用户手绘的真实轮廓**，只重填纯色
后者才是"手绘感"的唯一可靠来源：手抖、笔画粗细不匀、缺口圆头、边界的歪斜，
全部原样保留 —— 模拟出来的永远差一层。

流程：
  1) convert_source.ps1 把 JPEG 转成 BMP（本机 Python 没有 Pillow，不能直接读 JPEG）
  2) 找出画面里那块手绘黑方块的边界（降采样 + 连通域），用于定位与诊断
  3) 在方块内部按**绿度**（greenness = G − (R+B)/2）把绿色标记分割成软蒙版
     —— 用色彩而不是亮度：纸是灰的、马克笔的黑有深浅条纹与透出的纸白，
        这些在亮度上都会干扰分割，但在色彩上都属中性（绿度≈0），一票排除
  4) 蒙版去噪（只保留最大连通块）+ 轻微平滑（原图标记只有约 260×206 像素，
     要放大 2.2 倍，不平滑会看到明显的像素台阶）
  5) 用**蒙版自己的上边缘**测倾角并摆正 —— 注意不是用黑方块的边缘：
     手绘方块的边是弯的，线性拟合会被曲率带偏（实测上边缘与左边缘给出的角度
     差了 8 倍，根本不可用）
  6) 重填纯色（背景 #0B0C0E、标记 #C6E86B），同时输出"手稿原姿态"与"转 90° 正立"

用法（先跑转换脚本，再跑本脚本）：
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File convert_source.ps1
  python from_sketch.py
"""

import math
import os
import struct

import make_icon as mk

HERE = os.path.dirname(os.path.abspath(__file__))
SRC_BMP = os.path.join(HERE, "source-sketch.bmp")

TARGET_MARK_W = 0.56  # 横放时标记宽度占画布比例（与矢量版一致，便于横向比较）
TARGET_MARK_H = 0.62  # 正立时标记高度占画布比例
SS = 3  # 重采样时的每像素子采样数（抗锯齿）

SQUARE_LUMA = 110  # 手绘黑方块与纸的分界亮度
GREEN_T0 = 10.0  # 绿度下限（低于此完全算背景）
GREEN_T1 = 55.0  # 绿度上限（高于此完全算标记）

# (文件名, 是否转置, 适配方式与比例, 说明)
# 适配方式必须分两种：手稿横放时宽高比 1.36，转置成正立后变成 0.735。
# 若两版都按"宽度 56%"适配，正立版的高度会占到画布的 76%，比同门其他版本重得多 ——
# 在首页上就是"这一个图标特别大"。所以正立版按高度适配。
VARIANTS = [
    ("AppIcon-from-sketch.png", False, "w", TARGET_MARK_W,
     "手稿原姿态（脊线在上、三笔朝下）"),
    ("AppIcon-from-sketch-upright.png", True, "h", TARGET_MARK_H,
     "同一轮廓转 90° 正立"),
]
PREVIEW_NAME = "preview-from-sketch.png"


# ------------------------------------------------------------------ BMP 读取


def read_bmp(path):
    """读取未压缩 24/32 位 BMP，返回 (width, height, RGB bytearray)。"""
    with open(path, "rb") as f:
        data = f.read()
    if data[:2] != b"BM":
        raise ValueError("不是 BMP 文件（缺少 BM 头）")
    pixel_offset = struct.unpack_from("<I", data, 10)[0]
    width = struct.unpack_from("<i", data, 18)[0]
    height = struct.unpack_from("<i", data, 22)[0]
    bpp = struct.unpack_from("<H", data, 28)[0]
    compression = struct.unpack_from("<I", data, 30)[0]
    if compression != 0:
        raise ValueError("只支持未压缩 BMP，实际 compression=%d" % compression)
    if bpp not in (24, 32):
        raise ValueError("只支持 24/32 位 BMP，实际 bpp=%d" % bpp)

    top_down = height < 0
    h = abs(height)
    channel = bpp // 8
    stride = ((width * channel) + 3) // 4 * 4
    px = bytearray(width * h * 3)

    for row in range(h):
        src_row = row if top_down else (h - 1 - row)
        base = pixel_offset + src_row * stride
        raw = data[base:base + width * channel]
        dst = row * width * 3
        # BMP 通道顺序是 BGR，这里换成 RGB
        px[dst:dst + width * 3:3] = raw[2::channel]
        px[dst + 1:dst + width * 3:3] = raw[1::channel]
        px[dst + 2:dst + width * 3:3] = raw[0::channel]
    return width, h, px


def luma_at(px, width, x, y):
    i = (y * width + x) * 3
    return (px[i] * 299 + px[i + 1] * 587 + px[i + 2] * 114) // 1000


# ------------------------------------------------- 第一步：找出手绘黑方块


def find_dark_square(px, width, height):
    """
    降采样后做连通域标记，取面积最大的暗色连通块 = 手绘黑方块。

    为什么要连通域而不是"所有暗像素的外接框"：照片下方与左侧有纸张阴影，
    按外接框会被阴影拖偏；连通域能把它排除。
    """
    ds = 4
    dw = max(1, width // ds)
    dh = max(1, height // ds)

    small = bytearray(dw * dh)
    for y in range(dh):
        base = (y * ds) * width * 3
        row = y * dw
        for x in range(dw):
            i = base + (x * ds) * 3
            small[row + x] = 1 if (
                (px[i] * 299 + px[i + 1] * 587 + px[i + 2] * 114) // 1000
            ) < SQUARE_LUMA else 0

    labels = bytearray(dw * dh)
    best = None
    for start in range(dw * dh):
        if not small[start] or labels[start]:
            continue
        stack = [start]
        labels[start] = 1
        n = 0
        minx = dw
        miny = dh
        maxx = 0
        maxy = 0
        while stack:
            p = stack.pop()
            y = p // dw
            x = p - y * dw
            n += 1
            if x < minx:
                minx = x
            if x > maxx:
                maxx = x
            if y < miny:
                miny = y
            if y > maxy:
                maxy = y
            if x > 0 and small[p - 1] and not labels[p - 1]:
                labels[p - 1] = 1
                stack.append(p - 1)
            if x + 1 < dw and small[p + 1] and not labels[p + 1]:
                labels[p + 1] = 1
                stack.append(p + 1)
            if y > 0 and small[p - dw] and not labels[p - dw]:
                labels[p - dw] = 1
                stack.append(p - dw)
            if y + 1 < dh and small[p + dw] and not labels[p + dw]:
                labels[p + dw] = 1
                stack.append(p + dw)
        if best is None or n > best[0]:
            best = (n, minx, miny, maxx, maxy)

    if best is None:
        raise ValueError("没有找到暗色区域，阈值 %d 可能不合适" % SQUARE_LUMA)

    _, minx, miny, maxx, maxy = best
    return (minx * ds, miny * ds, (maxx + 1) * ds, (maxy + 1) * ds)


def report_square_edge_tilt(px, width, height, box):
    """
    量手绘方块上边缘/左边缘的倾角 —— **仅用于诊断**，不参与摆正。

    它不可靠的原因很具体：手绘方块的边是弯的（不是直线），线性拟合会把曲率
    折算成额外斜率；实测上边缘给出 −8.76°、左边缘给出 −1.12°，差 8 倍。
    留着它只是为了在日志里说明"为什么不拿它当依据"。
    """
    x0, y0, x1, y1 = box
    w = x1 - x0
    h = y1 - y0

    def first_dark_x(y, x_from, x_to):
        for x in range(x_from, x_to):
            if luma_at(px, width, x, y) < SQUARE_LUMA:
                return x
        return None

    top = []
    step = max(1, w // 120)
    for x in range(x0 + w // 5, x0 + w * 4 // 5, step):
        for y in range(y0, y0 + h // 3):
            if luma_at(px, width, x, y) < SQUARE_LUMA:
                top.append((x, y))
                break

    left = []
    step = max(1, h // 120)
    for y in range(y0 + h // 5, y0 + h * 4 // 5, step):
        x = first_dark_x(y, x0, x0 + w // 3)
        if x is not None:
            left.append((x, y))

    out = []
    for pts, swap, sign in ((top, False, 1.0), (left, True, -1.0)):
        if len(pts) < 8:
            continue
        n = len(pts)
        xs = [p[1] if swap else p[0] for p in pts]
        ys = [p[0] if swap else p[1] for p in pts]
        mx = sum(xs) / n
        my = sum(ys) / n
        den = sum((v - mx) ** 2 for v in xs)
        if den == 0:
            continue
        num = sum((xs[i] - mx) * (ys[i] - my) for i in range(n))
        out.append((math.degrees(math.atan(sign * num / den)), n))
    detail = " ".join("%+.2f°(%d点)" % (a, n) for a, n in out)
    print("  方块边缘倾角（仅诊断，不采用）：%s" % detail)


# ------------------------------------------- 第二步：按绿度分割出绿色标记


def build_alpha(px, width, box):
    """在方块内部按绿度生成软蒙版（255 = 标记，0 = 背景）。"""
    x0, y0, x1, y1 = box
    w = x1 - x0
    h = y1 - y0
    # 内缩，避开手绘方块边缘的黑白过渡带（那条带上的像素既非纸也非纯黑）
    inset_x = int(w * 0.06)
    inset_y = int(h * 0.06)
    x0 += inset_x
    x1 -= inset_x
    y0 += inset_y
    y1 -= inset_y

    aw = x1 - x0
    ah = y1 - y0
    alpha = bytearray(aw * ah)
    span = GREEN_T1 - GREEN_T0
    peak = 0.0
    counts = [0, 0, 0, 0]
    for y in range(ah):
        base = ((y + y0) * width + x0) * 3
        row = y * aw
        for x in range(aw):
            i = base + x * 3
            green = px[i + 1] - (px[i] + px[i + 2]) * 0.5
            if green > peak:
                peak = green
            if green > 20:
                counts[0] += 1
            if green > 40:
                counts[1] += 1
            if green > 60:
                counts[2] += 1
            if green > 80:
                counts[3] += 1
            if green <= GREEN_T0:
                continue
            v = (green - GREEN_T0) / span
            alpha[row + x] = 255 if v >= 1.0 else int(v * 255.0)
    print("  绿度峰值 %.1f（阈值 %.0f~%.0f）" % (peak, GREEN_T0, GREEN_T1))
    print("  绿度 >20/40/60/80 的像素数 %d / %d / %d / %d（共 %d）"
          % (counts[0], counts[1], counts[2], counts[3], aw * ah))
    return alpha, aw, ah, x0, y0


def smooth_alpha(alpha, aw, ah):
    """
    一次 3×3 的 [1,2,1]×[1,2,1] 平滑（可分离，两遍一维）。

    原图里的标记只有约 260×206 像素，要放大 2.2 倍到图标尺寸，
    不平滑的话放大后台阶清晰可见。平滑只影响边缘 1~2 个像素，
    且对称核不会挪动边缘位置（0.5 交叉点不变）。
    """
    tmp = bytearray(aw * ah)
    for y in range(ah):
        row = y * aw
        for x in range(aw):
            a = alpha[row + (x - 1 if x > 0 else 0)]
            b = alpha[row + x]
            c = alpha[row + (x + 1 if x < aw - 1 else aw - 1)]
            tmp[row + x] = (a + 2 * b + c) >> 2
    out = bytearray(aw * ah)
    for y in range(ah):
        up = (y - 1 if y > 0 else 0) * aw
        mid = y * aw
        dn = (y + 1 if y < ah - 1 else ah - 1) * aw
        for x in range(aw):
            out[mid + x] = (tmp[up + x] + 2 * tmp[mid + x] + tmp[dn + x]) >> 2
    return out


def keep_largest_component(alpha, aw, ah):
    """
    只保留面积最大的连通块，其余清零。

    JPEG 压缩会让个别远处像素的绿度偶然超过阈值，形成孤立小点；
    不清理的话，图标上会出现几粒莫名其妙的绿点 —— 而它们看起来"像是设计的一部分"，
    比明显的错误更难被发现。
    """
    seen = bytearray(aw * ah)
    best = None
    for start in range(aw * ah):
        if alpha[start] <= 128 or seen[start]:
            continue
        stack = [start]
        seen[start] = 1
        comp = []
        while stack:
            p = stack.pop()
            comp.append(p)
            y = p // aw
            x = p - y * aw
            if x > 0 and alpha[p - 1] > 128 and not seen[p - 1]:
                seen[p - 1] = 1
                stack.append(p - 1)
            if x + 1 < aw and alpha[p + 1] > 128 and not seen[p + 1]:
                seen[p + 1] = 1
                stack.append(p + 1)
            if y > 0 and alpha[p - aw] > 128 and not seen[p - aw]:
                seen[p - aw] = 1
                stack.append(p - aw)
            if y + 1 < ah and alpha[p + aw] > 128 and not seen[p + aw]:
                seen[p + aw] = 1
                stack.append(p + aw)
        if best is None or len(comp) > len(best):
            best = comp

    if best is None:
        return alpha, 0, 0

    keep = bytearray(aw * ah)
    for p in best:
        keep[p] = 1
    removed = 0
    dropped = 0
    for i in range(aw * ah):
        if alpha[i] and not keep[i]:
            if alpha[i] > 128:
                dropped += 1
            alpha[i] = 0
            removed += 1
    return alpha, len(best), dropped


def harden_interior(alpha, aw, ah):
    """
    把标记内部的半透明像素补满。

    原因：绿色是马克笔涂的，笔触内部本身有浓淡，再叠加 JPEG 噪点，内部会存在
    一片片"绿度不足 55"的像素；按软蒙版渲染出来就是内部深浅不匀的斑块 ——
    看起来像是设计上加了纹理，其实只是素材噪声，很容易被当成有意为之。

    做法：从包围盒边界做一次"外部"洪泛（阈值 128），凡洪泛到不了的像素即内部，
    一律补为 255。洪泛必须**从边界开始**、而不是"按面积判断内外"：两个缺口是
    朝下开口的，与外界连通，因此天然不会被误补成实心。
    """
    outside = bytearray(aw * ah)
    stack = []
    for x in range(aw):
        for y in (0, ah - 1):
            i = y * aw + x
            if alpha[i] < 128 and not outside[i]:
                outside[i] = 1
                stack.append(i)
    for y in range(ah):
        for x in (0, aw - 1):
            i = y * aw + x
            if alpha[i] < 128 and not outside[i]:
                outside[i] = 1
                stack.append(i)

    while stack:
        p = stack.pop()
        y = p // aw
        x = p - y * aw
        if x > 0 and alpha[p - 1] < 128 and not outside[p - 1]:
            outside[p - 1] = 1
            stack.append(p - 1)
        if x + 1 < aw and alpha[p + 1] < 128 and not outside[p + 1]:
            outside[p + 1] = 1
            stack.append(p + 1)
        if y > 0 and alpha[p - aw] < 128 and not outside[p - aw]:
            outside[p - aw] = 1
            stack.append(p - aw)
        if y + 1 < ah and alpha[p + aw] < 128 and not outside[p + aw]:
            outside[p + aw] = 1
            stack.append(p + aw)

    filled = 0
    for i in range(aw * ah):
        if not outside[i] and alpha[i] < 255:
            alpha[i] = 255
            filled += 1
    return alpha, filled


def mask_points(alpha, aw, ah, ox, oy):
    """取蒙版中"确定属于标记"的像素坐标（源图坐标系），用于求包围盒与质心。"""
    pts = []
    for y in range(ah):
        row = y * aw
        for x in range(aw):
            if alpha[row + x] > 128:
                pts.append((x + ox, y + oy))
    return pts


# ------------------------------------------------------- 第三步：摆正（自校正）


def _rotate(px, py, cx, cy, phi):
    dx = px - cx
    dy = py - cy
    cos_p = math.cos(phi)
    sin_p = math.sin(phi)
    return dx * cos_p - dy * sin_p, dx * sin_p + dy * cos_p


def _fit_slope(pts):
    n = len(pts)
    mx = sum(p[0] for p in pts) / n
    my = sum(p[1] for p in pts) / n
    den = sum((p[0] - mx) ** 2 for p in pts)
    if den == 0:
        return None
    num = sum((p[0] - mx) * (p[1] - my) for p in pts)
    return num / den


def _top_edge_after(alpha, aw, ah, ox, oy, cx, cy, phi):
    """取蒙版上边缘（每列第一个标记像素）并旋转 phi 后的点集。"""
    pts = []
    lo = int(aw * 0.12)
    hi = int(aw * 0.88)
    for x in range(lo, hi):
        for y in range(ah):
            if alpha[y * aw + x] > 128:
                pts.append(_rotate(x + ox, y + oy, cx, cy, phi))
                break
    return pts


def resolve_tilt(alpha, aw, ah, ox, oy, cx, cy):
    """
    用**蒙版自己的上边缘**确定摆正角，并自校正方向。

    两个刻意的设计：
      1) 不拿手绘黑方块的边缘当依据 —— 那条边是弯的，线性拟合会被曲率带偏
         （实测上边缘 −8.76°、左边缘 −1.12°，差 8 倍，不可用）；
      2) 不靠符号约定推断"该往哪边转" —— 图像坐标 y 向下，正向/反向的符号
         极容易写反（第一版就写反了，结果把 −9° 变成了 +9°）。这里直接试
         +θ 与 −θ 两个方向，取让上边缘斜率绝对值最小的那个，用结果说话。
    """
    base = _top_edge_after(alpha, aw, ah, ox, oy, cx, cy, 0.0)
    if len(base) < 20:
        print("  上边缘样本不足（%d 点），不做摆正" % len(base))
        return 0.0
    b0 = _fit_slope(base)
    theta = math.atan(b0)
    print("  上边缘原始斜率 %.4f（%.2f°）" % (b0, math.degrees(theta)))

    best = None
    for phi in (theta, -theta):
        pts = _top_edge_after(alpha, aw, ah, ox, oy, cx, cy, phi)
        b = _fit_slope(pts)
        if b is None:
            continue
        print("    试 phi=%+.2f° → 上边缘斜率 %.4f（%.2f°）"
              % (math.degrees(phi), b, math.degrees(math.atan(b))))
        if best is None or abs(b) < abs(best[1]):
            best = (phi, b)
    if best is None:
        return 0.0
    print("  采用 phi=%+.2f°（残余斜率 %.4f）" % (math.degrees(best[0]), best[1]))
    return best[0]


# ----------------------------------------------------------- 第四步：重采样


def bilinear(alpha, aw, ah, fx, fy):
    if fx <= -1.0 or fy <= -1.0 or fx >= aw or fy >= ah:
        return 0.0
    x0 = int(math.floor(fx))
    y0 = int(math.floor(fy))
    tx = fx - x0
    ty = fy - y0
    x1 = x0 + 1
    y1 = y0 + 1
    if x0 < 0:
        x0 = 0
    if y0 < 0:
        y0 = 0
    if x1 > aw - 1:
        x1 = aw - 1
    if y1 > ah - 1:
        y1 = ah - 1
    a = alpha[y0 * aw + x0]
    b = alpha[y0 * aw + x1]
    c = alpha[y1 * aw + x0]
    d = alpha[y1 * aw + x1]
    top = a + (b - a) * tx
    bot = c + (d - c) * tx
    return (top + (bot - top) * ty) / 255.0


def make_sampler(size, alpha, aw, ah, ox, oy, cx, cy, phi, span_x, span_y,
                 lx_min, ly_min, upright, fit_mode, fit_ratio):
    """
    返回该尺寸下的采样函数：图标画布坐标 (X, Y) → 蒙版覆盖率。

    正变换为「旋转摆正 → 可选转置 → 缩放」，这里实现它的逆映射。
    """
    span = span_x if fit_mode == "w" else span_y
    scale = fit_ratio * size / span
    inv = 1.0 / scale
    off_x = -lx_min - span_x * 0.5
    off_y = -ly_min - span_y * 0.5
    cos_p = math.cos(phi)
    sin_p = math.sin(phi)
    half = size * 0.5

    def sample(X, Y):
        lx = (X - half) * inv - off_x
        ly = (Y - half) * inv - off_y
        if upright:
            lx, ly = ly, lx
        # 逆旋转：把"已摆正"的局部坐标转回源图坐标
        sx = cx + lx * cos_p + ly * sin_p
        sy = cy - lx * sin_p + ly * cos_p
        return bilinear(alpha, aw, ah, sx - ox, sy - oy)

    return sample


def render_icon(size, sample, mark):
    """把蒙版渲染成图标：背景纯色 + 标记纯色，SS×SS 子采样抗锯齿。"""
    out = bytearray()
    step = 1.0 / SS
    half = step / 2.0
    total = SS * SS
    for py in range(size):
        out.append(0)
        for px in range(size):
            cov = 0.0
            for j in range(SS):
                sy = py + j * step + half
                for i in range(SS):
                    cov += sample(px + i * step + half, sy)
            cov /= total
            if cov <= 0.0:
                out += bytes(mk.BG)
            elif cov >= 1.0:
                out += bytes(mark)
            else:
                out += bytes(
                    (
                        int(round(mk.BG[0] + (mark[0] - mk.BG[0]) * cov)),
                        int(round(mk.BG[1] + (mark[1] - mk.BG[1]) * cov)),
                        int(round(mk.BG[2] + (mark[2] - mk.BG[2]) * cov)),
                    )
                )
    return out


def compose_preview(factories, mark, path):
    """
    按行排开若干姿态，每行给 256 / 180 / 120 / 60 px 四个尺寸。

    这里收的必须是**工厂函数**而不是构造好的采样器：第一版直接收了为 1024 画布
    构造的采样闭包，缩到 256 时它仍按 1024 的尺度换算，结果全部落在蒙版之外，
    预览图整片纯黑 —— 而"预览图黑掉"看起来像素材坏了，很容易往错误方向查。
    """
    items = mk.PREVIEW_ITEMS
    row_h = mk.PREVIEW_ROW_H
    top = mk.PREVIEW_TOP
    height = top * 2 + row_h * len(factories)
    canvas = bytearray(bytes(mk.PREVIEW_BG) * (mk.PREVIEW_W * height))
    radius_r = mk.rounded_mask_ratio()

    for row, factory in enumerate(factories):
        row_top = top + row * row_h
        for size, ox in items:
            oy = row_top + (row_h - size) // 2
            radius = size * radius_r
            icon = render_icon(size, factory(size), mark)
            stride = size * 3 + 1
            for y in range(size):
                src_row = y * stride + 1
                cy = y + 0.5
                dst_row = ((oy + y) * mk.PREVIEW_W + ox) * 3
                for x in range(size):
                    if not mk.in_round_corner(x + 0.5, cy, size, radius):
                        continue
                    s = src_row + x * 3
                    d = dst_row + x * 3
                    canvas[d] = icon[s]
                    canvas[d + 1] = icon[s + 1]
                    canvas[d + 2] = icon[s + 2]

    raw = bytearray()
    for y in range(height):
        raw.append(0)
        raw += canvas[y * mk.PREVIEW_W * 3:(y + 1) * mk.PREVIEW_W * 3]
    return mk.write_png(path, mk.PREVIEW_W, height, raw)


# ---------------------------------------------------------------------- 主流程


def local_bounds(pts, cx, cy, phi, upright):
    """把蒙版像素变换到"已摆正"的局部坐标系，返回包围盒（可选转置后再取）。"""
    lx_min = ly_min = 1e9
    lx_max = ly_max = -1e9
    for p in pts:
        lx, ly = _rotate(p[0], p[1], cx, cy, phi)
        if upright:
            lx, ly = ly, lx
        if lx < lx_min:
            lx_min = lx
        if lx > lx_max:
            lx_max = lx
        if ly < ly_min:
            ly_min = ly
        if ly > ly_max:
            ly_max = ly
    return lx_min, ly_min, lx_max - lx_min, ly_max - ly_min


def main():
    if not os.path.exists(SRC_BMP):
        raise SystemExit("缺少 source-sketch.bmp，请先运行 convert_source.ps1")

    width, height, px = read_bmp(SRC_BMP)
    print("source %d x %d" % (width, height))

    box = find_dark_square(px, width, height)
    print("黑方块 bbox %s（%d x %d）" % (box, box[2] - box[0], box[3] - box[1]))
    report_square_edge_tilt(px, width, height, box)

    alpha, aw, ah, ox, oy = build_alpha(px, width, box)
    alpha = smooth_alpha(alpha, aw, ah)
    alpha, kept, dropped = keep_largest_component(alpha, aw, ah)
    print("  连通块清理：保留 %d 像素，清掉 %d 个噪声点" % (kept, dropped))
    alpha, filled = harden_interior(alpha, aw, ah)
    print("  内部补满：%d 个像素由半透明补为实心" % filled)

    pts = mask_points(alpha, aw, ah, ox, oy)
    if len(pts) < 200:
        raise SystemExit("蒙版像素过少（%d），绿度阈值可能不合适" % len(pts))

    cx = sum(p[0] for p in pts) / float(len(pts))
    cy = sum(p[1] for p in pts) / float(len(pts))
    minx = min(p[0] for p in pts)
    maxx = max(p[0] for p in pts)
    miny = min(p[1] for p in pts)
    maxy = max(p[1] for p in pts)
    print("标记 %d 像素，bbox %d x %d，质心 (%.0f, %.0f)"
          % (len(pts), maxx - minx + 1, maxy - miny + 1, cx, cy))

    phi = resolve_tilt(alpha, aw, ah, ox, oy, cx, cy)

    factories = []
    for name, upright, fit_mode, fit_ratio, desc in VARIANTS:
        lx_min, ly_min, span_x, span_y = local_bounds(pts, cx, cy, phi, upright)
        print("  摆正后 %d x %d（宽高比 %.3f）%s，按%s适配到 %.0f%%"
              % (span_x, span_y, span_x / span_y, "已转置" if upright else "",
                 "宽" if fit_mode == "w" else "高", fit_ratio * 100))

        def factory(size, _upright=upright, _sx=span_x, _sy=span_y, _lx=lx_min,
                    _ly=ly_min, _mode=fit_mode, _ratio=fit_ratio):
            return make_sampler(size, alpha, aw, ah, ox, oy, cx, cy, phi,
                                _sx, _sy, _lx, _ly, _upright, _mode, _ratio)

        icon = render_icon(1024, factory(1024), mk.LIME_SOFT)
        n = mk.write_png(os.path.join(HERE, name), 1024, 1024, icon)
        print("wrote %-34s %8d bytes  %s" % (name, n, desc))
        del icon
        factories.append(factory)

    n = compose_preview(factories, mk.LIME_SOFT, os.path.join(HERE, PREVIEW_NAME))
    print("wrote %-34s %8d bytes  首页尺寸预览（上：原姿态 / 下：正立）"
          % (PREVIEW_NAME, n))


if __name__ == "__main__":
    main()
