--[[----------------------------------------------------------------------------
  ATS_Editor.lua  --  a SPEAR-like partial editor for Csound/ATS ".ats" files, in REAPER.

  Shows the sine partials as lines (time across, frequency up on a log axis,
  brighter = louder) and the 25 noise bands as a faint shaded layer behind them
  (checkbox top right). Select points of partials with a box, then delete or
  transpose them. Edits are saved to a NEW file next to the original.

  Run it from the action list (Actions > Show action list > ReaScript: Load...).
  The first run asks for a .ats file; later runs reopen the last one.

  Mouse:  left drag = select box (Shift adds, click on empty space clears)
          left drag ON a selected point = move the selection (Shift locks to one axis)
          right/middle drag = pan       wheel = zoom time
          Ctrl+wheel = zoom frequency   Shift+wheel = scroll time
          hover = time / frequency / note / nearest partial
  Keys:   Delete        silence the selected points
          Up / Down     transpose the selection (1 semitone; Shift 10 cents; Ctrl octave)
          Ctrl+Z / Ctrl+Y   undo / redo
          Left / Right  move the selection one frame in time (Ctrl: ten frames)
          A or AUDITION render the edited data (in Lua, no other program needed) and play it; Space stops
                        (partials / noise follow the P / N switches)
          ANALYSE / Ctrl+A  the Analysis page: make .ats files from a sound (python/reaats_analyse.py)
          Ctrl+P / PRINT render to a permanent WAV (unsaved edits are saved first) and put it on the selected
                        track (or a new ReaATS track) at the edit cursor; remembered for ReaSnap
          Ctrl+S        save as <name>_edit.ats (with phase; never overwrites)
          EXPORT .ats / Ctrl+Shift+S  export an .ats file: choose the folder and name (Csound-compatible; asks before replacing a file)
          O open   R reload   F or Home fit view   P partials on/off   N noise on/off
          Esc           clear the selection, then close
--------------------------------------------------------------------------------]]

local script_dir = ({ reaper.get_action_context() })[2]:match("^(.*)[/\\]") or "."
local ats = dofile(script_dir .. "/lib/ats_file.lua")
local edit = dofile(script_dir .. "/lib/ats_edit.lua")
local synth = dofile(script_dir .. "/lib/ats_synth.lua")
local wav_info = dofile(script_dir .. "/lib/wav_info.lua")
local Analysis = dofile(script_dir .. "/lib/analysis_page.lua")
local Serial = dofile(script_dir .. "/lib/reaats_serial.lua")     -- the tool's own save format (ReaSnap contract piece 1)

-- ReaSnap Integration Contract, optional: pieces 2 and 5. The editor works exactly the same without ReaSnap;
-- these only read values ReaSnap may have left for it, once, at the very start.
local reasnap_instance_number = nil          -- piece 2: "ATS Editor #2" in the window title
local reasnap_project_identity = nil         -- piece 5: which project this instance belongs to (Close All)
local reasnap_launch_time = reaper.time_precise()
do
  local pending = reaper.GetExtState("ReaSculpt_Registry", "pending_ReaATS_instance_number")
  if pending ~= "" then
    reasnap_instance_number = tonumber(pending)
    reaper.SetExtState("ReaSculpt_Registry", "pending_ReaATS_instance_number", "", false)   -- consume it
  end
  pending = reaper.GetExtState("ReaSculpt_Registry", "pending_ReaATS_project_identity")
  if pending ~= "" then
    reasnap_project_identity = pending
    reaper.SetExtState("ReaSculpt_Registry", "pending_ReaATS_project_identity", "", false)  -- consume it
  end
end
local closecheck_last = 0

-- ------------------------------------------------------------------ settings
local TITLE = "ATS Editor" .. (reasnap_instance_number and (" #" .. reasnap_instance_number) or "")
local DB_FLOOR = -80            -- partials quieter than this (relative to the loudest) are not drawn
local NOISE_RANGE_DB = 60       -- noise shading spans this many dB below the loudest band
local MARGIN_L, MARGIN_R, MARGIN_T, MARGIN_B = 62, 50, 70, 54
local EXT_SECTION, EXT_LAST = "tjingboem_ATSViewer", "last_file"

-- --------------------------------------------------------------------- state
local data, fname, load_error
local view = { t0 = 0, t1 = 1, f0 = 40, f1 = 16000 }
local show_partials, show_noise = true, true
local dirty = true
local last_w, last_h = 0, 0
local drag = nil               -- { x, y } of the last mouse position while dragging
local prev_down = false        -- left button state in the previous frame (for click detection)
local sel = {}                 -- sel[p] = { [frame] = true }: selected points (partial p at that frame)
local sel_info = nil           -- { points, partials, t0, t1, f0, f1 } of the selection, or nil
local clear_selection, update_sel_info   -- defined with the selection functions below
local undo_stack, redo_stack = {}, {}   -- each entry: { name = ..., changes = { {p, f, oa, na, of, nf}, ... } }
local modified = false
local edited_cells = {}         -- edited_cells[p][f] = true for every cell an edit has touched (the phases of those runs are rebuilt on save)
local saved_depth = 0          -- undo depth at the last save/load: modified = (#undo_stack ~= saved_depth)
local current_file = nil       -- the .ats file that holds the data as it is now (the opened file, or the last save)
local status_msg, status_until = nil, 0
local showing_analysis = false   -- the Analysis page is on screen instead of the picture
local analysis = nil            -- the Analysis page object (made at the end of the file)
local mover = nil              -- a drag that moves the selection: { x0, y0, x, y, lock }
local box = nil                -- rubber-band box while the left button is down: { x0, y0, x1, y1, add }
local amp_thresh = 0

local LOG = math.log
local function clamp(x, a, b) if x < a then return a elseif x > b then return b else return x end end

-- ------------------------------------------------------------------ geometry
local function plot_rect()
  local w, h = math.floor(gfx.w), math.floor(gfx.h)
  return MARGIN_L, MARGIN_T, math.max(w - MARGIN_L - MARGIN_R, 10), math.max(h - MARGIN_T - MARGIN_B, 10)
end

-- Local (plot-relative) coordinates.
local function tx(t, pw) return (t - view.t0) / (view.t1 - view.t0) * pw end
local function fy(f, ph)
  return ph * (1 - (LOG(f) - LOG(view.f0)) / (LOG(view.f1) - LOG(view.f0)))
end

-- ------------------------------------------------------------------- colours
local STOPS = {
  { 0.00, 0.16, 0.20, 0.55 },
  { 0.40, 0.10, 0.65, 0.85 },
  { 0.72, 0.95, 0.88, 0.30 },
  { 1.00, 1.00, 1.00, 1.00 },
}
local function colormap(db)
  local t = clamp((db - DB_FLOOR) / (-DB_FLOOR), 0, 1)
  for i = 2, #STOPS do
    local a, b = STOPS[i - 1], STOPS[i]
    if t <= b[1] then
      local u = (t - a[1]) / (b[1] - a[1])
      return a[2] + (b[2] - a[2]) * u, a[3] + (b[3] - a[3]) * u, a[4] + (b[4] - a[4]) * u
    end
  end
  return 1, 1, 1
end

local function nice_step(raw)
  local mag = 10 ^ math.floor(math.log(raw, 10))
  for _, m in ipairs({ 1, 2, 5, 10 }) do
    if raw <= m * mag then return m * mag end
  end
  return 10 * mag
end

-- Clips a segment to the rectangle [0,w] x [0,h]; returns the clipped ends or nil if outside.
local function clip_segment(x1, y1, x2, y2, w, h)
  local dx, dy = x2 - x1, y2 - y1
  local u0, u1 = 0, 1
  local function edge(p, q)
    if p == 0 then return q >= 0 end
    local r = q / p
    if p < 0 then if r > u1 then return false elseif r > u0 then u0 = r end
    else if r < u0 then return false elseif r < u1 then u1 = r end end
    return true
  end
  if edge(-dx, x1) and edge(dx, w - x1) and edge(-dy, y1) and edge(dy, h - y1) then
    return x1 + u0 * dx, y1 + u0 * dy, x1 + u1 * dx, y1 + u1 * dy
  end
  return nil
end

-- -------------------------------------------------------------- data helpers
local function fit_view()
  if not data then return end
  local tmax = data.times[data.frames]
  if not tmax or tmax <= 0 then tmax = data.dur end
  view.t0, view.t1 = 0, math.max(tmax, 0.01)
  local fmin, fmax = math.huge, 0
  for p = 1, data.partials do
    local a, fr = data.amp[p], data.frq[p]
    for f = 1, data.frames do
      if a[f] > amp_thresh and fr[f] > 0 then
        if fr[f] < fmin then fmin = fr[f] end
        if fr[f] > fmax then fmax = fr[f] end
      end
    end
  end
  if fmin >= fmax then fmin, fmax = 20, 20000 end
  view.f0 = math.max(10, fmin / 1.4)
  view.f1 = math.min(40000, fmax * 1.4)
  dirty = true
end

local function load_file(path)
  local d, err = ats.load(path)
  if not d then
    load_error = path .. "\n" .. tostring(err)
    return false
  end
  data, fname, load_error = d, path, nil
  clear_selection()
  undo_stack, redo_stack, modified, edited_cells = {}, {}, false, {}
  saved_depth, current_file = 0, path
  amp_thresh = d.ampmax * 10 ^ (DB_FLOOR / 20)
  reaper.SetExtState(EXT_SECTION, EXT_LAST, path, true)
  fit_view()
  return true
end

local function open_dialog()
  local start = reaper.GetExtState(EXT_SECTION, EXT_LAST)
  local ok, path = reaper.GetUserFileNameForRead(start, "Open an ATS analysis file", "ats")
  if ok and path and path ~= "" then load_file(path) end
end

-- Nearest frame index for a time (frames are evenly spaced, but search anyway).
local function frame_at(t)
  local times, lo, hi = data.times, 1, data.frames
  while hi - lo > 1 do
    local mid = (lo + hi) // 2
    if times[mid] <= t then lo = mid else hi = mid end
  end
  if math.abs(times[hi] - t) < math.abs(times[lo] - t) then return hi end
  return lo
end


-- ---------------------------------------------------------------- selection
function clear_selection()
  sel, sel_info = {}, nil
end

-- Selects every point (partial p at frame f) whose time and frequency lie inside the box.
-- add = true keeps the existing selection and adds to it.
local function select_box(ta, tb, fa, fb, add)
  if not data then return end
  if ta > tb then ta, tb = tb, ta end
  if fa > fb then fa, fb = fb, fa end
  if not add then sel = {} end
  for p = 1, data.partials do
    local amp, frq = data.amp[p], data.frq[p]
    for f = 1, data.frames do
      local t = data.times[f]
      if t >= ta and t <= tb and amp[f] > amp_thresh and frq[f] >= fa and frq[f] <= fb then
        sel[p] = sel[p] or {}
        sel[p][f] = true
      end
    end
  end
  update_sel_info()
end

-- Recomputes the selection summary (point count, time and frequency range) from sel.
function update_sel_info()
  local points, partials = 0, 0
  local i0, i1, g0, g1 = math.huge, -math.huge, math.huge, -math.huge
  for p, frames in pairs(sel) do
    local n = 0
    for f in pairs(frames) do
      n = n + 1
      local t, fr = data.times[f], data.frq[p][f]
      if t < i0 then i0 = t end
      if t > i1 then i1 = t end
      if fr < g0 then g0 = fr end
      if fr > g1 then g1 = fr end
    end
    if n > 0 then points = points + n; partials = partials + 1 end
  end
  sel_info = (points > 0) and { points = points, partials = partials, t0 = i0, t1 = i1, f0 = g0, f1 = g1 } or nil
  if not sel_info then sel = {} end
end

-- ------------------------------------------------------------------ editing
local function set_status(msg)
  status_msg, status_until = msg, reaper.time_precise() + 4
end

local function apply_changes(changes, forward)
  for _, c in ipairs(changes) do
    data.amp[c.p][c.f] = forward and c.na or c.oa
    data.frq[c.p][c.f] = forward and c.nf or c.of
    edited_cells[c.p] = edited_cells[c.p] or {}
    edited_cells[c.p][c.f] = true
  end
  dirty = true
end

local function do_edit(name, changes, rows_before, rows_after)
  if #changes == 0 then return end
  if rows_after and rows_after > data.partials then edit.add_rows(data, rows_after - data.partials) end
  apply_changes(changes, true)
  undo_stack[#undo_stack + 1] = { name = name, changes = changes, rows_before = rows_before, rows_after = rows_after }
  redo_stack = {}
  modified = (#undo_stack ~= saved_depth)
  set_status(string.format("%s: %d points", name, #changes))
end

local function undo()
  local e = table.remove(undo_stack)
  if not e then set_status("nothing to undo"); return end
  apply_changes(e.changes, false)
  if e.rows_before and data.partials > e.rows_before then edit.truncate_rows(data, e.rows_before) end
  redo_stack[#redo_stack + 1] = e
  clear_selection()
  modified = (#undo_stack ~= saved_depth)
  set_status("undo " .. e.name)
end

local function redo()
  local e = table.remove(redo_stack)
  if not e then set_status("nothing to redo"); return end
  if e.rows_after and e.rows_after > data.partials then edit.add_rows(data, e.rows_after - data.partials) end
  apply_changes(e.changes, true)
  undo_stack[#undo_stack + 1] = e
  clear_selection()
  modified = (#undo_stack ~= saved_depth)
  set_status("redo " .. e.name)
end

-- Delete: the selected points become silent (amplitude 0 = partial not sounding, as in ATS).
local function delete_selection()
  if not sel_info then return end
  local changes = {}
  for p, frames in pairs(sel) do
    for f in pairs(frames) do
      if data.amp[p][f] > 0 then
        changes[#changes + 1] = { p = p, f = f, oa = data.amp[p][f], na = 0, of = data.frq[p][f], nf = data.frq[p][f] }
      end
    end
  end
  do_edit("delete", changes)
  clear_selection()
end

-- Transpose the selected points by `semitones` (frequencies only; phases are not touched).
local function transpose_selection(semitones)
  if not sel_info then return end
  local ratio = 2 ^ (semitones / 12)
  local ny = data.sr / 2 - 1
  local changes = {}
  for p, frames in pairs(sel) do
    for f in pairs(frames) do
      local fr = data.frq[p][f]
      changes[#changes + 1] = { p = p, f = f, oa = data.amp[p][f], na = data.amp[p][f],
                                of = fr, nf = clamp(fr * ratio, 1, ny) }
    end
  end
  do_edit(string.format("transpose %+.2f st", semitones), changes)
  update_sel_info()
end

-- Move the selected points by df frames in time and by `ratio` in frequency (see lib/ats_edit.lua
-- for how colliding pieces get other rows). The selection follows the moved points.
local function move_selection(df, ratio)
  if not sel_info then return end
  local plan = edit.plan_move(data, sel, df, ratio)
  if not plan then set_status("nothing to move"); return end
  local label = string.format("move %+d frames, %+.2f st", plan.df, 12 * math.log(ratio, 2))
  do_edit(label, plan.changes, plan.rows_before, plan.rows_after)
  sel = plan.sel
  update_sel_info()
  if plan.rows_after > plan.rows_before then
    set_status(string.format("%s (+%d new partial rows)", label, plan.rows_after - plan.rows_before))
  end
end

-- ----------------------------------------------------------------- audition
-- Renders the current (edited) data (sines and noise bands, in Lua) to a temporary WAV and plays it through
-- REAPER's source preview, so the project is not touched. What you see is what you hear: the P / N switches decide whether sines / noise are included.
-- Crash safety (a REAPER crash on the second audition, 9 Nov 2026): the preview sources are never
-- destroyed from here (they were destroyed right after stopping, which is the one thing the second audition
-- did that the first did not); every render gets its own WAV name, so a file REAPER may still hold open is
-- never rewritten; old WAVs are only deleted several auditions later; and the stop call is only made while a
-- preview can still be playing.
local preview_until = 0        -- time_precise() at which the running preview ends
local audition_count = 0
local wav_history = {}

local function stop_audition()
  if reaper.Xen_StopSourcePreview and reaper.time_precise() < preview_until + 0.3 then
    reaper.Xen_StopSourcePreview(-1)
  end
  preview_until = 0
end

-- Renders the current data to `wav` (pure Lua, lib/ats_synth.lua; no other program needed). Returns the
-- duration and a label ("sines + noise", ...), or nil plus a message.
local function render_wav(wav)
  local use_sines = show_partials
  local use_noise = show_noise and data.has_noise
  local samples, sr = synth.render(data, { sines = use_sines, noise = use_noise })
  if not samples then return nil, sr end                      -- sr is the message when samples is nil
  local ok, err = synth.write_wav(wav, samples, sr)
  if not ok then return nil, err end
  return #samples / sr, (use_sines and use_noise) and "sines + noise" or (use_sines and "sines" or "noise")
end

local function audition()
  if not data then return end
  stop_audition()
  local dir = (os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "")
  audition_count = audition_count + 1
  local wav = string.format("%s/reaats_audition_%d.wav", dir, audition_count)
  local dur, mode = render_wav(wav)
  if not dur then set_status("audition failed: " .. tostring(mode)); return end
  local src = reaper.PCM_Source_CreateFromFile(wav)
  if src and reaper.Xen_StartSourcePreview then
    reaper.Xen_StartSourcePreview(src, 1.0, false)
    preview_until = reaper.time_precise() + dur
    wav_history[#wav_history + 1] = wav
    if #wav_history > 4 then os.remove(table.remove(wav_history, 1)) end
    set_status(string.format("auditioning %.1f s (%s)  Space stops", dur, mode))
  else
    set_status("audition rendered " .. wav .. ", but REAPER could not play it (needs the SWS extension)")
  end
end

-- Writes the current data to `path` as a Csound-compatible .ats file, WITH phase (the phases of edited runs are
-- rebuilt from their frequencies first). Returns the path, or nil after a status message.
local function write_ats(path, verb)
  ats.update_phases(data, edited_cells)
  edited_cells = {}
  local ok, err = ats.save(path, data, { phase = true })
  if ok then
    modified = false
    saved_depth, current_file = #undo_stack, path
    set_status((verb or "saved") .. " " .. (path:match("([^/\\]+)$") or path) .. " (with phase)")
    return path
  end
  set_status("save failed: " .. tostring(err))
end

-- Ctrl+S: saves next to the original as <name>_edit.ats (never overwrites; numbers further copies).
local function save_file()
  if not data or not fname then return end
  local base, ext = fname:match("^(.*)(%.[^./\\]+)$")
  base = (base or fname):gsub("_edit%d*$", "")
  ext = ext or ".ats"
  local path = base .. "_edit" .. ext
  local n = 2
  while reaper.file_exists(path) do
    path = base .. "_edit" .. n .. ext
    n = n + 1
  end
  return write_ats(path)
end

-- EXPORT .ats button / Ctrl+Shift+S: the same, but you choose the folder and the name (the JS_ReaScriptAPI file dialog if that
-- extension is installed, otherwise a box to type the path). An existing file is only replaced after a yes.
local function save_as()
  if not data or not fname then return end
  local here = current_file or fname
  local dir = reaper.GetExtState(EXT_SECTION, "save_dir")
  if dir == "" then dir = here:match("^(.*)[/\\]") or "" end
  local stem = (here:match("([^/\\]+)$") or "sound.ats"):gsub("%.[^.]*$", ""):gsub("_edit%d*$", "")
  local suggested = stem .. "_edit.ats"
  local path
  if reaper.JS_Dialog_BrowseForSaveFile then
    local rv, chosen = reaper.JS_Dialog_BrowseForSaveFile("Export .ats file (Csound compatible)", dir, suggested,
      "ATS files (*.ats)\0*.ats\0All files (*.*)\0*.*\0\0")
    if rv ~= 1 or not chosen or chosen == "" then return end
    path = chosen
  else
    local ok, text = reaper.GetUserInputs("Export .ats file", 1, "full path,extrawidth=420", dir .. "/" .. suggested)
    if not ok or text == "" then return end
    path = text
  end
  if not path:lower():match("%.ats$") then path = path .. ".ats" end
  if reaper.file_exists(path) and reaper.MB("Replace this file?\n\n" .. path, "ReaATS: export .ats file", 4) ~= 6 then
    set_status("not exported (the file was kept)")
    return
  end
  if write_ats(path, "exported") then
    reaper.SetExtState(EXT_SECTION, "save_dir", path:match("^(.*)[/\\]") or "", true)
  end
end

-- ------------------------------------------------------------------ print to track
-- Renders the current data (unsaved edits are saved first as <name>_edit.ats) to a permanent WAV next to the
-- .ats file and puts it on the selected track (or a new "ReaATS" track) at the edit cursor. This is the tool's
-- "generate" moment for the ReaSnap Integration Contract (piece 3): the settings that made the item are written
-- to the project under the item's GUID, so ReaSnap (or anything else) can bring them back.
local function build_state(ats_path)
  return {
    file = ats_path,
    name = (ats_path:match("([^/\\]+)$") or ats_path),
    view = { t0 = view.t0, t1 = view.t1, f0 = view.f0, f1 = view.f1 },
    partials = show_partials,
    noise = show_noise,
  }
end

local function print_to_track()
  if not data then return end
  local ats_path = current_file or fname
  if modified then
    ats_path = save_file()
    if not ats_path then return end
  end
  local stem = ats_path:gsub("%.[^./\\]+$", "")
  local n, wav = 1, nil
  repeat wav = string.format("%s_print%d.wav", stem, n); n = n + 1 until not reaper.file_exists(wav)
  local dur, mode = render_wav(wav)
  if not dur then set_status("print failed: " .. tostring(mode)); return end

  reaper.Undo_BeginBlock()
  local track = reaper.GetSelectedTrack(0, 0)
  if not track then
    reaper.InsertTrackAtIndex(reaper.CountTracks(0), true)
    track = reaper.GetTrack(0, reaper.CountTracks(0) - 1)
    reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "ReaATS", true)
  end
  reaper.SetOnlyTrackSelected(track)
  reaper.InsertMedia(wav, 0)
  local item
  for i = 0, reaper.CountTrackMediaItems(track) - 1 do
    local it = reaper.GetTrackMediaItem(track, i)
    local take = reaper.GetActiveTake(it)
    local src = take and reaper.GetMediaItemTake_Source(take)
    if src and reaper.GetMediaSourceFileName(src, "") == wav then item = it end
  end
  if item then
    local ok_g, guid = reaper.GetSetMediaItemInfo_String(item, "GUID", "", false)
    if ok_g and guid ~= "" then
      local ok_enc, encoded = pcall(Serial.serialize, build_state(ats_path))
      if ok_enc then reaper.SetProjExtState(0, "ReaATS_ItemSettings", guid, encoded) end
    end
    local take = reaper.GetActiveTake(item)
    if take then reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "ReaATS " .. (wav:match("([^/\\]+)$") or wav), true) end
  end
  reaper.Undo_EndBlock("ReaATS print", -1)
  reaper.UpdateArrange()
  set_status(item and string.format("printed %.1f s (%s) to the track", dur, mode)
                  or "printed, but the new item was not found on the track")
end

-- ------------------------------------------------------------------- drawing
local function draw_grid(pw, ph)
  gfx.set(1, 1, 1, 0.07)
  local fs = { 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000 }
  for _, f in ipairs(fs) do
    if f > view.f0 and f < view.f1 then
      local y = fy(f, ph)
      gfx.line(0, y, pw, y)
    end
  end
  local step = nice_step((view.t1 - view.t0) / 8)
  local t = math.ceil(view.t0 / step) * step
  while t < view.t1 do
    local x = tx(t, pw)
    gfx.line(x, 0, x, ph)
    t = t + step
  end
end

local function draw_noise(pw, ph)
  if not (data.has_noise and data.noise_max > 0) then return end
  local edges, times = ats.CRITICAL_BAND_EDGES, data.times
  for b = 1, ats.NUM_NOISE_BANDS do
    local lo, hi = math.max(edges[b], 1), edges[b + 1]
    if hi > view.f0 and lo < view.f1 then
      local y_top = fy(math.min(hi, view.f1), ph)
      local y_bot = fy(math.max(lo, view.f0), ph)
      local nb = data.noise[b]
      local y0, y1 = math.floor(y_top), math.floor(y_bot)
      for f = 1, data.frames do
        local e0 = (f == 1) and tx(times[1], pw) or tx((times[f - 1] + times[f]) * 0.5, pw)
        local e1 = (f == data.frames) and tx(times[f], pw) or tx((times[f] + times[f + 1]) * 0.5, pw)
        local x0, x1 = math.floor(e0), math.floor(e1)   -- whole pixels, so neighbours do not overlap
        if x1 > 0 and x0 < pw and nb[f] > 0 and x1 > x0 then
          local db = 10 * math.log(nb[f] / data.noise_max, 10)
          local a = clamp((db + NOISE_RANGE_DB) / NOISE_RANGE_DB, 0, 1) * 0.40
          if a > 0.01 then
            gfx.set(0.85, 0.50, 0.15, a)
            gfx.rect(x0, y0, x1 - x0, y1 - y0, 1)
          end
        end
      end
    end
  end
end

local function draw_partials(pw, ph)
  local times, nf = data.times, data.frames
  local xs = {}
  for f = 1, nf do xs[f] = tx(times[f], pw) end
  for p = 1, data.partials do
    local amp, frq = data.amp[p], data.frq[p]
    for f = 1, nf - 1 do
      local a1, a2 = amp[f], amp[f + 1]
      if a1 > amp_thresh and a2 > amp_thresh then
        local x1, x2 = xs[f], xs[f + 1]
        if x2 >= 0 and x1 <= pw then
          local f1, f2 = frq[f], frq[f + 1]
          if f1 > 0 and f2 > 0 then
            local cx1, cy1, cx2, cy2 = clip_segment(x1, fy(f1, ph), x2, fy(f2, ph), pw, ph)
            if cx1 then
              local db = 20 * math.log(math.min(a1, a2) / data.ampmax, 10)
              gfx.set(colormap(db))
              gfx.a = 1
              gfx.line(cx1, cy1, cx2, cy2, 1)
              if db > -30 then gfx.line(cx1, cy1 + 1, cx2, cy2 + 1, 1) end
            end
          end
        end
      end
    end
  end
end

local function render_cache(pw, ph)
  gfx.setimgdim(1, pw, ph)
  gfx.dest = 1
  gfx.set(0.055, 0.065, 0.085, 1)
  gfx.rect(0, 0, pw, ph, 1)
  if data then
    draw_grid(pw, ph)
    if show_noise then draw_noise(pw, ph) end
    if show_partials then draw_partials(pw, ph) end
  end
  gfx.dest = -1
  dirty = false
end

local function text_at(x, y, s, r, g, b, a)
  gfx.set(r or 0.85, g or 0.87, b or 0.9, a or 1)
  gfx.x, gfx.y = x, y
  gfx.drawstr(s)
end

local function fmt_freq(f)
  if f >= 1000 then return string.format("%.4g kHz", f / 1000) end
  return string.format("%.4g Hz", f)
end

local draw_note_scale   -- defined below, called from draw_axes

local function draw_axes(px, py, pw, ph)
  -- margin backgrounds paint over anything drawn outside the plot
  gfx.set(0.09, 0.10, 0.12, 1)
  gfx.rect(0, 0, gfx.w, py, 1)
  gfx.rect(0, py + ph, gfx.w, gfx.h - py - ph, 1)
  gfx.rect(0, py, px, ph, 1)
  gfx.rect(px + pw, py, gfx.w - px - pw, ph, 1)

  gfx.setfont(1, "Arial", 13)
  for _, f in ipairs({ 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000 }) do
    if f > view.f0 and f < view.f1 then
      local y = py + fy(f, ph)
      local label = (f >= 1000) and (tostring(f // 1000) .. "k") or tostring(f)
      text_at(px - 8 - gfx.measurestr(label), y - 7, label, 0.65, 0.68, 0.72)
      gfx.set(0.65, 0.68, 0.72, 0.8)
      gfx.line(px - 4, y, px, y)
    end
  end
  local step = nice_step((view.t1 - view.t0) / 8)
  local t = math.ceil(view.t0 / step) * step
  while t < view.t1 do
    local x = px + tx(t, pw)
    local label = string.format("%g s", t)
    text_at(x - gfx.measurestr(label) / 2, py + ph + 8, label, 0.65, 0.68, 0.72)
    gfx.set(0.65, 0.68, 0.72, 0.8)
    gfx.line(x, py + ph, x, py + ph + 4)
    t = t + step
  end
  gfx.set(0.4, 0.43, 0.48, 1)
  gfx.rect(px, py, pw, ph, 0)
  if data then draw_note_scale(px, py, pw, ph) end
end

-- Draws the selected points at an offset (ox, oy) in pixels, in the given colour.
local function draw_sel_points(px, py, pw, ph, ox, oy, r, g, bl, a)
  local times = data.times
  gfx.set(r, g, bl, a)
  for p, frames in pairs(sel) do
    local frq = data.frq[p]
    for f in pairs(frames) do
      local x1, y1 = tx(times[f], pw) + ox, fy(frq[f], ph) + oy
      if frames[f + 1] then
        local cx1, cy1, cx2, cy2 = clip_segment(x1, y1, tx(times[f + 1], pw) + ox, fy(frq[f + 1], ph) + oy, pw, ph)
        if cx1 then
          gfx.line(px + cx1, py + cy1, px + cx2, py + cy2, 1)
          gfx.line(px + cx1, py + cy1 + 1, px + cx2, py + cy2 + 1, 1)
        end
      elseif not frames[f - 1] and x1 >= 0 and x1 <= pw and y1 >= 0 and y1 <= ph then
        gfx.rect(px + x1 - 1, py + y1 - 1, 3, 3, 1)   -- isolated point
      end
    end
  end
end

-- How far the current move-drag goes: whole frames in time, a continuous factor in frequency.
local function mover_delta(pw, ph)
  local dx, dy = mover.x - mover.x0, mover.y - mover.y0
  if mover.lock == "x" then dy = 0 elseif mover.lock == "y" then dx = 0 end
  local span = view.t1 - view.t0
  local frame_dt = (data.times[data.frames] - data.times[1]) / math.max(data.frames - 1, 1)
  local df = math.floor(dx / pw * span / frame_dt + 0.5)
  local ratio = math.exp(-dy / ph * (LOG(view.f1) - LOG(view.f0)))
  return df, ratio, df * frame_dt / span * pw, dy, frame_dt
end

-- Selected points (bright pink), the move ghost and the rubber-band box, drawn on the screen each frame.
local function draw_selection(px, py, pw, ph)
  if not data then return end
  if sel_info then
    draw_sel_points(px, py, pw, ph, 0, 0, 1, 0.35, 0.75, mover and 0.35 or 1)
    if mover and mover.active then
      local _, _, ox, oy = mover_delta(pw, ph)
      draw_sel_points(px, py, pw, ph, ox, oy, 1, 0.9, 0.95, 0.95)
    end
  end
  if box then
    local x0, x1 = math.min(box.x0, box.x1), math.max(box.x0, box.x1)
    local y0, y1 = math.min(box.y0, box.y1), math.max(box.y0, box.y1)
    gfx.set(1, 1, 1, 0.10)
    gfx.rect(x0, y0, x1 - x0, y1 - y0, 1)
    gfx.set(1, 1, 1, 0.8)
    gfx.rect(x0, y0, x1 - x0, y1 - y0, 0)
  end
end

-- True when the mouse is within a few pixels of a selected point.
local function hit_selected(px, py, pw, ph, mx, my)
  for p, frames in pairs(sel) do
    local frq = data.frq[p]
    for f in pairs(frames) do
      local x = px + tx(data.times[f], pw)
      if math.abs(x - mx) <= 7 then
        local y = py + fy(frq[f], ph)
        if math.abs(y - my) <= 7 then return true end
      end
    end
  end
  return false
end

-- Noise-layer checkbox, top right of the header.
local function checkbox_rect()
  return math.floor(gfx.w) - 128, 8, 118, 16
end

local function audition_rect()
  local x, y, w, h = checkbox_rect()
  return x - 96, y - 2, 86, 20
end

local function print_rect()
  local x, y, w, h = audition_rect()
  return x - 72, y, 62, h
end

local function export_rect()
  local x, y, w, h = print_rect()
  return x - 112, y, 102, h
end

local function draw_export_button()
  local x, y, w, h = export_rect()
  gfx.set(0.36, 0.27, 0.16, 1)
  gfx.rect(x, y, w, h, 1)
  gfx.set(0.90, 0.72, 0.45, 1)
  gfx.rect(x, y, w, h, 0)
  gfx.setfont(1, "Arial", 14)
  local label = "EXPORT .ats"
  gfx.set(1, 0.96, 0.90, 1)
  gfx.x = x + (w - gfx.measurestr(label)) / 2
  gfx.y = y + 2
  gfx.drawstr(label)
end

local function analyse_rect()
  local x, y, w, h = export_rect()
  return x - 98, y, 88, h
end

local function draw_analyse_button()
  local x, y, w, h = analyse_rect()
  gfx.set(0.20, 0.36, 0.33, 1)
  gfx.rect(x, y, w, h, 1)
  gfx.set(0.50, 0.85, 0.78, 1)
  gfx.rect(x, y, w, h, 0)
  gfx.setfont(1, "Arial", 14)
  local label = "ANALYSE"
  gfx.set(0.93, 1, 0.98, 1)
  gfx.x = x + (w - gfx.measurestr(label)) / 2
  gfx.y = y + 2
  gfx.drawstr(label)
end

local function draw_print_button()
  local x, y, w, h = print_rect()
  gfx.set(0.22, 0.30, 0.46, 1)
  gfx.rect(x, y, w, h, 1)
  gfx.set(0.55, 0.68, 0.92, 1)
  gfx.rect(x, y, w, h, 0)
  gfx.setfont(1, "Arial", 14)
  local label = "PRINT"
  gfx.set(0.93, 0.96, 1, 1)
  gfx.x = x + (w - gfx.measurestr(label)) / 2
  gfx.y = y + 2
  gfx.drawstr(label)
end

local function draw_audition_button()
  local x, y, w, h = audition_rect()
  gfx.set(0.18, 0.42, 0.30, 1)
  gfx.rect(x, y, w, h, 1)
  gfx.set(0.45, 0.80, 0.60, 1)
  gfx.rect(x, y, w, h, 0)
  gfx.setfont(1, "Arial", 14)
  local label = "AUDITION"
  gfx.set(0.92, 1, 0.95, 1)
  gfx.x = x + (w - gfx.measurestr(label)) / 2
  gfx.y = y + 2
  gfx.drawstr(label)
end

local function draw_checkbox()
  local x, y, w, h = checkbox_rect()
  gfx.setfont(1, "Arial", 14)
  gfx.set(0.4, 0.43, 0.48, 1)
  gfx.rect(x, y + 1, 14, 14, 0)
  if show_noise then
    gfx.set(0.85, 0.50, 0.15, 1)
    gfx.rect(x + 3, y + 4, 8, 8, 1)
  end
  text_at(x + 22, y, "Noise layer", 0.85, 0.87, 0.9)
end

-- Note-name scale on the right edge (counterpart of the Hz labels on the left).
-- Only C's when zoomed out, natural notes when closer, every semitone when zoomed in far.
local NATURAL = { [0] = true, [2] = true, [4] = true, [5] = true, [7] = true, [9] = true, [11] = true }
function draw_note_scale(px, py, pw, ph)
  local octaves = LOG(view.f1 / view.f0) / LOG(2)
  local step_set = (octaves > 3.5) and "c" or (octaves > 1.2 and "natural" or "all")
  local nlo = math.floor(69 + 12 * LOG(view.f0 / 440) / LOG(2)) - 1
  local nhi = math.ceil(69 + 12 * LOG(view.f1 / 440) / LOG(2)) + 1
  gfx.setfont(1, "Arial", 13)
  for n = nlo, nhi do
    local pc = n % 12
    if step_set == "all" or (step_set == "natural" and NATURAL[pc]) or (step_set == "c" and pc == 0) then
      local f = 440 * 2 ^ ((n - 69) / 12)
      if f > view.f0 and f < view.f1 then
        local y = py + fy(f, ph)
        local label = ats.note_name(f)
        gfx.set(0.65, 0.68, 0.72, 0.8)
        gfx.line(px + pw, y, px + pw + 4, y)
        text_at(px + pw + 8, y - 7, label, 0.65, 0.68, 0.72)
      end
    end
  end
end

local function draw_header(px, py, pw, ph, plain)
  gfx.setfont(1, "Arial", 14)
  if not data then
    text_at(px, 10, load_error and ("Could not read:\n" .. load_error) or "Press O to open a .ats file, or click ANALYSE to make one from a sound", 0.95, 0.85, 0.5)
    if not plain then draw_analyse_button() end
    if status_msg and reaper.time_precise() < status_until then text_at(px, 48, status_msg, 0.6, 0.95, 0.6) end
    return
  end
  local name = fname:match("([^/\\]+)$") or fname
  local hop_ms = data.frame_size / data.sr * 1000
  local info = string.format("%s%s   |   %d partials   %d frames   %.2f s   %d Hz   hop %.1f ms   type %d%s%s",
    name, modified and " *" or "", data.partials, data.frames, data.dur, data.sr, hop_ms, data.type,
    data.has_phase and " (phase)" or "", data.has_noise and " (noise)" or "")
  text_at(px, 8, info)
  if not plain then
    draw_checkbox()
    draw_audition_button()
    draw_print_button()
    draw_export_button()
    draw_analyse_button()
  end
  if status_msg and reaper.time_precise() < status_until then
    text_at(px, 48, status_msg, 0.6, 0.95, 0.6)                       -- third header row: what the last action did
  end
  if plain then return end
  if sel_info then
    local msg = string.format("selected: %d points in %d partials   %.3f-%.3f s   %s - %s",
      sel_info.points, sel_info.partials, sel_info.t0, sel_info.t1, fmt_freq(sel_info.f0), fmt_freq(sel_info.f1))
    text_at(math.max(px + 560, gfx.w - gfx.measurestr(msg) - 14), 28, msg, 1, 0.5, 0.82)
  end
  -- hover readout
  local mx, my = gfx.mouse_x, gfx.mouse_y
  if mx >= px and mx < px + pw and my >= py and my < py + ph then
    local t = view.t0 + (mx - px) / pw * (view.t1 - view.t0)
    local f = view.f0 * (view.f1 / view.f0) ^ ((py + ph - my) / ph)
    local line = string.format("t = %.3f s    f = %s  (%s)", t, fmt_freq(f), ats.note_name(f))
    local fi = frame_at(t)
    local best, bestd = nil, 9
    for p = 1, data.partials do
      if data.amp[p][fi] > amp_thresh and data.frq[p][fi] > 0 then
        local d = math.abs(py + fy(data.frq[p][fi], ph) - my)
        if d < bestd then best, bestd = p, d end
      end
    end
    text_at(px, 28, line, 0.7, 0.75, 0.8)
    if best then
      local db = 20 * math.log(data.amp[best][fi] / data.ampmax, 10)
      text_at(px + 330, 28, string.format("partial %d: %s (%s)   %.1f dB   frame %d",
        best, fmt_freq(data.frq[best][fi]), ats.note_name(data.frq[best][fi]), db, fi), 1, 0.95, 0.6)
      -- highlight the whole partial
      local times, amp, frq = data.times, data.amp[best], data.frq[best]
      gfx.set(1, 1, 1, 0.95)
      for f = 1, data.frames - 1 do
        if amp[f] > amp_thresh and amp[f + 1] > amp_thresh and frq[f] > 0 and frq[f + 1] > 0 then
          local cx1, cy1, cx2, cy2 = clip_segment(tx(times[f], pw), fy(frq[f], ph),
                                                  tx(times[f + 1], pw), fy(frq[f + 1], ph), pw, ph)
          if cx1 then gfx.line(px + cx1, py + cy1, px + cx2, py + cy2, 1) end
        end
      end
    end
  end
  gfx.setfont(1, "Arial", 12)
  text_at(px, gfx.h - 34, "drag select (Shift adds)   drag a selected point = move (Shift locks axis)   right-drag pan   wheel zoom time   Ctrl+wheel zoom frequency   Shift+wheel scroll   O open   F fit   P partials   N noise",
    0.5, 0.53, 0.58)
  text_at(px, gfx.h - 18, "Del delete   Up/Down transpose   Left/Right move   Ctrl+Z/Y undo/redo   Ctrl+S save   Ctrl+Shift+S export   A audition   Ctrl+P print   Esc clear/close",
    0.5, 0.53, 0.58)
end

-- --------------------------------------------------------------- interaction
local function zoom_time(factor, pivot_frac)
  local span = view.t1 - view.t0
  local new = clamp(span * factor, 0.005, 4 * math.max(data.dur, 0.1))
  local pivot = view.t0 + span * pivot_frac
  view.t0 = pivot - new * pivot_frac
  view.t1 = view.t0 + new
  dirty = true
end

local function zoom_freq(factor, pivot_frac_from_top)
  local l0, l1 = LOG(view.f0), LOG(view.f1)
  local span = l1 - l0
  local new = clamp(span * factor, LOG(1.05), LOG(8000))
  local pivot = l1 - span * pivot_frac_from_top
  local n1 = pivot + new * pivot_frac_from_top
  view.f1 = math.min(math.exp(n1), 40000)
  view.f0 = math.max(math.exp(n1 - new), 5)
  dirty = true
end

local function handle_input(px, py, pw, ph)
  local mx, my, cap = gfx.mouse_x, gfx.mouse_y, gfx.mouse_cap
  local inside = mx >= px and mx < px + pw and my >= py and my < py + ph

  if gfx.mouse_wheel ~= 0 and data then
    local notches = gfx.mouse_wheel / 120
    gfx.mouse_wheel = 0
    local factor = 0.8 ^ notches
    if cap & 8 ~= 0 then                       -- Shift: scroll time
      local span = view.t1 - view.t0
      view.t0 = view.t0 - notches * span * 0.1
      view.t1 = view.t0 + span
      dirty = true
    elseif cap & 4 ~= 0 then                   -- Ctrl: zoom frequency
      zoom_freq(factor, inside and (my - py) / ph or 0.5)
    else
      zoom_time(factor, inside and (mx - px) / pw or 0.5)
    end
  end

  -- Right or middle button drag = pan.
  if data and (cap & (2 + 64)) ~= 0 then
    if drag then
      local dx, dy = mx - drag.x, my - drag.y
      if dx ~= 0 or dy ~= 0 then
        local span = view.t1 - view.t0
        view.t0 = view.t0 - dx / pw * span
        view.t1 = view.t0 + span
        local l0, l1 = LOG(view.f0), LOG(view.f1)
        local shift = dy / ph * (l1 - l0)
        view.f0 = clamp(math.exp(l0 + shift), 5, 40000)
        view.f1 = clamp(math.exp(l1 + shift), 6, 40000)
        dirty = true
      end
      drag.x, drag.y = mx, my
    elseif inside then
      drag = { x = mx, y = my }
    end
  else
    drag = nil
  end

  -- Left button: checkbox click; on a selected point it drags the selection, elsewhere a box selects.
  local down = (cap & 1) ~= 0
  if down and not prev_down then
    local cx, cy, cw, chh = checkbox_rect()
    local ax, ay, aw, ah = audition_rect()
    if mx >= cx and mx < cx + cw and my >= cy and my < cy + chh then
      show_noise = not show_noise
      dirty = true
    elseif mx >= ax and mx < ax + aw and my >= ay and my < ay + ah then
      audition()
    elseif (function() local rx, ry, rw, rh = print_rect(); return mx >= rx and mx < rx + rw and my >= ry and my < ry + rh end)() then
      print_to_track()
    elseif (function() local ex, ey, ew, eh = export_rect(); return mx >= ex and mx < ex + ew and my >= ey and my < ey + eh end)() then
      save_as()
    elseif (function() local ax2, ay2, aw2, ah2 = analyse_rect(); return mx >= ax2 and mx < ax2 + aw2 and my >= ay2 and my < ay2 + ah2 end)() then
      showing_analysis = true
    elseif data and inside then
      if sel_info and hit_selected(px, py, pw, ph, mx, my) then
        mover = { x0 = mx, y0 = my, x = mx, y = my, shift = (cap & 8) ~= 0, active = false }
      else
        box = { x0 = mx, y0 = my, x1 = mx, y1 = my, add = (cap & 8) ~= 0 }
      end
    end
  elseif down and mover then
    mover.x, mover.y = mx, my
    if not mover.active and (math.abs(mx - mover.x0) > 3 or math.abs(my - mover.y0) > 3) then
      mover.active = true
      if mover.shift then
        mover.lock = (math.abs(mx - mover.x0) >= math.abs(my - mover.y0)) and "x" or "y"
      end
    end
  elseif down and box then
    box.x1 = clamp(mx, px, px + pw)
    box.y1 = clamp(my, py, py + ph)
  elseif (not down) and prev_down and mover then
    local m = mover
    if m.active then
      local df, ratio = mover_delta(pw, ph)
      mover = nil
      move_selection(df, ratio)
    end
    mover = nil
  elseif (not down) and prev_down and box then
    local b = box
    box = nil
    if math.abs(b.x1 - b.x0) < 4 and math.abs(b.y1 - b.y0) < 4 then
      if not b.add then clear_selection() end            -- a plain click on empty space clears
    else
      local function t_of(x) return view.t0 + (x - px) / pw * (view.t1 - view.t0) end
      local function f_of(y) return view.f0 * (view.f1 / view.f0) ^ ((py + ph - y) / ph) end
      select_box(t_of(b.x0), t_of(b.x1), f_of(b.y0), f_of(b.y1), b.add)
    end
  end
  prev_down = down

  local ch = gfx.getchar()
  if ch < 0 then stop_audition(); return false end
  if ch == 27 then
    if sel_info then clear_selection() else stop_audition(); return false end
  end
  local ctrl, shift = (cap & 4) ~= 0, (cap & 8) ~= 0
  if ch == 6579564 then delete_selection()                      -- Delete
  elseif ch == 30064 or ch == 1685026670 then                   -- Up / Down arrow
    local step = ctrl and 12 or (shift and 0.1 or 1)
    transpose_selection(ch == 30064 and step or -step)
  elseif ch == 1818584692 or ch == 1919379572 then              -- Left / Right arrow: move in time
    local frames = ctrl and 10 or 1
    move_selection(ch == 1919379572 and frames or -frames, 1)
  elseif ch == 26 then if shift then redo() else undo() end     -- Ctrl+Z (Shift = redo)
  elseif ch == 25 then redo()                                   -- Ctrl+Y
  elseif ch == 19 then if shift then save_as() else save_file() end   -- Ctrl+S, Ctrl+Shift+S
  elseif ch == 1 then showing_analysis = true                   -- Ctrl+A: the Analysis page
  elseif ch == 16 then print_to_track()                          -- Ctrl+P
  elseif ch == 97 or ch == 65 then audition()                    -- A
  elseif ch == 32 then stop_audition(); set_status("audition stopped")
  elseif ch == 111 or ch == 79 then open_dialog()
  elseif ch == 114 or ch == 82 then if fname then load_file(fname) end
  elseif ch == 102 or ch == 70 or ch == 1752132965 then fit_view()
  elseif ch == 112 or ch == 80 then show_partials = not show_partials; dirty = true
  elseif ch == 110 or ch == 78 then show_noise = not show_noise; dirty = true end
  return true
end

-- ---------------------------------------------------------------------- main
-- ReaSnap "Close All" (piece 5): only for an instance ReaSnap launched (it knows its project then).
local function close_signal_received()
  if not reasnap_project_identity then return false end
  local now = reaper.time_precise()
  if now - closecheck_last < 0.25 then return false end
  closecheck_last = now
  local raw = reaper.GetExtState("ReaSculpt_Registry", "close_ReaATS_signal")
  if raw == "" then return false end
  local sig_project, sig_time = raw:match("^(.-)|([%d%.]+)$")
  sig_time = tonumber(sig_time)
  -- same project AND broadcast after this instance was born (a lingering signal must not kill a new window)
  return sig_project == reasnap_project_identity and sig_time ~= nil and sig_time > reasnap_launch_time
end

local function draw_analysis_frame()
  local px, py, pw, ph = plot_rect()
  gfx.set(0.09, 0.10, 0.12, 1)
  gfx.rect(0, 0, gfx.w, gfx.h, 1)
  draw_header(px, py, pw, ph, true)
  analysis:draw(math.floor(gfx.w), math.floor(gfx.h), MARGIN_T)
end

local function loop()
  if showing_analysis then
    local keep = true
    analysis:mouse(gfx.mouse_x, gfx.mouse_y, gfx.mouse_cap, gfx.mouse_wheel)
    gfx.mouse_wheel = 0
    local ch = gfx.getchar()
    if ch < 0 then keep = false
    elseif ch == 27 then showing_analysis = false; dirty = true end
    if keep and close_signal_received() then keep = false end
    if not keep then stop_audition() end
    if showing_analysis or not keep then
      draw_analysis_frame()
      gfx.update()
      if keep then reaper.defer(loop) end
      return
    end
    -- left the page (Esc or BACK): carry on with the picture in this same frame
  end
  local px, py, pw, ph = plot_rect()
  if math.floor(gfx.w) ~= last_w or math.floor(gfx.h) ~= last_h then
    last_w, last_h = math.floor(gfx.w), math.floor(gfx.h)
    dirty = true
  end
  local keep = handle_input(px, py, pw, ph)
  if keep and close_signal_received() then
    stop_audition()
    keep = false
  end
  if dirty then render_cache(pw, ph) end

  gfx.set(0.09, 0.10, 0.12, 1)
  gfx.rect(0, 0, gfx.w, gfx.h, 1)
  gfx.blit(1, 1, 0, 0, 0, pw, ph, px, py, pw, ph)
  draw_selection(px, py, pw, ph)
  draw_axes(px, py, pw, ph)
  draw_header(px, py, pw, ph)
  gfx.update()
  if keep then reaper.defer(loop) end
end

gfx.init(TITLE, 1100, 640)
analysis = Analysis.new({
  serial = Serial, wav_info = wav_info, script_dir = script_dir, ext_section = EXT_SECTION,
  on_open = function(path) return load_file(path) end,
  set_status = set_status,
  redraw = function() draw_analysis_frame(); gfx.update() end,
  back = function() showing_analysis = false; dirty = true end,
})
-- Piece 4: settings ReaSnap left for this instance (restoring a snapshot). Checked after everything the
-- apply touches exists (load_file, view, the switches). The snapshot names a file: if it has gone, say so.
local applied = false
do
  local pending = reaper.GetExtState("ReaSculpt_Registry", "pending_ReaATS_settings")
  if pending ~= "" then
    reaper.SetExtState("ReaSculpt_Registry", "pending_ReaATS_settings", "", false)   -- consume it
    local st = Serial.deserialize(pending)                                         -- nil + a console message on failure
    if type(st) == "table" and type(st.file) == "string" then
      if reaper.file_exists(st.file) and load_file(st.file) then
        local v = st.view
        if type(v) == "table" and type(v.t0) == "number" and type(v.t1) == "number" and v.t1 > v.t0
           and type(v.f0) == "number" and type(v.f1) == "number" and v.f0 > 0 and v.f1 > v.f0 then
          view.t0, view.t1, view.f0, view.f1 = v.t0, v.t1, v.f0, v.f1
        end
        show_partials = st.partials ~= false
        show_noise = st.noise ~= false
        dirty = true
        applied = true
      else
        set_status("snapshot file not found: " .. st.file)
      end
    end
  end
end
if not applied then
  local last = reaper.GetExtState(EXT_SECTION, EXT_LAST)
  if last ~= "" and reaper.file_exists(last) then
    load_file(last)
  else
    open_dialog()
  end
end
loop()
