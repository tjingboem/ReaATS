#!/usr/bin/env python3
"""Tests for python/reaats_audio.py (WAV, AIFF and FLAC reading). Run:  python3 python/tests/test_audio.py   (from the ReaATS folder)
The FLAC files are made here by a small encoder written for the tests (constant, verbatim, fixed and LPC subframes, all the stereo
modes, 16 and 24 bit), so the decoder is checked against exact known samples; a real FLAC file is checked as well when it is there."""
import math
import os
import shutil
import struct
import sys
import tempfile
import unittest

import numpy as np

PY = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, PY)
import reaats_audio                                         # noqa: E402
from pyatsyn import wavio                                   # noqa: E402


# ---------------------------------------------------------------------------------------------------------- writers for the tests
def ext80(x):
    if x == 0:
        return b"\0" * 10
    m, e = math.frexp(x)
    return struct.pack(">HQ", e - 1 + 16383, int(m * 2 ** 64))


def write_aiff(path, ints, rate, bits, aifc=None):
    """ints: (frames, channels) integers."""
    frames, ch = ints.shape
    width = bits // 8
    if aifc == "sowt":
        data = b"".join(int(v).to_bytes(width, "little", signed=True) for v in ints.ravel())
    else:
        data = b"".join(int(v).to_bytes(width, "big", signed=True) for v in ints.ravel())
    comm = struct.pack(">hIh", ch, frames, bits) + ext80(rate)
    if aifc:
        comm += aifc.encode() + b"\x07not cmp"                    # the compression type and a pascal string
    ssnd = struct.pack(">II", 0, 0) + data
    body = (b"AIFC" if aifc else b"AIFF") + b"COMM" + struct.pack(">I", len(comm)) + comm
    body += b"SSND" + struct.pack(">I", len(ssnd)) + ssnd + (b"\0" if len(ssnd) & 1 else b"")
    with open(path, "wb") as fh:
        fh.write(b"FORM" + struct.pack(">I", len(body)) + body)


class BitWriter:
    def __init__(self):
        self.value, self.count = 0, 0

    def write(self, v, n):
        self.value = (self.value << n) | (v & ((1 << n) - 1))
        self.count += n

    def signed(self, v, n):
        self.write(v & ((1 << n) - 1), n)

    def align(self):
        pad = (-self.count) % 8
        self.write(0, pad)

    def to_bytes(self):
        self.align()
        return self.value.to_bytes(self.count // 8, "big")


def rice_encode(bw, res, k):
    for r in res:
        u = r * 2 if r >= 0 else -r * 2 - 1
        q = u >> k
        bw.write(0, q)
        bw.write(1, 1)
        bw.write(u & ((1 << k) - 1), k)


def best_k(res):
    mean = sum(abs(r) * 2 for r in res) / max(len(res), 1)
    return int(min(max(math.log2(mean + 1), 0), 14))


def subframe(bw, x, bps, kind):
    block = len(x)
    bw.write(0, 1)
    if kind == "constant":
        bw.write(0, 6); bw.write(0, 1)
        bw.signed(x[0], bps)
    elif kind == "verbatim":
        bw.write(1, 6); bw.write(0, 1)
        for v in x:
            bw.signed(v, bps)
    elif kind == "fixed2":
        bw.write(8 + 2, 6); bw.write(0, 1)
        bw.signed(x[0], bps); bw.signed(x[1], bps)
        res = [x[i] - 2 * x[i - 1] + x[i - 2] for i in range(2, block)]
        k = best_k(res)
        bw.write(0, 2); bw.write(0, 4); bw.write(k, 4)                  # Rice method 0, partition order 0
        rice_encode(bw, res, k)
    elif kind == "fixed3_order2partitions":
        bw.write(8 + 3, 6); bw.write(0, 1)
        for i in range(3):
            bw.signed(x[i], bps)
        res = [x[i] - 3 * x[i - 1] + 3 * x[i - 2] - x[i - 3] for i in range(3, block)]
        bw.write(1, 2); bw.write(2, 4)                                   # Rice method 1 (5 bit parameters), 4 partitions
        n = block >> 2
        sizes = [n - 3, n, n, n]
        pos = 0
        for size in sizes:
            part = res[pos:pos + size]
            pos += size
            k = best_k(part)
            bw.write(k, 5)
            rice_encode(bw, part, k)
    elif kind == "lpc2":                                                 # x[i] = 2 x[i-1] - x[i-2], coefficients (2, -1), shift 1 of (4, -2)
        bw.write(32 + 1, 6); bw.write(0, 1)                              # LPC order 2
        bw.signed(x[0], bps); bw.signed(x[1], bps)
        bw.write(4 - 1, 4)                                               # precision 4 bits
        bw.signed(1, 5)                                                  # shift 1
        bw.signed(4, 4); bw.signed(-2, 4)
        res = [x[i] - ((4 * x[i - 1] - 2 * x[i - 2]) >> 1) for i in range(2, block)]
        k = best_k(res)
        bw.write(0, 2); bw.write(0, 4); bw.write(k, 4)
        rice_encode(bw, res, k)
    else:
        raise ValueError(kind)


def utf8_number(n):
    if n < 0x80:
        return bytes([n])
    if n < 0x800:
        return bytes([0xC0 | (n >> 6), 0x80 | (n & 0x3F)])
    return bytes([0xE0 | (n >> 12), 0x80 | ((n >> 6) & 0x3F), 0x80 | (n & 0x3F)])


def write_flac(path, ints, rate, bps, mode="independent", kind="fixed2", block=1000):
    """ints: (frames, channels) integers of `bps` bits. mode: independent, left_side, side_right, mid_side (stereo only)."""
    frames, ch = ints.shape
    out = bytearray(b"fLaC")
    info = struct.pack(">HH", block, block) + b"\0\0\0" + b"\0\0\0"
    info += ((rate << 44) | ((ch - 1) << 41) | ((bps - 1) << 36) | frames).to_bytes(8, "big") + b"\0" * 16
    out += bytes([0x80]) + len(info).to_bytes(3, "big") + info
    ssc = {16: 4, 24: 6, 8: 1}[bps]
    ch_code = {"independent": ch - 1, "left_side": 8, "side_right": 9, "mid_side": 10}[mode]
    for n, start in enumerate(range(0, frames, block)):
        seg = ints[start:start + block].astype(np.int64)
        size = len(seg)
        bw = BitWriter()
        bw.write(0x3FFE, 14); bw.write(0, 1); bw.write(0, 1)
        bw.write(7, 4)                                                    # the block size follows as 16 bits
        bw.write(0, 4)                                                    # the sample rate from STREAMINFO
        bw.write(ch_code, 4)
        bw.write(0, 3)                                                    # the sample size from STREAMINFO
        bw.write(0, 1)
        for byte in utf8_number(n):
            bw.write(byte, 8)
        bw.write(size - 1, 16)
        bw.write(0, 8)                                                    # CRC-8 (not checked)
        if mode == "independent":
            for c in range(ch):
                subframe(bw, [int(v) for v in seg[:, c]], bps, kind)
        else:
            L, R = seg[:, 0], seg[:, 1]
            side = L - R
            mid = (L + R) >> 1
            if mode == "left_side":
                subframe(bw, [int(v) for v in L], bps, kind); subframe(bw, [int(v) for v in side], bps + 1, kind)
            elif mode == "side_right":
                subframe(bw, [int(v) for v in side], bps + 1, kind); subframe(bw, [int(v) for v in R], bps, kind)
            else:
                subframe(bw, [int(v) for v in mid], bps, kind); subframe(bw, [int(v) for v in side], bps + 1, kind)
        bw.align()
        bw.write(0, 16)                                                   # CRC-16 (not checked)
        out += bw.to_bytes()
    with open(path, "wb") as fh:
        fh.write(out)


def smooth_ints(frames, channels, bits, seed=1):
    rng = np.random.default_rng(seed)
    t = np.arange(frames)
    top = 2 ** (bits - 1) - 1
    cols = []
    for c in range(channels):
        x = 0.45 * np.sin(2 * np.pi * (300 + 130 * c) * t / 44100) + 0.2 * np.sin(2 * np.pi * (1500 + 70 * c) * t / 44100)
        x += 0.02 * rng.standard_normal(frames)
        cols.append(np.clip(np.round(x * top), -top - 1, top).astype(np.int64))
    return np.stack(cols, axis=1)


# --------------------------------------------------------------------------------------------------------------------- tests
class Audio(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="reaats_audio_")

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def path(self, name):
        return os.path.join(self.dir, name)

    def check(self, p, ints, rate, bits):
        got, r = reaats_audio.read_audio(p)
        self.assertEqual(r, rate)
        self.assertEqual(got.shape, ints.shape)
        np.testing.assert_array_equal(np.round(got * 2 ** (bits - 1)).astype(np.int64), ints)

    def test_sniff(self):
        write_aiff(self.path("a.aif"), smooth_ints(100, 1, 16), 44100, 16)
        write_flac(self.path("a.flac"), smooth_ints(100, 1, 16), 44100, 16)
        wavio.write_wav(self.path("a.wav"), np.zeros((10, 1)), 44100)
        with open(self.path("junk.txt"), "w") as fh:
            fh.write("not a sound")
        self.assertEqual([reaats_audio.sniff(self.path(n)) for n in ("a.aif", "a.flac", "a.wav", "junk.txt")], ["aiff", "flac", "wav", None])
        with self.assertRaises(reaats_audio.WavError) as cm:
            reaats_audio.read_audio(self.path("junk.txt"))
        self.assertIn("AIFF", str(cm.exception))

    def test_aiff_sizes_and_rates(self):
        for bits in (8, 16, 24, 32):
            for ch, rate in ((1, 44100), (2, 48000), (2, 22050.0)):
                ints = smooth_ints(500, ch, bits, seed=bits + ch)
                write_aiff(self.path("t.aif"), ints, rate, bits)
                self.check(self.path("t.aif"), ints, int(rate), bits)

    def test_aifc_little_endian_and_float(self):
        ints = smooth_ints(300, 2, 16)
        write_aiff(self.path("s.aifc"), ints, 44100, 16, aifc="sowt")
        self.check(self.path("s.aifc"), ints, 44100, 16)
        data = np.linspace(-0.5, 0.5, 100, dtype=">f4")
        comm = struct.pack(">hIh", 1, 100, 32) + ext80(44100) + b"fl32" + b"\x07not cmp"
        ssnd = struct.pack(">II", 0, 0) + data.tobytes()
        body = b"AIFC" + b"COMM" + struct.pack(">I", len(comm)) + comm + b"SSND" + struct.pack(">I", len(ssnd)) + ssnd
        with open(self.path("f.aifc"), "wb") as fh:
            fh.write(b"FORM" + struct.pack(">I", len(body)) + body)
        got, rate = reaats_audio.read_audio(self.path("f.aifc"))
        np.testing.assert_allclose(got[:, 0], data.astype(np.float64), atol=1e-7)

    def test_compressed_aifc_is_refused(self):
        comm = struct.pack(">hIh", 1, 10, 16) + ext80(44100) + b"ulaw" + b"\x07not cmp"
        ssnd = struct.pack(">II", 0, 0) + b"\0" * 10
        body = b"AIFC" + b"COMM" + struct.pack(">I", len(comm)) + comm + b"SSND" + struct.pack(">I", len(ssnd)) + ssnd
        with open(self.path("u.aifc"), "wb") as fh:
            fh.write(b"FORM" + struct.pack(">I", len(body)) + body)
        with self.assertRaises(reaats_audio.WavError) as cm:
            reaats_audio.read_audio(self.path("u.aifc"))
        self.assertIn("compressed", str(cm.exception))

    def test_flac_every_subframe_type_mono_16_bit(self):
        ints = smooth_ints(2500, 1, 16)
        for kind in ("verbatim", "fixed2", "fixed3_order2partitions", "lpc2"):
            write_flac(self.path("m.flac"), ints, 44100, 16, kind=kind, block=1000)         # 2 full blocks and a short last one
            self.check(self.path("m.flac"), ints, 44100, 16)

    def test_flac_constant_silence(self):
        ints = np.zeros((1500, 1), dtype=np.int64) + 123
        write_flac(self.path("c.flac"), ints, 48000, 16, kind="constant", block=800)
        self.check(self.path("c.flac"), ints, 48000, 16)

    def test_flac_24_bit(self):
        ints = smooth_ints(1800, 1, 24)
        for kind in ("fixed2", "lpc2"):
            write_flac(self.path("b.flac"), ints, 96000, 24, kind=kind, block=700)
            self.check(self.path("b.flac"), ints, 96000, 24)

    def test_flac_stereo_modes(self):
        ints = smooth_ints(2100, 2, 16, seed=5)
        for mode in ("independent", "left_side", "side_right", "mid_side"):
            write_flac(self.path("s.flac"), ints, 44100, 16, mode=mode, kind="fixed2", block=900)
            self.check(self.path("s.flac"), ints, 44100, 16)

    def test_flac_stereo_odd_samples_in_mid_side(self):
        rng = np.random.default_rng(3)
        ints = rng.integers(-20000, 20000, size=(600, 2))                                    # L+R odd and even: the lost bit of mid
        write_flac(self.path("o.flac"), ints, 44100, 16, mode="mid_side", kind="verbatim", block=600)
        self.check(self.path("o.flac"), ints, 44100, 16)

    def test_flac_progress_is_reported(self):
        ints = smooth_ints(30000, 1, 16)
        write_flac(self.path("p.flac"), ints, 44100, 16, kind="fixed2", block=1000)
        seen = []
        reaats_audio.read_flac(self.path("p.flac"), seen.append)
        self.assertGreater(len(seen), 3)
        self.assertEqual(seen, sorted(seen))

    def test_a_truncated_flac_is_an_error_not_a_hang(self):
        ints = smooth_ints(2000, 1, 16)
        write_flac(self.path("t.flac"), ints, 44100, 16, kind="fixed2", block=1000)
        with open(self.path("t.flac"), "rb") as fh:
            raw = fh.read()
        with open(self.path("cut.flac"), "wb") as fh:
            fh.write(raw[:len(raw) - 300])
        with self.assertRaises(Exception):
            reaats_audio.read_audio(self.path("cut.flac"))

    def test_a_real_flac_file_equals_its_aiff_twin(self):
        flac, aif = os.path.expanduser("~/Piano.flac"), os.path.expanduser("~/Piano.aif")
        if not (os.path.exists(flac) and os.path.exists(aif)):
            self.skipTest("Piano.flac and Piano.aif are not on this machine")
        a, ra = reaats_audio.read_audio(aif)
        f, rf = reaats_audio.read_audio(flac)
        self.assertEqual((ra, a.shape), (rf, f.shape))
        np.testing.assert_array_equal(np.round(a * 32768), np.round(f * 32768))

    def test_the_analysis_takes_a_flac_and_an_aiff(self):
        import subprocess
        ints = smooth_ints(44100 * 2, 1, 16)
        write_flac(self.path("tone.flac"), ints, 44100, 16, kind="lpc2", block=4096)
        write_aiff(self.path("tone.aif"), ints, 44100, 16)
        for name in ("tone.flac", "tone.aif"):
            out = self.path(name + ".ats")
            r = subprocess.run([sys.executable, "-I", os.path.join(PY, "reaats_analyse.py"), self.path(name), out, "--lowest-frequency", "100"],
                               capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertTrue(os.path.getsize(out) > 80)
        a, b = open(self.path("tone.flac.ats"), "rb").read(), open(self.path("tone.aif.ats"), "rb").read()
        self.assertEqual(a, b, "the same sound, whatever file it came from, gives the same analysis")


if __name__ == "__main__":
    unittest.main(verbosity=1)
