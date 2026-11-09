-- Run: lua5.4 tests/test_ats_edit.lua   (from the ReaATS folder)
package.path = "lib/?.lua;" .. package.path
local edit = require("ats_edit")
local ok, fails = 0, 0
local function check(name, cond, extra)
  if cond then ok = ok + 1 else fails = fails + 1; print("FAIL: " .. name .. " " .. tostring(extra or "")) end
end

-- synthetic data: P partials x NF frames, no phase, no noise
local function make(P, NF)
  local d = { sr = 44100, partials = P, frames = NF, has_phase = false, has_noise = false, amp = {}, frq = {}, times = {} }
  for f = 1, NF do d.times[f] = (f - 1) * 0.01 end
  for p = 1, P do d.amp[p], d.frq[p] = {}, {}; for f = 1, NF do d.amp[p][f], d.frq[p][f] = 0, 0 end end
  return d
end
local function active(d)
  local n = 0
  for p = 1, d.partials do for f = 1, d.frames do if d.amp[p][f] > 0 then n = n + 1 end end end
  return n
end
local function apply(d, plan)
  edit.add_rows(d, plan.rows_after - d.partials)
  for _, c in ipairs(plan.changes) do d.amp[c.p][c.f] = c.na; d.frq[c.p][c.f] = c.nf end
end
local function revert(d, plan)
  for _, c in ipairs(plan.changes) do d.amp[c.p][c.f] = c.oa; d.frq[c.p][c.f] = c.of end
  edit.truncate_rows(d, plan.rows_before)
end
local function fill(d, p, f0, f1, freq, amp)
  for f = f0, f1 do d.amp[p][f] = amp or 0.5; d.frq[p][f] = freq + f end
end
local function snapshot(d)
  local t = {}
  for p = 1, d.partials do for f = 1, d.frames do t[#t + 1] = d.amp[p][f] .. "/" .. d.frq[p][f] end end
  return table.concat(t, ",")
end

-- 1. plain move into free cells stays in its own row
local d = make(2, 20); fill(d, 1, 3, 5, 100)
local before = snapshot(d)
local plan = edit.plan_move(d, { [1] = { [3] = true, [4] = true, [5] = true } }, 10, 1)
apply(d, plan)
check("plain move: still row 1", plan.rows_after == 2 and d.amp[1][13] > 0 and d.amp[1][3] == 0)
check("plain move: values travel", d.frq[1][13] == 103 and d.frq[1][15] == 105)
check("plain move: selection follows", plan.sel[1][13] and plan.sel[1][15] and not plan.sel[1][3])
revert(d, plan)
check("undo restores everything", snapshot(d) == before)

-- 2. overlapping the SAME row's other data: the run goes to another row, nothing is overwritten
d = make(2, 20); fill(d, 1, 3, 4, 100); fill(d, 1, 7, 10, 300)       -- piece A frames 3-4, piece B 7-10 (row 1)
plan = edit.plan_move(d, { [1] = { [3] = true, [4] = true } }, 4, 1)  -- A -> frames 7-8 (occupied by B)
local activeBefore = active(d)
apply(d, plan)
check("collision: B untouched in row 1", d.frq[1][7] == 307 and d.frq[1][10] == 310)
check("collision: A moved to row 2", d.amp[2][7] > 0 and d.frq[2][7] == 103 and d.frq[2][8] == 104)
check("collision: no points lost", active(d) == activeBefore)
check("collision: selection in row 2", plan.sel[2] and plan.sel[2][7] and not plan.sel[1])

-- 3. no free row anywhere -> a new row is created
d = make(2, 20); fill(d, 1, 3, 4, 100); fill(d, 1, 7, 10, 300); fill(d, 2, 7, 10, 500)
activeBefore = active(d)
plan = edit.plan_move(d, { [1] = { [3] = true, [4] = true } }, 4, 1)
check("new row planned", plan.rows_after == 3 and plan.rows_before == 2)
apply(d, plan)
check("new row exists", d.partials == 3 and d.amp[3][7] > 0 and d.frq[3][8] == 104)
check("new row: no points lost", active(d) == activeBefore)
revert(d, plan)
check("undo removes the new row", d.partials == 2 and active(d) == activeBefore)

-- 4. frequency ratio and clamping to the file
d = make(1, 10); fill(d, 1, 2, 4, 200)
plan = edit.plan_move(d, { [1] = { [2] = true, [3] = true, [4] = true } }, -50, 2)
check("df clamped so points stay inside", plan.df == -1)
apply(d, plan)
check("moved to frames 1-3", d.amp[1][1] > 0 and d.amp[1][3] > 0 and d.amp[1][4] == 0)
check("frequency doubled", d.frq[1][1] == 2 * 202, d.frq[1][1])
plan = edit.plan_move(d, { [1] = { [1] = true } }, -5, 1)
check("move that cannot happen does nothing", plan == nil)

-- 5. moving onto cells vacated by the same selection (shift by one inside a run)
d = make(1, 10); fill(d, 1, 2, 6, 100)
plan = edit.plan_move(d, { [1] = { [2] = true, [3] = true, [4] = true, [5] = true, [6] = true } }, 1, 1)
check("overlapping own run stays in row 1", plan.rows_after == 1)
apply(d, plan)
check("shifted run", d.amp[1][2] == 0 and d.amp[1][3] > 0 and d.amp[1][7] > 0 and d.frq[1][7] == 106)

-- 6. two runs of one row, destinations collide with each other -> separate rows, nothing lost
d = make(1, 20); fill(d, 1, 2, 3, 100); fill(d, 1, 6, 7, 200)
activeBefore = active(d)
plan = edit.plan_move(d, { [1] = { [2] = true, [3] = true, [6] = true, [7] = true } }, 2, 1)
apply(d, plan)
check("two runs: all points kept", active(d) == activeBefore)

-- 7. paste: into free cells it keeps its row, never overwrites, makes rows when needed, drops what is outside the file
d = make(2, 20); fill(d, 1, 3, 5, 100)
local clip = { { p = 1, df = 0, amp = 0.5, frq = 103 }, { p = 1, df = 1, amp = 0.5, frq = 104 }, { p = 1, df = 2, amp = 0.5, frq = 105 } }
before = snapshot(d)
plan = edit.plan_paste(d, clip, 10)
apply(d, plan)
check("paste: same row when free", plan.rows_after == 2 and d.amp[1][10] > 0 and d.frq[1][12] == 105 and d.amp[1][3] > 0)
check("paste: selection is the pasted cells", plan.sel[1][10] and plan.sel[1][12] and not plan.sel[1][3] and plan.count == 3 and plan.dropped == 0)
revert(d, plan)
check("paste: undo restores everything", snapshot(d) == before)
plan = edit.plan_paste(d, clip, 4)                                   -- frames 4-6 overlap the existing 4-5 in row 1
apply(d, plan)
check("paste on sound: the old sound is untouched", d.frq[1][4] == 104 and d.frq[1][5] == 105)
check("paste on sound: the copy goes to row 2", d.amp[2][4] > 0 and d.frq[2][4] == 103 and d.frq[2][6] == 105 and plan.sel[2])
d = make(1, 20); fill(d, 1, 3, 5, 100)
plan = edit.plan_paste(d, clip, 4)
apply(d, plan)
check("paste with no free row: a new row", plan.rows_after == 2 and d.partials == 2 and d.amp[2][4] > 0)
d = make(1, 12)
plan = edit.plan_paste(d, clip, 11)                                   -- frames 11, 12 fit; 13 is outside
check("paste past the end: the rest is dropped", plan and plan.count == 2 and plan.dropped == 1)
check("paste entirely outside: nothing", edit.plan_paste(d, clip, 40) == nil)
local gapclip = { { p = 5, df = 0, amp = 0.4, frq = 200 }, { p = 5, df = 3, amp = 0.4, frq = 210 } }   -- two runs of one row (and a row that does not exist)
d = make(2, 20)
plan = edit.plan_paste(d, gapclip, 1)
apply(d, plan)
check("paste: a source row beyond the file's rows lands in a row that exists", d.amp[2][1] > 0 and d.amp[2][4] > 0 and active(d) == 2)

-- 8. plan_warp: frequencies per point, time by making every run again on the frames
do
  local function ramp(d, p, f0, f1, a0, da, freq)                 -- amplitude a0, a0+da, ... ; frequency freq + 10*k
    for f = f0, f1 do d.amp[p][f] = a0 + (f - f0) * da; d.frq[p][f] = freq + 10 * (f - f0) end
  end
  local hop = 0.01
  local function selall(p, f0, f1) local t = {}; for f = f0, f1 do t[f] = true end; return { [p] = t } end
  -- identity: nothing changes
  local d8 = make(2, 40); ramp(d8, 1, 3, 7, 0.1, 0.1, 200)
  local plan8 = edit.plan_warp(d8, selall(1, 3, 7), function(t, fr) return t, fr end)
  check("warp: the identity changes nothing", plan8 and #plan8.changes == 0 and plan8.count == 5 and plan8.dropped == 0)
  -- frequencies only: doubled, same frames, same row
  plan8 = edit.plan_warp(d8, selall(1, 3, 7), function(t, fr) return t, fr * 2 end)
  check("warp: frequencies only: 5 changes in the same cells", #plan8.changes == 5 and plan8.sel[1][3] and plan8.sel[1][7] and plan8.rows_after == 2)
  local by = {}
  for _, c in ipairs(plan8.changes) do by[c.f] = c end
  check("warp: frequencies only: values", math.abs(by[3].nf - 400) < 1e-9 and math.abs(by[5].nf - 440) < 1e-9 and by[5].na == by[5].oa)
  -- later by 3 frames: the run is made 3 frames to the right
  plan8 = edit.plan_warp(d8, selall(1, 3, 7), function(t, fr) return t + 3 * hop, fr end)
  apply(d8, plan8)
  check("warp: later by 3 frames", d8.amp[1][3] == 0 and d8.amp[1][5] == 0 and math.abs(d8.amp[1][6] - 0.1) < 1e-9 and math.abs(d8.amp[1][10] - 0.5) < 1e-9 and d8.amp[1][11] == 0)
  check("warp: the selection follows", plan8.sel[1][6] and plan8.sel[1][10] and not plan8.sel[1][3])
  revert(d8, plan8)
  -- stretched to twice the length around the first point: 5 frames become 9, the new frames interpolate the points
  d8 = make(2, 60); ramp(d8, 1, 3, 7, 0.1, 0.1, 200)
  local t3 = d8.times[3]
  plan8 = edit.plan_warp(d8, selall(1, 3, 7), function(t, fr) return t3 + 2 * (t - t3), fr end)
  apply(d8, plan8)
  check("warp: stretched x2: 9 frames, 3 to 11", d8.amp[1][2] == 0 and d8.amp[1][3] > 0 and d8.amp[1][11] > 0 and d8.amp[1][12] == 0, d8.amp[1][11])
  check("warp: stretched x2: the frames between the points are interpolated", math.abs(d8.amp[1][4] - 0.15) < 1e-9 and math.abs(d8.frq[1][4] - 205) < 1e-9 and math.abs(d8.amp[1][5] - 0.2) < 1e-9)
  check("warp: stretched x2: the end keeps its value", math.abs(d8.amp[1][11] - 0.5) < 1e-9 and math.abs(d8.frq[1][11] - 240) < 1e-9)
  revert(d8, plan8)
  check("warp: stretched x2: undo", d8.amp[1][8] == 0 and math.abs(d8.amp[1][7] - 0.5) < 1e-9)
  -- squeezed to half: 9 frames become 5
  d8 = make(2, 60); ramp(d8, 1, 3, 11, 0.1, 0.05, 200)
  plan8 = edit.plan_warp(d8, selall(1, 3, 11), function(t, fr) return t3 + 0.5 * (t - t3), fr end)
  apply(d8, plan8)
  check("warp: squeezed to half: frames 3 to 7", d8.amp[1][3] > 0 and d8.amp[1][7] > 0 and d8.amp[1][8] == 0 and d8.amp[1][11] == 0)
  check("warp: squeezed to half: every second point", math.abs(d8.amp[1][5] - (0.1 + 2 * 0.1)) < 1e-9 and math.abs(d8.amp[1][7] - (0.1 + 4 * 0.1)) < 1e-9)
  -- a stretched run that meets other sound goes to another row, nothing is overwritten
  d8 = make(2, 60); ramp(d8, 1, 3, 7, 0.1, 0.1, 200); ramp(d8, 1, 10, 12, 0.9, 0, 900)
  plan8 = edit.plan_warp(d8, selall(1, 3, 7), function(t, fr) return t3 + 2 * (t - t3), fr end)
  apply(d8, plan8)
  check("warp: a stretch into other sound: the other sound stays", d8.amp[1][10] == 0.9 and d8.frq[1][12] == 920)
  check("warp: a stretch into other sound: the run is in row 2", d8.amp[2][3] > 0 and d8.amp[2][11] > 0 and plan8.sel[2] and not plan8.sel[1])
  -- beyond the end of the file: the frames after the last are dropped; a run that is wholly outside is a dropped run
  d8 = make(2, 20); ramp(d8, 1, 15, 19, 0.1, 0.1, 200)
  plan8 = edit.plan_warp(d8, selall(1, 15, 19), function(t, fr) return t + 3 * hop, fr end)
  apply(d8, plan8)
  check("warp: past the end: the cells that fit are kept", d8.amp[1][18] > 0 and d8.amp[1][20] > 0 and plan8.dropped == 0 and d8.amp[1][15] == 0)
  d8 = make(2, 20); ramp(d8, 1, 15, 19, 0.1, 0.1, 200)
  plan8 = edit.plan_warp(d8, selall(1, 15, 19), function(t, fr) return t + 30 * hop, fr end)
  check("warp: wholly past the end: dropped", plan8.dropped == 1 and #plan8.changes == 5 and next(plan8.sel) == nil)
  -- a single point goes to the nearest frame
  d8 = make(2, 40); d8.amp[1][10] = 0.7; d8.frq[1][10] = 300
  plan8 = edit.plan_warp(d8, selall(1, 10, 10), function(t, fr) return t + 2.4 * hop, fr end)
  apply(d8, plan8)
  check("warp: a single point: the nearest frame", d8.amp[1][10] == 0 and math.abs(d8.amp[1][12] - 0.7) < 1e-9)
  check("warp: nothing selected: nil", edit.plan_warp(d8, {}, function(t, fr) return t, fr end) == nil)
end

print(string.format("%d passed, %d failed", ok, fails))
os.exit(fails == 0 and 0 or 1)
