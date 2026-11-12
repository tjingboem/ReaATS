-- Run: lua5.4 tests/test_ats_warp.lua   (from the ReaATS folder)
package.path = "lib/?.lua;" .. package.path
local warp = require("ats_warp")
local ok, fails = 0, 0
local function check(name, cond, extra)
  if cond then ok = ok + 1 else fails = fails + 1; print("FAIL: " .. name .. " " .. tostring(extra or "")) end
end
local function near(a, b, eps) return math.abs(a - b) < (eps or 1e-9) end

local w = warp.new(1, 3, 100, 800)
check("a new warp is flat", warp.is_flat(w) and near(warp.displacement(w, 0.3, 0.7), 0))

-- the right edge up by an octave: a straight bend, the same at every height
warp.move_edge(w, "right", 12)
check("right edge up: not flat", not warp.is_flat(w))
check("right edge up: 0 at the left, 12 at the right", near(warp.displacement(w, 0, 0.5), 0) and near(warp.displacement(w, 1, 0.2), 12) and near(warp.displacement(w, 1, 1), 12))
check("right edge up: linear in time, at every height", near(warp.displacement(w, 0.5, 0.1), 6) and near(warp.displacement(w, 0.25, 0.9), 3) and near(warp.displacement(w, 0.75, 0.5), 9))
check("right edge up: the corners moved in the top and bottom edges too", near(w.bottom.pts[#w.bottom.pts].v, 12) and near(w.top.pts[#w.top.pts].v, 12))

-- one corner up: a tilt that is bilinear, the lower right stays
w = warp.new(0, 1, 100, 800)
warp.set_value(w, "top", 2, 12)                                      -- the top right corner
check("corner: the corner moves, the others stay", near(warp.displacement(w, 1, 1), 12) and near(warp.displacement(w, 1, 0), 0) and near(warp.displacement(w, 0, 1), 0) and near(warp.displacement(w, 0, 0), 0))
check("corner: bilinear inside (u*v*12)", near(warp.displacement(w, 0.5, 0.5), 3) and near(warp.displacement(w, 0.5, 1), 6) and near(warp.displacement(w, 1, 0.5), 6))
check("corner: it is the same corner in both edges", near(w.right.pts[#w.right.pts].v, 12))

-- the top edge up: every point moves by an amount that grows with its height
w = warp.new(0, 1, 100, 800)
warp.move_edge(w, "top", 6)
check("top edge up: nothing at the bottom, 6 at the top, 3 half way", near(warp.displacement(w, 0.5, 0), 0) and near(warp.displacement(w, 0.5, 1), 6) and near(warp.displacement(w, 0.5, 0.5), 3))

-- a border point: adding one changes nothing, moving it bends the edge
w = warp.new(0, 1, 100, 800)
local before = warp.displacement(w, 0.5, 1)
local i = warp.add_point(w, "top", 0.5)
check("add_point: index 2 in the middle", i == 2 and #w.top.pts == 3)
check("add_point: nothing moves", near(warp.displacement(w, 0.5, 1), before) and warp.is_flat(w))
warp.set_value(w, "top", i, 4)
check("a moved border point: the edge goes through it", near(warp.edge_value(w.top, 0.5), 4) and near(warp.edge_value(w.top, 0.25), 2) and near(warp.edge_value(w.top, 0.75), 2))
check("a moved border point: the corners stay", near(w.top.pts[1].v, 0) and near(w.top.pts[3].v, 0))
check("a moved border point reaches the inside of the box", near(warp.displacement(w, 0.5, 1), 4) and near(warp.displacement(w, 0.5, 0.5), 2))
warp.set_position(w, "top", i, 0.8)
check("set_position moves it along the edge", near(w.top.pts[2].s, 0.8) and near(warp.edge_value(w.top, 0.8), 4))
warp.set_position(w, "top", i, 5)
check("set_position stays between the neighbours", w.top.pts[2].s < 1 and w.top.pts[2].s > 0.99)
check("remove_point takes it away", warp.remove_point(w, "top", i) and #w.top.pts == 2 and warp.is_flat(w))
check("the corners cannot be removed", not warp.remove_point(w, "top", 1) and not warp.remove_point(w, "top", 2))

-- a bulge curves a segment: the middle moves by the bulge, the ends stay
w = warp.new(0, 1, 100, 800)
w.top.bulge[1] = 3
check("bulge: 3 semitones at the middle, 0 at the ends", near(warp.edge_value(w.top, 0.5), 3) and near(warp.edge_value(w.top, 0), 0) and near(warp.edge_value(w.top, 1), 0))
check("bulge: not flat", not warp.is_flat(w))
-- adding a point on a curved segment keeps the curve
w.top.bulge[1] = 4
local v25, v50, v75 = warp.edge_value(w.top, 0.25), warp.edge_value(w.top, 0.5), warp.edge_value(w.top, 0.75)
warp.add_point(w, "top", 0.5)
check("a point on an arched segment keeps its shape", near(warp.edge_value(w.top, 0.25), v25, 1e-6) and near(warp.edge_value(w.top, 0.5), v50) and near(warp.edge_value(w.top, 0.75), v75, 1e-6),
  warp.edge_value(w.top, 0.25) .. " " .. v25)

-- the changes: selected points move by their own displacement
local d = { sr = 44100, times = { 1, 2, 3 }, amp = { { 0.5, 0.5, 0.5 }, { 0.5, 0.5, 0.5 } }, frq = { { 200, 200, 200 }, { 400, 400, 400 } } }
w = warp.new(1, 3, 100, 800)
warp.move_edge(w, "right", 12)
local ch = warp.changes(d, { [1] = { [1] = true, [2] = true, [3] = true }, [2] = { [3] = true } }, w)
local by = {}
for _, c in ipairs(ch) do by[c.p .. "/" .. c.f] = c end
check("changes: the left end does not move", by["1/1"] == nil)
check("changes: the middle moves a half octave up", by["1/2"] and near(by["1/2"].nf, 200 * 2 ^ (6 / 12), 1e-6) and by["1/2"].na == 0.5 and by["1/2"].of == 200)
check("changes: the right end moves an octave up, at any height", by["1/3"] and near(by["1/3"].nf, 400, 1e-6) and by["2/3"] and near(by["2/3"].nf, 800, 1e-6))
check("changes: only selected points", by["2/1"] == nil and by["2/2"] == nil)
check("a flat warp gives no changes", #warp.changes(d, { [1] = { [1] = true } }, warp.new(1, 3, 100, 800)) == 0)
check("max_abs", near(warp.max_abs(w), 12, 1e-6))

-- time: control points also hold a displacement in seconds (h)
w = warp.new(0, 10, 100, 800)
warp.move_edge(w, "right", 0, 2)                                     -- the right edge 2 s later: a straight stretch
check("time: not flat", not warp.is_flat(w))
check("time: 0 at the left, 2 s at the right, linear in time, at every height",
      near(warp.displacement_h(w, 0, 0.5), 0) and near(warp.displacement_h(w, 1, 0.2), 2) and near(warp.displacement_h(w, 0.5, 0.9), 1) and near(warp.displacement(w, 0.5, 0.5), 0))
check("time: the corners carry their h to the other edges", near(w.top.pts[#w.top.pts].h, 2) and near(w.bottom.pts[#w.bottom.pts].h, 2))
local map = warp.mapper(w)
local t2, f2 = map(5, 300)
check("mapper: half way through: 1 s later, same frequency", near(t2, 6) and near(f2, 300))
check("monotone: a stretch is monotone", warp.monotone(w))
warp.move_edge(w, "right", 0, -14)                                   -- the right edge pulled to 14 s before where it was: folds time back
check("monotone: folding time back is refused", not warp.monotone(w))
w = warp.new(0, 10, 100, 800)
warp.move_edge(w, "right", 3, 2)
local t3, f3 = warp.mapper(w)(10, 800)
check("mapper: both: the top right corner goes later and up", near(t3, 12) and near(f3, 800 * 2 ^ (3 / 12)))
-- snapshot and restore
w = warp.new(0, 10, 100, 800)
local snap = warp.snapshot(w)
warp.add_point(w, "top", 0.5); warp.move_edge(w, "top", 4, 1); w.top.bulge_h[1] = 2
check("snapshot: changed", not warp.is_flat(w) and #w.top.pts == 3)
warp.restore(w, snap)
check("restore: flat again, two points", warp.is_flat(w) and #w.top.pts == 2 and #w.top.bulge_h == 1)
-- a border dot carries h too, and its arch keeps its shape when it is cut in two
w = warp.new(0, 10, 100, 800)
w.top.bulge_h[1] = 4
local h25, h50 = warp.edge_h(w.top, 0.25), warp.edge_h(w.top, 0.5)
local ii = warp.add_point(w, "top", 0.5)
check("add_point keeps h and its arch", ii == 2 and near(w.top.pts[2].h, h50) and near(warp.edge_h(w.top, 0.25), h25, 1e-6) and near(warp.max_abs_h(w), 4, 1e-6))
-- slant (12 Nov 2026): the speed of a stretch falls from the left to the right border, or the other way round
do
  local function stretched(dh)                                       -- a box 4 s long whose right border is moved dh seconds later
    local w = warp.new(10, 14, 100, 1000)
    warp.set_value(w, "bottom", 2, 0, dh); warp.set_value(w, "top", 2, 0, dh)
    return w
  end
  local w = stretched(4)                                             -- 4 s become 8 s: x2
  local base = warp.snapshot(w)
  check("slant: a plain stretch is even", math.abs(warp.stretch_at(w, "top", 0.1) - 2) < 1e-6 and math.abs(warp.stretch_at(w, "top", 0.9) - 2) < 1e-6)
  local k = warp.set_slant(w, base, 1)
  check("slant 1: k comes back as 1", k == 1)
  check("slant 1: the left border goes at x3 (1 + 2)", math.abs(warp.stretch_at(w, "top", 0) - 3) < 0.02, warp.stretch_at(w, "top", 0))
  check("slant 1: the right border is not stretched (x1)", math.abs(warp.stretch_at(w, "top", 1) - 1) < 0.02, warp.stretch_at(w, "top", 1))
  check("slant 1: the right border ends where it did", math.abs(warp.edge_h(w.top, 1) - 4) < 1e-9 and math.abs(warp.edge_h(w.bottom, 1) - 4) < 1e-9)
  check("slant 1: the left border does not move", math.abs(warp.edge_h(w.top, 0)) < 1e-9)
  check("slant 1: still monotone", warp.monotone(w))
  warp.set_slant(w, base, -1)
  check("slant -1: the left border is not stretched, the right one x3", math.abs(warp.stretch_at(w, "top", 0) - 1) < 0.02 and math.abs(warp.stretch_at(w, "top", 1) - 3) < 0.02)
  warp.set_slant(w, base, 0)
  check("slant 0 is the plain stretch again", math.abs(warp.stretch_at(w, "top", 0.1) - 2) < 1e-6 and math.abs(warp.stretch_at(w, "bottom", 0.9) - 2) < 1e-6)
  -- the inside of the box follows (a point in the middle of the height)
  warp.set_slant(w, base, 1)
  check("slant: the same displacement at every height", math.abs(warp.displacement_h(w, 0.3, 0.2) - warp.displacement_h(w, 0.3, 0.9)) < 1e-9)
  -- a squeeze that would fold time back is limited
  local sq = stretched(-3.2)                                         -- 4 s squeezed to 0.8 s
  local sb = warp.snapshot(sq)
  local used = warp.set_slant(sq, sb, 1)
  check("slant: a squeeze is limited to what keeps time in order", used < 1 and warp.monotone(sq), used)
  -- a stretch that is not even to begin with: the arch it has is kept, the slant is added
  local w2 = stretched(4)
  w2.top.bulge_h[1] = 0.5
  local b2 = warp.snapshot(w2)
  warp.set_slant(w2, b2, 0.5)
  check("slant adds to the arch that was there", math.abs(w2.top.bulge_h[1] - (0.5 + 0.5 * 4 / 4)) < 1e-9, w2.top.bulge_h[1])
  warp.set_slant(w2, b2, 0)
  check("slant 0 gives the old arch back", math.abs(w2.top.bulge_h[1] - 0.5) < 1e-9)
  -- the mapper that moves the points: a quarter of the way in, a slant of 1 has already moved the point further (4 s * (0.25 + 0.1875))
  local mp = warp.mapper(w)
  local t_new = mp(10 + 4 * 0.25, 300)
  check("slant: where a point a quarter in goes", math.abs(t_new - (11 + 4 * (0.25 + 0.25 * 0.75))) < 1e-9, t_new)
  -- two segments (a border dot): each segment slants by its own displacement
  local w3 = stretched(4)
  warp.add_point(w3, "top", 0.5); warp.add_point(w3, "bottom", 0.5)
  local b3 = warp.snapshot(w3)
  warp.set_slant(w3, b3, 1)
  check("slant: both segments of an edge with a dot", math.abs(w3.top.bulge_h[1] - 0.5) < 1e-9 and math.abs(w3.top.bulge_h[2] - 0.5) < 1e-9, w3.top.bulge_h[1])
end

print(string.format("%d passed, %d failed", ok, fails))
os.exit(fails == 0 and 0 or 1)
