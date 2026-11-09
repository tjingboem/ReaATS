# Third-party notices

## pyatsyn (BSD 3-clause), and the original ATSA / ATSH

`lib/ats_synth.lua` follows the structure of the phase-less sine synthesis of the Python package pyatsyn
(https://pypi.org/project/pyatsyn/ , version 1.0.0): one oscillator per partial, amplitude and frequency
interpolated linearly between frames, phase as the running sum of the frequency. The code is written in Lua
and the noise part is different (band-pass filtered noise, calibrated against Csound's ATS resynthesis), but
pyatsyn's notice is kept here as its licence asks. The .ats file layout and the meaning of the stored values
come from the ATS system, copyright 2002-2004 Oscar Pablo Di Liscia, Pete Moss and Juan Pampin.

The licence text that comes with pyatsyn 1.0.0 (LICENSE.rst) follows.

```
ATS Copyright:
The original common lisp and C libraries atsa and atsh were developed as part 
of the "Desarrollo de Software para analisis y sintesis de sonido digital 
(Digital Sound Analysis and Synthesis Software Development)" research and 
development project with the support of: Universidad Nacional de Quilmes, 
Buenos Aires, Argentina(http://www.unq.edu.ar), and the Center for Digital 
Arts and Experimental Media, University of Washington, Seattle, USA 
(http://www.washington.edu/dxarts). 

Except where otherwise noted, ATSA and ATSH is Copyright 2002-2004 Oscar Pablo
Di Liscia, Pete Moss, and Juan Pampin.

---
pyatsyn
Copyright (c) <2023>, <Johnathan G Lyon>
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice, this
  list of conditions and the following disclaimer.

* Redistributions in binary form must reproduce the above copyright notice,
  this list of conditions and the following disclaimer in the documentation
  and/or other materials provided with the distribution.

* Neither the name of the copyright holder nor the names of its
  contributors may be used to endorse or promote products derived from
  this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## pyatsyn, included in python/pyatsyn/

The folder `python/pyatsyn/` contains the code of pyatsyn 1.0.0 (BSD 3-clause, copyright 2023 Johnathan G Lyon, based on
the ATS system of Di Liscia, Moss and Pampin), with its own licence text in `python/pyatsyn/LICENSE.rst`. It is used by
`python/reaats_analyse.py`. Changes made for ReaATS (9 November 2026), each marked at the top of the file: the
`soundfile` package is replaced by `wavio.py` (WAV reading and writing with numpy only, new file), the analysis can be
called with a sound array (`tracker_array`) and computes the noise bands without writing a residual file, one speed-up (tracks that have been asleep for more than `track_length` frames are skipped when the running averages
are updated; the result is identical, only the cost no longer grows with every track ever born), and one
docstring was made a raw string. The analysis result is byte-identical to that of the unmodified package
(`python/tests/test_engine.py` checks this on `examples/sax.ats`).

## Csound

ReaATS does not contain Csound code and does not need Csound to run. Csound's own ATS opcodes (LGPL 2.1 or later,
Alex Norman 2004) and its `atsa` utility (LGPL 2.1 or later, ported from ATSA by Istvan Varga) were used as a reference
to check the output of `ats_synth.lua` (`tests/compare_with_csound.py`) and to learn the meaning of the stored noise
energy (amplitude = sqrt(energy / (window size x 0.04))), which is a property of the file format. No Csound source
was copied.
