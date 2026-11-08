-- Run: lua5.4 tests/test_ats_file.lua   (from the ATSEditor folder)
-- Checks the reader against the values the Python tool printed for examples/sax.ats.
package.path = "lib/?.lua;" .. package.path
local ats = require("ats_file")
local ok, fails = 0, 0
local function check(name, cond, extra)
  if cond then ok = ok + 1 else fails = fails + 1; print("FAIL: " .. name .. " " .. tostring(extra or "")) end
end
local d, err = ats.load("examples/sax.ats")
check("loads", d ~= nil, err)
check("header partials", d.partials == 69, d.partials)
check("header frames", d.frames == 219, d.frames)
check("type 4", d.type == 4 and d.has_phase and d.has_noise)
check("sr", d.sr == 44100)
check("dur", math.abs(d.dur - 2.172562358) < 1e-6, d.dur)
check("times start at 0", math.abs(d.times[1]) < 1e-9, d.times[1])
check("times increase", d.times[219] > d.times[2])
check("last time within dur", d.times[219] <= d.dur + 0.02, d.times[219])
local maxa = 0
for p = 1, d.partials do for f = 1, d.frames do if d.amp[p][f] > maxa then maxa = d.amp[p][f] end end end
check("ampmax equals header", math.abs(maxa - d.ampmax) < 1e-9, maxa .. " vs " .. d.ampmax)
local maxf = 0
for p = 1, d.partials do for f = 1, d.frames do
  if d.amp[p][f] > 0 and d.frq[p][f] > maxf then maxf = d.frq[p][f] end end end
check("frqmax plausible", maxf <= d.frqmax + 1e-6, maxf .. " vs " .. d.frqmax)
check("frame 101 (Python index 100) time", math.abs(d.times[101] - 1.0) < 1e-6, d.times[101])
check("frame 101 (Python index 100) partial 1 amp", math.abs(d.amp[1][101] - 0.303241) < 1e-6, d.amp[1][101])
check("frame 101 (Python index 100) partial 1 freq", math.abs(d.frq[1][101] - 262.0126) < 1e-3, d.frq[1][101])
check("frame 101 (Python index 100) partial 1 phase", math.abs(d.pha[1][101] - 1.5441) < 1e-3, d.pha[1][101])
check("frame 101 (Python index 100) noise 1", math.abs(d.noise[1][101] - 0.000271245) < 1e-8, d.noise[1][101])
check("25 noise bands", #d.noise == 25 and #d.noise[1] == 219)
check("noise max positive", d.noise_max > 0)
check("note A4", ats.note_name(440) == "A4", ats.note_name(440))
check("note C4", ats.note_name(261.6256) == "C4", ats.note_name(261.6256))
local bad, e2 = ats.load("tests/test_ats_file.lua")
check("rejects a non-ATS file", bad == nil and e2 ~= nil, e2)
local f = io.open("/tmp/claude-1000/-home-tjingboem/6ca29d3f-340f-46ca-9b11-e579b6c375ee/scratchpad/short.ats", "wb"); f:write(string.rep("x", 100)); f:close()
local bad2, e3 = ats.load("/tmp/claude-1000/-home-tjingboem/6ca29d3f-340f-46ca-9b11-e579b6c375ee/scratchpad/short.ats")
check("rejects junk", bad2 == nil, e3)
-- round trips through save()
local tmp = "/tmp/claude-1000/-home-tjingboem/6ca29d3f-340f-46ca-9b11-e579b6c375ee/scratchpad/roundtrip.ats"
local function same(a, b, label)
  check(label .. " header", a.partials == b.partials and a.frames == b.frames and a.sr == b.sr and a.dur == b.dur)
  local worst = 0
  for p = 1, a.partials do for f = 1, a.frames do
    worst = math.max(worst, math.abs(a.amp[p][f] - b.amp[p][f]), math.abs(a.frq[p][f] - b.frq[p][f]))
  end end
  check(label .. " amp/freq identical", worst == 0, worst)
  local nw = 0
  for b_ = 1, 25 do for f = 1, a.frames do nw = math.max(nw, math.abs(a.noise[b_][f] - b.noise[b_][f])) end end
  check(label .. " noise identical", nw == 0, nw)
end
check("save type 4", ats.save(tmp, d, { phase = true }))
local r4 = ats.load(tmp)
check("reload type 4", r4 and r4.type == 4 and r4.has_phase)
same(d, r4, "type 4")
check("phase kept", r4.pha[1][101] == d.pha[1][101])
check("save type 3 (default)", ats.save(tmp, d))
local r3 = ats.load(tmp)
check("reload type 3", r3 and r3.type == 3 and not r3.has_phase and r3.has_noise)
same(d, r3, "type 3")
-- edited data: header maxima follow the data
local saved_amp = d.amp[1][101]
d.amp[1][101] = 0
ats.save(tmp, d)
local r5 = ats.load(tmp)
check("edit survives", r5.amp[1][101] == 0)
check("ampmax recomputed", r5.ampmax <= d.ampmax + 1e-12)
d.amp[1][101] = saved_amp
print(string.format("%d passed, %d failed", ok, fails))
os.exit(fails == 0 and 0 or 1)
