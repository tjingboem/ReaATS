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
-- update_phases: edited runs get phases that follow the frequencies, untouched ones keep theirs
do
  local pi2 = 2 * math.pi
  local function wrap(x) return (x + math.pi) % pi2 - math.pi end
  local function rule_error(dd, p, f0, f1)                  -- largest deviation from the phase rule inside a run
    local worst = 0
    for f = f0 + 1, f1 do
      local pred = (dd.frq[p][f - 1] + dd.frq[p][f]) * math.pi * dd.frame_size / dd.sr
      worst = math.max(worst, math.abs(wrap(dd.pha[p][f] - dd.pha[p][f - 1] - pred)))
    end
    return worst
  end
  local e = assert(ats.load("examples/sax.ats"))
  -- find a long run in partial 1 (the fundamental)
  local f0, f1 = nil, nil
  for f = 1, e.frames do
    if e.amp[1][f] > 0 then f0 = f0 or f; f1 = f elseif f0 and f1 - f0 > 40 then break elseif f0 then f0, f1 = nil, nil end
  end
  check("found a long run to edit", f0 and f1 - f0 > 40, tostring(f0) .. "-" .. tostring(f1))
  local before = {}
  for p = 1, e.partials do before[p] = {}; for f = 1, e.frames do before[p][f] = e.pha[p][f] end end
  ats.update_phases(e, {})
  local same = true
  for p = 1, e.partials do for f = 1, e.frames do if e.pha[p][f] ~= before[p][f] then same = false end end end
  check("nothing edited: every phase kept", same)
  for f = f0, f1 do e.frq[1][f] = e.frq[1][f] * 2 end           -- transpose the run an octave up
  local dirty = { [1] = {} }
  for f = f0 + 5, f0 + 8 do dirty[1][f] = true end              -- only a few cells are marked: the whole run is rebuilt
  ats.update_phases(e, dirty)
  check("edited run follows the phase rule", rule_error(e, 1, f0, f1) < 1e-9, rule_error(e, 1, f0, f1))
  check("edited run keeps its first phase", e.pha[1][f0] == before[1][f0])
  local rest = true
  for p = 2, e.partials do for f = 1, e.frames do if e.pha[p][f] ~= before[p][f] then rest = false end end end
  check("other partials untouched", rest)
  check("save with phase", ats.save(tmp, e, { phase = true }))
  local r = ats.load(tmp)
  check("reloads as type 4", r and r.type == 4 and r.has_phase)
  check("the rule still holds after the round trip", rule_error(r, 1, f0, f1) < 1e-9)
  -- data without phase (type 3): phases are built for every run, the file becomes type 4
  local n3 = assert(ats.load(tmp)); n3.has_phase = false; n3.pha = nil
  ats.update_phases(n3, nil)
  check("phases created for a file without phase", n3.has_phase and #n3.pha == n3.partials)
  check("created phases follow the rule", rule_error(n3, 1, f0, f1) < 1e-9)
  check("created phases start at 0", math.abs(n3.pha[1][f0]) < 1e-12)
end
-- header(): the header and the size, without loading the data
do
  local h = assert(ats.header("examples/sax.ats"))
  local d = assert(ats.load("examples/sax.ats"))
  check("header: same numbers as load", h.partials == d.partials and h.frames == d.frames and h.type == d.type and h.sr == d.sr
        and h.dur == d.dur and h.has_noise == d.has_noise and h.has_phase == d.has_phase)
  local fh = io.open("examples/sax.ats", "rb"); local size = #fh:read("a"); fh:close()
  check("header: file size", h.bytes == size)
  local cut = os.tmpname()
  local fh2 = io.open("examples/sax.ats", "rb"); local all = fh2:read("a"); fh2:close()
  local out = io.open(cut, "wb"); out:write(all:sub(1, #all - 100)); out:close()
  local hh, err = ats.header(cut)
  check("header: a file that is too short is refused", hh == nil and err:find("smaller"), err)
  check("load: and so is loading it", ats.load(cut) == nil)
  os.remove(cut)
  check("header: a missing file", ats.header("/nonexistent.ats") == nil)
  local empty = os.tmpname()
  local h0, e0 = ats.header(empty)
  check("header: an empty file is called empty", h0 == nil and e0:find("empty"), e0)
  os.remove(empty)
end
-- a file made longer (frames added by an edit) is saved and read back as it is
do
  local ed = dofile("lib/ats_edit.lua")
  local d = assert(ats.load("examples/sax.ats"))
  local frames, dur = d.frames, d.dur
  ed.add_frames(d, 20)
  d.amp[1][frames + 5] = 0.3; d.frq[1][frames + 5] = 440
  local path = os.tmpname()
  assert(ats.save(path, d, { phase = true }))
  local r = assert(ats.load(path))
  check("longer file: frames and duration are saved", r.frames == frames + 20 and math.abs(r.dur - (dur + 20 * d.frame_size / d.sr)) < 1e-9, r.frames)
  check("longer file: the new frames are read back", r.amp[1][frames + 5] == 0.3 and r.frq[1][frames + 5] == 440 and r.amp[1][frames + 6] == 0 and r.noise[7][frames + 20] == 0)
  check("longer file: the times go on with the same spacing", math.abs(r.times[frames + 20] - (r.times[frames] + 20 * d.frame_size / d.sr)) < 1e-9)
  os.remove(path)
end
print(string.format("%d passed, %d failed", ok, fails))
os.exit(fails == 0 and 0 or 1)
