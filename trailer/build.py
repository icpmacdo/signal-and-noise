"""Signal & Noise trailer: ~21 s, 1920x1080, editorial data-viz look with watercolor washes.

Watercolor is procedural (OpenCV + numpy): noise-warped masks, pigment variation, darkened rims
where pigment pools, granulation, and a wet front that bleeds outward when a wash is laid down.
Type is crisp ink over the washes. Every number on screen is read from eval/synthetic/regression.json.

    uv run --with opencv-python-headless --with numpy --with pillow python trailer/build.py [--preview]
"""
import json
import math
import subprocess
import sys
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "trailer" / "out"
W, H, FPS = 1920, 1080, 30
DUR = 21.0
N = int(DUR * FPS)

# ---------------------------------------------------------------- data (claims come from here)
REG = json.loads((ROOT / "eval/synthetic/regression.json").read_text())
TWEETS = {t["id"]: t for t in json.loads((ROOT / "eval/synthetic/tweets.json").read_text())}
D = REG["defaults"]
assert D["picked"] == ["rage", "crypto", "engage"], "trailer claims are about the three defaults"
POSTS = [p for p in D["posts"] if p["pKeep"] is not None]
N_POSTS = len(POSTS)
FINE_HIDDEN, FINE = D["fineHidden"], D["fine"]
NOISE_CAUGHT, NOISE = D["noiseCaught"], D["noise"]
MS = int(round(REG["latencyP50"] / 10.0) * 10)
MODEL = REG["model"].replace("jev-", "Jev ").rsplit(".", 1)[0]  # "Jev 1.13"

# ---------------------------------------------------------------- palette (linear-ish 0..1 RGB)
PAPER = np.array([248, 246, 241], np.float32) / 255
INK = np.array([24, 24, 28], np.float32) / 255
GREY = np.array([110, 112, 120], np.float32) / 255
VERMILION = np.array([0.86, 0.30, 0.15], np.float32)
PRUSSIAN = np.array([0.15, 0.35, 0.62], np.float32)
OCHRE = np.array([0.86, 0.64, 0.26], np.float32)
SHOW_BLUE = np.array([0.15, 0.40, 0.80], np.float32)

# ---------------------------------------------------------------- fonts
NY = "/System/Library/Fonts/NewYork.ttf"
NYI = "/System/Library/Fonts/NewYorkItalic.ttf"
AV = "/System/Library/Fonts/Avenir Next Condensed.ttc"
AV_IDX = {"bold": 0, "demi": 2, "medium": 5, "regular": 7}


def ny(size, weight=500, italic=False):
    f = ImageFont.truetype(NYI if italic else NY, size)
    f.set_variation_by_axes([min(256, max(12, size)), weight, 0])
    return f


def av(size, face="demi"):
    return ImageFont.truetype(AV, size, index=AV_IDX[face])


# ---------------------------------------------------------------- easing
def clamp(x, a=0.0, b=1.0):
    return max(a, min(b, x))


def prog(t, t0, t1):
    return clamp((t - t0) / (t1 - t0)) if t1 > t0 else float(t >= t0)


def ease_out(x):
    return 1 - (1 - x) ** 3


def ease_in_out(x):
    return 4 * x ** 3 if x < 0.5 else 1 - (-2 * x + 2) ** 3 / 2


def env(t, t_in, t_out, fade=0.35):
    """Opacity envelope: fade in from t_in, fade out ending at t_out."""
    return ease_out(prog(t, t_in, t_in + fade)) * (1 - ease_in_out(prog(t, t_out - fade, t_out)))


# ---------------------------------------------------------------- noise + paper
def fbm(h, w, scale, octaves=4, seed=0):
    r = np.random.default_rng(seed)
    out = np.zeros((h, w), np.float32)
    amp, tot, s = 1.0, 0.0, float(scale)
    for _ in range(octaves):
        gh, gw = max(2, int(h / s) + 2), max(2, int(w / s) + 2)
        g = r.standard_normal((gh, gw)).astype(np.float32)
        out += amp * cv2.resize(g, (w, h), interpolation=cv2.INTER_CUBIC)
        tot += amp
        amp *= 0.5
        s = max(1.0, s / 2)
    out /= tot
    return (out - out.mean()) / (out.std() + 1e-6)


def make_paper():
    grain = fbm(H, W, 2.5, 2, 11) * 0.008 + fbm(H, W, 160, 3, 12) * 0.005
    hmap = fbm(H, W, 5, 3, 13)
    shade = cv2.Sobel(hmap, cv2.CV_32F, 1, 1, ksize=3) * 0.004
    vign = 1 - 0.03 * ((np.linspace(-1, 1, W)[None, :] ** 2) + (np.linspace(-1, 1, H)[:, None] ** 2))
    return np.clip(PAPER[None, None, :] * (1 + grain + shade)[..., None] * vign[..., None].astype(np.float32), 0, 1)


def smoothstep(a, b, x):
    t = np.clip((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)


# ---------------------------------------------------------------- watercolor washes
class Wash:
    """A pigment layer with an organic edge, pooled rim and granulation, laid down with a wet front.

    `mask` is a float array covering the box at (x, y). `origin` is where the brush touches first,
    in mask coordinates; the wash bleeds outward from it as `progress` goes 0 -> 1.
    """

    def __init__(self, mask, x, y, color, seed, strength=0.85, origin=None, warp=7.0, rim=1.5):
        h, w = mask.shape
        pad = 24
        m = cv2.copyMakeBorder(mask.astype(np.float32), pad, pad, pad, pad, cv2.BORDER_CONSTANT, value=0)
        h2, w2 = m.shape
        gx, gy = np.meshgrid(np.arange(w2, dtype=np.float32), np.arange(h2, dtype=np.float32))
        dx = fbm(h2, w2, 26, 3, seed) * warp
        dy = fbm(h2, w2, 26, 3, seed + 1) * warp
        m = cv2.remap(m, gx + dx, gy + dy, cv2.INTER_LINEAR)
        m = cv2.GaussianBlur(m, (0, 0), 2.2)
        m = smoothstep(0.32, 0.62, m)
        body = 0.62 + 0.20 * fbm(h2, w2, 70, 3, seed + 2) + 0.08 * fbm(h2, w2, 14, 2, seed + 5)
        edge = np.clip(m - cv2.GaussianBlur(m, (0, 0), 6), 0, 1) * rim
        gran = 1 + 0.16 * fbm(h2, w2, 2.2, 2, seed + 3)
        self.d = (np.clip((m * body + edge) * gran, 0, 1.25) * strength).astype(np.float32)
        self.m = m
        ox, oy = origin if origin is not None else (w / 2, h / 2)
        dist = np.sqrt((gx - ox - pad) ** 2 + (gy - oy - pad) ** 2)
        dist /= dist[m > 0.05].max() + 1e-6 if (m > 0.05).any() else 1
        self.field = (dist + 0.12 * fbm(h2, w2, 40, 3, seed + 4)).astype(np.float32)
        self.x, self.y, self.color = int(x) - pad, int(y) - pad, color.astype(np.float32)

    def density(self, progress):
        if progress >= 1.0:
            return self.d
        p = progress * 1.18
        vis = np.clip((p - self.field) / 0.07, 0, 1)
        front = np.exp(-(((p - self.field) / 0.035) ** 2)) * 0.32 * self.m
        return self.d * vis + front

    def draw(self, canvas, progress, alpha=1.0, dy=0, clip_h=None):
        if progress <= 0 or alpha <= 0:
            return
        d = self.density(min(1.0, progress)) * alpha
        if clip_h is not None:
            d = d[: max(0, int(clip_h) + 24)]
        apply_density(canvas, d, self.x, self.y + int(dy), self.color)


def apply_density(canvas, d, x, y, color):
    x, y = int(round(x)), int(round(y))
    h, w = d.shape
    x0, y0, x1, y1 = max(0, x), max(0, y), min(W, x + w), min(H, y + h)
    if x1 <= x0 or y1 <= y0:
        return
    dd = d[y0 - y:y1 - y, x0 - x:x1 - x][..., None]
    region = canvas[y0:y1, x0:x1]
    region *= 1 - np.clip(dd, 0, 1) * (1 - color)


def blob_mask(w, h, kind="ellipse", radius=None):
    m = np.zeros((h, w), np.float32)
    if kind == "ellipse":
        cv2.ellipse(m, (w // 2, h // 2), (w // 2 - 2, h // 2 - 2), 0, 0, 360, 1.0, -1, cv2.LINE_AA)
    else:  # rounded rect
        r = radius or h // 2
        cv2.rectangle(m, (r, 0), (w - r, h - 1), 1.0, -1)
        cv2.rectangle(m, (0, r), (w - 1, h - r), 1.0, -1)
        for cx, cy in ((r, r), (w - r - 1, r), (r, h - r - 1), (w - r - 1, h - r - 1)):
            cv2.circle(m, (cx, cy), r, 1.0, -1, cv2.LINE_AA)
    return m


def swash_mask(w, h, seed):
    """A loose brush stroke, thicker in the middle, slightly rising."""
    m = np.zeros((h, w), np.float32)
    r = np.random.default_rng(seed)
    n = 60
    for i in range(n):
        u = i / (n - 1)
        x = int(8 + u * (w - 16))
        y = int(h * 0.55 - u * h * 0.10 + math.sin(u * 3.1) * h * 0.06)
        rad = int(h * (0.26 + 0.18 * math.sin(math.pi * u)) * (0.92 + 0.16 * r.random()))
        cv2.circle(m, (x, y), max(3, rad), 1.0, -1, cv2.LINE_AA)
    return m


# ---------------------------------------------------------------- type layers
class Layer:
    """Pre-rendered RGBA (float) element composited as ink over the canvas."""

    def __init__(self, img):
        a = np.asarray(img, np.float32) / 255
        self.rgb, self.a = a[..., :3], a[..., 3:4]
        self.h, self.w = self.a.shape[:2]

    def draw(self, canvas, x, y, op=1.0, clip_h=None):
        if op <= 0:
            return
        x, y = int(round(x)), int(round(y))
        h = self.h if clip_h is None else max(0, min(self.h, int(clip_h)))
        x0, y0, x1, y1 = max(0, x), max(0, y), min(W, x + self.w), min(H, y + h)
        if x1 <= x0 or y1 <= y0:
            return
        a = self.a[y0 - y:y1 - y, x0 - x:x1 - x] * op
        canvas[y0:y1, x0:x1] = canvas[y0:y1, x0:x1] * (1 - a) + self.rgb[y0 - y:y1 - y, x0 - x:x1 - x] * a


def rgb255(c):
    return tuple(int(v * 255) for v in c)


def text_layer(text, font, color=INK, tracking=0, pad=8):
    if tracking:
        widths = [font.getlength(ch) + tracking for ch in text]
        tw = int(sum(widths)) + pad * 2
    else:
        tw = int(font.getlength(text)) + pad * 2
    asc, desc = font.getmetrics()
    img = Image.new("RGBA", (tw, asc + desc + pad * 2), (0, 0, 0, 0))
    dr = ImageDraw.Draw(img)
    if tracking:
        x = pad
        for ch, wch in zip(text, widths):
            dr.text((x, pad), ch, font=font, fill=rgb255(color) + (255,))
            x += wch
    else:
        dr.text((pad, pad), text, font=font, fill=rgb255(color) + (255,))
    return Layer(img)


def clean(text):
    keep = set("…·—–’‘“”€£")
    return "".join(ch for ch in text if ord(ch) < 0x2000 or ch in keep).replace("  ", " ").strip()


def wrap(text, font, width):
    words, lines, cur = text.split(), [], ""
    for w_ in words:
        cand = (cur + " " + w_).strip()
        if font.getlength(cand) <= width or not cur:
            cur = cand
        else:
            lines.append(cur)
            cur = w_
    if cur:
        lines.append(cur)
    return lines


def card_layer(author, text, width, max_lines=3, k=1.0):
    f_who, f_txt = av(int(24 * k), "demi"), av(int(29 * k), "regular")
    text = clean(text)
    pad = int(24 * k)
    lines = wrap(text, f_txt, width - 2 * pad)[:max_lines]
    if len(wrap(text, f_txt, width - 2 * pad)) > max_lines:
        lines[-1] = lines[-1].rstrip(".,") + "…"
    lh = int(38 * k)
    h = int((24 + 34 + 22) * k) + len(lines) * lh
    img = Image.new("RGBA", (width, h), (0, 0, 0, 0))
    dr = ImageDraw.Draw(img)
    dr.rounded_rectangle((1, 1, width - 2, h - 2), radius=16, fill=(255, 255, 255, 120), outline=rgb255(INK) + (90,), width=2)
    dr.text((pad, int(18 * k)), author, font=f_who, fill=rgb255(GREY) + (255,))
    for i, ln in enumerate(lines):
        dr.text((pad, int(52 * k) + i * lh), ln, font=f_txt, fill=rgb255(INK) + (255,))
    return Layer(img), h


def bar_layer(reason, width, k=1.0):
    f = av(int(26 * k), "medium")
    h = int(58 * k)
    img = Image.new("RGBA", (width, h), (0, 0, 0, 0))
    dr = ImageDraw.Draw(img)
    dr.rounded_rectangle((1, 1, width - 2, h - 2), radius=14, fill=(255, 255, 255, 90), outline=rgb255(INK) + (60,), width=2)
    dr.text((int(24 * k), int(13 * k)), f"Hidden · {reason}", font=f, fill=rgb255(GREY) + (255,))
    fs = av(int(26 * k), "demi")
    dr.text((width - int(24 * k) - fs.getlength("Show"), int(13 * k)), "Show", font=fs, fill=rgb255(SHOW_BLUE) + (255,))
    return Layer(img)


def pill_layer(label, filled, k=1.0):
    f = av(int(38 * k), "demi")
    w = int(f.getlength(label) + 70 * k)
    h = int(80 * k)
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    dr = ImageDraw.Draw(img)
    if not filled:
        dr.rounded_rectangle((1, 1, w - 2, h - 2), radius=h // 2, outline=rgb255(INK) + (150,), width=2)
    dr.text((int(35 * k), int(16 * k)), label, font=f, fill=rgb255(INK) + (255,))
    return Layer(img), w, h


# ---------------------------------------------------------------- scene builders
def scene_feed():
    """0–4.3 s: the hook."""
    S = {}
    S["kick"] = text_layer("SIGNAL & NOISE", av(26, "demi"), GREY, tracking=4)
    f = ny(88, 560)
    S["l1"] = text_layer("Most of your feed is signal.", f)
    S["l2"] = text_layer("Some of it is noise.", f)
    pre = f.getlength("Some of it is ")
    nw = f.getlength("noise")
    sw, sh = int(nw + 60), 70
    S["swash"] = Wash(swash_mask(sw, sh, 3), 140 + 8 + pre - 30, 480 + 70, VERMILION, 21, strength=0.75, origin=(0, sh / 2), warp=9)
    # a scrolling column of posts on the right
    ids = ["s001", "s096", "s005", "s010", "s106", "s014", "s020", "s111", "s025", "s030"]
    cards, y = [], 120
    for i, tid in enumerate(ids):
        t = TWEETS.get(tid) or list(TWEETS.values())[i]
        lay, h = card_layer(t["author"], t["text"], 500, 2)
        noise = t["kind"] == "clear" and any(t["labels"][m] == 1 for m in ("m0", "m1", "m2"))
        wash = Wash(blob_mask(500, h, "rr", 16), 0, 0, VERMILION, 40 + i, strength=0.42, origin=(0, h / 2), warp=6) if noise else None
        cards.append((lay, y, wash))
        y += h + 18
    S["cards"] = cards
    return S


def draw_feed(c, t, S):
    op = env(t, 0.0, 4.3, 0.5)
    if op <= 0:
        return
    S["kick"].draw(c, 140, 290, op * env(t, 0.2, 4.3))
    for key, t0, y in (("l1", 0.35, 340), ("l2", 1.5, 480)):
        k = ease_out(prog(t, t0, t0 + 0.7))
        S[key].draw(c, 140, y + 18 * (1 - k), op * k)
    S["swash"].draw(c, prog(t, 2.05, 3.0), op)
    scroll = -70 * t
    cop = op * ease_out(prog(t, 0.1, 0.9))
    for lay, y, wash in S["cards"]:
        yy = y + scroll
        if yy > H or yy + lay.h < 0:
            continue
        if wash is not None:
            wash.x, wash.y = 1320 - 24, int(yy) - 24
            wash.draw(c, prog(t, 2.3, 3.2), cop)
        lay.draw(c, 1320, yy, cop)


def lo(p):
    p = min(0.99, max(0.01, p))
    return math.log(p / (1 - p))


# Chart geometry. Jev is often certain (P(keep) 1.00), so posts it is >= 99% sure about stack in
# a pile at each end of the axis instead of piling into one column; the axis covers 1%..99%.
CH = {"labx": 400, "lp0": 430, "lp1": 640, "ax0": 690, "ax1": 1500, "rp0": 1550, "rp1": 1760, "step": 19, "rowsN": 9}


def scene_chart():
    """4.0–9.7 s: how Jev reads the test posts (real scores)."""
    S = {}
    S["kick"] = text_layer(f"HOW JEV READS {N_POSTS} TEST POSTS", av(26, "demi"), GREY, tracking=4)
    S["title"] = text_layer("Every post is read before it reaches you.", ny(64, 560))
    X = lambda sc: CH["ax0"] + (lo(sc) - lo(0.01)) / (lo(0.99) - lo(0.01)) * (CH["ax1"] - CH["ax0"])
    S["X"] = X
    rows = {"noise": 440, "debatable": 630, "fine": 820}
    S["rows"] = rows
    counts = {k: sum(p["label"] == k for p in POSTS) for k in rows}
    S["rowlab"] = {
        "noise": text_layer(f"Written as noise · {counts['noise']}", av(27, "demi"), INK),
        # Not noise for the three defaults, not plainly fine: borderline posts plus clear noise of
        # other kinds (AI hype, dunking), which the defaults don't cover.
        "debatable": text_layer(f"Borderline, or other noise · {counts['debatable']}", av(27, "demi"), INK),
        "fine": text_layer(f"Ordinary · {counts['fine']}", av(27, "demi"), INK),
    }
    S["pl"] = text_layer("Jev ≥ 99% sure: keep", av(24, "medium"), GREY)
    S["pr"] = text_layer("≥ 99% sure: noise", av(24, "medium"), GREY)
    S["axm"] = text_layer("Jev's read, in between", av(24, "medium"), GREY)
    S["ticks"] = [(X(v), text_layer(lab, av(22, "medium"), GREY)) for v, lab in ((0.05, "5%"), (0.5, "50%"), (0.95, "95%"))]
    S["ann"] = text_layer("Past this line, the post folds away", ny(30, 450, italic=True))
    S["ms"] = text_layer(f"~{MS} ms a post", av(27, "demi"), INK)
    stamps = {}
    for j, (k, col) in enumerate((("noise", VERMILION), ("debatable", OCHRE), ("fine", PRUSSIAN))):
        stamps[k] = [Wash(blob_mask(17, 17), 0, 0, col, 300 + 13 * j + i, strength=0.95, warp=1.8, rim=1.1) for i in range(10)]
    st, nrow = CH["step"], CH["rowsN"]
    offs = [0] + [v for k in range(1, nrow) for v in (-k, k)][: nrow - 1]
    dots, placed = [], {k: [] for k in rows}
    pile_n = {(k, side): 0 for k in rows for side in "lr"}
    for i, p in enumerate(sorted(POSTS, key=lambda p: 1 - p["pKeep"])):
        sc, base = 1 - p["pKeep"], rows[p["label"]]
        if sc < 0.01 or sc > 0.99:
            side = "l" if sc < 0.01 else "r"
            n = pile_n[(p["label"], side)]
            pile_n[(p["label"], side)] += 1
            col, r_ = divmod(n, nrow)
            x = CH["lp1"] - col * st if side == "l" else CH["rp0"] + col * st
            y = base + offs[r_] * st
        else:
            x, y = X(sc), base
            for k in range(40):
                y = base + (1 if k % 2 else -1) * ((k + 1) // 2) * (st - 3)
                if not any(abs(px - x) < st - 2 and abs(py - y) < st - 2 for px, py in placed[p["label"]]):
                    break
        placed[p["label"]].append((x, y))
        dots.append({"x": x, "y": y, "stamp": stamps[p["label"]][i % 10]})
    r = np.random.default_rng(5)
    for d, u in zip(dots, r.permutation(len(dots)) / len(dots)):
        d["delay"] = 4.6 + 2.6 * u
    S["dots"] = dots
    S["rule"] = Layer(Image.new("RGBA", (CH["rp1"] - CH["lp0"], 2), rgb255(INK) + (30,)))
    S["vline"] = Layer(Image.new("RGBA", (3, 960 - 330), rgb255(INK) + (235,)))
    return S


def draw_chart(c, t, S):
    op = env(t, 4.0, 9.7, 0.45)
    if op <= 0:
        return
    S["kick"].draw(c, 140, 100, op)
    k = ease_out(prog(t, 4.15, 4.8))
    S["title"].draw(c, 140, 140 + 14 * (1 - k), op * k)
    ax_op = op * ease_out(prog(t, 4.3, 4.9))
    for key, y in S["rows"].items():
        S["rule"].draw(c, CH["lp0"], y, ax_op)
        S["rowlab"][key].draw(c, CH["labx"] - S["rowlab"][key].w, y - 22, ax_op)
    ya = 935
    S["pl"].draw(c, (CH["lp0"] + CH["lp1"]) / 2 - S["pl"].w / 2, ya, ax_op)
    S["pr"].draw(c, (CH["rp0"] + CH["rp1"]) / 2 - S["pr"].w / 2, ya, ax_op)
    S["axm"].draw(c, (CH["ax0"] + CH["ax1"]) / 2 - S["axm"].w / 2, ya, ax_op)
    for x, lay in S["ticks"]:
        lay.draw(c, x - lay.w / 2, ya - 36, ax_op)
    for d in S["dots"]:
        p = prog(t, d["delay"], d["delay"] + 0.45)
        if p <= 0:
            continue
        e = ease_out(p)
        stp = d["stamp"]
        stp.x, stp.y = int(d["x"] - 8) - 24, int(d["y"] - 8 - 36 * (1 - e)) - 24
        stp.draw(c, 1.0, op * min(1, p * 2.2))
    xl = int(S["X"](0.5))
    lp = ease_in_out(prog(t, 7.45, 8.05))
    if lp > 0:
        S["vline"].draw(c, xl - 1, 330, op, clip_h=(960 - 330 - 60) * lp)
    S["ann"].draw(c, xl + 18, 300, op * ease_out(prog(t, 7.9, 8.4)))
    S["ms"].draw(c, 1760 - S["ms"].w, 100, op * ease_out(prog(t, 8.3, 8.8)))


def scene_picker():
    """9.5–13.9 s: tap it, or say it."""
    S = {}
    S["kick"] = text_layer("YOU DECIDE WHAT'S NOISE", av(26, "demi"), GREY, tracking=4)
    S["title"] = text_layer("Tap it. Or just say it.", ny(78, 560))
    labels = ["Political rage bait", "Crypto & memecoin shilling", "Engagement bait", "Vague AI hype", "Dunking & pile-ons",
              "Doom posting", "Hustle & get-rich-quick", "Revenue flexing", "Thread bait", "Culture-war bait", "Sports",
              "Celebrity gossip", "TV & movie spoilers", "Graphic violence", "Thirst traps", "AI slop images", "Promoted posts"]
    on = set(labels[:3])
    pills, x, y = [], 140, 380
    for i, lab in enumerate(labels):
        lay, w, h = pill_layer(lab, lab in on)
        if x + w > 1780:
            x, y = 140, y + h + 20
        wash = Wash(blob_mask(w, h, "rr"), x, y, VERMILION, 500 + i, strength=0.62, origin=(0, h / 2), warp=5) if lab in on else None
        pills.append({"lay": lay, "x": x, "y": y, "wash": wash, "delay": 9.95 + i * 0.05})
        x += w + 18
    S["pills"] = pills
    S["typed"] = "Spoilers for Severance"
    S["ty"] = y + 80 + 64
    f = av(40, "demi")
    tw = int(f.getlength(S["typed"])) + 70
    S["tfont"] = f
    S["twash"] = Wash(blob_mask(tw, 84, "rr"), 140, S["ty"], PRUSSIAN, 777, strength=0.5, origin=(0, 42), warp=5)
    S["tframe"] = Layer(_frame(tw, 84))
    S["thint"] = text_layer("your own, in plain words", ny(28, 450, italic=True), GREY)
    return S


def _frame(w, h):
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    ImageDraw.Draw(img).rounded_rectangle((1, 1, w - 2, h - 2), radius=h // 2, outline=rgb255(INK) + (150,), width=2)
    return img


def draw_picker(c, t, S):
    op = env(t, 9.5, 13.9, 0.4)
    if op <= 0:
        return
    S["kick"].draw(c, 140, 160, op)
    k = ease_out(prog(t, 9.65, 10.3))
    S["title"].draw(c, 140, 200 + 14 * (1 - k), op * k)
    for p in S["pills"]:
        a = ease_out(prog(t, p["delay"], p["delay"] + 0.35))
        if p["wash"] is not None:
            p["wash"].draw(c, prog(t, 10.75 + 0.18 * S["pills"].index(p), 11.6 + 0.18 * S["pills"].index(p)), op)
        p["lay"].draw(c, p["x"], p["y"] + 10 * (1 - a), op * a)
    # typed custom mute
    ty = S["ty"]
    fa = ease_out(prog(t, 11.55, 11.85))
    if fa > 0:
        S["twash"].draw(c, prog(t, 12.75, 13.45), op)
        S["tframe"].draw(c, 140, ty, op * fa)
        n = int(len(S["typed"]) * prog(t, 11.8, 12.7))
        txt = S["typed"][:n]
        lay = text_layer(txt + ("|" if (t * 2) % 1 < 0.6 and n < len(S["typed"]) else ""), S["tfont"], INK) if txt or t < 12.7 else None
        if lay:
            lay.draw(c, 140 + 27, ty + 10, op * fa)
        S["thint"].draw(c, 140 + S["tframe"].w + 24, ty + 18, op * ease_out(prog(t, 12.8, 13.2)))


def scene_fold():
    """13.7–17.9 s: noise folds away; the numbers."""
    S = {}
    feed_ids = ["s001", "s101", "s005", "s096", "s010"]
    cards = []
    for i, tid in enumerate(feed_ids):
        t = TWEETS[tid]
        lay, h = card_layer(t["author"], t["text"], 780, 3)
        noise = any(t["labels"][m] == 1 for m in ("m0", "m1", "m2"))
        reason = None
        if noise:
            m = next(m for m in ("m0", "m1", "m2") if t["labels"][m] == 1)
            reason = {"m0": "Political rage bait", "m1": "Crypto & memecoin shilling", "m2": "Engagement bait"}[m]
        cards.append({"lay": lay, "h": h, "noise": noise, "bar": bar_layer(reason, 780) if noise else None,
                      "wash": Wash(blob_mask(780, h, "rr", 16), 0, 0, VERMILION, 900 + i, strength=0.45, origin=(0, h / 2), warp=6) if noise else None})
    S["cards"] = cards
    S["n1"] = text_layer(f"{FINE_HIDDEN} of {FINE}", ny(150, 640))
    S["c1"] = text_layer("ordinary test posts hidden", av(34, "medium"), INK)
    S["n2"] = text_layer(f"{NOISE_CAUGHT} of {NOISE}", ny(150, 640))
    S["c2"] = text_layer("posts written as noise, folded away", av(34, "medium"), INK)
    S["foot"] = text_layer(f"Three default mutes · {N_POSTS} synthetic test posts · {MODEL}", av(24, "medium"), GREY)
    nw = max(S["n1"].w, S["n2"].w)
    S["u1"] = Wash(swash_mask(nw, 46, 8), 1040, 350, PRUSSIAN, 61, strength=0.45, origin=(0, 23), warp=8)
    S["u2"] = Wash(swash_mask(nw, 46, 9), 1040, 640, VERMILION, 62, strength=0.5, origin=(0, 23), warp=8)
    return S


def draw_fold(c, t, S):
    op = env(t, 13.7, 17.9, 0.4)
    if op <= 0:
        return
    y = 110
    fold = ease_in_out(prog(t, 15.15, 15.85))
    for i, cd in enumerate(S["cards"]):
        a = op * ease_out(prog(t, 13.85 + i * 0.08, 14.3 + i * 0.08))
        h = cd["h"]
        if cd["noise"]:
            cur = h + (58 - h) * fold
            if cd["wash"] is not None:
                cd["wash"].x, cd["wash"].y = 140 - 24, y - 24
                cd["wash"].draw(c, prog(t, 14.45, 15.15), a * (1 - fold), clip_h=cur)
            if fold < 1:
                cd["lay"].draw(c, 140, y, a * (1 - fold), clip_h=cur)
            if fold > 0:
                cd["bar"].draw(c, 140, y, a * fold)
            h = cur
        else:
            cd["lay"].draw(c, 140, y, a)
        y += h + 18
    k1 = ease_out(prog(t, 15.7, 16.2))
    S["u1"].draw(c, prog(t, 15.8, 16.5), op)
    S["n1"].draw(c, 1040, 220 + 12 * (1 - k1), op * k1)
    S["c1"].draw(c, 1046, 410, op * k1)
    k2 = ease_out(prog(t, 16.35, 16.85))
    S["u2"].draw(c, prog(t, 16.45, 17.1), op)
    S["n2"].draw(c, 1040, 510 + 12 * (1 - k2), op * k2)
    S["c2"].draw(c, 1046, 700, op * k2)
    S["foot"].draw(c, 1046, 790, op * ease_out(prog(t, 16.9, 17.3)))


def scene_title():
    """17.8–21 s: title card."""
    S = {}
    f = ny(188, 720)
    full = "Signal & Noise"
    lay = text_layer(full, f)
    S["t"], S["tx"], S["ty"] = lay, (W - lay.w) / 2, 330
    sw = f.getlength("Signal")
    nx = f.getlength("Signal & ")
    nwid = f.getlength("Noise")
    S["w1"] = Wash(blob_mask(int(sw + 80), 150), S["tx"] + 8 - 40, 400, PRUSSIAN, 71, strength=0.38, origin=(0, 75), warp=12)
    S["w2"] = Wash(blob_mask(int(nwid + 80), 150), S["tx"] + 8 + nx - 40, 400, VERMILION, 72, strength=0.45, origin=(nwid + 80, 75), warp=12)
    S["sub"] = text_layer("Say what's noise. Jev folds it away before you see it.", ny(42, 450, italic=True), INK)
    S["tag"] = text_layer("A CHROME EXTENSION FOR X", av(26, "demi"), GREY, tracking=4)
    return S


def draw_title(c, t, S):
    op = ease_out(prog(t, 17.85, 18.4))
    if op <= 0:
        return
    S["w1"].draw(c, prog(t, 18.0, 19.0), op)
    S["w2"].draw(c, prog(t, 18.35, 19.35), op)
    k = ease_out(prog(t, 18.05, 18.75))
    S["t"].draw(c, S["tx"], S["ty"] + 16 * (1 - k), op * k)
    ks = ease_out(prog(t, 19.0, 19.6))
    S["sub"].draw(c, (W - S["sub"].w) / 2, 600 + 8 * (1 - ks), ks)
    kt = ease_out(prog(t, 19.5, 20.0))
    S["tag"].draw(c, (W - S["tag"].w) / 2, 700, kt)


# ---------------------------------------------------------------- render
def main():
    preview = "--preview" in sys.argv
    OUT.mkdir(parents=True, exist_ok=True)
    print("building paper and washes…", flush=True)
    paper = make_paper()
    scenes = [(scene_feed(), draw_feed), (scene_chart(), draw_chart), (scene_picker(), draw_picker),
              (scene_fold(), draw_fold), (scene_title(), draw_title)]

    def frame(t):
        c = paper.copy()
        for S, fn in scenes:
            fn(c, t, S)
        return (np.clip(c, 0, 1) * 255).astype(np.uint8)

    if preview:
        times = [1.2, 3.4, 6.2, 8.6, 11.2, 13.3, 14.9, 17.2, 20.5]
        tiles = [cv2.resize(frame(t), (640, 360), interpolation=cv2.INTER_AREA) for t in times]
        rows = [np.hstack(tiles[i:i + 3]) for i in range(0, 9, 3)]
        Image.fromarray(np.vstack(rows)).save(OUT / "contact.png")
        for t in (3.4, 8.6, 17.2, 20.5):
            Image.fromarray(frame(t)).save(OUT / f"frame-{t:04.1f}.png")
        print("wrote contact sheet")
        return

    out = OUT / "signal-and-noise-trailer.mp4"
    ff = subprocess.Popen(["ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}",
                           "-r", str(FPS), "-i", "-", "-c:v", "libx264", "-preset", "slow", "-crf", "16",
                           "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(out)], stdin=subprocess.PIPE)
    for i in range(N):
        ff.stdin.write(frame(i / FPS).tobytes())
        if i % 60 == 0:
            print(f"frame {i}/{N}", flush=True)
    ff.stdin.close()
    ff.wait()
    Image.fromarray(frame(20.5)).save(OUT / "poster.png")
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
