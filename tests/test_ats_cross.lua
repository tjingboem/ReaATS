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
  check("the info lists the thread (a row and its frames) for the editor to blink", #info.threads == 1 and info.threads[1].f0 == 1 and info.threads[1].f1 == 301, #info.threads)
  check("and tells the overlap in the result's time and where its 0 lies", math.abs(info.ov0 - 1.0) < 1e-9 and math.abs(info.ov1 - 2.0) < 1e-9 and info.t_start == 0)
end

-- threads need not sound through the whole grey area (a wide grey area still finds them): A's partial ends at 1.5 s, B's begins at 1.35 s, the grey area is 1.3 .. 1.7
do
  local A = sound({ { 200, 0.5 } }, 2.0, HOP); local B = sound({ { 205, 0.5 } }, 1.65, HOP)       -- B is placed so that it starts at 1.35 s
  for f = 1, A.frames do if A.times[f] > 1.5 + 1e-9 then A.amp[1][f], A.frq[1][f] = 0, 0 end end   -- (A's partial ends at 1.5 s, the sound goes on)
  local spec = { a = { d = A, pos = 0 }, b = { d = B, pos = 1.35 }, line = 1.5, tol_time = 0.4, tol_cents = 100 }
  local info0 = cross.count(spec)
  check("the count says one thread without building the result", info0 and info0.pairs == 1, info0 and info0.pairs)
  local d, info = cross.build(spec)
  check("one thread although the partials sound together for only part of the grey area", info.pairs == 1, info.pairs)
  local r1, r2 = rows_at(d, 1.42), rows_at(d, 1.62)
  local th1, th2
  for _, x in ipairs(r1) do if x[2] > 190 and x[2] < 210 then th1 = x end end
  for _, x in ipairs(r2) do if x[2] > 190 and x[2] < 210 then th2 = x end end
  check("while both sound the frequency is between the two", th1 and th1[2] > 200 and th1[2] < 205, th1 and th1[2])
  check("after A's partial ended the thread goes on with B's frequency and the level moves to B's (s * 0.5)", th2 and th2[2] == 205 and th2[1] > 0.1 and th2[1] < 0.5, th2 and (th2[2] .. " " .. th2[1]))
  check("one row carries it all", #info.threads == 1)
  -- a very wide grey area: 4 s: the partials of 1 s overlap inside it: still a thread
  local A2 = sound({ { 200, 0.5 } }, 3.0, HOP); local B2 = sound({ { 205, 0.5 } }, 3.0, HOP)
  local info2 = cross.count({ a = { d = A2, pos = 0 }, b = { d = B2, pos = 1.0 }, line = 2.0, tol_time = 4.0, tol_cents = 100 })
  check("a wide grey area finds threads too", info2 and info2.pairs == 1, info2 and info2.pairs)
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

-- the level of a sound (gain): amplitudes times the factor, noise energy times its square
do
  local A = sound({ { 200, 0.5 } }, 1.0, HOP, 4.0)
  local B = sound({ { 800, 0.5 } }, 1.0, HOP)
  local d = cross.build({ a = { d = A, pos = 0, gain = 0.5 }, b = { d = B, pos = 2.0 }, line = 0, tol_time = 0 })
  local r = rows_at(d, 0.5)
  check("gain 0.5: the amplitude 0.5 becomes 0.25", #r == 1 and math.abs(r[1][1] - 0.25) < 1e-9, r[1] and r[1][1])
  check("and the noise energy 4.0 becomes 1.0", math.abs(d.noise[3][50] - 1.0) < 1e-9, d.noise[3][50])
end
-- the curves: A 200 / 400 Hz and B 205 / 800 Hz overlap from 1.0 to 2.0; in the middle of the grey area (1.5) s = 0.5
do
  local A = sound({ { 200, 0.5 }, { 400, 0.5 } }, 2.0, HOP)
  local B = sound({ { 205, 0.5 }, { 800, 0.5 } }, 2.0, HOP)
  local function mid(curve)
    local d = cross.build({ a = { d = A, pos = 0 }, b = { d = B, pos = 1.0 }, line = 1.5, tol_time = 0.4, tol_cents = 100, curve = curve })
    local r = rows_at(d, 1.5)
    local thread, lone = nil, nil
    for _, x in ipairs(r) do if x[2] < 300 then thread = x[1] elseif math.abs(x[2] - 400) < 1 then lone = x[1] end end
    return thread, lone
  end
  local th, lone = mid("smooth")
  check("smooth: a thread keeps its level (0.5), a lone partial is at cos(pi/4) of it", math.abs(th - 0.5) < 1e-6 and math.abs(lone - 0.5 * math.cos(math.pi / 4)) < 1e-6, th .. " " .. tostring(lone))
  th, lone = mid("linear")
  check("linear: the lone partial is at half", math.abs(th - 0.5) < 1e-6 and math.abs(lone - 0.25) < 1e-6, th .. " " .. tostring(lone))
  th, lone = mid("equal")
  check("equal power: the thread is louder in the middle (cos + sin = 0.707)", math.abs(th - 0.5 * 2 * math.cos(math.pi / 4)) < 1e-6 and math.abs(lone - 0.5 * math.cos(math.pi / 4)) < 1e-6, th .. " " .. tostring(lone))
  local d = cross.build({ a = { d = A, pos = 0 }, b = { d = B, pos = 1.0 }, line = 1.5, tol_time = 0.4, tol_cents = 100, curve = "s" })
  local r = rows_at(d, 1.4)                                                    -- a quarter of the way: the S is still lower than the cosine step
  local lone_s
  for _, x in ipairs(r) do if math.abs(x[2] - 400) < 1 then lone_s = x[1] end end
  local d2 = cross.build({ a = { d = A, pos = 0 }, b = { d = B, pos = 1.0 }, line = 1.5, tol_time = 0.4, tol_cents = 100 })
  local lone_c
  for _, x in ipairs(rows_at(d2, 1.4)) do if math.abs(x[2] - 400) < 1 then lone_c = x[1] end end
  check("S: little has happened a quarter of the way (louder A than the cosine step)", lone_s > lone_c, tostring(lone_s) .. " " .. tostring(lone_c))
end
-- a diagonal line: the low partials cross first, the high ones later (hard line, so each partial just switches at its own moment)
do
  local A = sound({ { 200, 0.5 }, { 2000, 0.5 } }, 2.0, HOP)
  local B = sound({ { 800, 0.5 }, { 3000, 0.5 } }, 2.0, HOP)
  local d, info = cross.build({ a = { d = A, pos = 0 }, b = { d = B, pos = 1.0 }, line = 1.5, tol_time = 0, tol_cents = 10, diag = { 1.2, 100, 1.8, 4000 } })
  local function has(t, f) for _, x in ipairs(rows_at(d, t)) do if math.abs(x[2] - f) < 1 then return true end end return false end
  check("A's 200 Hz has crossed at 1.5 s (its moment is 1.31 s)", not has(1.5, 200) and has(1.2, 200))
  check("A's 2000 Hz is still there at 1.5 s (its moment is 1.69 s)", has(1.5, 2000) and not has(1.75, 2000))
  check("B's 800 Hz starts at 1.54 s, B's 3000 Hz at 1.75 s", not has(1.5, 800) and has(1.6, 800) and not has(1.7, 3000) and has(1.8, 3000))
  check("the info tells the diagonal", info.diag and math.abs(info.diag[1] - 1.2) < 1e-9 and info.diag[2] == 100)
end
-- the count tells where the threads are (for the blinking on the CROSS page)
do
  local A = sound({ { 200, 0.5 } }, 2.0, HOP)
  local B = sound({ { 205, 0.5 } }, 2.0, HOP)
  local info = cross.count({ a = { d = A, pos = 0 }, b = { d = B, pos = 1.0 }, line = 1.5, tol_time = 0.4, tol_cents = 100 })
  check("the count lists the thread with both frequencies and its time", info.pairs == 1 and info.threads[1] and math.abs(info.threads[1].fl - 200) < 1e-6 and math.abs(info.threads[1].fr - 205) < 1e-6 and info.threads[1].t0 < info.threads[1].t1 and info.l_is_a, info.threads and info.threads[1] and info.threads[1].fl)
end

-- a timeline of three sounds: A (200 Hz, 0-2 s), B (205 Hz, 1.5-3.5 s), A2 (210 Hz, 3.0-5.0 s): A flows into B, and the result flows into A2
do
  local A = sound({ { 200, 0.5 } }, 2.0, HOP)
  local B = sound({ { 205, 0.5 } }, 2.0, HOP)
  local C = sound({ { 210, 0.5 } }, 2.0, HOP)
  local spec = { blocks = { { d = A, pos = 0 }, { d = B, pos = 1.5 }, { d = C, pos = 3.0 } }, steps = { [2] = { line = 1.75 }, [3] = { line = 3.25 } },
                 tol_time = 0.4, tol_cents = 100 }
  local d, info = cross.build_timeline(spec)
  check("the timeline is as long as the three sounds together (5 s)", d and math.abs(d.dur - 5.0) < 1e-9, d and d.dur)
  check("there are two transitions with their lines", info and #info.transitions == 2 and math.abs(info.transitions[1].line - 1.75) < 1e-9 and math.abs(info.transitions[2].line - 3.25) < 1e-9, info and #info.transitions)
  check("two threads (one per transition)", info and info.pairs == 2, info and info.pairs)
  local r = rows_at(d, 0.5); check("A alone at the start: 200 Hz", #r == 1 and math.abs(r[1][2] - 200) < 1e-6)
  r = rows_at(d, 2.5);       check("B alone in the middle: 205 Hz", #r == 1 and math.abs(r[1][2] - 205) < 1e-6, r[1] and r[1][2])
  r = rows_at(d, 4.5);       check("the last sound at the end: 210 Hz", #r == 1 and math.abs(r[1][2] - 210) < 1e-6, r[1] and r[1][2])
  check("the threads are found again in the result: here one partial runs through both transitions (A to B to A2)", #info.threads == 1 and info.threads[1].f0 == 1 and info.threads[1].f1 == d.frames, #info.threads)
  -- the order of the blocks in the list does not matter
  local d2 = cross.build_timeline({ blocks = { { d = C, pos = 3.0 }, { d = A, pos = 0 }, { d = B, pos = 1.5 } }, steps = spec.steps, tol_time = 0.4, tol_cents = 100 })
  check("any order in the list: the same result", d2 and d2.frames == d.frames)
  -- a gap: no transition, silence between
  local d3, i3 = cross.build_timeline({ blocks = { { d = A, pos = 0 }, { d = B, pos = 3.0 } }, steps = {}, tol_time = 0.4 })
  check("a gap between two sounds: no transition, nothing sounds in the gap", d3 and #i3.transitions == 0 and #rows_at(d3, 2.5) == 0 and #rows_at(d3, 1.0) == 1)
  check("one sound is not enough", cross.build_timeline({ blocks = { { d = A, pos = 0 } }, steps = {} }) == nil)
end

-- every transition has its own tolerances (a step with its own tol_time / tol_cents)
do
  local A = sound({ { 200, 0.5 } }, 2.0, HOP)
  local B = sound({ { 205, 0.5 } }, 2.0, HOP)
  local C = sound({ { 210, 0.5 } }, 2.0, HOP)
  local spec = { blocks = { { d = A, pos = 0 }, { d = B, pos = 1.5 }, { d = C, pos = 3.0 } },
                 steps = { [2] = { line = 1.75, tol_time = 0.4 }, [3] = { line = 3.25, tol_time = 0 } }, tol_time = 0.2, tol_cents = 100 }
  local d, info = cross.build_timeline(spec)
  check("the first transition has a grey area of 0.4 s, the second a hard line", d and math.abs(info.transitions[1].grey1 - info.transitions[1].grey0 - 0.4) < 1e-9
        and math.abs(info.transitions[2].grey1 - info.transitions[2].grey0) < 1e-9 and info.pairs == 1, info and info.transitions[2].grey1)
end

-- every transition may have its own curve (a step with curve): linear for the first, equal power for the second
do
  local A = sound({ { 200, 0.5 }, { 400, 0.5 } }, 2.0, HOP)
  local B = sound({ { 205, 0.5 }, { 800, 0.5 } }, 2.0, HOP)
  local d = cross.build_timeline({ blocks = { { d = A, pos = 0 }, { d = B, pos = 1.0 } }, steps = { [2] = { line = 1.5, tol_time = 0.4, curve = "linear" } }, tol_time = 0.4, tol_cents = 100, curve = "smooth" })
  local lone
  for _, x in ipairs(rows_at(d, 1.5)) do if math.abs(x[2] - 400) < 1 then lone = x[1] end end
  check("the step's own curve wins over the page's: linear gives half (0.25), smooth would give 0.354", lone and math.abs(lone - 0.25) < 1e-6, lone)
end

-- the level curves the page draws (weights of the first and second sound at the middle of the grey area)
do
  local wl, wr = cross.weights("linear", cross.shape("linear", 0.5))
  check("linear: both sounds at half in the middle", math.abs(wl - 0.5) < 1e-9 and math.abs(wr - 0.5) < 1e-9)
  wl, wr = cross.weights("equal", cross.shape("equal", 0.5))
  check("equal power: both at 0.707 in the middle (they cross higher)", math.abs(wl - math.sqrt(0.5)) < 1e-9 and math.abs(wr - math.sqrt(0.5)) < 1e-9)
end

print(string.format("%d passed, %d failed", ok, fails))
os.exit(fails == 0 and 0 or 1)
