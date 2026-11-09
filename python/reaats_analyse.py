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
    print("CHECK ok python=%s numpy=%s" % (py, numpy.__version__))
    sys.exit(0)


if "--check" in sys.argv[1:]:
    check_environment()

import numpy as np                                        # noqa: E402
from pyatsyn import wavio                                 # noqa: E402
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
    p.add_argument("wav", help="the sound to analyse (WAV: PCM 8/16/24/32 bit or float; any number of channels)")
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
    g.add_argument("--no-phase", action="store_true", help="do not store the phase (file type 3 instead of 4)")
    g.add_argument("--no-noise", action="store_true", help="no residual and no noise bands (faster; file type 2 or 1)")
    g.add_argument("--residual-wav", default=None, help="also write the residual of each channel to this WAV (name_ch1.wav for several channels)")
    g.add_argument("--summary-format", choices=("json", "lua"), default="json",
                   help="format of the last line printed: json, or lua (RESULT {a=1,...}, read by the ReaATS editor)")
    g.add_argument("-v", "--verbose", action="store_true")
    return p


def channel_path(path, n, count):
    if count == 1:
        return path
    stem, ext = os.path.splitext(path)
    return "%s_ch%d%s" % (stem, n, ext)


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
    sys.exit(2)


def main(argv=None):
    a = build_parser().parse_args(argv)
    try:
        samples, rate = wavio.read_wav(a.wav)
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

    count = len(sources)
    out = []
    for n, (label, x) in enumerate(sources, start=1):
        kw = dict(
            start=a.start, duration=a.duration,
            lowest_frequency=a.lowest_frequency, highest_frequency=a.highest_frequency,
            frequency_deviation=a.frequency_deviation, window_cycles=a.window_cycles,
            window_type=a.window_type, hop_size=a.hop_size, fft_size=a.fft_size,
            amp_threshold=db_to_amp(a.amp_threshold_db), track_length=a.track_length,
            min_gap_length=a.min_gap_length, min_segment_length=a.min_segment_length,
            last_peak_contribution=a.last_peak_contribution, SMR_continuity=a.smr_continuity,
            optimize=not a.no_optimize, force_M=a.window_length,
            window_alpha=a.window_alpha, window_beta=a.window_beta, verbose=a.verbose,
            compute_noise=not a.no_noise,
        )
        if a.optimize_amp_threshold_db is not None:
            kw["optimize_amp_threshold"] = db_to_amp(a.optimize_amp_threshold_db)
        if a.residual_wav and not a.no_noise:
            kw["residual_file"] = channel_path(a.residual_wav, n, count)
        try:
            snd = tracker_array(np.ascontiguousarray(x), rate, **kw)
        except ValueError as e:
            fail(str(e))
        path = channel_path(a.ats, n, count)
        ats_save(snd, path, save_phase=not a.no_phase, save_noise=not a.no_noise)
        out.append({
            "file": path, "channel": label, "partials": int(snd.partials), "frames": int(snd.frames),
            "duration": float(snd.dur), "sample_rate": int(snd.sampling_rate),
            "frame_size": int(snd.frame_size), "window_size": int(snd.window_size),
            "noise_bands": 0 if a.no_noise else int(len(snd.bands)),
            "phase": not a.no_phase,
        })
    summary = {"input_channels": in_channels, "files": out}
    if a.summary_format == "lua":
        print("RESULT " + to_lua(summary))
    else:
        print(json.dumps(summary))


if __name__ == "__main__":
    main()
