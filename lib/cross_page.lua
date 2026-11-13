-- cross_page.lua -- the CROSS page (tjingboem, 13 Nov 2026): sound A flows into sound B. An immediate-mode page like the Analysis page (Esc / BACK returns to the
-- editor). It holds the RECIPE only; the result is a new .ats file (lib/ats_cross.lua) that opens in the editor, where it is auditioned and finished by hand.
--   * two blocks, one per sound, drawn as long as the sound lasts, in two lanes (A above B) on one timeline; each is loaded from an .ats file (the name shows on it)
--     and shows a LOW RESOLUTION IMAGE of the sound (time sideways, frequency up, brightness = level; the same frequency range for both) to find the coarse cross point
--   * the blocks are dragged in time (before, after or on top of each other); the grey box (the used part, handles at both ends) says "use this portion only"
--   * the overlap of the used parts is the transition space; the RED LINE (vertical) is dragged inside it; the grey band round it is the time tolerance
--   * a slider for the time tolerance (0 = a hard line) and one for the frequency tolerance (which partials are one thread)
--   * MAKE RESULT writes <name of A>_cross<N>.ats (never over an existing file; in the project's ReaATS folder when the project is saved) and opens it.
-- The state stays while the editor runs (the page is reopened where you left it).
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
local ats = dofile(here .. "/ats_file.lua")
local cross = dofile(here .. "/ats_cross.lua")

local M = {}
local Page = {}
Page.__index = Page

local MEMORY_FACTOR = 2.1                           -- Lua tables take about this many times the size of an .ats file
local BLUE, GREEN = { 0.29, 0.64, 1.0 }, { 0.37, 0.83, 0.54 }

local function clamp(x, a, b) if x < a then return a elseif x > b then return b else return x end end
local function basename(p) return p:match("([^/\\]+)$") or p end

function M.new(env)
  local self = setmetatable({}, Page)
  self.env = env
  self.a, self.b = nil, nil                         -- { path, name, d, origin (timeline seconds of file time 0), t0, t1 (the used part, file time) }
  self.line = nil                                   -- seconds on the timeline
  self.tol_time, self.tol_cents = 0.6, 100
  self.curve = "smooth"                             -- the shape of the crossover (see ats_cross): smooth, linear, equal, s
  self.diag_pts = {}                                -- Ctrl+click in a lane: { t (timeline s), f (Hz) } x 2 = a diagonal line (low partials cross first)
  self.view = { 0, 10 }
  self.drag, self.prev_down = nil, false
  self.message = nil
  self.results = {}                                 -- by file name: { line, grey0, grey1, ov0, ov1, t_start, threads } of every result that was made (the editor draws the line over it)
  return self
end

-- 20 % or less memory free: a warning replaces the message (and shows in red)
function Page:memory_check()
  if not self.env.memory_warning then return end
  local low, msg = self.env.memory_warning()
  if low then self:say(msg, true) end
end

function Page:say(msg) self.message = msg end

-- How many threads the present recipe would make (counted when something is let go, not while it moves). Skipped for big sounds (the count resamples both).
function Page:recount()
  self.threads_est, self.thread_lines = nil, nil
  if not (self.a and self.b) or not self:overlap() then return end
  local cells = self.a.d.partials * self.a.d.frames + self.b.d.partials * self.b.d.frames
  if cells > 3e6 then self.threads_est = -1; return end
  local info = cross.count(self:spec())
  self.threads_est = info and info.pairs or nil
  self.thread_lines, self.thread_l_is_a = info and info.threads, info and info.l_is_a
end

-- ------------------------------------------------------------------ the sounds
local function sound_end(s) return s.d.times[s.d.frames] end

function Page:fit_view(force)
  if force then self.zoomed = false end
  if self.zoomed then return end                                      -- (a view that was zoomed by hand stays until a sound is loaded or removed)
  local lo, hi
  for _, s in ipairs({ self.a, self.b }) do
    if s then
      local a, b = s.origin + s.d.times[1], s.origin + sound_end(s)
      lo = lo and math.min(lo, a) or a
      hi = hi and math.max(hi, b) or b
    end
  end
  if not lo then self.view = { 0, 10 }; return end
  local m = math.max((hi - lo) * 0.06, 0.05)
  self.view = { lo - m, hi + m }
end

-- The low resolution image of a sound: THUMB_W x THUMB_H cells (time sideways over the whole file, frequency up on a log scale from FMIN to FMAX, the same for both
-- sounds), the loudest partial in a cell, brightness = level over 60 dB below the loudest. Drawn once into an image buffer of its own (20 for A, 21 for B).
local THUMB_W, THUMB_H, FMIN, FMAX, FLOOR_DB = 640, 72, 50, 10000, 60
local THUMB_ID = { a = 20, b = 21 }
function Page:make_thumb(slot)
  local s = self[slot]
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
  local col = (slot == "a") and BLUE or GREEN
  local id = THUMB_ID[slot]
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

-- Loads an .ats file into slot "a" or "b". The memory check: both files and the result must fit in about 85 % of the free memory.
function Page:load(slot, path)
  local h, err = ats.header(path)
  if not h then self:say(tostring(err)); return false end
  local other = (slot == "a") and self.b or self.a
  local need = h.bytes * MEMORY_FACTOR * 1.5 + (other and other.bytes * MEMORY_FACTOR * 1.5 or 0)
  local free = self.env.available_memory and self.env.available_memory(need)
  if free and need > free * 0.85 then
    self:say(string.format("not enough memory for this (%.1f GB needed, %.1f GB free): analyse with a higher threshold or use a shorter part", need / 2^30, free / 2^30))
    return false
  end
  local d, lerr = ats.load(path)
  if not d then self:say(tostring(lerr)); return false end
  local s = { path = path, file = path, name = basename(path), d = d, origin = 0, t0 = d.times[1], t1 = d.times[d.frames], bytes = h.bytes, full = true, edited = false }
  local old = self[slot]
  if old then s.origin = old.origin + old.d.times[1] - d.times[1]                -- (a sound that is replaced, an edited version for example, stays where it was)
  elseif slot == "b" and self.a then                                           -- (B starts half over the end of A: there is a transition space to begin with)
    local over = 0.5 * math.min(self.a.t1 - self.a.t0, s.t1 - s.t0)
    s.origin = (self.a.origin + self.a.t1 - over) - s.t0
  end
  self[slot] = s
  self:make_thumb(slot)
  self.line = nil
  self:recount()
  self:fit_view(true)
  self:say(string.format("%s loaded: %.2f s, %d partials", s.name, d.dur, d.partials))
  self:memory_check()
  return true
end

-- Right-click on a block: the sound leaves its lane. A sound with changes that are not in a file asks first (nothing else would bring it back).
function Page:remove(slot)
  local s = self[slot]
  if not s then return end
  if s.edited then
    local answer = reaper.MB(s.name .. " has changes that are not saved. Remove it anyway?", "ReaATS", 4)
    if answer ~= 6 then return end
  end
  self[slot] = nil
  self.line = nil
  self.results_for = nil
  self:fit_view(true)
  self:recount()
  self:say(slot:upper() .. " removed")
end

-- A double-click on a block (or EDIT): the sound opens in the editor, from memory (no file is read, nothing has to be saved), to edit it (a stretch to make it
-- longer, for example). The editor works on the very same table: when you press CROSS again the page has your changes.
function Page:edit_in_editor(slot)
  local s = self[slot]
  if not s then return end
  if self.env.open_in_editor(s.d, s.file or s.path, (not s.edited) and s.path or nil, s.edited) then
    self.editing = slot
    self.env.set_status(string.format("%s is open in the editor: edit it and press CROSS to come back (nothing needs to be saved)", s.name))
  else
    self:say("the sound could not be opened in the editor")
  end
end

-- Called when the page is shown again: a sound that the editor works on has changed (longer, other partials ...): its image and its used part follow.
function Page:enter()
  local st = self.env.editor_state()
  for _, slot in ipairs({ "a", "b" }) do
    local s = self[slot]
    if s and st.data == s.d then
      local changed = st.modified or (st.current ~= s.path)
      local d = s.d
      if s.full or s.t1 > d.times[d.frames] then s.t0, s.t1 = d.times[1], d.times[d.frames] end
      s.t0 = math.max(s.t0, d.times[1])
      if changed then s.edited = true end
      self:make_thumb(slot)
      if self.editing == slot and changed then self:say(string.format("%s has the changes made in the editor (nothing had to be saved)", slot:upper())) end
    end
  end
  self.editing = nil
  self:fit_view(true)
  self:recount()
end

function Page:choose(slot)
  local path
  if reaper.JS_Dialog_BrowseForOpenFiles then
    local rv, chosen = reaper.JS_Dialog_BrowseForOpenFiles("Load sound " .. slot:upper() .. " (.ats file)", "", "", "ATS files (*.ats)\0*.ats\0All files (*.*)\0*.*\0\0", false)
    if rv == 1 and chosen and chosen ~= "" then path = chosen end
  else
    local ok, p = reaper.GetUserFileNameForRead("", "Load sound " .. slot:upper() .. " (.ats file)", "ats")
    if ok and p ~= "" then path = p end
  end
  if path then self:load(slot, path) end
end

-- The sound that the editor holds becomes A or B: the table itself, in memory (edits made in the editor are in it; nothing has to be saved).
function Page:use_open_sound(slot)
  local st = self.env.editor_state()
  if not st.data then self:say("no sound is open in the editor"); return end
  local old = self[slot]
  local d = st.data
  local s = { d = d, path = st.current or st.file, file = st.file, name = basename(st.file or "sound.ats"), bytes = 0, origin = 0,
              t0 = d.times[1], t1 = d.times[d.frames], full = true, edited = st.modified or (st.current ~= st.file) }
  if old then s.origin = old.origin + old.d.times[1] - d.times[1]
  elseif slot == "b" and self.a then
    local over = 0.5 * math.min(self.a.t1 - self.a.t0, s.t1 - s.t0)
    s.origin = (self.a.origin + self.a.t1 - over) - s.t0
  end
  self[slot] = s
  self:make_thumb(slot)
  self.line = nil
  self:fit_view(true)
  self:recount()
  self:say(string.format("the sound of the editor is %s now: %s%s", slot:upper(), s.name, s.edited and " (with the changes made in the editor)" or ""))
end

-- ------------------------------------------------------------------ the recipe
function Page:pos_of(s) return s.origin + s.t0 end
function Page:end_of(s) return s.origin + s.t1 end

-- The overlap of the used parts (the transition space), or nil.
function Page:overlap()
  if not (self.a and self.b) then return nil end
  local lo = math.max(self:pos_of(self.a), self:pos_of(self.b))
  local hi = math.min(self:end_of(self.a), self:end_of(self.b))
  if hi > lo + 1e-6 then return lo, hi end
  return nil
end

function Page:current_line()
  local lo, hi = self:overlap()
  if not lo then return nil end
  self.line = clamp(self.line or (lo + hi) / 2, lo, hi)
  return self.line, lo, hi
end

-- The diagonal: { t1, f1, t2, f2 } with the low point first, or nil (a vertical line).
function Page:diag()
  local p = self.diag_pts
  if #p < 2 then return nil end
  local lo, hi = p[1], p[2]
  if lo.f > hi.f then lo, hi = hi, lo end
  return { lo.t, lo.f, hi.t, hi.f }
end

-- Frequency <-> height in a lane (the pictures: log scale, FMIN .. FMAX, 4 px inside the lane).
function Page:f_to_y(lane, f) return lane.y + 4 + (lane.h - 8) * (1 - (math.log(f) - math.log(FMIN)) / math.log(FMAX / FMIN)) end
function Page:y_to_f(lane, y)
  local fr = clamp(1 - (y - lane.y - 4) / (lane.h - 8), 0, 1)
  return FMIN * (FMAX / FMIN) ^ fr
end

function Page:spec()
  local a, b = self.a, self.b
  return { a = { d = a.d, t0 = a.t0, t1 = a.t1, pos = self:pos_of(a), gain = 10 ^ ((a.gain_db or 0) / 20) },
           b = { d = b.d, t0 = b.t0, t1 = b.t1, pos = self:pos_of(b), gain = 10 ^ ((b.gain_db or 0) / 20) },
           line = self:current_line(), tol_time = self.tol_time, tol_cents = self.tol_cents, curve = self.curve,
           diag = self:diag() }
end

-- Listens to the crossing without making a file: the result is built in memory and played from a little before the transition to a little after it.
function Page:audition()
  if not (self.a and self.b) then self:say("load both sounds first"); return end
  local d, info = cross.build(self:spec())
  if not d then self:say("cannot audition: " .. tostring(info)); return end
  local from, to = 0, nil
  if info.line then
    local half = (self.tol_time or 0) / 2
    from = math.max(0, info.line - half - 1.5)
    to = math.min(d.dur, info.line + half + 1.5)
  end
  if not self.env.audition(d, from, to) then return end
  self:say("listening")
end

-- Makes the result (a new file) and opens it in the editor.
function Page:make()
  if not (self.a and self.b) then self:say("load both sounds first"); return end
  local stem = self.a.path:gsub("%.[^./\\]+$", ""):gsub("_ch%d+$", ""):gsub("_edit%d*$", "")
  stem = (self.env.relocate and self.env.relocate(stem)) or stem
  local n, path = 1, nil
  repeat path = string.format("%s_cross%d.ats", stem, n); n = n + 1 until not reaper.file_exists(path)
  local info, err = cross.make(self:spec(), path)
  if not info then self:say("cannot make the result: " .. tostring(err)); return end
  self.results[path] = { path = path, diag = info.diag, line = info.line, grey0 = info.grey0, grey1 = info.grey1, ov0 = info.ov0, ov1 = info.ov1, t_start = info.t_start, threads = info.threads }
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
  local rx, ry = self:el("ruler", 40, 330, aw, 16, top)
  g.ruler = ry
  local function box(id, dx, dy, dw, dh) local x, y, w, h = self:el(id, dx, dy, dw, dh, top); return { x = x, y = y, w = w, h = h } end
  g.sl_time = box("sl_time", 40, 394, 300, 10)
  g.sl_freq = box("sl_freq", 420, 394, 300, 10)
  local function obox(id, dx, dy, dw, dh) local x, y, w, h = self:el(id, dx, dy, dw, dh, top, true); if x then return { x = x, y = y, w = w, h = h } end end
  g.dd_curve = obox("dd_curve", 740, 394, 150, 22)
  g.sl_gain_a = obox("sl_gain_a", 660, 52, 200, 10)
  g.sl_gain_b = obox("sl_gain_b", 660, 196, 200, 10)
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
-- The longest time tolerance: 4 s, or the whole overlap when that is longer (a transition needs time: tjingboem, 13 Nov 2026).
function Page:time_max()
  local lo, hi = self:overlap()
  return lo and math.max(4, hi - lo) or 4
end

function Page:slider_value(g, which, mx)
  local s = g[which]
  local frac = clamp((mx - s.x) / s.w, 0, 1)
  if which == "sl_time" then self.tol_time = math.floor(frac * frac * self:time_max() * 100 + 0.5) / 100        -- finer at the short end
  else self.tol_cents = math.floor((10 + frac * 590) / 10 + 0.5) * 10 end
end

-- The gain of a sound (dB): its slider, -24 .. +12, sticks at 0.
local GAIN_MIN, GAIN_MAX = -24, 12
local CURVES = { { "smooth", "Smooth" }, { "linear", "Linear" }, { "equal", "Equal power" }, { "s", "S curve" } }
local function curve_name(k) for _, c in ipairs(CURVES) do if c[1] == k then return c[2] end end return k end
function Page:gain_value(g, slot, mx)
  local s = self[slot]
  local sl = g["sl_gain_" .. slot]
  if not (s and sl) then return end
  local db = GAIN_MIN + clamp((mx - sl.x) / sl.w, 0, 1) * (GAIN_MAX - GAIN_MIN)
  db = math.floor(db * 2 + 0.5) / 2
  if math.abs(db) < 0.75 then db = 0 end
  s.gain_db = db
end

local function block_at(self, g, mx, my)
  for _, slot in ipairs({ "a", "b" }) do
    local s = self[slot]
    local lane = (slot == "a") and g.laneA or g.laneB
    if s and my >= lane.y and my < lane.y + lane.h and mx >= self:tx(g, s.origin + s.d.times[1]) and mx <= self:tx(g, s.origin + sound_end(s)) then return slot end
  end
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

function Page:mouse(mx, my, cap, wheel)
  local W, H = math.floor(gfx.w), math.floor(gfx.h)
  local g = self:geom(W, H, self.top or 40)
  local down = (cap & 1) ~= 0
  local right = (cap & 2) ~= 0
  local shift = (cap & 8) ~= 0
  if wheel and wheel ~= 0 and my >= g.laneA.y - 20 and my <= g.laneB.y + g.laneB.h + 40 then self:zoom(g, mx, wheel, shift) end
  if right and not self.prev_right then                           -- right-click on a block removes that sound
    local slot = block_at(self, g, mx, my)
    if slot then self:remove(slot) end
  end
  self.prev_right = right
  if down and not self.prev_down and self.dd_open and g.dd_curve then       -- the open list of curves takes this click
    local dd = g.dd_curve
    for i, c in ipairs(CURVES) do
      if mx >= dd.x and mx < dd.x + dd.w and my >= dd.y + i * dd.h and my < dd.y + (i + 1) * dd.h then self.curve = c[1] end
    end
    self.dd_open = false
    self.prev_down = down
    return
  end
  if down and not self.prev_down then
    self.drag = nil
    local b = g.btn
    local ctrl = (cap & 4) ~= 0
    local dd = g.dd_curve
    if ctrl and not shift and (my >= g.laneA.y and my < g.laneA.y + g.laneA.h or my >= g.laneB.y and my < g.laneB.y + g.laneB.h) then
      -- Ctrl+click in a lane: a point of the diagonal (low and high in the picture); the second one makes the line, a third starts again
      local lane = (my < g.laneA.y + g.laneA.h) and g.laneA or g.laneB
      if #self.diag_pts >= 2 then self.diag_pts = {} end
      self.diag_pts[#self.diag_pts + 1] = { t = self:tt(g, mx), f = self:y_to_f(lane, my) }
      self:recount()
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
      for _, which in ipairs({ "sl_time", "sl_freq", "sl_gain_a", "sl_gain_b" }) do
        local sl = g[which]
        if sl and mx >= sl.x - 6 and mx < sl.x + sl.w + 6 and my >= sl.y - 8 and my < sl.y + sl.h + 8 then
          if which:sub(1, 8) == "sl_gain_" then
            self.drag = { kind = "gain", slot = which:sub(9) }
            self:gain_value(g, self.drag.slot, mx)
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
        local line = (#self.diag_pts < 2) and self:current_line() or nil
        if line and math.abs(mx - self:tx(g, line)) <= 7 and my >= g.laneA.y - 14 and my <= g.laneB.y + g.laneB.h + 4 then
          self.drag = { kind = "line", x = mx, hx = self:tx(g, line), acc = 0 }
        end
      end
      if not self.drag then
        for _, slot in ipairs({ "a", "b" }) do
          local s = self[slot]
          local lane = (slot == "a") and g.laneA or g.laneB
          if s and my >= lane.y and my < lane.y + lane.h then
            local now = reaper.time_precise()
            local lc = self.last_click
            if lc and lc.slot == slot and now - lc.t < 0.45 and math.abs(mx - lc.x) <= 5 and math.abs(my - lc.y) <= 5 then
              self.last_click = nil                                       -- a double-click on a block: this sound opens in the editor (to be edited, stretched ...)
              self:edit_in_editor(slot)
              self.prev_down = down
              return
            end
            self.last_click = { slot = slot, t = now, x = mx, y = my }
            local x0, x1 = self:tx(g, self:pos_of(s)), self:tx(g, self:end_of(s))
            if math.abs(mx - x0) <= 7 then self.drag = { kind = "cut_in", slot = slot, x = mx, hx = x0, acc = 0 }
            elseif math.abs(mx - x1) <= 7 then self.drag = { kind = "cut_out", slot = slot, x = mx, hx = x1, acc = 0 }
            elseif mx >= self:tx(g, s.origin + s.d.times[1]) and mx <= self:tx(g, s.origin + sound_end(s)) then
              self.drag = { kind = "move", slot = slot, x = mx, acc = 0, origin0 = s.origin }
            end
            if self.drag then break end
          end
        end
      end
    end
  elseif down and self.drag then
    local d = self.drag
    if d.x then                                                      -- Shift = fine: a tenth of the movement of the mouse
      d.acc = d.acc + (mx - d.x) * (shift and 0.1 or 1)
      d.x = mx
    end
    if d.kind == "slider" then self:slider_value(g, d.which, mx)
    elseif d.kind == "gain" then self:gain_value(g, d.slot, mx)
    elseif d.kind == "pan" then
      local dt = -d.acc / g.pps
      self.view = { d.v0 + dt, d.v1 + dt }
      self.zoomed = true
    elseif d.kind == "line" then
      local lo, hi = self:overlap()
      if lo then self.line = clamp(self:tt(g, d.hx + d.acc), lo, hi) end
    elseif d.kind == "move" then
      self[d.slot].origin = d.origin0 + d.acc / g.pps
    elseif d.kind == "cut_in" then
      local s = self[d.slot]
      s.t0 = clamp(self:tt(g, d.hx + d.acc) - s.origin, s.d.times[1], s.t1 - 0.05)
      s.full = false
    elseif d.kind == "cut_out" then
      local s = self[d.slot]
      s.t1 = clamp(self:tt(g, d.hx + d.acc) - s.origin, s.t0 + 0.05, sound_end(s))
      s.full = false
    end
  end
  if not down then
    if self.drag then
      if self.drag.kind == "move" or self.drag.kind == "cut_in" or self.drag.kind == "cut_out" then self:fit_view() end
      self.drag = nil
      self:recount()
    end
  end
  self.prev_down = down
end

function Page:key(ch)
  if ch == 27 and (#self.diag_pts > 0 or self.dd_open) then self.diag_pts = {}; self.dd_open = false; self:recount(); return true end     -- Esc: back to a vertical line
  if ch == 13 then self:make(); return true end
  if ch == 32 then self.env.stop_audition(); return true end
  if ch == 97 or ch == 65 then self:audition(); return true end
  return false
end

-- ------------------------------------------------------------------ drawing
local function text(x, y, s, r, g, b, a) gfx.set(r or 0.85, g or 0.87, b or 0.9, a or 1); gfx.x, gfx.y = x, y; gfx.drawstr(s) end

local function button(r, label, rgb, enabled)
  rgb = rgb or { 0.5, 0.75, 0.95 }
  local k = (enabled == false) and 0.12 or 0.4
  gfx.set(rgb[1] * k, rgb[2] * k, rgb[3] * k, 1)
  gfx.rect(r[1], r[2], r[3], r[4], 1)
  gfx.set(rgb[1], rgb[2], rgb[3], (enabled == false) and 0.4 or 1)
  gfx.rect(r[1], r[2], r[3], r[4], 0)
  gfx.setfont(1, "Arial", 13)
  gfx.x, gfx.y = r[1] + (r[3] - gfx.measurestr(label)) / 2, r[2] + (r[4] - 14) / 2
  gfx.drawstr(label)
end

function Page:draw_block(g, slot)
  local s = self[slot]
  local lane = (slot == "a") and g.laneA or g.laneB
  local col = (slot == "a") and BLUE or GREEN
  gfx.set(0.13, 0.145, 0.18, 1)
  gfx.rect(g.x0, lane.y, g.x1 - g.x0, lane.h, 1)
  gfx.set(0.24, 0.26, 0.31, 1)
  gfx.rect(g.x0, lane.y, g.x1 - g.x0, lane.h, 0)
  gfx.setfont(1, "Arial", 14)
  if not s then
    text(g.x0 + 12, lane.y + lane.h / 2 - 8, "sound " .. slot:upper() .. ": load an .ats file (made on the Analysis page)", 0.5, 0.53, 0.6)
    return
  end
  local fx0, fx1 = self:tx(g, s.origin + s.d.times[1]), self:tx(g, s.origin + sound_end(s))
  local ux0, ux1 = self:tx(g, self:pos_of(s)), self:tx(g, self:end_of(s))
  -- the image of the whole file; the parts that are cut away are dimmed, the used part (the grey box) has handles at its ends
  local bw = fx1 - fx0
  gfx.set(1, 1, 1, 1)
  if s.thumb and bw > 1 then gfx.blit(THUMB_ID[slot], 1, 0, 0, 0, THUMB_W, THUMB_H, fx0, lane.y + 4, bw, lane.h - 8) end
  gfx.set(0, 0, 0, 0.62)
  if ux0 > fx0 then gfx.rect(fx0, lane.y + 4, ux0 - fx0, lane.h - 8, 1) end
  if ux1 < fx1 then gfx.rect(ux1, lane.y + 4, fx1 - ux1, lane.h - 8, 1) end
  gfx.set(col[1], col[2], col[3], 1)
  gfx.rect(fx0, lane.y + 4, fx1 - fx0, lane.h - 8, 0)
  gfx.rect(ux0, lane.y + 4, ux1 - ux0, lane.h - 8, 0)
  gfx.set(1, 1, 1, 0.95)                                                   -- the handles of the cut
  gfx.rect(ux0 - 2, lane.y + 4, 4, lane.h - 8, 1)
  gfx.rect(ux1 - 2, lane.y + 4, 4, lane.h - 8, 1)
end

-- The little "i" of a block: a circle in the top right corner of the USED part (it moves along when the sound is cut, and stays inside the window).
local INFO_R = 8
function Page:info_pos(g, slot)
  local s = self[slot]
  if not s then return nil end
  local lane = (slot == "a") and g.laneA or g.laneB
  local x = math.min(self:tx(g, self:end_of(s)), g.x1) - INFO_R - 8
  x = math.max(x, math.max(self:tx(g, self:pos_of(s)), g.x0) + INFO_R + 8)
  return x, lane.y + 4 + INFO_R + 4
end

function Page:draw_info_marks(g)
  for _, slot in ipairs({ "a", "b" }) do
    local x, y = self:info_pos(g, slot)
    if x then
      local col = (slot == "a") and BLUE or GREEN
      local hot = self.info_hover == slot
      gfx.set(0.03, 0.04, 0.06, hot and 0.95 or 0.65); gfx.circle(x, y, INFO_R, 1, 1)
      gfx.set(col[1], col[2], col[3], 1); gfx.circle(x, y, INFO_R, 0, 1)
      gfx.setfont(1, "Arial", 13)
      local w, h = gfx.measurestr("i")
      gfx.x, gfx.y = x - w / 2, y - h / 2
      gfx.drawstr("i")
    end
  end
end

-- What is known about a sound is shown in a box while the mouse is on its "i" (the blocks themselves show only the picture).
function Page:draw_tip(g, W, H)
  self.info_hover = nil
  if self.drag then return end
  local mx, my = gfx.mouse_x, gfx.mouse_y
  for _, slot in ipairs({ "a", "b" }) do
    local s = self[slot]
    local x, y = self:info_pos(g, slot)
    if s and (mx - x) ^ 2 + (my - y) ^ 2 <= (INFO_R + 2) ^ 2 then
      self.info_hover = slot
      local col = (slot == "a") and BLUE or GREEN
      local d = s.d
      local lines = {
        "sound " .. slot:upper() .. ": " .. s.name .. (s.edited and "  (changed in the editor)" or ""),
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

-- The partials of A and of B that make a thread blink orange in their own lane, at their own frequency, over the grey area they cross in.
function Page:draw_threads(g)
  local lines = self.thread_lines
  if not (lines and #lines > 0) then return end
  local on = (reaper.time_precise() * 2.5) % 1 < 0.5
  if on then gfx.set(1, 0.62, 0.1, 1) else gfx.set(0.45, 0.25, 0.05, 1) end
  local l_lane, r_lane = g.laneA, g.laneB
  if not self.thread_l_is_a then l_lane, r_lane = g.laneB, g.laneA end
  for _, th in ipairs(lines) do
    local x0, x1 = self:tx(g, th.t0), self:tx(g, th.t1)
    local yl, yr = self:f_to_y(l_lane, clamp(th.fl, FMIN, FMAX)), self:f_to_y(r_lane, clamp(th.fr, FMIN, FMAX))
    gfx.rect(x0, yl - 1, math.max(x1 - x0, 2), 2, 1)
    gfx.rect(x0, yr - 1, math.max(x1 - x0, 2), 2, 1)
  end
end

local function put(pos, str, r, g, b) if pos then text(pos.x, pos.y, str, r, g, b) end end

function Page:draw(W, H, top)
  self.top = top
  local g = self:geom(W, H, top)
  gfx.setfont(1, "Arial", 16)
  put(g.texts.title, self:label("txt_title", "CROSS: sound A flows into sound B"), 0.95, 0.72, 0.35)
  button(g.btn.back, self:label("btn_back", "BACK"), { 0.9, 0.55, 0.5 })
  button(g.btn.load_a, self:label("btn_load_a", "LOAD A"), BLUE)
  button(g.btn.edit_a, self:label("btn_edit_a", "EDIT A IN THE EDITOR"), BLUE, self.a ~= nil)
  button(g.btn.open_a, self:label("btn_use_a", "USE THE EDITOR'S SOUND AS A"), BLUE)
  button(g.btn.load_b, self:label("btn_load_b", "LOAD B"), GREEN)
  button(g.btn.edit_b, self:label("btn_edit_b", "EDIT B IN THE EDITOR"), GREEN, self.b ~= nil)
  button(g.btn.open_b, self:label("btn_use_b", "USE THE EDITOR'S SOUND AS B"), GREEN)
  self:draw_block(g, "a")
  self:draw_block(g, "b")
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
  -- the transition space, the red line and its grey band (or the diagonal)
  local line, lo, hi = self:current_line()
  local dg = self:diag()
  if lo then
    local y0, y1 = g.laneA.y, g.laneB.y + g.laneB.h
    gfx.set(0.55, 0.58, 0.65, 0.12)
    gfx.rect(self:tx(g, lo), y0, self:tx(g, hi) - self:tx(g, lo), y1 - y0, 1)
    local w = self.tol_time
    if dg then
      for _, lane in ipairs({ g.laneA, g.laneB }) do                               -- the grey band follows the diagonal, row by row
        for y = math.floor(lane.y + 4), math.floor(lane.y + lane.h - 5), 2 do
          local tc = self:diag_time(dg, self:y_to_f(lane, y), lo, hi)
          local a0, a1 = math.max(tc - w / 2, lo), math.min(tc + w / 2, hi)
          gfx.set(0.6, 0.63, 0.7, 0.35)
          gfx.rect(self:tx(g, a0), y, math.max(self:tx(g, a1) - self:tx(g, a0), 1), 2, 1)
        end
        gfx.set(1, 0.23, 0.19, 1)
        local fa, fb = math.max(dg[2], FMIN), math.min(dg[4], FMAX)
        for k = 0, 1 do gfx.line(self:tx(g, dg[1]) + k, self:f_to_y(lane, fa), self:tx(g, dg[3]) + k, self:f_to_y(lane, fb)) end
      end
      gfx.setfont(1, "Arial", 12)
      text(self:tx(g, dg[1]) + 10, g.laneA.y - 16, "diagonal", 1, 0.45, 0.4)
    else
      local g0, g1 = math.max(line - w / 2, lo), math.min(line + w / 2, hi)
      gfx.set(0.6, 0.63, 0.7, 0.35)
      gfx.rect(self:tx(g, g0), y0, math.max(self:tx(g, g1) - self:tx(g, g0), 1), y1 - y0, 1)
      if g1 - g0 > 0.01 then                                                          -- the curve of the crossover: s runs from 0 (only the first sound) to 1 (only the second)
        gfx.set(1, 1, 1, 0.75)
        local px, py
        for k = 0, 40 do
          local cx = self:tx(g, g0 + (g1 - g0) * k / 40)
          local cy = y1 - cross.shape(self.curve, k / 40) * (y1 - y0)
          if px then gfx.line(px, py, cx, cy); gfx.line(px, py + 1, cx, cy + 1) end
          px, py = cx, cy
        end
      end
      gfx.set(1, 0.23, 0.19, 1)
      local x = self:tx(g, line)
      gfx.rect(x - 1, g.laneA.y - 12, 3, y1 - y0 + 16, 1)
      gfx.rect(x - 6, g.laneA.y - 14, 13, 8, 1)
      gfx.setfont(1, "Arial", 12)
      text(x + 10, g.laneA.y - 16, string.format("%.3f s", line), 1, 0.45, 0.4)
      if #self.diag_pts == 1 then                                                     -- the first point of a diagonal waits for the second
        local pt = self.diag_pts[1]
        gfx.set(1, 0.23, 0.19, 1)
        for _, lane in ipairs({ g.laneA, g.laneB }) do gfx.circle(self:tx(g, pt.t), self:f_to_y(lane, pt.f), 4, 1, 1) end
      end
    end
  elseif self.a and self.b then
    gfx.setfont(1, "Arial", 12)
    text(g.x0, g.ruler + 26, "the used parts do not overlap: no transition, A and then B, nothing is faded", 0.75, 0.78, 0.84)
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
  for _, slot in ipairs({ "a", "b" }) do
    local sl = g["sl_gain_" .. slot]
    if sl and self[slot] then
      local db = self[slot].gain_db or 0
      slider(sl, "Level " .. slot:upper(), string.format("%+.1f dB", db), (db - GAIN_MIN) / (GAIN_MAX - GAIN_MIN))
    end
  end
  slider(g.sl_time, "Time tolerance", self.tol_time < 0.005 and "hard line" or string.format("%.2f s", self.tol_time), math.sqrt(math.min(self.tol_time / self:time_max(), 1)))
  slider(g.sl_freq, "Frequency tolerance", string.format("%d cents", self.tol_cents), (self.tol_cents - 10) / 590)
  gfx.setfont(1, "Arial", 12)
  gfx.setfont(1, "Arial", 24)
  local est = self.threads_est                                              -- only the count (nothing else is written here)
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
    text(dd.x + 8, dd.y + (dd.h - 14) / 2, curve_name(self.curve), 1, 0.9, 0.5)
    text(dd.x + dd.w - 16, dd.y + (dd.h - 14) / 2, "v", 0.7, 0.72, 0.78)
  end
  if g.btn.audition then button(g.btn.audition, self:label("btn_audition", "AUDITION"), { 0.95, 0.75, 0.3 }, self.a ~= nil and self.b ~= nil) end
  button(g.btn.make, self:label("btn_make", "MAKE RESULT"), { 0.45, 0.85, 0.6 }, self.a ~= nil and self.b ~= nil)
  gfx.setfont(1, "Arial", 12)
  put(g.texts.hint, "writes a new .ats file and opens it in the editor (A and B stay as they are); Enter does the same", 0.6, 0.64, 0.7)
  if self.message then text(g.texts.message.x, g.texts.message.y, self.message, 1, 0.8, 0.45) end      -- (a message is never left out)
  put(g.texts.help1, "Drag a block to place it in time. Drag the white handles at its ends to use only a part of the file. Drag the red line inside the overlap. Double-click a block (or EDIT) to edit that sound in the editor: what you change there comes back as that sound, without saving.", 0.55, 0.58, 0.64)
  put(g.texts.help2, "The partials of A and B that are close in frequency (the tolerance) become one thread that moves from A's frequency to B's.", 0.55, 0.58, 0.64)
  self:draw_info_marks(g)
  self:draw_tip(g, W, H)
  if self.dd_open and g.dd_curve then                                          -- the list of curves, over everything
    local dd = g.dd_curve
    gfx.setfont(1, "Arial", 13)
    for i, c in ipairs(CURVES) do
      local y = dd.y + i * dd.h
      gfx.set(0.1, 0.11, 0.14, 1); gfx.rect(dd.x, y, dd.w, dd.h, 1)
      gfx.set(0.35, 0.38, 0.43, 1); gfx.rect(dd.x, y, dd.w, dd.h, 0)
      text(dd.x + 8, y + (dd.h - 14) / 2, c[2], c[1] == self.curve and 1 or 0.85, c[1] == self.curve and 0.9 or 0.87, c[1] == self.curve and 0.5 or 0.9)
    end
  end
end

return M
