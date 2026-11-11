--[[----------------------------------------------------------------------------
  ATS_Editor.lua  --  a SPEAR-like partial editor for Csound/ATS ".ats" files, in REAPER.

  Shows the sine partials as lines (time across, frequency up on a log axis,
  brighter = louder) and the 25 noise bands as a faint shaded layer behind them
  (checkbox top right). Select points of partials with a box, then delete or
  transpose them. Edits are saved to a NEW file next to the original.

  Run it from the action list (Actions > Show action list > ReaScript: Load...).

  Mouse:  left drag = select box (Shift adds, click on empty space clears)
          Ctrl+Shift+drag = lasso (adds to the selection); Ctrl+Shift+drag on an edge of the bend box = arch (Alt is not used: KDE moves the window with it)
          left drag ON a selected point = move the selection (Shift locks to one axis)
          right/middle drag = pan       wheel = zoom time
          Ctrl+wheel = zoom frequency   Shift+wheel = scroll time
          hover = time / frequency / note / nearest partial
  Keys:   Delete        silence the selected points
          Up / Down     transpose the selection (1 semitone; Shift 10 cents; Ctrl octave)
          Ctrl+Z / Ctrl+Y   undo / redo
          Left / Right  move the selection one frame in time (Ctrl: ten frames)
          click on the picture, or click/drag on the time ruler  set the playhead; AUDITION starts there (the line moves while it plays)
          Z             zoom to the selection (with some room round it)
          A             AUDITION of the selection only (the selected points alone) when there is a selection; AUDITION button / A without one: the whole sound
          A or AUDITION render the edited data (in Lua, no other program needed) and play it; Space stops
                        (partials / noise follow the P / N switches)
          ANALYSE       the Analysis page: make .ats files from a sound (python/reaats_analyse.py)
          Ctrl+P / PRINT render, from the playhead to the end, to a permanent WAV (unsaved edits are saved first) and put it on the selected
                        track (or a new ReaATS track) at the edit cursor; remembered for ReaSnap
          Tab / the channel buttons  switch the channel of a set (name_ch1.ats, name_ch2.ats ...; AUDITION and PRINT play all channels)
          Ctrl+S        save as <name>_edit.ats (with phase; never overwrites)
          EXPORT .ats / Ctrl+Shift+S  export an .ats file: choose the folder and name (Csound-compatible; asks before replacing a file)
          O open   R reload   F or Home fit view   P partials on/off   N noise on/off
          Esc           clear the selection
--------------------------------------------------------------------------------]]

local script_dir = ({ reaper.get_action_context() })[2]:match("^(.*)[/\\]") or "."
local ats = dofile(script_dir .. "/lib/ats_file.lua")
local edit = dofile(script_dir .. "/lib/ats_edit.lua")
local synth = dofile(script_dir .. "/lib/ats_synth.lua")
local wav_info = dofile(script_dir .. "/lib/wav_info.lua")
local Analysis = dofile(script_dir .. "/lib/analysis_page.lua")
local py_synth = dofile(script_dir .. "/lib/py_synth.lua")
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
-- The picture's margins and the channel row's height come from the layout (lib/layout.lua, made by tools/gen_layout.py from the ReaLayout file):
-- left, right, top, bottom of the picture; CHAN_ROW is the extra header height with several channels: LEDs above, buttons and sliders below.
local MARGIN_L, MARGIN_R, MARGIN_T, MARGIN_B, CHAN_ROW = table.unpack(dofile(script_dir .. "/lib/layout.lua").margins)
local ANALYSIS_TOP = 40             -- the Analysis/Suggested pages have no channel row of their own: just room for the one plain header line above them
local EXT_SECTION, EXT_LAST = "tjingboem_ATSViewer", "last_file"

-- --------------------------------------------------------------------- state
local data, fname, load_error
local chs = {}                 -- the channels of the loaded set, one bundle each (see capture_channel); one entry for a single file
local cur = 1                  -- the reference channel: its bundle is held in the globals data, sel, undo_stack ... (see capture_channel)
local view_mode = "stack"       -- with several channels on: "stack" (one lane per channel) or "overlay" (one lane, channel colours)
local edit_group = nil         -- while one edit touches several channels: the id that groups their undo entries
local group_counter = 0
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
local playhead = 0             -- seconds: where AUDITION starts (set by a click on the time ruler)
local pending = nil            -- a sound being prepared: { kind = "audition" or "print", job = synth.render_job, mode, ... }
local finish_print             -- defined with print_to_track below
local set_status               -- defined with the editing code below
local play = nil               -- while a sound plays: { start (s in the sound), t0 (time_precise at the start), dur }
local ruler_drag = false       -- the left button is down on the time ruler
local stop_audition            -- defined with the audition code below
local edited_cells = {}         -- edited_cells[p][f] = true for every cell an edit has touched (the phases of those runs are rebuilt on save)
local saved_depth = 0          -- undo depth at the last save/load: modified = (#undo_stack ~= saved_depth)
local current_file = nil       -- the .ats file that holds the data as it is now (the opened file, or the last save)
local status_msg, status_until = nil, 0
local showing_analysis = false   -- the Analysis page is on screen instead of the picture
local analysis = nil            -- the Analysis page object (made at the end of the file)
local mover = nil              -- a drag that moves the selection: { x0, y0, x, y, lx, ly, ex, ey (the movement in pixels, Shift makes it a fifth), axis (Ctrl) }
local box = nil                -- rubber-band box while the left button is down: { x0, y0, x1, y1, add }
local lasso = nil              -- Ctrl+Shift+drag: a freehand loop being drawn: { pts = { {x, y}, ... }, add, off, h }
local amp_thresh = 0
-- The box round the selection with handles that bend it (the "rubber sheet", lib/ats_warp.lua): W.region = the box (t0, t1, f0, f1) the selection
-- was made with, W.w = the warp being shaped (nil = flat), W.drag = a handle being dragged. Everything about it lives in this one table (the main
-- chunk of this file is at Lua's limit of 200 local variables).
local W = { m = dofile(script_dir .. "/lib/ats_warp.lua"), layout = dofile(script_dir .. "/lib/layout.lua") }
-- The place of an element of the layout (lib/layout.lua) in the window as it is now: x, y, w, h. An element hangs on the edge that the layout says
-- (right: its distance to the right edge stays what it was in the default window, 1100 wide; bottom: likewise for the height, 640).
function W.lay(id)
  local e = W.layout.el[id]
  local x, y = e.x, e.y
  if e.ax == "r" then x = math.floor(gfx.w) - (W.layout.ref_w - e.x) end
  if e.ay == "b" then y = math.floor(gfx.h) - (W.layout.ref_h - e.y) end
  return x, y, e.w, e.h
end
-- The messages that belong to AUDITION (preparing the sound, auditioning from ..., audition stopped) are not shown (tjingboem, 11 Nov 2026: "remove text that pops
-- up when Auditioning"): the last one is kept in W.audition_note, and the tests can switch them on with the global REAATS_SHOW_AUDITION_TEXT. Failures are still shown.
function W.say_audition(msg)
  W.audition_note = msg
  if rawget(_G, "REAATS_SHOW_AUDITION_TEXT") then set_status(msg) end
end
-- The size of a font in which `label` fits in `w` pixels (13 or the given size at most, 9 at least).
function W.fit(label, w, size)
  size = size or 14
  while size > 9 do
    gfx.setfont(1, "Arial", size)
    if gfx.measurestr(label) <= w - 6 then break end
    size = size - 1
  end
  gfx.setfont(1, "Arial", size)
  return size
end
local last_audition = nil      -- the last sound AUDITION made (see start_preview)

local LOG = math.log
local function clamp(x, a, b) if x < a then return a elseif x > b then return b else return x end end

-- ------------------------------------------------------------ channels on screen
-- Every channel has a colour (used in the overlay and on its button) and can be switched ON/OFF; ON channels are drawn
-- and edited together. STACK view: one lane per ON channel under each other (shared time axis). OVERLAY view: all ON
-- channels in one lane, each in its colour with the strength its slider (20-100 %) gives.
local TINTS = { { 0.35, 0.85, 1.00 }, { 1.00, 0.62, 0.25 }, { 0.45, 0.95, 0.45 }, { 0.95, 0.40, 0.90 },
                { 1.00, 0.93, 0.35 }, { 1.00, 0.40, 0.40 }, { 0.30, 0.90, 0.75 }, { 1.00, 0.60, 0.75 } }
local function tint_of(i) return TINTS[(i - 1) % #TINTS + 1] end
local VIS_MIN = 0.20

-- Runs fn with channel i's data / selection in the globals the drawing and hit-test code reads (no bundle swap:
-- nothing else changes, the undo stacks stay where they are).
local function as_channel(i, fn)
  local c = chs[i]
  if not c or i == cur then return fn() end
  local d0, a0, s0, si0 = data, amp_thresh, sel, sel_info
  data, amp_thresh, sel, sel_info = c.data, c.amp_thresh, c.sel, c.sel_info
  local r = fn()
  data, amp_thresh, sel, sel_info = d0, a0, s0, si0
  return r
end

local function on_list()
  local l = {}
  for i, c in ipairs(chs) do if c.on then l[#l + 1] = i end end
  return l
end

local function any_sel()
  if sel_info then return true end
  for i, c in ipairs(chs) do if i ~= cur and c.on and c.sel_info then return true end end
  return false
end

-- The lanes of a plot of height ph: { off = pixels from the plot top, h = height, chans = channels drawn in it }.
local function lane_layout(ph)
  local on = on_list()
  if #on < 2 or view_mode == "overlay" then return { { off = 0, h = ph, chans = on } } end
  local n = #on
  local lh = math.max(math.floor((ph - (n - 1) * 4) / n), 8)
  local lanes = {}
  for j, ci in ipairs(on) do lanes[j] = { off = (j - 1) * (lh + 4), h = lh, chans = { ci } } end
  return lanes
end

local function lane_at(py, ph, y)
  for _, lane in ipairs(lane_layout(ph)) do
    if y >= py + lane.off and y < py + lane.off + lane.h then return lane end
  end
  return nil
end

-- ------------------------------------------------------------------ geometry
local function plot_rect()
  local w, h = math.floor(gfx.w), math.floor(gfx.h)
  local top = MARGIN_T + ((#chs > 1) and CHAN_ROW or 0)            -- an extra row for the channel LEDs, buttons and sliders
  return MARGIN_L, top, math.max(w - MARGIN_L - MARGIN_R, 10), math.max(h - top - MARGIN_B, 10)
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
  for _, c in ipairs(chs) do
    local d, th = c.data, c.amp_thresh
    for p = 1, d.partials do
      local a, fr = d.amp[p], d.frq[p]
      for f = 1, d.frames do
        if a[f] > th and fr[f] > 0 then
          if fr[f] < fmin then fmin = fr[f] end
          if fr[f] > fmax then fmax = fr[f] end
        end
      end
    end
  end
  if fmin >= fmax then fmin, fmax = 20, 20000 end
  view.f0 = math.max(10, fmin / 1.4)
  view.f1 = math.min(40000, fmax * 1.4)
  dirty = true
end

-- ----------------------------------------------------------------- channel sets
-- A stereo or multichannel analysis is a set of files name_ch1.ats, name_ch2.ats, ... (one per channel, see the Analysis
-- page). Opening any one of them opens the whole set; the channel buttons switch the channel that is shown and edited.
-- Everything that belongs to one channel is kept in a bundle so that switching only swaps the bundles.
local function capture_channel()
  local c = chs[cur]
  if not c then return end
  c.data, c.fname, c.current_file = data, fname, current_file
  c.undo_stack, c.redo_stack, c.modified, c.saved_depth = undo_stack, redo_stack, modified, saved_depth
  c.edited_cells, c.sel, c.sel_info, c.amp_thresh = edited_cells, sel, sel_info, amp_thresh
end

local function restore_channel(i)
  cur = i
  local c = chs[i]
  data, fname, current_file = c.data, c.fname, c.current_file
  undo_stack, redo_stack, modified, saved_depth = c.undo_stack, c.redo_stack, c.modified, c.saved_depth
  edited_cells, sel, sel_info, amp_thresh = c.edited_cells, c.sel, c.sel_info, c.amp_thresh
  box, mover = nil, nil
  dirty = true
end

local function switch_channel(i)
  if i == cur or not chs[i] then return end
  capture_channel()
  restore_channel(i)
end

-- The channels that are shown AND editable (green LED), in order: selecting and every edit go to these. (capture_channel first, so that the bundles are current.)
local function on_channels()
  capture_channel()
  local list = {}
  for i, c in ipairs(chs) do if c.on and c.edit then list[#list + 1] = i end end
  return list
end

-- Runs fn with channel i as the reference channel (its bundle in the globals), then puts the previous one back.
local function with_channel(i, fn)
  local keep = cur
  if i ~= cur then switch_channel(i) end
  local r1, r2 = fn()
  if cur ~= keep then switch_channel(keep) end
  return r1, r2
end

-- The files of the set that `path` belongs to, and which of them it is. A file that is not name_chK.ats, or whose
-- channels do not start at 1 or are not all there, is a set of one.
local function find_set(path)
  local stem, k, ext = path:match("^(.*)_ch(%d+)(%.[^./\\]+)$")
  if not stem then return { path }, 1 end
  local files, i = {}, 1
  while true do
    local f = string.format("%s_ch%d%s", stem, i, ext)
    if reaper.file_exists(f) then files[#files + 1] = f; i = i + 1 else break end
  end
  local which = tonumber(k)
  if files[which] ~= path then return { path }, 1 end
  return files, which
end

local data_rev = 0               -- counts every change of the sound data (an edit, undo, redo, a file loaded): AUDITION replays its last sound while it is unchanged
-- How much memory the computer has free (bytes), or nil when that cannot be found out (Linux only).
local function available_memory()
  local fh = io.open("/proc/meminfo", "r")
  if not fh then return nil end
  local t = fh:read("a")
  fh:close()
  local kb = t:match("MemAvailable:%s+(%d+)")
  return kb and tonumber(kb) * 1024 or nil
end


local function load_file(path)
  data_rev = data_rev + 1
  W.w, W.region = nil, nil
  local files, which = find_set(path)
  -- 1. Look at the headers only: is everything readable, do the channels fit together, will it fit in memory?
  local heads, note = {}, nil
  for i, f in ipairs(files) do
    local h, err = ats.header(f)
    if not h then
      if #files == 1 then load_error = f .. "\n" .. tostring(err); return false end
      note = "the channel files do not all open (" .. (f:match("([^/\\]+)$") or f) .. "): opened this file alone"
      files, which, heads = { path }, 1, {}
      break
    end
    heads[i] = h
  end
  if #heads == 0 then
    local h, err = ats.header(path)
    if not h then load_error = path .. "\n" .. tostring(err); return false end
    heads[1] = h
  end
  if #heads > 1 then                                            -- all channels must have the same frame grid
    local a = heads[1]
    for i = 2, #heads do
      local b = heads[i]
      if b.frames ~= a.frames or b.frame_size ~= a.frame_size or b.sr ~= a.sr or math.abs(b.dur - a.dur) > 1e-6 then
        note = "the channel files do not have the same frame grid: opened this file alone"
        files, which, heads = { path }, 1, { heads[which] }
        break
      end
    end
  end
  local need = 0
  for _, h in ipairs(heads) do need = need + h.bytes * 2.1 end      -- (the tables of a loaded analysis take about twice the size of the file: 16 bytes for every 8-byte number)
  local free = available_memory()
  if free then
    free = free + collectgarbage("count") * 1024               -- what the set that is open now gives back
    if need > free * 0.85 then
      local msg = string.format("this analysis needs about %.1f GB in the editor and only %.1f GB is free: analyse again with a higher "
        .. "amplitude threshold (-50 or -40 dB) or a higher lowest frequency, or one channel at a time", need / 2^30, free / 2^30)
      load_error = path .. "\n" .. msg
      if set_status then set_status(msg) end
      return false
    end
  end
  -- 2. Let go of the set that is open BEFORE loading the next one. Two long analyses in memory at the same time (and the
  --    garbage collector waiting before it frees the first) used up all the memory of a computer and REAPER was killed.
  if pending then pending.job.cancel(); pending = nil end
  if stop_audition then stop_audition() end
  last_audition = nil
  chs, data = {}, nil
  sel, sel_info, undo_stack, redo_stack, edited_cells = {}, nil, {}, {}, {}
  box, mover = nil, nil
  collectgarbage("collect")
  collectgarbage("collect")
  -- 3. Load.
  local loaded = {}
  for i, f in ipairs(files) do
    local d, err = ats.load(f)
    if not d then
      load_error = f .. "\n" .. tostring(err)
      return false
    end
    loaded[i] = d
  end
  chs = {}
  for i, d in ipairs(loaded) do
    chs[i] = { data = d, fname = files[i], current_file = files[i], undo_stack = {}, redo_stack = {}, modified = false,
               saved_depth = 0, edited_cells = {}, sel = {}, sel_info = nil, amp_thresh = d.ampmax * 10 ^ (DB_FLOOR / 20),
               on = true,                     -- shown (switched off = not drawn)
               edit = true,                   -- editable (the LED above the button: green = edited together with the others, red = left alone)
               vis = 1.0 }                    -- how strongly it is drawn in the overlay: 0.2 .. 1
  end
  restore_channel(which)
  load_error = nil
  playhead, play = 0, nil
  if stop_audition then stop_audition() end
  reaper.SetExtState(EXT_SECTION, EXT_LAST, path, true)
  fit_view()
  if note and set_status then set_status(note) end
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
  W.commit()                                   -- (a bend that has been shaped but not applied is applied before the selection goes)
  W.region = nil
  sel, sel_info = {}, nil
  for i, c in ipairs(chs) do if i ~= cur then c.sel, c.sel_info = {}, nil end end
end

-- Selects every point (partial p at frame f) whose time and frequency lie inside the box.
-- add = true keeps the existing selection and adds to it.
local function select_box_single(ta, tb, fa, fb, add)
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

-- The same time-frequency region on every channel that is switched on (each channel selects its own points).
local function select_box(ta, tb, fa, fb, add)
  if not data then return end
  if not show_partials then set_status("the sine layer is off: switch it on to select partials"); return end
  if #on_channels() == 0 then set_status("no channel is editable: click an LED to make it green"); return end
  W.commit()
  for _, i in ipairs(on_channels()) do
    with_channel(i, function() select_box_single(ta, tb, fa, fb, add) end)
  end
  W.set_region(ta, tb, fa, fb, add)
end

-- Lasso: selects the points inside a closed freehand loop. The loop is given in time and log-frequency (poly_t, poly_lf), the points
-- are tested with the even-odd rule; the same loop is applied to every channel that is on and green, like a box.
local function select_poly_single(poly_t, poly_lf, tmin, tmax, fmin, fmax, add)
  if not data then return end
  if not add then sel = {} end
  local n = #poly_t
  local f_lo = math.max(frame_at(tmin) - 1, 1)
  local f_hi = math.min(frame_at(tmax) + 1, data.frames)
  local times = data.times
  for p = 1, data.partials do
    local amp, frq = data.amp[p], data.frq[p]
    for f = f_lo, f_hi do
      local t = times[f]
      if t >= tmin and t <= tmax and amp[f] > amp_thresh then
        local fr = frq[f]
        if fr >= fmin and fr <= fmax then
          local y, inside, j = LOG(fr), false, n
          for i = 1, n do
            local yi, yj = poly_lf[i], poly_lf[j]
            if (yi > y) ~= (yj > y) and t < (poly_t[j] - poly_t[i]) * (y - yi) / (yj - yi) + poly_t[i] then inside = not inside end
            j = i
          end
          if inside then
            sel[p] = sel[p] or {}
            sel[p][f] = true
          end
        end
      end
    end
  end
  update_sel_info()
end

local function select_poly(poly_t, poly_lf, add)
  if not data then return end
  if not show_partials then set_status("the sine layer is off: switch it on to select partials"); return end
  if #on_channels() == 0 then set_status("no channel is editable: click an LED to make it green"); return end
  local tmin, tmax, lmin, lmax = math.huge, -math.huge, math.huge, -math.huge
  for i = 1, #poly_t do
    tmin, tmax = math.min(tmin, poly_t[i]), math.max(tmax, poly_t[i])
    lmin, lmax = math.min(lmin, poly_lf[i]), math.max(lmax, poly_lf[i])
  end
  local fmin, fmax = math.exp(lmin), math.exp(lmax)
  W.commit()
  for _, i in ipairs(on_channels()) do
    with_channel(i, function() select_poly_single(poly_t, poly_lf, tmin, tmax, fmin, fmax, add) end)
  end
  W.set_region(tmin, tmax, fmin, fmax, add)
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
function set_status(msg)
  status_msg, status_until = msg, reaper.time_precise() + 4
end

local function apply_changes(changes, forward)
  data_rev = data_rev + 1
  if pending then pending.job.cancel(); pending = nil; set_status("audition cancelled: the data changed") end
  for _, c in ipairs(changes) do
    data.amp[c.p][c.f] = forward and c.na or c.oa
    data.frq[c.p][c.f] = forward and c.nf or c.of
    edited_cells[c.p] = edited_cells[c.p] or {}
    edited_cells[c.p][c.f] = true
  end
  dirty = true
end

-- Frames in front of the file (a stretch to before 0) move everything k frames later: the cells an edit has touched are numbered again.
local function shift_edited(k)
  local moved = {}
  for p, frames in pairs(edited_cells) do
    local row = {}
    for f in pairs(frames) do if f + k >= 1 then row[f + k] = true end end
    moved[p] = row
  end
  edited_cells = moved
end

-- Makes this channel's file longer: k frames in front (everything later) and/or up to frames_after frames in all. Returns what is needed to undo it.
local function lengthen(front, frames_after)
  local before_frames, before_dur = data.frames, data.dur
  if front and front > 0 then
    edit.prepend_frames(data, front)
    shift_edited(front)
    W.shift_touched(front)
  end
  if frames_after and frames_after > data.frames then edit.add_frames(data, frames_after - data.frames) end
  return before_frames, before_dur
end

-- ext (optional): { front = k, frames_after = n }: the file becomes longer first (k frames in front, n frames in all); the way back is in the undo entry.
-- The noise bands follow the movements of the sines when the Noise layer is on (see edit.plan_noise_*): changes of the noise are
-- { b = band, f = frame, old, new }; the cells that were touched are remembered in data.noise_touched (for the synthesis of an unsaved edit).
function W.apply_noise(changes, forward)
  if not changes or #changes == 0 then return end
  data.noise_touched = data.noise_touched or {}
  for _, c in ipairs(changes) do
    local v = forward and c.new or c.old
    data.noise[c.b][c.f] = v
    local row = data.noise_touched[c.b]
    if not row then row = {}; data.noise_touched[c.b] = row end
    row[c.f] = true
    if v > data.noise_max then data.noise_max = v end
  end
  data.noise_cache = nil                                     -- (the noise that was kept for AUDITION is not the noise any more)
  dirty = true
end

-- The box of a channel's selection for the noise: the box it was made with (W.region), else the box round the selected points.
-- `c` is a channel bundle (data, sel_info).
function W.noise_region(d, si)
  if W.region then return W.region end
  if not si then return nil end
  local dt = (d.times[d.frames] - d.times[1]) / math.max(d.frames - 1, 1)
  local t0, t1, f0, f1 = si.t0, si.t1, si.f0, si.f1
  if t1 - t0 < dt then local m = (t0 + t1) / 2; t0, t1 = m - dt / 2, m + dt / 2 end
  return { t0 = t0, t1 = t1, f0 = f0, f1 = f1 }
end

-- Does the noise follow? When the Noise layer is shown and the file has noise bands.
function W.noise_on(d) return show_noise and d.has_noise end

-- Frames put in front move the numbers of the touched noise cells too (k later, or negative: k earlier).
function W.shift_touched(k)
  if not data.noise_touched then return end
  local moved = {}
  for b, frames in pairs(data.noise_touched) do
    local row = {}
    for f in pairs(frames) do if f + k >= 1 then row[f + k] = true end end
    moved[b] = row
  end
  data.noise_touched = moved
end

local function do_edit(name, changes, rows_before, rows_after, ext, noise_changes)
  if #changes == 0 and not (noise_changes and #noise_changes > 0) then return end
  if rows_after and rows_after > data.partials then edit.add_rows(data, rows_after - data.partials) end
  local frames_before, dur_before
  if ext and (((ext.front or 0) > 0) or (ext.frames_after or 0) > data.frames) then
    frames_before, dur_before = lengthen(ext.front, ext.frames_after)
  end
  apply_changes(changes, true)
  W.apply_noise(noise_changes, true)
  if not edit_group then group_counter = group_counter + 1 end
  undo_stack[#undo_stack + 1] = { name = name, changes = changes, noise_changes = noise_changes, rows_before = rows_before, rows_after = rows_after,
                                  frames_before = frames_before, frames_after = frames_before and ext.frames_after, front = frames_before and ext.front,
                                  dur_before = dur_before, group = edit_group or group_counter }      -- (one group = one Ctrl+Z, even across channels)
  redo_stack = {}
  modified = (#undo_stack ~= saved_depth)
  set_status(string.format("%s: %d points%s", name, #changes, (noise_changes and #noise_changes > 0) and " and the noise" or ""))
end

-- A channel that has no points in an edit that makes the file longer still gets longer (all channels share one frame grid): an entry
-- without changes, so that Ctrl+Z makes it short again together with the others.
local function do_extend_only(name, frames_after, front)
  if frames_after <= data.frames and (front or 0) == 0 then return end
  local frames_before, dur_before = lengthen(front, frames_after)
  data_rev = data_rev + 1
  dirty = true
  if not edit_group then group_counter = group_counter + 1 end
  undo_stack[#undo_stack + 1] = { name = name, changes = {}, frames_before = frames_before, frames_after = frames_after, front = front,
                                  dur_before = dur_before, group = edit_group or group_counter }
  redo_stack = {}
  modified = (#undo_stack ~= saved_depth)
end

local function undo_single()
  local e = table.remove(undo_stack)
  if not e then set_status("nothing to undo"); return end
  apply_changes(e.changes, false)
  W.apply_noise(e.noise_changes, false)
  if e.rows_before and data.partials > e.rows_before then
    edit.truncate_rows(data, e.rows_before)
    for p in pairs(edited_cells) do if p > data.partials then edited_cells[p] = nil end end     -- (rows that are gone have no cells to remember)
  end
  if e.frames_before then                                              -- the file was made longer by this edit: as it was again
    local k = e.front or 0
    if data.frames > e.frames_before + k then edit.truncate_frames(data, e.frames_before + k) end        -- (the end)
    if k > 0 then                                                      -- (the start: everything moves k frames earlier)
      edit.drop_front(data, k, e.dur_before)
      W.shift_touched(-k)
      local moved = {}
      for p, frames in pairs(edited_cells) do
        local row = {}
        for f in pairs(frames) do if f - k >= 1 then row[f - k] = true end end
        moved[p] = row
      end
      edited_cells = moved
    else
      data.dur = e.dur_before
    end
    for _, frames in pairs(edited_cells) do
      for f in pairs(frames) do if f > data.frames then frames[f] = nil end end
    end
    data_rev = data_rev + 1
    dirty = true
  end
  redo_stack[#redo_stack + 1] = e
  clear_selection()
  modified = (#undo_stack ~= saved_depth)
  set_status("undo " .. e.name)
end

local function redo_single()
  local e = table.remove(redo_stack)
  if not e then set_status("nothing to redo"); return end
  if e.rows_after and e.rows_after > data.partials then edit.add_rows(data, e.rows_after - data.partials) end
  if e.frames_before and data.frames == e.frames_before and (e.front or 0) > 0 then
    edit.prepend_frames(data, e.front)
    shift_edited(e.front)
    W.shift_touched(e.front)
  end
  if e.frames_after and e.frames_after > data.frames then edit.add_frames(data, e.frames_after - data.frames) end
  apply_changes(e.changes, true)
  W.apply_noise(e.noise_changes, true)
  undo_stack[#undo_stack + 1] = e
  clear_selection()
  modified = (#undo_stack ~= saved_depth)
  set_status("redo " .. e.name)
end

-- Ctrl+Z / Ctrl+Y act on the most recent group of edits, in every channel it touched.
local function undo()
  W.w, W.region = nil, nil                       -- (undo drops a bend that was shaped and not applied)
  capture_channel()
  local best, who = -1, {}
  for i, c in ipairs(chs) do
    local e = c.undo_stack[#c.undo_stack]
    if e then
      local g = e.group or 0
      if g > best then best, who = g, { i } elseif g == best then who[#who + 1] = i end
    end
  end
  if best < 0 then set_status("nothing to undo"); return end
  local front = 0
  for _, i in ipairs(who) do front = math.max(front, chs[i].undo_stack[#chs[i].undo_stack].front or 0) end
  for _, i in ipairs(who) do with_channel(i, undo_single) end
  if front > 0 then                                                    -- frames in front are gone: what was shown stays where it was
    local dt = front * chs[cur].data.frame_size / chs[cur].data.sr
    view.t0, view.t1, playhead = view.t0 - dt, view.t1 - dt, math.max(playhead - dt, 0)
  end
  if #who > 1 then set_status("undo in " .. #who .. " channels") end
end

local function redo()
  W.w, W.region = nil, nil
  capture_channel()
  local best, who = math.huge, {}
  for i, c in ipairs(chs) do
    local e = c.redo_stack[#c.redo_stack]
    if e then
      local g = e.group or 0
      if g < best then best, who = g, { i } elseif g == best then who[#who + 1] = i end
    end
  end
  if #who == 0 then set_status("nothing to redo"); return end
  local front = 0
  for _, i in ipairs(who) do front = math.max(front, chs[i].redo_stack[#chs[i].redo_stack].front or 0) end
  for _, i in ipairs(who) do with_channel(i, redo_single) end
  if front > 0 then
    local dt = front * chs[cur].data.frame_size / chs[cur].data.sr
    view.t0, view.t1, playhead = view.t0 + dt, view.t1 + dt, playhead + dt
  end
  if #who > 1 then set_status("redo in " .. #who .. " channels") end
end

-- An edit function that works on the reference channel's selection, run on every channel that is on and has a selection,
-- as one undo group.
local function edit_on_channels(fn_single, label)
  if not W.busy then W.commit() end            -- (a bend that was shaped is applied first; W.commit itself calls this with W.busy set)
  local targets = {}
  for _, i in ipairs(on_channels()) do if chs[i].sel_info then targets[#targets + 1] = i end end
  if #targets == 0 then return end
  group_counter = group_counter + 1
  edit_group = group_counter
  for _, i in ipairs(targets) do with_channel(i, fn_single) end
  edit_group = nil
  W.region = nil                               -- (the box is the one round the selection as it is now)
  if #targets > 1 and label then set_status(label .. " in " .. #targets .. " channels") end
end

-- Delete: the selected points become silent (amplitude 0 = partial not sounding, as in ATS).
local function delete_single(with_noise)
  if not sel_info then return end
  local changes = {}
  for p, frames in pairs(sel) do
    for f in pairs(frames) do
      if data.amp[p][f] > 0 then
        changes[#changes + 1] = { p = p, f = f, oa = data.amp[p][f], na = 0, of = data.frq[p][f], nf = data.frq[p][f] }
      end
    end
  end
  local nplan = with_noise and W.noise_on(data) and edit.plan_noise_clear(data, W.noise_region(data, sel_info)) or nil        -- (a cut takes the noise too; a delete leaves it)
  do_edit(with_noise and "cut" or "delete", changes, nil, nil, nil, nplan and nplan.changes)
  sel, sel_info = {}, nil
end

-- Transpose the selected points by `semitones` (frequencies only; phases are not touched).
local function transpose_single(semitones)
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
local function delete_selection() edit_on_channels(function() delete_single(false) end, "delete") end
local function transpose_selection(semitones) edit_on_channels(function() transpose_single(semitones) end, "transpose") end

-- A move (the arrow keys or a drag): the points of every green channel go by `df` frames and a frequency factor. When they go beyond the end
-- or before the start of the file, the file grows (every channel of a set), as for the bend box, and one undo step takes it all back.
function W.room()
  local rows_max = 1
  for _, c in ipairs(chs) do rows_max = math.max(rows_max, c.data.partials) end
  return math.min(chs[1].data.frames, math.floor(2e7 / rows_max))        -- at most as long again, and never more than 20 million new cells
end
function W.move(df, ratio)
  if not W.busy then W.commit() end
  local list = {}
  for _, i in ipairs(on_channels()) do if chs[i].sel_info then list[#list + 1] = i end end
  if #list == 0 then return end
  local room = W.room()
  local plans, nplans, need_end, need_front, first_plan = {}, {}, 0, 0, nil
  for _, i in ipairs(list) do
    with_channel(i, function()
      local opts = { max_extra = room, max_front = room }
      local plan = edit.plan_move(data, sel, df, ratio, opts)
      if not plan then return end
      plans[i], first_plan = plan, first_plan or plan
      need_end, need_front = math.max(need_end, plan.frames_after), math.max(need_front, plan.frames_front)
      if W.noise_on(data) then                                          -- (the noise bands go along in time)
        local np = edit.plan_noise_move(data, W.noise_region(data, sel_info), plan.df, opts)
        if np then
          nplans[i] = np
          need_end, need_front = math.max(need_end, np.frames_after), math.max(need_front, np.frames_front)
        end
      end
    end)
  end
  if not first_plan then set_status("nothing to move"); return end
  local label = string.format("move %+d frames, %+.2f st", first_plan.df, 12 * math.log(ratio, 2))
  local before, rows_added = chs[1].data.frames, 0
  for _, plan in pairs(plans) do rows_added = math.max(rows_added, plan.rows_after - plan.rows_before) end
  W.apply_grown(label, plans, nplans, need_end, need_front)
  W.region = nil                                                       -- (the box is the one round the selection as it is now)
  if chs[1].data.frames == before then
    if rows_added > 0 then set_status(string.format("%s (+%d new partial rows)", label, rows_added))
    elseif #list > 1 then set_status(label .. " in " .. #list .. " channels") end
  end
end
local function move_selection(df, ratio) W.move(df, ratio) end

-- ------------------------------------------------------------ copy, cut and paste
-- Ctrl+C copies the selected points of every channel that is on and green (their frames relative to the first copied frame, so the
-- channels keep their timing against each other); Ctrl+V pastes them at the playhead, every channel back into its own number, as
-- one undo step. Like a move, a paste never overwrites sound: it goes into silent cells, else other rows (see edit.plan_paste).
local clipboard = nil              -- { pieces = { [channel] = { { p, df, amp, frq }, ... } }, count }

local function copy_selection()
  W.commit()
  local gathered, count, fmin = {}, 0, math.huge
  for _, i in ipairs(on_channels()) do
    local c = chs[i]
    if c.sel_info then
      local list = {}
      for p, frames in pairs(c.sel) do
        for f in pairs(frames) do
          list[#list + 1] = { p = p, f = f, amp = c.data.amp[p][f], frq = c.data.frq[p][f] }
          if f < fmin then fmin = f end
        end
      end
      gathered[i] = list
      count = count + #list
    end
  end
  if count == 0 then set_status("nothing selected to copy"); return false end
  local pieces, channels = {}, 0
  for i, list in pairs(gathered) do
    for _, pt in ipairs(list) do pt.df = pt.f - fmin; pt.f = nil end
    pieces[i] = list
    channels = channels + 1
  end
  local noise = {}                                           -- the noise under the selection, to be pasted with it (when the Noise layer is on then)
  for i in pairs(pieces) do
    local c = chs[i]
    if c.data.has_noise then noise[i] = edit.noise_piece(c.data, W.noise_region(c.data, c.sel_info), fmin) end
  end
  clipboard = { pieces = pieces, count = count, noise = noise }
  set_status(string.format("copied %d points%s: Ctrl+V pastes them at the playhead", count,
                           channels > 1 and (" from " .. channels .. " channels") or ""))
  return true
end

local function paste_clipboard()
  if not data then return end
  W.commit()
  if not clipboard then set_status("nothing copied yet: select points, then Ctrl+C"); return end
  local targets = {}
  for _, i in ipairs(on_channels()) do if clipboard.pieces[i] then targets[#targets + 1] = i end end
  if #targets == 0 then set_status("the channels that were copied are not editable now: switch them on and make their LED green"); return end
  clear_selection()
  for _, c in ipairs(chs) do c.redo_stack = {} end
  redo_stack = {}
  local room = W.room()
  local plans, nplans, need_end, at = {}, {}, 0, 0
  for _, i in ipairs(targets) do
    with_channel(i, function()
      local f0 = frame_at(playhead)
      at = data.times[f0]
      local opts = { max_extra = room }                                          -- (a paste near the end makes the file longer)
      local plan = edit.plan_paste(data, clipboard.pieces[i], f0, opts)
      local np = W.noise_on(data) and clipboard.noise and clipboard.noise[i] and edit.plan_noise_paste(data, clipboard.noise[i], f0, opts) or nil
      plans[i], nplans[i] = plan, np
      if plan then need_end = math.max(need_end, plan.frames_after) end
      if np then need_end = math.max(need_end, np.frames_after) end
    end)
  end
  local total, dropped = 0, 0
  for _, plan in pairs(plans) do total, dropped = total + plan.count, dropped + plan.dropped end
  if total == 0 and next(nplans) == nil then set_status("nothing could be pasted there: the playhead is too near the end of the file"); return end
  local before, dur_before = chs[1].data.frames, chs[1].data.dur
  W.apply_grown("paste", plans, nplans, need_end, 0)
  W.region = nil
  local grown = chs[1].data.dur - dur_before
  set_status(string.format("pasted %d points at %.3f s%s%s%s (they are selected now)", total, at,
                           #targets > 1 and (" in " .. #targets .. " channels") or "",
                           chs[1].data.frames > before and string.format(", the file is %.2f s longer now", grown) or "",
                           dropped > 0 and (", " .. dropped .. " fell outside the file") or ""))
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
local start_preview, play_from_made   -- (defined below, used by audition)
math.randomseed(os.time() + math.floor(reaper.time_precise() * 1000))
local session_id = string.format("%d_%d", os.time(), math.random(100000, 999999))   -- makes the temporary file names this editor's own
local wav_history = {}

function stop_audition()
  if pending and pending.kind == "audition" then pending.job.cancel(); pending = nil end
  if reaper.Xen_StopSourcePreview and reaper.time_precise() < preview_until + 0.3 then
    reaper.Xen_StopSourcePreview(-1)
  end
  preview_until = 0
  play = nil
end

-- Renders the current data to `wav` (pure Lua, lib/ats_synth.lua; no other program needed). Returns the
-- duration and a label ("sines + noise", ...), or nil plus a message.
local function render_wav(wav, from)
  local use_sines = show_partials
  local use_noise = show_noise and data.has_noise
  local samples, sr, t_start = synth.render(data, { sines = use_sines, noise = use_noise, from = from })
  if not samples then return nil, sr end                      -- sr is the message when samples is nil
  local ok, err = synth.write_wav(wav, samples, sr)
  if not ok then return nil, err end
  return #samples / sr, (use_sines and use_noise) and "sines + noise" or (use_sines and "sines" or "noise"), t_start
end

local function tmp_dir() return (os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "") end
local synth_count = 0
local python_missing = false                   -- no Python was found for the synthesis (the Analysis page may find one later)

-- Starts the synthesis of every channel into `wav`. With Python (numpy) it runs in a program in the background, much faster;
-- without it, or if that cannot start, the built-in Lua synthesis runs in small steps. o: sines, noise, from, to, mixdown.
-- Returns the job, the engine's name and the request (to fall back on Lua if the Python run fails).
local function start_synth(wav, o)
  capture_channel()
  local list = {}
  for i, c in ipairs(chs) do list[i] = c.data end
  local req = { list = list, o = o }
  local function lua_job() return synth.render_multi_job(list, { sines = o.sines, noise = o.noise, from = o.from, to = o.to }), "Lua", req end
  local script = script_dir .. "/python/reaats_synth.py"
  if not (reaper.ExecProcess and reaper.file_exists(script) and analysis) then return lua_job() end
  if not analysis.python then                                  -- look for Python once; if there is none, stay with Lua
    if python_missing or not analysis:find_python() then python_missing = true; return lua_job() end
  end
  synth_count = synth_count + 1
  local id = string.format("%s_s%d", session_id, synth_count)
  local dir, files, temp, edits, any_edits = tmp_dir(), {}, {}, {}, false
  local function discard() for _, f in ipairs(temp) do os.remove(f) end end
  for i, c in ipairs(chs) do
    local d = list[i]
    if c.current_file and reaper.file_exists(c.current_file) then
      -- The channel's file is on disk already: the program reads it from there and gets only the cells edited since it was
      -- written (a long sound is a file of hundreds of megabytes; writing it again for every AUDITION is slow and can use up the memory).
      files[i] = c.current_file
      local hdr = ats.header(c.current_file)
      local cells, n = c.edited_cells or {}, 0
      local path = string.format("%s/reaats_%s_ch%d_edits.bin", dir, id, i)
      local fh = io.open(path, "wb")
      if not fh then discard(); return lua_job() end
      local buf = {}
      if hdr and (d.frames ~= hdr.frames or (d.front_frames or 0) > 0) then       -- the sound was made longer: a record with partial 0 (frames, duration, frames in front)
        buf[#buf + 1] = string.pack("<dddd", 0, d.frames, d.dur, d.front_frames or 0)
        n = n + 1
      end
      for p, frames in pairs(cells) do
        for f in pairs(d.amp[p] and frames or {}) do                -- (a row that an undo took away has nothing to send)
          buf[#buf + 1] = string.pack("<dddd", p, f, d.amp[p][f], d.frq[p][f])
          n = n + 1
          if #buf >= 4096 then fh:write(table.concat(buf)); buf = {} end
        end
      end
      for b, frames in pairs(d.noise_touched or {}) do                  -- the noise cells that were changed: partial = -band
        for f in pairs(frames) do
          local v = d.noise and d.noise[b] and d.noise[b][f]
          if v then
            buf[#buf + 1] = string.pack("<dddd", -b, f, v, 0)
            n = n + 1
            if #buf >= 4096 then fh:write(table.concat(buf)); buf = {} end
          end
        end
      end
      fh:write(table.concat(buf))
      fh:close()
      if n > 0 then edits[i] = path; temp[#temp + 1] = path; any_edits = true else edits[i] = "-"; os.remove(path) end
    else                                                       -- no file for this channel: the edited data goes to a temporary one
      files[i] = string.format("%s/reaats_%s_ch%d.ats", dir, id, i)
      temp[#temp + 1] = files[i]
      edits[i] = "-"
      local ok = ats.save(files[i], d, { phase = false })      -- (the phase is not needed to listen)
      if not ok then discard(); return lua_job() end
    end
  end
  if not any_edits then edits = nil end
  local select_files = nil
  if o.selection then                                          -- AUDITION of the selection: per channel the cells that may sound (a channel with none is silent)
    select_files = {}
    for i, c in ipairs(chs) do
      local path = string.format("%s/reaats_%s_ch%d_select.bin", dir, id, i)
      local fh = io.open(path, "wb")
      if not fh then discard(); return lua_job() end
      local buf = {}
      for p, frames in pairs(c.sel or {}) do
        for f in pairs(frames) do
          buf[#buf + 1] = string.pack("<dd", p, f)
          if #buf >= 4096 then fh:write(table.concat(buf)); buf = {} end
        end
      end
      fh:write(table.concat(buf))
      fh:close()
      select_files[i] = path
      temp[#temp + 1] = path
    end
  end
  local job = py_synth.start({ exe = analysis.python.exe, script = script, files = files, edits = edits, temp = temp, wav = wav, dir = dir, id = id,
                               from = o.from, to = o.to, sines = o.sines, noise = o.noise, seed = 12345, mixdown = o.mixdown, spatial = o.spatial, select = select_files,
                               cache_dir = dir .. "/reaats_noise_cache" })
  if not job then discard(); return lua_job() end
  return job, "Python", req
end

-- AUDITION prepares the sound in the background (Python) or in small steps, a few milliseconds per frame (Lua), so that the
-- window keeps drawing and the AUDITION button can blink while it works; advance_pending() (called every frame) finishes the
-- job and starts the sound.
local function audition()
  if not data then return end
  W.commit()                                   -- (what you hear includes a bend that was shaped)
  if pending and pending.kind == "print" then set_status("wait: the print is being prepared"); return end
  stop_audition()
  local use_sines = show_partials
  local use_noise = show_noise and data.has_noise
  if not use_sines and not use_noise then set_status("nothing to audition (partials and noise are both off)"); return end
  local mode = (use_sines and use_noise) and "sines + noise" or (use_sines and "sines" or "noise")
  local to = nil                                                    -- (AUDITION always plays to the end of the sound)
  local d1 = chs[1].data
  local fs, sr = math.floor(d1.frame_size + 0.5), d1.sr
  local n_total = math.min(math.floor(d1.dur * sr), (d1.frames - 1) * fs)
  local k0 = math.min(1 + math.floor(playhead * sr / fs + 1e-6), d1.frames - 1)
  local s_r = (k0 - 1) * fs                                        -- the part asked for, in samples of the sound
  local e_r = to and math.min(n_total, math.floor(to * sr)) or n_total
  if e_r - s_r < 1 then set_status("nothing to play after this point"); return end
  local state = string.format("%d|%s|%s|%d|%s", data_rev, tostring(use_sines), tostring(use_noise), #chs, W.space_key())
  local la = last_audition
  if la and la.state == state and la.s <= s_r and e_r <= la.e and reaper.file_exists(la.wav) then
    -- nothing has changed since a sound was made that holds this part: play it (or a piece of it) without making it again
    play_from_made(la, s_r, e_r, { mode = la.mode, channels = la.channels, engine = la.engine, gain_db = la.gain_db })
    return
  end
  audition_count = audition_count + 1
  local wav = string.format("%s/reaats_audition_%s_%d.wav", tmp_dir(), session_id, audition_count)
  -- From the playhead to the end the WHOLE sound is made (when it is not very long): every later start in the middle is then free.
  local from = playhead
  if not to and d1.dur <= 120 then from = 0 end
  local job, engine, req = start_synth(wav, { sines = use_sines, noise = use_noise, from = from, to = to,
                                              mixdown = (#chs > 2 or (W.space_opts() and W.space_opts().channels > 2)) and "stereo" or nil,
                                              spatial = W.space_opts() })
  if engine == "Lua" and W.space_opts() then job.cancel(); set_status("P-STEREO and VBAP need the Python program (see ANALYSE): put SPACE on STEREO to use the built-in synthesis"); return end
  pending = { kind = "audition", mode = mode, channels = #chs, wav = wav, engine = engine, req = req, job = job, state = state,
              span_s = s_r, span_e = e_r }
  W.say_audition("preparing the sound ... 0 %")
end

-- Plays the sound in `wav` through REAPER's preview, and remembers it: while nothing changes, the next AUDITION plays this
-- file again (replay) instead of making the sound once more.
last_audition = nil                -- (declared with the other state; the last sound that was made: { state, wav, s, e (first and last+1 sample in the sound), nch, sr, ... }
local slice_history = {}           -- pieces cut out of it (kept briefly, then deleted)


-- Temporary files. This editor's sounds are removed when it closes (reaper.atexit); what an editor left behind, because REAPER was
-- closed in a hurry or crashed, is removed at the next start once it is old enough to be nobody's (the file names hold the time).
-- Sounds of long files are hundreds of megabytes, and they once filled a disk.
local function cleanup_session()
  for _, f in ipairs(wav_history) do os.remove(f) end
  for _, f in ipairs(slice_history) do os.remove(f) end
  wav_history, slice_history = {}, {}
end
if reaper.atexit then reaper.atexit(cleanup_session) end

local function remove_stale_temp_files()
  if not reaper.EnumerateFiles then return end
  local dir = (os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "")
  local now, doomed, i = os.time(), {}, 0
  while true do
    local name = reaper.EnumerateFiles(dir, i)
    if not name then break end
    i = i + 1
    local stamp = name:match("^reaats_audition_(%d+)_%d+_%d+%.wav$")          -- a sound made by AUDITION
              or name:match("^reaats_(%d+)_%d+_s%d+_.+")                      -- a file of a synthesis job (edits, results ...)
              or name:match("^reaats_(%d+)_%d+_s%d+%.ats$")
    stamp = tonumber(stamp)
    if stamp and stamp > 1e9 and now - stamp > 6 * 3600 then doomed[#doomed + 1] = dir .. "/" .. name end
  end
  for _, f in ipairs(doomed) do os.remove(f) end
end
-- Starts the preview of `wav`. how: nil = a sound that was just made, "replayed" = the same file again, "cut" = a piece cut out
-- of the sound that was made before.
function start_preview(p, wav, dur, t_start, how)
  local src = reaper.PCM_Source_CreateFromFile(wav)
  if src and reaper.Xen_StartSourcePreview then
    reaper.Xen_StartSourcePreview(src, 1.0, false)
    preview_until = reaper.time_precise() + dur
    play = { start = t_start or 0, t0 = reaper.time_precise(), dur = dur }
    local chan_note = ""
    if (p.channels or 1) > 2 then chan_note = ", " .. p.channels .. " channels mixed down to stereo"
    elseif (p.channels or 1) == 2 then chan_note = ", stereo" end
    local engine_note = (how == "replayed") and ", replayed: nothing has changed since it was made"
      or (how == "cut") and ", from the sound already made: nothing has changed"
      or (p.note and (", " .. p.engine .. " synthesis: Python failed with: " .. p.note) or (", " .. p.engine .. " synthesis"))
    if p.gain_db and p.gain_db < -0.005 then engine_note = engine_note .. string.format(", turned down %.1f dB to stay under -1 dBFS", -p.gain_db) end
    W.say_audition(string.format("auditioning from %.2f s, %.1f s long (%s%s%s)  Space stops", t_start or 0, dur, p.mode, chan_note, engine_note))
  else
    set_status("audition rendered " .. wav .. ", but REAPER could not play it (needs the SWS extension)")
  end
end

-- Plays the part s_r .. e_r (samples in the sound) of the sound made before (m): the file itself when it is exactly that part,
-- otherwise a piece cut out of it. Returns false after a status message if that fails.
function play_from_made(m, s_r, e_r, p, fresh)
  local dur = (e_r - s_r) / m.sr
  if m.s == s_r and m.e == e_r then
    start_preview(p, m.wav, dur, s_r / m.sr, (not fresh) and "replayed" or nil)
    return true
  end
  audition_count = audition_count + 1
  local piece = string.format("%s/reaats_audition_%s_%d.wav", (os.getenv("TMPDIR") or "/tmp"):gsub("/+$", ""), session_id, audition_count)
  local ok, err = wav_info.slice(m.wav, piece, s_r - m.s, e_r - s_r)
  if not ok then set_status("audition failed: " .. tostring(err)); return false end
  slice_history[#slice_history + 1] = piece
  if #slice_history > 3 then os.remove(table.remove(slice_history, 1)) end
  start_preview(p, piece, dur, s_r / m.sr, (not fresh) and "cut" or nil)
  return true
end

local function advance_pending()
  py_synth.sweep()
  local p = pending
  if not p then return end
  if not p.job.step(0.03) then
    local msg = string.format("preparing the %s ... %d %%", p.kind == "print" and "print" or "sound", math.floor(p.job.progress * 100))
    if p.kind == "print" then set_status(msg) else W.say_audition(msg) end            -- (the print's progress is still told)
    return
  end
  local job = p.job
  if job.cancelled then pending = nil; return end
  if p.engine == "Python" and job.error then                   -- the Python run failed: say so, then do it with the built-in synthesis
    local o = p.req.o
    p.note = job.error
    p.job = synth.render_multi_job(p.req.list, { sines = o.sines, noise = o.noise, from = o.from, to = o.to })
    p.engine = "Lua"
    set_status("Python synthesis failed (" .. job.error .. "): using the built-in synthesis")
    return
  end
  pending = nil
  p.gain_db = job.gain_db
  if p.kind == "print" then finish_print(p, job); return end
  if p.selection then                                           -- the sound of the selection: played, but not kept as "the sound made before"
    slice_history[#slice_history + 1] = p.wav
    if #slice_history > 3 then os.remove(table.remove(slice_history, 1)) end
    p.mode = "the selection only"
    start_preview(p, p.wav, job.dur, job.t_start, nil)
    return
  end
  local wav, dur, t_start = p.wav, nil, job.t_start
  if p.engine == "Python" then
    dur = job.dur
  else
    if not job.samples then set_status("audition failed: " .. tostring(job.error)); return end
    local ok, err
    local chans = job.channels
    if #chans > 2 then chans = synth.mix_to_stereo(chans) end    -- REAPER's preview is stereo: more channels are mixed down
    job.gain_db = synth.limit_peak((#chans > 1) and chans or { job.samples })      -- (turned down when over -1 dBFS)
    p.gain_db = job.gain_db
    if #chans > 1 then ok, err = synth.write_wav_channels(wav, chans, job.sr) else ok, err = synth.write_wav(wav, job.samples, job.sr) end
    if not ok then set_status("audition failed: " .. tostring(err)); return end
    dur = #job.samples / job.sr
  end
  -- this sound is now "the sound made before": AUDITION cuts its starts from it while nothing changes
  local sr = job.sr
  local s0 = math.floor((t_start or 0) * sr + 0.5)
  local nch = (p.engine == "Python") and job.nchan or math.min(#job.channels, 2)
  wav_history[#wav_history + 1] = wav
  if #wav_history > 2 then os.remove(table.remove(wav_history, 1)) end     -- (a sound of minutes is hundreds of MB: keep few)
  last_audition = { state = p.state, wav = wav, s = s0, e = s0 + math.floor(dur * sr + 0.5), nch = nch, sr = sr,
                    mode = p.mode, channels = p.channels, engine = p.engine, note = p.note, gain_db = p.gain_db }
  play_from_made(last_audition, p.span_s, p.span_e, p, true)
end

-- Writes the current data to `path` as a Csound-compatible .ats file, WITH phase (the phases of edited runs are
-- rebuilt from their frequencies first). Returns the path, or nil after a status message.
local function write_ats(path, verb)
  ats.update_phases(data, edited_cells)
  edited_cells = {}
  local ok, err = ats.save(path, data, { phase = true })
  if ok then
    modified = false
    data.front_frames = 0                                    -- (the file on disk has all the frames now)
    data.noise_touched = nil
    saved_depth, current_file = #undo_stack, path
    set_status((verb or "saved") .. " " .. (path:match("([^/\\]+)$") or path) .. " (with phase)")
    return path
  end
  set_status("save failed: " .. tostring(err))
end

-- Writes every channel of a set to the given names, one file per channel (each with its phases rebuilt first).
local function write_set(names, verb)
  capture_channel()
  local keep = cur
  for k = 1, #chs do
    switch_channel(k)
    if not write_ats(names[k], verb) then switch_channel(keep); return false end
  end
  switch_channel(keep)
  set_status(string.format("%s %d channels: %s ... %s", verb, #chs, names[1]:match("([^/\\]+)$") or names[1], names[#names]:match("([^/\\]+)$") or names[#names]))
  return true
end

-- The names name_ch1.ats ... for a set, from any name (a trailing _chK and the extension are dropped first).
local function set_names(path, count)
  local stem, ext = path:match("^(.*)(%.[^./\\]+)$")
  stem, ext = stem or path, ext or ".ats"
  stem = stem:gsub("_ch%d+$", "")
  local names = {}
  for k = 1, count do names[k] = string.format("%s_ch%d%s", stem, k, ext) end
  return names
end

-- Ctrl+S: saves next to the original as <name>_edit.ats (never overwrites; numbers further copies). A set is saved as a
-- whole, every channel, as <name>_edit_ch1.ats, <name>_edit_ch2.ats ... (so it opens as a set again).
local function save_file()
  if not data or not fname then return end
  W.commit()
  if #chs > 1 then
    local first = chs[1].fname
    local base = set_names(first, 1)[1]:gsub("_ch1%.[^./\\]+$", ""):gsub("_edit%d*$", "")
    local ext = first:match("(%.[^./\\]+)$") or ".ats"
    local n, names = 1, nil
    repeat
      names = {}
      for k = 1, #chs do names[k] = string.format("%s_edit%s_ch%d%s", base, n > 1 and tostring(n) or "", k, ext) end
      local exists = false
      for _, f in ipairs(names) do if reaper.file_exists(f) then exists = true end end
      n = n + 1
    until not exists
    if write_set(names, "saved") then return names[cur] end
    return nil
  end
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
  W.commit()
  local here = current_file or fname
  local dir = reaper.GetExtState(EXT_SECTION, "save_dir")
  if dir == "" then dir = here:match("^(.*)[/\\]") or "" end
  local stem = (here:match("([^/\\]+)$") or "sound.ats"):gsub("%.[^.]*$", ""):gsub("_ch%d+$", ""):gsub("_edit%d*$", "")
  local suggested = stem .. "_edit" .. ((#chs > 1) and "_ch1" or "") .. ".ats"
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
  local names = (#chs > 1) and set_names(path, #chs) or { path }
  for _, f in ipairs(names) do
    if reaper.file_exists(f) and reaper.MB("Replace this file?\n\n" .. f, "ReaATS: export .ats file", 4) ~= 6 then
      set_status("not exported (the file was kept)")
      return
    end
  end
  local ok
  if #chs > 1 then ok = write_set(names, "exported") else ok = write_ats(path, "exported") end
  if ok then
    reaper.SetExtState(EXT_SECTION, "save_dir", path:match("^(.*)[/\\]") or "", true)
  end
end

-- ------------------------------------------------------------------ print to track
-- Renders the current data (unsaved edits are saved first as <name>_edit.ats) to a permanent WAV next to the
-- .ats file and puts it on the selected track (or a new "ReaATS" track) at the edit cursor. This is the tool's
-- "generate" moment for the ReaSnap Integration Contract (piece 3): the settings that made the item are written
-- to the project under the item's GUID, so ReaSnap (or anything else) can bring them back.
local function build_state(ats_path, from, files)
  return {
    from = from or 0,                                           -- where in the sound this print starts (the playhead)
    file = ats_path,                                            -- the channel that was shown; opening it opens the whole set
    files = files,                                              -- every channel file of the set, in channel order
    channel = cur,
    name = (ats_path:match("([^/\\]+)$") or ats_path),
    view = { t0 = view.t0, t1 = view.t1, f0 = view.f0, f1 = view.f1 },
    partials = show_partials,
    noise = show_noise,
  }
end

local function print_to_track()
  if not data then return end
  W.commit()
  if pending and pending.kind == "print" then return end
  capture_channel()
  local unsaved = false
  for _, c in ipairs(chs) do if c.modified then unsaved = true end end
  local ats_path = current_file or fname
  if unsaved then
    ats_path = save_file()                                      -- (a set is saved as a whole)
    if not ats_path then return end
    capture_channel()
  end
  local files = {}
  for i, c in ipairs(chs) do files[i] = (i == cur) and current_file or c.current_file end
  stop_audition()                                              -- a sound that is still being prepared is dropped
  if pending then pending.job.cancel(); pending = nil end
  local stem = ats_path:gsub("%.[^./\\]+$", "")
  if #chs > 1 then stem = stem:gsub("_ch%d+$", "") end
  local n, wav = 1, nil
  repeat wav = string.format("%s_print%d.wav", stem, n); n = n + 1 until not reaper.file_exists(wav)
  local use_sines = show_partials
  local use_noise = show_noise and data.has_noise
  if not use_sines and not use_noise then set_status("nothing to print (partials and noise are both off)"); return end
  local mode = (use_sines and use_noise) and "sines + noise" or (use_sines and "sines" or "noise")
  local job, engine, req = start_synth(wav, { sines = use_sines, noise = use_noise, from = playhead, spatial = W.space_opts() })           -- from the playhead
  if engine == "Lua" and W.space_opts() then job.cancel(); set_status("P-STEREO and VBAP need the Python program (see ANALYSE): put SPACE on STEREO to use the built-in synthesis"); return end
  pending = { kind = "print", mode = mode, wav = wav, ats_path = ats_path, files = files, channels = #chs,
              engine = engine, req = req, job = job }
  set_status(playhead > 0.0005 and string.format("preparing the print FROM %.2f s (the playhead) ... 0 %%   Esc cancels, Home puts the playhead at the start", playhead)
                         or "preparing the print ... 0 %   (Esc cancels)")
end

-- The sound is ready (see advance_pending): write the WAV, put it on the track and remember the settings under the item.
finish_print = function(p, job)
  local nch, dur
  local wav, ats_path, mode = p.wav, p.ats_path, p.mode
  if p.engine == "Python" then                                 -- the program has written the WAV already
    nch, dur = job.nchan, job.dur
  else
    if not job.samples then set_status("print failed: " .. tostring(job.error)); return end
    local ok_w, err_w
    job.gain_db = synth.limit_peak((#job.channels > 1) and job.channels or { job.samples })      -- (turned down when over -1 dBFS)
    if #job.channels > 1 then ok_w, err_w = synth.write_wav_channels(wav, job.channels, job.sr) else ok_w, err_w = synth.write_wav(wav, job.samples, job.sr) end
    if not ok_w then set_status("print failed: " .. tostring(err_w)); return end
    nch, dur = #job.channels, #job.samples / job.sr
  end

  reaper.Undo_BeginBlock()
  local track = reaper.GetSelectedTrack(0, 0)
  if not track then
    reaper.InsertTrackAtIndex(reaper.CountTracks(0), true)
    track = reaper.GetTrack(0, reaper.CountTracks(0) - 1)
    reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "ReaATS", true)
  end
  reaper.SetOnlyTrackSelected(track)
  if nch > 1 then                                    -- the track needs room for every channel (an even number)
    local need = nch + (nch % 2)
    if (reaper.GetMediaTrackInfo_Value(track, "I_NCHAN") or 2) < need then reaper.SetMediaTrackInfo_Value(track, "I_NCHAN", need) end
  end
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
      local ok_enc, encoded = pcall(Serial.serialize, build_state(ats_path, job.t_start, p.files))
      if ok_enc then reaper.SetProjExtState(0, "ReaATS_ItemSettings", guid, encoded) end
    end
    local take = reaper.GetActiveTake(item)
    if take then reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "ReaATS " .. (wav:match("([^/\\]+)$") or wav), true) end
  end
  reaper.Undo_EndBlock("ReaATS print", -1)
  reaper.UpdateArrange()
  local limited = (job.gain_db and job.gain_db < -0.005) and string.format("; turned down %.1f dB to stay under -1 dBFS", -job.gain_db) or ""
  set_status(item and string.format("printed %.1f s from %.2f s (%s%s, %s synthesis%s) to the track", dur, job.t_start or 0, mode,
                                    nch > 1 and (", " .. nch .. " channels") or "", p.engine or "Lua", limited)
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

local function draw_noise(pw, ph, tint, alpha)
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
            if tint then gfx.set(tint[1], tint[2], tint[3], a * alpha) else gfx.set(0.85, 0.50, 0.15, a * alpha) end
            gfx.rect(x0, y0, x1 - x0, y1 - y0, 1)
          end
        end
      end
    end
  end
end

local function draw_partials(pw, ph, tint, alpha)
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
              if tint then
                local k = 0.30 + 0.70 * clamp((db - DB_FLOOR) / (-DB_FLOOR), 0, 1)     -- loud = bright, in the channel's colour
                gfx.set(tint[1] * k, tint[2] * k, tint[3] * k, alpha)
              else
                gfx.set(colormap(db))
                gfx.a = alpha
              end
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
  local tinted = view_mode == "overlay" and #on_list() >= 2
  for k, lane in ipairs(lane_layout(ph)) do
    gfx.setimgdim(k, pw, lane.h)
    gfx.dest = k
    gfx.set(0.055, 0.065, 0.085, 1)
    gfx.rect(0, 0, pw, lane.h, 1)
    if #lane.chans > 0 then
      draw_grid(pw, lane.h)
      if show_noise then
        for _, ci in ipairs(lane.chans) do
          as_channel(ci, function() draw_noise(pw, lane.h, tinted and tint_of(ci) or nil, chs[ci].vis) end)
        end
      end
      if show_partials then
        for _, ci in ipairs(lane.chans) do
          as_channel(ci, function() draw_partials(pw, lane.h, tinted and tint_of(ci) or nil, chs[ci].vis) end)
        end
      end
    end
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
  local lanes = lane_layout(ph)
  for _, lane in ipairs(lanes) do
    for _, f in ipairs({ 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000 }) do
      if f > view.f0 and f < view.f1 then
        local y = py + lane.off + fy(f, lane.h)
        local label = (f >= 1000) and (tostring(f // 1000) .. "k") or tostring(f)
        if lane.h > 40 or f == 100 or f == 1000 or f == 10000 then
          text_at(px - 8 - gfx.measurestr(label), y - 7, label, 0.65, 0.68, 0.72)
        end
        gfx.set(0.65, 0.68, 0.72, 0.8)
        gfx.line(px - 4, y, px, y)
      end
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
  for _, lane in ipairs(lanes) do gfx.rect(px, py + lane.off, pw, lane.h, 0) end
  if data then
    for _, lane in ipairs(lanes) do draw_note_scale(px, py + lane.off, pw, lane.h) end
    if #lanes > 1 then                                           -- stack: which channel each lane is
      gfx.setfont(1, "Arial", 13)
      for _, lane in ipairs(lanes) do
        local ci = lane.chans[1]
        local tc = tint_of(ci)
        text_at(px + 6, py + lane.off + 4, "ch " .. ci, tc[1], tc[2], tc[3])
      end
    end
  end
end

-- ----------------------------------------------------------------- playhead
local function end_time() return data.times[data.frames] end

-- Where the playhead is now: moving while a sound plays, otherwise where it was set. It goes back to its set place when
-- the sound has ended or is stopped.
local function playhead_now()
  if play then
    local now = reaper.time_precise()
    if now > play.t0 + play.dur + 0.05 then play = nil else return math.min(play.start + (now - play.t0), end_time()) end
  end
  return playhead
end

local function set_playhead(t)
  if not data then return end
  if play then stop_audition() end
  playhead = clamp(t, 0, end_time())
end

local function draw_playhead(px, py, pw, ph)
  if not data then return end
  local t = playhead_now()
  if t < view.t0 or t > view.t1 then return end
  local x = px + tx(t, pw)
  local moving = play ~= nil
  gfx.set(1, moving and 0.95 or 0.85, moving and 0.4 or 0.25, 1)
  gfx.rect(x - 1, py, 2, ph, 1)
  gfx.rect(x - 5, py + ph + 1, 11, 7, 1)                       -- the marker on the time ruler
  gfx.rect(x - 3, py + ph + 8, 7, 3, 1)
  gfx.setfont(1, "Arial", 13)
  local label = string.format("%.3f s", t)
  local lw = gfx.measurestr(label)
  local lx = math.min(x + 6, px + pw - lw - 4)
  gfx.set(0.09, 0.10, 0.12, 0.85)
  gfx.rect(lx - 3, py + 2, lw + 6, 17, 1)
  text_at(lx, py + 3, label, 1, 0.9, 0.45)
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
  local dx, dy = mover.ex, mover.ey
  if mover.axis == "x" then dy = 0 elseif mover.axis == "y" then dx = 0 end
  local span = view.t1 - view.t0
  local frame_dt = (data.times[data.frames] - data.times[1]) / math.max(data.frames - 1, 1)
  local df = math.floor(dx / pw * span / frame_dt + 0.5)
  local ratio = math.exp(-dy / ph * (LOG(view.f1) - LOG(view.f0)))
  return df, ratio, df * frame_dt / span * pw, dy, frame_dt
end

-- Selected points (bright pink), the move ghost and the rubber-band box, drawn on the screen each frame.
local function draw_selection(px, py, pw, ph)
  if not data then return end
  for _, lane in ipairs(lane_layout(ph)) do
    for _, ci in ipairs(lane.chans) do
      as_channel(ci, function()
        if not sel_info then return end
        draw_sel_points(px, py + lane.off, pw, lane.h, 0, 0, 1, 0.35, 0.75, mover and 0.35 or 1)
        if mover and mover.active then
          local _, _, ox, oy = mover_delta(pw, mover.h or ph)
          draw_sel_points(px, py + lane.off, pw, lane.h, ox, oy, 1, 0.9, 0.95, 0.95)
        end
      end)
    end
  end
  if lasso and #lasso.pts > 1 then                              -- the loop being drawn, closed with a faint line back to the start
    gfx.set(1, 1, 1, 0.9)
    local function cx(x) return clamp(x, px, px + pw) end                                     -- (the start may be scrolled out of the picture)
    for i = 2, #lasso.pts do gfx.line(cx(lasso.pts[i - 1][1]), lasso.pts[i - 1][2], cx(lasso.pts[i][1]), lasso.pts[i][2], 1) end
    gfx.set(1, 1, 1, 0.35)
    gfx.line(cx(lasso.pts[#lasso.pts][1]), lasso.pts[#lasso.pts][2], cx(lasso.pts[1][1]), lasso.pts[1][2], 1)
  end
  if box then
    local x0, x1 = math.min(box.x0, box.x1), math.max(box.x0, box.x1)
    x0, x1 = clamp(x0, px, px + pw), clamp(x1, px, px + pw)                                 -- (the start may be scrolled out of the picture)
    local y0, y1 = math.min(box.y0, box.y1), math.max(box.y0, box.y1)
    gfx.set(1, 1, 1, 0.10)
    gfx.rect(x0, y0, x1 - x0, y1 - y0, 1)
    gfx.set(1, 1, 1, 0.8)
    gfx.rect(x0, y0, x1 - x0, y1 - y0, 0)
  end
end

-- The crosshair while something is dragged (a move, a box, a lasso): thin lines through the pointer with what is there. For a move the
-- lines are where the points really go (after Shift's fine movement and Ctrl's one axis), a faint cross marks where the drag began, and
-- the line of the axis that Ctrl keeps is drawn in colour.
local function draw_crosshair(px, py, pw, ph)
  if not data or not ((mover and mover.active) or box or lasso) then return end
  local mx, my = clamp(gfx.mouse_x, px, px + pw), clamp(gfx.mouse_y, py, py + ph)
  local label
  if mover then
    local df, ratio = mover_delta(pw, mover.h or ph)
    local ax = mover.axis
    local dx, dy = (ax == "y") and 0 or mover.ex, (ax == "x") and 0 or mover.ey
    gfx.set(1, 1, 1, 0.16)                                                  -- where the drag began
    gfx.line(mover.x0, py, mover.x0, py + ph, 1)
    gfx.line(px, mover.y0, px + pw, mover.y0, 1)
    if ax == "x" then gfx.set(0.3, 0.9, 1, 0.8); gfx.line(px, mover.y0, px + pw, mover.y0, 1)          -- the frequency stays
    elseif ax == "y" then gfx.set(0.3, 0.9, 1, 0.8); gfx.line(mover.x0, py, mover.x0, py + ph, 1) end   -- the time stays
    mx, my = clamp(mover.x0 + dx, px, px + pw), clamp(mover.y0 + dy, py, py + ph)
    label = string.format("%+d frames   %+.2f st%s", df, 12 * math.log(ratio, 2),
                          ax == "x" and "   (time only)" or ax == "y" and "   (frequency only)" or "")
  else
    local lane = lane_at(py, ph, my)
    if not lane then return end
    local t = view.t0 + (mx - px) / pw * (view.t1 - view.t0)
    local f = view.f0 * (view.f1 / view.f0) ^ ((py + lane.off + lane.h - my) / lane.h)
    label = string.format("%.3f s   %s (%s)", t, fmt_freq(f), ats.note_name(f))
  end
  gfx.set(1, 1, 1, 0.55)
  gfx.line(mx, py, mx, py + ph, 1)
  gfx.line(px, my, px + pw, my, 1)
  gfx.setfont(1, "Arial", 13)
  local w = gfx.measurestr(label)
  local bx = (mx + 16 + w + 8 < gfx.w) and (mx + 14) or (mx - 14 - w - 8)
  local by = (my + 34 < py + ph) and (my + 14) or (my - 30)
  gfx.set(0.05, 0.06, 0.08, 0.85)
  gfx.rect(bx, by, w + 10, 18, 1)
  text_at(bx + 5, by + 2, label, 0.95, 0.95, 0.8)
end

-- True when the mouse is within a few pixels of a selected point (in the lane under it); also gives that lane's height.
local function hit_selected(px, py, pw, ph, mx, my)
  local lane = lane_at(py, ph, my)
  if not lane then return false end
  for _, ci in ipairs(lane.chans) do
    local hit = false
    as_channel(ci, function()
      if not sel_info then return end
      for p, frames in pairs(sel) do
        local frq = data.frq[p]
        for f in pairs(frames) do
          local x = px + tx(data.times[f], pw)
          if math.abs(x - mx) <= 7 then
            local y = py + lane.off + fy(frq[f], lane.h)
            if math.abs(y - my) <= 7 then hit = true; return end
          end
        end
      end
    end)
    if hit then return true, lane.h end
  end
  return false
end

-- ------------------------------------------------------------ the box and its handles (the "rubber sheet")
-- The selection has a box round it, with a dot in each corner and the middle of every edge free to be dragged: the dots bend the box, and
-- the selected points follow it (lib/ats_warp.lua has the maths). Drag a corner dot or a border dot up or down; drag an edge between the
-- dots to move the whole edge; Ctrl+click on an edge adds a border dot, right-click on a border dot removes it, Ctrl+Shift+drag on an edge arches it,
-- Shift makes the movement fine. Nothing is changed in the data until Enter applies it (Esc, Ctrl+R: back to flat). Frequency only for now.
function W.sel_info_of(i) return (i == cur) and sel_info or chs[i].sel_info end
function W.sel_of(i) return (i == cur) and sel or chs[i].sel end

function W.set_region(ta, tb, fa, fb, add)
  W.w = nil
  if ta > tb then ta, tb = tb, ta end
  if fa > fb then fa, fb = fb, fa end
  local base = add and W.current_region() or nil
  if base then ta, tb, fa, fb = math.min(ta, base.t0), math.max(tb, base.t1), math.min(fa, base.f0), math.max(fb, base.f1) end
  W.region = { t0 = ta, t1 = tb, f0 = fa, f1 = fb }
end

-- The box: the one the selection was made with (W.region), except its t0/t1 are replaced with the exact span of the selected
-- frames when there are any -- so u is exactly 0/1 at the true edge of the data plan_warp itself will move, not wherever the mouse
-- happened to be when the drag started. The frequency range (f0/f1) keeps using the raw drag rectangle as before: frequency is
-- continuous (no frame grid to miss), so there is nothing there for a mismatch to silently drop.
-- Using W.region's raw time whenever it existed used to leave every row's own first selected frame at a small but nonzero u: its
-- real anchor is where ITS data starts, not where the mouse was, so any stretch already moved it a little, away from the still-
-- fixed, un-selected frame right before it -- a gap at exactly the old selection border, on every row alike (tjingboem, 10 Nov 2026,
-- a third screenshot after the ripple fix, diagnosing it directly: "the border itself is not the anchor point ... anchor points for
-- each partial just inside the selection ... should stretch as well to close the gap ... making this anchor point a joint point").
function W.current_region()
  local t0, t1, f0, f1 = math.huge, -math.huge, math.huge, 0
  for i, c in ipairs(chs) do
    local si = W.sel_info_of(i)
    if c.on and c.edit and si then
      t0, t1, f0, f1 = math.min(t0, si.t0), math.max(t1, si.t1), math.min(f0, si.f0), math.max(f1, si.f1)
    end
  end
  if t0 == math.huge or not data then return W.region end
  local dt = (data.times[data.frames] - data.times[1]) / math.max(data.frames - 1, 1)
  if t1 - t0 < dt then local m = (t0 + t1) / 2; t0, t1 = m - dt / 2, m + dt / 2 end
  if W.region then f0, f1 = W.region.f0, W.region.f1 end
  if f1 / f0 < 1.06 then local m = math.sqrt(f0 * f1); f0, f1 = m / 1.03, m * 1.03 end
  return { t0 = t0, t1 = t1, f0 = f0, f1 = f1 }
end

function W.get()
  if not W.w then
    local r = W.current_region()
    if not r then return nil end
    -- The box's own t0/t1/f0/f1 are the exact extent of the selected points: plan_warp maps every selected frame through them, so if
    -- this were padded out to a minimum size (as it used to be, for narrow selections), frames right at the true edge would sit at a
    -- fractional u/v instead of exactly 0/1 and pick up a sliver of unintended displacement -- some of them then land outside the
    -- destination range plan_warp computes from the (now shifted) mapped times, while plan_warp still silences their SOURCE cells
    -- unconditionally: a real gap, right where the selection border was, that stretching could not be undone. A minimum on-screen size
    -- for grabbable dots is still needed (one partial, a few frames, would draw them on top of each other) -- W.geo now does that purely
    -- in pixel space, leaving the box's own t0/t1/f0/f1 (and so the warp math) untouched.
    W.w = W.m.new(r.t0, r.t1, r.f0, r.f1)
  end
  return W.w
end

-- ------------------------------------------------------------ max partials (tjingboem, 10 Nov 2026)
-- A plain button, not a custom-drawn slider: three different slider designs in a row (in the plot, at the plot's own top, up in
-- the header) never rendered at all for tjingboem despite every one of them working in a from-scratch reproduction of the real
-- input/draw code against real data (lib/ats_edit.lua's rank_partials/plan_keep_loudest are fine, and tested; this was purely the
-- ATS_Editor.lua-side widget) -- including a version that drew an unconditional, oversized, solid-colour bar across the entire top
-- of the window, confirmed (by recording every gfx.rect call) to actually fire in a plain reproduction, and confirmed functionally
-- dead (no status change on click either) after closing every open window and fully restarting REAPER, ruling out a stale window
-- and a stale script load. Rather than keep chasing an unreproducible rendering difference, this uses only mechanisms already
-- proven to render and respond in that exact session: a button drawn exactly like PRINT/EXPORT/ANALYSE, and REAPER's own text
-- dialog (reaper.GetUserInputs), the same one Export/Save already use. No live drag, no dimmed preview -- type a count, it applies
-- right away, one undo step.
-- Ranks every channel's ACTUAL selected cells (sel[p][f], exactly what plan_move/plan_warp/delete_single etc. all operate on) --
-- not a time/frequency bounding box: a first version ranked (and so silenced) a whole continuous run wherever it merely PASSED
-- THROUGH the selection's box, which could reach far outside it in time -- a partial sustained from well before the selection to
-- well after lost its entire length, not just the selected stretch of it, the moment it was not among the ones kept (tjingboem,
-- 10 Nov 2026, with screenshots: "also outside the selection on the left things were removed, as if that was part of the
-- selection... only the selection should be affected"). Using sel itself instead means a dropped run can only ever be silenced
-- where it was actually highlighted, the same guarantee every other edit in this file already gives.
function W.pk_ranks()
  local per, max_count = {}, 0
  for _, i in ipairs(on_channels()) do
    local s = W.sel_of(i)
    if s and next(s) then
      local runs = edit.rank_partials(chs[i].data, s)
      per[i] = runs
      if #runs > max_count then max_count = #runs end
    end
  end
  if max_count == 0 then return nil end
  return { per = per, max = max_count }
end

-- Asks how many partials to keep (positive: that many loudest; negative: that many weakest) and applies it right away, as one
-- undo group across every channel with a ranking in the box's own region. plan_keep_loudest always keeps the FRONT of the list
-- it is given, loudest-first ranked -- keeping the weakest instead just hands it that list reversed (quietest-first), so lib/
-- ats_edit.lua needs no separate "weak" mode of its own.
function W.pk_apply()
  local ranks = W.pk_ranks()
  if not ranks then set_status("nothing selected to thin"); return end
  local ok, text = reaper.GetUserInputs("Max partials", 1,
    string.format("keep this many loudest (negative: weakest instead; up to %d here),extrawidth=60", ranks.max), "")
  if not ok then return end
  local n = tonumber(text)
  if not n then set_status("max partials: not a number"); return end
  local weak = n < 0
  n = math.floor(math.abs(n) + 0.5)
  group_counter = group_counter + 1
  edit_group = group_counter
  local dropped, touched = 0, 0
  for i, runs in pairs(ranks.per) do
    with_channel(i, function()
      local use = runs
      if weak then
        local rev = {}
        for k = #runs, 1, -1 do rev[#rev + 1] = runs[k] end
        use = rev
      end
      local plan = edit.plan_keep_loudest(data, use, n)
      if plan then
        do_edit("max partials", plan.changes)
        dropped, touched = dropped + plan.dropped, touched + 1
      end
    end)
  end
  edit_group = nil
  if touched > 0 then
    set_status(string.format("kept the %d %s, silenced %d%s", n, weak and "weakest" or "loudest", dropped,
                              touched > 1 and (" (" .. touched .. " channels)") or ""))
  else
    set_status("max partials: nothing to silence at that count")
  end
end

-- The button's own rectangle: bottom left, where the two keyboard-shortcut hint lines used to be (removed as unreadable clutter,
-- tjingboem 10 Nov 2026). A field of W, like W.pk_ranks/W.pk_apply, rather than its own local: this file is already at Lua's
-- 200-local-variable limit for its main chunk (see the comment near "local W =" above), so a plain new local here fails to compile.
function W.max_partials_rect() return W.lay("btn_maxpart_s") end

function W.draw_max_partials_button()
  local x, y, w, h = W.max_partials_rect()
  local enabled = any_sel()
  gfx.set(enabled and 0.20 or 0.15, enabled and 0.38 or 0.17, enabled and 0.42 or 0.19, 1)
  gfx.rect(x, y, w, h, 1)
  gfx.set(enabled and 0.45 or 0.3, enabled and 0.92 or 0.34, enabled and 1 or 0.37, 1)
  gfx.rect(x, y, w, h, 0)
  gfx.setfont(1, "Arial", 13)
  local label = "MAX PARTIALS"
  gfx.set(enabled and 1 or 0.42, enabled and 1 or 0.44, enabled and 1 or 0.46, 1)
  gfx.x = x + (w - gfx.measurestr(label)) / 2
  gfx.y = y + 2
  gfx.drawstr(label)
end

-- SPATIAL OUTPUT (tjingboem 10 Nov 2026: "we still need pseudo stereo and VBAP as we have in SpectralTransfer"): the sound's partials and
-- noise bands are divided over the outputs by the Python synthesis. SPACE cycles STEREO (as before) / P-STEREO (odd partials left, even right)
-- / VBAP (panned over 2-8 outputs); the slider is the amount (P-STEREO) or the spread (VBAP); the OUT box (VBAP) is the number of outputs.
-- AUDITION is always stereo (a VBAP sound is mixed down to two); PRINT writes every output as a channel. The state is in W (the main chunk is
-- at Lua's 200-local limit) and is remembered between sessions.
W.space_names = { "STEREO", "P-STEREO", "VBAP" }
W.space = { mode = 1, amount = 1.0, channels = 4 }
do
  local raw = reaper.GetExtState(EXT_SECTION, "space")
  local m, a, c = tostring(raw):match("^(%d)|([%d%.]+)|(%d)$")
  if m then W.space.mode, W.space.amount, W.space.channels = math.min(math.max(tonumber(m), 1), 3), math.min(math.max(tonumber(a), 0), 1), math.min(math.max(tonumber(c), 2), 8) end
end
function W.space_save()
  reaper.SetExtState(EXT_SECTION, "space", string.format("%d|%.3f|%d", W.space.mode, W.space.amount, W.space.channels), true)
end
function W.space_opts()                                         -- what the synthesis needs, or nil for plain stereo
  local sp = W.space
  if sp.mode == 1 then return nil end
  return { mode = sp.mode == 2 and "pseudo" or "vbap", amount = sp.amount, channels = sp.channels }
end
function W.space_key()                                          -- part of the key of a sound that can be played again
  local o = W.space_opts()
  return o and string.format("%s%.3f%d", o.mode, o.amount, o.channels) or "-"
end
function W.space_rects()
  return { button = { W.lay("btn_space_s") }, slider = { W.lay("space_slider_s") }, out = { W.lay("space_out_s") }, pct = { W.lay("space_pct_s") } }
end
-- The name of the first state: the sound comes out with the channels it was analysed in (one for a single file), so it says how many.
function W.space_label(mode)
  if mode == 1 then return (#chs == 1) and "1 channel" or (#chs .. " channels") end
  return W.space_names[mode]
end
function W.draw_space()
  local r, sp = W.space_rects(), W.space
  local on = sp.mode > 1                                         -- (the slider belongs to P-STEREO and VBAP: dim in the first state)
  local x, y, w, h = table.unpack(r.button)
  if sp.mode == 1 then gfx.set(0.18, 0.27, 0.36, 1)
  else gfx.set(sp.mode == 2 and 0.30 or 0.12, sp.mode == 2 and 0.26 or 0.28, sp.mode == 2 and 0.12 or 0.34, 1) end
  gfx.rect(x, y, w, h, 1)
  if sp.mode == 1 then gfx.set(0.55, 0.72, 0.95, 1)
  elseif sp.mode == 2 then gfx.set(0.95, 0.75, 0.35, 1)
  else gfx.set(0.45, 0.85, 1, 1) end
  gfx.rect(x, y, w, h, 0)
  local label = W.space_label(sp.mode)
  W.fit(label, w, 13)
  gfx.x = x + (w - gfx.measurestr(label)) / 2
  gfx.y = y + 2
  gfx.drawstr(label)
  local sx, sy, sw, sh = table.unpack(r.slider)
  gfx.set(0.14, 0.16, 0.19, on and 1 or 0.5)
  gfx.rect(sx, sy, sw, sh, 1)
  gfx.set(on and 0.55 or 0.3, on and 0.72 or 0.34, on and 0.95 or 0.38, 1)
  gfx.rect(sx, sy, sw * sp.amount, sh, 1)
  gfx.rect(sx, sy, sw, sh, 0)
  gfx.setfont(1, "Arial", 11)
  gfx.set(0.7, 0.74, 0.8, on and 1 or 0.5)
  gfx.x, gfx.y = r.pct[1], r.pct[2]
  gfx.drawstr(string.format("%s %d%%", sp.mode == 3 and "spread" or "width", math.floor(sp.amount * 100 + 0.5)))
  if sp.mode == 3 then
    local ox, oy, ow, oh = table.unpack(r.out)
    gfx.set(0.18, 0.2, 0.23, 1)
    gfx.rect(ox + 36, oy, ow - 36, oh, 1)
    gfx.set(0.45, 0.85, 1, 1)
    gfx.rect(ox + 36, oy, ow - 36, oh, 0)
    gfx.setfont(1, "Arial", 13)
    gfx.x, gfx.y = ox, oy + 2
    gfx.drawstr("OUT")
    gfx.x, gfx.y = ox + 44, oy + 2
    gfx.drawstr(tostring(sp.channels))
  end
end
-- A click on the SPACE controls. Returns true when it was one (and starts the slider drag).
function W.space_click(mx, my, cap)
  local r, sp = W.space_rects(), W.space
  local function inside(rc) return mx >= rc[1] and mx < rc[1] + rc[3] and my >= rc[2] and my < rc[2] + rc[4] end
  if inside(r.button) then
    sp.mode = sp.mode % 3 + 1
    W.space_save()
    set_status(sp.mode == 1 and ("output: " .. W.space_label(1) .. ", as analysed") or (sp.mode == 2 and "output: pseudo-stereo (odd partials left, even right); AUDITION and PRINT make it with the Python program"
      or string.format("output: VBAP over %d outputs (AUDITION mixes it down to stereo, PRINT writes %d channels)", sp.channels, sp.channels)))
    return true
  elseif inside({ r.slider[1] - 3, r.slider[2] - 4, r.slider[3] + 6, r.slider[4] + 8 }) then
    W.space_drag = true
    W.space_to(mx)
    return true
  elseif sp.mode == 3 and inside(r.out) then
    sp.channels = ((cap & 2) ~= 0) and (sp.channels <= 2 and 8 or sp.channels - 1) or (sp.channels >= 8 and 2 or sp.channels + 1)
    W.space_save()
    set_status(string.format("VBAP over %d outputs (click: more, right-click: fewer)", sp.channels))
    return true
  end
  return false
end
function W.space_to(mx)
  local r = W.space_rects()
  W.space.amount = math.min(math.max((mx - r.slider[1]) / r.slider[3], 0), 1)
  W.space_save()
  dirty = true
end

-- GAIN OF THE SELECTION (tjingboem 11 Nov 2026: "if we have a selection, we could do right-click to open up a slider for gain in dB. +-20dB should be
-- enough"): a right-click (no drag) with a selection opens a small slider at the pointer. Drag it, or Up/Down for 0.5 dB, Enter or APPLY changes the
-- amplitude of the selected points of every green channel by that many dB (one undo step); Esc, CANCEL or a click outside leaves everything as it was.
-- The sines only: the noise bands are not touched. W.gain = { x, y, db, drag } while it is open (it takes every click and key).
W.GAIN_MAX = 20
function W.gain_open(mx, my)
  W.gain = { x = clamp(mx - 130, 4, math.max(math.floor(gfx.w) - 264, 4)), y = clamp(my - 24, 4, math.max(math.floor(gfx.h) - 84, 4)), db = 0 }
  dirty = true
end
function W.gain_rects()
  local g = W.gain
  return { box = { g.x, g.y, 260, 80 }, track = { g.x + 16, g.y + 34, 228, 10 },
           reset = { g.x + 16, g.y + 54, 56, 18 }, cancel = { g.x + 120, g.y + 54, 62, 18 }, apply = { g.x + 188, g.y + 54, 56, 18 } }
end
function W.gain_single(db)
  if not sel_info then return end
  local k = 10 ^ (db / 20)
  local changes = {}
  for p, frames in pairs(sel) do
    for f in pairs(frames) do
      local a = data.amp[p][f]
      if a > 0 then changes[#changes + 1] = { p = p, f = f, oa = a, na = a * k, of = data.frq[p][f], nf = data.frq[p][f] } end
    end
  end
  if #changes == 0 then return end
  do_edit(string.format("gain %+.1f dB", db), changes)
  update_sel_info()
end
function W.gain_apply()
  local db = W.gain.db
  W.gain = nil
  dirty = true
  if math.abs(db) < 0.05 then set_status("gain: 0 dB, nothing changed"); return end
  edit_on_channels(function() W.gain_single(db) end, string.format("gain %+.1f dB", db))
end
function W.gain_to(mx)
  local r = W.gain_rects().track
  local db = (math.min(math.max((mx - r[1]) / r[3], 0), 1) * 2 - 1) * W.GAIN_MAX
  db = math.floor(db * 10 + 0.5) / 10
  if math.abs(db) < 0.4 then db = 0 end                                   -- (it sticks at 0 dB)
  W.gain.db = db
  dirty = true
end
-- Mouse and key while the slider is open. Returns nothing; the caller does not handle the input any further.
function W.gain_input(mx, my, cap, ch)
  local g, r = W.gain, W.gain_rects()
  local function inside(rc, pad) pad = pad or 0; return mx >= rc[1] - pad and mx < rc[1] + rc[3] + pad and my >= rc[2] - pad and my < rc[2] + rc[4] + pad end
  local down = (cap & 1) ~= 0
  if ch == 27 then W.gain = nil; dirty = true; set_status("gain cancelled"); return end
  if ch == 13 then W.gain_apply(); return end
  if ch == 30064 then g.db = math.min(g.db + 0.5, W.GAIN_MAX); dirty = true
  elseif ch == 1685026670 then g.db = math.max(g.db - 0.5, -W.GAIN_MAX); dirty = true end
  if down and not prev_down then
    if inside(r.track, 6) then g.drag = true; W.gain_to(mx)
    elseif inside(r.reset) then g.db = 0; dirty = true
    elseif inside(r.apply) then W.gain_apply()
    elseif inside(r.cancel) or not inside(r.box) then W.gain = nil; dirty = true; set_status("gain cancelled") end
  elseif down and g.drag then
    W.gain_to(mx)
  end
  if not down then g.drag = nil end
end
function W.draw_gain()
  local g = W.gain
  if not g then return end
  local r = W.gain_rects()
  local bx, by, bw, bh = table.unpack(r.box)
  gfx.set(0.10, 0.11, 0.14, 0.97)
  gfx.rect(bx, by, bw, bh, 1)
  gfx.set(0.55, 0.68, 0.92, 1)
  gfx.rect(bx, by, bw, bh, 0)
  gfx.setfont(1, "Arial", 13)
  gfx.set(0.9, 0.92, 0.96, 1)
  gfx.x, gfx.y = bx + 16, by + 8
  gfx.drawstr("Gain of the selection")
  local label = string.format("%+.1f dB", g.db)
  gfx.set(1, 0.9, 0.5, 1)
  gfx.x, gfx.y = bx + bw - 16 - gfx.measurestr(label), by + 8
  gfx.drawstr(label)
  local tx0, ty, tw, th = table.unpack(r.track)
  gfx.set(0.16, 0.18, 0.22, 1)
  gfx.rect(tx0, ty, tw, th, 1)
  gfx.set(0.4, 0.43, 0.48, 1)
  gfx.rect(tx0 + tw // 2, ty - 3, 1, th + 6, 1)                           -- the 0 dB mark
  local frac = (g.db / W.GAIN_MAX + 1) / 2
  gfx.set(0.45, 0.62, 0.95, 0.6)
  if frac >= 0.5 then gfx.rect(tx0 + tw // 2, ty, tw * (frac - 0.5), th, 1) else gfx.rect(tx0 + tw * frac, ty, tw * (0.5 - frac), th, 1) end
  gfx.set(1, 1, 1, 0.95)
  gfx.rect(tx0 + math.floor((tw - 3) * frac), ty - 2, 3, th + 4, 1)
  gfx.set(0.35, 0.38, 0.43, 1)
  gfx.rect(tx0, ty, tw, th, 0)
  gfx.setfont(1, "Arial", 11)
  gfx.set(0.6, 0.64, 0.7, 1)
  gfx.x, gfx.y = tx0, ty + 12; gfx.drawstr("-20")
  gfx.x, gfx.y = tx0 + tw - gfx.measurestr("+20"), ty + 12; gfx.drawstr("+20")
  local function button(rc, text, rgb)
    gfx.set(rgb[1] * 0.4, rgb[2] * 0.4, rgb[3] * 0.4, 1)
    gfx.rect(rc[1], rc[2], rc[3], rc[4], 1)
    gfx.set(rgb[1], rgb[2], rgb[3], 1)
    gfx.rect(rc[1], rc[2], rc[3], rc[4], 0)
    gfx.setfont(1, "Arial", 12)
    gfx.x, gfx.y = rc[1] + (rc[3] - gfx.measurestr(text)) / 2, rc[2] + 2
    gfx.drawstr(text)
  end
  button(r.reset, "0 dB", { 0.7, 0.72, 0.78 })
  button(r.cancel, "CANCEL", { 0.9, 0.55, 0.5 })
  button(r.apply, "APPLY", { 0.45, 0.85, 0.6 })
  gfx.setfont(1, "Arial", 14)
end

-- AUDITION of the selection only (A with a selection): only the selected points sound, from just before the first to just after the last
-- frame of the selection (the sines only, in the SPACE output; no noise). Always made by the Python program, always made again.
function W.audition_selection()
  if not data then return end
  W.commit()
  capture_channel()
  local t0, t1
  for _, c in ipairs(chs) do
    local si = c.sel_info
    if si then t0 = math.min(t0 or si.t0, si.t0); t1 = math.max(t1 or si.t1, si.t1) end
  end
  if not t0 then return false end
  if pending and pending.kind == "print" then set_status("wait: the print is being prepared"); return true end
  stop_audition()
  local hop = chs[1].data.frame_size / chs[1].data.sr
  local from, to = math.max(t0 - hop, 0), t1 + hop
  audition_count = audition_count + 1
  local wav = string.format("%s/reaats_audition_%s_%d.wav", tmp_dir(), session_id, audition_count)
  local sp = W.space_opts()
  local job, engine, req = start_synth(wav, { sines = true, noise = false, from = from, to = to, selection = true,
                                              mixdown = (#chs > 2 or (sp and sp.channels > 2)) and "stereo" or nil, spatial = sp })
  if engine ~= "Python" then
    job.cancel()
    set_status("AUDITION of the selection needs the Python program (see ANALYSE)")
    return true
  end
  pending = { kind = "audition", selection = true, mode = "the selection only", channels = #chs, wav = wav, engine = engine, req = req, job = job }
  W.say_audition("preparing the selection ... 0 %")
  return true
end

-- EDGE-SCROLL (tjingboem 11 Nov 2026: "all three of them"): while a box, a lasso or a move is dragged with the pointer in the last stretch of the
-- picture (or beyond it), the view scrolls on, faster the further in, as it does for the bend box. The view goes on only as far as the file does (so a drag
-- to the edge of a picture that shows the whole file does not move it). Returns how many pixels the picture moved (the dragged things are kept in place by the caller).
-- `right_ok` / `left_ok`: the drag may go on that way (a drag that began in the edge zone and goes the other way does not scroll there).
-- `beyond`: the view may go past the ends of the file, by the room the file may grow into (a move: the file gets longer there).
function W.edge_scroll(mx, right_ok, left_ok, beyond)
  if not data then return 0 end
  local px0, _, pw0 = plot_rect()
  local zone = math.max(48, 0.08 * pw0)
  local right, left = px0 + pw0 - zone, px0 + zone
  local span = view.t1 - view.t0
  local tmax = data.times[data.frames] or data.dur
  local lo, hi = 0, tmax                                                  -- (only as far as the file goes: nothing to select beyond it)
  if beyond then lo, hi = -tmax, 2 * tmax end                            -- (a move makes the file longer: as far as the room goes)
  local scroll = 0
  if mx > right and right_ok then scroll = span * 0.012 * clamp((mx - right) / zone, 0, 2.5)
  elseif mx < left and left_ok then scroll = -span * 0.012 * clamp((left - mx) / zone, 0, 2.5) end
  if scroll > 0 and view.t1 + scroll > hi then scroll = math.max(hi - view.t1, 0) end
  if scroll < 0 and view.t0 + scroll < lo then scroll = math.min(lo - view.t0, 0) end
  if scroll == 0 then return 0 end
  view.t0, view.t1 = view.t0 + scroll, view.t1 + scroll
  dirty = true
  return scroll / span * pw0
end

-- Z: the view goes to the selection, with some room round it (a quarter of its size at each side, at least a little).
function W.zoom_selection()
  if not data then return end
  capture_channel()
  local t0, t1, f0, f1
  for _, c in ipairs(chs) do
    local si = c.sel_info
    if si then
      t0 = math.min(t0 or si.t0, si.t0); t1 = math.max(t1 or si.t1, si.t1)
      f0 = math.min(f0 or si.f0, si.f0); f1 = math.max(f1 or si.f1, si.f1)
    end
  end
  if not t0 then set_status("Z zooms to the selection: select something first"); return end
  local hop = chs[1].data.frame_size / chs[1].data.sr
  local pad_t = math.max((t1 - t0) * 0.25, hop * 8, 0.02)
  view.t0, view.t1 = math.max(t0 - pad_t, -pad_t), t1 + pad_t
  local l0, l1 = math.log(math.max(f0, 1)), math.log(math.max(f1, 1.01))
  local pad_f = math.max((l1 - l0) * 0.25, math.log(2) * 0.2)
  view.f0 = math.max(5, math.exp(l0 - pad_f))
  view.f1 = math.min(40000, math.exp(l1 + pad_f))
  dirty = true
end

-- Applies the bend to the selected points of every channel that is on and green (one undo step), and opens a flat box round them.
-- Applies the plans of every channel in one undo group, making the file (every channel of the set, so that they stay equally long) longer
-- at the end and in front by what the plans need. plans[i] / nplans[i]: the sine and the noise plan of channel i (or nil). The cells of a plan
-- are numbered from the old first frame: when frames go in front they are later by that many. Used by the bend box, a move and a paste.
function W.apply_grown(label, plans, nplans, need_end, need_front)
  need_end = math.max(need_end, chs[1].data.frames)
  -- 2. one undo group: every channel gets its own entry (the edit, or just the longer file). The frames in front move all the numbers.
  W.busy = true
  group_counter = group_counter + 1
  edit_group = group_counter
  local dropped, frames_before, dur_before, any_noise = 0, chs[1].data.frames, chs[1].data.dur, false
  local hop = chs[1].data.frame_size / chs[1].data.sr
  for i = 1, #chs do
    with_channel(i, function()
      local plan, np = plans[i], nplans[i]
      local has_plan, has_noise = plan and #plan.changes > 0, np and #np.changes > 0
      if has_noise then any_noise = true end
      local total = need_end + need_front
      local ext = (need_front > 0 or total > data.frames) and { front = need_front, frames_after = total } or nil
      if has_plan or has_noise then
        if need_front > 0 then                                          -- the cells of the plans are numbered from the old first frame: later by the frames in front
          if has_plan then
            for _, c in ipairs(plan.changes) do c.f = c.f + need_front end
            local moved = {}
            for p, frames in pairs(plan.sel) do
              local row = {}
              for f in pairs(frames) do row[f + need_front] = true end
              moved[p] = row
            end
            plan.sel = moved
          end
          if has_noise then for _, c in ipairs(np.changes) do c.f = c.f + need_front end end
        end
        do_edit(label, has_plan and plan.changes or {}, has_plan and plan.rows_before or nil, has_plan and plan.rows_after or nil, ext, has_noise and np.changes or nil)
        if has_plan then
          sel = plan.sel
          update_sel_info()
          dropped = dropped + plan.dropped
        end
      elseif ext then
        do_extend_only(label, total, need_front)
      end
    end)
  end
  edit_group = nil
  W.busy = false
  W.region = nil
  if need_front > 0 then                                                -- what was shown stays where it was: the data is later by the frames in front
    view.t0, view.t1, playhead = view.t0 + need_front * hop, view.t1 + need_front * hop, playhead + need_front * hop
  end
  local grown = chs[1].data.frames - frames_before
  if grown > 0 then
    local where = {}
    if need_front > 0 then where[#where + 1] = string.format("%d frames in front (everything is %.2f s later)", need_front, need_front * hop) end
    if grown - need_front > 0 then where[#where + 1] = string.format("%d at the end", grown - need_front) end
    set_status(string.format("%s: the file is %.2f s longer now: %s%s%s", label, chs[1].data.dur - dur_before, table.concat(where, ", "),
      any_noise and ", and the noise" or "",
      dropped > 0 and (string.format(", %d piece(s) still fell outside", dropped)) or ""))
  elseif dropped > 0 then
    set_status(string.format("%s: %d piece(s) of partials fell outside the file and are gone", label, dropped))
  end
end

function W.commit()
  local w = W.w
  W.w = nil
  if not w or W.m.is_flat(w) then return end
  local peak, peak_h = W.m.max_abs(w), W.m.max_abs_h(w)
  local map = W.m.mapper(w)
  local parts = {}
  if peak > 0.005 then parts[#parts + 1] = string.format("up to %.1f st", peak) end
  if peak_h > 0.0005 then parts[#parts + 1] = string.format("in time up to %.0f ms", peak_h * 1000) end
  local label = "bend " .. table.concat(parts, ", ")
  -- 1. the plan of every channel that is edited together (nothing is changed yet): how far the file has to grow, at the end and in front
  local targets, plans, nplans, need_end, need_front, rows_max = on_channels(), {}, {}, 0, 0, 1
  local list = {}
  for _, i in ipairs(targets) do if chs[i].sel_info then list[#list + 1] = i end end
  if #list == 0 then return end
  for _, c in ipairs(chs) do rows_max = math.max(rows_max, c.data.partials) end
  for _, i in ipairs(list) do
    with_channel(i, function()
      -- the file may get longer when a stretch goes past its end or before its start: at most as long again at each side, and never more
      -- than 20 million new cells. (What goes before the start puts frames in front: everything in the file moves later.)
      local room = math.min(data.frames, math.floor(2e7 / math.max(rows_max, 1)))
      plans[i] = edit.plan_warp(data, sel, map, { max_extra = room, max_front = room })
      if plans[i] then
        need_end = math.max(need_end, plans[i].frames_after)
        need_front = math.max(need_front, plans[i].frames_front)
      end
      if W.noise_on(data) then                                          -- the noise bands in the box follow in time (they have no pitch to bend)
        nplans[i] = edit.plan_noise_warp(data, { t0 = w.t0, t1 = w.t1, f0 = w.f0, f1 = w.f1 }, map, { max_extra = room, max_front = room })
        if nplans[i] then
          need_end = math.max(need_end, nplans[i].frames_after)
          need_front = math.max(need_front, nplans[i].frames_front)
        end
      end
    end)
  end
  W.apply_grown(label, plans, nplans, need_end, need_front)
end

-- Pixel geometry of the box in a lane: x0, x1, yt (top), yb (bottom), pxs (pixels for one semitone). A box that is only a few pixels
-- high or wide (one partial, a few frames) would have its dots on top of each other, so it is drawn (and hit-tested: everything below
-- goes through this) at least 30 px each way, round its own middle -- purely on screen: w.t0/t1/f0/f1 themselves, and so the warp math,
-- stay the box's exact, un-padded extent (see W.get).
function W.geo(px, py, pw, lane, w)
  local lpy = py + lane.off
  local x0, x1 = px + tx(w.t0, pw), px + tx(w.t1, pw)
  if x1 - x0 < 30 then local m = (x0 + x1) / 2; x0, x1 = m - 15, m + 15 end
  local yt, yb = lpy + fy(w.f1, lane.h), lpy + fy(w.f0, lane.h)
  if yb - yt < 30 then local m = (yt + yb) / 2; yt, yb = m - 15, m + 15 end
  return { x0 = x0, x1 = x1, yt = yt, yb = yb,
           pxs = lane.h / (12 * math.log(view.f1 / view.f0, 2)), pps = pw / (view.t1 - view.t0) }
end

-- Where a point of an edge is on the screen (s along the edge, v its displacement in semitones, h in seconds).
function W.pos(g, edge, s, v, h)
  local dx = (h or 0) * g.pps
  if edge == "bottom" then return g.x0 + s * (g.x1 - g.x0) + dx, g.yb - v * g.pxs
  elseif edge == "top" then return g.x0 + s * (g.x1 - g.x0) + dx, g.yt - v * g.pxs
  elseif edge == "left" then return g.x0 + dx, g.yb + s * (g.yt - g.yb) - v * g.pxs
  else return g.x1 + dx, g.yb + s * (g.yt - g.yb) - v * g.pxs end
end

-- The lanes that have a selection, with the geometry of the box in each.
function W.lane_geos(px, py, pw, ph)
  local list = {}
  if not (data and show_partials and any_sel()) then return list end
  local w = W.get()
  if not w then return list end
  for _, lane in ipairs(lane_layout(ph)) do
    local has = false
    for _, ci in ipairs(lane.chans) do if chs[ci].edit and W.sel_info_of(ci) then has = true end end
    if has then list[#list + 1] = { lane = lane, g = W.geo(px, py, pw, lane, w) } end
  end
  return list
end

local function seg_distance(x, y, ax, ay, bx, by)
  local dx, dy = bx - ax, by - ay
  local len2 = dx * dx + dy * dy
  local t = (len2 > 0) and clamp(((x - ax) * dx + (y - ay) * dy) / len2, 0, 1) or 0
  local qx, qy = ax + t * dx, ay + t * dy
  return math.sqrt((x - qx) ^ 2 + (y - qy) ^ 2), t
end

-- What is under the mouse: a dot ("point"), or a stretch of an edge ("edge", s along it); nil for nothing.
function W.hit(px, py, pw, ph, mx, my)
  local lane = lane_at(py, ph, my)
  if not lane then return nil end
  local w = W.w
  for _, e in ipairs(W.lane_geos(px, py, pw, ph)) do
    if e.lane.off == lane.off then
      w = W.w
      local best, found = 9, nil
      for _, edge in ipairs(W.m.EDGES) do
        for i, pt in ipairs(w[edge].pts) do
          local x, y = W.pos(e.g, edge, pt.s, pt.v, pt.h)
          local d = math.sqrt((mx - x) ^ 2 + (my - y) ^ 2)
          if d < best then best, found = d, { kind = "point", edge = edge, i = i, s = pt.s, g = e.g } end
        end
      end
      if found then return found end
      for _, edge in ipairs(W.m.EDGES) do                          -- the handle in the middle of every edge: it takes the whole edge
        local x, y = W.pos(e.g, edge, 0.5, W.m.edge_value(w[edge], 0.5), W.m.edge_h(w[edge], 0.5))
        if (mx - x) ^ 2 + (my - y) ^ 2 < 100 then return { kind = "edge", edge = edge, s = 0.5, mid = true, g = e.g } end
      end
      best = 6
      for _, edge in ipairs(W.m.EDGES) do
        local px0, py0 = W.pos(e.g, edge, 0, W.m.edge_value(w[edge], 0), W.m.edge_h(w[edge], 0))
        for k = 1, 40 do
          local s1 = k / 40
          local px1, py1 = W.pos(e.g, edge, s1, W.m.edge_value(w[edge], s1), W.m.edge_h(w[edge], s1))
          local d, t = seg_distance(mx, my, px0, py0, px1, py1)
          if d < best then best, found = d, { kind = "edge", edge = edge, s = (k - 1 + t) / 40, g = e.g } end
          px0, py0 = px1, py1
        end
      end
      return found
    end
  end
  return nil
end

-- A click on the box: a dot is dragged; an edge is dragged as a whole (Ctrl: a new dot, Ctrl+Shift: an arch; Alt is not used: KDE moves the window with it). Returns true when it took the click.
function W.mouse_down(px, py, pw, ph, mx, my, cap)
  if not (data and show_partials and any_sel()) then return false end
  local h = W.hit(px, py, pw, ph, mx, my)
  if not h then return false end
  local alt = (cap & 12) == 12                                          -- (Ctrl+Shift: the arch; it was Alt before)
  local ctrl = (cap & 4) ~= 0 and not alt
  -- A selected point that happens to lie on an edge is moved, not the edge (the dots are always the box's own).
  if h.kind == "edge" and not h.mid and not alt and hit_selected(px, py, pw, ph, mx, my) then return false end   -- (Ctrl there is the one-axis move; the handle in the middle of an edge is always the box's)
  local w = W.get()
  local d = { lastx = mx, lasty = my, ex = 0, ey = 0, th = 0, g = h.g, edge = h.edge, good = W.m.snapshot(w) }
  if h.kind == "point" and not alt and not ctrl then
    d.kind, d.i, d.v0, d.h0 = "point", h.i, w[h.edge].pts[h.i].v, w[h.edge].pts[h.i].h
  elseif ctrl then
    local i = W.m.add_point(w, h.edge, h.s)
    if not i then return true end
    d.kind, d.i, d.v0, d.h0 = "point", i, w[h.edge].pts[i].v, w[h.edge].pts[i].h
    d.good = W.m.snapshot(w)
  elseif alt then
    local pts, seg = w[h.edge].pts, 1
    for i = 1, #pts - 1 do if h.s >= pts[i].s then seg = i end end
    d.kind, d.seg, d.b0, d.bh0 = "bulge", seg, w[h.edge].bulge[seg] or 0, w[h.edge].bulge_h[seg] or 0
  else
    d.kind, d.vals0, d.hals0 = "edge", {}, {}
    for i, pt in ipairs(w[h.edge].pts) do d.vals0[i], d.hals0[i] = pt.v, pt.h end
  end
  W.drag = d
  return true
end

-- The mouse moves with a handle held. Up is up in frequency and right is later in time. Shift: a fifth of the movement. Ctrl: one
-- direction only (the one that moves most). A movement that would make time fold back on itself is not made (the handle waits).
function W.drag_to(mx, my, cap)
  local d, w = W.drag, W.w
  if not (d and w) then return end
  local fine = ((cap & 8) ~= 0 and d.kind ~= "bulge") and 0.2 or 1        -- (an arch is made with Ctrl+Shift held: no fine movement, no one-axis lock)
  d.ex, d.ey = d.ex + (mx - d.lastx) * fine, d.ey + (d.lasty - my) * fine
  d.th = d.th + (mx - d.lastx) * fine / d.g.pps                       -- the movement in time, in seconds (it also counts what the window scrolls)
  d.lastx, d.lasty = mx, my
  -- The window follows the drag: with the pointer in the last stretch of the picture it scrolls on (faster the further in), so a
  -- bend can be dragged as long as you like; what the window scrolls is added to the movement, so the dot stays under the pointer.
  local px0, _, pw0 = plot_rect()
  local zone = math.max(48, 0.08 * pw0)
  local right, left = px0 + pw0 - zone, px0 + zone
  local lower = w.t0 - 3.2 * (w.t1 - w.t0)                              -- how far before the start the window may follow (the file gets frames in front)
  local scroll = 0
  if mx > right then scroll = (view.t1 - view.t0) * 0.012 * clamp((mx - right) / zone, 0, 2.5)
  elseif mx < left and view.t0 > lower then scroll = -(view.t1 - view.t0) * 0.012 * clamp((left - mx) / zone, 0, 2.5) end
  if scroll < 0 and view.t0 + scroll < lower then scroll = lower - view.t0 end
  if scroll ~= 0 then
    view.t0, view.t1 = view.t0 + scroll, view.t1 + scroll
    d.th = d.th + scroll
    d.lastscroll = scroll
    dirty = true
  end
  if (cap & 4) ~= 0 and d.kind ~= "bulge" then
    if not d.axis and math.abs(d.ex) + math.abs(d.ey) > 3 then d.axis = (math.abs(d.ex) >= math.abs(d.ey)) and "x" or "y" end
  else
    d.axis = nil
  end
  local ey = (d.axis == "x") and 0 or d.ey
  d.dv = clamp(ey / d.g.pxs, -48, 48)
  local span = w.t1 - w.t0
  -- No cap on d.dh itself any more (tjingboem, 10 Nov 2026: "i need to stretch partials for creative sounds. There should be no
  -- cap."): the old +-3x-the-selection's-own-width limit was an arbitrary drag-time ceiling with no record of why that number, not
  -- a safety limit -- the real one is W.commit's `room` (the file may grow by at most its own length again, or 20 million cells,
  -- whichever is smaller), which still applies no matter how far the handle is dragged.
  d.dh = (d.axis == "y") and 0 or d.th
  if d.kind == "point" then
    W.m.set_value(w, d.edge, d.i, clamp(d.v0 + d.dv, -48, 48), d.h0 + d.dh)
  elseif d.kind == "edge" then
    for i, v in ipairs(d.vals0) do W.m.set_value(w, d.edge, i, clamp(v + d.dv, -48, 48), d.hals0[i] + d.dh) end
  else                                                                -- an arch: in the direction that moves most
    if not d.arch and math.abs(d.ex) + math.abs(d.ey) > 3 then d.arch = (math.abs(d.ex) > math.abs(d.ey)) and "h" or "v" end
    if d.arch == "h" then w[d.edge].bulge_h[d.seg] = clamp(d.bh0 + d.dh, -3 * span, 3 * span)
    else w[d.edge].bulge[d.seg] = clamp(d.b0 + d.dv, -48, 48) end
  end
  if W.m.monotone(w) then d.good = W.m.snapshot(w) else W.m.restore(w, d.good) end
  local parts = {}
  if math.abs(d.dv) > 0.004 then parts[#parts + 1] = string.format("%+.2f st", d.dv) end
  if math.abs(d.dh) > 0.0004 then parts[#parts + 1] = string.format("%+.0f ms", d.dh * 1000) end
  set_status("bend " .. (#parts > 0 and table.concat(parts, "  ") or "") .. ": Enter applies, Esc cancels")
end

-- Right-click: a border dot goes away (true), anything else is not ours.
function W.right_click(px, py, pw, ph, mx, my)
  if not (data and show_partials and any_sel()) then return false end
  local h = W.hit(px, py, pw, ph, mx, my)
  if h and h.kind == "point" and W.m.remove_point(W.get(), h.edge, h.i) then
    set_status("border dot removed")
    return true
  end
  return false
end

-- Draws the boxes (the original faint, the bent shape bright), the dots, and the selected points where the bend puts them.
function W.draw(px, py, pw, ph)
  local list = W.lane_geos(px, py, pw, ph)
  if #list == 0 then return end
  local w = W.w
  local flat = W.m.is_flat(w)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  for _, e in ipairs(list) do
    local g, lane = e.g, e.lane
    gfx.set(1, 1, 1, flat and 0.0 or 0.22)
    gfx.rect(g.x0, g.yt, g.x1 - g.x0, g.yb - g.yt, 0)
    gfx.set(0.45, 0.9, 1, 0.85)
    for _, edge in ipairs(W.m.EDGES) do
      local x0, y0 = W.pos(g, edge, 0, W.m.edge_value(w[edge], 0), W.m.edge_h(w[edge], 0))
      for k = 1, 32 do
        local s1 = k / 32
        local x1, y1 = W.pos(g, edge, s1, W.m.edge_value(w[edge], s1), W.m.edge_h(w[edge], s1))
        gfx.line(x0, y0, x1, y1, 1)
        x0, y0 = x1, y1
      end
    end
    if not flat then                                           -- the selected points as the bend would put them
      gfx.set(1, 0.9, 0.95, 0.95)
      local map = W.m.mapper(w)
      for _, ci in ipairs(lane.chans) do
        as_channel(ci, function()
          if not sel_info then return end
          local times = data.times
          for p, frames in pairs(sel) do
            local frq = data.frq[p]
            for f in pairs(frames) do
              if frames[f + 1] then
                local function put(k)
                  local t2, fr2 = map(times[k], frq[k])
                  return px + tx(t2, pw), py + lane.off + fy(fr2, lane.h)
                end
                local ax, ay = put(f)
                local bx, by = put(f + 1)
                local cx1, cy1, cx2, cy2 = clip_segment(ax - px, ay - py - lane.off, bx - px, by - py - lane.off, pw, lane.h)
                if cx1 then gfx.line(px + cx1, py + lane.off + cy1, px + cx2, py + lane.off + cy2, 1) end
              end
            end
          end
        end)
      end
    end
    for _, edge in ipairs(W.m.EDGES) do                         -- the handle in the middle of every edge (drag it: the whole edge moves: a bend, a stretch)
      local x, y = W.pos(g, edge, 0.5, W.m.edge_value(w[edge], 0.5), W.m.edge_h(w[edge], 0.5))
      local hover = (W.drag and W.drag.kind == "edge" and W.drag.edge == edge) or (not W.drag and (mx - x) ^ 2 + (my - y) ^ 2 < 100)
      gfx.set(hover and 1 or 0.45, hover and 0.95 or 0.9, hover and 0.5 or 1, 1)
      gfx.rect(x - 4, y - 4, 9, 9, 1)
      gfx.set(0.05, 0.06, 0.08, 0.9)
      gfx.rect(x - 4, y - 4, 9, 9, 0)
    end
    for _, edge in ipairs(W.m.EDGES) do                         -- the dots
      for i, pt in ipairs(w[edge].pts) do
        local x, y = W.pos(g, edge, pt.s, pt.v, pt.h)
        local corner = (i == 1 or i == #w[edge].pts)
        local hover = (W.drag and W.drag.edge == edge and W.drag.i == i) or (not W.drag and (mx - x) ^ 2 + (my - y) ^ 2 < 81)
        gfx.set(hover and 1 or 0.45, hover and 0.95 or 0.9, hover and 0.5 or 1, 1)
        gfx.circle(x, y, corner and 5 or 4, 1)
        gfx.set(0.05, 0.06, 0.08, 0.9)
        gfx.circle(x, y, corner and 5 or 4, 0)
      end
    end
    if not flat then
      gfx.setfont(1, "Arial", 13)
      local what = {}
      if W.m.max_abs(w) > 0.005 then what[#what + 1] = string.format("up to %.1f st", W.m.max_abs(w)) end
      if W.m.max_abs_h(w) > 0.0005 then what[#what + 1] = string.format("in time up to %.0f ms", W.m.max_abs_h(w) * 1000) end
      text_at(g.x0 + 4, math.max(g.yt - 18, py + lane.off + 2), "bend " .. table.concat(what, ", ") .. "    Enter applies   Esc cancels", 0.65, 0.95, 1)
    end
  end
  if W.drag and W.drag.dv then
    gfx.setfont(1, "Arial", 13)
    local label = string.format("%+.2f st", W.drag.dv)
    if math.abs(W.drag.dh or 0) > 0.0004 then label = label .. string.format("  %+.0f ms", W.drag.dh * 1000) end
    text_at(mx + 14, my - 22, label, 1, 0.95, 0.6)
  end
end

-- Noise-layer checkbox, top right of the header.
local function checkbox_rect()
  return W.lay("chk_noise_s")
end

local function audition_rect() return W.lay("btn_audition_s") end
local function start_rect() return W.lay("btn_start_s") end            -- under PRINT: the playhead goes back to the start
local function print_rect() return W.lay("btn_print_s") end
local function export_rect() return W.lay("btn_export_s") end

local function draw_export_button()
  local x, y, w, h = export_rect()
  gfx.set(0.36, 0.27, 0.16, 1)
  gfx.rect(x, y, w, h, 1)
  gfx.set(0.90, 0.72, 0.45, 1)
  gfx.rect(x, y, w, h, 0)
  local label = (w >= 96) and "EXPORT .ats" or "EXPORT"                 -- (the layout may make the button narrow)
  W.fit(label, w, 14)
  gfx.set(1, 0.96, 0.90, 1)
  gfx.x = x + (w - gfx.measurestr(label)) / 2
  gfx.y = y + 2
  gfx.drawstr(label)
end

local function analyse_rect() return W.lay("btn_analyse_s") end

local function draw_analyse_button()
  local x, y, w, h = analyse_rect()
  gfx.set(0.20, 0.36, 0.33, 1)
  gfx.rect(x, y, w, h, 1)
  gfx.set(0.50, 0.85, 0.78, 1)
  gfx.rect(x, y, w, h, 0)
  local label = "ANALYSE"
  W.fit(label, w, 14)
  gfx.set(0.93, 1, 0.98, 1)
  gfx.x = x + (w - gfx.measurestr(label)) / 2
  gfx.y = y + 2
  gfx.drawstr(label)
end

-- The empty state (no file open yet): a bigger version of the same button, centred above the empty picture rather than tucked in
-- the top-right corner, and labelled to make clear it leads to BOTH an analysis of a new sound and opening an existing .ats file
-- (the Analysis page's own "Import Sound File" / "Import .ats File" buttons) -- tjingboem, 10 Nov 2026: "move the Analyze button to
-- the middle above the empty Editor and make the button show: ANALYZE or IMPORT FILE... This button takes us to the Analysis page
-- where also a file to import can be chosen." Fields of W, like W.max_partials_rect, rather than new locals: this file is already
-- at Lua's 200-local-variable limit for its main chunk.
function W.empty_analyse_rect()
  local px, py, pw = plot_rect()
  local w, h = 280, 30
  return px + (pw - w) / 2, math.floor((py - h) / 2), w, h
end

function W.draw_empty_analyse_button()
  local x, y, w, h = W.empty_analyse_rect()
  gfx.set(0.20, 0.36, 0.33, 1)
  gfx.rect(x, y, w, h, 1)
  gfx.set(0.50, 0.85, 0.78, 1)
  gfx.rect(x, y, w, h, 0)
  gfx.setfont(1, "Arial", 15)
  local label = "ANALYSE or IMPORT FILE"
  gfx.set(0.93, 1, 0.98, 1)
  gfx.x = x + (w - gfx.measurestr(label)) / 2
  gfx.y = y + (h - 17) / 2
  gfx.drawstr(label)
end

local function draw_print_button()
  local x, y, w, h = print_rect()
  if pending and pending.kind == "print" and (math.floor(reaper.time_precise() * 2.5) % 2 == 0) then
    gfx.set(0.42, 0.58, 0.90, 1)                                  -- blinking: the print is being prepared
  else
    gfx.set(0.22, 0.30, 0.46, 1)
  end
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

-- A small bar and the percentage under a button while its sound is being prepared.
local function draw_progress_under(x, w, y, frac, rgb)
  gfx.set(0.14, 0.16, 0.19, 1)
  gfx.rect(x, y, w, 5, 1)
  gfx.set(rgb[1], rgb[2], rgb[3], 1)
  gfx.rect(x, y, w * math.min(math.max(frac, 0), 1), 5, 1)
  gfx.set(0.5, 0.53, 0.58, 1)
  gfx.rect(x, y, w, 5, 0)
  gfx.setfont(1, "Arial", 11)
  local label = string.format("%d %%", math.floor(frac * 100 + 0.5))
  gfx.set(0.85, 0.9, 0.95, 1)
  gfx.x = x + (w - gfx.measurestr(label)) / 2
  gfx.y = y + 7
  gfx.drawstr(label)
end

-- The channel row (only when there are several channels): per channel an ON/OFF button (a star marks unsaved changes)
-- and a visibility slider (20-100 %), then the STACK/OVERLAY button.
-- (the places come from the layout: channel 1's button, slider and LED, and the distance between channels 1 and 2)
local function chan_pitch()
  local base = W.layout.el.ch2_btn.x - W.layout.el.ch1_btn.x
  return math.max(math.min(base, math.floor((gfx.w - MARGIN_L - 130) / math.max(#chs, 1))), 44)
end
local function channel_button_rect(i)
  local x, y, w, h = W.lay("ch1_btn")
  return x + (i - 1) * chan_pitch(), y, w, h
end
local function slider_rect(i)
  local bx, by = channel_button_rect(i)
  local b1x, _, _, _ = W.lay("ch1_btn")
  local sx, sy, sw, sh = W.lay("ch1_slider")
  local shrink = (W.layout.el.ch2_btn.x - W.layout.el.ch1_btn.x) - chan_pitch()          -- (a narrow window makes the channels closer: the slider gets shorter)
  return bx + (sx - b1x), sy, sw - shrink, sh
end
local function led_rect(i)
  local bx = channel_button_rect(i)
  local b1x = W.lay("ch1_btn")
  local lx, ly, lw = W.lay("ch1_led")
  return bx + (lx - b1x), ly, lw
end
local function mode_rect()
  local b1x = W.lay("ch1_btn")
  local mx, my, mw, mh = W.lay("btn_stackmode")
  local base = W.layout.el.ch2_btn.x - W.layout.el.ch1_btn.x
  return b1x + #chs * chan_pitch() + (mx - (b1x + 3 * base)), my, mw, mh      -- (in the layout the button sits after three channels)
end

local function draw_channel_buttons()
  if #chs < 2 then return end
  gfx.setfont(1, "Arial", 13)
  for i = 1, #chs do
    local c = chs[i]
    local tc = tint_of(i)
    local x, y, w, h = channel_button_rect(i)
    if c.on then gfx.set(tc[1] * 0.45, tc[2] * 0.45, tc[3] * 0.45, 1) else gfx.set(0.16, 0.18, 0.22, 1) end
    gfx.rect(x, y, w, h, 1)
    if c.on then gfx.set(tc[1], tc[2], tc[3], 1) else gfx.set(0.35, 0.38, 0.43, 1) end
    gfx.rect(x, y, w, h, 0)
    local label = tostring(i) .. (((i == cur and modified) or (i ~= cur and c.modified)) and "*" or "")
    gfx.set(1, 1, 1, c.on and 1 or 0.5)
    gfx.x = x + (w - gfx.measurestr(label)) / 2
    gfx.y = y + 2
    gfx.drawstr(label)
    -- the LED above the button: green = editable, red = not editable (dim when the channel is off)
    local lx, ly, lw = led_rect(i)
    local dim = c.on and 1 or 0.35
    if c.edit then gfx.set(0.15 * dim, 0.95 * dim, 0.30 * dim, 1) else gfx.set(0.95 * dim, 0.12 * dim, 0.12 * dim, 1) end
    gfx.circle(lx + lw // 2, ly + lw // 2, lw // 2, 1)
    gfx.set(0, 0, 0, 0.6)
    gfx.circle(lx + lw // 2, ly + lw // 2, lw // 2, 0)
    -- the visibility slider
    local sx, sy, sw, sh = slider_rect(i)
    gfx.set(0.16, 0.18, 0.22, 1)
    gfx.rect(sx, sy, sw, sh, 1)
    if c.on then
      local fill = (c.vis - VIS_MIN) / (1 - VIS_MIN)
      gfx.set(tc[1], tc[2], tc[3], 0.55)
      gfx.rect(sx, sy, sw * fill, sh, 1)
      gfx.set(1, 1, 1, 0.9)
      gfx.rect(sx + math.floor((sw - 3) * fill), sy - 2, 3, sh + 4, 1)
    end
    gfx.set(0.35, 0.38, 0.43, 1)
    gfx.rect(sx, sy, sw, sh, 0)
  end
  local x, y, w, h = mode_rect()
  gfx.set(0.16, 0.18, 0.22, 1)
  gfx.rect(x, y, w, h, 1)
  gfx.set(0.55, 0.90, 0.82, 1)
  gfx.rect(x, y, w, h, 0)
  local label = (view_mode == "stack") and "STACK" or "OVERLAY"
  gfx.x = x + (w - gfx.measurestr(label)) / 2
  gfx.y = y + 2
  gfx.drawstr(label)
end

-- Switches channel i on or off. At least one stays on.
local function toggle_channel(i)
  local c = chs[i]
  if c.on then
    if #on_list() <= 1 then set_status("at least one channel stays on"); return end
    capture_channel()
    c.on = false
    if i == cur then
      for j, x in ipairs(chs) do if x.on then switch_channel(j); break end end
    end
    chs[i].sel, chs[i].sel_info = {}, nil                         -- an OFF channel keeps no selection
  else
    c.on = true
  end
  dirty = true
end

-- Click on an LED: editable (green) or not (red). A channel that is not editable loses its selection.
local function toggle_edit(i)
  capture_channel()
  local c = chs[i]
  c.edit = not c.edit
  if not c.edit then c.sel, c.sel_info = {}, nil; if i == cur then sel, sel_info = c.sel, nil end end
  dirty = true
  set_status(string.format("channel %d %s", i, c.edit and "is editable (green)" or "is not editable (red)"))
end

-- Tab: solo the next channel; after the last one, all channels again.
local function solo_next()
  local on = on_list()
  local target
  if #on == #chs then target = 1
  elseif #on == 1 then target = (on[1] < #chs) and on[1] + 1 or nil end
  for i, c in ipairs(chs) do
    capture_channel()
    c.on = (target == nil) or i == target
  end
  if not chs[cur].on then for j, x in ipairs(chs) do if x.on then switch_channel(j); break end end end
  for i, c in ipairs(chs) do if not c.on then c.sel, c.sel_info = {}, nil end end
  dirty = true
end

local function toggle_view_mode()
  view_mode = (view_mode == "stack") and "overlay" or "stack"
  dirty = true
  set_status("view: " .. view_mode)
end

local slider_drag = nil           -- the channel whose visibility slider is being dragged

local function set_slider_from_mouse(i, mx)
  local sx, _, sw = slider_rect(i)
  local v = VIS_MIN + clamp((mx - sx) / sw, 0, 1) * (1 - VIS_MIN)
  chs[i].vis = math.floor(v * 100 + 0.5) / 100
  set_status(string.format("channel %d visibility %d %%", i, math.floor(chs[i].vis * 100 + 0.5)))
  dirty = true
end

-- A left click in the channel row; true when it hit something there.
local function channel_row_click(mx, my)
  if #chs < 2 then return false end
  for i = 1, #chs do
    local lx, ly, lw = led_rect(i)
    if mx >= lx - 6 and mx < lx + lw + 6 and my >= ly - 3 and my < ly + lw + 3 then toggle_edit(i); return true end
    local bx, by, bw, bh = channel_button_rect(i)
    if mx >= bx and mx < bx + bw and my >= by and my < by + bh then toggle_channel(i); return true end
    local sx, sy, sw, sh = slider_rect(i)
    if chs[i].on and mx >= sx - 2 and mx < sx + sw + 2 and my >= sy - 3 and my < sy + sh + 3 then
      slider_drag = i
      set_slider_from_mouse(i, mx)
      return true
    end
  end
  local x, y, w, h = mode_rect()
  if mx >= x and mx < x + w and my >= y and my < y + h then toggle_view_mode(); return true end
  return false
end

local function draw_audition_button()
  local x, y, w, h = audition_rect()
  if pending and (math.floor(reaper.time_precise() * 2.5) % 2 == 0) then
    gfx.set(0.36, 0.80, 0.56, 1)                                  -- blinking: the sound is being prepared
  else
    gfx.set(0.18, 0.42, 0.30, 1)
  end
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

local function draw_start_button()
  local x, y, w, h = start_rect()
  local away = playhead > 0.0005
  gfx.set(away and 0.30 or 0.14, away and 0.24 or 0.16, away and 0.10 or 0.2, 1)
  gfx.rect(x, y, w, h, 1)
  gfx.set(away and 0.95 or 0.4, away and 0.75 or 0.43, away and 0.35 or 0.5, 1)
  gfx.rect(x, y, w, h, 0)
  local label = (w < 44) and "|<" or (away and string.format("|< %.1f s", playhead) or "|< start")     -- (a small button in the layout: only the arrow)
  W.fit(label, w, 12)
  gfx.set(1, away and 0.9 or 0.65, away and 0.6 or 0.7, 1)
  gfx.x = x + (w - gfx.measurestr(label)) / 2
  gfx.y = y + 1
  gfx.drawstr(label)
  gfx.setfont(1, "Arial", 14)
end

-- The sine layer checkbox sits under the noise layer checkbox.
local function sine_checkbox_rect() return W.lay("chk_sine_s") end

local function draw_sine_checkbox()
  local x, y = sine_checkbox_rect()
  gfx.setfont(1, "Arial", 14)
  gfx.set(0.4, 0.43, 0.48, 1)
  gfx.rect(x, y + 1, 14, 14, 0)
  if show_partials then
    gfx.set(0.35, 0.80, 0.90, 1)
    gfx.rect(x + 3, y + 4, 8, 8, 1)
  end
  text_at(x + 22, y, "Sine layer", 0.85, 0.87, 0.9)
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

local function any_modified()
  if modified then return true end
  for i, c in ipairs(chs) do if i ~= cur and c.modified then return true end end
  return false
end

local function draw_header(px, py, pw, ph, plain)
  gfx.setfont(1, "Arial", 14)
  if not data then
    if load_error then text_at(px, 10, "Could not read:\n" .. load_error, 0.95, 0.85, 0.5) end
    if not plain then W.draw_empty_analyse_button() end
    if status_msg and reaper.time_precise() < status_until then text_at(px, 48, status_msg, 0.6, 0.95, 0.6) end
    return
  end
  local name = fname:match("([^/\\]+)$") or fname
  local hop_ms = data.frame_size / data.sr * 1000
  local head = string.format("%s%s", name, any_modified() and " *" or "")
  local tail = string.format("   |   %d partials   %d frames   %.2f s%s   %d Hz   hop %.1f ms   type %d%s%s",
    data.partials, data.frames, data.dur,
    (data.dur >= 59.5) and (" (" .. Analysis.clock(data.dur) .. ")") or "", data.sr, hop_ms, data.type,
    data.has_phase and " (phase)" or "", data.has_noise and " (noise)" or "")
  -- With a sound in it the window follows the layout (lib/layout.lua): the file line is at the bottom, and a message of the last action takes the place of
  -- its numbers for a few seconds (the name and the star stay; there is no line of its own for messages). The Analysis page (plain) keeps the old lines at the top.
  local ix, iy = px, 8
  if not plain then ix, iy = W.lay("hdr_info_s") end
  text_at(ix, iy, head)
  if (not plain) and status_msg and reaper.time_precise() < status_until then
    text_at(ix + gfx.measurestr(head) + 16, iy, status_msg, 0.6, 0.95, 0.6)
  else
    text_at(ix + gfx.measurestr(head), iy, tail)
  end
  if not plain then
    draw_checkbox()
    draw_sine_checkbox()
    draw_audition_button()
    draw_start_button()
    draw_print_button()
    draw_export_button()
    draw_analyse_button()
    draw_channel_buttons()
    if pending then                                              -- how far the sound is, under the button it belongs to
      local x, y, w, h, rgb
      if pending.kind == "print" then x, y, w, h = print_rect(); rgb = { 0.45, 0.62, 0.95 }
      else x, y, w, h = audition_rect(); rgb = { 0.30, 0.85, 0.55 } end
      draw_progress_under(x, w, y + h + 2, pending.job.progress, rgb)
    end
  end
  gfx.setfont(1, "Arial", 14)
  if plain and status_msg and reaper.time_precise() < status_until then
    text_at(px, 48, status_msg, 0.6, 0.95, 0.6)                       -- (the Analysis page: third header row, what the last action did)
  end
  if plain then return end
  if any_sel() then
    local pts, parts, nch, t0, t1, f0, f1 = 0, 0, 0, math.huge, -math.huge, math.huge, -math.huge
    for i, c in ipairs(chs) do
      local si = (i == cur) and sel_info or c.sel_info
      if si and c.on then
        pts, parts, nch = pts + si.points, parts + si.partials, nch + 1
        t0, t1, f0, f1 = math.min(t0, si.t0), math.max(t1, si.t1), math.min(f0, si.f0), math.max(f1, si.f1)
      end
    end
    local msg = string.format("selected: %d points in %d partials%s   %.3f-%.3f s   %s - %s",
      pts, parts, nch > 1 and (" (" .. nch .. " channels)") or "", t0, t1, fmt_freq(f0), fmt_freq(f1))
    local sx, sy, sw = W.lay("hdr_selinfo_s")
    text_at(sx + sw - gfx.measurestr(msg), sy, msg, 1, 0.5, 0.82)                  -- (right aligned in its place of the layout)
  end
  -- hover readout (the lane under the mouse; in the overlay every channel that is on)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local lane = (mx >= px and mx < px + pw) and lane_at(py, ph, my) or nil
  if lane then
    local lpy, lph = py + lane.off, lane.h
    local t = view.t0 + (mx - px) / pw * (view.t1 - view.t0)
    local f = view.f0 * (view.f1 / view.f0) ^ ((lpy + lph - my) / lph)
    local best, bestd, bestch, bestfi = nil, 9, nil, nil
    if show_partials then
      for _, ci in ipairs(lane.chans) do
        as_channel(ci, function()
          local fi = frame_at(t)
          for p = 1, data.partials do
            if data.amp[p][fi] > amp_thresh and data.frq[p][fi] > 0 then
              local d = math.abs(lpy + fy(data.frq[p][fi], lph) - my)
              if d < bestd then best, bestd, bestch, bestfi = p, d, ci, fi end
            end
          end
        end)
      end
    end
    if best then
      as_channel(bestch, function()
        local fi = bestfi
        local db = 20 * math.log(data.amp[best][fi] / data.ampmax, 10)
        local hx, hy = W.lay("hdr_partial_s")
        text_at(hx, hy, string.format("%spartial %d: %s (%s)   %.1f dB   frame %d",
          #chs > 1 and ("ch " .. bestch .. "  ") or "", best, fmt_freq(data.frq[best][fi]), ats.note_name(data.frq[best][fi]), db, fi), 1, 0.95, 0.6)
        -- highlight the whole partial
        local times, amp, frq = data.times, data.amp[best], data.frq[best]
        gfx.set(1, 1, 1, 0.95)
        for f = 1, data.frames - 1 do
          if amp[f] > amp_thresh and amp[f + 1] > amp_thresh and frq[f] > 0 and frq[f + 1] > 0 then
            local cx1, cy1, cx2, cy2 = clip_segment(tx(times[f], pw), fy(frq[f], lph),
                                                    tx(times[f + 1], pw), fy(frq[f + 1], lph), pw, lph)
            if cx1 then gfx.line(px + cx1, lpy + cy1, px + cx2, lpy + cy2, 1) end
          end
        end
      end)
    end
  end
  gfx.setfont(1, "Arial", 12)
  W.draw_max_partials_button()
  W.draw_space()
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
  if W.gain then                                                 -- the gain slider is open: it takes the mouse and the keys
    local ch = gfx.getchar()
    if ch < 0 then stop_audition(); return false end
    gfx.mouse_wheel = 0
    W.gain_input(mx, my, cap, ch)
    prev_down = (cap & 1) ~= 0
    return true
  end

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
      if math.abs(mx - drag.x0) > 3 or math.abs(my - drag.y0) > 3 then drag.moved = true end
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
      drag = { x = mx, y = my, x0 = mx, y0 = my, moved = false, right = (cap & 2) ~= 0 }
    end
  else
    if drag and drag.right and not drag.moved then              -- a right-click without a drag: a border dot goes away, else the whole file in view (as F; the same in ReaShapeM)
      if not W.right_click(px, py, pw, ph, drag.x0, drag.y0) then
        if any_sel() and show_partials then
          W.gain_open(mx, my)                                    -- a selection: the gain slider
        else
          fit_view()
          set_status("whole file in view")
        end
      end
    end
    drag = nil
  end

  -- Left button: checkbox click; on a selected point it drags the selection, elsewhere a box selects.
  local down = (cap & 1) ~= 0
  if down and not prev_down then
    local cx, cy, cw, chh = checkbox_rect()
    local ax, ay, aw, ah = audition_rect()
    local sx, sy, sw, sh = sine_checkbox_rect()
    if mx >= cx and mx < cx + cw and my >= cy and my < cy + chh then
      show_noise = not show_noise
      dirty = true
    elseif mx >= sx and mx < sx + sw and my >= sy and my < sy + sh then
      show_partials = not show_partials
      dirty = true
    elseif mx >= ax and mx < ax + aw and my >= ay and my < ay + ah then
      audition()
    elseif data and (function() local bx, by, bw, bh = start_rect(); return mx >= bx and mx < bx + bw and my >= by and my < by + bh end)() then
      set_playhead(0); set_status("playhead at the start")
    elseif (function() local rx, ry, rw, rh = print_rect(); return mx >= rx and mx < rx + rw and my >= ry and my < ry + rh end)() then
      print_to_track()
    elseif (function() local ex, ey, ew, eh = export_rect(); return mx >= ex and mx < ex + ew and my >= ey and my < ey + eh end)() then
      save_as()
    elseif (function()
        local ax2, ay2, aw2, ah2
        if data then ax2, ay2, aw2, ah2 = analyse_rect() else ax2, ay2, aw2, ah2 = W.empty_analyse_rect() end
        return mx >= ax2 and mx < ax2 + aw2 and my >= ay2 and my < ay2 + ah2
      end)() then
      showing_analysis = true
    elseif data and (function()
        local mx2, my2, mw2, mh2 = W.max_partials_rect()
        return any_sel() and mx >= mx2 and mx < mx2 + mw2 and my >= my2 and my < my2 + mh2
      end)() then
      W.pk_apply()
    elseif data and W.space_click(mx, my, cap) then
      -- (the SPACE controls: handled above)
    elseif data and mx >= px and mx < px + pw and my >= py + ph and my < py + ph + 26 then
      ruler_drag = true                                          -- a click (or drag) on the time ruler sets the playhead
      set_playhead(view.t0 + (mx - px) / pw * (view.t1 - view.t0))
    elseif channel_row_click(mx, my) then
      -- (the channel row: handled above)
    elseif data and inside and ((cap & 8) == 0 or (cap & 12) == 12) and W.mouse_down(px, py, pw, ph, mx, my, cap) then
      -- (the box and its handles: handled above; Shift is left for adding to the selection)
    elseif data and inside and (cap & 12) == 12 and lane_at(py, ph, my) then       -- Ctrl+Shift+drag: a lasso (it adds to the selection; Esc or a click on empty space clears first)
      local lane = lane_at(py, ph, my)
      lasso = { pts = { { mx, my } }, add = true, off = lane.off, h = lane.h }
    elseif data and inside and lane_at(py, ph, my) then
      local lane = lane_at(py, ph, my)
      local hit, lh = false, nil
      if any_sel() then hit, lh = hit_selected(px, py, pw, ph, mx, my) end
      if hit then
        mover = { x0 = mx, y0 = my, x = mx, y = my, lx = mx, ly = my, ex = 0, ey = 0, active = false, h = lh }
      else
        box = { x0 = mx, y0 = my, x1 = mx, y1 = my, add = (cap & 8) ~= 0, off = lane.off, h = lane.h }
      end
    end
  elseif down and W.space_drag then
    W.space_to(mx)
  elseif down and slider_drag then
    set_slider_from_mouse(slider_drag, mx)
  elseif down and ruler_drag then
    set_playhead(view.t0 + (clamp(mx, px, px + pw) - px) / pw * (view.t1 - view.t0))
  elseif down and mover then
    -- Shift: fine (a fifth of the mouse movement); Ctrl: one axis only (the one that moves most), the other keeps its place.
    -- Both are read all the time, so they can be pressed or let go in the middle of a drag.
    local fine = ((cap & 8) ~= 0) and 0.2 or 1
    mover.ex, mover.ey = mover.ex + (mx - mover.lx) * fine, mover.ey + (my - mover.ly) * fine
    mover.lx, mover.ly, mover.x, mover.y = mx, my, mx, my
    if mover.active then mover.ex = mover.ex + W.edge_scroll(mx, mover.ex > 0, mover.ex < 0, true) end                -- (what the view scrolls is part of the move)
    if not mover.active and (math.abs(mx - mover.x0) > 3 or math.abs(my - mover.y0) > 3) then mover.active = true end
    if (cap & 4) ~= 0 then
      if not mover.axis and math.abs(mover.ex) + math.abs(mover.ey) > 3 then
        mover.axis = (math.abs(mover.ex) >= math.abs(mover.ey)) and "x" or "y"
      end
    else
      mover.axis = nil
    end
  elseif down and W.drag then
    W.drag_to(mx, my, cap)
  elseif down and lasso then
    local ax = lasso.pts[1][1]
    local shift_px = W.edge_scroll(mx, mx > ax, mx < ax)
    if shift_px ~= 0 then for _, q in ipairs(lasso.pts) do q[1] = q[1] - shift_px end end      -- (the loop stays on the same points of the sound)
    local x, y = clamp(mx, px, px + pw), clamp(my, py + lasso.off, py + lasso.off + lasso.h)
    local last = lasso.pts[#lasso.pts]
    if math.abs(x - last[1]) + math.abs(y - last[2]) >= 4 then lasso.pts[#lasso.pts + 1] = { x, y } end
  elseif down and box then
    local shift_px = W.edge_scroll(mx, mx > box.x0, mx < box.x0)
    if shift_px ~= 0 then box.x0 = box.x0 - shift_px end                                       -- (the start stays on the same time of the sound)
    box.x1 = clamp(mx, px, px + pw)
    box.y1 = clamp(my, py + box.off, py + box.off + box.h)
  elseif (not down) and prev_down and mover then
    local m = mover
    if m.active then
      local df, ratio = mover_delta(pw, m.h or ph)
      mover = nil
      move_selection(df, ratio)
    end
    mover = nil
  elseif (not down) and prev_down and lasso then
    local l = lasso
    lasso = nil
    local x0, x1, y0, y1 = math.huge, -math.huge, math.huge, -math.huge
    for _, q in ipairs(l.pts) do x0, x1, y0, y1 = math.min(x0, q[1]), math.max(x1, q[1]), math.min(y0, q[2]), math.max(y1, q[2]) end
    if #l.pts < 3 or (x1 - x0 < 4 and y1 - y0 < 4) then
      if not l.add then clear_selection() end                    -- (a click with Ctrl+Shift held and no loop: nothing)
    else
      local pt, plf = {}, {}
      for i, q in ipairs(l.pts) do
        pt[i] = view.t0 + (q[1] - px) / pw * (view.t1 - view.t0)
        plf[i] = LOG(view.f0 * (view.f1 / view.f0) ^ ((py + l.off + l.h - q[2]) / l.h))
      end
      select_poly(pt, plf, l.add)
    end
  elseif (not down) and prev_down and box then
    local b = box
    box = nil
    if math.abs(b.x1 - b.x0) < 4 and math.abs(b.y1 - b.y0) < 4 then
      if not b.add then
        clear_selection()                                   -- a plain click on empty space clears the selection ...
        set_playhead(view.t0 + (b.x0 - px) / pw * (view.t1 - view.t0))   -- ... and puts the playhead there
      end
    else
      local function t_of(x) return view.t0 + (x - px) / pw * (view.t1 - view.t0) end
      local function f_of(y) return view.f0 * (view.f1 / view.f0) ^ ((py + b.off + b.h - y) / b.h) end
      select_box(t_of(b.x0), t_of(b.x1), f_of(b.y0), f_of(b.y1), b.add)
    end
  end
  if not down then ruler_drag = false; slider_drag = nil; W.drag = nil; W.space_drag = nil end
  prev_down = down

  local ch = gfx.getchar()
  if ch < 0 then stop_audition(); return false end
  if ch == 27 then
    if pending and pending.kind == "print" then pending.job.cancel(); pending = nil; set_status("print cancelled")
    elseif W.w and not W.m.is_flat(W.w) then W.w = nil; set_status("bend cancelled")
    elseif any_sel() then clear_selection() else stop_audition() end     -- Esc no longer closes the window (tjingboem, 10 Nov 2026)
  end
  local ctrl, shift = (cap & 4) ~= 0, (cap & 8) ~= 0
  if ch == 6579564 then delete_selection()                      -- Delete
  elseif ch == 30064 or ch == 1685026670 then                   -- Up / Down arrow
    local step = ctrl and 12 or (shift and 0.1 or 1)
    transpose_selection(ch == 30064 and step or -step)
  elseif ch == 1818584692 or ch == 1919379572 then              -- Left / Right arrow: move in time
    local frames = ctrl and 10 or 1
    move_selection(ch == 1919379572 and frames or -frames, 1)
  elseif ch == 13 then                                          -- Enter: apply the bend
    if W.w and not W.m.is_flat(W.w) then W.commit() else set_status("nothing to apply: drag the corner dots or the edges of the box first") end
  elseif ch == 18 then W.w = nil; set_status("bend reset")        -- Ctrl+R: the box flat again
  elseif ch == 3 then copy_selection()                           -- Ctrl+C
  elseif ch == 24 then if copy_selection() then edit_on_channels(function() delete_single(true) end, "cut") end   -- Ctrl+X (the noise goes with the sines)
  elseif ch == 22 then paste_clipboard()                        -- Ctrl+V: at the playhead
  elseif ch == 26 then if shift then redo() else undo() end     -- Ctrl+Z (Shift = redo)
  elseif ch == 25 then redo()                                   -- Ctrl+Y
  elseif ch == 19 then if shift then save_as() else save_file() end   -- Ctrl+S, Ctrl+Shift+S
  elseif ch == 9 then if #chs > 1 then solo_next() end           -- Tab: only the next channel (then all again)
  elseif ch == 118 or ch == 86 then if #chs > 1 then toggle_view_mode() end   -- V: stack / overlay
  elseif ch == 16 then print_to_track()                          -- Ctrl+P
  elseif ch == 97 or ch == 65 then                                -- A: the selection only when there is one, else the whole sound from the playhead
    if not (any_sel() and W.audition_selection()) then audition() end
  elseif ch == 122 or ch == 90 then W.zoom_selection()           -- Z: zoom to the selection
  elseif ch == 32 then stop_audition(); W.say_audition("audition stopped")
  elseif ch == 111 or ch == 79 then open_dialog()
  elseif ch == 114 or ch == 82 then if fname then load_file(fname) end
  elseif ch == 102 or ch == 70 then fit_view()
  elseif ch == 1752132965 then set_playhead(0); set_status("playhead at the start")                 -- Home
  elseif ch == 6647396 then set_playhead(math.huge); set_status("playhead at the end")                -- End
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
  analysis:draw(math.floor(gfx.w), math.floor(gfx.h), ANALYSIS_TOP)
end

local function loop()
  analysis:poll()                                              -- looks at a background analysis, if one runs
  advance_pending()                                            -- prepares the AUDITION sound a little each frame
  if showing_analysis then
    local keep = true
    analysis:mouse(gfx.mouse_x, gfx.mouse_y, gfx.mouse_cap, gfx.mouse_wheel)
    gfx.mouse_wheel = 0
    local ch = gfx.getchar()
    while ch > 0 do                                              -- every key typed since the last frame (a value is typed in a field)
      if not analysis:key(ch) and ch == 27 then showing_analysis = false; dirty = true end
      ch = gfx.getchar()
    end
    if ch < 0 then keep = false end
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
  for k, lane in ipairs(lane_layout(ph)) do gfx.blit(k, 1, 0, 0, 0, pw, lane.h, px, py + lane.off, pw, lane.h) end
  if data then                                                  -- what lies before the start and after the end of the file is darker (a bend can go there)
    local x_start, x_end = px + tx(data.times[1], pw), px + tx(data.times[data.frames], pw)
    gfx.set(0, 0, 0, 0.38)
    for _, lane in ipairs(lane_layout(ph)) do
      if x_start > px then gfx.rect(px, py + lane.off, math.min(x_start, px + pw) - px, lane.h, 1) end
      if x_end < px + pw then gfx.rect(math.max(x_end, px), py + lane.off, px + pw - math.max(x_end, px), lane.h, 1) end
    end
  end
  draw_selection(px, py, pw, ph)
  W.draw(px, py, pw, ph)
  draw_crosshair(px, py, pw, ph)
  draw_axes(px, py, pw, ph)
  draw_playhead(px, py, pw, ph)
  draw_header(px, py, pw, ph)
  W.draw_gain()
  gfx.update()
  if keep then reaper.defer(loop) end
end

gfx.init(TITLE, 1100, 640)
analysis = Analysis.new({
  layout = dofile(script_dir .. "/lib/analysis_layout.lua"),
  serial = Serial, wav_info = wav_info, script_dir = script_dir, ext_section = EXT_SECTION,
  on_open = function(path) return load_file(path) end,
  set_status = set_status,
  redraw = function() draw_analysis_frame(); gfx.update() end,
  back = function() showing_analysis = false; dirty = true end,
})
Analysis.check_python_once(script_dir, EXT_SECTION)      -- once ever (tjingboem, 10 Nov 2026): a popup, not a Check button on the page
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
        if type(st.from) == "number" then playhead = clamp(st.from, 0, data.times[data.frames]) end   -- where the print started
        dirty = true
        applied = true
      else
        set_status("snapshot file not found: " .. st.file)
      end
    end
  end
end
-- Without a snapshot the window starts EMPTY (tjingboem, 9 Nov 2026: "it must start cleared"): no file is reopened and no
-- dialog asks for one. (The last folder is still the dialog's starting point.)
remove_stale_temp_files()                                       -- (files that an earlier editor left behind)
loop()
