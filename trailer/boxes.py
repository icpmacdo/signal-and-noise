"""Explainer for os/ (34 s, 1920x1080): where the Mac app's ad finder is, and what the Vision Jev
Box thread (@lillyguisnet's beetle tests, @lotusfracture's notes, Oct 16-17) suggests doing next.
Same engine as build.py: paper, procedural watercolor, New York type; the score uses piano.py.

The screen is a schematic, not a capture. The two percentages are from os/README.md ("Tuning the
zoomed look", 2026-10-09). Everything after "THE TRICK" is a proposal and has not been run.

    uv run --no-project --with opencv-python-headless --with numpy --with pillow --with scipy \
        python trailer/boxes.py [--preview]   ->  trailer/out/os-boxes.mp4
"""
import math
import subprocess
import sys
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build as B  # noqa: E402
import piano as P  # noqa: E402

W, H, FPS, LEN = B.W, B.H, 30, 34.0
OUT = B.OUT
prog, eo, eio, env = B.prog, B.ease_out, B.ease_in_out, B.env
INK, GREY, PAPER = B.INK, B.GREY, B.PAPER
VER, PRU, OCH = B.VERMILION, B.PRUSSIAN, B.OCHRE
OCH_INK = np.array([0.62, 0.42, 0.10], np.float32)   # ochre dark enough to read as type
VER_INK = np.array([0.72, 0.22, 0.10], np.float32)

# os/README.md, "Tuning the zoomed look": coarse threshold 0.5 + zoomed look (the default)
RECALL, PRECISION = "65–67%", "57–60%"

# The schematic screen: 1000x625 at (140, 230), an 8x5 grid of 125-point cells, 3x3 subcells.
SX, SY, SW, SH = 140, 230, 1000, 625
CELL = SW / 8
SUB = CELL / 3
AD1 = (150, 52, 700, 64)          # leaderboard
AD2 = (730, 175, 215, 290)        # side rail
AD3 = (470, 530, 230, 62)         # inline ad the coarse grid never flags
PHOTO = (60, 265, 360, 215)       # a photo the grid wrongly flags
COARSE = [(125, 0, 750, 125), (625, 125, 375, 375), (125, 250, 125, 125)]   # merged flagged cells
CX, CW = 1220, 560                # caption column
SCENES = [(0.0, 8.2), (8.2, 14.6), (14.6, 21.0), (21.0, 28.2), (28.2, LEN)]


def rgba(c, a=255):
    return B.rgb255(c) + (int(a),)


def snap(r, s=SUB):
    x0, y0 = math.floor(r[0] / s) * s, math.floor(r[1] / s) * s
    x1, y1 = math.ceil((r[0] + r[2]) / s) * s, math.ceil((r[1] + r[3]) / s) * s
    return (x0, y0, x1 - x0, y1 - y0)


FINE = [snap(AD1), snap(AD2), (2 * SUB * 2, 7 * SUB, 2 * SUB, 2 * SUB)]


# ---------------------------------------------------------------- drawing helpers
def ink(c, segs, color, op, th=4):
    """Anti-aliased strokes blended onto the canvas."""
    if op <= 0 or not segs:
        return
    xs = [p[0] for s in segs for p in s]
    ys = [p[1] for s in segs for p in s]
    x0, y0 = max(0, int(min(xs)) - th - 2), max(0, int(min(ys)) - th - 2)
    x1, y1 = min(W, int(max(xs)) + th + 3), min(H, int(max(ys)) + th + 3)
    if x1 <= x0 or y1 <= y0:
        return
    m = np.zeros((y1 - y0, x1 - x0), np.uint8)
    for a, b in segs:
        cv2.line(m, (int(round((a[0] - x0) * 16)), int(round((a[1] - y0) * 16))),
                 (int(round((b[0] - x0) * 16)), int(round((b[1] - y0) * 16))), 255, th, cv2.LINE_AA, shift=4)
    a_ = (m.astype(np.float32) / 255 * op)[..., None]
    reg = c[y0:y1, x0:x1]
    reg[:] = reg * (1 - a_) + color * a_


def rect_path(r, pad=0):
    x, y, w, h = r[0] + SX - pad, r[1] + SY - pad, r[2] + 2 * pad, r[3] + 2 * pad
    return [(x, y), (x + w, y), (x + w, y + h), (x, y + h), (x, y)]


def partial(pts, p):
    """The first `p` (0..1) of a polyline, as segments."""
    lens = [math.dist(a, b) for a, b in zip(pts, pts[1:])]
    left, out = sum(lens) * p, []
    for (a, b), ln in zip(zip(pts, pts[1:]), lens):
        if left <= 0:
            break
        f = min(1.0, left / ln)
        out.append((a, (a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f)))
        left -= ln
    return out


def dashed(pts, dash=14, gap=10):
    out = []
    for a, b in zip(pts, pts[1:]):
        ln = math.dist(a, b)
        d = 0.0
        while d < ln:
            e = min(ln, d + dash)
            out.append(((a[0] + (b[0] - a[0]) * d / ln, a[1] + (b[1] - a[1]) * d / ln),
                        (a[0] + (b[0] - a[0]) * e / ln, a[1] + (b[1] - a[1]) * e / ln)))
            d += dash + gap
    return out


def box(c, t, r, t0, color=PRU, op=1.0, th=4, dur=0.55):
    ink(c, partial(rect_path(r, 6), eio(prog(t, t0, t0 + dur))), color, op, th)


def para(text, font, width, color=INK, lh=None):
    lines = B.wrap(text, font, width)
    asc, desc = font.getmetrics()
    lh = lh or int((asc + desc) * 1.12)
    img = Image.new("RGBA", (width + 16, lh * len(lines) + 16), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    for i, ln in enumerate(lines):
        d.text((8, 8 + i * lh), ln, font=font, fill=rgba(color))
    return B.Layer(img)


def chip(text, color=INK, k=1.0):
    f = B.av(int(30 * k), "demi")
    w, h = int(f.getlength(text) + 48 * k), int(58 * k)
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((1, 1, w - 2, h - 2), radius=h // 2, fill=(255, 255, 255, 150), outline=rgba(color, 170), width=2)
    d.text((int(24 * k), int(11 * k)), text, font=f, fill=rgba(color))
    return B.Layer(img)


def fill_layer(w, h, color, a=255):
    return B.Layer(Image.new("RGBA", (int(w), int(h)), rgba(color, a)))


def rr_wash(r, color, seed, strength=0.5):
    x, y, w, h = r
    return B.Wash(B.blob_mask(int(w), int(h), "rr", 8), SX + x, SY + y, color, seed, strength=strength,
                  origin=(0, h / 2), warp=4, rim=1.2)


# ---------------------------------------------------------------- the schematic screen
def screen_layer():
    o = 4
    img = Image.new("RGBA", (SW + 2 * o, SH + 2 * o), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    def R(r):
        return (o + r[0], o + r[1], o + r[0] + r[2], o + r[1] + r[3])

    d.rounded_rectangle((o, o, o + SW, o + SH), radius=14, fill=(255, 255, 255, 150), outline=rgba(INK, 170), width=2)
    d.line((o, o + 36, o + SW, o + 36), fill=rgba(INK, 80), width=2)
    for i in range(3):
        d.ellipse((o + 16 + i * 20, o + 12, o + 28 + i * 20, o + 24), outline=rgba(INK, 120), width=2)
    d.rounded_rectangle(R((120, 10, 420, 17)), radius=8, fill=rgba(GREY, 45))
    # headlines and body text
    d.rounded_rectangle(R((60, 140, 560, 26)), radius=6, fill=rgba(INK, 205))
    d.rounded_rectangle(R((60, 178, 420, 26)), radius=6, fill=rgba(INK, 205))
    d.rounded_rectangle(R((60, 222, 300, 12)), radius=5, fill=rgba(GREY, 110))
    for i in range(8):
        d.rounded_rectangle(R((450, 268 + i * 27, 245 - (60 if i == 7 else 0), 10)), radius=5, fill=rgba(GREY, 105))
    for i in range(4):
        d.rounded_rectangle(R((60, 505 + i * 27, 370 - (110 if i == 3 else 0), 10)), radius=5, fill=rgba(GREY, 105))
    # a photo with mountains
    d.rectangle(R(PHOTO), fill=rgba(PRU, 40), outline=rgba(INK, 110), width=2)
    px, py = o + PHOTO[0], o + PHOTO[1]
    d.polygon([(px, py + 215), (px + 120, py + 95), (px + 190, py + 160), (px + 260, py + 70), (px + 360, py + 215)], fill=rgba(PRU, 70))
    d.ellipse((px + 270, py + 30, px + 310, py + 70), fill=rgba(OCH, 130))
    # ads: tinted, labelled, with a call-to-action button
    f = B.av(18, "demi")
    for ad in (AD1, AD2, AD3):
        x0, y0, x1, y1 = R(ad)
        d.rectangle((x0, y0, x1, y1), fill=rgba(OCH, 60), outline=rgba(INK, 120), width=2)
        d.text((x0 + 8, y0 + 5), "Ad", font=f, fill=rgba(GREY))
        bw, bh = min(120, (x1 - x0) // 3), 24
        bx, by = x1 - bw - 12, y1 - bh - 10
        d.rounded_rectangle((bx, by, bx + bw, by + bh), radius=12, fill=rgba(OCH, 150))
        d.rounded_rectangle((x0 + 40, y0 + 10, x0 + 40 + min(260, (x1 - x0) // 2), y0 + 22), radius=5, fill=rgba(INK, 90))
    return B.Layer(img)


def grid_layer():
    img = Image.new("RGBA", (SW + 4, SH + 4), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    f = B.av(15, "demi")
    for i in range(9):
        x = int(round(i * CELL)) + 1
        d.line((x, 1, x, SH + 1), fill=rgba(VER, 170), width=2)
    for j in range(6):
        y = int(round(j * CELL)) + 1
        d.line((1, y, SW + 1, y), fill=rgba(VER, 170), width=2)
    for j in range(5):
        for i in range(8):
            d.text((int(i * CELL) + 6, int(j * CELL) + 4), f"{chr(65 + i)}{j + 1}", font=f, fill=rgba(VER_INK, 230))
    return B.Layer(img)


# ---------------------------------------------------------------- build every layer once
def build():
    L = {}
    L["screen"], L["grid"] = screen_layer(), grid_layer()
    kick, title = B.av(26, "demi"), B.ny(58, 560)
    heads = [("MAC APP · WHERE IT IS", "It finds ads on screen from pixels alone."),
             ("THE TRICK · VISION JEV", "Jev can answer with a box. One per question."),
             ("1 · CHECK EVERY BOX", "Checking throws out wrong boxes."),
             ("2 · PAINT OUT, ASK AGAIN", "Finding more comes from asking again."),
             ("THE PROPOSAL · NOT BUILT YET", "Two steps, each measured before it ships.")]
    L["heads"] = [(B.text_layer(k, kick, GREY, tracking=4), B.text_layer(t, title)) for k, t in heads]
    cap = B.ny(34, 450)
    L["capA"] = [para(s, cap, CW) for s in (
        "1  An 8×5 grid over the screen. The model flags the cells that show an ad.",
        "2  A zoomed look at each flagged block trims the mask to the ad's edges.",
        "3  What's left are ads the grid never flags. The zoomed look can't trim what it never saw.")]
    L["coarse"] = [rr_wash(r, VER, 40 + i, 0.42) for i, r in enumerate(COARSE)]
    L["fine"] = [rr_wash(r, VER, 60 + i, 0.55) for i, r in enumerate(FINE)]
    big, small = B.ny(60, 640), B.av(28, "medium")
    L["stats"] = [(B.text_layer(RECALL, big), B.text_layer("of ad area masked", small)),
                  (B.text_layer(PRECISION, big), B.text_layer("of the mask is ad", small))]
    L["src"] = B.text_layer("4 hand-labelled WSJ/NYT screens on a 6K display", B.av(22, "medium"), GREY)
    L["missed"] = B.text_layer("never flagged", B.ny(28, 500, italic=True), OCH_INK)
    # B: the box
    L["qWhere"] = chip("Where is an ad?")
    L["aBox"] = B.text_layer("Jev: one box, t 8%  l 15%  b 19%  r 85%", B.av(30, "demi"), PRU)
    L["capB"] = para("Name any thing and it says where it is. But it gives one box per question, so finding them all takes a loop.", cap, CW)
    L["credit"] = B.text_layer("Vision Jev 1.14 preview · from @lillyguisnet's beetle tests and @lotusfracture's notes, Oct 16–17",
                               B.av(24, "medium"), GREY)
    # C: verify
    L["qCheck"] = chip("Is the outlined box on an ad?")
    L["aDrop"] = B.text_layer("photo: no, drop it", B.av(30, "demi"), VER_INK)
    L["aKeep"] = B.text_layer("leaderboard: yes, keep it", B.av(30, "demi"), PRU)
    L["capC"] = para("In the beetle test this threw out bad boxes, found no new beetles, and lost one real one. Checking filters. It doesn't search.", cap, CW)
    tag = B.av(22, "demi")
    L["kept"], L["dropped"] = B.text_layer("kept", tag, PRU), B.text_layer("dropped", tag, VER_INK)
    # D: paint out and repeat
    q, a = B.av(30, "medium"), B.av(30, "demi")
    L["log"] = [(B.text_layer("Paint it out. Where is an ad?", q), B.text_layer("Jev: box 2", a, PRU)),
                (B.text_layer("Paint it out. Where is an ad?", q), B.text_layer("Jev: box 3, the one the grid missed", a, PRU)),
                (B.text_layer("Any ad left?", q), B.text_layer("Jev: no. Stop.", a, PRU))]
    L["capD"] = para("If a box fails its check, cut the crop in half and ask each half.", B.ny(30, 450, italic=True), CW, GREY)
    L["paint"] = [fill_layer(r[2] + 12, r[3] + 12, PAPER * 0.95) for r in (AD1, AD2)]
    L["painted"] = B.text_layer("painted out", tag, GREY)
    L["missedTag"] = B.text_layer("the grid missed this one", B.ny(26, 500, italic=True), OCH_INK)
    # E: the plan
    L["cards"] = []
    for i, (head, lines, col) in enumerate((
            ("A · Works with today's model", ["Check each mask with one yes/no question.",
                                              "Paint out what was found. Ask again about the cells nobody flagged."], PRU),
            ("B · Needs a box model", ["Vision Jev or Amos 1. Neither API has been tried yet.",
                                                    "A box per flagged block. Halve when a box fails. Stop when “any left?” says no."], OCH))):
        img = Image.new("RGBA", (780, 320), (0, 0, 0, 0))
        d = ImageDraw.Draw(img)
        d.rounded_rectangle((1, 1, 778, 318), radius=22, outline=rgba(INK, 110), width=2)
        d.text((36, 30), head, font=B.ny(44, 600), fill=rgba(INK))
        f = B.av(38, "regular")
        y = 116
        for ln in lines:
            wrapped = B.wrap(ln, f, 690)
            d.ellipse((38, y + 19, 48, y + 29), fill=rgba(INK, 200))
            for wl in wrapped:
                d.text((64, y), wl, font=f, fill=rgba(INK))
                y += 48
            y += 18
        L["cards"].append((B.Layer(img), B.Wash(B.blob_mask(780, 320, "rr", 22), 140 + i * 860, 250, col, 80 + i, strength=0.22,
                                                 origin=(0, 160), warp=8)))
    L["gate"] = B.text_layer("Ships only if it beats 65–67% recall and 57–60% precision on the labelled screens.", B.ny(44, 540))
    L["gateWash"] = B.Wash(B.swash_mask(L["gate"].w - 20, 40, 5), 150, 712, VER, 91, strength=0.35, origin=(0, 20), warp=7)
    return L


# ---------------------------------------------------------------- one frame
def frame_fn(paper, L):
    def frame(t):
        c = paper.copy()
        for (t0, t1), (kl, tl) in zip(SCENES, L["heads"]):
            op = env(t, t0, t1, 0.35) if t0 > 0 else (1 - eio(prog(t, t1 - 0.35, t1))) * eo(prog(t, 0.0, 0.4))
            if op > 0:
                k = eo(prog(t, t0 + 0.1, t0 + 0.7))
                kl.draw(c, 140, 70, op)
                tl.draw(c, 140, 102 + 12 * (1 - k), op * k)

        so = eo(prog(t, 0.3, 0.9)) * (1 - eio(prog(t, 27.8, 28.2)))
        if so > 0:
            L["screen"].draw(c, SX - 4, SY - 4, so)
            # A: coarse grid, then fine shapes
            g = 1 - eio(prog(t, 4.3, 4.9))
            gp = eio(prog(t, 1.2, 1.9))
            if gp > 0 and g > 0:
                L["grid"].draw(c, SX - 1, SY - 1, so * g * 0.9, clip_h=SH * gp + 4)
            for i, w in enumerate(L["coarse"]):
                w.draw(c, prog(t, 2.0 + 0.15 * i, 2.9 + 0.15 * i), so * g)
            fo = 1 - eio(prog(t, 7.9, 8.4))
            for i, w in enumerate(L["fine"]):
                w.draw(c, prog(t, 4.5 + 0.12 * i, 5.3 + 0.12 * i), so * fo)
            mo = eo(prog(t, 6.6, 7.0)) * (1 - eio(prog(t, 7.9, 8.4)))
            if mo > 0:
                ink(c, dashed(rect_path(AD3, 10)), OCH_INK, so * mo, 3)
                L["missed"].draw(c, SX + AD3[0] + AD3[2] + 18, SY + AD3[1] + 10, so * mo)

            # B-D: boxes, checks, painting out
            p1 = eio(prog(t, 21.4, 21.9))
            box(c, t, AD1, 9.6, PRU, so * (1 - p1))
            if t >= 15.2:
                po = 1 - eio(prog(t, 17.8, 18.2))
                box(c, t, PHOTO, 15.2, PRU, so * po)
                cross = eio(prog(t, 16.6, 17.0))
                if cross > 0:
                    a, b = rect_path(PHOTO, 6)[0], rect_path(PHOTO, 6)[2]
                    d_, e_ = rect_path(PHOTO, 6)[1], rect_path(PHOTO, 6)[3]
                    ink(c, partial([a, b], cross) + partial([d_, e_], cross), VER_INK, so * po, 4)
                    L["dropped"].draw(c, SX + PHOTO[0] + 4, SY + PHOTO[1] + 4, so * po * eo(prog(t, 16.6, 16.9)))
            ko = eo(prog(t, 16.9, 17.2)) * (1 - p1)
            L["kept"].draw(c, SX + AD1[0] + AD1[2] + 18, SY + AD1[1] + 12, so * ko)
            for ad, layer, t0 in ((AD1, L["paint"][0], 21.4), (AD2, L["paint"][1], 23.4)):
                pp = eio(prog(t, t0, t0 + 0.5))
                if pp > 0:
                    layer.draw(c, SX + ad[0] - 6, SY + ad[1] - 6, so * pp)
                    L["painted"].draw(c, SX + ad[0] + 4, SY + ad[1] + 2, so * pp * 0.9)
            box(c, t, AD2, 22.5, PRU, so * (1 - eio(prog(t, 23.4, 23.9))))
            box(c, t, AD3, 24.5, PRU, so)
            L["missedTag"].draw(c, SX + AD3[0] + AD3[2] + 18, SY + AD3[1] + 10, so * eo(prog(t, 25.0, 25.4)))

        # captions, A
        oa = 1 - eio(prog(t, 7.9, 8.2))
        y = 240
        for i, (lay, t0) in enumerate(zip(L["capA"], (1.4, 4.0, 6.6))):
            nxt = (4.0, 6.6, 99)[i]
            op = oa * eo(prog(t, t0, t0 + 0.5)) * (1 - 0.55 * eio(prog(t, nxt, nxt + 0.4)))
            lay.draw(c, CX, y + 10 * (1 - eo(prog(t, t0, t0 + 0.5))), op)
            y += lay.h + 22
        so_ = oa * eo(prog(t, 5.6, 6.1))
        if so_ > 0:
            x = 140
            for big, small in L["stats"]:
                big.draw(c, x, 870, so_)
                small.draw(c, x + big.w + 6, 900, so_)
                x += big.w + small.w + 70
            L["src"].draw(c, x, 904, so_ * 0.9)

        # B
        ob = env(t, 8.2, 14.6, 0.35)
        if ob > 0:
            L["qWhere"].draw(c, CX + 8, 250, ob * eo(prog(t, 9.0, 9.4)))
            L["aBox"].draw(c, CX + 8, 326, ob * eo(prog(t, 10.2, 10.6)))
            L["capB"].draw(c, CX, 400, ob * eo(prog(t, 10.8, 11.3)))
            L["credit"].draw(c, 140, 900, ob * eo(prog(t, 11.4, 11.9)))

        # C
        oc = env(t, 14.6, 21.0, 0.35)
        if oc > 0:
            L["qCheck"].draw(c, CX + 8, 250, oc * eo(prog(t, 15.9, 16.3)))
            L["aDrop"].draw(c, CX + 8, 330, oc * eo(prog(t, 16.6, 17.0)))
            L["aKeep"].draw(c, CX + 8, 384, oc * eo(prog(t, 16.9, 17.3)))
            L["capC"].draw(c, CX, 460, oc * eo(prog(t, 18.2, 18.7)))

        # D
        od = env(t, 21.0, 28.2, 0.35)
        if od > 0:
            y = 250
            for (ql, al), t0 in zip(L["log"], (21.9, 23.9, 25.6)):
                ql.draw(c, CX, y, od * eo(prog(t, t0, t0 + 0.4)))
                al.draw(c, CX + 28, y + 46, od * eo(prog(t, t0 + 0.6, t0 + 1.0)))
                y += 120
            L["capD"].draw(c, CX, y + 10, od * eo(prog(t, 26.6, 27.1)))

        # E
        oe = env(t, 28.2, LEN + 1, 0.4) * (1 - eio(prog(t, LEN - 0.5, LEN)))
        if oe > 0:
            for i, (lay, wash) in enumerate(L["cards"]):
                t0 = 28.7 + 0.5 * i
                k = eo(prog(t, t0, t0 + 0.6))
                wash.draw(c, prog(t, t0, t0 + 0.9), oe)
                lay.draw(c, 140 + i * 860, 250 + 14 * (1 - k), oe * k)
            L["gateWash"].draw(c, prog(t, 31.4, 32.2), oe)
            L["gate"].draw(c, 132, 640, oe * eo(prog(t, 31.0, 31.5)))
        return (np.clip(c, 0, 1) * 255).astype(np.uint8)

    return frame


# ---------------------------------------------------------------- score
def compose():
    s = P.Score(LEN)
    for a, b in ((0, 6.6), (6.6, 8.2), (8.2, 14.6), (14.6, 16.6), (16.6, 21.0), (21.0, 23.4), (23.4, 25.6),
                 (25.6, 26.1), (26.1, 28.2), (28.2, 31.2), (31.2, LEN)):
        s.pedal_down(a, b - 0.02)
    harmony = [(0.0, ["D2", "A2"], ["D3", "F#3", "A3"]), (6.6, ["B1", "F#2"], ["B2", "D3", "F#3"]),
               (8.2, ["G1", "D2"], ["G2", "B2", "D3"]), (14.6, ["A1", "E2"], ["A2", "C#3", "E3"]),
               (16.6, ["F#1", "C#2"], ["F#2", "A2", "C#3"]), (21.0, ["B1", "F#2"], ["B2", "D3", "F#3"]),
               (23.4, ["G1", "D2"], ["G2", "B2", "D3"]), (25.6, ["A1", "E2"], ["A2", "C#3", "E3"]),
               (26.1, ["D2", "A2"], ["D3", "F#3", "A3"]), (28.2, ["D1", "D2", "A2"], ["D3", "F#3", "A3", "D4"]),
               (31.2, ["G1", "D2"], ["B2", "D3", "F#3", "A3"])]
    for at, low, mid in harmony:
        s.chord(at, low, 0.42 if at == 28.2 else 0.3, hold=2)
        s.chord(at + 0.02, mid, 0.2, hold=2, roll=0.02)
    # a quiet pulse in the chord's upper tones, so the explainer never sits in silence
    tones = {0.0: ["A4", "D5"], 6.6: ["F#4", "B4"], 8.2: ["B4", "D5"], 14.6: ["C#5", "E5"], 16.6: ["A4", "C#5"],
             21.0: ["F#4", "B4"], 23.4: ["G4", "B4"], 25.6: ["A4", "E5"], 26.1: ["A4", "D5"], 28.2: ["F#4", "A4"], 31.2: ["F#4", "B4"]}
    starts = sorted(tones)
    t = 0.5
    i = 0
    while t < LEN - 1.5:
        cur = max(k for k in starts if k <= t)
        s.note(t, tones[cur][i % 2], 0.09, hold=0.3)
        t += 0.75
        i += 1
    # plucks on the events: grid, cells, trims, the box, check, each new box, stop
    for at, nm, v in ((1.2, "A5", 0.2), (2.0, "D5", 0.18), (2.15, "F#5", 0.18), (2.3, "A5", 0.18),
                      (4.5, "E5", 0.16), (4.62, "F#5", 0.16), (4.74, "A5", 0.16), (5.6, "D6", 0.2),
                      (9.6, "B5", 0.22), (10.2, "D6", 0.2), (15.2, "E5", 0.18), (16.9, "A5", 0.22),
                      (22.5, "D5", 0.2), (24.5, "F#5", 0.22), (26.1, "D6", 0.26), (31.0, "A5", 0.2), (31.4, "D6", 0.22)):
        s.note(at, nm, v, hold=0.3)
    s.chord(16.6, ["F#1"], 0.35, hold=1)        # the drop
    s.chord(32.6, ["D3", "F#3", "A3", "D4"], 0.24, hold=1.5, roll=0.05)
    return s


# ---------------------------------------------------------------- render
def main():
    preview = "--preview" in sys.argv
    OUT.mkdir(parents=True, exist_ok=True)
    print("building paper and washes…", flush=True)
    frame = frame_fn(B.make_paper(), build())
    if preview:
        times = [3.2, 7.4, 11.8, 17.6, 20.0, 25.2, 27.4, 32.6, 33.2]
        tiles = [cv2.resize(frame(t), (640, 360), interpolation=cv2.INTER_AREA) for t in times]
        Image.fromarray(np.vstack([np.hstack(tiles[i:i + 3]) for i in range(0, 9, 3)])).save(OUT / "boxes-contact.png")
        for t in (7.4, 11.8, 20.0, 27.4, 33.2):
            Image.fromarray(frame(t)).save(OUT / f"boxes-{t:04.1f}.png")
        print("wrote contact sheet")
        return
    P.LENGTH = LEN
    wav = OUT / "boxes-score.wav"
    P.write_wav(wav, P.master(compose().buf))
    out = OUT / "os-boxes.mp4"
    ff = subprocess.Popen(["ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}",
                           "-r", str(FPS), "-i", "-", "-i", str(wav), "-map", "0:v", "-map", "1:a",
                           "-c:v", "libx264", "-preset", "slow", "-crf", "17", "-pix_fmt", "yuv420p",
                           "-c:a", "aac", "-b:a", "192k", "-shortest", "-movflags", "+faststart", str(out)], stdin=subprocess.PIPE)
    n = int(LEN * FPS)
    for i in range(n):
        ff.stdin.write(frame(i / FPS).tobytes())
        if i % 90 == 0:
            print(f"frame {i}/{n}", flush=True)
    ff.stdin.close()
    ff.wait()
    Image.fromarray(frame(33.0)).save(OUT / "boxes-poster.png")
    print("wrote", out)


if __name__ == "__main__":
    main()
