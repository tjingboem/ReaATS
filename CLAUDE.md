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
