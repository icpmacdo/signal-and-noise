"""Vertical trailer (1080x1920, 20.5 s) cut to trailer/out/score.wav, following the storyboard
(trailer/storyboard-site). Same engine as build.py: paper, procedural watercolor, New York type.

    uv run --no-project --with opencv-python-headless --with numpy --with pillow python trailer/vertical.py [--preview]
    -> trailer/out/signal-and-noise-vertical.mp4
"""
import subprocess
import sys
from pathlib import Path

import cv2
import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build as B  # noqa: E402

B.W, B.H = 1080, 1920
W, H, FPS, LEN = 1080, 1920, 30, 18.5
OUT = B.OUT
T = B.TWEETS
MX = 90
K = 1.65                              # type scale for a phone frame
prog, eo, eio = B.prog, B.ease_out, B.ease_in_out


def back_out(x, s=1.6):
    x -= 1
    return 1 + x * x * ((s + 1) * x + s)


def headline(lines, size):
    lays = []
    for ln in lines:
        lay = B.text_layer(ln, B.ny(size, 600))
        if lay.w > W - 2 * MX:
            lay = B.text_layer(ln, B.ny(int(size * (W - 2 * MX) / lay.w), 600))
        lays.append(lay)
    return lays


def draw_headline(c, lays, t, t0, y=300, gap=None):
    k = eo(prog(t, t0, t0 + 0.22))
    gap = gap or lays[0].h - 40
    for i, lay in enumerate(lays):
        lay.draw(c, (W - lay.w) / 2, y + i * gap + 24 * (1 - k), k)


def card(tid, lines=4, width=W - 2 * MX):
    t = T[tid]
    return B.card_layer(t["author"], t["text"], width, lines, K)


# ------------------------------------------------------------------ slide 1: the scroll
FEED = ["s001", "s005", "s010", "s014", "s020", "s025", "s030", "s034", "s011", "s017", "s022", "s036", "s064", "s088"]
feed_cards = []
_y = 0
for tid in FEED:
    lay, h = card(tid, 3)
    feed_cards.append((lay, _y))
    _y += h + 24
FEED_LEN = _y


def slide1(c, t):
    # fast at first, easing to a stop at 2.0
    u = prog(t, 0, 2.0)
    travel = 2600
    pos = travel * (1 - (1 - u) ** 2.4)
    vel = travel * 2.4 * (1 - u) ** 1.4 / 2.0              # px per second
    layer = np.zeros_like(c)
    mask = np.zeros(c.shape[:2], np.float32)
    for lay, y in feed_cards:
        yy = 160 + y - pos
        yy = (yy % FEED_LEN) - 200 if yy < -400 else yy
        if -lay.h < yy < H:
            lay.draw(c, MX, yy)
    blur = vel / FPS * 0.45
    if blur > 1:
        k = int(blur) * 2 + 1
        c[:] = cv2.blur(c, (1, k))


# ------------------------------------------------------------------ slides 2–4: "Not this."
NOT = headline(["Not this."], 150)
HITS = []
for i, (tid, at) in enumerate((("s096", 2.0), ("s101", 3.5), ("s106", 5.0))):
    lay, h = card(tid, 5)
    y = 840 - h // 2 + 80
    wash = B.Wash(B.blob_mask(W - 2 * MX + 40, h + 40, "rr", 24), MX - 20, y - 20, B.VERMILION, 81 + i,
                  strength=0.62, origin=(0, (h + 40) / 2), warp=10)
    HITS.append((at, lay, y, wash))


def slide_hit(c, t, idx):
    at, lay, y, wash = HITS[idx]
    settle = eo(prog(t, at, at + 0.18))
    wash.draw(c, prog(t, at + 0.05, at + 0.65))
    lay.draw(c, MX, y + 30 * (1 - settle), 0.4 + 0.6 * settle)
    draw_headline(c, NOT, t, at + 0.02, y=330)


# ------------------------------------------------------------------ slide 5: the fold
GONE = headline(["Gone before", "you get there."], 120)
FOLD_FEED = [("s001", None), ("s096", "Political rage bait"), ("s005", None), ("s101", "Crypto & memecoin shilling"),
             ("s106", "Engagement bait"), ("s014", None)]
fold_items = []
for i, (tid, reason) in enumerate(FOLD_FEED):
    lay, h = card(tid, 3)
    item = {"lay": lay, "h": h, "reason": reason}
    if reason:
        item["bar"] = B.bar_layer(reason, W - 2 * MX, K)
        item["wash"] = B.Wash(B.blob_mask(W - 2 * MX, h, "rr", 16), 0, 0, B.VERMILION, 120 + i, strength=0.5, origin=(0, h / 2), warp=7)
    fold_items.append(item)


def slide_fold(c, t):
    draw_headline(c, GONE, t, 6.55, y=250)
    y = 620
    n = 0
    for it in fold_items:
        if it["reason"]:
            f = eio(prog(t, 6.75 + n * 0.12, 7.35 + n * 0.12))
            n += 1
            cur = it["h"] + (it["bar"].h - it["h"]) * f
            it["wash"].x, it["wash"].y = MX - 24, y - 24
            it["wash"].draw(c, 1.0, 1 - f, clip_h=cur)
            if f < 1:
                it["lay"].draw(c, MX, y, 1 - f, clip_h=cur)
            if f > 0:
                it["bar"].draw(c, MX, y, f)
            y += cur + 22
        else:
            it["lay"].draw(c, MX, y)
            y += it["h"] + 22


# ------------------------------------------------------------------ slide 6: bubbles
TAP = headline(["Tap what you're", "done with."], 118)
LABELS = ["Political rage bait", "Crypto & memecoin shilling", "Engagement bait", "Vague AI hype", "Dunking & pile-ons",
          "Doom posting", "Hustle & get-rich-quick", "Thread bait", "Culture-war bait", "Sports", "Celebrity gossip",
          "TV & movie spoilers", "AI slop images"]
bubbles = []
_x, _yb = MX, 720
for i, lab in enumerate(LABELS):
    lay, w, h = B.pill_layer(lab, i < 3, 1.35)
    if _x + w > W - MX:
        _x, _yb = MX, _yb + h + 22
    wash = B.Wash(B.blob_mask(w, h, "rr"), _x, _yb, B.VERMILION, 500 + i, strength=0.62, origin=(0, h / 2), warp=5) if i < 3 else None
    bubbles.append({"lay": lay, "x": _x, "y": _yb, "wash": wash, "drop": 8.55 + i * 0.075, "tap": (9.0, 9.5, 10.0)[i] if i < 3 else None})
    _x += w + 18
TAP_RING = B.Layer(Image.new("RGBA", (1, 1), (0, 0, 0, 0)))


def slide_bubbles(c, t):
    draw_headline(c, TAP, t, 8.52, y=250)
    for b in bubbles:
        p = prog(t, b["drop"], b["drop"] + 0.32)
        if p <= 0:
            continue
        dy = -70 * (1 - back_out(p))
        if b["wash"] is not None and t >= b["tap"]:
            b["wash"].draw(c, prog(t, b["tap"], b["tap"] + 0.45))
            press = 1 - eo(prog(t, b["tap"], b["tap"] + 0.18))
            dy += 6 * press
        b["lay"].draw(c, b["x"], b["y"] + dy, min(1, p * 2))


# ------------------------------------------------------------------ slide 7: type it
TYPE = headline(["Or just type it."], 128)
TYPED = "Spoilers for Severance"
_tf = B.av(56, "demi")
_tw, _th = int(_tf.getlength(TYPED)) + 100, 120
_tx, _ty = (W - _tw) // 2, 940
TWASH = B.Wash(B.blob_mask(_tw, _th, "rr"), _tx, _ty, B.PRUSSIAN, 777, strength=0.55, origin=(0, _th / 2), warp=6)
TFRAME = B.Layer(B._frame(_tw, _th))
_typed_cache = {}


def slide_type(c, t):
    draw_headline(c, TYPE, t, 11.02, y=330)
    TFRAME.draw(c, _tx, _ty, eo(prog(t, 11.0, 11.2)))
    TWASH.draw(c, prog(t, 12.5, 13.0))
    n = int(len(TYPED) * prog(t, 11.05, 12.3))
    caret = n < len(TYPED) or (t * 2.5) % 1 < 0.55
    key = (n, caret)
    if key not in _typed_cache:
        _typed_cache[key] = B.text_layer(TYPED[:n] + ("|" if caret else ""), _tf)
    _typed_cache[key].draw(c, _tx + 42, _ty + 18)


# ------------------------------------------------------------------ slide 8: proof
PROOF = headline([f"{B.FINE_HIDDEN} of {B.FINE} good", "posts hidden."], 124)
NOTE = B.text_layer(f"test of {B.N_POSTS} posts, three default mutes", B.ny(36, 450, italic=True), B.GREY)
_r = np.random.default_rng(3)
stamps_b = [B.Wash(B.blob_mask(26, 26), 0, 0, B.PRUSSIAN, 300 + i, strength=0.95, warp=2.2) for i in range(10)]
stamps_r = [B.Wash(B.blob_mask(26, 26), 0, 0, B.VERMILION, 400 + i, strength=0.95, warp=2.2) for i in range(10)]
DOTS = []
for i in range(B.FINE):
    col, row = divmod(i, 11)
    DOTS.append((130 + col * 34, 900 + row * 34 + int(_r.normal(0, 2)), stamps_b[i % 10], 13.0 + _r.uniform(0, 0.85)))
for i in range(B.NOISE):
    col, row = divmod(i, 7)
    DOTS.append((W - 156 - col * 34, 1000 + row * 34 + int(_r.normal(0, 2)), stamps_r[i % 10], 13.0 + _r.uniform(0, 0.85)))
VLINE = B.Layer(Image.new("RGBA", (5, 560), B.rgb255(B.INK) + (240,)))


def slide_proof(c, t):
    for x, y, st, d in DOTS:
        p = prog(t, d, d + 0.3)
        if p <= 0:
            continue
        st.x, st.y = x - 24, int(y - 90 * (1 - eo(p))) - 24
        st.draw(c, 1.0, min(1, p * 2.5))
    lp = eo(prog(t, 14.0, 14.12))
    if lp > 0:
        VLINE.draw(c, W // 2 - 2, 840, 1.0, clip_h=560 * lp)
    draw_headline(c, PROOF, t, 14.0, y=250)
    NOTE.draw(c, (W - NOTE.w) / 2, 600, eo(prog(t, 14.4, 14.7)))


# ------------------------------------------------------------------ slide 9: title
_f = B.ny(230, 760)
SIG, NOI = B.text_layer("Signal", _f), B.text_layer("& Noise", _f)
Y1, Y2 = 700, 960
W1 = B.Wash(B.blob_mask(SIG.w + 60, 200), (W - SIG.w) / 2 - 30, Y1 + 50, B.PRUSSIAN, 71, strength=0.4, origin=(0, 100), warp=14)
W2 = B.Wash(B.blob_mask(NOI.w + 60, 200), (W - NOI.w) / 2 - 30, Y2 + 50, B.VERMILION, 72, strength=0.46, origin=(NOI.w + 60, 100), warp=14)


def slide_title(c, t):
    # lands on the big chord at 14.0
    W1.draw(c, prog(t, 14.0, 14.9))
    W2.draw(c, prog(t, 14.25, 15.15))
    k = eo(prog(t, 14.0, 14.18))
    SIG.draw(c, (W - SIG.w) / 2, Y1 + 30 * (1 - k), k)
    k2 = eo(prog(t, 14.08, 14.26))
    NOI.draw(c, (W - NOI.w) / 2, Y2 + 30 * (1 - k2), k2)


# ------------------------------------------------------------------ timeline (hard cuts on the beat)
CUTS = [(0, 2.0, slide1), (2.0, 3.5, lambda c, t: slide_hit(c, t, 0)), (3.5, 5.0, lambda c, t: slide_hit(c, t, 1)),
        (5.0, 6.5, lambda c, t: slide_hit(c, t, 2)), (6.5, 8.5, slide_fold), (8.5, 11.0, slide_bubbles),
        (11.0, 14.0, slide_type), (14.0, 99, slide_title)]


def main():
    preview = "--preview" in sys.argv
    paper = B.make_paper()

    def frame(t):
        c = paper.copy()
        for a, b, fn in CUTS:
            if a <= t < b:
                fn(c, t)
                break
        if 14.0 <= t < 14.25:                              # a small shake on the slam
            s = int(round(6 * (1 - (t - 14.0) / 0.25) * np.sin((t - 14.0) * 90)))
            c = np.roll(c, s, axis=0)
        return (np.clip(c, 0, 1) * 255).astype(np.uint8)

    if preview:
        times = [0.6, 2.4, 7.9, 9.7, 12.0, 13.5, 14.1, 15.5, 18.3]
        tiles = [cv2.resize(frame(t), (270, 480), interpolation=cv2.INTER_AREA) for t in times]
        Image.fromarray(np.hstack(tiles)).save(OUT / "vertical-contact.png")
        print("wrote contact")
        return
    out = OUT / "signal-and-noise-vertical.mp4"
    ff = subprocess.Popen(["ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}",
                           "-r", str(FPS), "-i", "-", "-i", str(OUT / "score.wav"), "-map", "0:v", "-map", "1:a",
                           "-c:v", "libx264", "-preset", "slow", "-crf", "17", "-pix_fmt", "yuv420p",
                           "-c:a", "aac", "-b:a", "192k", "-shortest", "-movflags", "+faststart", str(out)], stdin=subprocess.PIPE)
    n = int(LEN * FPS)
    for i in range(n):
        ff.stdin.write(frame(i / FPS).tobytes())
        if i % 90 == 0:
            print(f"frame {i}/{n}", flush=True)
    ff.stdin.close()
    ff.wait()
    print("wrote", out)


if __name__ == "__main__":
    main()
