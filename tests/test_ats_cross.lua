-- Run: lua5.4 tests/test_ats_cross.lua   (from the ReaATS folder)
package.path = "lib/?.lua;" .. package.path
local cross = require("ats_cross")
local ats = require("ats_file")
local synth = require("ats_synth")
local ok, fails = 0, 0
local function check(name, cond, extra)
  if cond then ok = ok + 1 else fails = fails + 1; print("FAIL: " .. name .. " " .. tostring(extra or "")) end
end
-- a sound: `parts` = { {freq, amp} ... } steady for `dur` seconds at hop `hop`; optional noise energy
local function sound(parts, dur, hop, noise, window)
  local NF = math.floor(dur / hop + 1e-9) + 1
  local d = { sr = 44100, frame_size = math.floor(hop * 44100 + 0.5), window_size = window or 1764, partials = #parts, frames = NF, dur = dur,
              has_phase = false, has_noise = noise ~= nil, amp = {}, frq = {}, times = {}, noise_max = 0 }
  for f = 1, NF do d.times[f] = (f - 1) * d.frame_size / 44100 end
  for p, pr in ipairs(parts) do d.amp[p], d.frq[p] = {}, {}; for f = 1, NF do d.amp[p][f], d.frq[p][f] = pr[2], pr[1] end end
  if noise then d.noise = {}; for b = 1, 25 do d.noise[b] = {}; for f = 1, NF do d.noise[b][f] = noise end end end
  return d
end
local function at(d, p, t) return d.amp[p][math.floor(t / (d.frame_size / d.sr) + 0.5) + 1], d.frq[p][math.floor(t / (d.frame_size / d.sr) + 0.5) + 1] end
local function rows_at(d, t)            -- every sounding row at time t: { {amp, frq} ... } sorted by frequency
  local fi = math.floor(t / (d.frame_size / d.sr) + 0.5) + 1
  local out = {}
  for p = 1, d.partials do if d.amp[p][fi] > 0 then out[#out + 1] = { d.amp[p][fi], d.frq[p][fi] } end end
  table.sort(out, function(a, b) return a[2] < b[2] end)
  return out
end
local HOP = 0.01

-- A: 200 and 400 Hz for 2 s from 0; B: 205 and 800 Hz for 2 s from 1.0; the line at 1.5, the grey area 0.4 s wide (1.3 .. 1.7)
do
  local A = sound({ { 200, 0.5 }, { 400, 0.5 } }, 2.0, HOP)
  local B = sound({ { 205, 0.5 }, { 800, 0.5 } }, 2.0, HOP)
  local d, info = cross.build({ a = { d = A, pos = 0 }, b = { d = B, pos = 1.0 }, line = 1.5, tol_time = 0.4, tol_cents = 100 })
  check("the result is as long as both together (3 s)", math.abs(d.dur - 3.0) < 1e-9 and d.frames == 301, d.frames)
  check("one pair (200 -> 205 Hz is 43 cents)", info.pairs == 1, info.pairs)
  check("the line is told in the result's time", math.abs(info.line - 1.5) < 1e-9 and math.abs(info.grey0 - 1.3) < 1e-9 and math.abs(info.grey1 - 1.7) < 1e-9)
  local r = rows_at(d, 0.5)
  check("before the grey area: A as it was", #r == 2 and r[1][2] == 200 and r[2][2] == 400 and math.abs(r[1][1] - 0.5) < 1e-9, #r)
  r = rows_at(d, 2.5)
  check("after the grey area: B as it is, on its own frequencies (205 and 800)", #r == 2 and r[1][2] == 205 and r[2][2] == 800 and math.abs(r[1][1] - 0.5) < 1e-9, #r)
  r = rows_at(d, 1.5)
  local thread
  for _, x in ipairs(r) do if x[2] > 190 and x[2] < 210 then thread = x end end
  check("in the middle the thread is half way in semitones (202.49 Hz)", thread and math.abs(thread[2] - 200 * (205 / 200) ^ 0.5) < 0.01, thread and thread[2])
  check("and its level is linear (0.5 stays 0.5: not louder)", thread and math.abs(thread[1] - 0.5) < 1e-9)
  -- the thread is ONE continuous track: one row sounds at 200 Hz at 1.2 s and at 205 Hz at 1.8 s, without a gap in between
  local row
  for p = 1, d.partials do
    local fi = math.floor(1.2 / HOP + 0.5) + 1
    if d.frq[p][fi] == 200 then row = p end
  end
  local gap = false
  if row then for f = math.floor(1.2 / HOP + 0.5) + 1, math.floor(1.8 / HOP + 0.5) + 1 do if d.amp[row][f] <= 0 then gap = true end end end
  check("the thread is one continuous track on one row", row and not gap and math.abs(d.frq[row][math.floor(1.8 / HOP + 0.5) + 1] - 205) < 1e-9)
  -- unpaired partials fade with equal-power weights
  local a400 = nil
  for _, x in ipairs(rows_at(d, 1.5)) do if x[2] == 400 then a400 = x[1] end end
  check("the unpaired A partial (400 Hz) is at cos(pi/4) of its level in the middle", a400 and math.abs(a400 - 0.5 * math.cos(math.pi / 4)) < 1e-6, a400)
  check("and is gone after the grey area", #rows_at(d, 1.75) == 2 and rows_at(d, 1.75)[1][2] > 200)
  local a800 = nil
  for _, x in ipairs(rows_at(d, 1.5)) do if x[2] == 800 then a800 = x[1] end end
  check("the unpaired B partial (800 Hz) is at sin(pi/4) in the middle", a800 and math.abs(a800 - 0.5 * math.sin(math.pi / 4)) < 1e-6, a800)
  check("and absent before the grey area (1.0 s: only A's two)", #rows_at(d, 1.1) == 2)
  check("rows are shared: few rows", d.partials <= 4, d.partials)
  check("type 4 after the phases", d.has_phase and d.pha[1][1] ~= nil)
end

-- a partial that has no partner: tolerance 20 cents: 200 -> 205 (43 cents) is no pair any more: both fade on their own frequencies
do
  local A = sound({ { 200, 0.5 } }, 2.0, HOP); local B = sound({ { 205, 0.5 } }, 2.0, HOP)
  local d, info = cross.build({ a = { d = A, pos = 0 }, b = { d = B, pos = 1.0 }, line = 1.5, tol_time = 0.4, tol_cents = 20 })
  check("tolerance 20 cents: no pair", info.pairs == 0)
  local r = rows_at(d, 1.5)
  check("two partials in the middle, each at cos / sin of pi/4", #r == 2 and math.abs(r[1][1] - 0.5 * math.cos(math.pi / 4)) < 1e-6 and r[1][2] == 200 and r[2][2] == 205)
end

-- a hard line (no tolerance): a cut at the line
do
  local A = sound({ { 200, 0.5 } }, 2.0, HOP); local B = sound({ { 205, 0.5 } }, 2.0, HOP)
  local d, info = cross.build({ a = { d = A, pos = 0 }, b = { d = B, pos = 1.0 }, line = 1.5, tol_time = 0, tol_cents = 100 })
  check("a hard line makes no threads", info.pairs == 0)
  local r1, r2 = rows_at(d, 1.4), rows_at(d, 1.6)
  check("before the line A, after it B", #r1 == 1 and r1[1][2] == 200 and #r2 == 1 and r2[1][2] == 205)
end

-- no overlap: A and then B, nothing is faded
do
  local A = sound({ { 200, 0.5 } }, 1.0, HOP); local B = sound({ { 300, 0.4 } }, 1.0, HOP)
  local d, info = cross.build({ a = { d = A, pos = 0 }, b = { d = B, pos = 1.5 }, line = 1.0, tol_time = 0.2, tol_cents = 100 })
  check("no overlap: no pairs, no line", info.pairs == 0 and not info.overlap)
  local r1, r2 = rows_at(d, 0.5), rows_at(d, 2.0)
  check("A at its own level, then B at its own", #r1 == 1 and math.abs(r1[1][1] - 0.5) < 1e-9 and #r2 == 1 and math.abs(r2[1][1] - 0.4) < 1e-9 and r2[1][2] == 300)
  check("a gap between them", #rows_at(d, 1.25) == 0)
end

-- the order is swapped: B comes first, A flows in
do
  local A = sound({ { 200, 0.5 } }, 2.0, HOP); local B = sound({ { 300, 0.5 } }, 2.0, HOP)
  local d = cross.build({ a = { d = A, pos = 1.0 }, b = { d = B, pos = 0 }, line = 1.5, tol_time = 0.2, tol_cents = 20 })
  local r1, r2 = rows_at(d, 0.5), rows_at(d, 2.5)
  check("B (the earlier one) is heard first, A after the line", r1[1][2] == 300 and r2[1][2] == 200)
end

-- cuts: only the used part: A is cut to 0.5 .. 1.5 s
do
  local A = sound({ { 200, 0.5 } }, 2.0, HOP); local B = sound({ { 300, 0.5 } }, 1.0, HOP)
  local d = cross.build({ a = { d = A, t0 = 0.5, t1 = 1.5, pos = 0 }, b = { d = B, pos = 2.0 }, line = 0, tol_time = 0 })
  check("the result is 3 s: 1 s of A, a gap, 1 s of B", math.abs(d.dur - 3.0) < 1e-9, d.dur)
  check("A sounds from 0 to 1 s only", #rows_at(d, 0.5) == 1 and #rows_at(d, 1.2) == 0)
end

-- different hops: A at 10 ms, B at 20 ms: the result has the smaller hop and B keeps its level
do
  local A = sound({ { 200, 0.5 } }, 2.0, 0.01); local B = sound({ { 300, 0.5 } }, 2.0, 0.02)
  local d = cross.build({ a = { d = A, pos = 0 }, b = { d = B, pos = 1.0 }, line = 1.5, tol_time = 0.2, tol_cents = 20 })
  check("the smaller hop is used", math.abs(d.frame_size / d.sr - 0.01) < 1e-6, d.frame_size)
  local r = rows_at(d, 2.2)
  check("B's partial is steady after resampling (0.5 at 300 Hz)", #r == 1 and math.abs(r[1][1] - 0.5) < 1e-9 and r[1][2] == 300)
end

-- noise: the stored energy depends on the window size; weights are squared
do
  local A = sound({ { 200, 0.5 } }, 2.0, HOP, 1.0, 1000); local B = sound({ { 300, 0.5 } }, 2.0, HOP, 1.0, 2000)
  local d = cross.build({ a = { d = A, pos = 0 }, b = { d = B, pos = 0 }, line = 1.0, tol_time = 1.0, tol_cents = 20 })
  check("the result has noise bands and the window of A", d.has_noise and d.window_size == 1000)
  local fi = math.floor(0.2 / HOP + 0.5) + 1
  check("A's noise alone before the grey area (1.0)", math.abs(d.noise[5][fi] - 1.0) < 1e-9, d.noise[5][fi])
  fi = math.floor(1.0 / HOP + 0.5) + 1
  check("in the middle: half of A's (1.0) and half of B's converted to A's window (0.5)", math.abs(d.noise[5][fi] - (0.5 * 1.0 + 0.5 * 0.5)) < 1e-6, d.noise[5][fi])
  fi = math.floor(1.9 / HOP + 0.5) + 1
  check("B's noise alone after it, converted to A's window (0.5)", math.abs(d.noise[5][fi] - 0.5) < 1e-9, d.noise[5][fi])
end

-- a sound without noise adds none
do
  local A = sound({ { 200, 0.5 } }, 2.0, HOP, 1.0); local B = sound({ { 300, 0.5 } }, 2.0, HOP)
  local d = cross.build({ a = { d = A, pos = 0 }, b = { d = B, pos = 0 }, line = 1.0, tol_time = 0.2 })
  local fi = math.floor(1.9 / HOP + 0.5) + 1
  check("only A has noise: it is gone after the line", d.has_noise and d.noise[3][fi] == 0)
end

-- written to a file and read back; the synthesis plays it and the level has no hole at the crossing
do
  local A = sound({ { 200, 0.3 }, { 400, 0.2 } }, 2.0, HOP); local B = sound({ { 205, 0.3 }, { 800, 0.2 } }, 2.0, HOP)
  local path = "/tmp/claude-1000/-home-tjingboem/6ca29d3f-340f-46ca-9b11-e579b6c375ee/scratchpad/cross_test.ats"
  local info = assert(cross.make({ a = { d = A, pos = 0 }, b = { d = B, pos = 1.0 }, line = 1.5, tol_time = 0.4, tol_cents = 100 }, path))
  local r = assert(ats.load(path))
  check("the file reads back: type 2 (phase, no noise bands in these sounds), 3 s", r.type == 2 and r.has_phase and math.abs(r.dur - 3.0) < 1e-9 and r.frames == 301, r.type)
  local s = assert(synth.render(r, { noise = false }))
  local function rms(t0, t1) local a, b, sum = math.floor(t0 * 44100) + 1, math.floor(t1 * 44100), 0 for i = a, b do sum = sum + s[i] * s[i] end return math.sqrt(sum / (b - a + 1)) end
  local before, mid, after = rms(0.5, 0.9), rms(1.4, 1.6), rms(2.2, 2.6)
  check("no hole at the crossing: the level in the middle is within 3 dB of the level before and after", mid > before * 0.7 and mid > after * 0.7, string.format("%.3f %.3f %.3f", before, mid, after))
  os.remove(path)
end

print(string.format("%d passed, %d failed", ok, fails))
os.exit(fails == 0 and 0 or 1)
