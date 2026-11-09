-- ats_warp.lua -- the "rubber sheet" behind the selection box (pure maths, no REAPER calls, so it can be tested with plain Lua).
--
-- A box in time and frequency has four edges: bottom, top (along time) and left, right (along frequency). Every edge is a line of
-- control points; a point holds two displacements: v, in SEMITONES (how far the points of the sheet at that place move up or down) and
-- h, in SECONDS (how far they move later or earlier). Between two control points both are linear, plus an arch ("bulge", "bulge_h": the
-- extra displacement at the middle of the segment) that curves them. The corners belong to two edges and always have the same values
-- in both.
--
-- The displacement inside the box is a Coons patch (for v and for h alike): the four edges blended, with the corners taken out once:
--   D(u, v) = (1-v) B(u) + v T(u) + (1-u) L(v) + u R(v)  -  [ (1-u)(1-v) c_bl + u (1-v) c_br + (1-u) v c_tl + u v c_tr ]
-- u runs 0..1 along time, v runs 0..1 from the lowest to the highest frequency of the box (in log frequency). The edge values are
-- reproduced exactly on the border, and inside the box the points follow smoothly. With all values 0 nothing moves.
-- A bend in time must keep the order of time (monotone): M.monotone says whether a warp does.

local M = {}

local function clamp(x, a, b) if x < a then return a elseif x > b then return b else return x end end

local function new_edge() return { pts = { { s = 0, v = 0, h = 0 }, { s = 1, v = 0, h = 0 } }, bulge = { 0 }, bulge_h = { 0 } } end

-- A new, flat warp over the box t0..t1 (seconds), f0..f1 (Hz).
function M.new(t0, t1, f0, f1)
  return { t0 = t0, t1 = t1, f0 = f0, f1 = f1, bottom = new_edge(), top = new_edge(), left = new_edge(), right = new_edge() }
end

M.EDGES = { "bottom", "top", "left", "right" }

-- The displacement of an edge at position s (0..1): `what` is "v" (semitones) or "h" (seconds).
local function edge_component(edge, s, what)
  local pts = edge.pts
  local arch = (what == "h") and edge.bulge_h or edge.bulge
  s = clamp(s, 0, 1)
  for i = 1, #pts - 1 do
    local a, b = pts[i], pts[i + 1]
    if s <= b.s or i == #pts - 1 then
      local w = (b.s > a.s) and clamp((s - a.s) / (b.s - a.s), 0, 1) or 0
      return a[what] + (b[what] - a[what]) * w + (arch[i] or 0) * 4 * w * (1 - w)
    end
  end
  return 0
end

function M.edge_value(edge, s) return edge_component(edge, s, "v") end
function M.edge_h(edge, s) return edge_component(edge, s, "h") end

local function corners(w, what)
  return w.bottom.pts[1][what], w.bottom.pts[#w.bottom.pts][what], w.top.pts[1][what], w.top.pts[#w.top.pts][what]   -- bl, br, tl, tr
end

local function coons(w, u, v, what)
  u, v = clamp(u, 0, 1), clamp(v, 0, 1)
  local bl, br, tl, tr = corners(w, what)
  return (1 - v) * edge_component(w.bottom, u, what) + v * edge_component(w.top, u, what)
       + (1 - u) * edge_component(w.left, v, what) + u * edge_component(w.right, v, what)
       - ((1 - u) * (1 - v) * bl + u * (1 - v) * br + (1 - u) * v * tl + u * v * tr)
end

-- The displacement in semitones, and in seconds, at u (0..1 along time) and v (0..1 up the box).
function M.displacement(w, u, v) return coons(w, u, v, "v") end
function M.displacement_h(w, u, v) return coons(w, u, v, "h") end

function M.is_flat(w)
  for _, name in ipairs(M.EDGES) do
    local e = w[name]
    for _, p in ipairs(e.pts) do if math.abs(p.v) > 1e-9 or math.abs(p.h) > 1e-9 then return false end end
    for _, b in ipairs(e.bulge) do if math.abs(b) > 1e-9 then return false end end
    for _, b in ipairs(e.bulge_h) do if math.abs(b) > 1e-9 then return false end end
  end
  return true
end

-- The same edge point's twin at the other edge, for the four corners: { edge, index } pairs.
local function twin(w, edge, i)
  local e = w[edge]
  local first, last = (i == 1), (i == #e.pts)
  if not (first or last) then return nil end
  if edge == "bottom" then return first and { "left", 1 } or { "right", 1 }
  elseif edge == "top" then return first and { "left", #w.left.pts } or { "right", #w.right.pts }
  elseif edge == "left" then return first and { "bottom", 1 } or { "top", 1 }
  else return first and { "bottom", #w.bottom.pts } or { "top", #w.top.pts } end
end

-- Sets the displacement of point i of an edge (v semitones, and h seconds when given); a corner changes in both of its edges.
function M.set_value(w, edge, i, v, h)
  w[edge].pts[i].v = v
  if h then w[edge].pts[i].h = h end
  local t = twin(w, edge, i)
  if t then
    w[t[1]].pts[t[2]].v = v
    if h then w[t[1]].pts[t[2]].h = h end
  end
end

-- Moves a whole edge by dv semitones and dh seconds (its corners move with it).
function M.move_edge(w, edge, dv, dh)
  for i, p in ipairs(w[edge].pts) do M.set_value(w, edge, i, p.v + (dv or 0), p.h + (dh or 0)) end
end

-- Moves an interior point along its edge (to position s, between its neighbours).
function M.set_position(w, edge, i, s)
  local pts = w[edge].pts
  if i <= 1 or i >= #pts then return end
  pts[i].s = clamp(s, pts[i - 1].s + 1e-4, pts[i + 1].s - 1e-4)
end

-- Adds a point at position s of an edge, on the line as it is now (nothing moves). Returns its index.
function M.add_point(w, edge, s)
  local e = w[edge]
  s = clamp(s, 1e-4, 1 - 1e-4)
  for i = 1, #e.pts - 1 do
    local a, b = e.pts[i], e.pts[i + 1]
    if s > a.s and s < b.s then
      local v, h = M.edge_value(e, s), M.edge_h(e, s)
      local old, old_h = e.bulge[i] or 0, e.bulge_h[i] or 0
      local frac = (s - a.s) / (b.s - a.s)
      table.insert(e.pts, i + 1, { s = s, v = v, h = h })
      e.bulge[i], e.bulge_h[i] = old * frac * frac, old_h * frac * frac           -- (an arch cut in two keeps its shape: each part has the square of its length)
      table.insert(e.bulge, i + 1, old * (1 - frac) * (1 - frac))
      table.insert(e.bulge_h, i + 1, old_h * (1 - frac) * (1 - frac))
      return i + 1
    end
  end
  return nil
end

-- Removes an interior point. The two segments become one, straight.
function M.remove_point(w, edge, i)
  local e = w[edge]
  if i <= 1 or i >= #e.pts then return false end
  table.remove(e.pts, i)
  e.bulge[i - 1], e.bulge_h[i - 1] = 0, 0
  table.remove(e.bulge, i)
  table.remove(e.bulge_h, i)
  return true
end

-- The largest displacement on the border: semitones (max_abs) and seconds (max_abs_h), for a status message.
function M.max_abs(w)
  local m = 0
  for _, name in ipairs(M.EDGES) do
    for k = 0, 20 do m = math.max(m, math.abs(M.edge_value(w[name], k / 20))) end
  end
  return m
end

function M.max_abs_h(w)
  local m = 0
  for _, name in ipairs(M.EDGES) do
    for k = 0, 20 do m = math.max(m, math.abs(M.edge_h(w[name], k / 20))) end
  end
  return m
end

-- A copy of everything that can change in a warp (the control points and arches), and a way back to it.
function M.snapshot(w)
  local snap = {}
  for _, name in ipairs(M.EDGES) do
    local e, c = w[name], { pts = {}, bulge = {}, bulge_h = {} }
    for i, p in ipairs(e.pts) do c.pts[i] = { s = p.s, v = p.v, h = p.h } end
    for i, b in ipairs(e.bulge) do c.bulge[i] = b end
    for i, b in ipairs(e.bulge_h) do c.bulge_h[i] = b end
    snap[name] = c
  end
  return snap
end

function M.restore(w, snap)
  for _, name in ipairs(M.EDGES) do
    local c = snap[name]
    w[name] = { pts = {}, bulge = {}, bulge_h = {} }
    for i, p in ipairs(c.pts) do w[name].pts[i] = { s = p.s, v = p.v, h = p.h } end
    for i, b in ipairs(c.bulge) do w[name].bulge[i] = b end
    for i, b in ipairs(c.bulge_h) do w[name].bulge_h[i] = b end
  end
end

-- True when the warp keeps the order of time: at every height of the box the time of a point still grows from left to right (by at
-- least a twentieth of the spacing it had), so that a track cannot fold back on itself.
function M.monotone(w)
  local span = w.t1 - w.t0
  if span <= 0 then return true end
  local steps = 64
  for vi = 0, 8 do
    local v = vi / 8
    local prev
    for ui = 0, steps do
      local u = ui / steps
      local t = u * span + M.displacement_h(w, u, v)
      if prev and t - prev < 0.05 * span / steps then return false end
      prev = t
    end
  end
  return true
end

-- The changes that apply the warp to the selected points of one channel when only frequencies move (no time displacement): sel[p] = { [frame] = true }.
-- Returns a list of { p, f, oa, na, of, nf } (the amplitude stays). (For a warp with time displacement use ats_edit.plan_warp.)
function M.changes(d, sel, w)
  local out = {}
  local l0, l1 = math.log(w.f0), math.log(w.f1)
  local span_t, span_l = w.t1 - w.t0, l1 - l0
  local ny = d.sr / 2 - 1
  for p, frames in pairs(sel) do
    local amp, frq = d.amp[p], d.frq[p]
    for f in pairs(frames) do
      local fr = frq[f]
      local u = (span_t > 0) and (d.times[f] - w.t0) / span_t or 0
      local v = (span_l > 0 and fr > 0) and (math.log(fr) - l0) / span_l or 0
      local st = M.displacement(w, u, v)
      if math.abs(st) > 1e-9 then
        out[#out + 1] = { p = p, f = f, oa = amp[f], na = amp[f], of = fr, nf = clamp(fr * 2 ^ (st / 12), 1, ny) }
      end
    end
  end
  return out
end

-- A function t, fr -> t', fr' that moves a point of the sheet to where the warp puts it (for ats_edit.plan_warp and for drawing).
function M.mapper(w)
  local span_t = w.t1 - w.t0
  local l0, span_l = math.log(w.f0), math.log(w.f1) - math.log(w.f0)
  return function(t, fr)
    local u = (span_t > 0) and (t - w.t0) / span_t or 0
    local v = (span_l > 0 and fr > 0) and (math.log(fr) - l0) / span_l or 0
    return t + M.displacement_h(w, u, v), fr * 2 ^ (M.displacement(w, u, v) / 12)
  end
end

return M
