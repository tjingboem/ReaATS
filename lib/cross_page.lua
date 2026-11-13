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
  self.view = { 0, 10 }
  self.drag, self.prev_down = nil, false
  self.message = nil
  self.results = {}                                 -- by file name: { line, grey0, grey1, ov0, ov1, t_start, threads } of every result that was made (the editor draws the line over it)
  return self
end

function Page:say(msg) self.message = msg end

-- How many threads the present recipe would make (counted when something is let go, not while it moves). Skipped for big sounds (the count resamples both).
function Page:recount()
  self.threads_est = nil
  if not (self.a and self.b) or not self:overlap() then return end
  local cells = self.a.d.partials * self.a.d.frames + self.b.d.partials * self.b.d.frames
  if cells > 3e6 then self.threads_est = -1; return end
  local info = cross.count(self:spec())
  self.threads_est = info and info.pairs or nil
end

-- ------------------------------------------------------------------ the sounds
local function sound_end(s) return s.d.times[s.d.frames] end

function Page:fit_view()
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
  self:fit_view()
  self:say(string.format("%s loaded: %.2f s, %d partials", s.name, d.dur, d.partials))
  return true
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
  self:fit_view()
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
  self:fit_view()
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

function Page:spec()
  local a, b = self.a, self.b
  return { a = { d = a.d, t0 = a.t0, t1 = a.t1, pos = self:pos_of(a) }, b = { d = b.d, t0 = b.t0, t1 = b.t1, pos = self:pos_of(b) },
           line = self:current_line(), tol_time = self.tol_time, tol_cents = self.tol_cents }
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
  self.results[path] = { path = path, line = info.line, grey0 = info.grey0, grey1 = info.grey1, ov0 = info.ov0, ov1 = info.ov1, t_start = info.t_start, threads = info.threads }
  local msg = string.format("%s: %d partials in %d rows, %d thread%s", basename(path), info.tracks, info.rows, info.pairs, info.pairs == 1 and "" or "s")
  if self.env.on_open(path) then
    self.env.set_status(msg)
    self.env.back()
  else
    self:say("the result was written but could not be opened: " .. path)
  end
end

-- ------------------------------------------------------------------ geometry
function Page:geom(W, H, top)
  local g = { x0 = 40, x1 = W - 40 }
  g.laneA = { y = top + 80, h = 104 }
  g.laneB = { y = top + 220, h = 104 }
  g.ruler = top + 330
  g.sl_time = { x = 40, y = top + 394, w = 300, h = 10 }
  g.sl_freq = { x = 40 + 380, y = top + 394, w = 300, h = 10 }
  g.btn = {
    back = { W - 120, top + 6, 90, 24 },
    load_a = { 40, top + 44, 110, 24 }, edit_a = { 158, top + 44, 190, 24 }, open_a = { 356, top + 44, 290, 24 },
    load_b = { 40, top + 188, 110, 24 }, edit_b = { 158, top + 188, 190, 24 }, open_b = { 356, top + 188, 290, 24 },
    make = { 40, top + 434, 190, 32 },
  }
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

function Page:mouse(mx, my, cap, wheel)
  local W, H = math.floor(gfx.w), math.floor(gfx.h)
  local g = self:geom(W, H, self.top or 40)
  local down = (cap & 1) ~= 0
  if down and not self.prev_down then
    self.drag = nil
    local b = g.btn
    if inside(b.back, mx, my) then self.env.back()
    elseif inside(b.load_a, mx, my) then self:choose("a")
    elseif inside(b.edit_a, mx, my) then self:edit_in_editor("a")
    elseif inside(b.open_a, mx, my) then self:use_open_sound("a")
    elseif inside(b.edit_b, mx, my) then self:edit_in_editor("b")
    elseif inside(b.open_b, mx, my) then self:use_open_sound("b")
    elseif inside(b.load_b, mx, my) then self:choose("b")
    elseif inside(b.make, mx, my) then self:make()
    else
      for _, which in ipairs({ "sl_time", "sl_freq" }) do
        local s = g[which]
        if mx >= s.x - 6 and mx < s.x + s.w + 6 and my >= s.y - 8 and my < s.y + s.h + 8 then
          self.drag = { kind = "slider", which = which }
          self:slider_value(g, which, mx)
        end
      end
      if not self.drag then
        local line = self:current_line()
        if line and math.abs(mx - self:tx(g, line)) <= 7 and my >= g.laneA.y - 14 and my <= g.laneB.y + g.laneB.h + 4 then
          self.drag = { kind = "line" }
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
            if math.abs(mx - x0) <= 7 then self.drag = { kind = "cut_in", slot = slot }
            elseif math.abs(mx - x1) <= 7 then self.drag = { kind = "cut_out", slot = slot }
            elseif mx >= self:tx(g, s.origin + s.d.times[1]) and mx <= self:tx(g, s.origin + sound_end(s)) then
              self.drag = { kind = "move", slot = slot, mx0 = mx, origin0 = s.origin }
            end
            if self.drag then break end
          end
        end
      end
    end
  elseif down and self.drag then
    local d = self.drag
    if d.kind == "slider" then self:slider_value(g, d.which, mx)
    elseif d.kind == "line" then
      local lo, hi = self:overlap()
      if lo then self.line = clamp(self:tt(g, mx), lo, hi) end
    elseif d.kind == "move" then
      self[d.slot].origin = d.origin0 + (mx - d.mx0) / g.pps
    elseif d.kind == "cut_in" then
      local s = self[d.slot]
      s.t0 = clamp(self:tt(g, mx) - s.origin, s.d.times[1], s.t1 - 0.05)
      s.full = false
    elseif d.kind == "cut_out" then
      local s = self[d.slot]
      s.t1 = clamp(self:tt(g, mx) - s.origin, s.t0 + 0.05, sound_end(s))
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
  if ch == 13 then self:make(); return true end
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
  local tx0 = math.max(ux0, g.x0) + 10
  gfx.set(0.03, 0.04, 0.06, 0.72)                                          -- a dark strip behind the name, so that it reads on the image
  gfx.rect(tx0 - 4, lane.y + 7, 300, 32, 1)
  gfx.setfont(1, "Arial", 14)
  gfx.set(col[1], col[2], col[3], 1)
  gfx.x, gfx.y = tx0, lane.y + 9
  gfx.drawstr(s.name)
  gfx.setfont(1, "Arial", 12)
  gfx.set(0.85, 0.87, 0.9, 1)
  gfx.x, gfx.y = tx0, lane.y + 25
  gfx.drawstr(string.format("used %.2f - %.2f s of %.2f s   hop %.0f ms   %d partials", s.t0, s.t1, s.d.dur, s.d.frame_size / s.d.sr * 1000, s.d.partials))
end

function Page:draw(W, H, top)
  self.top = top
  local g = self:geom(W, H, top)
  gfx.setfont(1, "Arial", 16)
  text(40, top + 8, "CROSS: sound A flows into sound B", 0.95, 0.72, 0.35)
  button(g.btn.back, "BACK", { 0.9, 0.55, 0.5 })
  button(g.btn.load_a, "LOAD A", BLUE)
  button(g.btn.edit_a, "EDIT A IN THE EDITOR", BLUE, self.a ~= nil)
  button(g.btn.open_a, "USE THE EDITOR'S SOUND AS A", BLUE)
  button(g.btn.load_b, "LOAD B", GREEN)
  button(g.btn.edit_b, "EDIT B IN THE EDITOR", GREEN, self.b ~= nil)
  button(g.btn.open_b, "USE THE EDITOR'S SOUND AS B", GREEN)
  self:draw_block(g, "a")
  self:draw_block(g, "b")
  gfx.setfont(1, "Arial", 10)                                              -- the frequency scale of the images (the same for both)
  for _, lane in ipairs({ g.laneA, g.laneB }) do
    text(4, lane.y + 4, "10k", 0.5, 0.53, 0.6); text(4, lane.y + lane.h - 14, "50 Hz", 0.5, 0.53, 0.6)
  end
  -- the ruler
  gfx.set(0.4, 0.43, 0.48, 1)
  gfx.line(g.x0, g.ruler, g.x1, g.ruler)
  local span = self.view[2] - self.view[1]
  local step = 1
  for _, st in ipairs({ 0.1, 0.25, 0.5, 1, 2, 5, 10, 30, 60, 120, 300 }) do step = st; if span / st <= 14 then break end end
  gfx.setfont(1, "Arial", 11)
  local t = math.ceil(self.view[1] / step) * step
  while t <= self.view[2] do
    local x = self:tx(g, t)
    gfx.set(0.4, 0.43, 0.48, 1); gfx.line(x, g.ruler, x, g.ruler + 5)
    text(x + 3, g.ruler + 6, string.format(step < 1 and "%.2f s" or "%g s", t), 0.55, 0.58, 0.64)
    t = t + step
  end
  -- the transition space, the red line and its grey band
  local line, lo, hi = self:current_line()
  if lo then
    gfx.set(0.55, 0.58, 0.65, 0.12)
    gfx.rect(self:tx(g, lo), g.laneA.y, self:tx(g, hi) - self:tx(g, lo), g.laneB.y + g.laneB.h - g.laneA.y, 1)
    local w = self.tol_time
    local g0, g1 = math.max(line - w / 2, lo), math.min(line + w / 2, hi)
    gfx.set(0.6, 0.63, 0.7, 0.35)
    gfx.rect(self:tx(g, g0), g.laneA.y, math.max(self:tx(g, g1) - self:tx(g, g0), 1), g.laneB.y + g.laneB.h - g.laneA.y, 1)
    gfx.set(1, 0.23, 0.19, 1)
    local x = self:tx(g, line)
    gfx.rect(x - 1, g.laneA.y - 12, 3, g.laneB.y + g.laneB.h - g.laneA.y + 16, 1)
    gfx.rect(x - 6, g.laneA.y - 14, 13, 8, 1)
    gfx.setfont(1, "Arial", 12)
    text(x + 10, g.laneA.y - 16, string.format("the red line  %.2f s", line), 1, 0.45, 0.4)
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
  slider(g.sl_time, "Time tolerance (the grey area)", self.tol_time < 0.005 and "hard line" or string.format("%.2f s", self.tol_time), math.sqrt(math.min(self.tol_time / self:time_max(), 1)))
  slider(g.sl_freq, "Frequency tolerance (which partials are one thread)", string.format("%d cents", self.tol_cents), (self.tol_cents - 10) / 590)
  gfx.setfont(1, "Arial", 12)
  local est = self.threads_est
  if est == -1 then text(40, g.sl_time.y + 22, "the number of threads is counted when the result is made (the sounds are big)", 0.6, 0.64, 0.7)
  elseif est then
    if est > 0 then text(40, g.sl_time.y + 22, string.format("%d thread%s: partials of A and B that sound together inside the grey area and are close in frequency (the orange blinking partials in the editor)", est, est == 1 and "" or "s"), 1, 0.62, 0.1)
    else text(40, g.sl_time.y + 22, "no threads: no partial of A and partial of B sound together inside the grey area within the frequency tolerance. A shorter grey area or a wider frequency tolerance may help.", 1, 0.5, 0.3) end
  end
  button(g.btn.make, "MAKE RESULT", { 0.45, 0.85, 0.6 }, self.a ~= nil and self.b ~= nil)
  gfx.setfont(1, "Arial", 12)
  text(g.btn.make[1] + g.btn.make[3] + 14, g.btn.make[2] + 9, "writes a new .ats file and opens it in the editor (A and B stay as they are); Enter does the same", 0.6, 0.64, 0.7)
  if self.message then text(40, top + 478, self.message, 1, 0.8, 0.45) end
  text(40, top + 506, "Drag a block to place it in time. Drag the white handles at its ends to use only a part of the file. Drag the red line inside the overlap. Double-click a block (or EDIT) to edit that sound in the editor: what you change there comes back as that sound, without saving.", 0.55, 0.58, 0.64)
  text(40, top + 524, "The partials of A and B that are close in frequency (the tolerance) become one thread that moves from A's frequency to B's.", 0.55, 0.58, 0.64)
end

return M
