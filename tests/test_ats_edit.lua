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

print(string.format("%d passed, %d failed", ok, fails))
os.exit(fails == 0 and 0 or 1)
