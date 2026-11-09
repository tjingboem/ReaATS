#!/usr/bin/env python3
"""Tests for the ReaATS analysis engine. Run:  python3 python/tests/test_engine.py   (from the ReaATS folder)
Needs Python 3 and numpy only (and lua5.4 for one optional cross-check)."""
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
PY = os.path.dirname(HERE)
ROOT = os.path.dirname(PY)
sys.path.insert(0, PY)
from pyatsyn import wavio                      # noqa: E402

CLI = os.path.join(PY, "reaats_analyse.py")
SAX_WAV = os.path.expanduser("~/blue/blue/csoundManual/examples/saxophone-alto-C-octave0.wav")


def write_bytes(path, data):
    with open(path, "wb") as fh:
        fh.write(data)


def read_bytes(path):
    with open(path, "rb") as fh:
        return fh.read()


def run_cli(*args):
    return subprocess.run([sys.executable, "-I", CLI] + [str(a) for a in args], capture_output=True, text=True)


def read_ats(path):
    raw = read_bytes(path)
    h = struct.unpack("<10d", raw[:80])
    names = "magic sr frame_size window_size partials frames ampmax frqmax dur type".split()
    d = dict(zip(names, h))
    P, NF, T = int(d["partials"]), int(d["frames"]), int(d["type"])
    per_partial = 3 if T in (2, 4) else 2
    per_frame = 1 + per_partial * P + (25 if T in (3, 4) else 0)
    assert len(raw) == 80 + 8 * per_frame * NF, "file size does not match its header"
    body = np.frombuffer(raw, dtype="<f8", offset=80).reshape(NF, per_frame)
    d["times"] = body[:, 0]
    d["amp"] = body[:, 1:1 + per_partial * P:per_partial]
    d["frq"] = body[:, 2:2 + per_partial * P:per_partial]
    d["noise"] = body[:, 1 + per_partial * P:] if T in (3, 4) else None
    return d


def strongest_frequency(d):
    peak = d["amp"].mean(axis=0).argmax()
    return float(d["frq"][:, peak][d["amp"][:, peak] > 0].mean())


def tone(freq, seconds=2.0, rate=44100, amp=0.5):
    t = np.arange(int(seconds * rate)) / rate
    return amp * np.sin(2 * np.pi * freq * t)


class WavIO(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="reaats_test_")

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def make(self, name, tag, bits, channels, payload, rate=44100, extensible=False, extra_chunk=False, data_size=None):
        fmt = struct.pack("<HHIIHH", tag, channels, rate, rate * channels * bits // 8, channels * bits // 8, bits)
        if extensible:
            fmt = struct.pack("<HHIIHH", 0xFFFE, channels, rate, rate * channels * bits // 8, channels * bits // 8, bits)
            fmt += struct.pack("<HHI", 22, bits, 3) + struct.pack("<H", tag) + b"\x00\x00\x00\x00\x10\x00\x80\x00\x00\xaa\x00\x38\x9b\x71"
        chunks = b"fmt " + struct.pack("<I", len(fmt)) + fmt
        if extra_chunk:
            chunks += b"LIST" + struct.pack("<I", 5) + b"abcde" + b"\x00"       # odd size: padded
        size = len(payload) if data_size is None else data_size
        chunks += b"data" + struct.pack("<I", size) + payload
        path = os.path.join(self.dir, name)
        write_bytes(path, b"RIFF" + struct.pack("<I", 4 + len(chunks)) + b"WAVE" + chunks)
        return path

    def test_pcm16_mono(self):
        v = np.array([0, 16384, -16384, 32767, -32768], dtype="<i2")
        x, rate = wavio.read_wav(self.make("a.wav", 1, 16, 1, v.tobytes()))
        self.assertEqual((x.shape, rate), ((5, 1), 44100))
        np.testing.assert_allclose(x[:, 0], [0, 0.5, -0.5, 32767 / 32768, -1.0])

    def test_pcm24_stereo(self):
        vals = [0, 4194304, -4194304, 8388607, -8388608, 1]           # three stereo frames
        payload = b"".join(struct.pack("<i", v)[:3] for v in vals)
        x, _ = wavio.read_wav(self.make("b.wav", 1, 24, 2, payload))
        self.assertEqual(x.shape, (3, 2))
        np.testing.assert_allclose(x.ravel(), [0, 0.5, -0.5, 8388607 / 8388608, -1.0, 1 / 8388608])

    def test_pcm8_pcm32(self):
        x, _ = wavio.read_wav(self.make("c.wav", 1, 8, 1, bytes([128, 255, 0])))
        np.testing.assert_allclose(x[:, 0], [0, 127 / 128, -1.0])
        v = np.array([0, 1 << 30, -(1 << 30)], dtype="<i4")
        x, _ = wavio.read_wav(self.make("d.wav", 1, 32, 1, v.tobytes()))
        np.testing.assert_allclose(x[:, 0], [0, 0.5, -0.5])

    def test_float32_float64(self):
        a = np.array([0.0, 0.25, -0.75, 1.0], dtype="<f4")
        x, _ = wavio.read_wav(self.make("e.wav", 3, 32, 1, a.tobytes()))
        np.testing.assert_allclose(x[:, 0], a)
        b = np.array([0.1, -0.2, 0.3], dtype="<f8")
        x, _ = wavio.read_wav(self.make("f.wav", 3, 64, 1, b.tobytes()))
        np.testing.assert_allclose(x[:, 0], b)

    def test_extensible_and_extra_chunk(self):
        v = np.array([1000, -1000, 2000, -2000], dtype="<i2")
        x, _ = wavio.read_wav(self.make("g.wav", 1, 16, 2, v.tobytes(), extensible=True, extra_chunk=True))
        self.assertEqual(x.shape, (2, 2))
        np.testing.assert_allclose(x[:, 0] * 32768, [1000, 2000])

    def test_streamed_data_size(self):
        v = np.array([100, 200, 300], dtype="<i2")
        x, _ = wavio.read_wav(self.make("h.wav", 1, 16, 1, v.tobytes(), data_size=0xFFFFFFFF))
        self.assertEqual(x.shape, (3, 1))

    def test_write_read_roundtrip(self):
        a = np.sin(np.arange(1000) * 0.1)
        p = os.path.join(self.dir, "w.wav")
        wavio.write_wav(p, a, 48000)
        x, rate = wavio.read_wav(p)
        self.assertEqual(rate, 48000)
        np.testing.assert_allclose(x[:, 0], a, atol=1e-6)
        two = np.stack([a, -a], axis=1)
        wavio.write_wav(p, two, 44100)
        x, _ = wavio.read_wav(p)
        self.assertEqual(x.shape, (1000, 2))
        np.testing.assert_allclose(x, two, atol=1e-6)

    def test_rejects_other_files(self):
        p = os.path.join(self.dir, "x.wav")
        write_bytes(p, b"not a wav file at all, really")
        with self.assertRaises(wavio.WavError):
            wavio.read_wav(p)


class Engine(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="reaats_test_")

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def wav(self, name, channels):
        p = os.path.join(self.dir, name)
        wavio.write_wav(p, np.stack(channels, axis=1) if len(channels) > 1 else channels[0], 44100)
        return p

    def test_matches_the_unmodified_pyatsyn_result(self):
        if not os.path.exists(SAX_WAV):
            self.skipTest("the Csound manual example sax file is not on this machine")
        out = os.path.join(self.dir, "sax.ats")
        r = run_cli(SAX_WAV, out, "--lowest-frequency", 100, "--no-pack-rows")      # (sharing rows reorders them)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(read_bytes(out), read_bytes(os.path.join(ROOT, "examples", "sax.ats")),
                         "must be byte-identical to examples/sax.ats (made with pyatsyn 1.0.0, soundfile and all)")

    def test_two_channels_two_files(self):
        w = self.wav("st.wav", [tone(440), tone(660)])
        out = os.path.join(self.dir, "st.ats")
        r = run_cli(w, out, "--channels", 2, "--lowest-frequency", 100)
        self.assertEqual(r.returncode, 0, r.stderr)
        info = json.loads(r.stdout.strip().splitlines()[-1])
        self.assertEqual([f["channel"] for f in info["files"]], [1, 2])
        files = [os.path.join(self.dir, "st_ch1.ats"), os.path.join(self.dir, "st_ch2.ats")]
        self.assertEqual([f["file"] for f in info["files"]], files)
        a, b = read_ats(files[0]), read_ats(files[1])
        self.assertAlmostEqual(strongest_frequency(a), 440, delta=3)
        self.assertAlmostEqual(strongest_frequency(b), 660, delta=3)
        for key in ("sr", "frame_size", "window_size", "frames", "dur", "type"):      # the common factor
            self.assertEqual(a[key], b[key], key)
        np.testing.assert_array_equal(a["times"], b["times"])
        self.assertFalse(os.path.exists(out), "with several channels only name_chN.ats files are written")

    def test_three_channels(self):
        w = self.wav("tri.wav", [tone(300), tone(500), tone(700)])
        r = run_cli(w, os.path.join(self.dir, "t.ats"), "--channels", 3, "--lowest-frequency", 100)
        self.assertEqual(r.returncode, 0, r.stderr)
        got = [strongest_frequency(read_ats(os.path.join(self.dir, "t_ch%d.ats" % i))) for i in (1, 2, 3)]
        for g, want in zip(got, (300, 500, 700)):
            self.assertAlmostEqual(g, want, delta=4)

    def test_single_channel_of_a_stereo_file_keeps_the_name(self):
        w = self.wav("st2.wav", [tone(440), tone(660)])
        out = os.path.join(self.dir, "one.ats")
        r = run_cli(w, out, "--lowest-frequency", 100)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertAlmostEqual(strongest_frequency(read_ats(out)), 440, delta=3)    # channel 1

    def test_mono_mix_has_both(self):
        w = self.wav("mix.wav", [tone(440), tone(660)])
        out = os.path.join(self.dir, "mix.ats")
        r = run_cli(w, out, "--mono-mix", "--lowest-frequency", 100)
        self.assertEqual(r.returncode, 0, r.stderr)
        d = read_ats(out)
        freqs = {round(float(d["frq"][:, i][d["amp"][:, i] > 0].mean()) / 20) * 20 for i in range(int(d["partials"])) if (d["amp"][:, i] > 0).any()}
        self.assertTrue(any(abs(f - 440) <= 20 for f in freqs) and any(abs(f - 660) <= 20 for f in freqs), freqs)

    def test_too_many_channels_is_refused(self):
        w = self.wav("m.wav", [tone(440)])
        r = run_cli(w, os.path.join(self.dir, "m.ats"), "--channels", 2)
        self.assertEqual(r.returncode, 2)
        self.assertIn("1 channel", r.stderr)

    def test_file_types(self):
        w = self.wav("ty.wav", [tone(440)])
        types = {}
        for name, flags in (("full", []), ("nophase", ["--no-phase"]), ("nonoise", ["--no-noise"]), ("bare", ["--no-phase", "--no-noise"])):
            out = os.path.join(self.dir, name + ".ats")
            r = run_cli(w, out, "--lowest-frequency", 100, *flags)
            self.assertEqual(r.returncode, 0, r.stderr)
            types[name] = int(read_ats(out)["type"])
        self.assertEqual(types, {"full": 4, "nophase": 3, "nonoise": 2, "bare": 1})

    def test_hop_size_changes_the_frame_count(self):
        w = self.wav("hop.wav", [tone(440)])
        n = {}
        for hop in (0.25, 0.5):
            out = os.path.join(self.dir, "hop%s.ats" % hop)
            self.assertEqual(run_cli(w, out, "--lowest-frequency", 100, "--hop-size", hop).returncode, 0)
            n[hop] = int(read_ats(out)["frames"])
        self.assertAlmostEqual(n[0.25] / n[0.5], 2.0, delta=0.1)

    def test_start_and_duration(self):
        w = self.wav("cut.wav", [tone(440, seconds=3.0)])
        out = os.path.join(self.dir, "cut.ats")
        r = run_cli(w, out, "--lowest-frequency", 100, "--start", 0.5, "--duration", 1.0)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertAlmostEqual(read_ats(out)["dur"], 1.0, delta=0.01)

    def test_window_length_follows_the_lowest_frequency(self):
        w = self.wav("win.wav", [tone(440)])
        sizes = {}
        for low in (100, 200):
            r = run_cli(w, os.path.join(self.dir, "w%d.ats" % low), "--lowest-frequency", low)
            sizes[low] = json.loads(r.stdout.strip().splitlines()[-1])["files"][0]["window_size"]
        self.assertAlmostEqual(sizes[100] / sizes[200], 2.0, delta=0.05)

    def test_window_types_all_run(self):
        w = self.wav("wt.wav", [tone(440, seconds=1.0)])
        for wt in ("hann", "hamming", "blackman", "kaiser", "rectangular", "tukey"):
            r = run_cli(w, os.path.join(self.dir, wt + ".ats"), "--lowest-frequency", 100, "--window-type", wt)
            self.assertEqual(r.returncode, 0, wt + ": " + r.stderr)

    def test_a_long_vibrato_voice_is_not_slow(self):
        # a track that has been asleep for a long time must not cost anything (pyatsyn's cost grew with every
        # track ever born; see the speed-up in peak_tracking.update_track_averages)
        import time
        sr = 44100
        t = np.arange(sr * 8) / sr
        phase = 2 * np.pi * (220.0 * t + (3.0 / (2 * np.pi * 5)) * (1 - np.cos(2 * np.pi * 5 * t)))
        y = sum((0.3 / h) * np.sin(h * phase) for h in range(1, 16)) * (0.5 + 0.5 * np.sin(2 * np.pi * 0.3 * t))
        y = y + 1e-3 * np.random.default_rng(1).standard_normal(len(t))
        w = self.wav("vib.wav", [y])
        t0 = time.time()
        r = run_cli(w, os.path.join(self.dir, "vib.ats"), "--lowest-frequency", 100)
        took = time.time() - t0
        self.assertEqual(r.returncode, 0, r.stderr)
        info = json.loads(r.stdout.strip().splitlines()[-1])["files"][0]
        self.assertLess(info["partials"], 400, info["partials"])
        self.assertLess(took, 12.0, "8 s of sound took %.1f s" % took)

    def test_argument_file_and_lua_summary(self):
        w = self.wav("af.wav", [tone(440, seconds=1.0)])
        out = os.path.join(self.dir, "with space.ats")
        argfile = os.path.join(self.dir, "args.txt")
        write_bytes(argfile, "\n".join([w, out, "--lowest-frequency", "100", "--summary-format", "lua"]).encode())
        r = run_cli("@" + argfile)
        self.assertEqual(r.returncode, 0, r.stderr)
        last = r.stdout.strip().splitlines()[-1]
        self.assertTrue(last.startswith("RESULT {input_channels=1,files={{file="), last)
        self.assertIn("partials=", last)
        self.assertTrue(os.path.exists(out), "a path with a space must work")

    def test_check_says_whether_this_python_can_analyse(self):
        r = run_cli("--check")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertRegex(r.stdout.strip(), r"^CHECK ok python=\d+\.\d+\.\d+ numpy=\S+ cores=\d+$")

    def test_background_mode_reports_progress_and_the_result(self):
        import time
        w = self.wav("bg.wav", [tone(440, seconds=6.0), tone(660, seconds=6.0)][0:1])
        res = os.path.join(self.dir, "bg.result")
        out = os.path.join(self.dir, "bg.ats")
        proc = subprocess.Popen([sys.executable, "-I", CLI, w, out, "--lowest-frequency", "100", "--result-file", res,
                                 "--summary-format", "lua"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        seen = []
        t0 = time.time()
        while proc.poll() is None and time.time() - t0 < 60:
            try:
                seen.append(float(read_bytes(res + ".started").decode().split()[0]))
            except (OSError, ValueError):
                pass
            time.sleep(0.01)
        self.assertEqual(proc.returncode, 0)
        self.assertTrue(os.path.exists(res), "the result file must exist when the program is done")
        self.assertTrue(read_bytes(res).decode().startswith("RESULT {input_channels=1,files={{file="))
        self.assertEqual(float(read_bytes(res + ".started").decode().split()[0]), 1.0)
        self.assertGreater(len(set(seen)), 3, "progress should move: %r" % seen[:10])
        self.assertEqual(seen, sorted(seen), "progress must not go backwards")

    def test_the_progress_file_is_a_sign_of_life(self):
        import time
        w = self.wav("hb.wav", [self.voice(200, 14)])
        res = os.path.join(self.dir, "hb.result")
        proc = subprocess.Popen([sys.executable, "-I", CLI, w, os.path.join(self.dir, "hb.ats"), "--lowest-frequency", "100",
                                 "--result-file", res], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        stamps, t0 = [], time.time()
        while proc.poll() is None and time.time() - t0 < 90:
            try:
                parts = read_bytes(res + ".started").decode().split()
                if len(parts) >= 2:                                     # progress, time, and the words for the step
                    stamps.append(float(parts[1]))
            except (OSError, ValueError):
                pass
            time.sleep(0.05)
        self.assertEqual(proc.returncode, 0)
        self.assertGreater(len(set(stamps)), 2, "the time in the progress file should keep moving")
        self.assertAlmostEqual(stamps[-1], time.time(), delta=60)
        self.assertEqual([f for f in os.listdir(self.dir) if f.endswith(".tmp")], [], "no temporary files may remain")

    def test_background_mode_can_be_cancelled(self):
        import time
        w = self.wav("cx.wav", [tone(440, seconds=8.0)])
        res = os.path.join(self.dir, "cx.result")
        out = os.path.join(self.dir, "cx.ats")
        proc = subprocess.Popen([sys.executable, "-I", CLI, w, out, "--lowest-frequency", "100", "--result-file", res],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        t0 = time.time()
        while not os.path.exists(res + ".started") and time.time() - t0 < 20:
            time.sleep(0.01)
        time.sleep(0.15)
        write_bytes(res + ".cancel", b"stop")
        proc.wait(timeout=60)
        self.assertEqual(proc.returncode, 4)
        self.assertEqual(read_bytes(res).decode().strip(), "ERROR cancelled")
        self.assertFalse(os.path.exists(out), "a cancelled analysis leaves no file")

    def test_background_mode_reports_errors(self):
        w = self.wav("be.wav", [tone(440, seconds=0.5)])
        res = os.path.join(self.dir, "be.result")
        r = run_cli(w, os.path.join(self.dir, "be.ats"), "--channels", 5, "--result-file", res)
        self.assertEqual(r.returncode, 2)
        self.assertIn("ERROR the file has 1 channel(s)", read_bytes(res).decode())

    def voice(self, f0, seconds):
        sr = 44100
        tt = np.arange(int(sr * seconds)) / sr
        phase = 2 * np.pi * (f0 * tt + (3.0 / (2 * np.pi * 5)) * (1 - np.cos(2 * np.pi * 5 * tt)))
        y = sum((0.3 / h) * np.sin(h * phase) for h in range(1, 12)) * (0.6 + 0.4 * np.sin(2 * np.pi * 0.4 * tt))
        return y + 1e-3 * np.random.default_rng(int(f0)).standard_normal(len(tt))

    def test_parallel_channels_give_exactly_the_same_files(self):
        w = self.wav("par.wav", [self.voice(200, 4), self.voice(300, 4), self.voice(450, 4)])
        files = {}
        for jobs in (1, 3, 0):
            out = os.path.join(self.dir, "j%d.ats" % jobs)
            r = run_cli(w, out, "--channels", 3, "--lowest-frequency", 100, "--jobs", jobs)
            self.assertEqual(r.returncode, 0, r.stderr)
            files[jobs] = [read_bytes(os.path.join(self.dir, "j%d_ch%d.ats" % (jobs, c))) for c in (1, 2, 3)]
        self.assertEqual(files[1], files[3], "--jobs 3 must give exactly the files of --jobs 1")
        self.assertEqual(files[1], files[0], "automatic must give exactly the same files too")
        self.assertEqual([f for f in os.listdir(self.dir) if f.endswith(".part")], [], "no .part files may remain")

    def test_parallel_channels_are_faster(self):
        import time
        if (os.cpu_count() or 1) < 4:
            self.skipTest("fewer than 4 cores")
        w = self.wav("fast.wav", [self.voice(200 + 50 * i, 10) for i in range(4)])
        took = {}
        for jobs in (1, 4):
            t0 = time.time()
            r = run_cli(w, os.path.join(self.dir, "f%d.ats" % jobs), "--channels", 4, "--lowest-frequency", 100, "--jobs", jobs)
            took[jobs] = time.time() - t0
            self.assertEqual(r.returncode, 0, r.stderr)
        self.assertLess(took[4], 0.75 * took[1], "4 channels on 4 cores took %.1f s against %.1f s on one" % (took[4], took[1]))

    def test_parallel_background_progress_and_cancel(self):
        import time
        w = self.wav("pc.wav", [self.voice(200 + 50 * i, 10) for i in range(4)])
        res = os.path.join(self.dir, "pc.result")
        out = os.path.join(self.dir, "pc.ats")
        proc = subprocess.Popen([sys.executable, "-I", CLI, w, out, "--channels", "4", "--jobs", "4", "--lowest-frequency", "100",
                                 "--result-file", res], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        seen = []
        t0 = time.time()
        while not os.path.exists(res + ".started") and time.time() - t0 < 20:
            time.sleep(0.01)
        # let it run a bit, watching the progress, then cancel
        t1 = time.time()
        while time.time() - t1 < 1.0 and proc.poll() is None:
            try:
                seen.append(float(read_bytes(res + ".started").decode().split()[0]))
            except (OSError, ValueError):
                pass
            time.sleep(0.02)
        write_bytes(res + ".cancel", b"stop")
        proc.wait(timeout=60)
        self.assertEqual(proc.returncode, 4)
        self.assertEqual(read_bytes(res).decode().strip(), "ERROR cancelled")
        self.assertEqual(seen, sorted(seen), "progress must not go backwards")
        self.assertGreater(max(seen), 0.0, "progress should have moved")
        left = [f for f in os.listdir(self.dir) if f.startswith("pc") and (f.endswith(".ats") or f.endswith(".part"))]
        self.assertEqual(left, [], "a cancelled analysis leaves nothing behind: %r" % left)

    def test_old_files_survive_a_cancel(self):
        import time
        w = self.wav("keep.wav", [self.voice(200, 10)])
        res = os.path.join(self.dir, "keep.result")
        out = os.path.join(self.dir, "keep.ats")
        write_bytes(out, b"the old file")
        proc = subprocess.Popen([sys.executable, "-I", CLI, w, out, "--lowest-frequency", "100", "--result-file", res],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        t0 = time.time()
        while not os.path.exists(res + ".started") and time.time() - t0 < 20:
            time.sleep(0.01)
        write_bytes(res + ".cancel", b"stop")
        proc.wait(timeout=60)
        self.assertEqual(read_bytes(out), b"the old file", "a cancel must not destroy the file that was there")

    def test_a_duration_past_the_end_is_cut_to_the_sound(self):
        w = self.wav("past.wav", [tone(440, seconds=2.0)])
        ref = os.path.join(self.dir, "ref.ats")
        self.assertEqual(run_cli(w, ref, "--lowest-frequency", 100).returncode, 0)
        for name, args in (("long", ["--duration", "5"]), ("few", ["--duration", "2.0004"]), ("start", ["--start", "0.5", "--duration", "10"])):
            out = os.path.join(self.dir, name + ".ats")
            r = run_cli(w, out, "--lowest-frequency", 100, *args)
            self.assertEqual(r.returncode, 0, name + ": " + r.stdout + r.stderr)
        self.assertEqual(read_bytes(os.path.join(self.dir, "long.ats")), read_bytes(ref), "a too long duration gives the whole sound")
        self.assertEqual(read_bytes(os.path.join(self.dir, "few.ats")), read_bytes(ref), "a few samples too long give the whole sound")
        self.assertAlmostEqual(read_ats(os.path.join(self.dir, "start.ats"))["dur"], 1.5, delta=0.01)

    def test_a_length_that_is_not_exact_in_floating_point_analyses(self):
        # 44109 samples at 44100 Hz: dur = samples / rate, and int(dur * rate) is 44108. The synthesis of the residual was one
        # sample short and the analysis failed with "operands could not be broadcast together" (seen on a 536 s stereo file,
        # 25750302 samples at 48000 Hz: the same thing). Every length from 44100 to 44300 must work.
        self.assertNotEqual(int(44109 / 44100 * 44100), 44109, "this length is a bad case for int()")
        for n in (44109, 44110, 44127):
            t = np.arange(n) / 44100.0
            w = self.wav("odd%d.wav" % n, [0.5 * np.sin(2 * np.pi * 440 * t)])
            out = os.path.join(self.dir, "odd%d.ats" % n)
            r = run_cli(w, out, "--lowest-frequency", 100)
            self.assertEqual(r.returncode, 0, "%d samples: %s" % (n, r.stderr))
            self.assertAlmostEqual(strongest_frequency(read_ats(out)), 440, delta=3)

    def test_sharing_rows_gives_the_same_sound_in_a_much_smaller_file(self):
        if not os.path.exists(SAX_WAV):
            self.skipTest("the Csound manual example sax file is not on this machine")
        packed, plain = os.path.join(self.dir, "p.ats"), os.path.join(self.dir, "n.ats")
        self.assertEqual(run_cli(SAX_WAV, packed, "--lowest-frequency", 100).returncode, 0)
        self.assertEqual(run_cli(SAX_WAV, plain, "--lowest-frequency", 100, "--no-pack-rows").returncode, 0)
        a, b = read_ats(packed), read_ats(plain)
        self.assertLess(a["partials"], b["partials"], "tracks that do not overlap must share rows")
        self.assertEqual(a["frames"], b["frames"])
        # the same data, row by row regrouped: the amplitude and the noise add up the same, and no row holds two tracks at once
        self.assertAlmostEqual(float(np.sum(a["amp"])), float(np.sum(b["amp"])), places=9)
        np.testing.assert_allclose(a["noise"], b["noise"], rtol=1e-9, atol=1e-12)
        self.assertEqual(int(np.count_nonzero(a["amp"])), int(np.count_nonzero(b["amp"])))
        # the sound itself (the phase-exact synthesis of the ATS format) is identical
        from pyatsyn.ats_io import ats_load
        from pyatsyn.ats_synth import synth
        sa, sb = synth(ats_load(packed), noise_pct=0.0), synth(ats_load(plain), noise_pct=0.0)
        self.assertEqual(len(sa), len(sb))
        self.assertLess(float(np.max(np.abs(sa - sb))), 1e-9)

    def test_the_rows_hold_one_track_at_a_time_with_a_silent_frame_between(self):
        from pyatsyn.atsa.tracker import pack_track_rows

        class Pk:
            def __init__(self, track):
                self.track = track
        # track 0: frames 0-3, track 1: frames 2-6 (overlaps 0), track 2: frames 5-8 (starts 2 after 0's end: may share row 0),
        # track 3: frames 4-5 (starts 1 after track 0's end: must NOT share row 0)
        spans = {0: (0, 3), 1: (2, 6), 2: (5, 8), 3: (4, 5)}
        frames = [[] for _ in range(9)]
        for t, (a, b) in spans.items():
            for f in range(a, b + 1):
                frames[f].append(Pk(t))
        n = pack_track_rows(frames, 4)
        rows = {}
        for f, peaks in enumerate(frames):
            for pk in peaks:
                rows.setdefault(pk.track, []).append(f)
        self.assertEqual(n, len(rows))
        for r, fl in rows.items():                       # in one row: no frame twice, and tracks at least two frames apart
            self.assertEqual(len(fl), len(set(fl)), "a frame holds two peaks in row %d" % r)
        self.assertLessEqual(n, 3)
        self.assertGreaterEqual(n, 3, "tracks 1, 2 and 3 are alive together at frame 5")

    def test_a_start_past_the_end_says_so(self):
        w = self.wav("beyond.wav", [tone(440, seconds=1.0)])
        r = run_cli(w, os.path.join(self.dir, "b.ats"), "--start", "3")
        self.assertEqual(r.returncode, 2)
        self.assertIn("ERROR the start (3.00 s) is beyond the end of the sound (1.00 s)", r.stdout)

    def test_errors_are_also_printed_on_stdout(self):
        w = self.wav("er.wav", [tone(440, seconds=0.5)])
        r = run_cli(w, os.path.join(self.dir, "er.ats"), "--channels", 4)
        self.assertEqual(r.returncode, 2)
        self.assertIn("ERROR the file has 1 channel(s)", r.stdout)

    def test_bad_options_are_refused(self):
        w = self.wav("bad.wav", [tone(440, seconds=0.5)])
        out = os.path.join(self.dir, "bad.ats")
        self.assertEqual(run_cli(w, out, "--lowest-frequency", 0).returncode, 2)
        self.assertEqual(run_cli(w, out, "--lowest-frequency", 500, "--highest-frequency", 200).returncode, 2)
        self.assertEqual(run_cli(w, out, "--window-type", "nonsense").returncode, 2)
        self.assertEqual(run_cli(os.path.join(self.dir, "missing.wav"), out).returncode, 2)

    def test_the_lua_reader_opens_the_result(self):
        lua = shutil.which("lua5.4")
        if not lua:
            self.skipTest("lua5.4 not installed")
        w = self.wav("lu.wav", [tone(440), tone(660)])
        out = os.path.join(self.dir, "lu.ats")
        self.assertEqual(run_cli(w, out, "--channels", 2, "--lowest-frequency", 100).returncode, 0)
        script = ('package.path = "%s/lib/?.lua;" .. package.path\nlocal ats = require("ats_file")\n'
                  'local a = assert(ats.load("%s")); local b = assert(ats.load("%s"))\n'
                  'print(a.type, b.type, a.frames == b.frames, a.has_phase, a.has_noise)') % (ROOT, os.path.join(self.dir, "lu_ch1.ats"), os.path.join(self.dir, "lu_ch2.ats"))
        r = subprocess.run([lua, "-e", script], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.split(), ["4", "4", "true", "true", "true"])


if __name__ == "__main__":
    unittest.main(verbosity=1)
