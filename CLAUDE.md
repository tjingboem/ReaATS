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
  name_edit[N]_ch1.ats ... ; EXPORT writes name_ch1.ats ... from the chosen name (asks before replacing any). EDIT LEDs (tjingboem 9 Nov: "an indicator of which channels will be edited at the same time ... green led when editable, clicking makes it red"): `chs[i].edit` (default true), LED above each button (`led_rect`, `toggle_edit`), `on_channels()` = shown AND editable; the channel row is CHAN_ROW=30 px (plot top 100 with 2+ channels). STACK / OVERLAY
  + CHANNEL SELECTORS + SLIDERS (BUILT 9 Nov 2026, tjingboem: "see both channels separate under each other ... an option to see all
  channels in one window but with channel selectors, and the 20%-100% visible sliders"): the channel buttons are now ON/OFF toggles
  (`chs[i].on`, at least one stays on, an OFF channel keeps no selection); each channel has a slider `chs[i].vis` 0.2..1 (screen only);
  `view_mode` "stack" (one lane per ON channel under each other, `lane_layout`, LANE_GAP 4, one image buffer per lane) or "overlay"
  (one lane, channel colours `TINTS`, loudness = brightness, alpha = vis); mode button + V; Tab = solo next channel (after the last:
  all). Drawing/hit-tests run a channel through `as_channel(i, fn)` (swaps only data/amp_thresh/sel/sel_info). The reference channel
  `cur` keeps its bundle in the globals; `on_channels()` + `with_channel(i, fn)` run an edit on each ON channel; select_box,
  delete/transpose/move go through `edit_on_channels` (selection region applies to every ON channel's own points). UNDO is by
  GROUP: every do_edit stores `group`; Ctrl+Z/Y undo/redo the newest group across all channels (one step for a multi-channel edit);
  a new edit clears all redo stacks. Box/mover remember their lane (`box.off/h`, `mover.h`) so frequency maps with that lane's height. Tests: tests/mock_channels.lua (real engine
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

- SPEED OF AUDITION/PRINT (tjingboem 9 Nov 2026: "is there something we can do to speed up the auditioning?" -> "all of them"): measured first: on sax.ats
  the noise was 1.19 s of a 1.36 s render (25 bands x 4 biquad stages x every sample). Built: (1) NOISE CACHE in `ats_synth.lua`: the noise
  is independent of the partials, so `d.noise_cache` ({seed,k0,n,nz}) holds it; a request inside the cached stretch reuses it;
  global limit 12M samples, oldest dropped; ANYTHING THAT EDITS d.noise MUST SET d.noise_cache = nil (no noise editing exists yet).
  (2) add_noise skips silent stretches per band (filters restart from rest at the start of a run), the 4 filter stages and the LCG are
  written out with locals in the inner loop (1.58 s -> 0.96 s), and the unit-RMS norm per band is computed once from the impulse
  response (`band_norm`), not from the realisation. (3) `opts.to` in synth.render; the editor's AUDITION length button (`len_rect`,
  AUDITION_LENS END / WINDOW / 5 s / 15 s, key L, not persisted). (4) `python/reaats_synth.py` (numpy only): same method as the Lua
  (sines identical, corr 1.0000; noise level within ~0.4 dB, Gaussian carriers made by FFT with a 4th-order Butterworth magnitude),
  reads the .ats files the editor writes to TMPDIR (`ats.save(..., {phase=false})` of the EDITED data), `--from --to --mixdown stereo`
  (same mix as Lua), a noise cache on disk (`--cache-dir`, fingerprint = sha1 of noise data + grid + part + seed; 40 files / 400 MB),
  result protocol like the analysis (R.started heartbeat, R "OK t_start dur sr nch" or "ERROR msg", R.cancel). `lib/py_synth.lua`
  runs it with ExecProcess(-1) and polls (job.step/progress/cancel/wav, sweep() of cancelled jobs' files). The editor's `start_synth`
  uses it when Python is found (`analysis:find_python()` once; `python_missing` remembers a failure), else the Lua job; a failed Python
  run falls back to Lua with the error in the status. Measured on 30 s (69 partials): Lua 9.0 s first / 1.6 s cached, Python 2.7 s
  first / 0.9 s with the disk cache. Tests: tests/test_py_synth.lua (28), more in test_ats_synth.lua (66), mock_channels.lua; mock_run
  sets `no_py_synth` and a ticking os.clock for the step-wise tests. Possible later: Python channels in parallel, a persistent worker.
  MIDDLE STARTS (tjingboem, same day: "start Audition in the middle of the file without recalculating"): END mode with a sound <= 120 s renders the WHOLE sound (from=0) at the first AUDITION; `last_audition` = {state (data_rev|sines|noise|#chs), wav, s, e (samples), nch, sr}; any later request [s_r,e_r] inside [s,e] with the same state is `play_from_made`: the file itself when identical, else `wav_info.slice` cuts a new WAV (slice_history keeps 3). WINDOW/5 s/15 s render only their span. BUG FIXED same day: reaats_synth.py was started with `@"path"` (REAPER's ExecProcess keeps the quotes literally); now `--args-file PATH`, quoted only when the path has spaces. NOTE: the Analysis page still uses `@%s` with quoting only when needed, so it has the same latent problem for TMPDIR paths with spaces (Windows) -- not changed, tell tjingboem.
  PARALLEL CHANNELS in reaats_synth.py (tjingboem: "Python in parallel"): `--jobs N` (0 = cores-2, >=1, <= channels), `run_parallel` with a
  multiprocessing Pool, one `synth_task` per channel (each loads its own .ats), progress via a shared Array (`_SHARED`, workers never write files; the
  parent writes R.started and notices R.cancel -> terminate), result identical to sequential (tested with cmp). Measured 30 s: 2 ch 5.1 -> 3.4 s,
  4 ch 10.0 -> 5.9 s (1.5 s with the noise cache). Not parallel inside one channel.
  CRASH FIXED (tjingboem 9 Nov: "audition crashes Reaper. It started 0%", a 90 s stereo analysis): the temp files in /tmp were 563 MB and
  604 MB: every AUDITION wrote each channel's whole edited data to a temp .ats (Lua `ats.save` collected every frame string, then
  table.concat = a second copy), then the Python program read both files whole, in several processes, so the machine ran out of memory
  (oom_reaper) and the kernel killed REAPER. Now: (a) the editor writes NO .ats for a channel whose file is on disk (`c.current_file`): the
  program gets that file plus an EDITS file (`--edits`, one per channel in order, '-' = none; records of 4 little-endian doubles
  partial, frame, amplitude, frequency, 1-based = the cells in `edited_cells`, with their current values); (b) reaats_synth.py opens
  .ats files as a memory map (`load_ats`, `chunk(a, p0, p1)` 256 partials at a time, edits applied per chunk) -- never whole in memory;
  measured: 673 MB file (7000 partials, 4000 frames) 2 channels in parallel 26 s, parent 0.9 GB mostly shared file pages; (c) `ats.save`
  streams in 4 MB blocks. A channel without a file still gets a temp .ats (streamed). Test: test_py_synth.lua "edits".
  SECOND CRASH (tjingboem 9 Nov: "Reaper crashed again"; the kernel log showed `Out of memory: Killed process (reaper) anon-rss:12995200kB` -- REAPER itself,
  not Python): measured with a 2-channel set of 635 MB files (20 s, 13215 partials): the Lua tables take ~2.1x the file size (3.4 GB RSS for the set), and
  LOADING A SECOND SET while the first was still open peaked at 8 GB (both alive, the old one only freed by a later GC cycle, plus a whole-file string per
  channel). Fix in `load_file`: (1) `ats.header` looks at headers/sizes/frame grid first; (2) a memory check on Linux (/proc/meminfo MemAvailable, plus what the open set
  gives back) refuses a set that needs more than 85 % of it (needs = file bytes x MEMORY_FACTOR 2.1) with a message that says to analyse with a higher
  threshold; (3) the open set is released (chs = {}, data = nil, pending/last_audition cleared, two full collectgarbage) BEFORE the next one is loaded;
  (4) `ats.load` reads frame by frame, not the whole file as a string. Result: three loads in a row peak at 3.4 GB instead of 8.0 GB. Selection and edits cost little
  (only ~1 % of the cells sound: 475k selected points cost ~20 MB). Still open: phase arrays are a third of the memory (could be left out of memory and rebuilt on save).
  Stress script (not in the suite): scratchpad/stress_big.lua.
  THE FILE SIZE PROBLEM (tjingboem 9 Nov 2026, 536 s stereo, -40 dB: "finished in 907 seconds" = "No space left on device", /home had 12 GB): the ATS analysis gives every
  TRACK its own row, so rows grow with the length (1422 rows for 60 s -> 8894 rows for 240 s = 4.9 GB per channel; 536 s would be 25+ GB per channel). The time was
  never the analysis (240 s: tracking 14 s, rebuilding 6 s, noise 11 s) but writing: pyatsyn's `ats_save` wrote every number with its own struct.pack and file write (now
  numpy blocks, byte-identical), and `synth` (residual) looked at every row in every frame with a cache miss each (now `nonzero` on rows of the transposed frequencies, bit-identical).
  FIX: `pack_track_rows` in vendored tracker.py (option pack_rows, CLI --no-pack-rows, page checkbox "Share rows between tracks", default ON): greedy interval scheduling
  with a heap; a track may reuse a row when it starts >= 2 frames after the previous track on that row ended (one silent frame between, so fade-out/fade-in are as before). 60 s: 1422
  rows -> 11, 206 MB -> 2.7 MB; phase-exact synthesis of packed and unpacked files differ by 2e-16; noise bands identical. Side effect: a row is no longer "one partial"
  (the editor's plan_move logic already handles rows, but "select whole partial" would grab unrelated tracks). Also new: stage text in the progress file
  ("progress epoch text", `STAGES` in reaats_analyse.py) shown by the page, and per-step timings in the result ("Steps: tracking .. s, ..."). Disk-full note: the engine deletes its .part files on failure.
  COPY / CUT / PASTE (tjingboem 10 Nov 2026: "We need a copy and paste"): Ctrl+C / Ctrl+X / Ctrl+V (control chars 3 / 24 / 22; ReaMaskM also uses Ctrl+C/V). `clipboard.pieces[channel]` = points
  {p, df, amp, frq} with df relative to the first copied frame over all channels (so channels keep their timing); paste at `frame_at(playhead)` into the SAME channel numbers that are on and
  green; `edit.plan_paste` (lib/ats_edit.lua) is like plan_move without the source cells: runs of one source row keep their row if silent, else nearest silent row, else a new row; nothing is
  overwritten; points past the end are dropped and counted; the pasted points become the selection; one undo group across channels. Bugs found while building it (both fixed, tested):
  (1) an undo that removes rows left `edited_cells` entries for rows that no longer exist -> start_synth crashed writing the edits file (pruned in undo_single, and skipped in start_synth);
  (2) edits that ADD ROWS (paste, or a move into new rows) were silently ignored by reaats_synth.py (it only knew the file's rows): `a.rows = max(partials, highest edited row)`, `chunk` makes the extra rows.
  LASSO (tjingboem 10 Nov 2026: "can we make a lasso using Alt?"): Alt+drag (gfx cap bit 16) in a lane draws a freehand loop (`lasso.pts`, points >= 4 px apart, clamped to the lane); on release `select_poly` converts it to (time, log f) and `select_poly_single` tests every sounding point in the bounding box with the even-odd rule in each green channel (Shift+Alt adds; a click with Alt clears). RISK: many Linux window managers take Alt+drag to move the window; the manual says how to move that to Super. If tjingboem reports it does not arrive, switch the modifier.
  NOISE TOO LOUD (tjingboem 10 Nov 2026: "the mix is not right of the sine/noise part. Noise is way too loud"): measured on MixPre-042 (20 s) and sax with --residual-wav: the
  synthesized noise was +3.7 / +3.2 dB over the REAL residual, and spectrally tilted (+7 dB at 200-800 Hz, -5 dB above 4 kHz). Cause: ATS stores per band the AVERAGE |X|^2 per FFT bin
  (`residual_compute_band_energy`: sum / number of bins), equalised so the bands add up to the time-domain energy, i.e. a PSD not the band energy; Csound's atsaddnz (and our classic
  synth, calibrated to it) plays that as the band's power, so narrow low bands are too loud and wide high bands too soft. FIX (default, both synths): power_b = E_b * width_b / wbar(frame),
  wbar = energy-weighted mean width of that frame (energy of the frame preserved), and the gain re-calibrated so the noise has the power of the real residual (NOISE_GAIN_CORRECTED 0.20;
  classic 0.30 = Csound): synth/residual -0.14 dB (Lua) / +0.16 dB (Python) on MixPre, -0.30 dB on sax; band spread std 4.15 -> 1.84 dB. `--noise-shape classic|corrected`,
  `opts.noise_shape`. The noise caches (memory: `c.shape`; disk: fingerprint with shape and gains, "v2") know the shape. The "Csound level within 0.1 dB" statements apply to `classic` only.
  Measuring script idea: analyse with --residual-wav, synth with --no-sines, compare RMS and per-band power (rfft over the 25 band edges).
  DISK FULL (tjingboem 10 Nov: "i am running out of disk space"; / was at 100 % with 74 MB free): ReaATS never deleted its AUDITION sounds from earlier sessions -- 48 files, 2.4 GB in /tmp
  (a 536 s stereo sound is 200 MB) -- plus a 368 MB noise cache and my own test files. Now: `cleanup_session` (reaper.atexit) removes this editor's sounds and slices when it closes;
  `remove_stale_temp_files` at the start removes AUDITION sounds and synthesis-job files whose name's time stamp is more than 6 hours old (REAPER.EnumerateFiles); the sound history keeps 2
  (was 3). Tests: mock_channels 0 and 4a. Remember to delete my own big test files in the scratchpad (the scratchpad is under /tmp = the same small disk).
  PLAYHEAD / PRINT (tjingboem 10 Nov: "PRINT starts at the playhead ... is that in the manual? ... i do not know how to get the playhead to the start"): it WAS in the PRINT chapter but easy to miss, and
  there was no way to go to 0 except clicking the left end of the ruler. Now: Home = playhead to 0 (Home no longer fits the view: F and right-click do), End = to the end, a small
  `|<` button under PRINT (`start_rect`) that shows the playhead time in amber when it is away from 0 and resets it, the print status says "FROM x s" when the playhead is not at 0,
  and the manual says it in bold at the top of the PRINT chapter. NOTE: the main chunk of ATS_Editor.lua is AT LUA'S 200-LOCAL LIMIT (two locals were inlined to make room): put new
  helpers in an existing table, or split the file, before adding more local functions.
  CROSSHAIR + DRAG KEYS (tjingboem 10 Nov 2026: "while dragging, add a crosshair. Also: what do we have for shortcut options to keep the same X or Y while dragging?"): `draw_crosshair` draws thin lines through
  the pointer and a label while a move (`mover.active`), box or lasso is dragged; for a move the lines are at the EFFECTIVE position (after fine/lock), a faint cross marks the start, the kept axis
  is drawn in cyan, label "+N frames +x.xx st (time only)". The Shift/Ctrl swap agreed on 10 Nov is built: SHIFT = fine (a fifth of the mouse movement), CTRL = one axis only (the one that moves most),
  both read LIVE every frame (the mover accumulates `ex, ey`, so pressing/releasing mid-drag does not jump; `mover.axis` is set when Ctrl is held and the movement is > 3 px). Shift+box still ADDS to the
  selection. Arrow keys (Left/Right time only, Up/Down frequency only) are the keyboard alternative. No X/Y letter keys (gfx only reports key presses, not held keys). Tests: mock_run (free, Ctrl x2, Shift).
  BEND BOX / RUBBER SHEET (tjingboem 10 Nov 2026: "the selection box stays open ... corners with a dot ... the box gets another shape ... adding a point on the border ... we need an Apply command. That would be Enter."):
  PHASE 1 BUILT (frequency only). `lib/ats_warp.lua` (pure maths, tests/test_ats_warp.lua, 27): a warp = box (t0,t1,f0,f1) with four edges (bottom, top along time; left, right up the
  box), each a list of control points {s, v semitones} + per-segment arch `bulge`; corners are shared (set_value syncs the twin); the displacement inside is a COONS PATCH
  D(u,v) = (1-v)B(u)+vT(u)+(1-u)L(v)+uR(v) - bilinear corners; `M.changes(d, sel, w)` gives the per-point frequency changes (amplitude unchanged). Editor: everything is in ONE local table
  `W` (state W.region, W.w, W.drag, W.busy; functions W.draw/W.hit/W.mouse_down/W.drag_to/W.right_click/W.commit ...) because the main chunk is at 197/200 locals. Interaction: dots (corners and border dots)
  within 9 px, else an edge within 6 px; plain drag = dot or whole edge up/down, Ctrl+click on an edge = add a border dot, right-click on a dot = remove, Alt+drag on an edge = arch (ReaShapeM
  conventions), Shift = fine (x0.2), Shift also lets a box selection start on a box line. A selected point under the pointer wins over an EDGE (not over a dot; Alt excepted), so moving the
  selection still works. ENTER = apply (W.commit -> edit_on_channels -> one undo group, "bend up to x st"), ESC = cancel (before clearing the selection), CTRL+R = flat. A pending bend is applied
  automatically before: a new selection (select_box/select_poly/clear_selection), another edit (edit_on_channels), paste, copy, AUDITION, PRINT, save; undo/redo/load DROP it. W.region = the box the selection
  was made with (union with Shift), nil after an edit -> the box round the selected points. After Enter the box is flat round the points as they are now.
  NOT BUILT (phase 2): moving points in TIME with the box (stretch/squeeze): needs resampling of every track onto the frame grid and monotonic edges so tracks cannot cross; the dots are vertical-only today.
  NOT BUILT: "zoom to selection" (Z).
  ANALYSIS PAGE: INLINE EDITING + NOISE ADVICE (tjingboem 10 Nov 2026: "when i want to change a value in the Analyzer, i get a window popup ... why can i not enter values in the Analyzer itself?" and "i analyzed Piano.wav ... the noise part is enormous"):
  (1) numbers are now typed IN the field (`Page:begin_edit/commit_edit/key`, the editor loop drains `gfx.getchar()` and hands every key to `analysis:key`; click = all selected, Enter accepts, Tab next number, Esc cancels,
  click elsewhere accepts); the GetUserInputs popup remains only for the output path without JS_ReaScriptAPI. (2) The Piano analysis (Piano_2.ats, 16 partials, 54 frames) had been made with the REMEMBERED settings
  amp threshold -40 dB (my advice for the long recording!) and highest frequency 5000 Hz: everything quieter / higher became noise (sines -15.7 dB, noise -33 dB overall but the tail 1.4-9 dB under the noise).
  The synthesis was fine; the analysis settings were the cause. `M.noise_advice` shows an orange line on the page for sounds <= 2 min with threshold > -55 dB or highest frequency < 15 kHz. LESSON: settings persist between
  sounds; don't hand out settings advice without saying it is for long recordings only.
  PRE-ANALYSIS + SUGGEST (tjingboem 10 Nov 2026: "maybe we can do a pre-analyze fase that shows the lowest and highest frequencies in a sound?" and "a Suggest button ... values come up in red outside the value window on the
  right"): `python/reaats_prescan.py WAV [--start --duration]` (numpy only, ~0.9 s for 536 s: a long sound is sampled as 12 pieces of 5 s) prints `PRESCAN {lua table}`: average spectrum (8192 FFT, 160 log points
  20 Hz..nyquist, max per step), loudness envelope (50 ms blocks, <=120 points), strong low partials (local maxima >= 12 dB over +-60 bins and within 25 dB of the strongest low peak, parabolic frequency, note
  names), highest frequency with content (smoothed 1/6 octave curve, >= -75 dB), attack (steepest 20 ms rise starting above -45 dB) and `abrupt` (starts within 12 dB of full level) and `suggest` = lowest
  frequency (0.8 x lowest strong partial, rounded 5/10/25 Hz), highest (content x 1.15 rounded, 4000..min(20000, 0.95 nyq)), threshold (-60 <=120 s, -50 <=600 s, -40 longer), hop 0.125 for a fast attack or an
  abrupt start (<=120 s only) else 0.25, window cycles 4. Page: button "Look at the sound" (`Page:prescan`, synchronous ExecProcess, 60 s) opens `draw_pre` (spectrum, markers white = now / red = suggested, peaks, loudness, list with the
  reasons, "Use all suggestions", Esc = back); the suggestions also stand in RED (`-> 210`) right of each field (`self.suggest[key]`, click = `apply_suggestion`, tooltip = the reason). A new sound clears them.
  Verified on tjingboem's Piano (fundamental 254 Hz -> suggests 210 Hz / hop 0.125 / -60 dB, which is what the experiments found best: residual in the first 100 ms 6 dB lower than at 50 Hz). LESSON: "within 40 dB" took a
  -30 dB rumble (97 Hz) for the lowest note; 25 dB fixed it; a floor-based threshold was wrong for a decaying note (removed).
  FLAC / AIFF + EDITOR AT ONCE (tjingboem 10 Nov 2026: "Reading flac and aif and aiff directly in the Analysis page" and "after Analyzing, the Editor can be shown right away"): `python/reaats_audio.py`
  (numpy only): `read_audio` sniffs WAV / AIFF(+AIFC NONE, sowt, fl32, fl64, 8-32 bit, 80-bit extended rate) / FLAC and decodes AIFF and FLAC itself. FLAC = a pure Python decoder (STREAMINFO, constant/verbatim/fixed/LPC
  subframes, Rice 4/5-bit with escape, wasted bits, all channel modes, any block size code, CRCs not checked): exact (bit-identical to Piano.aif for tjingboem's Piano.flac), ~0.5 M samples/s
  => ~10 s per minute of stereo 44.1 kHz; `reaats_analyse.py` writes the label "reading the sound ... FLAC" to the progress file first; `reaats_prescan.py` uses it too. Tests: python/tests/test_audio.py (13; it contains a small FLAC
  ENCODER and AIFF writer used also by tests/mock_analysis.lua). Lua `wav_info.read` reads WAV/AIFF/FLAC headers (rate, channels, bits, frames, `format`). The page: "Choose sound file...", Use selected item accepts
  .wav/.aif/.aiff/.aifc/.flac. After a successful analysis `handle_reply` calls `env.back()` so the EDITOR IS SHOWN AT ONCE (status line: "analysed X: N partials, M frames in T s (steps)"); ANALYSE / Ctrl+A shows the page and its
  result again. Failures stay on the page. mock_analysis.lua uses `pump_done()` (waits for the editor status, then Ctrl+A) and `expire_status()` before ANALYSE (a stale status would end the wait at once).
  REPLAY (tjingboem, same day: "if nothing has changed ... play the file directly from memory"): `data_rev` (bumped in apply_changes and load_file)
  + switches + playhead + audition end + channel count = the key of `last_audition`; an identical key with the WAV still on disk is played again
  by `start_preview(..., replay=true)` without any render (status says "replayed"). Tested in mock_channels 4c.
- BROADCAST ERROR #2 (tjingboem 9 Nov 2026, 536 s stereo, -40 dB, 100 Hz-20 kHz: "operands could not be broadcast together with shapes (25750302,) (25750301,)"): NOT a
  Start/Duration problem. pyatsyn's `synth` sized its output `int(dur * rate)` with dur = samples / rate, which floats to one sample short for some lengths
  (int(25750302/48000*48000) = 25750301; 44109 samples at 44100 Hz reproduces it in a second). The residual (`signal - synthesis`) then failed at the END of the
  analysis, after all the work. Fixed in vendored `ats_synth.py` (`int(round(...))`), test `test_a_length_that_is_not_exact_in_floating_point_analyses` (every
  such length). The Lua and reaats_synth.py sides floor dur*sr too but only limit the length, so they are harmless.
- AUDITION LENGTH BUTTON REMOVED (tjingboem 10 Nov 2026: "Remove the Plays: 5s button"): the END/WINDOW/5 s/15 s button and the L key are gone; AUDITION always plays from the playhead to the end (`to = nil`).
  The engine/synth `to` option (`--to`, `opts.to`) stays (tested) but has no UI. HOME/END "did nothing" for tjingboem because the editor window was still the OLD script: a running Lua script keeps its
  old code, so every change needs the editor to be CLOSED AND STARTED AGAIN. A `build DD Mon HH:MM` stamp is now drawn bottom right (update it at every install) to see which version runs.

- NOISE FOLLOWS THE SINES (tjingboem 10 Nov 2026: "when noise is active, it should follow the movements of the sines"): when `show_noise` and the file has noise (`W.noise_on(d)`), the 25 noise-band energies follow
  TIME movements of the sines: move, bend/stretch (`W.commit`), copy/paste, cut (Ctrl+X; plain Delete leaves noise; transpose never moves noise). Planners in lib/ats_edit.lua: `noise_bands` (band included
  when >50% of its width is inside the region's frequencies), `plan_noise_move/clear/warp`, `noise_piece`, `plan_noise_paste`; a noise change is `{b,f,old,new}`; landing energies are ADDED, source silenced.
  `do_edit(..., noise_changes)` stores them in the undo entry (`W.apply_noise`), `data.noise_touched[b][f]` remembers edited cells (shifted by `W.shift_touched` when frames go in front); the edits file for the
  Python synthesis carries them as records with partial = -band (`apply_edits` writes them into `a.noise`). Region = the bend box, or the bounding box of the selection (`W.noise_region`). The main chunk is at
  Lua's 200-local limit: new helpers go into the `W` table. Tests: test_ats_edit section 11, test_py_synth (noise edits), mock_channels (stretch status "and the noise").

- IDEA, NOT BUILT (tjingboem 10 Nov 2026, "do not build the controls but add the idea to Claude.md. This needs more experimenting to better pinpoint the issue"): NOISE SHAPING CONTROLS.
  Context: tjingboem analyses a cello; the bow/breath noise lands in the noise bands. Their workflow: print the sines, then the noise (Sine layer / Noise layer checkboxes), mix in REAPER, and the
  lower noise bands feel too present (this was before / partly after the noise-shape correction below; re-test with the corrected noise before drawing conclusions). They suggested a high-pass on
  the noise for a better balance between low and high noise bands. Candidate design (to be tried, not decided): three controls beside the Noise layer checkbox, applied to AUDITION and PRINT and saved
  in the item state (ReaSnap): LOW CUT (Hz, smooth 12 dB/oct high-pass on the 25 band powers: g_b = 1/sqrt(1+(fc/f_b)^4) at the band centre), TILT (dB per octave around ~1 kHz) and LEVEL (dB).
  They scale the band energies in the synthesis (Lua `add_noise` and Python `add_noise` both have the per-band envelope), so no filter has to run; the noise caches (memory `c.shape`, disk
  fingerprint) would need the new parameters in their keys. Interim advice given: a ReaEQ high-pass (about 250-400 Hz, 12 dB/oct) on the printed noise track. A plain high-pass only removes low
  rumble; a TILT is probably what balances low against high. Later idea: select a region of the noise layer like partials and scale/delete the noise there (editing the noise bands themselves; any
  such edit must clear `d.noise_cache`). tjingboem wants to experiment first to pin down the problem: do not build until they say so.
- BUTTON NAMES (tjingboem 10 Nov 2026): "Import Sound File" (was Choose sound file...), "Import .ats File" (was Import .ats file...), "Inspect Sound File" (was Look at the sound). The Import Sound File dialog shows ONLY
  .wav .flac .aif .aiff: it uses JS_Dialog_BrowseForOpenFiles with `M.SOUND_FILTER` when JS_ReaScriptAPI is installed (the plain GetUserFileNameForRead can only offer one extension plus "all files", so without
  JS it stays as it was). Capitalisation of the page buttons follows these three: Title Case.
- BEND BOX PHASE 2: TIME (tjingboem 10 Nov 2026: "Bend box. Moving points in time (stretch and squeeze)"): BUILT. `lib/ats_warp.lua` control points hold v (semitones) AND h (seconds); the Coons patch is applied to both
  (`displacement`, `displacement_h`), arches `bulge` / `bulge_h`, corners sync both, `snapshot/restore`, `monotone(w)` (time must still grow left to right at 9 heights, min step 1/20 of the original) and
  `mapper(w)` (t, f -> t', f'). `ats_edit.plan_warp(d, sel, map)` replaces the vertical-only `warp.changes` in the editor: for each RUN of consecutive selected frames of one row it maps the points, makes
  the run again on the frames between the new first and last time (linear interpolation of amp and freq; a run between two frames -> nearest frame), silences the source cells, and places the new run like plan_move/paste
  (own row if free, else nearest silent row, else a new row); frames outside the file are dropped (`dropped` counts runs that vanished); the FILE LENGTH NEVER CHANGES (a stretch past the end is clipped;
  extending the file would be a later feature). Editor: handles drag in 2D (right = later; Shift fine x0.2, Ctrl one axis, both live); `W.geo.pps` pixels per second; border dots no longer slide along the edge
  (horizontal drag is now time; delete + Ctrl+click to reposition); Alt-arch picks v or h by the dominant movement; a drag step that would break `monotone` is REVERTED (`d.good` snapshot) so the dot waits;
  status "bend +2.50 st  +120 ms". Timing: plan_warp on all of sax.ats (4177 cells) 0.02 s. Tests: tests/test_ats_warp.lua (37), test_ats_edit.lua (45, 17 for plan_warp), mock_channels 4g.
  STILL NOT BUILT: Z (zoom to selection).
- FILE LENGTH EXTENSION (tjingboem 10 Nov 2026: "Extending the file length"): a bend that stretches past the end now makes the file LONGER. `edit.add_frames(d, k)` appends k silent frames (times at the frame spacing frame_size/sr, amp/frq/pha 0, noise bands 0, `d.dur += k*hop`);
  `edit.truncate_frames(d, n, dur)` undoes it. `plan_warp(d, sel, map, {max_extra})` may reach frame NF+max_extra and returns `frames_after` (the last frame it needs; cells use f > NF freely). `W.commit` plans every green channel first, takes the largest
  `frames_after` (room = min(NF, 2e7 / rows)), then gives EVERY channel (also red / off ones) exactly one undo entry in one group: the edit (`do_edit(..., ext)`) or `do_extend_only` (changes = {}); undo/redo re-truncate / re-extend
  (`frames_before/frames_after/dur_before` in the entry). Audition/print: the edits file gets a record with PARTIAL 0 = (0, frames, dur, 0) when the data has more frames than the file on disk (`ats.header`), and `reaats_synth.py` `apply_edits`
  extends times/noise and `chunk` reads only `file_frames` from the memmap. Paste and move still stop at the end of the file (not asked). The view is not changed when the file grows (press F). Tests: test_ats_edit (54), test_ats_file (55),
  test_py_synth (41: the longer sound is byte-identical to the longer data written out), mock_channels 4g (status, header duration, one Ctrl+Z / Ctrl+Y in 3 channels).
- VIEW FOLLOWS THE BEND DRAG (tjingboem 10 Nov 2026: "when i drag a selection longer than the original file, the window should follow this dragging and leave a bit of space"): `W.drag_to` autoscrolls the view (t0/t1 shifted, not zoomed)
  when the pointer is in the outer max(48 px, 8 %) of the plot (right: also past the end of the file; left: not below 0), speed 0.012 x view span per frame x depth (0..2.5); the scrolled time is added to the drag's time displacement
  (`d.th`, seconds) so the dot stays under the pointer; the Ctrl axis choice still uses pixel accumulators (`d.ex/d.ey`). Only the bend handles scroll (not the box selection, lasso or move drag). Test: mock_channels 4g.
- MID-EDGE HANDLES (tjingboem 10 Nov 2026: "when i drag the right edge, the whole selection goes with it. It is not stretching"): the drag started on a SELECTED POINT lying on the box line (the last points of a selection sit right at its right edge), and a
  selected point under the pointer wins over an edge line (so that moving the selection works) -> the mover moved everything. Fix: a square handle at the middle (s = 0.5) of every edge (`W.hit` returns `{kind="edge", mid=true}`, hit radius 10 px, always the box's
  own: it is not subject to the selected-point exemption); drawn as a 9 px square, highlighted on hover/drag. Dragging the right handle sideways = stretch, up = bend. Test: mock_channels 4g.
- FRAMES IN FRONT (tjingboem 10 Nov 2026: "i do not think we can stretch in minus time, before 0? ... what we could do is move the unselected portion when trying to drag beyond -0"): a bend that goes before 0 PREPENDS frames:
  `edit.prepend_frames(d, k)` (every row/noise band/phase table-moved k later, new times t1 + (f-1)*hop, dur += k hop, `d.front_frames += k`), `edit.drop_front(d, k, dur)` undoes it; `plan_warp(..., {max_front})` allows frames <= 0 (cell keys use
  `first_ok`) and returns `frames_front`; `W.commit` shifts every plan's changes and selection by `need_front` (all numbers are later), gives every channel one undo entry (`lengthen(front, frames_after)` shared by do_edit and do_extend_only; entry fields front /
  frames_before / frames_after / dur_before), shifts `edited_cells` (`shift_edited`), and moves `view` and `playhead` by k x hop so nothing jumps; undo()/redo() move them back/forward once per group. `data.front_frames` (reset to 0 by write_ats) feeds the
  edits record for the synthesis: record of partial 0 = (0, frames, dur, FRONT); `reaats_synth.py` `apply_edits` rebuilds times/noise and `chunk` places the file's own frames at `a.front`. The drag may scroll before 0 down to box start - 3.2 x its width. Darker
  shading for t < start and t > end in the picture. Tests: test_ats_edit (64), test_py_synth (42: byte-identical to the written-out data), mock_channels 4g (3 channels, undo/redo; its `sweep` helper first Alt+clicks to clear an old selection: an old box's
  dots would otherwise take the sweep).
- "USE ALL SUGGESTIONS" NOW GOES STRAIGHT BACK (tjingboem 10 Nov 2026: "there is no new information for the user to see on that page" once the suggestions are applied): `Page:apply_all_suggestions` now also sets `self.view = nil`,
  the same thing "Back to the settings"/Esc already did -- once all five suggested values are used, their rows and the red spectrum markers disappear anyway (nothing left in `self.suggest`), so there was nothing left on the "pre" view worth
  staying on. Before this, the page just sat there with the suggestion list and markers gone and the two buttons shifted up to fill the space, waiting for a second, separate click. Test: mock_analysis.lua (clicking "Use all suggestions"
  now shows "ANALYSIS: make..." right away, no Esc needed -- the Esc-after-"Use all suggestions" step this test used to check was removed, since it would now close the whole Analysis page instead of just the pre-view).
- THE "PRESS O TO OPEN..." HINT WAS REMOVED EVERYWHERE (tjingboem 10 Nov 2026), AND THE ANALYSIS/PRE-VIEW TOP MARGIN SHRUNK (same day, "a lot of empty space on the top"): the empty-window hint text (`draw_header`'s default branch) is gone;
  the empty window now shows nothing there unless `load_error` is set. Removed from the two in-code comments that quoted it (file header, the "window starts EMPTY" note near `loop()`) and from `ReaATS_manual_draft.md` (rebuilt `ReaATS.odt`
  from it) -- O/R/F/P/N etc. are still documented in the one keyboard-shortcuts line that already had them, nothing lost. A missed spot, caught only once this note was written: `tests/mock_analysis.lua` line ~300 still asserted the removed
  text and was silently broken (not re-run after the first edit) -- fixed to assert the hint is ABSENT instead; `tests/mock_snap.lua` was updated correctly the first time. LESSON: when a shared string is deleted, grep every test file for
  it by name, not just the ones found while first searching the source -- a passing-looking test run from an earlier, unrelated change is not evidence the current change didn't break something else.
  Removing the hint left the Analysis and "pre" (Inspect Sound File results) pages' top margin almost entirely blank, which is what actually prompted "a lot of empty space": `draw_analysis_frame` (`ATS_Editor.lua`) was reusing the main
  EDITOR's own header margin, `MARGIN_T + (#chs > 1 and CHAN_ROW or 0)` (70, or 100 with several channels) -- sized for the editor's channel LEDs/buttons/sliders, none of which the Analysis page has; it only ever shows at most one plain
  line of file info/error text up there (`draw_header(..., true)`, the `plain` branch). Replaced with a new, dedicated `ANALYSIS_TOP = 40` constant, decoupled from both the editor's margin and from `#chs` (which was never relevant to the
  Analysis page's own layout to begin with). Every row inside `Page:draw`/`Page:draw_pre` is built as a fixed offset from the `top` argument, so this is a uniform 30 px upward shift of the whole page, not a redesign. Updated every
  pixel-coordinate click/enter in `tests/mock_analysis.lua` to match (one click, the main-editor ANALYSE button at y=16, is unaffected -- it does not depend on this margin at all). All Lua tests pass.
- STRETCHING COULD CUT A GAP AT THE SELECTION'S OWN EDGE (tjingboem 10 Nov 2026, with a screenshot: "I dragged a selection. The place where the selection border was, is now cut... I guess it has moved a bit while stretching"): REAL BUG,
  CONFIRMED AND FIXED. Root cause: `W.get()` (`ATS_Editor.lua`) used to pad a box narrower than 30 px out to that minimum size (for grabbable dots -- "one partial, a few frames" would draw them on top of each other), by moving `t0`/`t1`/
  `f0`/`f1` themselves outward. Those are the SAME numbers `ats_warp`'s Coons patch uses for `u`/`v` (0 at one edge, 1 at the other); padding them out meant the TRUE first/last selected frame no longer sat exactly at `u=0`/`u=1`, so even a
  pure "drag the right edge to stretch" (left edge untouched) gave the FIRST selected frame a nonzero, unintended time nudge too (reproduced directly: a 5-frame selection, right edge dragged 60-150 ms, under a padded box -- the first 2-3 of
  the 5 ORIGINALLY SELECTED frames landed outside the destination range `plan_warp` computes from the shifted mapped times, while `plan_warp` still unconditionally silences every source cell in the original selected range regardless of
  where the destination lands -- a real, silent gap, exactly at the old selection edge, confirmed with a pure-Lua repro of the real `ats_warp`+`ats_edit.plan_warp` code, no REAPER needed). Fix: `W.get()` no longer pads `t0`/`t1`/`f0`/`f1` at
  all -- the box stays the exact extent of the selected points, so the warp math (and so `plan_warp`'s coverage) is untouched. The 30 px minimum moved to `W.geo` instead, purely in SCREEN PIXELS (`x0`/`x1`/`yt`/`yb`, widened symmetrically
  around their own middle when under 30 px) -- `W.pos`/`W.hit`/`W.drag_to`/`W.draw` all go through `W.geo`'s result already, so dots are still comfortably grabbable and click-detection still matches what's drawn; only the underlying `u`/`v`
  fed to `ats_warp` changed (now always exact). No existing test depended on the old padded math (the one bend/stretch test in mock_channels.lua drags a 535 px selection, well above the old 30 px threshold, so its coordinates and asserted
  values are untouched by this). New regression test, test_ats_edit.lua section 8b: a REAL `ats_warp` mapper (not the plain `function(t,fr) return t',fr' end` stand-ins the rest of section 8 uses) with a box built EXACTLY to the selected
  frames' own time span, asserts every originally-selected frame is still covered after a stretch -- confirmed this fails (reproduces the bug) if the box is padded the old way, confirming the test actually catches it, not just a tautology.
- STRETCHING A MIDDLE SEGMENT ALWAYS JUMPED TO A NEW ROW -- SECOND, SEPARATE BUG, SAME REPORT (tjingboem 10 Nov 2026, "no change, still a gap" after the fix above): the padded-box fix was real but was not what the screenshot showed.
  plan_warp's row choice (own row if free, else nearest silent row, else a new row) checks whether the run's OWN destination frames are free on its OWN row -- and for an ordinary stretch of a segment in the MIDDLE of an otherwise
  continuous, unbroken partial line, they never are: the rest of the SAME line is real, un-silent data sitting right where the lengthened run now needs to land, every time. So an everyday "lengthen this note a bit" ALWAYS collided with
  its own tail and relocated to a brand new row -- plan_warp still unconditionally silences the original [run.f0, run.f1] regardless of where the destination lands, so the original row showed a real, silent gap exactly at the
  selection's old edge, while the stretched copy reappeared disconnected on a different row (confirmed directly: one continuous line, frames 1..40, stretch the middle 5 frames -> result lands on row 2, row 1 silent at 18..22).
  Fixed with a ripple: when exactly one run uses a row, the run's own destination grows past its old right edge, the run's new start does not reach before its old start, AND the frame right after the run's old end already has real
  data with NO silent gap before it (the signal that it is the SAME line continuing, not a different stretch reaching into someone else's unrelated sound sharing the row by coincidence -- that case, "a stretch into other sound",
  test_ats_edit.lua section 8, is a real, already-tested, deliberately DIFFERENT scenario and still relocates to a new row, untouched, exactly as before), ripple(run, delta) shifts every EXISTING cell on that row after the run's old
  end later by delta (processed from the end of the file backward so a cell is always read before anything could overwrite it), clipped at `limit` the same way the run's own cells already are, and marks the new positions `taken` so no
  other run can be placed on top of them. `frames_after` is widened to the new, further-out tail end too, so W.commit's existing file-growth machinery (`need_end`, already built for "FILE LENGTH EXTENSION" above) naturally grows the
  file when the rippled tail runs past the current end -- exactly as it already does for a run's own direct overrun, same mechanism, no new one needed. Noise bands are NOT rippled (plan_noise_warp has no row/relocation concept to begin
  with -- it always writes additively into its own fixed 25 bands, never moves between "rows" -- so there was nothing to extend there). Real sax.ats data continuing right up to where a stretch tried to land (mock_channels.lua's existing
  bend test) now legitimately ripples AND grows the file in the same action it used to just relocate silently in -- W.commit's "the file is X s longer now" status (set AFTER do_edit's own "N points and the noise" message, so it was
  silently overwriting it whenever both happened together, which is now the common case) gained `any_noise` tracking across channels so it says "...and the noise" too instead of just dropping that information on the floor.
  STILL NOT BUILT: rippling backward (a stretch growing past its OLD LEFT edge into a contiguous same-row predecessor) -- that would need to push frames before 0, the whole-file "frames in front" machinery (shifts every row/channel in
  lockstep), not a per-row shift the way the forward case is; left relocating to a new row for now, same as any other collision. Tests: test_ats_edit.lua section 8b (the contiguous case ripples and stays on one row) and section 8's
  existing "stretch into other sound" case (the gap case still relocates, confirmed unchanged) -- both re-checked against the old behavior to confirm they actually distinguish the two cases, not just pass by coincidence. Full suite
  (500+ cases) passes.
- THIRD TIME, SAME REPORT -- THE CONTIGUITY CHECK WAS TOO BRITTLE, AND A RELOCATED ROW IN A MULTI-ROW SELECTION CAN LAND ON A BRAND NEW ROW (tjingboem 10 Nov 2026, with before/after screenshots of a multi-row bend box: "still a gap"
  after the ripple fix above). The exact-next-frame contiguity check (`d.amp[run.p][run.f1 + 1] > 0`) was too strict for real analysed audio: a genuinely continuous partial can report one or two flat-zero frames at an arbitrary point
  purely as a tracking artifact, with no audible gap at all -- a selection boundary landing on or near one of these by coincidence (very plausible, since the boundary is wherever the user happened to drag it, not tied to the data) made
  that one row fail the contiguity check and fall back to `choose()`. The screenshots were a box spanning several simultaneous rows at once; confirmed directly (five continuous rows, one with a 2-frame dip right after the selection,
  the rest clean): the dip row did not just fail to ripple, it got pushed all the way to a brand-new 6th row -- `free()`'s "a selected cell is vacated by the move" treats every OTHER row's own originally-selected cells as free too (the
  whole point of that rule, for a single-row collision), so with several rows sharing the same selected time range, EVERY existing row rejected the dip row's run, and `choose()`'s only option left was a new one. A single partial
  effectively vanishing out of a multi-row stretch, not just one row showing a gap.
  Fix: `looks_continuing(run)` replaces the single-frame check with a GAP_TOLERANCE (5 frames) lookahead from the run's old end -- real data anywhere in that window counts as "the same line continuing" and ripples; nothing in the
  window falls back to relocating, same as before. GAP_TOLERANCE is an explicit judgement call (ats_edit.lua, where `ripple` is defined), not derived from anything measured: short tracking dropouts are plausibly 1-2 frames, a few
  hundred ms of real silence between two different notes is not going to fit in 5. The two cases cannot be told apart from gap size alone up close, which matters for tests: the existing "stretch into other sound" test's gap was only
  2 frames, the same order of magnitude as the dip this fix now tolerates, so a test meaning to represent a genuinely separate sound now has to be built with a gap clearly wider than GAP_TOLERANCE on purpose, not just barely nonzero --
  that test's fixture was widened (and its stretch multiplied more, so the run's own reach still overlaps the far-away other sound; the original 2x stretch of a 5-frame run didn't reach far enough to even collide with a gap that wide,
  which was the first, wrong attempt at this fix: moving the other sound away without also moving the stretch's own reach just made the run fit on its own row, not relocate, since there was nothing left to collide with). New test,
  section 8c: a 5-row selection, one row with a 2-frame dip, confirms it stays on its own row like its neighbours (not row 6); a second case with a gap that exactly fills the GAP_TOLERANCE lookahead window, but with real data again
  just past it (within the stretch's own reach, so a genuine collision), confirms that one still relocates. Full suite passes.
- FOURTH TIME, SAME REPORT -- THE BOX'S OWN TIME ANCHOR WAS NEVER THE DATA'S ANCHOR (tjingboem 10 Nov 2026, a fourth screenshot after the GAP_TOLERANCE fix above, still "nope", with the right diagnosis in the same message: "the border
  itself is not the anchor point from which the partials are stretched ... stretching starts at the anchor points for each partial just inside the selection ... the partials that were on the border line ... should stretch as well to
  close the gap ... making this anchor point a joint point"). All three earlier fixes were real and are still needed, but none of them touched the actual root cause, which was present on EVERY stretch, not an edge case: `W.current_region()`
  returned `W.region` whenever it existed, and `W.region` is `{ t0 = ta, t1 = tb, ... }` set straight from `select_box`'s `ta`/`tb` (ATS_Editor.lua ~2694: `select_box(t_of(b.x0), t_of(b.x1), ...)`) -- the RAW, continuous, pixel-to-time
  conversion of wherever the mouse was when the drag rectangle was drawn, never snapped to the frame grid at all. `W.get()` feeds this straight into `ats_warp.new(r.t0, r.t1, ...)` as the box's own `t0`, i.e. the point the math treats as
  "u = 0, zero displacement, the anchor nothing moves away from". But a mouse drag essentially never lands exactly on a frame's own time -- `plan_warp` computes each run's own `f0` from the actually SELECTED frames (`sel[p]`, built by
  `select_box_single` against the frame grid), so the true first selected frame almost always sits a fraction of a hop AFTER `ta`, at a small but nonzero `u`. Any stretch already displaces a frame at nonzero `u` by a proportional amount,
  so the row's own true first frame moved a little relative to the still-completely-untouched, un-selected frame directly before it in the same row -- a real, silent gap, at exactly the old selection border, on every row of a multi-row
  box alike (same `u`, since time-only displacement from a plain edge-drag does not depend on frequency) -- which is exactly the uniform, identical-width black column across every line in the screenshot: not an aggregate of five
  separate per-row glitches, one single shared cause. Confirmed directly with a pure-Lua repro of the real `ats_warp`+`ats_edit.plan_warp` code: one continuous row, select frames 10..30, build the box with `t0` a fraction of a hop BEFORE
  `times[10]` (what an unsnapped drag typically gives) vs. `t0 = times[10]` exactly (the fix) -- same stretch, same selection: the raw box leaves frame 10 silent with nothing replacing it, the snapped box does not.
  Fix: `W.current_region()` still returns `W.region` outright when there is no actual sine selection (an empty, or noise-only, drag -- nothing to snap to, the box has to be the gesture itself), but whenever any channel DOES have a
  selection, `t0`/`t1` are now always the real min/max TIME of the selected frames (`si.t0`/`si.t1`, already computed by `update_sel_info` from `sel` itself, on the frame grid by construction) -- never the raw drag rectangle, regardless of
  whether `W.region` exists. `f0`/`f1` (frequency) deliberately keep using `W.region`'s raw rectangle when it exists, unchanged from before: frequency is stored as a continuous value per frame, not resampled onto a frequency grid the way
  time is, so a mismatch there cannot silently drop a cell the way a time mismatch can -- changing it too would have been scope creep, and did in fact first break the existing corner-drag bend test below by moving the box's on-screen
  frequency edges (reverted to touch only `t0`/`t1`). No existing test depended on `W.region`'s raw time surviving into the box used for warping (mock_channels.lua's bend/stretch test drags a rectangle whose time bounds already match the
  actual data underneath almost exactly, so it was not sensitive to this). Full suite (500+ cases) passes.
- THE DRAG-TIME STRETCH CAP HAD NO RECORDED REASON, SO IT IS GONE (tjingboem, 10 Nov 2026: "i need to stretch partials for creative
  sounds. There should be no cap."). `W.drag_to` clamped the time displacement of a dragged corner/edge to +-3x the selection's own
  width (ATS_Editor.lua, `d.dh = ... clamp(d.th, -3 * span, 3 * span)`); `git log -S"3 * span"` found only the original commit that
  added dragging, with no comment explaining the figure -- not a safety limit, since the real one (`W.commit`'s `room`: the file may
  grow by at most its own length again, or 20 million cells, whichever is smaller) is untouched and still applies regardless of how
  far the handle is dragged. Removed; `d.dh` is now the plain drag distance. Full suite passes (no test depended on hitting the cap).
- THE MAX-PARTIALS SLIDER -- A NEW CREATIVE TOOL, NOT A BUG FIX (tjingboem, 10 Nov 2026, after asking why there was no way to say
  "give me 10 partials for this sound": ATS tracking has no such knob -- the partial count is an emergent result of the threshold,
  frequency range and track-length settings, not a target it solves for -- so building "keep only the N loudest, drop the rest" as
  a post-processing step on an existing analysis was the alternative. Design, settled with tjingboem before writing any UI code:
  ranked by TOTAL ENERGY (the sum of a partial's amplitude over its own length -- favours a long, sustained partial over a short,
  loud blip, which reads better for "important to the sound" than a bare peak amplitude would); the unit kept/dropped is each
  separate CONTIGUOUS RUN of real sound, not a whole row -- `pack_rows` already shares a row between unrelated, non-overlapping
  tracks, so a whole-row count would conflate them; scope is the selection box's own region (time AND frequency), falling back to
  the whole file with no selection; and it behaves exactly like the bend box -- shaped live (a dimmed preview of what would be
  dropped, directly in the picture, nothing touched in the data yet), Enter commits, Esc cancels.
  Pure logic in lib/ats_edit.lua: `rank_partials(d, region)` walks every row for contiguous amp>0 runs, keeps the ones that enter the
  region (any frame inside both its time AND frequency range; nil region = the whole file), and returns them sorted loudest first;
  `plan_keep_loudest(d, runs, n)` takes that SAME ranked list (not recomputed) and n, and silences every run beyond the n'th --
  passing in the already-ranked list rather than re-ranking is what keeps a live preview and the eventual commit from ever
  disagreeing about which run was where.
  The UI (ATS_Editor.lua): `W.pk` holds the ranking, built lazily (`W.pk_get`, called every time it might be drawn or hit-tested) and
  invalidated two ways -- the box's own region bounds changed (a new or different selection), or `group_counter` moved on since it was
  built (an edit happened that could have touched the same cells, even one that leaves the region's own bounds unchanged, e.g. a
  move within the box) -- rather than hooking a reset into every single place `W.region`/`sel` can change, which is scattered across
  a dozen call sites and an easy one to miss (as the "forgot to re-run a test file" lesson above already showed once this session).
  A small slider is drawn just under the box (`W.pk_rect`, clamped to the lane's own bottom so a box selected low in frequency cannot
  push it off the plot or onto the time ruler); dragging it maps the mouse x linearly across its width to n (0..the most of any one
  channel) and the live preview (`W.pk_draw_preview`) dims every run beyond n directly over the cached picture, drawn fresh every
  frame like the box itself rather than baked into the picture's own render cache, so dragging needs no re-render of the whole
  picture. DELIBERATELY NOT COMBINED with a bend shaped on the same box in one Enter: both silence cells, computed from a snapshot of
  the data at the moment each was shaped, and reconciling which one's view of "already silenced" wins for a cell both could touch
  (narrow, but real: a partial dropped by the slider could also be a bend's own collision target) was not worth the risk for a first
  version -- whichever one is engaged (slider moved down from its full count) wins Enter/Esc outright; the bend is untouched and can
  still be applied afterward with a fresh Enter. Tests: lib/ats_edit.lua's two new functions get a dedicated section (12) in
  test_ats_edit.lua (a shared row's two separate runs rank as two, the sort order, both n=0 and n>=every-run edges, and a region that
  excludes a row entirely); the full interactive path (drag, live preview text, Enter, the actual silenced amplitudes on a saved and
  reloaded file, Esc, and undo restoring the saved file's data again) is a new dedicated end-to-end test, tests/mock_partials_knob.lua,
  against a hand-built 4-partial fixture (known, distinct energies and frequencies) rather than the shared sax.ats/mc_ch*.ats fixtures,
  so the exact pixel geometry of the slider is fully predictable rather than approximated. Full suite passes.
- THE SLIDER MADE GREY, AND MADE BIDIRECTIONAL (tjingboem, 10 Nov 2026, straight after the above). Two follow-ups, same control:
  (1) the dimmed preview used the original line's own colour at 90% alpha -- too subtle to read as "this is being dropped" rather
  than just a dimmer version of the same partial. Now a flat, fully OPAQUE grey, and drawn TWICE (the main line and the 1px-lower
  highlight line `draw_partials` itself draws for anything louder than -30 dB) so no sliver of the original bright colour can still
  show beside a single grey line the way it could before. Verified the already-reported worry (grey lingering after Enter) was
  already correct rather than a bug: added an explicit check (test above) that the slider re-ranks against the smaller, real
  partial count in the SAME frame Enter is processed -- `pk.n >= pk.max` becomes true again immediately because there is nothing
  left to rank above it, which is exactly the guard `W.pk_draw_preview` already used to decide whether to draw anything at all.
  (2) "What if we move the slider from left to right? We could then eliminate the strongest partials... drag from right to left =
  keep the strongest, drag from left to right = keep the weakest" -- the slider is now CENTRED: the middle is "nothing dropped" (as
  the full-right end used to be), dragging LEFT keeps the n loudest same as before, dragging RIGHT keeps the n WEAKEST instead,
  eliminating the loudest ones. `W.pk.mode` ("loud"/"weak") records which half is active; `W.pk_drag_to` derives both `n` and
  `mode` fresh from the mouse x every call (so a single drag can cross the centre and flip mode mid-gesture, which just falls out
  of the maths rather than needing special-casing). lib/ats_edit.lua is UNCHANGED: `plan_keep_loudest` only ever keeps the FRONT of
  whatever ranked list it is handed, so "weak" mode hands it `p.runs` reversed (quietest-first) instead of changing the function --
  the core, already-tested logic stays agnostic of direction entirely. `W.pk_draw_preview` mirrors this: dims the TAIL of the
  loudest-first list in "loud" mode (unchanged), the FRONT of it in "weak" mode. A new label helper, `W.pk_label` (a FIELD of `W`,
  not a new top-level `local` -- this file is already at Lua's 200-local-variable chunk limit, hit immediately when a plain local
  function was tried first) builds the slider's own text ("keep N loudest/weakest of M", or "max partials: M of M" at rest) so the
  drag status and the drawn label can never say something different from each other.
  Test lesson, found the hard way extending tests/mock_partials_knob.lua for the new mode: `undo_single` (and `redo_single`) call
  `clear_selection()` as part of normal, intentional behaviour -- so a test that does Ctrl+Z and then expects the selection (and so
  the slider) to still be there needs to select again first; the symptom when it is not re-selected is not an error, just every
  selection-dependent status line silently missing, which looks exactly like a feature regression until you dump every drawn
  string to look for it. Also fixed in the same pass: `saw()` fell off its own end with no explicit `return nil` when nothing
  matched, so `tostring(saw(...))` used on its own (not as part of an `x or y`, which coerces to one value either way) crashed
  outright instead of reporting "nil" in the assertion message -- a trap for the NEXT test that writes `tostring(saw(...))` without
  the `or`, not just this one. Full suite passes, including a new end-to-end section of mock_partials_knob.lua for the weak-mode
  mirror (drag right, keep the 2 weakest of the 4-partial fixture, verify the 2 loudest are actually silenced in the saved file).
- THE SLIDER MOVED OUT OF THE PLOT ENTIRELY, INTO THE HEADER (tjingboem, 10 Nov 2026: "the 2 way slider is mostly in the way of
  other partials. Can we move the slider to above the selection where there is always empty space?"). First attempt: pin it to the
  very top of the PLOT (the same row the playhead's own time readout sits in) instead of next to the box. That broke mock_channels.
  lua's "a stretch to before 0" test outright: a bend's own draggable corners and edges can be anywhere the selection's own
  frequency range reaches, including the plot's very top row when a selection spans the whole visible range (a plain "select
  everything" does, and is exactly the kind of broad selection someone thinning partials would make) -- so the slider's hit test
  (checked first in the input dispatch) silently stole the click meant for the box's own corner dot. There is no row INSIDE the
  plot that is reliably free of the bend box's own draggable area, because that area is defined by the selection itself, not by any
  fixed layout.
  Fixed by moving the slider OUTSIDE the plot altogether, into the header: the row between the file info line and the "selected:
  ... points ..." summary (y 26-47 in both single- and multi-channel layouts) is blank except on its own right-hand side, where
  PRINT / EXPORT .ats / ANALYSE and the rest of the header buttons live -- `W.pk_rect`'s `right_limit` mirrors that chain of rects
  (checkbox_rect -> audition_rect -> print_rect -> export_rect -> analyse_rect) by hand, since those functions are declared further
  down the file and are not yet in scope as locals at the point `W.pk_rect` is compiled (an early return just for geometry was not
  worth moving a few hundred lines of code for). Its hit-test is no longer gated on `inside` (the plot's own mouse-over-the-picture
  test) since it no longer lives inside the plot; it is checked in the SAME un-gated header block as the Noise/Sine checkboxes and
  the transport buttons, right after ANALYSE and before the time ruler. x0/x1 still follow the selection's own time span (via
  `W.get()`'s `t0`/`t1`), clamped to stay left of that button row and never narrower than 60 px.
  The persistent "max partials: N of M" label beside the slider is gone too: the header gap is not tall enough for a bar AND a
  label without reaching into the "selected: ..." row below it, and the bend box itself already follows the same convention --
  nothing is written beside it while it is flat, only once it is actually being shaped (`W.commit`'s own "bend ...: Enter applies"
  text). The live count still shows on the status line, via `W.pk_drag_to`'s existing `set_status` call. tests/mock_partials_knob.lua
  updated for the new geometry and the missing persistent label (the "slider re-ranks immediately" check, previously read straight
  off that label, now drags again right after Enter and reads the live status instead -- same thing it was checking, read a
  different way). Full suite passes, including the mock_channels.lua stretch-to-before-0 test that caught this.
- THE SLIDER WAS NOT, IN FACT, INVISIBLE -- JUST NEARLY SO (tjingboem 10 Nov 2026, twice: "where is the slider?", after moving it
  into the header above). Also caught something more basic first: the build stamp at the bottom-right of the editor ("which version
  of the script is running") was a hand-written literal that I had never once updated while working on this feature all day, so the
  first screenshot was a genuinely stale, pre-session build -- REAPER keeps a script's old code loaded until its window is closed
  and reopened, same as always. Told tjingboem to reopen the window; it's now bumped on every deploy during this feature's work.
  After reopening, still nothing showed, even zoomed in on just the header strip. Rather than guess again, recorded every gfx.rect
  call for a selection built to match the real one in the screenshot (a real sax.ats fixture, a comparable point/partial count) and
  printed whichever ones landed in the header's own y-range: the slider's rect WAS there, at sane coordinates (x matching the
  selection's own time span, y=34, 8 px tall) -- so the earlier placement fix was not the bug. The actual problem: its colours
  (`gfx.set(0.16, 0.18, 0.22, 1)` track, muted grey border) were barely lighter than the header's own near-black background, and 8
  px is thin to begin with -- reads as basically invisible once screenshotted and shared, which is exactly the two reports that
  came in. Fixed by making it unmistakable regardless of contrast conditions: taller (12 px, still well inside the 24-48 px header
  gap), a teal-tinted track instead of flat grey, and a bright cyan border -- deliberately far more saturated than anything else in
  this muted header, so it cannot blend in again. Lesson for next time something "isn't showing": record the actual draw calls for
  a matching scenario before assuming either a geometry bug or genuinely dead code -- it settled in one step whether the function
  even ran, instead of re-reading the same logic a fourth time looking for a mistake that was not there.
- THE SLIDER WAS GIVEN UP ON, AND REPLACED WITH A PLAIN BUTTON (tjingboem, 10 Nov 2026, after the contrast fix also showed nothing:
  "Maybe we should think about other solutions"). Even an UNCONDITIONAL, oversized (the whole top 60 px of the window), solid-
  magenta `gfx.rect` call, placed in the exact same per-frame function as the build stamp text (which DID keep reflecting every
  edit, confirming fresh code loaded every time), produced no visible effect and no functional response to a click -- confirmed
  with the SAME code after a full REAPER restart, ruling out a stale window or a stale script load, and confirmed in an offline
  reproduction that the exact same file DOES fire that gfx.rect call when run under plain lua5.4. Something about that specific
  draw call never reached the screen in that one real REAPER session, for a reason this never got to the bottom of -- every other
  gfx.rect/gfx.set call in this file, old and new, renders fine there (buttons, the bend box, checkboxes), so it was not a blanket
  gfx problem, and no error ever appeared in the REAPER console either. Rather than keep spending tjingboem's time on an
  unreproducible difference between a real REAPER Lua host and everything this project can test offline, the whole custom-drawn,
  live-dragged slider (and its dimmed, live preview over the picture) is gone. In its place: a plain button, drawn and hit-tested
  exactly like PRINT/EXPORT/ANALYSE (mechanisms already proven, in that exact session, to render and respond), which opens
  REAPER's own text-input dialog (reaper.GetUserInputs, the same one Export/Save already use) asking how many partials to keep --
  positive keeps that many loudest, negative that many weakest -- and applies immediately as one undo step. No live drag, no
  dimmed preview; W.pk_ranks/W.pk_apply replace the whole W.pk/W.pk_get/W.pk_commit/W.pk_draw*/W.pk_drag_to/W.pk_mouse_down state
  machine, and lib/ats_edit.lua's rank_partials/plan_keep_loudest (always solid, tested independently of any of this) are unchanged
  and reused as-is.
  Also removed in the same pass, at tjingboem's request ("remove all these unreadable messages from the bottom of ReaATS"): the two
  long keyboard-shortcut hint lines that used to run along the bottom of the window -- the button now sits in that freed space
  (bottom left, where the first hint line began). The button is greyed out, and its click does nothing, whenever there is no
  selection (`any_sel()`), per tjingboem's explicit ask.
  tests/mock_partials_knob.lua rewritten for the new flow: the fake `reaper.GetUserInputs` now records whether it was called and
  returns a settable (ok, text) pair, so the test can drive Cancel, a non-numeric answer, a positive count and a negative one, each
  checked against the actual saved-and-reloaded file's amplitudes, plus confirming the button does NOT open the dialog at all when
  nothing is selected. Hit the 200-local chunk limit again doing this (two new `local function`s for the button's rect/draw) --
  same fix as before, made them fields of W instead. Full suite passes.
- MAX PARTIALS SILENCED REAL DATA OUTSIDE THE SELECTION (tjingboem, 10 Nov 2026, with screenshots: selected a short stretch in the
  middle of several sustained partials, set MAX PARTIALS to 1, and a dropped partial went silent well to the LEFT of the selection
  box too -- "only the selection should be affected"). Root cause: `rank_partials` and every other edit in this file (delete,
  transpose, move, plan_warp...) are NOT the same shape. Every other edit works on `sel[p][f]`, the literal per-cell selection.
  `rank_partials` instead took a `region` (the box's own t0/t1/f0/f1) and ranked -- and so `plan_keep_loudest` silenced -- the WHOLE
  continuous run of real sound (amp > 0) wherever it merely PASSED THROUGH that box at any single frame, however far the run
  actually reached outside it. A partial sustained from well before the selection to well after lost its entire length the moment
  it was not among the ones kept, not just the selected stretch of it. This was there from the very first version (the abandoned
  slider had the same bug; it was simply never exercised with a selection that was narrower than an entire continuous partial, in
  all the testing that went into that feature, including the pure-logic tests -- every fixture so far used partials selected in
  full, end to end, which cannot expose this).
  Fixed in lib/ats_edit.lua: `rank_partials(d, sel)` now takes the actual selection, exactly like plan_move/plan_warp already do --
  finds contiguous runs of SELECTED frames per row (same sort-and-group idiom as those two), ranks them by energy over only the
  selected frames, and `plan_keep_loudest` (unchanged) then only ever silences f0..f1 of a run, which now IS the selected sub-range,
  never more. ATS_Editor.lua's W.pk_ranks passes `W.sel_of(i)` (a new accessor beside the existing W.sel_info_of, same `(i==cur) and
  sel or chs[i].sel` pattern) instead of `W.current_region()`'s box.
  New regression coverage at both levels: test_ats_edit.lua's section 12 adds a continuous one-partial fixture where only the
  middle third of the frames is selected, asserting the resulting run's own f0/f1 match the selection exactly and that silencing it
  leaves the real data on both sides, on the very same row, completely untouched; mock_partials_knob.lua adds an end-to-end case
  selecting only a middle stretch of a real multi-partial picture and verifying (via the saved file) that a silenced partial is
  silent inside the selection and still fully intact, same amplitude and frequency as the original, well before and well after it.
  Also fixed two accuracy issues found WHILE building that end-to-end case, both pre-existing in the test itself, not today's bug:
  the "select everything" sweeps used a few pixels of inset from the plot's own edges, which (now that silencing is exact instead
  of over-reaching) could miss the very first or last frame and leave it stuck at its old value -- replaced with a sweep that starts
  exactly on the plot's left edge and deliberately overshoots the right/bottom, which the box-select's own clamp brings back to
  exactly the view's own t0/t1; and reusing the still-active selection from a previous scenario to start a new, smaller drag can hit
  an already-selected point and MOVE the old selection instead of replacing it with a new one -- a plain Esc, or here a reload (also
  needed to undo earlier scenarios' edits still sitting in the live data), clears it first. Full suite passes.
- THE EMPTY-STATE ANALYSE BUTTON MOVED TO THE MIDDLE, AND GAINED A SECOND JOB IN ITS LABEL (tjingboem, 10 Nov 2026, starting a look-
  and-feel pass: "move the Analyze button to the middle above the empty Editor and make the button show: ANALYZE or IMPORT FILE...
  This button takes us to the Analysis page where also a file to import can be chosen"). Before, the SAME small ANALYSE button and
  position served both the empty window (nothing open yet) and the normal, file-open header (top right, beside EXPORT/PRINT/
  AUDITION) -- fine once something is open, but on first launch it left no visible clue that the Analysis page is also where you
  open an EXISTING .ats file (`lib/analysis_page.lua`'s own "Import Sound File" / "Import .ats File" buttons), not only where a new
  sound gets analysed. Split into two: `W.empty_analyse_rect`/`W.draw_empty_analyse_button` (fields of W, not new top-level locals --
  this file's main chunk is already at Lua's 200-local limit, hit immediately when tried as plain locals first) draw a bigger
  button, centred above the empty plot, labelled "ANALYSE or IMPORT FILE"; `analyse_rect`/`draw_analyse_button` are UNCHANGED, still
  the small, top-right, plain "ANALYSE" button, used once a file is actually open.
  Caught a real crash writing the click dispatch for this: `local ax2, ay2, aw2, ah2 = (data and analyse_rect() or
  W.empty_analyse_rect())` -- Lua's `and`/`or` each adjust their OWN operand to exactly one value before combining, so only the
  FIRST of analyse_rect()'s four returns survives that expression; ay2/aw2/ah2 end up nil regardless of which rect "wins", throwing
  the moment anything was clicked with a file open (mock_channels.lua's own Analysis-page round trip caught it at once). Fixed with
  a plain `if data then ... else ... end` assigning all four locals, which the full suite is why it is run before every deploy --
  this would not have been something to find by eye.
  Tests updated for both the new label text and the new button position (mock_analysis.lua, mock_snap.lua -- the empty-state click
  test now clicks the centred rect instead of the old top-right one). Full suite passes.
