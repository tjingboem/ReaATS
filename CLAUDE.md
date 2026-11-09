# ReaATS -- notes

A SPEAR-like editor for Csound/ATS analysis files, inside REAPER. Started 8 Nov 2026.
Decisions (tjingboem): files stay standard Csound `.ats` (type 4 = amp/freq/phase + 25 noise
bands); the editor is Lua `gfx`; sound = an AUDITION button that renders the edited file to a WAV (no
real-time sound while dragging, not wanted). 9 Nov 2026: ReaATS must be INDEPENDENT OF CSOUND so that other
people can use it: synthesis is now pure Lua (`lib/ats_synth.lua`); analysis (making .ats files) still needs
Csound's `atsa` (or pyatsyn / ATSA) until it is ported.

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
  SAVE KEEPS THE PHASE (changed 9 Nov 2026, tjingboem: "i want to keep the phase"): `ats_file.update_phases(d, edited_cells)`
  rebuilds the phases of every run (consecutive sounding frames of one partial) that has an edited cell with the rule
  pha[k+1] = pha[k] + (w[k]+w[k+1])/2 * frame_size (checked on a real analysis: median error 0.01 rad), starting from
  the run's stored first phase; untouched runs keep theirs; a file without phase gets phases for all runs (start 0).
  The edited file is type 4 (type 2 without noise). Verified: pyatsyn loads it and synthesises with its cubic phase
  interpolation at the same level as phaseless, the transposed fundamental really is at the new pitch (392.3 Hz
  after +7 semitones from 261.8 Hz), Csound `atsinfo`/`atsadd` read it without errors. Phase values are not MOVED by
  move/transpose (ats_edit does not carry `pha`), they are rebuilt from the frequencies on save.
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

- Audition (9 Nov 2026; the render part below was REPLACED by the Lua synthesis, see "Csound-free synthesis"; the preview/crash notes still hold): button "AUDITION" top right, or key A; Space stops.
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

- PRINT + ReaSnap hookup (9 Nov 2026, not yet tried by tjingboem). Audition plays through the source preview
  and creates no item, so ReaSnap (which keys on item GUIDs) needed a "generate" action: PRINT / Ctrl+P
  renders the current data (unsaved edits are saved first as `<name>_editN.ats`) to a permanent
  `<ats stem>_printN.wav` next to the .ats file and inserts it on the selected track (or a new "ReaATS" track)
  at the edit cursor. All five pieces of the ReaSnap Integration Contract (`ReaSnap/doc/ReaSnap_Integration_Contract.md`):
  1 own serializer `lib/reaats_serial.lua` (the template with the name replaced; rejects code), 2 window title
  "ATS Editor #n", 3 `SetProjExtState(0, "ReaATS_ItemSettings", item_guid, {file, name, view, partials, noise})`
  at PRINT, 4 startup apply of `pending_ReaATS_settings` (a missing .ats file is reported, then the last file
  opens), 5 Close All (`close_ReaATS_signal`, project identity + birth-time guard). Not built: live follow
  (selecting a printed item reloads its file). `ReaATS = "_RSd54b3e518c70fbdf5b5f6264be9a55593608e6f3"` was added to
  KNOWN_SCRIPTS in ReaSnap_Core.lua (the id depends on the script's path in REAPER's action list).
  `modified` now means "undo depth differs from the last save" and `current_file` is the file that holds the
  current data. Tests: `lua5.4 tests/mock_run.lua`, `tests/mock_snap.lua` (restore, Close All, missing file),
  `tests/test_ats_edit.lua`, `tests/test_ats_file.lua`.

- Csound-free synthesis (9 Nov 2026, not yet heard by tjingboem; replaces the Csound render of Audition and
  PRINT): `lib/ats_synth.lua` renders sines (one oscillator per partial, linear amplitude and frequency between
  frames, stored phase NOT used) and noise (white noise, 4th-order Butterworth band-pass per critical band, unit
  RMS, times sqrt(energy/(window_size*0.04)) times NOISE_GAIN 0.30) and writes a 32-bit float mono WAV.
  Checked against Csound (`python3 tests/compare_with_csound.py`) on examples/sax.ats: overall level difference
  0.0 dB for sines, noise and both; envelope correlation 0.97 / 0.92; per-band noise level within about 2 dB
  (a few bands up to 7 dB). NOISE_GAIN was calibrated to that (Lua noise was +10.4 dB before). Speed: 2.2 s of
  sound with 69 partials: 0.14 s sines, +0.9 s noise; REAPER waits while it renders. Tests:
  `lua5.4 tests/test_ats_synth.lua` (20). Method follows pyatsyn's phase-less sine path (BSD-3): see
  THIRD-PARTY-NOTICES.md (the pyatsyn licence text is kept there). No Csound source was copied; reading
  Csound's ugnorman.c only gave the unit of the noise energy (amplitude = sqrt(E/(winsz*0.04)), a property of the
  format). LICENSE: BSD 3-clause, "Copyright (c) 2026, tjingboem Productions" (chosen by tjingboem 9 Nov 2026, compatible with pyatsyn's BSD-3; third-party notices in THIRD-PARTY-NOTICES.md).
  Licences checked 9 Nov 2026: Csound's ATS opcodes (ugnorman.c) and atsa.c are LGPL 2.1+ (copying them would
  make the ported files LGPL); pyatsyn is BSD-3 (translation allowed with its notice kept).

- Import/export (tjingboem, 9 Nov 2026: "import and export of Csound compatible .ats files"): ALREADY possible:
  O (or the dialog) opens any Csound/ATS file (types 1-4, little or big endian; Csound's own `atsa` output opened);
  Ctrl+S exports a Csound-compatible file. Verified 9 Nov: Csound's atsa output read and re-saved as type 4 is
  byte-identical after the header (only the header's frqmax differs: ours is recomputed from the sounding points,
  7581.5 Hz vs 7600.6 Hz); Csound `atsinfo` reads our type 3 and 4 files. EXPORT BUTTON (tjingboem 9 Nov 2026: "i prefer a button that says: export .ats file"): the button "EXPORT .ats" (header, left of PRINT) and
  Ctrl+Shift+S call `save_as()` (status says "exported"). Header now has three rows (MARGIN_T 70): info + buttons, hover /
  selection summary, status. (Before, the status shared row 1 and was hidden by the long file info.) Built as Save as:
    (`JS_Dialog_BrowseForSaveFile` if the JS_ReaScriptAPI extension is there, else `GetUserInputs` to type the path; adds
  .ats; asks `MB` before replacing a file; remembers the folder in ExtState `save_dir`); Ctrl+S stays the quick,
  never-overwrite save. `write_ats(path)` is the shared writer (rebuilds phases, saves type 4). Tested with fake dialogs
  (dialog, extension added, overwrite no/yes, cancel, fallback); the real JS dialog has not been tried by tjingboem.
- ANALYSIS PAGE (tjingboem, 9 Nov 2026: "all options as we find for analysis must be used in a yet to make Analyses
  page"): NOT built. `docs/analysis_options.md` lists every option of Csound's atsa and pyatsyn (flags, defaults,
  meaning, presets, what to show). Build it when tjingboem says so.

## Next (not started, wait for tjingboem)
1. Analysis (making .ats files) without Csound, ported to Lua from pyatsyn (BSD-3; keep its notice): peak
   detection with `reaper.new_array` FFTs, partial tracking, residual (synthesise the partials, subtract), 25-band
   noise energy. Until then Csound's `atsa` (`csound -U atsa in.wav out.ats -l 100`) or pyatsyn make the files.
2. A LICENSE file (tjingboem chooses; recommended MIT or BSD-3).
3. More edit operations (amplitude scale, frequency shift in Hz, copy/paste, stretch), audition of the selection only.

## Facts
- Csound 7 opcode names are lowercase (`atsinfo`, `atsadd`); `atsadd` ignores the stored phase
  (its `ATS_DATA_LOC` holds only amp+freq) -- a Csound contribution, parked.
- pyatsyn (BSD-3) was run from an unpacked wheel with a scipy-based `soundfile` stand-in; there is
  no pip/venv on this machine. Test analysis: `examples/sax.ats` from the alto sax of the Csound
  manual examples, `lowest_frequency=100`.
- Licences: pyatsyn BSD-3; Csound ATS opcodes LGPL 2.1+; the original ATSA licence file itself
  has not been read.
