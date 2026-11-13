-- cross_page.lua -- the CROSS page (tjingboem, 13 Nov 2026): sound A flows into sound B. An immediate-mode page like the Analysis page (Esc / BACK returns to the
-- editor). It holds the RECIPE only; the result is a new .ats file (lib/ats_cross.lua) that opens in the editor, where it is auditioned and finished by hand.
--   * two blocks, one per sound, drawn as long as the sound lasts, in two lanes (A above B) on one timeline; each is loaded from an .ats file (the name shows on it)
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
  self.result = nil                                 -- { path, line, grey0, grey1 } of the last result (the editor draws the line over it)
  return self
end

function Page:say(msg) self.message = msg end

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
  local s = { path = path, name = basename(path), d = d, origin = 0, t0 = d.times[1], t1 = d.times[d.frames], bytes = h.bytes }
  if slot == "b" and self.a then                                           -- (B starts half over the end of A: there is a transition space to begin with)
    local over = 0.5 * math.min(self.a.t1 - self.a.t0, s.t1 - s.t0)
    s.origin = (self.a.origin + self.a.t1 - over) - s.t0
  end
  self[slot] = s
  self.line = nil
  self.result = nil
  self:fit_view()
  self:say(string.format("%s loaded: %.2f s, %d partials", s.name, d.dur, d.partials))
  return true
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

function Page:use_open_sound()
  local path, modified = self.env.open_file()
  if not path then self:say("no sound is open in the editor"); return end
  if modified then self:say("the open sound has unsaved changes: save it first (Ctrl+S), then it can be used"); return end
  self:load("a", path)
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
  self.result = { path = path, line = info.line, grey0 = info.grey0, grey1 = info.grey1 }
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
  g.laneA = { y = top + 84, h = 70 }
  g.laneB = { y = top + 206, h = 70 }
  g.ruler = top + 284
  g.sl_time = { x = 40, y = top + 350, w = 300, h = 10 }
  g.sl_freq = { x = 40 + 380, y = top + 350, w = 300, h = 10 }
  g.btn = {
    back = { W - 120, top + 6, 90, 24 },
    load_a = { 40, top + 44, 110, 24 }, open_a = { 158, top + 44, 180, 24 },
    load_b = { 40, top + 166, 110, 24 },
    make = { 40, top + 398, 190, 32 },
  }
  g.pps = (g.x1 - g.x0) / math.max(self.view[2] - self.view[1], 1e-6)
  return g
end

function Page:tx(g, t) return g.x0 + (t - self.view[1]) * g.pps end
function Page:tt(g, x) return self.view[1] + (x - g.x0) / g.pps end

local function inside(r, mx, my) return mx >= r[1] and mx < r[1] + r[3] and my >= r[2] and my < r[2] + r[4] end

-- ------------------------------------------------------------------ mouse
function Page:slider_value(g, which, mx)
  local s = g[which]
  local frac = clamp((mx - s.x) / s.w, 0, 1)
  if which == "sl_time" then self.tol_time = math.floor(frac * frac * 4 * 100 + 0.5) / 100             -- 0 .. 4 s, finer at the short end
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
    elseif inside(b.open_a, mx, my) then self:use_open_sound()
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
    elseif d.kind == "cut_out" then
      local s = self[d.slot]
      s.t1 = clamp(self:tt(g, mx) - s.origin, s.t0 + 0.05, sound_end(s))
    end
  end
  if not down then
    if self.drag and (self.drag.kind == "move" or self.drag.kind == "cut_in" or self.drag.kind == "cut_out") then self:fit_view() end
    self.drag = nil
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
  -- the whole file (dim: the parts that are cut away) and the used part (the grey box, bright)
  gfx.set(col[1] * 0.28, col[2] * 0.28, col[3] * 0.28, 1)
  gfx.rect(fx0, lane.y + 4, fx1 - fx0, lane.h - 8, 1)
  gfx.set(col[1] * 0.75, col[2] * 0.75, col[3] * 0.75, 1)
  gfx.rect(ux0, lane.y + 4, ux1 - ux0, lane.h - 8, 1)
  gfx.set(col[1], col[2], col[3], 1)
  gfx.rect(fx0, lane.y + 4, fx1 - fx0, lane.h - 8, 0)
  gfx.set(1, 1, 1, 0.95)                                                   -- the handles of the cut
  gfx.rect(ux0 - 2, lane.y + 4, 4, lane.h - 8, 1)
  gfx.rect(ux1 - 2, lane.y + 4, 4, lane.h - 8, 1)
  gfx.setfont(1, "Arial", 14)
  gfx.set(0.04, 0.05, 0.07, 1)
  gfx.x, gfx.y = math.max(ux0, g.x0) + 10, lane.y + 12
  gfx.drawstr(s.name)
  gfx.setfont(1, "Arial", 12)
  gfx.x, gfx.y = math.max(ux0, g.x0) + 10, lane.y + 32
  gfx.drawstr(string.format("used %.2f - %.2f s of %.2f s   hop %.0f ms   %d partials", s.t0, s.t1, s.d.dur, s.d.frame_size / s.d.sr * 1000, s.d.partials))
end

function Page:draw(W, H, top)
  self.top = top
  local g = self:geom(W, H, top)
  gfx.setfont(1, "Arial", 16)
  text(40, top + 8, "CROSS: sound A flows into sound B", 0.95, 0.72, 0.35)
  button(g.btn.back, "BACK", { 0.9, 0.55, 0.5 })
  button(g.btn.load_a, "LOAD A", BLUE)
  button(g.btn.open_a, "A = THE OPEN SOUND", BLUE)
  button(g.btn.load_b, "LOAD B", GREEN)
  self:draw_block(g, "a")
  self:draw_block(g, "b")
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
  slider(g.sl_time, "Time tolerance (the grey area)", self.tol_time < 0.005 and "hard line" or string.format("%.2f s", self.tol_time), math.sqrt(self.tol_time / 4))
  slider(g.sl_freq, "Frequency tolerance (which partials are one thread)", string.format("%d cents", self.tol_cents), (self.tol_cents - 10) / 590)
  button(g.btn.make, "MAKE RESULT", { 0.45, 0.85, 0.6 }, self.a ~= nil and self.b ~= nil)
  gfx.setfont(1, "Arial", 12)
  text(g.btn.make[1] + g.btn.make[3] + 14, g.btn.make[2] + 9, "writes a new .ats file and opens it in the editor (A and B stay as they are); Enter does the same", 0.6, 0.64, 0.7)
  if self.message then text(40, top + 448, self.message, 1, 0.8, 0.45) end
  text(40, top + 480, "Drag a block to place it in time. Drag the white handles at its ends to use only a part of the file. Drag the red line inside the overlap.", 0.55, 0.58, 0.64)
  text(40, top + 498, "The partials of A and B that are close in frequency (the tolerance) become one thread that moves from A's frequency to B's.", 0.55, 0.58, 0.64)
end

return M
