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

print(string.format("%d passed, %d failed", ok, fails))
os.exit(fails == 0 and 0 or 1)
