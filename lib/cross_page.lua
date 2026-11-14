-- cross_page.lua -- the CROSS page (tjingboem, 13 Nov 2026): sounds flow into each other. An immediate-mode page like the Analysis page (Esc / BACK returns to the
-- editor). It holds the RECIPE only; the result is a new .ats file (lib/ats_cross.lua) that opens in the editor, where it is auditioned and finished by hand.
--   * any number of blocks, one per sound, drawn as long as the sound lasts, in two lanes (A above B) on one timeline; LOAD adds a block at the end of its lane;
--     each block shows a LOW RESOLUTION IMAGE of the sound (time sideways, frequency up, brightness = level; the same frequency range for all) to find the coarse cross point
--   * the blocks are dragged in time; two blocks in one lane cannot overlap; the handles at the ends of a block cut it ("use this portion only")
--   * where blocks of the two lanes overlap there is a TRANSITION; each has its RED LINE (vertical, or a diagonal made with two Ctrl+clicks) and a grey band (time tolerance)
--   * a slider for the time tolerance (0 = a hard line), one for the frequency tolerance, a curve menu, a level per selected sound
--   * MAKE RESULT writes <name of the first sound>_cross<N>.ats (never over an existing file; in the project's ReaATS folder when the project is saved) and opens it.
-- The state stays while the editor runs (the page is reopened where you left it).
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
local ats = dofile(here .. "/ats_file.lua")
local cross = dofile(here .. "/ats_cross.lua")

local M = {}
local Page = {}
Page.__index = Page

local MEMORY_FACTOR = 2.1                           -- Lua tables take about this many times the size of an .ats file
local BLUE, GREEN = { 0.29, 0.64, 1.0 }, { 0.37, 0.83, 0.54 }
local LANE_COL = { a = BLUE, b = GREEN }
local THUMB_W, THUMB_H, FMIN, FMAX, FLOOR_DB = 640, 72, 50, 10000, 60
local THUMB_FIRST, MAX_BLOCKS = 20, 40              -- the images of the blocks live in image buffers 20 ...

local function clamp(x, a, b) if x < a then return a elseif x > b then return b else return x end end
local function basename(p) return p:match("([^/\\]+)$") or p end

function M.new(env)
  local self = setmetatable({}, Page)
  self.env = env
  self.blocks = {}                                  -- { id, lane ("a" / "b"), path, file, name, d, origin (timeline seconds of file time 0), t0, t1 (the used part, file time), gain_db, tid (image buffer) ... }
  self.sel = {}                                     -- the selected block of each lane: { a = block, b = block } (what EDIT A / EDIT B open)
  self.cur = nil                                    -- THE selected block (in either lane): the level slider changes it; it is shown with a thick frame
  self.next_id = 1
  self.lines = {}                                   -- by transition key: the red line (seconds on the timeline)
  self.diags = {}                                   -- by transition key: the points of a diagonal { t (timeline s), f (Hz) } x 2 (Ctrl+click in a lane)
  self.tol_time, self.tol_cents = 0.6, 100          -- the tolerances a transition has until its own are set (see tol_of)
  self.tr_set = {}                                  -- by transition key: { time, cents } = the tolerances of that transition
  self.active = nil                                 -- the key of the transition whose red line is active: the sliders change its tolerances
  self.curve = "smooth"                             -- the shape of the crossover (see ats_cross): smooth, linear, equal, s; what a transition has until its own is set (see curve_of)
  self.view = { 0, 10 }
  self.drag, self.prev_down = nil, false
  self.message = nil
  self.results = {}                                 -- by file name: { transitions, threads, t_start } of every result that was made (the editor draws the lines over it)
  return self
end

-- 20 % or less memory free: a warning replaces the message (and shows in red)
function Page:memory_check()
  if not self.env.memory_warning then return end
  local low, msg = self.env.memory_warning()
  if low then self:say(msg, true) end
end

function Page:say(msg) self.message = msg end

-- ------------------------------------------------------------------ the blocks
local function sound_end(s) return s.d.times[s.d.frames] end
function Page:pos_of(s) return s.origin + s.t0 end
function Page:end_of(s) return s.origin + s.t1 end

-- The blocks of a lane, in the order they start.
function Page:lane_blocks(lane)
  local out = {}
  for _, b in ipairs(self.blocks) do if b.lane == lane then out[#out + 1] = b end end
  table.sort(out, function(x, y) return self:pos_of(x) < self:pos_of(y) end)
  return out
end

-- All blocks in the order they start (what the crossing follows).
function Page:sorted()
  local out = {}
  for i, b in ipairs(self.blocks) do out[i] = { i = i, b = b } end
  table.sort(out, function(x, y)
    local px, py = self:pos_of(x.b), self:pos_of(y.b)
    if px ~= py then return px < py end
    return x.i < y.i
  end)
  for i, o in ipairs(out) do out[i] = o.b end
  return out
end

function Page:selected(lane) return self.sel[lane] or (self:lane_blocks(lane)[#self:lane_blocks(lane)]) end

function Page:alloc_tid()
  local used = {}
  for _, b in ipairs(self.blocks) do used[b.tid] = true end
  for id = THUMB_FIRST, THUMB_FIRST + MAX_BLOCKS - 1 do if not used[id] then return id end end
end

-- The TRANSITIONS: every block after the first, in the order of starting, that overlaps what came before (the block that ends last of those) is one.
-- { k (place in the order), l (the block that flows in), r (the block it flows into), lo, hi (the overlap, seconds), key }
function Page:transitions()
  local out, max_end, partner = {}, nil, nil
  for k, b in ipairs(self:sorted()) do
    if k > 1 then
      local lo, hi = self:pos_of(b), math.min(self:end_of(b), max_end)
      if hi > lo + 1e-6 then out[#out + 1] = { k = k, l = partner, r = b, lo = lo, hi = hi, key = partner.id .. "_" .. b.id } end
    end
    if not max_end or self:end_of(b) > max_end then max_end, partner = self:end_of(b), b end
  end
  return out
end

-- The tolerances of a transition (its own once they were set, else the page's).
-- The curve of a transition (its own once it was chosen, else the page's).
function Page:curve_of(tr)
  local v = tr and self.tr_set[tr.key]
  return (v and v.curve) or self.curve
end

function Page:tol_of(tr)
  local v = tr and self.tr_set[tr.key]
  return (v and v.time) or self.tol_time, (v and v.cents) or self.tol_cents
end

-- The active transition (its red line is drawn in full, the others fainter; the sliders change its tolerances): the one that was chosen last, else the first.
function Page:active_tr()
  local trs = self:transitions()
  for _, tr in ipairs(trs) do if tr.key == self.active then return tr end end
  return trs[1]
end

function Page:line_of(tr)
  local v = clamp(self.lines[tr.key] or (tr.lo + tr.hi) / 2, tr.lo, tr.hi)
  self.lines[tr.key] = v
  return v
end

-- The diagonal of a transition: { t1, f1, t2, f2 } with the low point first, or nil (a vertical line).
function Page:diag_of(tr)
  local p = self.diags[tr.key]
  if not p or #p < 2 then return nil end
  local lo, hi = p[1], p[2]
  if lo.f > hi.f then lo, hi = hi, lo end
  return { lo.t, lo.f, hi.t, hi.f }
end

-- UNDO (tjingboem, 13 Nov 2026: "i accidentally deleted a ats file in crossing. Can we have a Ctrl+Z function here?"): the recipe (the sounds with their place, cuts and
-- level, the lines, the tolerances, the curve, the diagonals) is copied before every change (the sound data itself is shared, not copied); Ctrl+Z goes back, Ctrl+Y
-- forward. A removed sound stays in memory while the undo list holds it (the last 20 steps).
function Page:capture()
  local blocks, sel_id = {}, {}
  for i, b in ipairs(self.blocks) do
    local c = {}
    for k, v in pairs(b) do c[k] = v end
    blocks[i] = c
    for lane, sb in pairs(self.sel) do if sb == b then sel_id[lane] = b.id end end
    if self.cur == b then sel_id.cur = b.id end
  end
  local lines, diags = {}, {}
  for k, v in pairs(self.lines) do lines[k] = v end
  for k, pts in pairs(self.diags) do local c = {}; for i, p in ipairs(pts) do c[i] = { t = p.t, f = p.f } end; diags[k] = c end
  local tr_set = {}
  for k, v in pairs(self.tr_set) do tr_set[k] = { time = v.time, cents = v.cents, curve = v.curve } end
  return { blocks = blocks, sel_id = sel_id, lines = lines, diags = diags, tr_set = tr_set, active = self.active, tol_time = self.tol_time, tol_cents = self.tol_cents, curve = self.curve }
end
function Page:push_undo(state)
  self.undo = self.undo or {}
  self.undo[#self.undo + 1] = state or self:capture()
  if #self.undo > 20 then table.remove(self.undo, 1) end
  self.redo = {}
end
function Page:restore(st)
  self.blocks, self.lines, self.diags = st.blocks, st.lines, st.diags
  self.tol_time, self.tol_cents, self.curve = st.tol_time, st.tol_cents, st.curve
  self.tr_set, self.active = st.tr_set, st.active
  self.sel, self.cur = {}, nil
  for _, b in ipairs(self.blocks) do
    for lane, id in pairs(st.sel_id) do
      if b.id == id then if lane == "cur" then self.cur = b else self.sel[lane] = b end end
    end
    self:make_thumb(b)
  end
  self.zoomed = false
  self:fit_view(true)
  self:recount()
end
function Page:undo_step()
  local st = self.undo and table.remove(self.undo)
  if not st then self:say("nothing to undo"); return end
  self.redo = self.redo or {}
  self.redo[#self.redo + 1] = self:capture()
  self:restore(st)
  self:say("undone")
end
function Page:redo_step()
  local st = self.redo and table.remove(self.redo)
  if not st then self:say("nothing to redo"); return end
  self.undo[#self.undo + 1] = self:capture()
  self:restore(st)
  self:say("redone")
end

-- The recipe for the crossing code: the sounds in the order of starting, a red line (and diagonal) for every transition.
local function block_spec(self, b) return { d = b.d, t0 = b.t0, t1 = b.t1, pos = self:pos_of(b), gain = 10 ^ ((b.gain_db or 0) / 20) } end
function Page:spec()
  local blocks, steps = {}, {}
  for i, b in ipairs(self:sorted()) do blocks[i] = block_spec(self, b) end
  for _, tr in ipairs(self:transitions()) do
    local tt, tc = self:tol_of(tr)
    steps[tr.k] = { line = self:line_of(tr), diag = self:diag_of(tr), tol_time = tt, tol_cents = tc, curve = self:curve_of(tr) }
  end
  return { blocks = blocks, steps = steps, tol_time = self.tol_time, tol_cents = self.tol_cents, curve = self.curve }
end

-- How many threads the present recipe would make (counted when something is let go, not while it moves): every transition is counted between the two sounds
-- that meet there. Skipped for big sounds (the count resamples both).
function Page:recount()
  self.threads_est, self.thread_lines, self.counts = nil, nil, {}
  local total, lines = 0, {}
  for _, tr in ipairs(self:transitions()) do
    local l, r = tr.l, tr.r
    local cells = l.d.partials * l.d.frames + r.d.partials * r.d.frames
    if cells > 3e6 then
      self.counts[tr.key] = -1                                                      -- (too big to count in advance)
    else
      local info = cross.count({ a = block_spec(self, l), b = block_spec(self, r), line = self:line_of(tr), diag = self:diag_of(tr),
                                 tol_time = select(1, self:tol_of(tr)), tol_cents = select(2, self:tol_of(tr)), curve = self:curve_of(tr) })
      if info then
        total = total + info.pairs
        self.counts[tr.key] = info.pairs
        for _, th in ipairs(info.threads) do
          lines[#lines + 1] = { lane_l = l.lane, lane_r = r.lane, fl = th.fl, fr = th.fr, t0 = th.t0, t1 = th.t1, key = tr.key }
        end
      end
    end
  end
  if #self:sorted() >= 2 then self.threads_est = total end
  self.thread_lines = lines
end

function Page:fit_view(force)
  if force then self.zoomed = false end
  if self.zoomed then return end                                      -- (a view that was zoomed by hand stays until a sound is loaded or removed)
  local lo, hi
  for _, s in ipairs(self.blocks) do
    local a, b = s.origin + s.d.times[1], s.origin + sound_end(s)
    lo = lo and math.min(lo, a) or a
    hi = hi and math.max(hi, b) or b
  end
  if not lo then self.view = { 0, 10 }; return end
  local m = math.max((hi - lo) * 0.06, 0.05)
  self.view = { lo - m, hi + m }
end

-- The low resolution image of a sound: THUMB_W x THUMB_H cells (time sideways over the whole file, frequency up on a log scale from FMIN to FMAX, the same for all
-- sounds), the loudest partial in a cell, brightness = level over 60 dB below the loudest. Drawn once into an image buffer of its own (tid).
function Page:make_thumb(s)
  local d = s.d
  local cells = {}
  local t0, span = d.times[1], math.max(d.times[d.frames] - d.times[1], 1e-9)
  local lfmin, lrange = math.log(FMIN), math.log(FMAX / FMIN)
  local max = 0
  for p = 1, d.partials do
    local amp, frq = d.amp[p], d.frq[p]
    for f = 1, d.frames do
      local a = amp[f]
      if a > 0 and frq[f] >= FMIN and frq[f] < FMAX then
        local x = math.floor((d.times[f] - t0) / span * (THUMB_W - 1)) + 1
        local y = math.floor((math.log(frq[f]) - lfmin) / lrange * THUMB_H) + 1
        local k = (y - 1) * THUMB_W + x
        if a > (cells[k] or 0) then cells[k] = a; if a > max then max = a end end
      end
    end
  end
  local col = LANE_COL[s.lane]
  local id = s.tid
  gfx.setimgdim(id, THUMB_W, THUMB_H)
  gfx.dest = id
  gfx.set(0.06, 0.07, 0.09, 1)
  gfx.rect(0, 0, THUMB_W, THUMB_H, 1)
  for k, a in pairs(cells) do
    local v = math.min(math.max((20 * math.log(a / max, 10) + FLOOR_DB) / FLOOR_DB, 0), 1)
    if v > 0.02 then
      v = v ^ 0.7
      local x, y = (k - 1) % THUMB_W, (k - 1) // THUMB_W
      gfx.set(col[1] * v, col[2] * v, col[3] * v, 1)
      gfx.rect(x, THUMB_H - 1 - y, 1, 1, 1)
    end
  end
  gfx.dest = -1
  s.thumb = true
end

-- Where a new sound goes: at the end of its lane (the lane's sounds follow each other); the first sound of lane B starts half over the end of the last sound of lane A,
-- so that there is a transition space to begin with.
function Page:place(b)
  local last = self:lane_blocks(b.lane)
  last = last[#last]
  if last then
    b.origin = self:end_of(last) - b.t0
  elseif b.lane == "b" then
    local a = self:lane_blocks("a")
    a = a[#a]
    if a then
      local over = 0.5 * math.min(a.t1 - a.t0, b.t1 - b.t0)
      b.origin = (self:end_of(a) - over) - b.t0
    end
  end
end

-- Adds a sound to a lane.
function Page:add_block(lane, b)
  if #self.blocks >= MAX_BLOCKS then self:say("too many sounds"); return false end
  b.lane, b.id, b.tid = lane, self.next_id, self:alloc_tid()
  self.next_id = self.next_id + 1
  self:place(b)
  self:push_undo()
  self.blocks[#self.blocks + 1] = b
  self.sel[lane] = b
  self.cur = b
  self:make_thumb(b)
  self:recount()
  self:fit_view(true)
  return true
end

-- Loads an .ats file as a new block at the end of lane "a" or "b". The memory check: all the files and the result must fit in about 85 % of the free memory.
function Page:load(lane, path)
  local h, err = ats.header(path)
  if not h then self:say(tostring(err)); return false end
  local need = h.bytes * MEMORY_FACTOR * 1.5
  for _, o in ipairs(self.blocks) do need = need + (o.bytes or 0) * MEMORY_FACTOR * 1.5 end
  local free = self.env.available_memory and self.env.available_memory(need)
  if free and need > free * 0.85 then
    self:say(string.format("not enough memory for this (%.1f GB needed, %.1f GB free): analyse with a higher threshold or use a shorter part", need / 2^30, free / 2^30))
    return false
  end
  local d, lerr = ats.load(path)
  if not d then self:say(tostring(lerr)); return false end
  local s = { path = path, file = path, name = basename(path), d = d, origin = 0, t0 = d.times[1], t1 = d.times[d.frames], bytes = h.bytes, full = true, edited = false }
  if not self:add_block(lane, s) then return false end
  self:say(string.format("%s loaded: %.2f s, %d partials", s.name, d.dur, d.partials))
  self:memory_check()
  return true
end

-- Right-click on a block: the sound leaves its lane. A sound with changes that are not in a file asks first (nothing else would bring it back).
function Page:remove(b)
  if not b then return end
  if b.edited then
    local answer = reaper.MB(b.name .. " has changes that are not saved. Remove it anyway?", "ReaATS", 4)
    if answer ~= 6 then return end
  end
  self:push_undo()
  for i, o in ipairs(self.blocks) do if o == b then table.remove(self.blocks, i); break end end
  if self.sel[b.lane] == b then self.sel[b.lane] = nil end
  if self.cur == b then self.cur = nil end
  self:fit_view(true)
  self:recount()
  self:say(b.name .. " removed")
end

-- A double-click on a block (or EDIT): the sound opens in the editor, from memory (no file is read, nothing has to be saved), to edit it (a stretch to make it
-- longer, for example). The editor works on the very same table: when you press CROSS again the page has your changes.
function Page:edit_in_editor(lane, block)
  local s = block or self:selected(lane)
  if not s then return end
  self.sel[s.lane] = s
  self.cur = s
  if self.env.open_in_editor(s.d, s.file or s.path, (not s.edited) and s.path or nil, s.edited) then
    self.editing = s
    self.env.set_status(string.format("%s is open in the editor: edit it and press CROSS to come back (nothing needs to be saved)", s.name))
  else
    self:say("the sound could not be opened in the editor")
  end
end

-- Called when the page is shown again: a sound that the editor works on has changed (longer, other partials ...): its image and its used part follow.
function Page:enter()
  local st = self.env.editor_state()
  for _, s in ipairs(self.blocks) do
    if st.data == s.d then
      local changed = st.modified or (st.current ~= s.path)
      local d = s.d
      if s.full or s.t1 > d.times[d.frames] then s.t0, s.t1 = d.times[1], d.times[d.frames] end
      s.t0 = math.max(s.t0, d.times[1])
      if changed then s.edited = true end
      self:make_thumb(s)
      if self.editing == s and changed then self:say(string.format("%s has the changes made in the editor (nothing had to be saved)", s.name)) end
    end
  end
  self.editing = nil
  self:fit_view(true)
  self:recount()
end

function Page:choose(lane)
  local path
  if reaper.JS_Dialog_BrowseForOpenFiles then
    local rv, chosen = reaper.JS_Dialog_BrowseForOpenFiles("Load sound " .. lane:upper() .. " (.ats file)", "", "", "ATS files (*.ats)\0*.ats\0All files (*.*)\0*.*\0\0", false)
    if rv == 1 and chosen and chosen ~= "" then path = chosen end
  else
    local ok, p = reaper.GetUserFileNameForRead("", "Load sound " .. lane:upper() .. " (.ats file)", "ats")
    if ok and p ~= "" then path = p end
  end
  if path then self:load(lane, path) end
end

-- The sound that the editor holds is added to a lane: the table itself, in memory (edits made in the editor are in it; nothing has to be saved). When it is already a
-- block of the page, that block is selected instead.
function Page:use_open_sound(lane)
  local st = self.env.editor_state()
  if not st.data then self:say("no sound is open in the editor"); return end
  local d = st.data
  for _, o in ipairs(self.blocks) do
    if o.d == d then self.sel[o.lane] = o; self.cur = o; self:say(o.name .. " is on the page already"); return end
  end
  local s = { d = d, path = st.current or st.file, file = st.file, name = basename(st.file or "sound.ats"), bytes = 0, origin = 0,
              t0 = d.times[1], t1 = d.times[d.frames], full = true, edited = st.modified or (st.current ~= st.file) }
  if not self:add_block(lane, s) then return end
  self:say(string.format("the sound of the editor is added: %s%s", s.name, s.edited and " (with the changes made in the editor)" or ""))
end

-- Frequency <-> height in a lane (the pictures: log scale, FMIN .. FMAX, 4 px inside the lane).
function Page:f_to_y(lane, f) return lane.y + 4 + (lane.h - 8) * (1 - (math.log(f) - math.log(FMIN)) / math.log(FMAX / FMIN)) end
function Page:y_to_f(lane, y)
  local fr = clamp(1 - (y - lane.y - 4) / (lane.h - 8), 0, 1)
  return FMIN * (FMAX / FMIN) ^ fr
end

-- Listens to the crossing without making a file: the result is built in memory and played from its start to its end; a playhead moves along the timeline.
function Page:audition()
  if #self.blocks < 2 then self:say("load two sounds first"); return end
  local d, info = cross.build_timeline(self:spec())
  if not d then self:say("cannot audition: " .. tostring(info)); return end
  self.aud_t_start = info.t_start                                                  -- (where the start of the result lies on the timeline: for the playhead)
  if not self.env.audition(d, 0, nil) then return end                              -- always from 0 s to the end (tjingboem, 14 Nov 2026)
  self:say("listening")
end

-- Makes the result (a new file) and opens it in the editor.
function Page:make()
  if #self.blocks < 2 then self:say("load two sounds first"); return end
  local order = self:sorted()
  local stem = order[1].path:gsub("%.[^./\\]+$", ""):gsub("_ch%d+$", ""):gsub("_edit%d*$", "")
  stem = (self.env.relocate and self.env.relocate(stem)) or stem
  local n, path = 1, nil
  repeat path = string.format("%s_cross%d.ats", stem, n); n = n + 1 until not reaper.file_exists(path)
  local info, err = cross.make_timeline(self:spec(), path)
  if not info then self:say("cannot make the result: " .. tostring(err)); return end
  local trs = self:transitions()
  local keys = {}
  for _, tr in ipairs(trs) do keys[tr.k] = tr.key end
  for _, t in ipairs(info.transitions) do t.key = keys[t.k] end
  self.results[path] = { path = path, transitions = info.transitions, t_start = info.t_start, threads = info.threads }
  local msg = string.format("%s: %d partials in %d rows, %d thread%s", basename(path), info.tracks, info.rows, info.pairs, info.pairs == 1 and "" or "s")
  if self.env.on_open(path) then
    self.env.set_status(msg)
    self.env.back()
  else
    self:say("the result was written but could not be opened: " .. path)
  end
end

-- ------------------------------------------------------------------ geometry
-- The places come from the layout (lib/cross_layout.lua, made by tools/gen_cross_layout.py from the ReaLayout file) in pixels of the default window; an
-- element that is not in the layout has the default place below. The layout's y counts from the top of the window, the page starts `top` (40) from it.
function Page:el(id, dx, dy, dw, dh, top, optional)
  local lay = self.env.layout and self.env.layout.el
  local e = lay and lay[id]
  if e then return e.x, e.y - 40 + top, e.w, e.h end
  if lay and optional then return nil end                         -- (left out of the layout: not drawn, as on the Analysis page)
  return dx, top + dy, dw, dh
end

-- The text on a button or the title: the label of its element in the layout (rename it in ReaLayout), else the built-in one.
function Page:label(id, default)
  local lay = self.env.layout and self.env.layout.el and self.env.layout.el[id]
  return (lay and lay.label and lay.label ~= "") and lay.label or default
end

function Page:geom(W, H, top)
  local g = { texts = {} }
  local ax, ay, aw, ah = self:el("lane_a", 40, 80, W - 80, 104, top)
  local bx, by, bw, bh = self:el("lane_b", 40, 220, W - 80, 104, top)
  g.x0, g.x1 = ax, ax + aw
  g.laneA, g.laneB = { y = ay, h = ah }, { y = by, h = bh }
  g.lane = { a = g.laneA, b = g.laneB }
  local rx, ry = self:el("ruler", 40, 330, aw, 16, top)
  g.ruler = ry
  local function box(id, dx, dy, dw, dh) local x, y, w, h = self:el(id, dx, dy, dw, dh, top); return { x = x, y = y, w = w, h = h } end
  g.sl_time = box("sl_time", 40, 394, 300, 10)
  g.sl_freq = box("sl_freq", 420, 394, 300, 10)
  local function obox(id, dx, dy, dw, dh) local x, y, w, h = self:el(id, dx, dy, dw, dh, top, true); if x then return { x = x, y = y, w = w, h = h } end end
  g.dd_curve = obox("dd_curve", 740, 394, 150, 22)
  g.sl_gain = obox("sl_gain", 660, 52, 200, 10) or obox("sl_gain_a", 660, 52, 200, 10)       -- (one level slider for the selected block; an older layout has sl_gain_a / sl_gain_b: the first is used)
  local function rect(id, dx, dy, dw, dh) local x, y, w, h = self:el(id, dx, dy, dw, dh, top); return { x, y, w, h } end
  g.btn = {
    back = rect("btn_back", W - 120, 6, 90, 24),
    load_a = rect("btn_load_a", 40, 44, 110, 24), edit_a = rect("btn_edit_a", 158, 44, 190, 24), open_a = rect("btn_use_a", 356, 44, 290, 24),
    load_b = rect("btn_load_b", 40, 188, 110, 24), edit_b = rect("btn_edit_b", 158, 188, 190, 24), open_b = rect("btn_use_b", 356, 188, 290, 24),
    make = rect("btn_make", 40, 434, 190, 32),
  }
  local ax, ay, aw, ah = self:el("btn_audition", 240, 434, 110, 32, top, true)
  if ax then g.btn.audition = { ax, ay, aw, ah } end
  local function pt(id, dx, dy, always) local x, y = self:el(id, dx, dy, 0, 0, top, not always); if x then return { x = x, y = y } end end
  g.texts = { title = pt("txt_title", 40, 8), threads = pt("txt_threads", 40, 416), hint = pt("txt_make_hint", 244, 443),
              message = pt("txt_message", 40, 478, true), help1 = pt("txt_help1", 40, 506), help2 = pt("txt_help2", 40, 524) }
  local function sc(id, lane, dx)                                  -- the numbers of the frequency scale: a box whose height is the height of the picture
    local x, y, w, h = self:el(id, dx, lane.y + 4 - top, 34, lane.h - 8, top, true)
    if x then return { x = x, y = y, w = w, h = h } end
  end
  g.scale_a, g.scale_b = sc("scale_hz_a", g.laneA, g.x0 - 38), sc("scale_hz_b", g.laneB, g.x0 - 38)
  g.pps = (g.x1 - g.x0) / math.max(self.view[2] - self.view[1], 1e-6)
  return g
end

function Page:tx(g, t) return g.x0 + (t - self.view[1]) * g.pps end
function Page:tt(g, x) return self.view[1] + (x - g.x0) / g.pps end

local function inside(r, mx, my) return mx >= r[1] and mx < r[1] + r[3] and my >= r[2] and my < r[2] + r[4] end

-- ------------------------------------------------------------------ mouse
-- The longest time tolerance: 4 s, or the longest overlap when that is longer (a transition needs time: tjingboem, 13 Nov 2026).
function Page:time_max()
  local tr = self:active_tr()
  return tr and math.max(4, tr.hi - tr.lo) or 4
end

function Page:slider_value(g, which, mx)
  local s = g[which]
  local frac = clamp((mx - s.x) / s.w, 0, 1)
  local tr = self:active_tr()
  local v
  if tr then v = self.tr_set[tr.key] or { time = self.tol_time, cents = self.tol_cents }; self.tr_set[tr.key] = v end
  if which == "sl_time" then
    local t = math.floor(frac * frac * self:time_max() * 100 + 0.5) / 100        -- finer at the short end
    if v then v.time = t else self.tol_time = t end
  else
    local c = math.floor((10 + frac * 590) / 10 + 0.5) * 10
    if v then v.cents = c else self.tol_cents = c end
  end
end

-- The gain of the selected sound (dB): the one level slider, -24 .. +12, sticks at 0.
local GAIN_MIN, GAIN_MAX = -24, 12
local CURVES = { { "smooth", "Smooth" }, { "linear", "Linear" }, { "equal", "Equal power" }, { "s", "S curve" } }
local function curve_name(k) for _, c in ipairs(CURVES) do if c[1] == k then return c[2] end end return k end
function Page:gain_value(g, mx)
  local s, sl = self.cur, g.sl_gain
  if not (s and sl) then return end
  local db = GAIN_MIN + clamp((mx - sl.x) / sl.w, 0, 1) * (GAIN_MAX - GAIN_MIN)
  db = math.floor(db * 2 + 0.5) / 2
  if math.abs(db) < 0.75 then db = 0 end
  s.gain_db = db
end

-- The block under the pointer (the one drawn last wins), or nil.
function Page:block_at(g, mx, my)
  local found
  for _, s in ipairs(self.blocks) do
    local lane = g.lane[s.lane]
    if my >= lane.y and my < lane.y + lane.h and mx >= self:tx(g, self:pos_of(s)) and mx <= self:tx(g, self:end_of(s)) then found = s end      -- (only the used part is there)
  end
  return found
end

-- Zoom with the wheel round the pointer (Shift + wheel scrolls), a drag on the ruler scrolls.
function Page:zoom(g, mx, wheel, shift)
  local v = self.view
  local span = v[2] - v[1]
  if shift then
    local d = -wheel / 120 * span * 0.1
    self.view = { v[1] + d, v[2] + d }
  else
    local t = self:tt(g, mx)
    local k = 0.8 ^ (wheel / 120)
    local ns = clamp(span * k, 0.05, 3600)
    local f = (t - v[1]) / span
    self.view = { t - f * ns, t + (1 - f) * ns }
  end
  self.zoomed = true
end

-- The neighbours of a block in its lane at this moment: where the one before it ends and the one after it starts (a block may not overlap them).
function Page:neighbours(b)
  local prev_end, next_pos
  for _, o in ipairs(self.blocks) do
    if o ~= b and o.lane == b.lane then
      if self:end_of(o) <= self:pos_of(b) + 1e-9 then prev_end = math.max(prev_end or -1e18, self:end_of(o)) end
      if self:pos_of(o) >= self:end_of(b) - 1e-9 then next_pos = math.min(next_pos or 1e18, self:pos_of(o)) end
    end
  end
  return prev_end, next_pos
end

-- When a block is let go it must not lie over another one in its lane: it goes to the nearest free place (before or after the sounds it was dropped on).
function Page:settle(b)
  local w = b.t1 - b.t0
  local pos = self:pos_of(b)
  local others = {}
  for _, o in ipairs(self.blocks) do if o ~= b and o.lane == b.lane then others[#others + 1] = o end end
  table.sort(others, function(x, y) return self:pos_of(x) < self:pos_of(y) end)
  local best, bd
  local function try(lo, hi)                                      -- a free stretch from lo to hi
    if hi - lo + 1e-9 < w then return end
    local c = clamp(pos, lo, hi - w)
    local dist = math.abs(c - pos)
    if not bd or dist < bd then best, bd = c, dist end
  end
  local lo = -1e18
  for _, o in ipairs(others) do
    try(lo, self:pos_of(o))
    lo = math.max(lo, self:end_of(o))
  end
  try(lo, 1e18)
  if best and math.abs(best - pos) > 1e-9 then b.origin = best - b.t0 end
end

function Page:mouse(mx, my, cap, wheel)
  local W, H = math.floor(gfx.w), math.floor(gfx.h)
  local g = self:geom(W, H, self.top or 40)
  local down = (cap & 1) ~= 0
  local right = (cap & 2) ~= 0
  local shift = (cap & 8) ~= 0
  if wheel and wheel ~= 0 and my >= g.laneA.y - 20 and my <= g.laneB.y + g.laneB.h + 40 then self:zoom(g, mx, wheel, shift) end
  if right and not self.prev_right then                           -- right-click on a block removes that sound
    local b = self:block_at(g, mx, my)
    if b then self:remove(b) end
  end
  self.prev_right = right
  if down and not self.prev_down and self.dd_open and g.dd_curve then       -- the open list of curves takes this click
    local dd = g.dd_curve
    for i, c in ipairs(CURVES) do
      if mx >= dd.x and mx < dd.x + dd.w and my >= dd.y + i * dd.h and my < dd.y + (i + 1) * dd.h and c[1] ~= self:curve_of(self:active_tr()) then
        self:push_undo()
        local tr = self:active_tr()
        if tr then
          local v = self.tr_set[tr.key] or { time = self.tol_time, cents = self.tol_cents }
          v.curve = c[1]; self.tr_set[tr.key] = v
        else self.curve = c[1] end
      end
    end
    self.dd_open = false
    self.prev_down = down
    return
  end
  if down and not self.prev_down then
    self.drag = nil
    local pre = self:capture()                                       -- (for undo: kept when the press starts a change)
    local b = g.btn
    local ctrl = (cap & 4) ~= 0
    local dd = g.dd_curve
    local in_lane = my >= g.laneA.y and my < g.laneA.y + g.laneA.h or my >= g.laneB.y and my < g.laneB.y + g.laneB.h
    if ctrl and not shift and in_lane then
      -- Ctrl+click in a lane: a point of the diagonal of the transition at that moment (low and high in the picture); the second one makes the line, a third starts again
      local t = self:tt(g, mx)
      local best, bd
      for _, tr in ipairs(self:transitions()) do
        local dist = (t < tr.lo) and (tr.lo - t) or (t > tr.hi and t - tr.hi or 0)
        if not bd or dist < bd then best, bd = tr, dist end
      end
      if best then
        local lane = (my < g.laneA.y + g.laneA.h) and g.laneA or g.laneB
        self:push_undo(pre)
        local pts = self.diags[best.key] or {}
        if #pts >= 2 then pts = {} end
        pts[#pts + 1] = { t = t, f = self:y_to_f(lane, my) }
        self.diags[best.key] = pts
        self.active = best.key
        self:recount()
      else
        self:say("no transition here")
      end
      self.prev_down = down
      return
    elseif dd and mx >= dd.x and mx < dd.x + dd.w and my >= dd.y and my < dd.y + dd.h then self.dd_open = true
    elseif inside(b.back, mx, my) then self.env.back()
    elseif inside(b.load_a, mx, my) then self:choose("a")
    elseif inside(b.edit_a, mx, my) then self:edit_in_editor("a")
    elseif inside(b.open_a, mx, my) then self:use_open_sound("a")
    elseif inside(b.edit_b, mx, my) then self:edit_in_editor("b")
    elseif inside(b.open_b, mx, my) then self:use_open_sound("b")
    elseif inside(b.load_b, mx, my) then self:choose("b")
    elseif inside(b.make, mx, my) then self:make()
    elseif b.audition and inside(b.audition, mx, my) then self:audition()
    else
      for _, which in ipairs({ "sl_time", "sl_freq", "sl_gain" }) do
        local sl = g[which]
        if sl and mx >= sl.x - 6 and mx < sl.x + sl.w + 6 and my >= sl.y - 8 and my < sl.y + sl.h + 8 then
          if which == "sl_gain" then
            if self.cur then
              self.drag = { kind = "gain" }
              self:gain_value(g, mx)
            else
              self:say("select a block first")
            end
          else
            self.drag = { kind = "slider", which = which }
            self:slider_value(g, which, mx)
          end
        end
      end
      if not self.drag and my >= g.ruler - 4 and my <= g.ruler + 16 and mx >= g.x0 and mx <= g.x1 then
        local now = reaper.time_precise()
        local lc = self.last_ruler
        if lc and now - lc < 0.45 then self.last_ruler = nil; self:fit_view(true)       -- a double-click on the ruler: the whole timeline again
        else self.last_ruler = now; self.drag = { kind = "pan", x = mx, v0 = self.view[1], v1 = self.view[2], acc = 0 } end
      end
      if not self.drag then
        for _, tr in ipairs(self:transitions()) do                    -- the red line of a transition (a diagonal is moved by making a new one)
          if not self:diag_of(tr) then
            local lx = self:tx(g, self:line_of(tr))
            if math.abs(mx - lx) <= 7 and my >= g.laneA.y - 14 and my <= g.laneB.y + g.laneB.h + 4 then
              self.drag = { kind = "line", key = tr.key, tr = tr, x = mx, hx = lx, acc = 0 }
              self.active = tr.key                                         -- (the sliders now change this transition)
              break
            end
          end
        end
      end
      if not self.drag then
        local hit
        for _, s in ipairs(self.blocks) do                            -- the cut handles first (at the ends of the used part), then the body
          local lane = g.lane[s.lane]
          if my >= lane.y and my < lane.y + lane.h then
            local x0, x1 = self:tx(g, self:pos_of(s)), self:tx(g, self:end_of(s))
            if math.abs(mx - x0) <= 7 then hit = { s = s, kind = "cut_in", hx = x0 }
            elseif math.abs(mx - x1) <= 7 then hit = { s = s, kind = "cut_out", hx = x1 } end
            if hit then break end
          end
        end
        local body = (not hit) and self:block_at(g, mx, my) or nil
        local s = hit and hit.s or body
        if s then
          self.sel[s.lane] = s
          self.cur = s
          local now = reaper.time_precise()
          local lc = self.last_click
          if lc and lc.block == s and now - lc.t < 0.45 and math.abs(mx - lc.x) <= 5 and math.abs(my - lc.y) <= 5 then
            self.last_click = nil                                       -- a double-click on a block: this sound opens in the editor (to be edited, stretched ...)
            self:edit_in_editor(s.lane, s)
            self.prev_down = down
            return
          end
          self.last_click = { block = s, t = now, x = mx, y = my }
          local prev_end, next_pos = self:neighbours(s)
          if hit then self.drag = { kind = hit.kind, block = s, x = mx, hx = hit.hx, acc = 0, prev_end = prev_end, next_pos = next_pos }
          else self.drag = { kind = "move", block = s, x = mx, acc = 0, pos0 = self:pos_of(s), prev_end = prev_end, next_pos = next_pos } end
        end
      end
    end
    if self.drag and self.drag.kind ~= "pan" then self:push_undo(pre) end
  elseif down and self.drag then
    local d = self.drag
    if d.x then                                                      -- Shift = fine: a tenth of the movement of the mouse
      d.acc = d.acc + (mx - d.x) * (shift and 0.1 or 1)
      d.x = mx
    end
    if d.kind == "slider" then self:slider_value(g, d.which, mx)
    elseif d.kind == "gain" then self:gain_value(g, mx)
    elseif d.kind == "pan" then
      local dt = -d.acc / g.pps
      self.view = { d.v0 + dt, d.v1 + dt }
      self.zoomed = true
    elseif d.kind == "line" then
      self.lines[d.key] = clamp(self:tt(g, d.hx + d.acc), d.tr.lo, d.tr.hi)
    elseif d.kind == "move" then
      local s = d.block
      local w = s.t1 - s.t0
      s.origin = d.pos0 + d.acc / g.pps - s.t0                                  -- (over its neighbours while it moves; it settles in a free place when it is let go)
      local want
      if my >= g.laneA.y and my < g.laneA.y + g.laneA.h then want = "a" elseif my >= g.laneB.y and my < g.laneB.y + g.laneB.h then want = "b" end
      if want and want ~= s.lane then                                           -- dragged to the other lane
        if self.sel[s.lane] == s then self.sel[s.lane] = nil end
        s.lane = want
        self.sel[want] = s
        self:make_thumb(s)                                                      -- (the picture takes the colour of its lane)
      end
    elseif d.kind == "cut_in" then
      local s = d.block
      local lowest = s.d.times[1]
      if d.prev_end then lowest = math.max(lowest, d.prev_end - s.origin) end
      s.t0 = clamp(self:tt(g, d.hx + d.acc) - s.origin, lowest, s.t1 - 0.05)
      s.full = false
    elseif d.kind == "cut_out" then
      local s = d.block
      local highest = sound_end(s)
      if d.next_pos then highest = math.min(highest, d.next_pos - s.origin) end
      s.t1 = clamp(self:tt(g, d.hx + d.acc) - s.origin, s.t0 + 0.05, highest)
      s.full = false
    end
  end
  if not down then
    if self.drag then
      if self.drag.kind == "move" then self:settle(self.drag.block) end
      if self.drag.kind == "move" or self.drag.kind == "cut_in" or self.drag.kind == "cut_out" then self:fit_view() end
      self.drag = nil
      self:recount()
    end
  end
  self.prev_down = down
end

function Page:key(ch)
  if ch == 27 and (next(self.diags) ~= nil or self.dd_open) then self.diags = {}; self.dd_open = false; self:recount(); return true end     -- Esc: back to vertical lines
  if ch == 9 then                                                                 -- Tab: the next transition becomes the active one
    local trs, cur = self:transitions(), self:active_tr()
    for i, tr in ipairs(trs) do if cur and tr.key == cur.key then self.active = trs[i % #trs + 1].key; return true end end
    return #trs > 0
  end
  if ch == 26 then self:undo_step(); return true end                              -- Ctrl+Z
  if ch == 25 then self:redo_step(); return true end                              -- Ctrl+Y
  if ch == 13 then self:make(); return true end
  if ch == 32 then self.env.stop_audition(); return true end
  if ch == 97 or ch == 65 then self:audition(); return true end
  return false
end

-- ------------------------------------------------------------------ drawing
local function text(x, y, s, r, g, b, a) gfx.set(r or 0.85, g or 0.87, b or 0.9, a or 1); gfx.x, gfx.y = x, y; gfx.drawstr(s) end

-- Rounded buttons (tjingboem, 14 Nov 2026): the fill is two rectangles and four circles, the border is gfx.roundrect (a plain rectangle where that is missing).
local function rfill(x, y, w, h)
  local r = math.max(0, math.min(5, math.floor(h / 2), math.floor(w / 2)))
  if r < 2 then gfx.rect(x, y, w, h, 1); return end
  gfx.rect(x + r, y, w - 2 * r, h, 1)
  gfx.rect(x, y + r, w, h - 2 * r, 1)
  gfx.circle(x + r, y + r, r, 1, 1); gfx.circle(x + w - r - 1, y + r, r, 1, 1)
  gfx.circle(x + r, y + h - r - 1, r, 1, 1); gfx.circle(x + w - r - 1, y + h - r - 1, r, 1, 1)
end
local function rline(x, y, w, h)
  local r = math.max(0, math.min(5, math.floor(h / 2), math.floor(w / 2)))
  if gfx.roundrect and r >= 2 then gfx.roundrect(x, y, w - 1, h - 1, r, 1) else gfx.rect(x, y, w, h, 0) end
end

local function button(r, label, rgb, enabled)
  rgb = rgb or { 0.5, 0.75, 0.95 }
  local k = (enabled == false) and 0.12 or 0.4
  gfx.set(rgb[1] * k, rgb[2] * k, rgb[3] * k, 1)
  rfill(r[1], r[2], r[3], r[4])
  gfx.set(rgb[1], rgb[2], rgb[3], (enabled == false) and 0.4 or 1)
  rline(r[1], r[2], r[3], r[4])
  gfx.setfont(1, "Arial", 13)
  gfx.x, gfx.y = r[1] + (r[3] - gfx.measurestr(label)) / 2, r[2] + (r[4] - 14) / 2
  gfx.drawstr(label)
end

function Page:draw_lane(g, lane)
  local l = g.lane[lane]
  gfx.set(0.13, 0.145, 0.18, 1)
  gfx.rect(g.x0, l.y, g.x1 - g.x0, l.h, 1)
  gfx.set(0.24, 0.26, 0.31, 1)
  gfx.rect(g.x0, l.y, g.x1 - g.x0, l.h, 0)
  gfx.setfont(1, "Arial", 14)
  if #self:lane_blocks(lane) == 0 then
    text(g.x0 + 12, l.y + l.h / 2 - 8, "sound " .. lane:upper() .. ": load an .ats file (made on the Analysis page)", 0.5, 0.53, 0.6)
  end
end

-- A block shows only its USED part (tjingboem, 14 Nov 2026: what is cut away must not hide the other sounds, and "when we want to find out what is before the ats block,
-- we can drag again to make the selection bigger"): the cut-away rest of the file is not drawn; the handles at the ends of the block are dragged outwards to use more
-- of the file (up to its ends) and the picture grows with them.
function Page:draw_block(g, s)
  local lane = g.lane[s.lane]
  local col = LANE_COL[s.lane]
  local fx0, fx1 = self:tx(g, s.origin + s.d.times[1]), self:tx(g, s.origin + sound_end(s))
  local ux0, ux1 = self:tx(g, self:pos_of(s)), self:tx(g, self:end_of(s))
  local bw = fx1 - fx0
  if s.thumb and bw > 1 and ux1 > ux0 then
    local f0, f1 = (ux0 - fx0) / bw, (ux1 - fx0) / bw
    gfx.set(1, 1, 1, 1)
    gfx.blit(s.tid, 1, 0, f0 * THUMB_W, 0, (f1 - f0) * THUMB_W, THUMB_H, ux0, lane.y + 4, ux1 - ux0, lane.h - 8)
  end
  gfx.set(col[1], col[2], col[3], 1)
  gfx.rect(ux0, lane.y + 4, ux1 - ux0, lane.h - 8, 0)
  if self.cur then                                                                   -- THE selected block stands out: a thick white frame; the other blocks are dimmed
    if self.cur == s then
      gfx.set(1, 1, 1, 0.95)
      for k = 1, 3 do gfx.rect(ux0 + k, lane.y + 4 + k, ux1 - ux0 - 2 * k, lane.h - 8 - 2 * k, 0) end
    else
      gfx.set(0, 0, 0, 0.45)
      gfx.rect(ux0, lane.y + 4, ux1 - ux0, lane.h - 8, 1)
    end
  end
  gfx.set(1, 1, 1, 0.95)                                                   -- the handles of the cut
  gfx.rect(ux0 - 2, lane.y + 4, 4, lane.h - 8, 1)
  gfx.rect(ux1 - 2, lane.y + 4, 4, lane.h - 8, 1)
end

-- The little "i" of a block: a circle in the top right corner of the USED part (it moves along when the sound is cut, and stays inside the window).
local INFO_R = 8
function Page:info_pos(g, s)
  local lane = g.lane[s.lane]
  local x = math.min(self:tx(g, self:end_of(s)), g.x1) - INFO_R - 8
  x = math.max(x, math.max(self:tx(g, self:pos_of(s)), g.x0) + INFO_R + 8)
  return x, lane.y + 4 + INFO_R + 4
end

function Page:draw_info_marks(g)
  for _, s in ipairs(self.blocks) do
    local x, y = self:info_pos(g, s)
    local col = LANE_COL[s.lane]
    local hot = self.info_hover == s
    gfx.set(0.03, 0.04, 0.06, hot and 0.95 or 0.65); gfx.circle(x, y, INFO_R, 1, 1)
    gfx.set(col[1], col[2], col[3], 1); gfx.circle(x, y, INFO_R, 0, 1)
    gfx.setfont(1, "Arial", 13)
    local w, h = gfx.measurestr("i")
    gfx.x, gfx.y = x - w / 2, y - h / 2
    gfx.drawstr("i")
  end
end

-- What is known about a sound is shown in a box while the mouse is on its "i" (the blocks themselves show only the picture).
function Page:draw_tip(g, W, H)
  self.info_hover = nil
  if self.drag then return end
  local mx, my = gfx.mouse_x, gfx.mouse_y
  for _, s in ipairs(self.blocks) do
    local x, y = self:info_pos(g, s)
    if (mx - x) ^ 2 + (my - y) ^ 2 <= (INFO_R + 2) ^ 2 then
      self.info_hover = s
      local col = LANE_COL[s.lane]
      local d = s.d
      local lines = {
        "sound " .. s.lane:upper() .. ": " .. s.name .. (s.edited and "  (changed in the editor)" or ""),
        string.format("used %.2f - %.2f s of %.2f s", s.t0, s.t1, d.dur),
        string.format("%d partials, %d frames, hop %.1f ms, %d Hz", d.partials, d.frames, d.frame_size / d.sr * 1000, d.sr),
        s.path and s.path ~= "" and s.path or "(not saved as a file)",
      }
      gfx.setfont(1, "Arial", 13)
      local w = 0
      for _, l in ipairs(lines) do w = math.max(w, gfx.measurestr(l)) end
      local hh
      w, hh = w + 16, #lines * 18 + 10
      local bx, by = x + INFO_R - w, y + INFO_R + 6                 -- below the circle, ending at its right side
      bx = math.max(4, math.min(bx, W - 4 - w))
      if by + hh > H - 4 then by = y - INFO_R - 6 - hh end
      gfx.set(0.05, 0.06, 0.09, 0.96); gfx.rect(bx, by, w, hh, 1)
      gfx.set(col[1], col[2], col[3], 1); gfx.rect(bx, by, w, hh, 0)
      for i, l in ipairs(lines) do
        if i == 1 then gfx.set(col[1], col[2], col[3], 1) else gfx.set(0.85, 0.87, 0.9, 1) end
        gfx.x, gfx.y = bx + 8, by + 6 + (i - 1) * 18
        gfx.drawstr(l)
      end
      return
    end
  end
end

-- The time of the diagonal at a frequency (seconds on the timeline), inside the overlap.
function Page:diag_time(dg, f, lo, hi)
  local lf1, lf2 = math.log(dg[2]), math.log(dg[4])
  local x = (lf2 ~= lf1) and clamp((math.log(f) - lf1) / (lf2 - lf1), 0, 1) or 0
  return clamp(dg[1] + (dg[3] - dg[1]) * x, lo, hi)
end

-- The partials that make a thread blink orange in their own lane, at their own frequency, over the grey area they cross in.
function Page:draw_threads(g)
  local lines = self.thread_lines
  if not (lines and #lines > 0) then return end
  local on = (reaper.time_precise() * 2.5) % 1 < 0.5
  local cur = self:active_tr()
  for _, th in ipairs(lines) do
    local fade = (cur and th.key == cur.key) and 1 or 0.3                          -- (the threads of the transitions that are not active blink fainter)
    if on then gfx.set(1, 0.62, 0.1, fade) else gfx.set(0.45, 0.25, 0.05, fade) end
    local x0, x1 = self:tx(g, th.t0), self:tx(g, th.t1)
    local yl, yr = self:f_to_y(g.lane[th.lane_l], clamp(th.fl, FMIN, FMAX)), self:f_to_y(g.lane[th.lane_r], clamp(th.fr, FMIN, FMAX))
    gfx.rect(x0, yl - 1, math.max(x1 - x0, 2), 2, 1)
    gfx.rect(x0, yr - 1, math.max(x1 - x0, 2), 2, 1)
  end
end

local function put(pos, str, r, g, b) if pos then text(pos.x, pos.y, str, r, g, b) end end

-- One transition: the shaded overlap, the grey band, the curve and the red line (or the diagonal).
function Page:draw_transition(g, tr)
  local line, lo, hi = self:line_of(tr), tr.lo, tr.hi
  local dg = self:diag_of(tr)
  local cur = self:active_tr()
  local act = (cur ~= nil and cur.key == tr.key)
  local fade = act and 1 or 0.3                                                      -- the transitions that are not active are fainter
  local y0, y1 = g.laneA.y, g.laneB.y + g.laneB.h
  gfx.set(0.55, 0.58, 0.65, 0.12 * fade)
  gfx.rect(self:tx(g, lo), y0, self:tx(g, hi) - self:tx(g, lo), y1 - y0, 1)
  local w = select(1, self:tol_of(tr))
  if dg then
    for _, lane in ipairs({ g.laneA, g.laneB }) do                               -- the grey band follows the diagonal, row by row
      for y = math.floor(lane.y + 4), math.floor(lane.y + lane.h - 5), 2 do
        local tc = self:diag_time(dg, self:y_to_f(lane, y), lo, hi)
        local a0, a1 = math.max(tc - w / 2, lo), math.min(tc + w / 2, hi)
        gfx.set(0.6, 0.63, 0.7, 0.35 * fade)
        gfx.rect(self:tx(g, a0), y, math.max(self:tx(g, a1) - self:tx(g, a0), 1), 2, 1)
      end
      gfx.set(1, 0.23, 0.19, fade)
      local fa, fb = math.max(dg[2], FMIN), math.min(dg[4], FMAX)
      for k = 0, 1 do gfx.line(self:tx(g, dg[1]) + k, self:f_to_y(lane, fa), self:tx(g, dg[3]) + k, self:f_to_y(lane, fb)) end
    end
    gfx.setfont(1, "Arial", 12)
    text(self:tx(g, dg[1]) + 10, g.laneA.y - 16, "diagonal", 1, 0.45, 0.4, fade)
  else
    local g0, g1 = math.max(line - w / 2, lo), math.min(line + w / 2, hi)
    gfx.set(0.6, 0.63, 0.7, 0.35 * fade)
    gfx.rect(self:tx(g, g0), y0, math.max(self:tx(g, g1) - self:tx(g, g0), 1), y1 - y0, 1)
    if g1 - g0 > 0.01 then                                                          -- the LEVELS over the grey area: the first sound falls, the second rises (equal power crosses higher than linear)
      gfx.set(1, 1, 1, 0.75 * fade)
      local cv = self:curve_of(tr)
      local pxl, pyl, pyr
      for k = 0, 40 do
        local sv = cross.shape(cv, k / 40)
        local wl, wr = cross.weights(cv, sv)
        if k == 0 then wl, wr = 1, 0 elseif k == 40 then wl, wr = 0, 1 end
        local cx = self:tx(g, g0 + (g1 - g0) * k / 40)
        local cyl, cyr = y1 - wl * (y1 - y0), y1 - wr * (y1 - y0)
        if pxl then
          gfx.line(pxl, pyl, cx, cyl); gfx.line(pxl, pyl + 1, cx, cyl + 1)
          gfx.line(pxl, pyr, cx, cyr); gfx.line(pxl, pyr + 1, cx, cyr + 1)
        end
        pxl, pyl, pyr = cx, cyl, cyr
      end
    end
    gfx.set(1, 0.23, 0.19, fade)
    local x = self:tx(g, line)
    gfx.rect(x - 1, g.laneA.y - 12, 3, y1 - y0 + 16, 1)
    gfx.rect(x - 6, g.laneA.y - 14, 13, 8, 1)
    gfx.setfont(1, "Arial", 12)
    text(x + 10, g.laneA.y - 16, string.format("%.3f s", line), 1, 0.45, 0.4, fade)
  end
  local pts = self.diags[tr.key]
  if pts and #pts == 1 then                                                         -- the first point of a diagonal waits for the second
    gfx.set(1, 0.23, 0.19, fade)
    for _, lane in ipairs({ g.laneA, g.laneB }) do gfx.circle(self:tx(g, pts[1].t), self:f_to_y(lane, pts[1].f), 4, 1, 1) end
  end
end

function Page:draw(W, H, top)
  self.top = top
  local g = self:geom(W, H, top)
  local la, lb = self:selected("a"), self:selected("b")
  gfx.setfont(1, "Arial", 16)
  put(g.texts.title, self:label("txt_title", "CROSS: sound A flows into sound B"), 0.95, 0.72, 0.35)
  button(g.btn.back, self:label("btn_back", "BACK"), { 0.9, 0.55, 0.5 })
  button(g.btn.load_a, self:label("btn_load_a", "LOAD A"), BLUE)
  button(g.btn.edit_a, self:label("btn_edit_a", "EDIT A IN THE EDITOR"), BLUE, la ~= nil)
  button(g.btn.open_a, self:label("btn_use_a", "USE THE EDITOR'S SOUND AS A"), BLUE)
  button(g.btn.load_b, self:label("btn_load_b", "LOAD B"), GREEN)
  button(g.btn.edit_b, self:label("btn_edit_b", "EDIT B IN THE EDITOR"), GREEN, lb ~= nil)
  button(g.btn.open_b, self:label("btn_use_b", "USE THE EDITOR'S SOUND AS B"), GREEN)
  self:draw_lane(g, "a")
  self:draw_lane(g, "b")
  for _, s in ipairs(self.blocks) do self:draw_block(g, s) end
  -- the frequency scale of the images (log, 50 Hz - 10 kHz, the same for both): faint lines over the lane; the numbers are placed by the layout (scale_hz_a / _b:
  -- a box as high as the picture, the numbers right-aligned to its right side)
  gfx.setfont(1, "Arial", 10)
  local lf0, lr = math.log(FMIN), math.log(FMAX / FMIN)
  for _, pair in ipairs({ { g.laneA, g.scale_a }, { g.laneB, g.scale_b } }) do
    local lane, sc = pair[1], pair[2]
    for _, f in ipairs({ 100, 200, 500, 1000, 2000, 5000, 10000 }) do
      local frac = 1 - (math.log(f) - lf0) / lr
      local y = math.floor(lane.y + 4 + (lane.h - 8) * frac + 0.5)
      gfx.set(0.7, 0.75, 0.85, (f == 100 or f == 1000 or f == 10000) and 0.22 or 0.1)
      gfx.line(g.x0, y, g.x1, y)
      if sc then
        local label = f >= 1000 and (f // 1000) .. "k" or tostring(f)
        text(sc.x + sc.w - gfx.measurestr(label), math.floor(sc.y + sc.h * frac + 0.5) - 6, label, 0.55, 0.58, 0.64)
      end
    end
  end
  -- the ruler: no line, only a tick and the time beside it ("| 0.50 s")
  local span = self.view[2] - self.view[1]
  local step = 1
  for _, st in ipairs({ 0.1, 0.25, 0.5, 1, 2, 5, 10, 30, 60, 120, 300 }) do step = st; if span / st <= 14 then break end end
  gfx.setfont(1, "Arial", 11)
  local t = math.ceil(self.view[1] / step - 1e-9) * step
  while t <= self.view[2] + 1e-9 do
    local x = self:tx(g, t)
    gfx.set(0.4, 0.43, 0.48, 1); gfx.line(x, g.ruler + 1, x, g.ruler + 13)
    text(x + 4, g.ruler + 1, string.format(step < 1 and "%.2f s" or "%g s", t), 0.55, 0.58, 0.64)
    t = t + step
  end
  -- the transitions: each with its red line and grey band (or its diagonal)
  local trs = self:transitions()
  for _, tr in ipairs(trs) do self:draw_transition(g, tr) end
  if #trs == 0 and #self.blocks >= 2 then
    gfx.setfont(1, "Arial", 12)
    text(g.x0, g.ruler + 26, "the used parts do not overlap: no transition, one sound and then the next, nothing is faded", 0.75, 0.78, 0.84)
  end
  -- the playhead: only where the crossing plays now (it cannot be set by hand), from the start of the result to its end
  local ppos = self.env.play_pos and self.env.play_pos()
  if ppos and self.aud_t_start then
    local px = self:tx(g, self.aud_t_start + ppos)
    if px >= g.x0 - 1 and px <= g.x1 + 1 then
      gfx.set(1, 0.9, 0.3, 1)
      gfx.rect(px - 1, g.laneA.y - 4, 3, g.laneB.y + g.laneB.h - g.laneA.y + 8, 1)
      gfx.rect(px - 5, g.laneA.y - 8, 11, 6, 1)
    end
  end
  -- the sliders
  local function slider(s, label, value, frac)
    gfx.setfont(1, "Arial", 13)
    text(s.x, s.y - 20, label, 0.9, 0.92, 0.96)
    gfx.set(1, 0.9, 0.5, 1)
    gfx.x = s.x + s.w - gfx.measurestr(value); gfx.y = s.y - 20; gfx.drawstr(value)
    gfx.set(0.16, 0.18, 0.22, 1)
    gfx.rect(s.x, s.y, s.w, s.h, 1)
    gfx.set(0.85, 0.6, 0.25, 0.6)
    gfx.rect(s.x, s.y, s.w * frac, s.h, 1)
    gfx.set(1, 1, 1, 0.95)
    gfx.rect(s.x + math.floor((s.w - 3) * frac), s.y - 2, 3, s.h + 4, 1)
    gfx.set(0.35, 0.38, 0.43, 1)
    gfx.rect(s.x, s.y, s.w, s.h, 0)
  end
  self:draw_threads(g)
  if g.sl_gain then
    local db = self.cur and (self.cur.gain_db or 0) or 0
    slider(g.sl_gain, "Level", self.cur and string.format("%+.1f dB", db) or "-", (db - GAIN_MIN) / (GAIN_MAX - GAIN_MIN))
  end
  local tt, tc = self:tol_of(self:active_tr())
  slider(g.sl_time, "Time tolerance", tt < 0.005 and "hard line" or string.format("%.2f s", tt), math.sqrt(math.min(tt / self:time_max(), 1)))
  slider(g.sl_freq, "Frequency tolerance", string.format("%d cents", tc), (tc - 10) / 590)
  gfx.setfont(1, "Arial", 24)
  local cur_tr = self:active_tr()                                           -- the count of the ACTIVE transition (the one the sliders and the menu work on)
  local est = cur_tr and self.counts and self.counts[cur_tr.key] or self.threads_est      -- only the count (nothing else is written here)
  if est == -1 then put(g.texts.threads, "threads: counted when made", 0.6, 0.64, 0.7)
  elseif est then
    if est > 0 then put(g.texts.threads, string.format("%d thread%s", est, est == 1 and "" or "s"), 1, 0.62, 0.1)
    else put(g.texts.threads, "no threads", 1, 0.5, 0.3) end
  end
  if g.dd_curve then
    local dd = g.dd_curve
    gfx.setfont(1, "Arial", 13)
    text(dd.x, dd.y - 20, "Curve", 0.9, 0.92, 0.96)
    gfx.set(0.16, 0.18, 0.22, 1); gfx.rect(dd.x, dd.y, dd.w, dd.h, 1)
    gfx.set(0.35, 0.38, 0.43, 1); gfx.rect(dd.x, dd.y, dd.w, dd.h, 0)
    text(dd.x + 8, dd.y + (dd.h - 14) / 2, curve_name(self:curve_of(self:active_tr())), 1, 0.9, 0.5)
    text(dd.x + dd.w - 16, dd.y + (dd.h - 14) / 2, "v", 0.7, 0.72, 0.78)
  end
  local ready = #self.blocks >= 2
  if g.btn.audition then button(g.btn.audition, self:label("btn_audition", "AUDITION"), { 0.95, 0.75, 0.3 }, ready) end
  button(g.btn.make, self:label("btn_make", "MAKE RESULT"), { 0.45, 0.85, 0.6 }, ready)
  gfx.setfont(1, "Arial", 12)
  put(g.texts.hint, "writes a new .ats file and opens it in the editor (the sounds stay as they are); Enter does the same", 0.6, 0.64, 0.7)
  if self.message then text(g.texts.message.x, g.texts.message.y, self.message, 1, 0.8, 0.45) end      -- (a message is never left out)
  put(g.texts.help1, "Drag a block to place it in time. Drag the white handles at its ends to use only a part of the file. Drag the red line inside the overlap. Double-click a block (or EDIT) to edit that sound in the editor: what you change there comes back as that sound, without saving.", 0.55, 0.58, 0.64)
  put(g.texts.help2, "The partials of two sounds that are close in frequency (the tolerance) become one thread that moves from the first frequency to the second.", 0.55, 0.58, 0.64)
  self:draw_info_marks(g)
  self:draw_tip(g, W, H)
  if self.dd_open and g.dd_curve then                                          -- the list of curves, over everything
    local dd = g.dd_curve
    gfx.setfont(1, "Arial", 13)
    for i, c in ipairs(CURVES) do
      local y = dd.y + i * dd.h
      gfx.set(0.1, 0.11, 0.14, 1); gfx.rect(dd.x, y, dd.w, dd.h, 1)
      gfx.set(0.35, 0.38, 0.43, 1); gfx.rect(dd.x, y, dd.w, dd.h, 0)
      local on = (c[1] == self:curve_of(self:active_tr()))
      text(dd.x + 8, y + (dd.h - 14) / 2, c[2], on and 1 or 0.85, on and 0.9 or 0.87, on and 0.5 or 0.9)
    end
  end
end

return M
