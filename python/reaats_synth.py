#!/usr/bin/env python3
"""reaats_synth.py -- renders ATS files (one per channel) to a WAV file: sines + noise.

This is the fast twin of lib/ats_synth.lua (same method, same levels), used by the editor for AUDITION and PRINT when
Python with numpy is available. It needs numpy only. The Lua synthesis stays in the editor as the fallback.

    python3 reaats_synth.py --out sound.wav [--from S] [--to S] [--no-sines] [--no-noise] [--seed N]
                            [--mixdown stereo] [--result-file R] channel1.ats [channel2.ats ...]

Arguments can also be given in a file: reaats_synth.py --args-file args.txt (one argument per line).

Method (see ats_synth.lua for the long description): every partial is one oscillator whose amplitude and frequency change
linearly between the frames, the phase being the running sum of the frequency; the noise of each of the 25 critical bands
is band-limited Gaussian noise (a 4th-order Butterworth magnitude response, applied by FFT) with unit RMS, multiplied by the
band's energy envelope sqrt(energy / (window_size * 0.04)) * 0.30.

With --result-file R the program writes R.started ("progress seconds-since-1970", every 2 s as a sign of life) and, when
done, R: "OK t_start duration samplerate channels" or "ERROR message". A file R.cancel stops it.
"""
import argparse
import hashlib
import os
import sys
import threading
import time

import numpy as np

NOISE_VARIANCE = 0.04
NOISE_GAIN = 0.30
EDGES = [0, 100, 200, 300, 400, 510, 630, 770, 920, 1080, 1270, 1480, 1720,
         2000, 2320, 2700, 3150, 3700, 4400, 5300, 6400, 7700, 9500, 12000, 15500, 20000]
BANDS = 25

RESULT = None
_BEAT = {"p": 0.0}


class Cancelled(Exception):
    pass


def write_text(path, text):
    tmp = "%s.%d.%d.tmp" % (path, os.getpid(), threading.get_ident())
    with open(tmp, "w") as fh:
        fh.write(text)
    os.replace(tmp, path)


def progress(p):
    """Reports how far we are (0..1) and notices a Cancel."""
    _BEAT["p"] = p
    if RESULT:
        if os.path.exists(RESULT + ".cancel"):
            raise Cancelled()
        write_text(RESULT + ".started", "%.4f %.3f" % (p, time.time()))


def start_heartbeat():
    stop = threading.Event()

    def beat():
        while not stop.wait(2.0):
            try:
                write_text(RESULT + ".started", "%.4f %.3f" % (_BEAT["p"], time.time()))
            except OSError:
                pass
    threading.Thread(target=beat, daemon=True).start()
    return stop.set


def fail(msg):
    sys.stderr.write("reaats_synth: " + msg + "\n")
    print("ERROR " + msg)
    if RESULT:
        write_text(RESULT, "ERROR " + msg + "\n")
    sys.exit(2)


# ---------------------------------------------------------------------------------------------------------- reading
class Ats:
    pass


def load_ats(path):
    """Reads an ATS file (types 1-4, either byte order)."""
    try:
        raw = np.fromfile(path, dtype="<f8")
    except OSError as e:
        raise ValueError("cannot open %s: %s" % (path, e))
    if raw.size < 10:
        raise ValueError("%s is too short for an ATS header" % path)
    if raw[0] != 123.0:
        raw = np.fromfile(path, dtype=">f8").astype("<f8")
        if raw[0] != 123.0:
            raise ValueError("%s is not an ATS file" % path)
    a = Ats()
    h = raw[:10]
    a.sr, a.frame_size, a.window_size = float(h[1]), float(h[2]), float(h[3])
    a.partials, a.frames = int(round(h[4])), int(round(h[5]))
    a.dur, a.type = float(h[8]), int(round(h[9]))
    if a.type < 1 or a.type > 4 or a.partials < 1 or a.frames < 1:
        raise ValueError("%s: unusable header" % path)
    pp = 3 if a.type in (2, 4) else 2
    a.has_noise = a.type in (3, 4)
    per_frame = 1 + pp * a.partials + (BANDS if a.has_noise else 0)
    need = 10 + per_frame * a.frames
    if raw.size < need:
        raise ValueError("%s is smaller than its header says" % path)
    m = raw[10:need].reshape(a.frames, per_frame)
    a.times = m[:, 0].copy()
    a.amp = np.ascontiguousarray(m[:, 1:1 + pp * a.partials:pp].T)          # [partial, frame]
    a.frq = np.ascontiguousarray(m[:, 2:2 + pp * a.partials:pp].T)
    a.noise = np.ascontiguousarray(m[:, 1 + pp * a.partials:1 + pp * a.partials + BANDS].T) if a.has_noise else None
    return a


# ------------------------------------------------------------------------------------------------------- synthesis
def grid(a, start, end):
    """The part to render: frame offset j0 (0-based), samples n, hop fs; None when there is nothing."""
    fs = int(round(a.frame_size))
    n_total = min(int(a.dur * a.sr), (a.frames - 1) * fs)
    if n_total < 1:
        raise ValueError("the file has no sound")
    j0 = 0
    if start and start > 0:
        j0 = min(int(start * a.sr / fs + 1e-6), a.frames - 2)
    n = n_total - j0 * fs
    if end is not None:
        n = min(n, int(end * a.sr) - j0 * fs)
    if n < 1:
        raise ValueError("nothing to play after this point")
    return fs, j0, n


def fill_zeros(f):
    """Frequencies of 0 take the value of the nearest frame that has one (the oscillator keeps its pitch while it fades)."""
    idx = np.where(f > 0, np.arange(len(f)), -1)
    fwd = np.maximum.accumulate(idx)
    out = np.where(fwd >= 0, f[np.maximum(fwd, 0)], 0.0)
    if np.any(out <= 0):                                          # leading zeros: take the first value that exists
        nz = np.nonzero(f > 0)[0]
        if len(nz) == 0:
            return None
        out[:nz[0]] = f[nz[0]]
    return out


def add_sines(a, out, fs, j0, n, base, span):
    two_pi_sr = 2 * np.pi / a.sr
    nf = a.frames
    xs_all = (np.arange(nf) - j0) * fs                           # sample position of every frame
    for p in range(a.partials):
        amp, frq = a.amp[p], a.frq[p]
        seg = (amp[j0:nf - 1] > 0) | (amp[j0 + 1:nf] > 0)         # segment j -> j+1 sounds
        seg &= (frq[j0:nf - 1] > 0) | (frq[j0 + 1:nf] > 0)
        if seg.any():
            edges = np.diff(np.concatenate(([0], seg.astype(np.int8), [0])))
            starts = np.nonzero(edges == 1)[0] + j0                # first segment of every run
            stops = np.nonzero(edges == -1)[0] + j0                # one past the last segment
            phase0 = 0.0
            for s, e in zip(starts, stops):
                x0, x1 = int(xs_all[s]), int(xs_all[e])            # samples of the run
                if x0 >= n:
                    break
                x1 = min(x1, n)
                f = fill_zeros(frq[s:e + 1])
                if f is None:
                    continue
                i = np.arange(x0, x1)
                xf = xs_all[s:e + 1]
                fr = np.interp(i, xf, f)
                am = np.interp(i, xf, amp[s:e + 1])
                w = fr * two_pi_sr
                ph = np.cumsum(w) - w + phase0
                out[x0:x1] += am * np.sin(ph)
                phase0 = float((ph[-1] + w[-1]) % (2 * np.pi))
        if p % 8 == 0:
            progress(base + span * (p + 1) / a.partials)
    progress(base + span)


def fast_length(m):
    """The next length >= m whose only prime factors are 2, 3 and 5 (the FFT is much quicker on those)."""
    best = 1 << (m - 1).bit_length()
    f5 = 1
    while f5 < best:
        f35 = f5
        while f35 < best:
            f = f35
            while f < m:
                f *= 2
            best = min(best, f)
            f35 *= 3
        f5 *= 5
    return best


def band_response(freqs, lo, hi, nyq):
    """Magnitude of two cascaded 2nd-order Butterworth stages, high-pass at lo (not for the first band) and low-pass at hi."""
    hi = min(hi, nyq * 0.98)
    r = freqs / hi
    r2 = r * r
    h = 1.0 / (1.0 + r2 * r2)
    if lo > 0:
        q = lo / np.maximum(freqs, 1e-9)
        q2 = q * q
        h = h / (1.0 + q2 * q2)
        h[freqs <= 0] = 0.0
    return h


def add_noise(a, out, fs, j0, n, seed, base, span):
    nf = a.frames
    xs = (np.arange(nf) - j0) * fs
    nyq = a.sr / 2
    amp_scale = NOISE_GAIN / np.sqrt(a.window_size * NOISE_VARIANCE)
    rng = np.random.default_rng(seed)
    i_all = np.arange(n)
    for b in range(BANDS):
        lo, hi = EDGES[b], EDGES[b + 1]
        e = a.noise[b]
        env = np.sqrt(np.maximum(e[j0:nf], 0.0)) * amp_scale
        if lo >= nyq * 0.98 or not np.any(env > 0):
            progress(base + span * (b + 1) / BANDS)
            continue
        # only the stretch where the band sounds is made (the rest would be multiplied by zero)
        active = np.nonzero(env > 0)[0]
        f_first, f_last = active[0], active[-1]
        x_first = max(int(xs[j0 + max(f_first - 1, 0)]), 0)
        x_last = min(int(xs[min(j0 + f_last + 1, nf - 1)]) + 1, n)
        m = x_last - x_first
        if m < 2:
            continue
        mf = fast_length(m)                                       # (made a little longer, then cut: much quicker FFT)
        half = mf // 2 + 1
        df = a.sr / mf
        k_lo = int(lo / 8 / df)                                   # outside lo/8 .. 8*hi the response is below -70 dB: left out
        k_hi = min(int(min(hi, nyq) * 8 / df) + 2, half)
        spec = np.zeros(half, dtype=np.complex128)
        cnt = k_hi - k_lo
        spec[k_lo:k_hi] = rng.standard_normal(2 * cnt).view(np.complex128) * band_response(np.arange(k_lo, k_hi) * df, lo, hi, nyq)
        carrier = np.fft.irfft(spec, mf)[:m]
        rms = np.sqrt(np.mean(carrier ** 2))
        if rms <= 0:
            continue
        carrier /= rms
        env_s = np.interp(np.arange(x_first, x_last), xs[j0:nf], env)
        out[x_first:x_last] += carrier * env_s
        progress(base + span * (b + 1) / BANDS)
    progress(base + span)


CACHE_KEEP_FILES = 40
CACHE_KEEP_BYTES = 400 * 1024 * 1024


def cache_path(cache_dir, a, j0, n, seed):
    """The noise does not depend on the partials, so what is made from it is kept between renders. The file name is a
    fingerprint of everything the noise is made from: the noise data, the grid, the part and the seed."""
    h = hashlib.sha1()
    h.update(np.ascontiguousarray(a.noise).tobytes())
    h.update(repr((a.sr, a.frame_size, a.window_size, a.frames, j0, n, seed, "v1")).encode())
    return os.path.join(cache_dir, "reaats_noise_" + h.hexdigest() + ".f32")


def prune_cache(cache_dir):
    try:
        files = [os.path.join(cache_dir, f) for f in os.listdir(cache_dir) if f.startswith("reaats_noise_") and f.endswith(".f32")]
        info = sorted(((os.path.getmtime(f), os.path.getsize(f), f) for f in files), reverse=True)
        total = 0
        for i, (_, size, f) in enumerate(info):
            total += size
            if i >= CACHE_KEEP_FILES or total > CACHE_KEEP_BYTES:
                os.remove(f)
    except OSError:
        pass


def noise_signal(a, fs, j0, n, seed, base, span, cache_dir):
    """The noise of the part, from the cache when it was made before."""
    path = cache_path(cache_dir, a, j0, n, seed) if cache_dir else None
    if path and os.path.exists(path):
        try:
            nz = np.fromfile(path, dtype="<f4")
            if len(nz) == n:
                os.utime(path, None)                           # (used lately: pruned last)
                return nz.astype(np.float64)
        except OSError:
            pass
    nz = np.zeros(n)
    add_noise(a, nz, fs, j0, n, seed, base, span)
    if path:
        try:
            os.makedirs(cache_dir, exist_ok=True)
            tmp = "%s.%d.tmp" % (path, os.getpid())
            nz.astype("<f4").tofile(tmp)
            os.replace(tmp, path)
            prune_cache(cache_dir)
        except OSError:
            pass
    return nz


def render_channel(a, start, end, use_sines, use_noise, seed, base, span, cache_dir=None):
    fs, j0, n = grid(a, start, end)
    out = np.zeros(n)
    both = use_sines and use_noise and a.has_noise
    if use_sines:
        add_sines(a, out, fs, j0, n, base, span * (0.15 if both else 1.0))
    if use_noise and a.has_noise:
        b0, sp = base + (span * 0.15 if both else 0.0), span * (0.85 if both else 1.0)
        out += noise_signal(a, fs, j0, n, seed, b0, sp, cache_dir)
        progress(b0 + sp)
    return out, j0 * fs / a.sr


def mix_to_stereo(chans):
    """The same mixdown as ats_synth.lua: channel 1 left, the last right, the others between (constant power)."""
    n = len(chans)
    if n <= 2:
        return chans
    gl, gr = [], []
    for k in range(n):
        pan = k / (n - 1)
        gl.append(np.cos(pan * np.pi / 2))
        gr.append(np.sin(pan * np.pi / 2))
    norm = 1.0 / np.sqrt(max(sum(g * g for g in gl), sum(g * g for g in gr)))
    length = max(len(c) for c in chans)
    left, right = np.zeros(length), np.zeros(length)
    for k, c in enumerate(chans):
        left[:len(c)] += gl[k] * c
        right[:len(c)] += gr[k] * c
    return [left * norm, right * norm]


def write_wav(path, chans, sr):
    """A 32-bit float WAV, one channel per array (shorter ones padded with silence)."""
    n = max(len(c) for c in chans)
    data = np.zeros((n, len(chans)), dtype="<f4")
    for k, c in enumerate(chans):
        data[:len(c), k] = c
    body = data.tobytes()
    nch = len(chans)
    sr = int(round(sr))
    import struct
    head = b"RIFF" + struct.pack("<I", 36 + len(body)) + b"WAVE"
    head += b"fmt " + struct.pack("<IHHIIHH", 16, 3, nch, sr, sr * 4 * nch, 4 * nch, 32)
    head += b"data" + struct.pack("<I", len(body))
    tmp = path + ".tmp"
    with open(tmp, "wb") as fh:                     # (written under another name first: the editor sees only a whole file)
        fh.write(head)
        fh.write(body)
    os.replace(tmp, path)


def build_parser():
    p = argparse.ArgumentParser(description="Renders ATS files (one per channel) to a float WAV.", fromfile_prefix_chars="@")
    p.add_argument("ats", nargs="+", help="the .ats files, one per channel")
    p.add_argument("--out", required=True, help="the WAV file to write")
    p.add_argument("--from", dest="start", type=float, default=0.0, help="start at this time, seconds")
    p.add_argument("--to", dest="end", type=float, default=None, help="stop at this time, seconds (default: the end)")
    p.add_argument("--no-sines", action="store_true")
    p.add_argument("--no-noise", action="store_true")
    p.add_argument("--seed", type=int, default=1)
    p.add_argument("--cache-dir", default=None,
                   help="a folder where the noise of a render is kept (it does not change when you edit partials), so that the "
                        "next render of the same part is quick")
    p.add_argument("--mixdown", choices=("none", "stereo"), default="none",
                   help="stereo: mix more than two channels down to a stereo file (for listening)")
    p.add_argument("--result-file", default=None)
    return p


def expand_args(argv):
    """`--args-file PATH` as the only argument: the arguments are read from that file, one per line. (A separate word, because a
    quoted @path is not understood by every way of starting a program.)"""
    if len(argv) == 2 and argv[0] == "--args-file":
        with open(argv[1], encoding="utf-8") as fh:
            return [line.rstrip("\r\n") for line in fh if line.strip()]
    return argv


def main(argv=None):
    global RESULT
    a = build_parser().parse_args(expand_args(sys.argv[1:] if argv is None else argv))
    RESULT = a.result_file
    stop_beat = None
    if RESULT:
        write_text(RESULT + ".started", "0.0000 %.3f" % time.time())
        stop_beat = start_heartbeat()
    try:
        if a.no_sines and a.no_noise:
            fail("nothing to render (sines and noise are both off)")
        files = [load_ats(p) for p in a.ats]
        first = files[0]
        for f in files[1:]:
            if f.frames != first.frames or abs(f.sr - first.sr) > 1e-6 or abs(f.frame_size - first.frame_size) > 1e-6:
                fail("the channel files do not have the same frame grid")
        chans, t_start = [], 0.0
        for k, f in enumerate(files):
            out, t_start = render_channel(f, a.start, a.end, not a.no_sines, not a.no_noise, a.seed + k,
                                          k / len(files), 1.0 / len(files), a.cache_dir)
            chans.append(out)
        if a.mixdown == "stereo":
            chans = mix_to_stereo(chans)
        write_wav(a.out, chans, first.sr)
        if RESULT:
            write_text(RESULT, "OK %.6f %.6f %d %d\n" % (t_start, len(chans[0]) / first.sr, int(round(first.sr)), len(chans)))
    except Cancelled:
        fail("cancelled")
    except ValueError as e:
        fail(str(e))
    except Exception as e:                                         # anything unexpected: say it instead of dying silently
        fail("internal error: %s: %s" % (type(e).__name__, e))
    finally:
        if stop_beat:
            stop_beat()


if __name__ == "__main__":
    main()
