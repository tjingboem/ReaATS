# ReaATS -- notes

A SPEAR-like editor for Csound/ATS analysis files, inside REAPER. Started 8 Nov 2026.
Decisions (tjingboem): files stay standard Csound `.ats` (type 4 = amp/freq/phase + 25 noise
bands); the editor is Lua `gfx`; analysis/resynthesis happen offline outside REAPER (Python +
numpy/scipy, REAPER is already set to libpython3.12.so); sound = an AUDITION button that renders
the edited file to a WAV (no real-time sound while dragging, not wanted).

## Built
- `lib/ats_file.lua` -- reader written from the published layout (no ported code). 22 tests
  (`lua5.4 tests/test_ats_file.lua`), checked against values read by Python from the same file.
- `ATS_Editor.lua` (was ATS_Viewer.lua, renamed 9 Nov 2026): the editor window. First built as a read-only viewer: partials as lines on a log-frequency axis (colour
  = level, floor -80 dB below the loudest), the 25 noise bands as a faint shaded layer, hover
  readout (time, frequency, note, nearest partial), wheel / Ctrl+wheel / Shift+wheel / drag, keys
  O R F P N. `lua5.4 tests/mock_run.lua` runs it against a fake gfx (catches runtime errors only).
- Seen working in REAPER by tjingboem 8 Nov 2026 ("gorgeous", "very fast"); noise layer has a checkbox
  (top right), note-name scale on the right edge (C's when zoomed out, naturals, then semitones).
- Selection (9 Nov 2026, not yet seen by tjingboem): left-drag draws a box that selects POINTS
  (a partial at a frame, SPEAR-style: part of a partial, not the whole line); Shift adds; a plain
  click on empty space clears; Esc clears, then closes. Pan moved to right/middle drag. Selected
  points are drawn bright pink, header shows "selected: N points in M partials, time, frequency".

- Editing (9 Nov 2026, not yet seen by tjingboem): Delete (selected points get amplitude 0, the ATS
  convention for "not sounding"), Up/Down = transpose the selection (1 semitone; Shift 10 cents;
  Ctrl octave), Ctrl+Z undo, Ctrl+Y redo (Ctrl+Shift+Z too), Ctrl+S saves NEXT to the original as
  `<name>_edit.ats` (`_edit2`, ... never overwrites). Edits are point-level (a partial at a frame),
  so transposing part of a partial makes a frequency jump at the selection edge (SPEAR does the same).
  The edited file is saved WITHOUT phase (type 3): edits make the stored phases wrong, and Csound's
  ATS opcodes ignore phase anyway (checked: `atsinfo`, `atsadd`, `atsaddnz` read the saved file).
  `ats_file.save()` recomputes ampmax/frqmax; 35 reader/writer tests, mock run covers the editing.
  Key codes (gfx.getchar): Delete 6579564, Up 30064, Down 1685026670, Ctrl+Z 26, Ctrl+Y 25, Ctrl+S 19
  -- from memory, not yet confirmed on this REAPER.

- Move (9 Nov 2026, not yet seen by tjingboem): drag a SELECTED point to move the selection (time in
  whole frames, frequency continuous; Shift locks to one axis; a ghost shows the target), or Left/Right
  arrows = one frame (Ctrl ten). Logic in `lib/ats_edit.lua` (`plan_move`, 19 tests, pure Lua): every
  contiguous run of one partial keeps its row if the destination is silent, else goes to the nearest row
  that is silent there, else a NEW row is appended (the file may then have more partials than the
  original; undo removes the rows again). Nothing is ever overwritten. The move is clamped so no point
  leaves the file. Phase values are not moved (the saved file has no phase anyway).
  Two partials CAN overlap in time and frequency (different rows); a row holds one value per frame.

- Audition (9 Nov 2026, not yet heard by tjingboem): button "AUDITION" top right, or key A; Space stops.
  Saves the current data to `$TMPDIR/reaats_audition.ats` (type 3), writes a small .csd, runs the real
  Csound (`/usr/local/bin/csound`, needs Csound installed; ~0.1 s for 2 s of sound) with `atsadd` (sines)
  and `atsaddnz` (noise bands), and plays the WAV through `Xen_StartSourcePreview` (REAPER's source
  preview: the project is not touched). P / N decide whether sines / noise are included ("what you see
  is what you hear"). Measured: sines alone match the original level (-12.7 dBFS); the noise bands are
  about 30 dB lower (-42.8 dBFS), as in the analysis. `ExecProcess` blocks REAPER for the render.
  Not built: audition of the selection only, placing the render on a track (a "print" button).
  CRASH 9 Nov 2026 (tjingboem: first audition fine, the second crashed REAPER). NOT reproduced (a scratch
  REAPER instance did not load the SWS extension, so `Xen_*` was nil there; the user's install has SWS).
  Hypothesis: the second audition was the first to call `PCM_Source_Destroy` on a previewed source. Changes:
  sources are never destroyed from the script, each render has its own WAV (`reaats_audition_N.wav`, old ones
  deleted 4 auditions later), `Xen_StopSourcePreview` is only called while a preview can still be running.
  If it still crashes, switch to a real temporary item on a track (how ReaShapeM's Audition does it).

## Next (not started, wait for tjingboem)
More edit operations (delete, transpose, shift, scale, move, copy,
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
