#!/usr/bin/env python3
"""Tests of the synthesis with the stored phase. Run:  python3 python/tests/test_phase.py   (from the ReaATS folder)
Needs Python 3 and numpy only."""
import os
import struct
import subprocess
import sys
import tempfile
import unittest

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
PY = os.path.dirname(HERE)
sys.path.insert(0, PY)
from pyatsyn import wavio                      # noqa: E402

SYNTH = os.path.join(PY, "reaats_synth.py")
SR, FS = 44100, 441                             # hop of 441 samples: a partial of 441 Hz has exactly 1 cycle per frame... (see F below)


def write_ats(path, amp, frq, pha=None, noise=False):
    """amp, frq (, pha): arrays [partial, frame]. Type 2 with phase, type 1 without."""
    P, NF = amp.shape
    typ = 2 if pha is not None else 1
    head = struct.pack("<10d", 123.0, SR, FS, 4 * FS, P, NF, float(amp.max()), float(frq.max()), NF * FS / SR, typ)
    rows = []
    for f in range(NF):
        r = [f * FS / SR]
        for p in range(P):
            r += [amp[p, f], frq[p, f]] + ([pha[p, f]] if pha is not None else [])
        rows.append(r)
    with open(path, "wb") as fh:
        fh.write(head)
        fh.write(np.array(rows, dtype="<f8").tobytes())


def write_edits(path, cells):
    """cells: (partial, frame, amp, frq), counted from 1."""
    with open(path, "wb") as fh:
        fh.write(np.array(cells, dtype="<f8").tobytes())


def render(ats, *extra, out=None):
    out = out or ats + ".wav"
    r = subprocess.run([sys.executable, "-I", SYNTH, "--out", out, "--no-noise", "--no-limit", "--seed", "1"] + list(extra) + [ats],
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    y, sr = wavio.read_wav(out)
    return np.asarray(y, float).reshape(-1)


F = 441.0                                        # 441 Hz = 100 samples per cycle; one frame (441 samples) = 4.41 cycles


class PhaseSynthesis(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="reaats_phase_")
        self.path = os.path.join(self.dir, "t.ats")

    def phases(self, phi0, nf, f=F):
        return np.array([[phi0 + 2 * np.pi * f * k * FS / SR for k in range(nf)]])

    def test_a_steady_partial_with_stored_phase_is_the_cosine_of_that_phase(self):
        nf, phi0 = 20, 1.0
        amp, frq = np.full((1, nf), 0.5), np.full((1, nf), F)
        pha = np.angle(np.exp(1j * self.phases(phi0, nf)))                       # (stored wrapped to -pi..pi, as the analysis does)
        write_ats(self.path, amp, frq, pha)
        y = render(self.path)
        t = np.arange(len(y))
        want = 0.5 * np.cos(2 * np.pi * F * t / SR + phi0)
        sl = slice(FS, (nf - 2) * FS)                                              # (away from the fade in and out)
        self.assertLess(np.max(np.abs(y[sl] - want[sl])), 1e-6)

    def test_no_phase_flag_and_a_file_without_phase_give_the_phase_from_the_frequency(self):
        nf = 20
        amp, frq = np.full((1, nf), 0.5), np.full((1, nf), F)
        write_ats(self.path, amp, frq, np.angle(np.exp(1j * self.phases(1.0, nf))))
        a = render(self.path, "--no-phase")
        write_ats(self.path, amp, frq)                                             # type 1: no phase at all
        b = render(self.path)
        self.assertLess(np.max(np.abs(a - b)), 1e-9)
        t = np.arange(len(a))
        want = 0.5 * np.sin(2 * np.pi * F * t / SR)
        sl = slice(FS, (nf - 2) * FS)
        self.assertLess(np.max(np.abs(a[sl] - want[sl])), 1e-6)

    def test_two_tracks_in_one_row_each_start_with_their_own_phase(self):
        nf = 30
        amp, frq = np.zeros((1, nf)), np.full((1, nf), F)
        amp[0, 2:12] = 0.5                                                         # frames 3..12 (1-based)
        amp[0, 13:25] = 0.5                                                        # one silent frame between
        pha = np.zeros((1, nf))
        pha[0, 2:12] = 0.3 + 2 * np.pi * F * np.arange(10) * FS / SR
        pha[0, 13:25] = 2.0 + 2 * np.pi * F * np.arange(12) * FS / SR
        pha = np.angle(np.exp(1j * pha))
        write_ats(self.path, amp, frq, pha)
        y = render(self.path)
        t = np.arange(len(y))
        w1 = 0.5 * np.cos(2 * np.pi * F * (t - 2 * FS) / SR + 0.3)
        w2 = 0.5 * np.cos(2 * np.pi * F * (t - 13 * FS) / SR + 2.0)
        s1, s2 = slice(3 * FS, 11 * FS), slice(14 * FS, 24 * FS)
        self.assertLess(np.max(np.abs(y[s1] - w1[s1])), 1e-6)
        self.assertLess(np.max(np.abs(y[s2] - w2[s2])), 1e-6)

    def test_an_edited_track_is_rebuilt_from_its_frequency_and_stays_smooth(self):
        nf = 30
        amp, frq = np.full((1, nf), 0.5), np.full((1, nf), F)
        pha = np.angle(np.exp(1j * self.phases(0.5, nf)))
        write_ats(self.path, amp, frq, pha)
        edits = os.path.join(self.dir, "e.bin")
        write_edits(edits, [(1, f, 0.5, F * 2 ** (7 / 12.0)) for f in range(11, 31)])      # frames 11..30 up a fifth
        y = render(self.path, "--edits", edits)
        self.assertLess(np.max(np.abs(np.diff(y[FS:(nf - 2) * FS]))), 0.5 * 2 * np.pi * F * 2 ** (7 / 12.0) / SR * 1.2)    # no jump: the slope of the fastest sine
        # the first part is untouched (stored phase), the end really is a fifth higher
        t = np.arange(len(y))
        self.assertLess(np.max(np.abs(y[FS:9 * FS] - (0.5 * np.cos(2 * np.pi * F * t / SR + 0.5))[FS:9 * FS])), 1e-3)
        seg = y[20 * FS:28 * FS]
        spec = np.abs(np.fft.rfft(seg * np.hanning(len(seg))))
        peak = np.argmax(spec) * SR / len(seg)
        self.assertAlmostEqual(peak, F * 2 ** (7 / 12.0), delta=8.0)

    def test_playing_from_the_middle_keeps_the_phase(self):
        nf = 30
        amp, frq = np.full((1, nf), 0.5), np.full((1, nf), F)
        write_ats(self.path, amp, frq, np.angle(np.exp(1j * self.phases(1.0, nf))))
        y = render(self.path, "--from", "%.9f" % (10 * FS / SR))
        t = np.arange(len(y)) + 10 * FS
        want = 0.5 * np.cos(2 * np.pi * F * t / SR + 1.0)
        sl = slice(0, (nf - 12) * FS)
        self.assertLess(np.max(np.abs(y[sl] - want[sl])), 1e-6)

    def test_a_row_the_edits_added_is_built_from_the_frequency(self):
        nf = 20
        amp, frq = np.full((1, nf), 0.5), np.full((1, nf), F)
        write_ats(self.path, amp, frq, np.angle(np.exp(1j * self.phases(0.2, nf))))
        edits = os.path.join(self.dir, "e.bin")
        write_edits(edits, [(2, f, 0.25, 2 * F) for f in range(5, 15)])              # a second row: new cells
        y = render(self.path, "--edits", edits)
        self.assertEqual(len(y), (nf - 1) * FS)
        self.assertTrue(np.all(np.isfinite(y)))
        self.assertGreater(np.max(np.abs(y[6 * FS:12 * FS])), 0.5)                   # (both rows sound)

    def test_the_stereo_set_and_parallel_workers_use_the_phase_too(self):
        nf = 20
        amp, frq = np.full((1, nf), 0.5), np.full((1, nf), F)
        pha = np.angle(np.exp(1j * self.phases(1.0, nf)))
        p2 = os.path.join(self.dir, "t2.ats")
        write_ats(self.path, amp, frq, pha)
        write_ats(p2, amp, frq, pha)
        r = subprocess.run([sys.executable, "-I", SYNTH, "--out", os.path.join(self.dir, "m.wav"), "--no-noise", "--no-limit", "--jobs", "2",
                            self.path, p2], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        y, _ = wavio.read_wav(os.path.join(self.dir, "m.wav"))
        y = np.asarray(y, float)
        t = np.arange(y.shape[0])
        want = 0.5 * np.cos(2 * np.pi * F * t / SR + 1.0)
        self.assertLess(np.max(np.abs(y[FS:(nf - 3) * FS, 0] - want[FS:(nf - 3) * FS])), 1e-6)


if __name__ == "__main__":
    unittest.main()
