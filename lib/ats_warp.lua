-- ats_warp.lua -- the "rubber sheet" behind the selection box (pure maths, no REAPER calls, so it can be tested with plain Lua).
--
-- A box in time and frequency has four edges: bottom, top (along time) and left, right (along frequency). Every edge is a line of
-- control points; a point holds a displacement in SEMITONES (how far the points of the sheet at that place move up or down). Between two
-- control points the displacement is linear, plus an arch ("bulge", in semitones at the middle of the segment) that curves it. The corners
-- belong to two edges and always have the same value in both.
--
-- The displacement inside the box is a Coons patch: the four edges blended, with the corners taken out once:
--   D(u, v) = (1-v) B(u) + v T(u) + (1-u) L(v) + u R(v)  -  [ (1-u)(1-v) c_bl + u (1-v) c_br + (1-u) v c_tl + u v c_tr ]
-- u runs 0..1 along time, v runs 0..1 from the lowest to the highest frequency of the box (in log frequency). The edge values are
-- reproduced exactly on the border, and inside the box the points follow smoothly. With all values 0 nothing moves.
-- (Phase 1: displacements are in frequency only; moving points in time is a later step.)

local M = {}

local function clamp(x, a, b) if x < a then return a elseif x > b then return b else return x end end

local function new_edge() return { pts = { { s = 0, v = 0 }, { s = 1, v = 0 } }, bulge = { 0 } } end

-- A new, flat warp over the box t0..t1 (seconds), f0..f1 (Hz).
function M.new(t0, t1, f0, f1)
  return { t0 = t0, t1 = t1, f0 = f0, f1 = f1, bottom = new_edge(), top = new_edge(), left = new_edge(), right = new_edge() }
end

M.EDGES = { "bottom", "top", "left", "right" }

-- The displacement (semitones) of an edge at position s (0..1).
function M.edge_value(edge, s)
  local pts = edge.pts
  s = clamp(s, 0, 1)
  for i = 1, #pts - 1 do
    local a, b = pts[i], pts[i + 1]
    if s <= b.s or i == #pts - 1 then
      local w = (b.s > a.s) and clamp((s - a.s) / (b.s - a.s), 0, 1) or 0
      return a.v + (b.v - a.v) * w + (edge.bulge[i] or 0) * 4 * w * (1 - w)
    end
  end
  return 0
end

local function corners(w)
  return w.bottom.pts[1].v, w.bottom.pts[#w.bottom.pts].v, w.top.pts[1].v, w.top.pts[#w.top.pts].v   -- bl, br, tl, tr
end

-- The displacement (semitones) at u (0..1 along time) and v (0..1 up the box).
function M.displacement(w, u, v)
  u, v = clamp(u, 0, 1), clamp(v, 0, 1)
  local bl, br, tl, tr = corners(w)
  return (1 - v) * M.edge_value(w.bottom, u) + v * M.edge_value(w.top, u)
       + (1 - u) * M.edge_value(w.left, v) + u * M.edge_value(w.right, v)
       - ((1 - u) * (1 - v) * bl + u * (1 - v) * br + (1 - u) * v * tl + u * v * tr)
end

function M.is_flat(w)
  for _, name in ipairs(M.EDGES) do
    local e = w[name]
    for _, p in ipairs(e.pts) do if math.abs(p.v) > 1e-9 then return false end end
    for _, b in ipairs(e.bulge) do if math.abs(b) > 1e-9 then return false end end
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

-- Sets the displacement of point i of an edge; a corner changes in both of its edges.
function M.set_value(w, edge, i, v)
  w[edge].pts[i].v = v
  local t = twin(w, edge, i)
  if t then w[t[1]].pts[t[2]].v = v end
end

-- Moves a whole edge up or down by dv semitones (its corners move with it).
function M.move_edge(w, edge, dv)
  for i, p in ipairs(w[edge].pts) do M.set_value(w, edge, i, p.v + dv) end
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
      local v = M.edge_value(e, s)
      local old = e.bulge[i] or 0
      local frac = (s - a.s) / (b.s - a.s)
      table.insert(e.pts, i + 1, { s = s, v = v })
      e.bulge[i] = old * frac * frac                       -- (an arch cut in two keeps its shape: each part has the square of its length)
      table.insert(e.bulge, i + 1, old * (1 - frac) * (1 - frac))
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
  e.bulge[i - 1] = 0
  table.remove(e.bulge, i)
  return true
end

-- The largest displacement on the border (for a status message), in semitones.
function M.max_abs(w)
  local m = 0
  for _, name in ipairs(M.EDGES) do
    for k = 0, 20 do m = math.max(m, math.abs(M.edge_value(w[name], k / 20))) end
  end
  return m
end

-- The changes that apply the warp to the selected points of one channel: sel[p] = { [frame] = true }.
-- Returns a list of { p, f, oa, na, of, nf } (the amplitude stays), and nothing for points that do not move.
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

return M
