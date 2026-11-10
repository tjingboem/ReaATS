-- Run: lua5.4 tests/test_ats_edit.lua   (from the ReaATS folder)
package.path = "lib/?.lua;" .. package.path
local edit = require("ats_edit")
local warp = require("ats_warp")
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
  -- a stretched run that meets other sound goes to another row, nothing is overwritten. The other sound is placed so the stretched
  -- run's own new range (3 to 19, a x4 stretch from frame 3) genuinely reaches it -- a real collision, not just nearby -- while still
  -- starting well past plan_warp's own GAP_TOLERANCE (5 frames after the run's old end, frame 7) for "is this the same line
  -- continuing": a gap meant to read as a separate sound in a test has to be built clearly wider than that tolerance AND still within
  -- the stretch's own reach, not just barely nonzero somewhere -- see the comment above `ripple` in ats_edit.lua.
  d8 = make(2, 60); ramp(d8, 1, 3, 7, 0.1, 0.1, 200); ramp(d8, 1, 15, 17, 0.9, 0, 900)
  plan8 = edit.plan_warp(d8, selall(1, 3, 7), function(t, fr) return t3 + 4 * (t - t3), fr end)
  apply(d8, plan8)
  check("warp: a stretch into other sound: the other sound stays", d8.amp[1][15] == 0.9 and d8.frq[1][17] == 920)
  check("warp: a stretch into other sound: the run is in row 2", d8.amp[2][3] > 0 and d8.amp[2][19] > 0 and plan8.sel[2] and not plan8.sel[1])
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

-- 8b. plan_warp with a REAL (ats_warp) mapper, box t0/t1 exactly the extent of the selected frames (as ATS_Editor.lua's W.get must give
-- it -- it used to pad a narrow box out to a minimum size for grabbable dots, which left the box's u=0/u=1 short of the true first/last
-- selected frame; those frames then picked up a fractional, unintended displacement from the stretch, could land outside the destination
-- range plan_warp computes, and were silenced as source cells with nothing left to rewrite them: a real gap, right at the selection's own
-- edge. Fixed 10 Nov 2026 by keeping the box exact and moving the minimum size to screen pixels only (W.geo); this guards the invariant
-- plan_warp must hold for that fix to be correct: an exact box never drops a selected frame.
do
  local d8b = make(1, 40)
  for f = 5, 22 do d8b.amp[1][f] = 0.5; d8b.frq[1][f] = 300 + f * 5 end    -- nothing after frame 22: row 1 stays free for the stretch
  local f0, f1 = 18, 22
  local sel8b = { [1] = {} }
  for f = f0, f1 do sel8b[1][f] = true end
  local w = warp.new(d8b.times[f0], d8b.times[f1], 200, 600)              -- the box: exactly the selected frames' own time span
  warp.move_edge(w, "right", 0, 0.06)                                     -- a pure time stretch, right edge only (left stays put)
  local plan8b = edit.plan_warp(d8b, sel8b, warp.mapper(w))
  local covered = true
  for f = f0, f1 do if not plan8b.sel[1][f] then covered = false end end
  check("warp box exact: every originally selected frame is still covered after a stretch", covered,
    "sel after: " .. (function() local l = {}; for f in pairs(plan8b.sel[1]) do l[#l + 1] = f end; table.sort(l); return table.concat(l, ",") end)())
  check("warp box exact: the stretch still expands (more frames than were selected)", plan8b.frames_after - f0 + 1 >= f1 - f0 + 1)
end

-- 8c. a multi-row selection, one row with a brief (2-frame) tracking dip right at the old boundary, must still ripple on its OWN row
-- like its neighbours, not relocate -- found 10 Nov 2026 from a real screenshot ("still a gap" after 8b's fix): the first version of the
-- ripple-eligibility check required real data in the EXACT next frame, which a genuine, otherwise-continuous analysed line can fail by
-- one or two flat-zero frames; AND because every row of a multi-row selection treats every OTHER row's own selected cells as "free," a
-- relocated run can end up pushed past every other selected row too and land on a brand new one -- a whole partial vanishing, not just
-- its own row's content shifting. `looks_continuing` (GAP_TOLERANCE frames of lookahead) fixes the dip case; a gap wider than the
-- tolerance must still relocate, same as "stretch into other sound" above.
do
  local function five_rows(dip)
    local d = make(5, 60)
    for f = 1, 60 do for p = 1, 5 do d.amp[p][f] = 0.4 + p * 0.05; d.frq[p][f] = 200 * p + f * 2 end end
    if dip then for _, f in ipairs(dip) do d.amp[1][f] = 0 end end
    return d
  end
  local f0, f1 = 18, 22
  local sel = {}
  for p = 1, 5 do sel[p] = {}; for f = f0, f1 do sel[p][f] = true end end
  local function stretch_all(d)
    local w = warp.new(d.times[f0], d.times[f1], 100, 2000)
    warp.move_edge(w, "right", 0, 0.06)
    return edit.plan_warp(d, sel, warp.mapper(w), { max_extra = 20 })
  end
  -- a 2-frame dip, well inside GAP_TOLERANCE: row 1 ripples in place like every other row
  local dn = five_rows({ 23, 24 })
  local pn = stretch_all(dn)
  check("warp ripple: a brief dip in one row of a multi-row selection does not eject it to a new row",
    pn.sel[1] ~= nil and pn.sel[6] == nil, "rows used: " .. (function() local l = {}; for p in pairs(pn.sel) do l[#l + 1] = p end; table.sort(l); return table.concat(l, ",") end)())
  check("warp ripple: all five rows stay on their own row", pn.sel[1] and pn.sel[2] and pn.sel[3] and pn.sel[4] and pn.sel[5] and not pn.sel[6])
  -- a gap wider than GAP_TOLERANCE: silent for exactly the 5-frame lookahead (23..27, right after the run's old end at 22), with
  -- real data again at 28 -- within the stretch's own reach (its new range extends past 28), so row 1 genuinely collides there and
  -- must relocate, same as the "other sound" case, rather than this just coincidentally having nothing in the way at all.
  local gap = { 23, 24, 25, 26, 27 }
  local dg = five_rows(gap)
  local pg = stretch_all(dg)
  check("warp ripple: a gap wider than the tolerance still relocates, not rippled through",
    pg.sel[1] == nil and pg.sel[6] ~= nil, "rows used: " .. (function() local l = {}; for p in pairs(pg.sel) do l[#l + 1] = p end; table.sort(l); return table.concat(l, ",") end)())
end

-- 9. the length of the file: frames added and taken away; a warp that may grow the file
do
  local d9 = make(2, 20); d9.dur = 0.2; d9.frame_size = 441; d9.sr = 44100
  d9.has_noise = true; d9.noise = {}; for b = 1, 25 do d9.noise[b] = {}; for f = 1, 20 do d9.noise[b][f] = 0.1 end end
  d9.has_phase = true; d9.pha = { {}, {} }; for p = 1, 2 do for f = 1, 20 do d9.pha[p][f] = 0.5 end end
  edit.add_frames(d9, 5)
  check("add_frames: 25 frames, longer duration", d9.frames == 25 and math.abs(d9.dur - 0.25) < 1e-9 and math.abs(d9.times[25] - 0.24) < 1e-9, d9.dur)
  check("add_frames: silent amplitude, frequency, phase and noise", d9.amp[2][25] == 0 and d9.frq[1][21] == 0 and d9.pha[1][23] == 0 and d9.noise[10][25] == 0 and d9.noise[10][20] == 0.1)
  edit.truncate_frames(d9, 20, 0.2)
  check("truncate_frames: back to 20 frames", d9.frames == 20 and d9.dur == 0.2 and d9.times[21] == nil and d9.amp[1][21] == nil and d9.noise[3][21] == nil and d9.pha[2][21] == nil)
  -- a stretch that runs past the end: without room it is clipped, with room the file grows by exactly what is needed
  local d10 = make(2, 20); d10.frame_size = 441; d10.dur = 0.2
  for f = 15, 19 do d10.amp[1][f] = 0.1 * (f - 14); d10.frq[1][f] = 200 + 10 * (f - 15) end
  local t15 = d10.times[15]
  local function stretch(t, fr) return t15 + 2 * (t - t15), fr end
  local sel10 = { [1] = { [15] = true, [16] = true, [17] = true, [18] = true, [19] = true } }
  local clipped = edit.plan_warp(d10, sel10, stretch)
  check("grow: without room: clipped at frame 20", clipped.frames_after == 20 and clipped.sel[1][20] and not clipped.sel[1][21])
  local grown = edit.plan_warp(d10, sel10, stretch, { max_extra = 20 })
  check("grow: with room: frames up to 23 (15 + 8)", grown.frames_after == 23 and grown.sel[1][23] and grown.frames_before == 20, grown.frames_after)
  check("grow: the rows stay", grown.rows_after == 2 and grown.sel[1][21] and grown.sel[1][22])
  edit.add_frames(d10, grown.frames_after - d10.frames)
  apply(d10, grown)
  check("grow: the new frames hold the stretched sound", math.abs(d10.amp[1][23] - 0.5) < 1e-9 and math.abs(d10.frq[1][23] - 240) < 1e-9 and d10.frames == 23)
  check("grow: interpolated between the points", math.abs(d10.amp[1][16] - 0.15) < 1e-9 and math.abs(d10.amp[1][20] - 0.35) < 1e-9)
  -- a run wholly beyond the room that is allowed still falls away
  local far = edit.plan_warp(d10, { [1] = { [20] = true } }, function(t, fr) return t + 500 * 0.01, fr end, { max_extra = 5 })
  check("grow: beyond the room: dropped", far.dropped == 1 and far.frames_after == 23)
end

-- 10. the length of the file at the START: frames in front, everything later; a warp that goes before 0
do
  local d = make(2, 20); d.frame_size = 441; d.dur = 0.2
  d.has_noise = true; d.noise = {}; for b = 1, 25 do d.noise[b] = {}; for f = 1, 20 do d.noise[b][f] = f end end
  d.has_phase = true; d.pha = { {}, {} }; for p = 1, 2 do for f = 1, 20 do d.pha[p][f] = f / 10 end end
  for f = 5, 9 do d.amp[1][f] = 0.1 * (f - 4); d.frq[1][f] = 100 + f end
  edit.prepend_frames(d, 6)
  check("prepend: 26 frames, longer duration, times from the same start", d.frames == 26 and math.abs(d.dur - 0.26) < 1e-9 and d.times[1] == 0 and math.abs(d.times[26] - 0.25) < 1e-9)
  check("prepend: everything moved 6 frames later", d.amp[1][5] == 0 and d.amp[1][11] > 0 and math.abs(d.amp[1][11] - 0.1) < 1e-9 and d.frq[1][15] == 109 and d.amp[2][1] == 0)
  check("prepend: noise and phase moved too, the new frames are silent", d.noise[3][1] == 0 and d.noise[3][7] == 1 and d.noise[3][26] == 20 and d.pha[2][7] == 0.1 and d.pha[1][3] == 0)
  check("prepend: counted", d.front_frames == 6)
  edit.drop_front(d, 6, 0.2)
  check("drop_front: back as it was", d.frames == 20 and d.dur == 0.2 and d.amp[1][5] > 0 and math.abs(d.amp[1][9] - 0.5) < 1e-9 and d.amp[1][21] == nil and d.noise[3][20] == 20 and d.pha[1][20] == 2 and d.times[21] == nil and d.front_frames == 0)
  -- a stretch to the left, past the start: with room in front the pieces go to frames 0, -1 ... (frames_front says how many)
  local dw = make(2, 20); dw.frame_size = 441; dw.dur = 0.2
  for f = 3, 7 do dw.amp[1][f] = 0.1 * (f - 2); dw.frq[1][f] = 200 + 10 * (f - 3) end
  local t7 = dw.times[7]
  local function stretch_left(t, fr) return t7 - 2 * (t7 - t), fr end                  -- twice as long, the right end stays
  local sel = { [1] = { [3] = true, [4] = true, [5] = true, [6] = true, [7] = true } }
  local clipped = edit.plan_warp(dw, sel, stretch_left)
  check("front: without room: clipped at frame 1", clipped.frames_front == 0 and clipped.sel[1][1] and not clipped.sel[1][0])
  local grown = edit.plan_warp(dw, sel, stretch_left, { max_front = 20 })
  check("front: with room: down to frame -1 (7 - 8), 2 frames in front", grown.frames_front == 2 and grown.sel[1][-1] and grown.sel[1][0] and grown.frames_after == 20, grown.frames_front)
  check("front: the amplitudes at both ends", true)
  local first_amp
  for _, c in ipairs(grown.changes) do if c.f == -1 then first_amp = c.na end end
  check("front: the first frame holds the start of the stretched run (the amplitude of its first point)", first_amp and math.abs(first_amp - 0.1) < 1e-9, first_amp)
  check("front: wholly before the room: dropped", edit.plan_warp(dw, { [1] = { [3] = true } }, function(t, fr) return t - 500 * 0.01, fr end, { max_front = 5 }).dropped == 1)
end

-- 11. the noise bands follow the sines
do
  local function noisy(frames)
    local d = make(2, frames); d.frame_size = 441; d.dur = frames * 0.01
    d.has_noise = true; d.noise = {}
    for b = 1, 25 do d.noise[b] = {}; for f = 1, frames do d.noise[b][f] = 0 end end
    return d
  end
  -- which bands: more than half of the band inside the range
  local list = edit.noise_bands(300, 1000, 22050)                   -- bands 4 (300-400) .. 8 (770-920), band 9 (920-1080) has 80/160 inside: not more than half
  check("noise_bands: 300-1000 Hz", #list == 5 and list[1] == 4 and list[5] == 8, #list)
  check("noise_bands: a single partial has no bands", #edit.noise_bands(440, 440, 22050) == 0)
  check("noise_bands: a range that holds only a quarter of a band", #edit.noise_bands(100, 125, 22050) == 0)
  check("noise_bands: the whole range", #edit.noise_bands(0, 30000, 22050) == 25 - 1 or #edit.noise_bands(0, 30000, 22050) == 25)
  local d = noisy(40)
  for b = 4, 8 do for f = 10, 14 do d.noise[b][f] = 1 + b + 0.1 * f end end
  d.noise[6][20] = 5                                                -- other noise, outside the region, where the moved noise will land
  local region = { t0 = d.times[10], t1 = d.times[14], f0 = 300, f1 = 1000 }
  local mv = edit.plan_noise_move(d, region, 10)
  check("noise move: the bands in the region, the frames 10-14", mv and #mv.bands == 5)
  local got = {}
  for _, c in ipairs(mv.changes) do got[c.b .. "/" .. c.f] = c end
  check("noise move: the old place is silent", got["4/10"] and got["4/10"].new == 0 and got["8/14"].new == 0)
  check("noise move: the new place has the energy", math.abs(got["4/20"].new - (1 + 4 + 1.0)) < 1e-9 and math.abs(got["8/24"].new - (1 + 8 + 1.4)) < 1e-9)
  check("noise move: added to the noise that was there (nothing is written over)", math.abs(got["6/20"].new - (5 + 1 + 6 + 1.0)) < 1e-9, got["6/20"] and got["6/20"].new)
  check("noise move: other bands are not touched", got["3/10"] == nil and got["9/20"] == nil)
  check("noise move: past the end the cells are left out", #(edit.plan_noise_move(d, region, 28).changes) > 0 and edit.plan_noise_move(d, region, 100) ~= nil)
  -- clear (cut)
  local cl = edit.plan_noise_clear(d, region)
  check("noise clear: every cell of the region", #cl.changes == 25 and cl.changes[1].new == 0)
  -- copy and paste
  local piece = edit.noise_piece(d, region, 8)                       -- the reference frame 8: the piece starts 2 frames after it
  check("noise piece: relative start and length", piece.rel == 2 and piece.n == 5 and #piece.bands[4] == 5 and math.abs(piece.bands[4][1] - 6.0) < 1e-9)
  local pp = edit.plan_noise_paste(d, piece, 20)                     -- reference at frame 20: the noise at frames 22-26
  local pg = {}
  for _, c in ipairs(pp.changes) do pg[c.b .. "/" .. c.f] = c end
  check("noise paste: added at the new place, the source untouched", math.abs(pg["4/22"].new - 6.0) < 1e-9 and pg["4/10"] == nil and math.abs(pg["8/26"].new - 10.4) < 1e-9)
  -- warp: stretched to twice the length around the first frame: 5 frames become 9
  local t10 = d.times[10]
  local wp = edit.plan_noise_warp(d, region, function(t, fr) return t10 + 2 * (t - t10), fr end)
  local wg = {}
  for _, c in ipairs(wp.changes) do wg[c.b .. "/" .. c.f] = c end
  check("noise warp: stretched x2: frames 11-18 changed (frame 10 keeps its value), nothing after 18", wg["4/11"] and wg["4/18"] and wg["4/19"] == nil)
  check("noise warp: the new frames are interpolated", math.abs(wg["4/11"].new - (6.0 + 6.1) / 2) < 1e-9 and math.abs(wg["4/18"].new - 6.4) < 1e-9)
  local wp2 = edit.plan_noise_warp(d, region, function(t, fr) return t + 100, fr end)
  check("noise warp: far past the end with no room: nothing lands, the old place is silent", #wp2.changes == 25)
  local wp3 = edit.plan_noise_warp(d, region, function(t, fr) return t + 0.45, fr end, { max_extra = 20 })
  check("noise warp: with room the file may grow", wp3.frames_after == 59 and wp3.frames_front == 0, wp3.frames_after)
  check("no noise: nothing", edit.plan_noise_move(make(2, 10), region, 3) == nil and edit.plan_noise_clear(make(2, 10), region) == nil)
end

-- 12. the max-partials knob: rank_partials finds every run (a shared row can hold more than one), plan_keep_loudest silences the rest
do
  -- three rows, three different loudnesses, plus a second, separate run sharing row 2's own row (pack_rows) much later
  local d = make(3, 60)
  fill(d, 1, 1, 10, 200, 0.9)                -- 10 frames at 0.9 = 9.0 energy (loudest)
  fill(d, 2, 1, 10, 300, 0.2)                -- 10 frames at 0.2 = 2.0 energy (quietest of the first three)
  fill(d, 2, 41, 45, 300, 0.5)               -- a second, unrelated run sharing row 2: 5 frames at 0.5 = 2.5 energy
  fill(d, 3, 1, 10, 400, 0.5)                -- 10 frames at 0.5 = 5.0 energy
  local runs = edit.rank_partials(d, nil)
  check("rank_partials: a shared row's two separate runs are two entries, not one", #runs == 4, #runs)
  check("rank_partials: sorted loudest first", runs[1].p == 1 and math.abs(runs[1].energy - 9.0) < 1e-9
        and runs[2].p == 3 and math.abs(runs[2].energy - 5.0) < 1e-9
        and runs[3].p == 2 and math.abs(runs[3].energy - 2.5) < 1e-9
        and runs[4].p == 2 and math.abs(runs[4].energy - 2.0) < 1e-9,
        table.concat((function() local t={} for _,r in ipairs(runs) do t[#t+1]=r.p.."@"..r.f0..":"..r.energy end return t end)(), " "))

  local plan = edit.plan_keep_loudest(d, runs, 2)
  check("plan_keep_loudest: keeps 2, drops the other 2", plan.kept == 2 and plan.dropped == 2)
  local touched = {}
  for _, c in ipairs(plan.changes) do touched[c.p .. "@" .. c.f] = c.na end
  check("plan_keep_loudest: the 2 loudest runs are untouched", touched["1@1"] == nil and touched["3@1"] == nil)
  check("plan_keep_loudest: the quieter run of row 2 and its other run are both silenced",
        touched["2@1"] == 0 and touched["2@41"] == 0 and touched["2@10"] == 0 and touched["2@45"] == 0)

  check("plan_keep_loudest: n >= every run silences nothing", edit.plan_keep_loudest(d, runs, 10) == nil)
  local none = edit.plan_keep_loudest(d, runs, 0)
  check("plan_keep_loudest: n = 0 silences every run", none.kept == 0 and none.dropped == 4 and #none.changes == 10 + 10 + 5 + 10)

  -- a region keeps only the runs that enter its time AND frequency range -- others are never even candidates, whatever n is
  local region = { t0 = 0, t1 = 0.1, f0 = 150, f1 = 250 }                 -- only row 1 (200 Hz, frames 1-10) is inside
  local in_region = edit.rank_partials(d, region)
  check("rank_partials: a region keeps only the runs that actually enter it", #in_region == 1 and in_region[1].p == 1, #in_region)
  check("plan_keep_loudest: with n = 0 on a region, only what is IN the region can be silenced", edit.plan_keep_loudest(d, in_region, 0).dropped == 1)

  check("rank_partials: an empty file has nothing to rank", #edit.rank_partials(make(2, 10), nil) == 0)
end

print(string.format("%d passed, %d failed", ok, fails))
os.exit(fails == 0 and 0 or 1)
