#!/usr/bin/env python3
"""Tests for the spatial output (pseudo-stereo and VBAP) of python/reaats_synth.py. Run: python3 python/tests/test_spatial.py"""
import os
import struct
import sys
import tempfile
import unittest

import numpy as np

PY = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, PY)
import reaats_synth as S                                    # noqa: E402

SR, FS, FRAMES = 44100, 441, 60


def make_ats(path, freqs, amps=None, noise=None):
    """A type 1 (type 3 with noise) file: one constant partial per frequency."""
    n = len(freqs)
    amps = amps or [0.3] * n
    typ = 3 if noise is not None else 1
    head = [123.0, SR, FS, 1764.0, n, FRAMES, max(amps), max(freqs), FRAMES * FS / SR, typ]
    rows = []
    for f in range(FRAMES):
        row = [f * FS / SR]
        for p in range(n):
            row += [amps[p], freqs[p]]
        if noise is not None:
            row += [noise] * 25
        rows.append(row)
    with open(path, "wb") as fh:
        fh.write(struct.pack("<10d", *head))
        fh.write(np.array(rows, dtype="<f8").tobytes())


def render(path, spatial, sines=True, noise=False):
    a = S.load_ats(path)
    S.NOISE_SHAPE = "corrected"
    out, _ = S.render_channel(a, 0.0, None, sines, noise, 1, 0.0, 1.0, None, spatial)
    return out


class SpatialTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.path = os.path.join(self.dir, "t.ats")
        make_ats(self.path, [440.0, 880.0, 1320.0, 1760.0])

    def test_off_is_the_plain_sound(self):
        a = render(self.path, None)
        self.assertEqual(a.ndim, 1)
        b = render(self.path, S.Spatial("off"))
        self.assertTrue(np.array_equal(a, b) or b.ndim == 2)

    def test_pseudo_full_split_odd_partials_left_even_right(self):
        plain = render(self.path, None)
        out = render(self.path, S.Spatial("pseudo", 1.0))
        self.assertEqual(out.shape[0], 2)
        left, right = out
        # partial 1 and 3 (440, 1320) left, 2 and 4 (880, 1760) right: with 4 equal partials the two halves add up to the plain sound x makeup
        makeup = 10 ** (S.PSEUDO_MAKEUP_DB / 20.0)
        self.assertLess(np.max(np.abs((left + right) - plain * makeup)), 1e-3)
        spec_l, spec_r = np.abs(np.fft.rfft(left[5000:25000])), np.abs(np.fft.rfft(right[5000:25000]))
        k = lambda f: int(round(f * 20000 / SR))
        self.assertGreater(spec_l[k(440)], 20 * spec_r[k(440)])
        self.assertGreater(spec_r[k(880)], 20 * spec_l[k(880)])

    def test_pseudo_zero_amount_is_the_same_in_both(self):
        left, right = render(self.path, S.Spatial("pseudo", 0.0))
        self.assertLess(np.max(np.abs(left - right)), 1e-5)

    def test_vbap_is_constant_power_between_two_outputs(self):
        sp = S.Spatial("vbap", 1.0, 5)
        for j in range(8):
            for freq in (50.0, 500.0):
                g = sp.gains(j, 8, freq)
                self.assertAlmostEqual(sum(x * x for _, x in g), 1.0, places=6)
                self.assertEqual(len(g), 2)
                self.assertEqual(g[1][0], g[0][0] + 1)

    def test_vbap_low_end_stays_in_the_centre_and_width_grows_with_the_partial(self):
        sp = S.Spatial("vbap", 1.0, 7)
        low = dict(sp.gains(5, 8, 60.0))
        self.assertAlmostEqual(low[3], 1.0, places=6)              # the centre of 7 outputs is output index 3, with the whole gain
        first = sp.gains(0, 8, 500.0)                              # the first partial is always in the centre (width 0)
        last_even = sp.gains(6, 8, 500.0)                          # a high even partial is far to the left
        self.assertLess(last_even[0][0], first[0][0])

    def test_vbap_zero_spread_collapses_to_the_centre(self):
        sp = S.Spatial("vbap", 0.0, 4)
        self.assertEqual(sp.gains(0, 8, 500.0), sp.gains(7, 8, 500.0))

    def test_vbap_render_has_the_asked_number_of_outputs_and_the_same_power(self):
        plain = render(self.path, None)
        out = render(self.path, S.Spatial("vbap", 1.0, 6))
        self.assertEqual(out.shape[0], 6)
        # constant power per partial: the sum of the squares of the outputs equals that of the plain sound when the partials do not overlap
        p_out = float(np.sum(out.astype(np.float64) ** 2))
        p_plain = float(np.sum(plain ** 2))
        self.assertAlmostEqual(p_out / p_plain, 1.0, delta=0.02)

    def test_noise_follows_the_gains_and_the_cache_keeps_spatial_apart(self):
        p = os.path.join(self.dir, "n.ats")
        make_ats(p, [440.0], noise=0.5)
        a = S.load_ats(p)
        S.NOISE_SHAPE = "corrected"
        cache = os.path.join(self.dir, "cache")
        plain, _ = S.render_channel(a, 0.0, None, False, True, 1, 0.0, 1.0, cache, None)
        sp = S.Spatial("pseudo", 1.0)
        first, _ = S.render_channel(a, 0.0, None, False, True, 1, 0.0, 1.0, cache, sp)
        again, _ = S.render_channel(a, 0.0, None, False, True, 1, 0.0, 1.0, cache, sp)    # from the cache
        self.assertEqual(plain.ndim, 1)
        self.assertEqual(first.shape[0], 2)
        self.assertTrue(np.array_equal(first, again))
        self.assertGreater(float(np.std(first[0])), 0.0)
        self.assertGreater(float(np.std(first[1])), 0.0)
        self.assertLess(abs(np.corrcoef(first[0], first[1])[0, 1]), 0.2)       # different bands: not the same noise

    def test_command_line_writes_a_multichannel_wav(self):
        wav = os.path.join(self.dir, "o.wav")
        S.main(["--out", wav, "--spatial", "vbap", "--spatial-channels", "4", "--jobs", "1", self.path])
        with open(wav, "rb") as fh:
            raw = fh.read()
        nch = struct.unpack("<H", raw[22:24])[0]
        self.assertEqual(nch, 4)
        wav2 = os.path.join(self.dir, "o2.wav")
        S.main(["--out", wav2, "--spatial", "vbap", "--spatial-channels", "4", "--mixdown", "stereo", "--jobs", "1", self.path])
        with open(wav2, "rb") as fh:
            self.assertEqual(struct.unpack("<H", fh.read()[22:24])[0], 2)


if __name__ == "__main__":
    unittest.main()
