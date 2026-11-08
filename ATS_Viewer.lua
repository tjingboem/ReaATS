--[[----------------------------------------------------------------------------
  ATS_Viewer.lua  --  read-only viewer for Csound/ATS ".ats" files (first step
  of a SPEAR-like partial editor for REAPER; nothing is edited here).

  Shows the sine partials as lines (time across, frequency up on a log axis,
  brighter = louder) and the 25 noise bands as a faint shaded layer behind them.

  Run it from the action list (Actions > Show action list > ReaScript: Load...).
  The first run asks for a .ats file; later runs reopen the last one.

  Mouse:  wheel = zoom time        Ctrl+wheel = zoom frequency
          Shift+wheel = scroll time    left drag = pan
          hover = time / frequency / nearest partial
  Keys:   O open file   R reload   F or Home fit view
          P partials on/off   N noise on/off   Esc close
--------------------------------------------------------------------------------]]

local script_dir = ({ reaper.get_action_context() })[2]:match("^(.*)[/\\]") or "."
local ats = dofile(script_dir .. "/lib/ats_file.lua")

-- ------------------------------------------------------------------ settings
local TITLE = "ATS Viewer"
local DB_FLOOR = -80            -- partials quieter than this (relative to the loudest) are not drawn
local NOISE_RANGE_DB = 60       -- noise shading spans this many dB below the loudest band
local MARGIN_L, MARGIN_R, MARGIN_T, MARGIN_B = 62, 50, 52, 38
local EXT_SECTION, EXT_LAST = "tjingboem_ATSViewer", "last_file"

-- --------------------------------------------------------------------- state
local data, fname, load_error
local view = { t0 = 0, t1 = 1, f0 = 40, f1 = 16000 }
local show_partials, show_noise = true, true
local dirty = true
local last_w, last_h = 0, 0
local drag = nil               -- { x, y } of the last mouse position while dragging
local prev_down = false        -- left button state in the previous frame (for click detection)
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

-- Noise-layer checkbox, top right of the header.
local function checkbox_rect()
  return math.floor(gfx.w) - 128, 8, 118, 16
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

local function draw_header(px, py, pw, ph)
  gfx.setfont(1, "Arial", 14)
  if not data then
    text_at(px, 10, load_error and ("Could not read:\n" .. load_error) or "Press O to open a .ats file", 0.95, 0.85, 0.5)
    return
  end
  local name = fname:match("([^/\\]+)$") or fname
  local hop_ms = data.frame_size / data.sr * 1000
  text_at(px, 8, string.format("%s   |   %d partials   %d frames   %.2f s   %d Hz   hop %.1f ms   type %d%s%s",
    name, data.partials, data.frames, data.dur, data.sr, hop_ms, data.type,
    data.has_phase and " (phase)" or "", data.has_noise and " (noise)" or ""))
  draw_checkbox()
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
  text_at(px, gfx.h - 18,
    "wheel zoom time   Ctrl+wheel zoom frequency   Shift+wheel scroll   drag pan   O open   R reload   F fit   P partials   N noise",
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

  if data and cap & 1 ~= 0 then
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

  local down = (cap & 1) ~= 0
  if down and not prev_down then
    local cx, cy, cw, chh = checkbox_rect()
    if mx >= cx and mx < cx + cw and my >= cy and my < cy + chh then
      show_noise = not show_noise
      dirty = true
    end
  end
  prev_down = down

  local ch = gfx.getchar()
  if ch < 0 or ch == 27 then return false end
  if ch == 111 or ch == 79 then open_dialog()
  elseif ch == 114 or ch == 82 then if fname then load_file(fname) end
  elseif ch == 102 or ch == 70 or ch == 1752132965 then fit_view()
  elseif ch == 112 or ch == 80 then show_partials = not show_partials; dirty = true
  elseif ch == 110 or ch == 78 then show_noise = not show_noise; dirty = true end
  return true
end

-- ---------------------------------------------------------------------- main
local function loop()
  local px, py, pw, ph = plot_rect()
  if math.floor(gfx.w) ~= last_w or math.floor(gfx.h) ~= last_h then
    last_w, last_h = math.floor(gfx.w), math.floor(gfx.h)
    dirty = true
  end
  local keep = handle_input(px, py, pw, ph)
  if dirty then render_cache(pw, ph) end

  gfx.set(0.09, 0.10, 0.12, 1)
  gfx.rect(0, 0, gfx.w, gfx.h, 1)
  gfx.blit(1, 1, 0, 0, 0, pw, ph, px, py, pw, ph)
  draw_axes(px, py, pw, ph)
  draw_header(px, py, pw, ph)
  gfx.update()
  if keep then reaper.defer(loop) end
end

gfx.init(TITLE, 1100, 640)
local last = reaper.GetExtState(EXT_SECTION, EXT_LAST)
if last ~= "" and reaper.file_exists(last) then
  load_file(last)
else
  open_dialog()
end
loop()
