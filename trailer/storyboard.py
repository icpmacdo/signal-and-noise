"""Vertical (1080x1920) storyboard stills for trailer/pitch-vertical.md, one per slide, drawn with
the same engine as build.py (paper, watercolor washes, New York type).

    uv run --no-project --with opencv-python-headless --with numpy --with pillow python trailer/storyboard.py
    -> trailer/out/board/NN.jpg
"""
import sys
from pathlib import Path

import cv2
import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build as B  # noqa: E402

B.W, B.H = 1080, 1920          # the engine reads these at draw time
W, H = B.W, B.H
OUT = B.OUT / "board"
T = B.TWEETS
MX = 90                         # side margin
TOP = 330                       # headline baseline area (clear of X's top bar)


def canvas():
    return B.make_paper()


def headline(c, text, y=TOP, size=128, center=True):
    lay = B.text_layer(text, B.ny(size, 600))
    if lay.w > W - 2 * MX:      # shrink to fit
        lay = B.text_layer(text, B.ny(int(size * (W - 2 * MX) / lay.w), 600))
    lay.draw(c, (W - lay.w) / 2 if center else MX, y)
    return lay


K = 1.65  # type scale for a phone-sized frame


def card(tid, width=W - 2 * MX, lines=4):
    t = T[tid]
    return B.card_layer(t["author"], t["text"], width, lines, K)


def washed_card(c, tid, x, y, width, seed, color=B.VERMILION, strength=0.5):
    lay, h = card(tid, width)
    B.Wash(B.blob_mask(width, h, "rr", 16), x, y, color, seed, strength=strength, origin=(0, h / 2), warp=7).draw(c, 1.0)
    lay.draw(c, x, y)
    return h


def save(c, n):
    img = (np.clip(c, 0, 1) * 255).astype(np.uint8)
    Image.fromarray(img).resize((540, 960), Image.LANCZOS).save(OUT / f"{n:02d}.jpg", quality=86)


def s1():
    c = canvas()
    y = 120
    for i, tid in enumerate(["s001", "s005", "s010", "s096", "s014", "s020", "s025"]):
        lay, h = card(tid, lines=3)
        lay.draw(c, MX, y)
        y += h + 22
    blurred = cv2.GaussianBlur(c, (1, 0), sigmaX=0.1, sigmaY=14)   # fast scroll
    save(blurred, 1)


def not_this(n, tid, seed):
    c = canvas()
    headline(c, "Not this.", y=TOP, size=150)
    lay, h = card(tid, lines=5)
    y = 900 - h // 2 + 120
    B.Wash(B.blob_mask(W - 2 * MX + 40, h + 40, "rr", 24), MX - 20, y - 20, B.VERMILION, seed, strength=0.62,
           origin=(0, (h + 40) / 2), warp=10).draw(c, 1.0)
    lay.draw(c, MX, y)
    save(c, n)


def s5():
    c = canvas()
    headline(c, "Gone before", y=TOP - 40, size=120)
    headline(c, "you get there.", y=TOP + 105, size=120)
    y = 760
    for tid, hidden in (("s001", None), ("s096", "Political rage bait"), ("s005", None), ("s101", "Crypto & memecoin shilling"), ("s106", "Engagement bait"), ("s014", None)):
        if hidden:
            bar = B.bar_layer(hidden, W - 2 * MX, K)
            bar.draw(c, MX, y)
            y += bar.h + 22
        else:
            lay, h = card(tid, lines=3)
            lay.draw(c, MX, y)
            y += h + 22
    save(c, 5)


def s6():
    c = canvas()
    headline(c, "Tap what you're", y=TOP - 40, size=118)
    headline(c, "done with.", y=TOP + 100, size=118)
    labels = ["Political rage bait", "Crypto & memecoin shilling", "Engagement bait", "Vague AI hype", "Dunking & pile-ons",
              "Doom posting", "Hustle & get-rich-quick", "Thread bait", "Culture-war bait", "Sports", "Celebrity gossip",
              "TV & movie spoilers", "AI slop images"]
    x, y = MX, 760
    for i, lab in enumerate(labels):
        lay, w, h = B.pill_layer(lab, i < 3, 1.35)
        if x + w > W - MX:
            x, y = MX, y + h + 22
        if i < 3:
            B.Wash(B.blob_mask(w, h, "rr"), x, y, B.VERMILION, 500 + i, strength=0.62, origin=(0, h / 2), warp=5).draw(c, 1.0)
        lay.draw(c, x, y)
        x += w + 18
    save(c, 6)


def s7():
    c = canvas()
    headline(c, "Or just type it.", y=TOP, size=128)
    text = "Spoilers for Severance"
    f = B.av(56, "demi")
    tw, th = int(f.getlength(text)) + 100, 120
    x, y = (W - tw) // 2, 1000
    B.Wash(B.blob_mask(tw, th, "rr"), x, y, B.PRUSSIAN, 777, strength=0.55, origin=(0, th / 2), warp=6).draw(c, 1.0)
    B.Layer(B._frame(tw, th)).draw(c, x, y)
    B.text_layer(text + "|", f).draw(c, x + 42, y + 18)
    save(c, 7)


def s8():
    c = canvas()
    headline(c, f"{B.FINE_HIDDEN} of {B.FINE} good", y=TOP - 40, size=124)
    headline(c, "posts hidden.", y=TOP + 105, size=124)
    note = B.text_layer(f"test of {B.N_POSTS} posts, three default mutes", B.ny(36, 450, italic=True), B.GREY)
    note.draw(c, (W - note.w) / 2, 620)
    # two rows: ordinary pile on the left, noise on the right, the line between
    rng = np.random.default_rng(3)
    stamps_b = [B.Wash(B.blob_mask(26, 26), 0, 0, B.PRUSSIAN, 300 + i, strength=0.95, warp=2.2) for i in range(10)]
    stamps_r = [B.Wash(B.blob_mask(26, 26), 0, 0, B.VERMILION, 400 + i, strength=0.95, warp=2.2) for i in range(10)]
    xl = W // 2
    for i in range(B.FINE):
        col, row = divmod(i, 11)
        st = stamps_b[i % 10]
        st.x, st.y = 130 + col * 34 - 24, 900 + row * 34 + int(rng.normal(0, 2)) - 24
        st.draw(c, 1.0)
    for i in range(B.NOISE):
        col, row = divmod(i, 7)
        st = stamps_r[i % 10]
        st.x, st.y = W - 130 - 26 - col * 34 - 24, 1000 + row * 34 + int(rng.normal(0, 2)) - 24
        st.draw(c, 1.0)
    B.Layer(Image.new("RGBA", (5, 560), B.rgb255(B.INK) + (240,))).draw(c, xl - 2, 840)
    save(c, 8)


def s9():
    c = canvas()
    f = B.ny(230, 760)
    sig, noi = B.text_layer("Signal", f), B.text_layer("& Noise", f)
    y1, y2 = 640, 900
    B.Wash(B.blob_mask(sig.w + 60, 200), (W - sig.w) / 2 - 30, y1 + 50, B.PRUSSIAN, 71, strength=0.4, origin=(0, 100), warp=14).draw(c, 1.0)
    B.Wash(B.blob_mask(noi.w + 60, 200), (W - noi.w) / 2 - 30, y2 + 50, B.VERMILION, 72, strength=0.46, origin=(noi.w + 60, 100), warp=14).draw(c, 1.0)
    sig.draw(c, (W - sig.w) / 2, y1)
    noi.draw(c, (W - noi.w) / 2, y2)
    sub = B.text_layer("For X. Runs on Jev.", B.ny(52, 450, italic=True))
    sub.draw(c, (W - sub.w) / 2, 1230)
    save(c, 9)


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    s1()
    not_this(2, "s096", 81)
    not_this(3, "s101", 82)
    not_this(4, "s106", 83)
    s5(); s6(); s7(); s8(); s9()
    print("wrote", OUT)
