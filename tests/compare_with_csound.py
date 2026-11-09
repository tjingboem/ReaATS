#!/usr/bin/env python3
"""Development check, not needed to use ReaATS: compares lib/ats_synth.lua with Csound's own ATS resynthesis
(atsadd / atsaddnz) on examples/sax.ats. Needs csound, lua5.4, numpy and scipy.
Usage: python3 tests/compare_with_csound.py [work_dir]   (run from the ReaATS folder)
Prints level difference, loudness-envelope correlation and per-critical-band level difference.
Last result (9 Nov 2026, NOISE_GAIN 0.30): sines 0.0 dB / noise 0.0 dB / both 0.0 dB overall, envelope
correlation 0.97 / 0.92 / 0.97; per-band noise level within about +/-2 dB (a few bands up to 7 dB)."""
import os, subprocess, sys, tempfile
import numpy as np
from scipy.io import wavfile

root = os.getcwd()
work = sys.argv[1] if len(sys.argv) > 1 else tempfile.mkdtemp(prefix="reaats_cmp_")
ats_file = os.path.join(root, "examples", "sax.ats")
EDGES = [0,100,200,300,400,510,630,770,920,1080,1270,1480,1720,2000,2320,2700,3150,3700,4400,5300,6400,7700,9500,12000,15500,20000]

lua = f'''package.path = "{root}/lib/?.lua;" .. package.path
local ats, synth = require("ats_file"), require("ats_synth")
local d = assert(ats.load("{ats_file}"))
for _, m in ipairs({{ {{"sine", true, false}}, {{"noise", false, true}}, {{"both", true, true}} }}) do
  local s, sr = assert(synth.render(d, {{ sines = m[2], noise = m[3] }}))
  assert(synth.write_wav("{work}/lua_" .. m[1] .. ".wav", s, sr))
end'''
open(os.path.join(work, "render.lua"), "w").write(lua)
subprocess.run(["lua5.4", os.path.join(work, "render.lua")], check=True)

for mode in ("sine", "noise", "both"):
    out = {"sine": "out asine", "noise": "out anz", "both": "out asine + anz"}[mode]
    csd = f'''<CsoundSynthesizer><CsOptions>-d -m0 -W -f -o {work}/csound_{mode}.wav</CsOptions>
<CsInstruments>
sr = 44100
ksmps = 32
nchnls = 1
0dbfs = 1
instr 1
  ktime line 0, p3, 2.1725
  asine atsadd ktime, 1, "{ats_file}", 1, 69
  anz atsaddnz ktime, "{ats_file}", 25
  {out}
endin
</CsInstruments>
<CsScore>
f1 0 16384 10 1
i1 0 2.1725
</CsScore></CsoundSynthesizer>'''
    p = os.path.join(work, f"ref_{mode}.csd")
    open(p, "w").write(csd)
    subprocess.run(["csound", p], check=True, capture_output=True)

def load(p):
    import warnings
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        sr, y = wavfile.read(p)
    return sr, y.astype(float)
db = lambda x: 20 * np.log10(x + 1e-12)
def bands(y, sr):
    sp = np.abs(np.fft.rfft(y)) ** 2 / len(y); f = np.fft.rfftfreq(len(y), 1 / sr)
    return np.array([sp[(f >= EDGES[i]) & (f < EDGES[i + 1])].sum() for i in range(25)])
def env(y, hop=441):
    return np.array([np.sqrt(np.mean(y[i*hop:(i+1)*hop] ** 2)) for i in range(len(y) // hop)])
for mode in ("sine", "noise", "both"):
    sr, a = load(f"{work}/csound_{mode}.wav"); _, b = load(f"{work}/lua_{mode}.wav")
    m = min(len(a), len(b)); a, b = a[:m], b[:m]
    ra, rb = np.sqrt(np.mean(a ** 2)), np.sqrt(np.mean(b ** 2))
    ba, bb = bands(a, sr), bands(b, sr); ok = (ba > 1e-14) & (bb > 1e-14)
    d = 10 * np.log10(bb[ok] / ba[ok])
    print(f"{mode:5s} csound {db(ra):6.1f} dBFS  lua {db(rb):6.1f} dBFS  diff {db(rb)-db(ra):+5.1f} dB | "
          f"envelope corr {np.corrcoef(env(a), env(b))[0, 1]:.3f} | per-band diff mean {d.mean():+.1f} dB, spread +/-{d.std():.1f} dB")
print("files in", work)
