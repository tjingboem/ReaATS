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

- STEREO / MULTICHANNEL (tjingboem 9 Nov 2026, NOT built): see `docs/multichannel_design.md`. Analysis sets the number
  of channels (one .ats per channel, same options, same duration); the editor loads them separately, switches
  between them, individual edits per channel, one toggle button per channel (1 2 3 ...), selecting and editing apply to every channel that is on
  (decided 9 Nov, replacing the LINK button idea; Shift keeps its existing uses); a slider per channel sets how visible
  that channel is in the overlay (screen only: tjingboem's answer; no effect on edits or sound); a channel that is OFF is not drawn (0 %); a channel that is ON is drawn at 20-100 % by its slider, common edit window / duration. Python engine plan: pyatsyn vendored (BSD-3), WAV via
  numpy only, any number of channels, writes one file per channel; called from the editor with `python3`.

- PYTHON ANALYSIS ENGINE (9 Nov 2026, built, not yet called from the editor): `python/reaats_analyse.py` + vendored
  `python/pyatsyn/` (BSD-3, licence kept, changes marked; see THIRD-PARTY-NOTICES.md). numpy only: `pyatsyn/wavio.py`
  replaces `soundfile` (reads WAV PCM 8/16/24/32 + float 32/64, extensible, any channels; writes float WAV).
  `tracker_array()` takes a sound array; noise bands are computed in memory (`compute_noise`). CLI options = the spec in
  docs/analysis_options.md except Csound-only -T/-S; `--channels N` writes name_ch1.ats ... name_chN.ats (same options,
  same frame grid/duration), `--mono-mix`, `--no-phase`, `--no-noise`, `--residual-wav`; last stdout line is a JSON summary;
  problems go to stderr, exit code 2. Result is BYTE-IDENTICAL to the unmodified pyatsyn analysis of examples/sax.ats
  (the file tjingboem listened to). 2.2 s sax: 0.55 s including Python start. Tests: `python3 python/tests/test_engine.py`
  (21: wav formats, channels 1/2/3, file types, hop, start/duration, window types, errors, Lua reader cross-check).
  SPEED: one change to the vendored code (marked in peak_tracking.update_track_averages): tracks asleep for more than
  `track_length` frames are skipped, which cannot change the result (checked: byte-identical output on the sax example
  and on 3 s vibrato signals, clean and noisy) but stops the cost growing with every track ever born (it was quadratic).
  Measured: 2.2 s sax 0.55 s; 20 s harmonic voice with vibrato (105 partials, 2001 frames) 2.9 s mono, 5.7 s for 2
  channels. WARNING for the Analysis page: sounds that break into thousands of tracks (noise above the amplitude
  threshold, a badly modulated signal: my first test signal made 15,000 partials) are still slow (60 s for 20 s of
  sound); raising --amp-threshold-db or the lowest frequency helps. (My first test signal was a wrong vibrato, a
  growing chirp, not a real sound.)
  ANALYSIS PAGE BUILT 9 Nov 2026 (not yet seen by tjingboem: "i can not reach the Analysis window"): ANALYSE button in the
  header (left of EXPORT; also drawn when NO file is loaded) and Ctrl+A open `lib/analysis_page.lua` (immediate-mode page,
  Esc/BACK returns): source = "Use selected item" (the take's WAV, start offset and item length; item volume/FX not applied;
  non-WAV sources refused with advice) or "Choose WAV file..."; every engine option as a field (click = type a value via
  GetUserInputs, wheel = step, Shift = finer, bool = checkbox, choice = menu), hover tip, derived line (window/FFT/hop/
  frames, warning when the window is longer than the sound), Defaults / Csound defaults (only SMR contribution 0.5 differs),
  output name (unique, Change... with confirm before replacing), settings remembered in ExtState `analysis_settings`.
  ANALYSE writes an argument file (one argument per line, no quoting problems), runs
  `python3 python/reaats_analyse.py @args` with `reaper.ExecProcess` (blocking, 10 min limit), reads the `RESULT {...}`
  line (our serializer format) or the `ERROR ...` line (the engine prints errors on stdout too), opens channel 1 and lists
  every channel file with an Open button. `lib/wav_info.lua` reads WAV headers. Tests: `tests/test_analysis_page.lua` (64:
  every flag exists in the engine's --help, args, derived values), `tests/test_wav_info.lua`, `tests/mock_analysis.lua`
  (real engine: stereo 440/660 Hz -> two files, item part only, settings remembered, errors, page reachable with no file).
  NOT verified in real REAPER: `ExecProcess` quoting of paths with spaces (quoted only when needed), and how REAPER
  reports a missing python3. Spatial output answer: the PARTIALS are divided over the outputs (docs/spatial_output.md).
  NEXT (after tjingboem's test): editor channel buttons + visibility sliders (docs/multichannel_design.md); calling `python3 .../reaats_analyse.py`; editor channel
  buttons + visibility sliders (docs/multichannel_design.md).

- ON THE LIST (tjingboem 9 Nov 2026, not built): pseudo-stereo output and VBAP, as in SpectralTransfer ("dividing the
  analysed channels over a stereo output"); see `docs/spatial_output.md` (what SpectralTransfer does, and the open
  question whether the partials or the analysed channels are divided over the outputs).

- DECISION (tjingboem 9 Nov 2026): NO Lua version of the analysis will be made. Python (3.8+ with numpy) is required for
  analysis. When it is missing, ANALYSE shows a popup: download Python from python.org, install numpy, add the Python
  path in REAPER (Options > Preferences > Plug-ins > ReaScript), with an offer to open the download page. Built the same
  day: `python3 reaats_analyse.py --check` (prints CHECK ok|old|missing before numpy is imported; MIN_PYTHON (3, 8),
  not tested on other versions), `analysis_page.python_candidates()` (the Python REAPER is set to use first, read from
  reaper.ini `pythonlibpath64`/`pythonlibdll64`; then the usual places; the one that worked is remembered in ExtState
  `python_exe`), a Python status line + Check button on the page, the popup (`python_help_text`, separates "no Python",
  "no numpy" and "too old"), 11 new pure tests + 4 mock scenarios. NOT verified in real REAPER: the reaper.ini lookup,
  `reaper.get_ini_file`, the popup text layout in `reaper.MB`, `open_url`.

- WAITING DISPLAY (tjingboem 9 Nov 2026: "a blinking button and a big word ANALYZING..."; also an "Import .ats file" button
  on the page): the analysis now runs in the BACKGROUND (`ExecProcess(cmd, -1)`), because a blocking call cannot animate.
  Engine `--result-file R`: writes R.started (progress 0..1: tracking 0-0.8, residual 0.85-0.93, done 1.0, overall across
  channels), R at the end (`RESULT {...}` or `ERROR ...`, also for any exception), stops when R.cancel appears (no
  files left behind, exit 4; vendored tracker got a `progress` callback). The page polls R each frame (`Page:poll`, called
  by the editor loop even when the page is hidden, so Esc does not stop the job): dimmed page, big blinking ANALYZING...
  (0.5 s), blinking ANALYSE button, bar with % and seconds, Cancel; "did not start" after 20 s without R.started, give up
  after an hour. The page, not the engine, deletes old R files before starting (an early Cancel must survive). "Import
  .ats file..." opens a file and returns to the editor. This polling exists only while an analysis the user started runs
  (no watcher loop). Tests: 28 Python, mock_analysis (blink, progress, Cancel, Esc, Import, engine that never starts).
- PARALLEL CHANNELS (tjingboem 9 Nov 2026: "optimize the analyzing part by using more cores", chose: channels in parallel):
  engine `--jobs N` (0 = automatic: cores-2, at least 1, never more than the channels): `multiprocessing.Pool`, one
  process per channel (`run_parallel`, `analyse_channel`), workers put progress in a shared array, the parent writes
  R.started and watches R.cancel; one process when jobs==1. Every file is written as name.ats.part and renamed when ALL
  channels are done (a cancel/failure leaves nothing and old files survive). `--check` now prints `cores=N`; the page has a
  "CPU cores" field (shows "N at once, of M cores"; `analysis_page.workers`). Result is byte-identical to the serial run
  (tested). Measured on tjingboem's 8-core machine: 2 channels x 20 s 7.4 s -> 4.2 s (1.8x); 8 channels x 20 s 29.7 s ->
  10.8 s with 4 jobs (2.75x), 10.5 s with 6 (probably 4 physical cores). NOT done (the bigger change, offered): frames in
  parallel inside ONE channel (peak detection + SMR, residual synthesis and analysis are parallel; the track matching,
  ~18 % of the time, is sequential): expected 2-3x for long single sounds, none for short ones. 32 Python tests.
- PLAYHEAD (tjingboem 9 Nov 2026: "we need a playhead in the editor"; my reading, not confirmed): a yellow line with a ruler
  marker and a "1.234 s" label. Click / drag on the time ruler (the strip under the plot) sets `playhead`; AUDITION renders
  FROM there (`synth.render(d, {from=t})` starts at the frame at or before it and returns that start time) and the line
  moves while it plays (position = start + time since the preview started; SWS's Xen preview has no position query, so it
  is an estimate); at the end or on Space it returns to where it was set. PRINT still makes the whole sound. Not asked,
  not built: following REAPER's edit cursor/transport, looping, audition of the selection only.
- AUDITION BLINK (tjingboem 9 Nov 2026: "it takes a few seconds before Audition actually starts playing. Make the Audition
  button blink"): the sound is now prepared in STEPS so the window can animate: `synth.render_job(d, opts)` (a coroutine; the
  render loops call `tick()`; `job.step(0.03)` per frame, `job.progress`, `job.cancel()`; result identical sample for sample to
  `synth.render`), `advance_pending()` in the editor loop writes the WAV and starts the preview when the job is done; the
  AUDITION button blinks (0.4 s) while `pending` is set and the status shows "preparing the sound ... N %". Space, a new
  load or any edit (`apply_changes`) cancels a pending sound. PRINT is still one blocking render. The wait is at most
  ~1.3x the render time (30 ms of work per frame).
- PERCENTAGE UNDER THE BUTTONS (tjingboem 9 Nov 2026: "show under the Audition button a small indicator showing the %
  before Auditioning. Do the same for Printing"): a 5 px bar + "NN %" under the AUDITION or PRINT button while `pending`
  (second header row, x of the button; the selection summary moved one row down to row 3 so they never overlap). PRINT now
  also prepares its sound with `synth.render_job` and blinks (`pending.kind == "print"`; `finish_print` writes the WAV and
  inserts the item); Esc or any edit cancels a print in preparation; AUDITION pressed during a print is refused with a
  status; Space only cancels an audition. Unsaved edits are still saved first (a short blocking step).
- PRINT FROM THE PLAYHEAD (tjingboem 9 Nov 2026: "let printing and auditioning be done from the playhead's position";
  AUDITION already did): `synth.render_job(..., {from = playhead})` for PRINT too; the status says "printed 1.2 s from
  1.00 s (...)"; the item settings now hold `from` (the frame-aligned start) and a ReaSnap restore puts the playhead back
  there (`st.from`); the item is still placed at the edit cursor. Tests in mock_run (a print from 1.0 s is about half as long,
  the state remembers it) and mock_snap (restore).
- SINE LAYER CHECKBOX (tjingboem 9 Nov 2026: "noise layer needs the switchable sine layer option"): a "Sine layer" checkbox
  under the "Noise layer" one (top right, second row); both set `show_partials` / `show_noise`, the same switches as the P / N
  keys, and they still decide what AUDITION and PRINT render. While the sine layer is off nothing can be selected (status
  says why) and the hover readout does not name partials: no editing of hidden data.
- SDIF: asked about 9 Nov 2026 (SPEAR reads it), then DROPPED by tjingboem ("Drop SDIF"). ReaATS is .ats only. Do not propose it again.

- MULTICHANNEL SOUND (tjingboem 9 Nov 2026: "Multichannel sound for AUDITION and PRINT"; no question about unsaved edits
  wanted: "no"): the editor now holds a CHANNEL SET. Opening name_chK.ats opens all consecutive files name_ch1.ats ... (same
  frame size, frames, sample rate and duration, else the file opens alone and the status says why); `chs` holds one bundle
  per channel (data, undo/redo, modified, selection ... swapped by `capture_channel`/`restore_channel`/`switch_channel`),
  `cur` is the shown/edited channel. Channel buttons (an extra header row, only with 2+ channels; plot top 90 instead of 70)
  and Tab switch; a star on a button = unsaved changes in that channel. AUDITION and PRINT render ALL channels
  (`synth.render_multi_job`, interleaved float WAV via `synth.write_wav_channels`); 9 Nov, same day, tjingboem: REAPER's
  preview is stereo, so AUDITION MIXES DOWN to stereo when a set has more than 2 channels (`synth.mix_to_stereo`: channel 1
  hard left, the last hard right, the rest spread, constant power, level so no side is louder than one channel; exactly 2
  channels play as they are) while PRINT stays multichannel ("I do think Printing can be multichannel though"; REAPER must
  be set up for multichannel use); PRINT raises the track to an even number
  of channels >= N (`I_NCHAN`) and the item state lists every file (`files`, `channel`). Ctrl+S saves the whole set as
  name_edit[N]_ch1.ats ... ; EXPORT writes name_ch1.ats ... from the chosen name (asks before replacing any). Edits still
  apply to ONE channel at a time. NOT built (the rest of the design in docs/multichannel_design.md): several channels switched
  on and edited together, the overlay in channel colours, the visibility sliders. Tests: tests/mock_channels.lua (real engine
  makes a 3-channel set), test_ats_synth.lua (12 new for multi-channel rendering and the WAV).

- INCIDENT 9 Nov 2026 (tjingboem: the Analysis page showed "800 seconds" and never finished; they cancelled the import):
  the page and my own test runs used the SAME fixed temp names (/tmp/reaats_analysis_args.txt, _result.txt, .started, .cancel,
  /tmp/reaats_audition_N.wav), so a test run of mine removed/consumed the live job's result file while tjingboem's analysis
  ran in REAPER (the engine process was a defunct child of REAPER, no result file, no .ats). FIXED: every job has a unique id
  in its file names (`reaats_<time>_<random>_args/result.txt`), audition WAVs carry a per-editor-session id; the engine
  writes a sign of life (`progress epoch-seconds`, plus a heartbeat thread every 2 s) into R.started and the page declares
  the program lost after 120 s without one (message with advice), and a Cancel nobody answers ends after 8 s. RULE for me:
  run the Lua tests with `TMPDIR=<scratchpad>/tmp` and never reuse fixed temp names between the live plugin and tests.
  A 217 s stereo song at the default settings needs about 3.5 minutes (2 parallel workers; progress 0.45 after 100 s): long
  full-range music at lowest frequency 20 Hz is slow; raise the lowest frequency / amplitude threshold or analyse a part.
  REAPER leaves a defunct (zombie) child per background ExecProcess until REAPER exits; harmless.

- LONG SOUNDS (tjingboem 9 Nov 2026: a 103 MB stereo wav, 536 s, channel 1 at lowest 100 Hz and the default -60 dB, ran for
  ~1000 s at 37 %; asked "how long should it take"): the time is dominated by the NUMBER OF PEAKS, not the length: first 30 s
  of that recording: 52 s at -60 dB (7705 partials), 18 s at -50 (2384), 10 s at -40 (716), 5.3 s at -30 (121). The old engine
  needed >110 s for the first 60 s, so the whole file at -60 dB would take hours (progress is also non-linear: cost grows with
  the number of tracks alive). RECOMMENDATION given: cancel; use -40 dB (about 5 minutes for the whole file) or analyse parts.
  Added: the Analysis page warns "Long sound, low threshold: this can take very long. Try -40 dB, or a shorter part" (> 90 s
  analysed and threshold below -45 dB; `analysis_page.long_warning`). Engine: another speed-up in the vendored tracker (only
  `active` tracks are visited each frame; byte-identical output on sax, synthetic voices and 25 s of music), about 10 % faster
  on that file, the remaining cost is the peaks themselves. NOT done: a time estimate, a smarter default threshold.

- START CLEARED (tjingboem 9 Nov 2026: "i think it must start cleared"; chose "Editor: no file"): the editor window starts EMPTY.
  No last file is reopened and no file dialog opens (O opens one, ANALYSE makes one). A ReaSnap snapshot still restores its file;
  a snapshot whose file is gone says so and the window stays empty (it used to fall back to the last file). The remembered
  last folder is still the dialog's starting point; the Analysis settings are still remembered (not asked to clear).
  Mocks now press O after starting.

- CRYPTIC ERROR (tjingboem 9 Nov 2026, screenshot: "Analysis failed: operands could not be broadcast together with shapes
  (355663,) (355680,)"): the analysis failed whenever Start + Duration ran past the end of the file (typically "Use selected
  item" with an item a few samples longer than its file); numpy raised a shape error. FIXED: the vendored tracker cuts the
  end to the sound (`nd = min(..., in_sound.size)`), the page clamps an item's duration to the file, the engine says
  "the start (3.00 s) is beyond the end of the sound (1.00 s)" for a start past the end, and any unexpected exception now
  reads "internal error (Type: message). The settings or the sound may be unusual; if it happens again with other settings,
  please report it". Tests: 2 engine tests (duration past the end gives the same file as the whole sound; start past the
  end), 1 page test (item 5 s on a 2 s file).

## Next (not started, wait for tjingboem)
1. (There is no Lua analysis: see DECISION above.)
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
