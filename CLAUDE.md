# ReaATS -- notes

A SPEAR-like editor for Csound/ATS analysis files, inside REAPER. Started 8 Nov 2026.
Decisions (tjingboem): files stay standard Csound `.ats` (type 4 = amp/freq/phase + 25 noise
bands); the editor is Lua `gfx`; analysis/resynthesis happen offline outside REAPER (Python +
numpy/scipy, REAPER is already set to libpython3.12.so); sound = an AUDITION button that renders
the edited file to a WAV (no real-time sound while dragging, not wanted).

## Built
- `lib/ats_file.lua` -- reader written from the published layout (no ported code). 22 tests
  (`lua5.4 tests/test_ats_file.lua`), checked against values read by Python from the same file.
- `ATS_Viewer.lua` -- READ-ONLY viewer (step 1): partials as lines on a log-frequency axis (colour
  = level, floor -80 dB below the loudest), the 25 noise bands as a faint shaded layer, hover
  readout (time, frequency, note, nearest partial), wheel / Ctrl+wheel / Shift+wheel / drag, keys
  O R F P N. `lua5.4 tests/mock_run.lua` runs it against a fake gfx (catches runtime errors only).
- Seen working in REAPER by tjingboem 8 Nov 2026 ("gorgeous", "very fast"); noise layer has a checkbox
  (top right), note-name scale on the right edge (C's when zoomed out, naturals, then semitones).
- Selection (9 Nov 2026, not yet seen by tjingboem): left-drag draws a box that selects POINTS
  (a partial at a frame, SPEAR-style: part of a partial, not the whole line); Shift adds; a plain
  click on empty space clears; Esc clears, then closes. Pan moved to right/middle drag. Selected
  points are drawn bright pink, header shows "selected: N points in M partials, time, frequency".

## Next (not started, wait for tjingboem)
Edit operations (delete, transpose, shift, scale, move, copy,
stretch), undo, a writer (`ats_file.save`), the Python helper for analysis from an item and for
Audition, then the Audition button.

## Facts
- Csound 7 opcode names are lowercase (`atsinfo`, `atsadd`); `atsadd` ignores the stored phase
  (its `ATS_DATA_LOC` holds only amp+freq) -- a Csound contribution, parked.
- pyatsyn (BSD-3) was run from an unpacked wheel with a scipy-based `soundfile` stand-in; there is
  no pip/venv on this machine. Test analysis: `examples/sax.ats` from the alto sax of the Csound
  manual examples, `lowest_frequency=100`.
- Licences: pyatsyn BSD-3; Csound ATS opcodes LGPL 2.1+; the original ATSA licence file itself
  has not been read.
