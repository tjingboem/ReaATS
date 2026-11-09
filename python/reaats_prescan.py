#!/usr/bin/env python3
"""reaats_prescan.py -- a quick look at a sound before it is analysed: where its partials are, how high its content goes, how loud and
how fast it is. It needs numpy only and takes a second or two, whatever the length of the sound (a long sound is sampled).

    python3 reaats_prescan.py sound.wav [--start S] [--duration D]

It prints one line, PRESCAN {...}, a Lua table that the Analysis page reads, or ERROR message:
  seconds, rate, peak_db, floor_db                  the length, the sample rate, the loudest sample (dBFS), the quietest tenth (dB below the loudest block)
  curve = {dB...}                                    the average spectrum, 160 points from 20 Hz to the Nyquist frequency (log scale), 0 dB = the strongest
  envelope = {dB...}                                 the loudness over time (up to 120 points, 0 dB = the loudest), covering the whole selected part
  peaks = { {f=Hz, db=dB, note="A3"}, ... }          the strong low partials of the average spectrum (lowest first)
  lowest, highest                                    the lowest strong partial (Hz, or 0 when there is none) and the highest frequency with content (Hz)
  suggest = { key = { v = value, why = "text" } }    settings that suit the sound (the Analysis page shows them in red)
Method: an averaged FFT of 8192 points (Hann window, half overlap); the lowest strong partial is the lowest local maximum that stands at least
12 dB above its surroundings and is within 25 dB of the strongest low partial; the highest content is the highest point of the spectrum
(smoothed over a sixth of an octave) that is not more than 75 dB below the strongest.
"""
import argparse
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pyatsyn import wavio                                       # noqa: E402
import reaats_audio                                             # noqa: E402

N = 8192
NOTE_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
CURVE_POINTS = 160
CURVE_LO = 20.0


def note_name(f):
    if f <= 0:
        return ""
    n = int(round(69 + 12 * math.log2(f / 440.0)))
    return "%s%d" % (NOTE_NAMES[n % 12], n // 12 - 1)


def to_lua(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(float(v)) if isinstance(v, float) else repr(v)
    if isinstance(v, str):
        return '"' + v.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'
    if isinstance(v, dict):
        return "{" + ",".join("%s=%s" % (k, to_lua(x)) for k, x in v.items()) + "}"
    if isinstance(v, (list, tuple)):
        return "{" + ",".join(to_lua(x) for x in v) + "}"
    raise TypeError(repr(v))


def nice_round(x):
    """A value people would type: to 5 Hz below 100, 10 Hz below 300, 25 Hz above."""
    step = 5 if x < 100 else (10 if x < 300 else 25)
    return max(step, int(round(x / step)) * step)


def average_spectrum(seg, rate):
    """Mean power spectrum of the sound (a long sound: twelve pieces of 5 seconds spread over it)."""
    if len(seg) <= 60 * rate:
        chunks = [seg]
    else:
        piece = int(5 * rate)
        starts = np.linspace(0, len(seg) - piece, 12).astype(int)
        chunks = [seg[s:s + piece] for s in starts]
    win = np.hanning(N)
    acc, count = np.zeros(N // 2 + 1), 0
    for c in chunks:
        if len(c) < N:
            c = np.concatenate([c, np.zeros(N - len(c))])
        for i in range(0, len(c) - N + 1, N // 2):
            acc += np.abs(np.fft.rfft(c[i:i + N] * win)) ** 2
            count += 1
    return acc / max(count, 1)


def prescan(path, start=0.0, duration=None):
    x, rate = reaats_audio.read_audio(path)
    mono = x.mean(axis=1) if x.ndim > 1 else x
    n0 = int(start * rate)
    n1 = len(mono) if not duration or duration <= 0 else min(len(mono), n0 + int(duration * rate))
    if n0 >= len(mono):
        raise ValueError("the start is beyond the end of the sound")
    seg = mono[n0:n1]
    if len(seg) < 256:
        raise ValueError("the sound is too short")
    seconds = len(seg) / rate
    nyq = rate / 2.0
    peak = float(np.max(np.abs(seg)))
    if peak <= 0:
        raise ValueError("the sound is silent")
    peak_db = 20 * math.log10(peak)

    # the average spectrum
    P = average_spectrum(seg, rate)
    ref = float(P.max())
    db = 10 * np.log10(P / ref + 1e-20)
    freqs = np.arange(N // 2 + 1) * rate / N

    # the curve: for every step the strongest bin in it (so that the partials show)
    edges = CURVE_LO * (nyq / CURVE_LO) ** (np.arange(CURVE_POINTS + 1) / CURVE_POINTS)
    curve = []
    last = 0
    for i in range(CURVE_POINTS):
        lo = max(int(np.searchsorted(freqs, edges[i])), last)
        hi = max(int(np.searchsorted(freqs, edges[i + 1])), lo + 1)
        curve.append(round(float(db[lo:hi].max()), 1))
        last = lo

    # the loudness over time
    block = max(int(0.05 * rate), 64)
    nb = len(seg) // block
    rms = np.sqrt(np.mean(seg[:nb * block].reshape(nb, block) ** 2, axis=1)) + 1e-12
    rms_db = 20 * np.log10(rms / rms.max())
    pooled = rms_db
    if nb > 120:
        k = int(math.ceil(nb / 120.0))
        m = (nb // k) * k
        pooled = rms_db[:m].reshape(-1, k).max(axis=1)
    floor_db = float(np.percentile(rms_db, 10)) if nb >= 10 else -90.0
    fine = max(int(0.005 * rate), 16)                                          # the attack, at 5 ms
    nf = len(seg) // fine
    fdb = 20 * np.log10(np.sqrt(np.mean(seg[:nf * fine].reshape(nf, fine) ** 2, axis=1)) + 1e-12)
    fdb -= fdb.max()
    rises = [fdb[i + 4] - fdb[i] for i in range(nf - 4) if fdb[i] > -45]       # (a rise out of near silence is just the sound beginning)
    attack = float(max(rises)) if rises else 0.0                                # the steepest rise in 20 ms, dB
    abrupt = bool(nf > 0 and fdb[0] > -12 and seconds < 60)                    # the sound starts at (nearly) full level

    # the strong low partials: local maxima that stand out
    k_lo, k_hi = int(25 / (rate / N)) + 2, int(min(2000.0, nyq * 0.9) / (rate / N))
    band = db[k_lo:k_hi]
    top = float(band.max()) if len(band) else -200.0
    cands = []
    for k in range(k_lo, k_hi):
        if db[k] > db[k - 1] and db[k] >= db[k + 1] and db[k] >= top - 25:
            around = np.median(db[max(k - 60, 0):k + 60])
            if db[k] - around >= 12:
                if cands and k - cands[-1] <= 3:
                    if db[k] > db[cands[-1]]:
                        cands[-1] = k
                else:
                    cands.append(k)
    peaks = []
    for k in cands[:6]:
        # the frequency of the peak from the three bins round it (a parabola), better than the bin itself
        a, b, c = db[k - 1], db[k], db[k + 1]
        d = 0.5 * (a - c) / (a - 2 * b + c) if (a - 2 * b + c) != 0 else 0.0
        f = float((k + d) * rate / N)
        peaks.append({"f": round(f, 1), "db": round(float(b), 1), "note": note_name(f)})
    lowest = peaks[0]["f"] if peaks else 0.0

    # the highest frequency with content: from the smoothed curve (a sixth of an octave is 160/ (log2(nyq/20)*6) points ~ 4 points)
    smooth = np.array(curve)
    width = max(int(round(CURVE_POINTS / (math.log2(nyq / CURVE_LO) * 6))), 1)
    if width > 1:
        smooth = np.array([max(curve[max(i - width // 2, 0):i + width // 2 + 1]) for i in range(CURVE_POINTS)])
    centers = np.sqrt(edges[:-1] * edges[1:])

    def highest_above(level):
        idx = np.nonzero(smooth >= level)[0]
        return float(centers[idx[-1]]) if len(idx) else 0.0
    highest75, highest60 = highest_above(-75.0), highest_above(-60.0)

    # settings that suit the sound
    suggest = {}
    if lowest > 0:
        f = min(max(nice_round(lowest * 0.8), 20), 1000)
        win_ms = 4.0 / f * 1000
        suggest["lowest_frequency"] = {"v": f, "why": "the lowest strong partial is at %.0f Hz (%s); the window (4 cycles of %d Hz) is then %.0f ms long" % (lowest, note_name(lowest), f, win_ms)}
    else:
        suggest["lowest_frequency"] = {"v": 50, "why": "no clear low partial was found; 50 Hz suits most sounds"}
    hi = min(max(nice_round(max(highest75, 4000.0) * 1.15 / 25) * 25, 4000), int(min(20000, nyq * 0.95)))
    suggest["highest_frequency"] = {"v": hi, "why": "the sound has content up to about %.0f Hz (within 75 dB of its strongest); above that only the noise bands would be needed" % highest75}
    if seconds <= 120:
        thr, why = -60, "a short sound: -60 dB follows even the quiet partials, so little of the sound ends up in the noise"
    elif seconds <= 600:
        thr, why = -50, "a long sound (%.0f s): -50 dB keeps the analysis and the file smaller" % seconds
    else:
        thr, why = -40, "a very long sound (%.0f s): -40 dB keeps the analysis and the file manageable" % seconds
    suggest["amp_threshold_db"] = {"v": thr, "why": why}
    if seconds <= 120 and (attack >= 15 or abrupt):
        suggest["hop_size"] = {"v": 0.125, "why": ("a fast attack (%.0f dB in 20 ms)" % attack if attack >= 15 else "the sound starts at full level, like a struck note") + ": a shorter hop follows it better"}
    else:
        suggest["hop_size"] = {"v": 0.25, "why": ("a long sound: the default hop keeps the analysis manageable" if seconds > 120
                                                  else "no fast attack (%.0f dB in 20 ms): the default hop is enough" % attack)}
    suggest["window_cycles"] = {"v": 4, "why": "4 periods of the lowest frequency in the window is the usual choice"}

    return {
        "seconds": round(seconds, 3), "rate": int(rate), "peak_db": round(peak_db, 1), "floor_db": round(floor_db, 1), "attack_db": round(attack, 1),
        "curve": curve, "envelope": [round(float(v), 1) for v in pooled], "peaks": peaks,
        "lowest": lowest, "highest": round(highest75, 0), "highest60": round(highest60, 0), "suggest": suggest,
    }


def main(argv=None):
    p = argparse.ArgumentParser(description="A quick look at a sound before it is analysed.")
    p.add_argument("wav")
    p.add_argument("--start", type=float, default=0.0)
    p.add_argument("--duration", type=float, default=None)
    a = p.parse_args(argv)
    try:
        result = prescan(a.wav, a.start, a.duration)
    except (OSError, ValueError, wavio.WavError) as e:
        print("ERROR " + str(e))
        sys.exit(2)
    except Exception as e:                                       # anything unexpected: say it
        print("ERROR internal error: %s: %s" % (type(e).__name__, e))
        sys.exit(2)
    print("PRESCAN " + to_lua(result))


if __name__ == "__main__":
    main()
