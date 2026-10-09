"""A soft felt piano, synthesised from scratch, and the score for the vertical trailer.

Each note is a bank of slightly inharmonic string partials (stiff-string stretch), three strings
per note detuned by a cent or two so they beat, a felt-hammer thump at the attack, two-stage decay
(fast prompt sound, long aftersound), a sustain pedal, and a synthetic room reverb.

    uv run --no-project --with numpy --with scipy python trailer/piano.py   ->  trailer/out/score.wav

The score follows trailer/pitch-vertical.md at 120 BPM (a beat every 0.5 s): three "Not this."
hits at 2.0 / 3.5 / 5.0 s, a falling run for the fold, plucked notes for the bubbles, typing
ticks, a build that lands on 14.0 s for the line slam, a stop at 16.0 s, and one chord under the
title.

Revised: no proof slide; the build from 13.0 lands the title at 14.0 and the piece ends at 18.5 s.
"""
import wave
from pathlib import Path

import numpy as np
from scipy.signal import fftconvolve, butter, sosfilt

SR = 44100
OUT = Path(__file__).resolve().parent / "out"
LENGTH = 18.5
rng = np.random.default_rng(1)

NAMES = {"C": 0, "C#": 1, "Db": 1, "D": 2, "D#": 3, "Eb": 3, "E": 4, "F": 5, "F#": 6, "Gb": 6,
         "G": 7, "G#": 8, "Ab": 8, "A": 9, "A#": 10, "Bb": 10, "B": 11}


def midi(name):
    """'F#3' -> 54."""
    note, octave = name[:-1], int(name[-1])
    return 12 * (octave + 1) + NAMES[note]


def freq(m):
    return 440.0 * 2 ** ((m - 69) / 12)


# ------------------------------------------------------------------ the instrument
def piano_note(m, vel, hold, pedal_until=None):
    """One note. `hold` = key-down seconds; the damper falls after it unless the pedal is down."""
    f0 = freq(m)
    B = 0.00012 * (f0 / 110) ** 0.9 + 0.00002          # string stiffness: higher notes stretch more
    tau0 = float(np.clip(5.5 * (110 / f0) ** 0.55, 0.7, 9.0))   # bass rings longer
    release_at = max(hold, (pedal_until or 0))
    damp = 0.12 + 0.25 * (110 / f0) ** 0.3               # damper time constant
    dur = min(release_at + 5 * damp, 7 * tau0) + 0.05
    n = int(dur * SR)
    t = np.arange(n) / SR
    out = np.zeros(n)
    tilt = 1.25 + (1 - vel) * 1.4                         # softer = darker
    cutoff = 1800 + 5200 * vel ** 1.5                     # felt hammer: few highs when soft
    hammer = 1 / 7.3                                      # strike point along the string
    for k in range(1, 40):
        fk = k * f0 * np.sqrt(1 + B * k * k)
        if fk > min(cutoff, SR / 2 - 1000):
            break
        a = (1 / k ** tilt) * abs(np.sin(np.pi * k * hammer)) * (1 / (1 + (fk / cutoff) ** 4))
        tau_fast = tau0 * 0.18 / (1 + 0.5 * (k - 1))
        tau_slow = tau0 / (1 + 0.35 * (k - 1))
        env = 0.72 * np.exp(-t / tau_fast) + 0.28 * np.exp(-t / tau_slow)
        partial = np.zeros(n)
        for cents in (-1.1, 0.0, 1.3):                    # three strings, slightly detuned
            ph = rng.uniform(0, 2 * np.pi)
            partial += np.sin(2 * np.pi * fk * 2 ** (cents / 1200) * t + ph)
        out += a * env * partial / 3
    # attack: a few ms of rise, plus a soft felt thump
    att = np.minimum(1, t / (0.004 + 0.006 * (1 - vel)))
    out *= att
    thump_len = int(0.03 * SR)
    thump = rng.standard_normal(thump_len) * np.exp(-np.arange(thump_len) / (0.006 * SR))
    sos = butter(2, min(0.99, (300 + 900 * vel) / (SR / 2)), output="sos")
    out[:thump_len] += sosfilt(sos, thump) * 0.05 * vel
    # damper
    rel = int(release_at * SR)
    if rel < n:
        out[rel:] *= np.exp(-(t[rel:] - release_at) / damp)
    return out * vel


class Score:
    def __init__(self, length):
        self.buf = np.zeros(int(length * SR) + SR * 8)
        self.pedal = []                                   # (start, end) pedal-down spans

    def pedal_down(self, a, b):
        self.pedal.append((a, b))

    def pedal_end(self, t):
        for a, b in self.pedal:
            if a <= t < b:
                return b
        return None

    def note(self, at, name, vel, hold=0.4):
        m = midi(name) if isinstance(name, str) else name
        x = piano_note(m, vel, hold, self.pedal_end(at) and self.pedal_end(at) - at)
        i = int(at * SR)
        self.buf[i:i + len(x)] += x[: len(self.buf) - i]

    def chord(self, at, names, vel, hold=0.4, roll=0.012):
        for j, nm in enumerate(names):
            self.note(at + j * roll, nm, vel * (0.92 + 0.08 * rng.random()), hold)


# ------------------------------------------------------------------ the piece (D major, 120 BPM)
def compose():
    s = Score(LENGTH)
    beat = 0.5
    # pedal changes with the harmony
    for a, b in ((0, 2), (2, 3.5), (3.5, 5), (5, 6.5), (6.5, 8), (8, 10), (10, 12), (12, 13), (13, 14), (14, 18.5)):
        s.pedal_down(a, b - 0.02)

    # 0:00 cold open: low B pedal tone and a quiet eighth-note ostinato that keeps the pulse
    s.chord(0.0, ["B1", "F#2"], 0.32, hold=2)
    osti = ["B3", "D4", "F#4", "D4"]
    for i in range(4):
        s.note(i * beat / 2 * 2, osti[i % 4], 0.16 + 0.02 * i)
        s.note(i * beat + beat / 2, osti[(i + 2) % 4], 0.13)

    # 0:02 / 0:03.5 / 0:05 "Not this." x3: low octave + chord, each a step down
    hits = [(2.0, ["G1", "G2"], ["G3", "B3", "D4", "F#4"]),
            (3.5, ["A1", "A2"], ["A3", "C#4", "E4"]),
            (5.0, ["F#1", "F#2"], ["F#3", "A3", "C#4"])]
    for at, low, mid in hits:
        s.chord(at, low, 0.8, hold=1.4)
        s.chord(at + 0.01, mid, 0.58, hold=1.4, roll=0.018)
        # the ostinato keeps going quietly underneath
        for k in range(3):
            s.note(at + 0.25 + k * beat, ["D5", "B4", "A4"][k], 0.12)

    # 0:06.5 the fold: a soft falling run that settles on D
    run = ["F#5", "E5", "D5", "B4", "A4", "F#4", "E4", "D4"]
    for i, nm in enumerate(run):
        s.note(6.5 + i * 0.125, nm, 0.30 - i * 0.015, hold=0.3)
    s.chord(7.5, ["D2", "A2"], 0.4, hold=0.9)
    s.chord(7.52, ["D3", "F#3", "A3"], 0.26, hold=0.9)

    # 0:08 bubbles: harmony D - Bm, a plucked pentatonic note on every beat (bubbles dropping in)
    s.chord(8.0, ["D2", "A2", "F#3"], 0.34, hold=2)
    s.chord(10.0, ["B1", "F#2", "D3"], 0.34, hold=2)
    bubbles = ["A5", "F#5", "B5", "E5", "A5", "D6", "B5", "F#5", "E5", "A5"]
    for i, nm in enumerate(bubbles):
        s.note(8.5 + i * beat, nm, 0.24 + (0.06 if i in (1, 2, 3) else 0), hold=0.25)   # the three taps
    for i in range(8):                                    # a gentle left-hand pulse
        s.note(8.0 + i * beat + beat / 2, ["A3", "D4"][i % 2] if i < 4 else ["F#3", "B3"][i % 2], 0.14)

    # 0:11 typing: light repeated high ticks, then the pill fills on 12.5
    for i in range(14):
        s.note(11.0 + i * 0.09 + 0.012 * rng.random(), ["F#6", "A6", "E6"][i % 3], 0.07, hold=0.08)
    s.chord(12.0, ["G1", "G2", "D3"], 0.4, hold=1)
    s.chord(12.5, ["B4", "D5", "F#5"], 0.28, hold=0.6)

    # 0:13 proof: an A pedal and rising eighths, growing, landing on D at 14.0 for the line slam
    s.chord(13.0, ["A1", "A2"], 0.4, hold=1)
    rise = ["A3", "C#4", "E4", "G4", "A4", "C#5", "E5", "G5"]
    for i, nm in enumerate(rise):
        s.note(13.0 + i * 0.125, nm, 0.22 + i * 0.04, hold=0.2)
    # 0:14 the title lands on the big chord and rings out on the pedal
    s.chord(14.0, ["D1", "D2", "A2"], 0.95, hold=3)
    s.chord(14.01, ["D3", "F#3", "A3", "D4", "F#4", "A4"], 0.7, hold=3, roll=0.008)
    s.chord(15.5, ["A4", "C#5", "E5", "F#5"], 0.22, hold=2.5, roll=0.07)
    s.note(16.5, "A5", 0.14, hold=2)
    return s


def room(x):
    """Stereo reverb from a synthetic impulse response: early reflections + a darkening tail."""
    n = int(2.6 * SR)
    t = np.arange(n) / SR
    out = []
    for ch in range(2):
        r = np.random.default_rng(10 + ch)
        tail = r.standard_normal(n) * np.exp(-t / 0.75)
        sos = butter(1, 3500 / (SR / 2), output="sos")
        tail = sosfilt(sos, tail) + 0.25 * tail * np.exp(-t / 0.15)
        ir = np.zeros(n)
        for d, g in ((0.011, 0.6), (0.017, 0.45), (0.023 + ch * 0.004, 0.35), (0.031, 0.3), (0.043 - ch * 0.003, 0.22)):
            ir[int(d * SR)] += g
        ir += tail * 0.08
        out.append(fftconvolve(x, ir)[: len(x)])
    return np.stack(out, 1)


def master(dry):
    # gentle stereo spread of the dry signal (bass centred, highs slightly wide)
    sos_lo = butter(2, 250 / (SR / 2), output="sos")
    lo = sosfilt(sos_lo, dry)
    hi = dry - lo
    d = int(0.0007 * SR)
    left = lo + hi
    right = lo + np.concatenate([np.zeros(d), hi[:-d]])
    wet = room(dry)
    mix = np.stack([left, right], 1) * 0.78 + wet * 0.42
    mix = mix[: int(LENGTH * SR)]
    fade = int(0.8 * SR)
    mix[-fade:] *= np.linspace(1, 0, fade)[:, None] ** 2
    mix /= np.abs(mix).max() + 1e-9
    mix = np.tanh(mix * 1.2) / np.tanh(1.2)               # soft-knee limiting
    return mix * 10 ** (-1.0 / 20)                        # -1 dBFS peak


def write_wav(path, x):
    pcm = (np.clip(x, -1, 1) * 32767).astype(np.int16)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    s = compose()
    write_wav(OUT / "score.wav", master(s.buf))
    print("wrote", OUT / "score.wav")
