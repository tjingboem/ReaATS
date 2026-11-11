#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""reaats_analyse.py -- ATS analysis for ReaATS: a WAV file in, one standard Csound-compatible .ats file per channel out.

Needs Python 3 and numpy, nothing else. The analysis is the ATS analysis of Di Liscia, Moss and Pampin as implemented
in the Python package pyatsyn (BSD 3-clause, included in the folder pyatsyn/ with its licence).

    python3 reaats_analyse.py sound.wav sound.ats [options]

Channels: --channels N analyses the first N channels of the file, each on its own with the same options, and writes
one file per channel (sound_ch1.ats, sound_ch2.ats, ...; with N = 1 exactly the name given). --mono-mix analyses the
average of all channels as one sound instead. All files of a set have the same frame size, frame count and duration.

On success the last line printed is a JSON summary (the list of files with their partials, frames, duration, window
and hop size); problems are written to stderr and the exit code is 2.

Options that Csound's atsa has and this analyser does not: -T (SMR threshold) and -S (minimum segment SMR).
"""
import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

MIN_PYTHON = (3, 8)


def check_environment():
    """--check: says whether this Python can run the analysis (the ReaATS editor asks before it analyses).
    Prints one line, CHECK ok|old|missing, and exits 0 only when everything is there. Runs before numpy is imported."""
    v = sys.version_info
    py = "%d.%d.%d" % (v[0], v[1], v[2])
    if (v[0], v[1]) < MIN_PYTHON:
        print("CHECK old python=%s needs=%d.%d" % (py, MIN_PYTHON[0], MIN_PYTHON[1]))
        sys.exit(3)
    try:
        import numpy
    except ImportError:
        print("CHECK missing numpy python=%s" % py)
        sys.exit(3)
    print("CHECK ok python=%s numpy=%s cores=%d" % (py, numpy.__version__, os.cpu_count() or 1))
    sys.exit(0)


def available_memory_bytes():
    """The memory that is free for programs, in bytes, or None when it cannot be found out. The same call on Linux, Windows and macOS: the editor asks
    this program (--memory) so that it needs no operating system specific code of its own. (Only Linux has been tried.)"""
    try:
        if sys.platform.startswith("linux"):
            with open("/proc/meminfo") as fh:
                for line in fh:
                    if line.startswith("MemAvailable:"):
                        return int(line.split()[1]) * 1024
        elif sys.platform == "win32":
            import ctypes

            class MEMORYSTATUSEX(ctypes.Structure):
                _fields_ = [("dwLength", ctypes.c_ulong), ("dwMemoryLoad", ctypes.c_ulong), ("ullTotalPhys", ctypes.c_ulonglong),
                            ("ullAvailPhys", ctypes.c_ulonglong), ("ullTotalPageFile", ctypes.c_ulonglong), ("ullAvailPageFile", ctypes.c_ulonglong),
                            ("ullTotalVirtual", ctypes.c_ulonglong), ("ullAvailVirtual", ctypes.c_ulonglong), ("sullAvailExtendedVirtual", ctypes.c_ulonglong)]
            st = MEMORYSTATUSEX()
            st.dwLength = ctypes.sizeof(MEMORYSTATUSEX)
            if ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(st)):
                return int(st.ullAvailPhys)
        elif sys.platform == "darwin":
            import re
            import subprocess
            out = subprocess.run(["vm_stat"], capture_output=True, text=True, timeout=5).stdout
            page = int(re.search(r"page size of (\d+) bytes", out).group(1))
            pages = sum(int(m.group(1)) for m in re.finditer(r"Pages (?:free|inactive|speculative):\s+(\d+)", out))
            return pages * page
    except Exception:
        return None
    return None


if "--memory" in sys.argv[1:]:
    mem = available_memory_bytes()
    print("MEMORY %s" % (mem if mem is not None else "unknown"))
    sys.exit(0)

if "--check" in sys.argv[1:]:
    check_environment()

import multiprocessing                                   # noqa: E402
import threading                                         # noqa: E402
import time                                              # noqa: E402

import numpy as np                                        # noqa: E402
from pyatsyn import wavio                                 # noqa: E402
import reaats_audio                                       # noqa: E402  (WAV, AIFF and FLAC)
from pyatsyn.ats_io import ats_save                       # noqa: E402
from pyatsyn.atsa.tracker import tracker_array            # noqa: E402
from pyatsyn.atsa.utils import db_to_amp                  # noqa: E402
from pyatsyn.atsa.windows import VALID_FFT_WINDOW_DEFINITIONS   # noqa: E402

WINDOW_TYPES = sorted(set(VALID_FFT_WINDOW_DEFINITIONS))


def build_parser():
    p = argparse.ArgumentParser(
        description="ATS analysis: WAV in, one .ats file per channel out (Python 3 + numpy only).",
        epilog="Not available here, but in Csound's atsa: -T (SMR threshold) and -S (minimum segment SMR). "
               "Arguments can also be read from a file: @args.txt (one argument per line).",
        fromfile_prefix_chars="@")
    p.add_argument("wav", help="the sound to analyse (WAV: PCM 8/16/24/32 bit or float; AIFF/AIFC; FLAC; any number of channels)")
    p.add_argument("ats", help="the .ats file to write (with --channels above 1: name_ch1.ats, name_ch2.ats, ...)")
    g = p.add_argument_group("channels")
    g.add_argument("--channels", type=int, default=1, help="how many channels to analyse, each into its own file (default 1)")
    g.add_argument("--mono-mix", action="store_true", help="analyse the average of all channels as one sound")
    g = p.add_argument_group("analysis (the options of docs/analysis_options.md)")
    g.add_argument("--start", type=float, default=0.0, help="where the analysis starts, seconds (default 0)")
    g.add_argument("--duration", type=float, default=None, help="how much is analysed, seconds (default: to the end)")
    g.add_argument("--lowest-frequency", type=float, default=20.0, help="lowest frequency, Hz, above 0 (default 20)")
    g.add_argument("--highest-frequency", type=float, default=20000.0, help="highest frequency, Hz (default 20000)")
    g.add_argument("--frequency-deviation", type=float, default=0.1, help="largest relative frequency change between frames when matching peaks (default 0.1)")
    g.add_argument("--window-cycles", type=float, default=4, help="periods of the lowest frequency in the window (default 4)")
    g.add_argument("--window-type", default="blackman-harris-4-1", choices=WINDOW_TYPES, help="FFT window (default blackman-harris-4-1)")
    g.add_argument("--window-alpha", type=float, default=0.5, help="Tukey window parameter (default 0.5)")
    g.add_argument("--window-beta", type=float, default=1.0, help="parameter of windows that take a beta (default 1.0)")
    g.add_argument("--hop-size", type=float, default=0.25, help="distance between frames as a fraction of the window (default 0.25)")
    g.add_argument("--fft-size", type=int, default=None, help="force an FFT size, a power of 2 (default: automatic)")
    g.add_argument("--window-length", type=int, default=None, help="force the window length in samples (default: from the lowest frequency)")
    g.add_argument("--amp-threshold-db", type=float, default=-60.0, help="quietest peak that counts, dB (default -60)")
    g.add_argument("--track-length", type=int, default=3, help="frames used to smooth a track's frequency (default 3)")
    g.add_argument("--min-segment-length", type=int, default=3, help="shorter track pieces are dropped, frames (default 3)")
    g.add_argument("--min-gap-length", type=int, default=3, help="longer gaps in a track are not bridged, frames (default 3)")
    g.add_argument("--last-peak-contribution", type=float, default=0.0, help="extra weight of the previous frame when a track is smoothed (default 0)")
    g.add_argument("--smr-continuity", type=float, default=0.0, help="share of the signal-to-mask ratio in the matching cost (default 0)")
    g.add_argument("--no-optimize", action="store_true", help="do not prune the tracks after tracking")
    g.add_argument("--optimize-amp-threshold-db", type=float, default=None, help="extra amplitude threshold in the pruning, dB")
    g = p.add_argument_group("output")
    g.add_argument("--no-pack-rows", action="store_true",
                   help="give every track a row of its own in the file (the original ATS way; the file of a long sound is then enormous)")
    g.add_argument("--no-phase", action="store_true", help="do not store the phase (file type 3 instead of 4)")
    g.add_argument("--no-noise", action="store_true", help="no residual and no noise bands (faster; file type 2 or 1)")
    g.add_argument("--residual-wav", default=None, help="also write the residual of each channel to this WAV (name_ch1.wav for several channels)")
    g.add_argument("--jobs", type=int, default=0,
                   help="CPU cores to use: channels are analysed in parallel, one per core (0 = automatic: all cores but two, at least 1)")
    g.add_argument("--result-file", default=None,
                   help="background mode (used by the editor): write progress (0..1) to RESULT.started and, when done, the last "
                        "line (RESULT ... or ERROR ...) to RESULT; stop when RESULT.cancel appears")
    g.add_argument("--summary-format", choices=("json", "lua"), default="json",
                   help="format of the last line printed: json, or lua (RESULT {a=1,...}, read by the ReaATS editor)")
    g.add_argument("-v", "--verbose", action="store_true")
    return p


_SHARED = None          # in a worker: the array the parent reads the progress from


def _init_worker(shared):
    global _SHARED
    _SHARED = shared


def make_progress(result_file, count, index, parallel=False):
    """The progress function for one channel. In one process it writes the overall progress to RESULT.started itself;
    in a worker it puts its own progress in the shared array (the parent writes the file). Both stop when the cancel
    file appears."""
    started, cancel = (result_file + ".started", result_file + ".cancel") if result_file else (None, None)
    state = {"last": -1.0, "stage": None, "t0": time.time(), "times": {}}

    def note_stage(p):
        """Adds up how long each stage takes (reported in the result, so that slow steps can be found)."""
        key = stage_key(p)
        if key != state["stage"]:
            now = time.time()
            if state["stage"] is not None:
                state["times"][state["stage"]] = state["times"].get(state["stage"], 0.0) + now - state["t0"]
            state["stage"], state["t0"] = key, now

    def report(p):
        if cancel and os.path.exists(cancel):
            raise Cancelled()
        p = min(max(p, 0.0), 1.0)
        note_stage(p)
        if parallel:
            _SHARED[index] = p
        elif started:
            overall = (index + p) / count
            if overall - state["last"] >= 0.004 or stage_label(p) != _BEAT["label"]:
                state["last"] = overall
                write_progress(started, overall, ("channel %d: " % (index + 1) if count > 1 else "") + stage_label(p))

    def timings():
        times = dict(state["times"])
        if state["stage"] is not None:
            times[state["stage"]] = times.get(state["stage"], 0.0) + time.time() - state["t0"]
        return {k: round(v, 1) for k, v in times.items()}
    report.timings = timings
    return report


def analyse_channel(task):
    """Analyses one channel and writes its file (as path.part; the caller renames it when the whole set is done).
    Runs in the main process or in a worker. Returns the summary of the file."""
    kw = dict(task["kw"])
    report = None
    if task["result_file"]:
        report = make_progress(task["result_file"], task["count"], task["n"] - 1, task["parallel"])
        kw["progress"] = report
    snd = tracker_array(np.ascontiguousarray(task["x"]), task["rate"], **kw)
    if report:
        report(0.995)                                                # the file is being written
    ats_save(snd, task["path"] + ".part", save_phase=task["save_phase"], save_noise=task["save_noise"])
    timings = report.timings() if report else {}
    return {
        "file": task["path"], "channel": task["label"], "partials": int(snd.partials), "frames": int(snd.frames),
        "duration": float(snd.dur), "sample_rate": int(snd.sampling_rate),
        "frame_size": int(snd.frame_size), "window_size": int(snd.window_size),
        "noise_bands": int(len(snd.bands)) if task["save_noise"] else 0,
        "phase": task["save_phase"],
        "timings": timings,
    }


def choose_jobs(requested, count):
    """How many channels run at the same time."""
    cores = os.cpu_count() or 1
    jobs = requested if requested > 0 else max(1, cores - 2)
    return max(1, min(jobs, count))


def channel_path(path, n, count):
    if count == 1:
        return path
    stem, ext = os.path.splitext(path)
    return "%s_ch%d%s" % (stem, n, ext)


class Cancelled(Exception):
    pass


RESULT_FILE = None


_BEAT = {"progress": 0.0, "label": "", "stop": None}

# What the analysis is busy with, by how far it is (the tracker reports 0..1 over these steps). The editor shows the text, so that
# a long step that moves the bar slowly (or not at all) is not mistaken for a program that has stopped.
STAGES = [(0.80, "tracking", "finding the peaks and following them as tracks"),
          (0.85, "pruning", "pruning and joining the tracks"),
          (0.93, "rebuilding", "rebuilding the sound from the partials (to find the noise)"),
          (0.99, "noise", "measuring the noise in 25 bands"),
          (1.01, "writing", "writing the file")]


def stage_label(p):
    for limit, _, text in STAGES:
        if p < limit:
            return text
    return STAGES[-1][2]


def stage_key(p):
    for limit, key, _ in STAGES:
        if p < limit:
            return key
    return STAGES[-1][1]


def describe(values):
    """The stage text for one or more channels' progress values: one text when they agree, else one per channel."""
    labels = [stage_label(v) for v in values]
    if len(values) == 1 or len(set(labels)) == 1:
        return ("all channels: " if len(values) > 1 else "") + labels[0]
    return "; ".join("channel %d: %s" % (i + 1, t) for i, t in enumerate(labels))


def write_progress(path, progress, label=None):
    """RESULT.started holds 'progress seconds-since-1970 text': the editor reads the time as a sign of life and shows the text."""
    _BEAT["progress"] = progress
    if label is not None:
        _BEAT["label"] = label
    write_text(path, "%.4f %.3f %s" % (progress, time.time(), _BEAT["label"]))


def start_heartbeat(path):
    """A thread that rewrites the progress file every two seconds, so the editor can tell that the program is alive even
    while a long step reports nothing. Returns a function that stops it."""
    stop = threading.Event()

    def beat():
        while not stop.wait(2.0):
            try:
                write_progress(path, _BEAT["progress"])
            except OSError:
                pass
    t = threading.Thread(target=beat, daemon=True)
    t.start()
    return stop.set


def write_text(path, text):
    """Writes a small file so that a reader never sees half of it."""
    tmp = "%s.%d.%d.tmp" % (path, os.getpid(), threading.get_ident())     # (the heartbeat thread writes the same file)
    with open(tmp, "w") as fh:
        fh.write(text)
    os.replace(tmp, path)


def to_lua(v):
    """Writes a value as a Lua table literal in the format of ReaATS's own serializer (lib/reaats_serial.lua)."""
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, str):
        return '"' + v.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'
    if isinstance(v, dict):
        return "{" + ",".join("%s=%s" % (k, to_lua(x)) for k, x in v.items()) + "}"
    if isinstance(v, (list, tuple)):
        return "{" + ",".join(to_lua(x) for x in v) + "}"
    raise TypeError("cannot write %r" % (v,))


def fail(msg):
    sys.stderr.write("reaats_analyse: " + msg + "\n")
    print("ERROR " + msg)                  # also on stdout: the editor reads what the program prints
    if RESULT_FILE:
        write_text(RESULT_FILE, "ERROR " + msg + "\n")
    sys.exit(2)


def run_parallel(tasks, jobs):
    """Analyses the channels at the same time, `jobs` at once, one process each; returns the summaries in channel order.
    The parent writes the overall progress and watches for the cancel file."""
    ctx = multiprocessing.get_context()
    shared = ctx.Array("d", len(tasks), lock=False)
    pool = ctx.Pool(processes=jobs, initializer=_init_worker, initargs=(shared,))
    try:
        pending = [pool.apply_async(analyse_channel, (t,)) for t in tasks]
        cancel = (RESULT_FILE + ".cancel") if RESULT_FILE else None
        last = -1.0
        while True:
            if cancel and os.path.exists(cancel):
                raise Cancelled()
            for r in pending:                           # the first failure ends everything (r.get() raises it)
                if r.ready() and not r.successful():
                    r.get()
            if RESULT_FILE:
                overall = sum(shared) / len(tasks)
                text = describe(list(shared))
                if overall - last >= 0.004 or text != _BEAT["label"]:
                    last = overall
                    write_progress(RESULT_FILE + ".started", overall, text)
            if all(r.ready() for r in pending):
                return [r.get() for r in pending]
            time.sleep(0.05)
    finally:
        pool.terminate()
        pool.join()


def expand_args(argv):
    """`--args-file PATH` as the only argument: the arguments are read from that file, one per line. (A separate word, so that no quote ends up
    glued to a path: with a space in a Windows user name, `@"C:\\Users\\First Last\\..."` is not understood by every way of starting a program.)"""
    if len(argv) == 2 and argv[0] == "--args-file":
        with open(argv[1], encoding="utf-8") as fh:
            return [line.rstrip("\r\n") for line in fh if line.strip()]
    return argv


def main(argv=None):
    global RESULT_FILE
    a = build_parser().parse_args(expand_args(sys.argv[1:] if argv is None else argv))
    RESULT_FILE = a.result_file
    if RESULT_FILE:
        # (the editor removes old result/cancel files before it starts the program, so a Cancel clicked at once is kept)
        write_progress(RESULT_FILE + ".started", 0.0)
        stop_beat = start_heartbeat(RESULT_FILE + ".started")
    try:
        kind = reaats_audio.sniff(a.wav) if os.path.exists(a.wav) else None
        if RESULT_FILE and kind == "flac":
            write_progress(RESULT_FILE + ".started", 0.0, "reading the sound: a FLAC file is decoded first, which takes a while for a long sound")
        samples, rate = reaats_audio.read_audio(a.wav)
    except (OSError, wavio.WavError) as e:
        fail(str(e))
    in_channels = samples.shape[1]
    if a.mono_mix:
        sources = [("mix", samples.mean(axis=1))]
    else:
        if a.channels < 1:
            fail("--channels must be at least 1")
        if a.channels > in_channels:
            fail("the file has %d channel(s), but --channels %d was asked for" % (in_channels, a.channels))
        sources = [(i + 1, samples[:, i]) for i in range(a.channels)]
    if a.lowest_frequency <= 0:
        fail("the lowest frequency must be above 0")
    if a.highest_frequency <= a.lowest_frequency:
        fail("the highest frequency must be above the lowest frequency")
    if a.hop_size <= 0:
        fail("the hop size must be above 0")
    length_s = samples.shape[0] / rate
    if a.start < 0:
        fail("the start must not be negative")
    if a.start >= length_s:
        fail("the start (%.2f s) is beyond the end of the sound (%.2f s)" % (a.start, length_s))
    if a.duration is not None and a.duration <= 0:
        a.duration = None                                  # 0 or less means: to the end

    count = len(sources)
    jobs = choose_jobs(a.jobs, count)
    kw_common = dict(
        start=a.start, duration=a.duration,
        lowest_frequency=a.lowest_frequency, highest_frequency=a.highest_frequency,
        frequency_deviation=a.frequency_deviation, window_cycles=a.window_cycles,
        window_type=a.window_type, hop_size=a.hop_size, fft_size=a.fft_size,
        amp_threshold=db_to_amp(a.amp_threshold_db), track_length=a.track_length,
        min_gap_length=a.min_gap_length, min_segment_length=a.min_segment_length,
        last_peak_contribution=a.last_peak_contribution, SMR_continuity=a.smr_continuity,
        optimize=not a.no_optimize, force_M=a.window_length,
        window_alpha=a.window_alpha, window_beta=a.window_beta, verbose=a.verbose,
        compute_noise=not a.no_noise, pack_rows=not a.no_pack_rows,
    )
    if a.optimize_amp_threshold_db is not None:
        kw_common["optimize_amp_threshold"] = db_to_amp(a.optimize_amp_threshold_db)
    tasks = []
    for n, (label, x) in enumerate(sources, start=1):
        kw = dict(kw_common)
        if a.residual_wav and not a.no_noise:
            kw["residual_file"] = channel_path(a.residual_wav, n, count)
        tasks.append({"n": n, "label": label, "x": x, "rate": rate, "kw": kw, "path": channel_path(a.ats, n, count),
                      "save_phase": not a.no_phase, "save_noise": not a.no_noise,
                      "result_file": RESULT_FILE, "count": count, "parallel": jobs > 1})
    parts = [t["path"] + ".part" for t in tasks]

    def discard_parts():
        for part in parts:                              # a cancelled or failed analysis leaves no half-made set behind
            if os.path.exists(part):
                os.remove(part)

    try:
        if jobs == 1:
            out = [analyse_channel(t) for t in tasks]
        else:
            out = run_parallel(tasks, jobs)
    except ValueError as e:
        discard_parts()
        fail(str(e))
    except BaseException:
        discard_parts()
        raise
    for part in parts:                                  # all channels are done: now the files get their real names
        os.replace(part, part[:-len(".part")])
    summary = {"input_channels": in_channels, "files": out}
    if a.summary_format == "lua":
        line = "RESULT " + to_lua(summary)
    else:
        line = json.dumps(summary)
    print(line)
    if RESULT_FILE:
        stop_beat()
        write_progress(RESULT_FILE + ".started", 1.0)
        write_text(RESULT_FILE, line + "\n")


if __name__ == "__main__":
    try:
        main()
    except Cancelled:
        print("ERROR cancelled")
        if RESULT_FILE:
            write_text(RESULT_FILE, "ERROR cancelled\n")
        sys.exit(4)
    except SystemExit:
        raise
    except Exception as e:                 # in background mode the editor must always get an answer
        msg = "internal error (%s: %s). The settings or the sound may be unusual; if it happens again with other settings, please report it" % (type(e).__name__, e)
        print("ERROR " + msg)
        if RESULT_FILE:
            write_text(RESULT_FILE, "ERROR " + msg + "\n")
        sys.exit(5)
