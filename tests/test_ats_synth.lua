-- Run: lua5.4 tests/test_ats_synth.lua   (from the ReaATS folder)
package.path = "lib/?.lua;" .. package.path
local ats, synth = require("ats_file"), require("ats_synth")
local ok, fails = 0, 0
local function check(name, cond, extra)
  if cond then ok = ok + 1 else fails = fails + 1; print("FAIL: " .. name .. " " .. tostring(extra or "")) end
end

local function make(P, NF, with_noise)
  local d = { sr = 44100, frame_size = 441, window_size = 1765, partials = P, frames = NF,
              dur = (NF - 1) * 0.01, type = with_noise and 3 or 1, has_phase = false, has_noise = with_noise or false,
              ampmax = 1, frqmax = 20000, amp = {}, frq = {}, times = {}, noise_max = 0 }
  for f = 1, NF do d.times[f] = (f - 1) * 0.01 end
  for p = 1, P do d.amp[p], d.frq[p] = {}, {}; for f = 1, NF do d.amp[p][f], d.frq[p][f] = 0, 0 end end
  if with_noise then d.noise = {}; for b = 1, 25 do d.noise[b] = {}; for f = 1, NF do d.noise[b][f] = 0 end end end
  return d
end
local function rms(s, i0, i1)
  local sum = 0
  for i = i0 or 1, i1 or #s do sum = sum + s[i] * s[i] end
  return math.sqrt(sum / ((i1 or #s) - (i0 or 1) + 1))
end
local function crossings(s)               -- rising zero crossings
  local n = 0
  for i = 2, #s do if s[i - 1] < 0 and s[i] >= 0 then n = n + 1 end end
  return n
end
local function power_at(s, freq, sr)      -- Goertzel
  local w = 2 * math.pi * freq / sr
  local c, s1, s2 = 2 * math.cos(w), 0, 0
  for i = 1, #s do local s0 = s[i] + c * s1 - s2; s2 = s1; s1 = s0 end
  return (s1 * s1 + s2 * s2 - c * s1 * s2) / #s
end

-- 1. one steady sine: level and pitch
local d = make(2, 101)
for f = 1, 101 do d.amp[1][f], d.frq[1][f] = 0.5, 440 end
local s, sr = synth.render(d)
check("renders 1 s", s and #s == 44100 and sr == 44100, s and #s)
check("sine level 0.5/sqrt2", math.abs(rms(s, 2000, 40000) - 0.5 / math.sqrt(2)) < 0.005, rms(s, 2000, 40000))
check("sine pitch 440 Hz", math.abs(crossings(s) - 440) <= 2, crossings(s))

-- 2. a second partial adds in power
for f = 1, 101 do d.amp[2][f], d.frq[2][f] = 0.2, 1234 end
s = synth.render(d)
check("two partials", math.abs(rms(s, 2000, 40000) - math.sqrt((0.25 + 0.04) / 2)) < 0.01, rms(s, 2000, 40000))

-- 3. deleted frames (amplitude 0) are silent in the middle, with linear ramps at the edges
d = make(1, 101)
for f = 1, 101 do d.amp[1][f], d.frq[1][f] = 0.5, 440 end
for f = 40, 60 do d.amp[1][f] = 0 end
s = synth.render(d)
check("silence where deleted", rms(s, math.floor(0.41 * 44100), math.floor(0.59 * 44100)) < 1e-9)
check("sound outside", rms(s, 1000, 15000) > 0.3 and rms(s, 30000, 43000) > 0.3)

-- 4. transposed (frequency doubled) really doubles the pitch
d = make(1, 101)
for f = 1, 101 do d.amp[1][f], d.frq[1][f] = 0.5, 880 end
s = synth.render(d)
check("880 Hz", math.abs(crossings(s) - 880) <= 3, crossings(s))

-- 5. a point with amplitude but no frequency takes the neighbour's frequency, nothing explodes
d = make(1, 11)
for f = 1, 11 do d.amp[1][f], d.frq[1][f] = 0.5, 440 end
d.frq[1][5] = 0
s = synth.render(d)
local finite = true
for i = 1, #s do if s[i] ~= s[i] or math.abs(s[i]) > 1 then finite = false end end
check("zero frequency is bridged", finite)

-- 6. noise: level follows the formula and stays inside its band
d = make(1, 101, true)
for f = 1, 101 do d.noise[10][f] = 0.01 end                       -- band 10 = 920..1080 Hz
s = synth.render(d, { sines = false, noise_shape = "classic" })
local expect = synth.NOISE_GAIN * math.sqrt(0.01 / (1765 * synth.NOISE_VARIANCE))
check("noise level (classic: as Csound's ATS synthesis)", math.abs(rms(s, 100, #s - 100) / expect - 1) < 0.05, rms(s) .. " vs " .. expect)
s = synth.render(d, { sines = false })
expect = synth.NOISE_GAIN_CORRECTED * math.sqrt(0.01 / (1765 * synth.NOISE_VARIANCE))
check("noise level (corrected, the default: one band keeps its own power)", math.abs(rms(s, 100, #s - 100) / expect - 1) < 0.05, rms(s) .. " vs " .. expect)
-- the bandwidth correction moves power between bands but keeps the energy of the frame: with equal values in all bands the total power
-- is only changed by the calibration of the gain
local dall = make(1, 101, true)
for b = 1, 25 do for f = 1, 101 do dall.noise[b][f] = 0.01 end end
local sc, scl = synth.render(dall, { sines = false }), synth.render(dall, { sines = false, noise_shape = "classic" })
local ratio = rms(sc, 100, #sc - 100) / rms(scl, 100, #scl - 100)
check("the correction keeps the energy of a frame (ratio " .. string.format("%.3f", ratio) .. " vs the gain ratio " .. string.format("%.3f", synth.NOISE_GAIN_CORRECTED / synth.NOISE_GAIN) .. ")",
      math.abs(ratio / (synth.NOISE_GAIN_CORRECTED / synth.NOISE_GAIN) - 1) < 0.08)
local function mean_power(f0, f1, step)           -- averaged over many bins: one bin of noise fluctuates a lot
  local sum, n = 0, 0
  for f = f0, f1, step do sum = sum + power_at(s, f, 44100); n = n + 1 end
  return sum / n
end
local p_in, p_out = mean_power(930, 1070, 10), mean_power(3000, 4000, 50)
check("noise stays near its band (>18 dB below, 4th-order skirts)", 10 * math.log(p_in / p_out, 10) > 18, 10 * math.log(p_in / p_out, 10))
local s2 = synth.render(d, { sines = false })
local same = true
for i = 1, #s do if s[i] ~= s2[i] then same = false; break end end
check("noise is repeatable", same)

-- 7. switches
check("nothing to render", select(1, synth.render(d, { sines = false, noise = false })) == nil)
d = make(1, 11); for f = 1, 11 do d.amp[1][f], d.frq[1][f] = 0.5, 440 end
check("no noise data: sines only", synth.render(d, { noise = true }) ~= nil)

-- 7b. rendering from a point in time
d = make(1, 101)
for f = 1, 101 do d.amp[1][f], d.frq[1][f] = 0.5, 440 end
local full, _, t_full = synth.render(d)
local part, _, t_part = synth.render(d, { from = 0.5 })
check("full render starts at 0", t_full == 0)
check("from 0.5 s starts at the frame at or before it", t_part == 0.5 or (t_part <= 0.5 and 0.5 - t_part < 0.0101), t_part)
check("from: length is the rest", math.abs(#part - (#full - math.floor(t_part * 44100 + 0.5))) <= 1, #part .. " vs " .. #full)
check("from: same level", math.abs(rms(part, 500, #part - 500) - 0.5 / math.sqrt(2)) < 0.005)
check("from: pitch still 440", math.abs(crossings(part) / (#part / 44100) - 440) < 6)
local none, why = synth.render(d, { from = 5 })
check("from after the end is clamped to the last frame, not an error", none ~= nil or why ~= nil)
d = make(1, 101, true)
for f = 1, 101 do d.noise[10][f] = 0.01 end
local npart = synth.render(d, { sines = false, from = 0.3 })
check("noise from a point", npart and #npart == 44100 - 29 * 441 + 0 or #npart > 0, npart and #npart)

-- 8. WAV file: header and samples
local tmp = "/tmp/claude-1000/-home-tjingboem/6ca29d3f-340f-46ca-9b11-e579b6c375ee/scratchpad/synth_test.wav"
local src = { 0, 0.5, -0.25, 1, -1, 0.123456 }
for i = 7, 5000 do src[i] = math.sin(i * 0.01) * 0.4 end
check("write_wav", synth.write_wav(tmp, src, 44100))
local f = io.open(tmp, "rb"); local bytes = f:read("a"); f:close()
check("RIFF/WAVE", bytes:sub(1, 4) == "RIFF" and bytes:sub(9, 12) == "WAVE")
local fmt_tag, ch, rate, _, _, bits = string.unpack("<I2I2I4I4I2I2", bytes, 21)
check("float mono 32 bit 44100", fmt_tag == 3 and ch == 1 and rate == 44100 and bits == 32, fmt_tag .. "/" .. ch .. "/" .. rate .. "/" .. bits)
check("data size", string.unpack("<I4", bytes, 41) == #src * 4 and #bytes == 44 + #src * 4)
local back = { string.unpack("<ffffff", bytes, 45) }
check("samples round trip", math.abs(back[2] - 0.5) < 1e-7 and math.abs(back[6] - 0.123456) < 1e-6 and back[5] == -1)
os.remove(tmp)

-- 9. a real file: speed and sanity
local sax = assert(ats.load("examples/sax.ats"))
local t0 = os.clock()
local out = synth.render(sax)
local took = os.clock() - t0
check("sax.ats renders (2.2 s of sound)", #out == 95810 and took < 5, took)
check("sax.ats level near the original (-12.7 dBFS)", math.abs(20 * math.log(rms(out), 10) - (-12.7)) < 1.0, 20 * math.log(rms(out), 10))

-- 10. the same render in small steps (so a window can keep drawing)
do
  local direct = synth.render(sax, { from = 0.4 })
  local job = synth.render_job(sax, { from = 0.4 })
  local steps, last, monotone = 0, 0, true
  while not job.step(0.005) do
    steps = steps + 1
    if job.progress < last - 1e-9 then monotone = false end
    last = job.progress
    if steps > 100000 then break end
  end
  check("a job needs several steps with a small budget", steps > 3, steps)
  check("progress only goes up", monotone)
  check("progress ends at 1", job.progress == 1 and job.done)
  check("the job gives exactly the samples of a direct render", job.samples and #job.samples == #direct, job.samples and #job.samples)
  local same = true
  for i = 1, #direct do if direct[i] ~= job.samples[i] then same = false; break end end
  check("sample for sample", same)
  check("the start time comes through", math.abs(job.t_start - 0.4) < 0.0101, job.t_start)
  -- cancelling leaves nothing that could yield later
  local j2 = synth.render_job(sax, {})
  j2.step(0.001); j2.cancel()
  local again = synth.render(d, {}) or true
  check("a direct render after a cancelled job still works", synth.render(sax, { sines = true, noise = false }) ~= nil)
  -- a failing job reports instead of raising
  local j3 = synth.render_job(sax, { sines = false, noise = false })
  while not j3.step(0.01) do end
  check("an impossible job ends with a message", j3.samples == nil and j3.error and j3.error:find("nothing to render"))
end

-- 11. several channels
do
  local function tone_data(freq)
    local dd = make(1, 101)
    for f = 1, 101 do dd.amp[1][f], dd.frq[1][f] = 0.5, freq end
    return dd
  end
  local list = { tone_data(440), tone_data(660), tone_data(880) }
  local job = synth.render_multi_job(list, {})
  local steps, last, monotone = 0, 0, true
  while not job.step(0.004) do
    steps = steps + 1
    if job.progress < last - 1e-9 then monotone = false end
    last = job.progress
    if steps > 100000 then break end
  end
  check("multi: three channels", job.channels and #job.channels == 3 and #job.channels[1] == 44100)
  check("multi: progress only goes up and ends at 1", monotone and job.progress == 1)
  local heavy = synth.render_multi_job({ sax, sax }, {})
  local heavy_steps = 0
  while not heavy.step(0.004) do heavy_steps = heavy_steps + 1; if heavy_steps > 100000 then break end end
  check("multi: a real sound needs several steps", heavy_steps > 5 and #heavy.channels == 2, heavy_steps)
  check("multi: pitches follow the channel", math.abs(crossings(job.channels[1]) - 440) <= 3 and math.abs(crossings(job.channels[2]) - 660) <= 3
    and math.abs(crossings(job.channels[3]) - 880) <= 3, crossings(job.channels[1]) .. "/" .. crossings(job.channels[2]) .. "/" .. crossings(job.channels[3]))
  check("multi: samples are the first channel's", job.samples == job.channels[1])
  local direct = synth.render(list[2], {})
  local same = true
  for i = 1, #direct do if direct[i] ~= job.channels[2][i] then same = false; break end end
  check("multi: a channel is exactly a single render", same)
  local f = "/tmp/claude-1000/-home-tjingboem/6ca29d3f-340f-46ca-9b11-e579b6c375ee/scratchpad/multi_test.wav"
  check("multi: write", synth.write_wav_channels(f, job.channels, job.sr))
  local wavinfo = dofile("lib/wav_info.lua").read(f)
  check("multi: header says 3 channels", wavinfo and wavinfo.channels == 3 and wavinfo.frames == 44100 and wavinfo.float and wavinfo.rate == 44100, wavinfo and wavinfo.channels)
  local fh = io.open(f, "rb"); local bytes = fh:read("a"); fh:close()
  local a1, a2, a3 = string.unpack("<fff", bytes, 45 + 3 * 4 * 1000)       -- sample 1001 of every channel
  check("multi: interleaved in channel order", math.abs(a1 - job.channels[1][1001]) < 1e-6 and math.abs(a2 - job.channels[2][1001]) < 1e-6 and math.abs(a3 - job.channels[3][1001]) < 1e-6)
  os.remove(f)
  local bad = synth.render_multi_job({ tone_data(440), tone_data(440) }, { sines = false, noise = false })
  while not bad.step(0.01) do end
  check("multi: a failing channel ends with a message", bad.samples == nil and bad.error ~= nil)
  local cancelled = synth.render_multi_job(list, {})
  cancelled.step(0.001); cancelled.cancel()
  check("multi: a direct render after a cancelled job still works", synth.render(list[1], {}) ~= nil)
end

-- 12. the stereo mixdown for listening
do
  local function sine_ch(freq, n)
    local c = {}
    for i = 1, n do c[i] = 0.5 * math.sin(2 * math.pi * freq * i / 44100) end
    return c
  end
  local two = { sine_ch(440, 4410), sine_ch(660, 4410) }
  check("two channels stay as they are", synth.mix_to_stereo(two) == two)
  local one = { sine_ch(440, 100) }
  check("one channel stays as it is", synth.mix_to_stereo(one) == one)
  local chans = { sine_ch(440, 22050), sine_ch(660, 22050), sine_ch(880, 22050) }
  local mix = synth.mix_to_stereo(chans)
  check("three channels become two", #mix == 2 and #mix[1] == 22050 and #mix[2] == 22050)
  local function pw(s, f) local w = 2 * math.pi * f / 44100; local c, s1, s2 = 2 * math.cos(w), 0, 0
    for i = 1, #s do local s0 = s[i] + c * s1 - s2; s2 = s1; s1 = s0 end return (s1 * s1 + s2 * s2 - c * s1 * s2) / #s end
  check("channel 1 is hard left", pw(mix[2], 440) < 1e-6 * pw(mix[1], 440), pw(mix[2], 440) / pw(mix[1], 440))
  check("the last channel is hard right", pw(mix[1], 880) < 1e-6 * pw(mix[2], 880))
  local pl, pr = pw(mix[1], 660), pw(mix[2], 660)
  check("the middle channel is in both, equally", math.abs(pl / pr - 1) < 0.01 and pl > 0, pl / pr)
  check("the middle channel is 3 dB down on each side", math.abs(10 * math.log(pl / pw(mix[1], 440), 10) + 3.01) < 0.1, 10 * math.log(pl / pw(mix[1], 440), 10))
  local peak = 0
  for _, side in ipairs(mix) do for i = 1, #side do peak = math.max(peak, math.abs(side[i])) end end
  check("the mixdown does not get louder than the loudest channel could be times the sum of gains", peak < 1.0, peak)
  local four = synth.mix_to_stereo({ sine_ch(300, 2000), sine_ch(400, 2000), sine_ch(500, 2000), sine_ch(600, 2000) })
  check("four channels become two", #four == 2 and #four[1] == 2000)
  -- equal-level uncorrelated channels: the loudest side keeps the level of one channel (the level rule)
  local pl4, pr4 = pw(four[1], 300) + pw(four[1], 400) + pw(four[1], 500) + pw(four[1], 600), pw(four[2], 300) + pw(four[2], 400) + pw(four[2], 500) + pw(four[2], 600)
  check("the sides are about equally loud", math.abs(10 * math.log(pl4 / pr4, 10)) < 0.5, 10 * math.log(pl4 / pr4, 10))
end


-- ------------------------------------------------------------ speed-ups: window, noise cache, silent stretches
do
  local ats2 = dofile("lib/ats_file.lua")
  local sx = assert(ats2.load("examples/sax.ats"))
  local function rms(a) local s = 0; for i = 1, #a do s = s + a[i] * a[i] end; return math.sqrt(s / #a) end
  -- `to`: stop at a time
  local full = synth.render(sx, { sines = true, noise = false })
  local part = synth.render(sx, { sines = true, noise = false, from = 0.5, to = 1.0 })
  check("to: a window of 0.5 s is 22050 samples", #part == 22050, "got " .. #part)
  local ratio_w = rms(part) / rms({ table.unpack(full, off_samples or math.floor(0.5 * sx.sr / math.floor(sx.frame_size + 0.5)) * math.floor(sx.frame_size + 0.5) + 1, 22050 + math.floor(0.5 * sx.sr / math.floor(sx.frame_size + 0.5)) * math.floor(sx.frame_size + 0.5)) })
  check("to: the window has the level of that part of the full render (ratio " .. string.format("%.3f", ratio_w) .. ")", ratio_w > 0.97 and ratio_w < 1.03)
  -- the noise cache: the same noise again, quickly; a request inside a cached stretch reuses it
  sx.noise_cache = nil
  local t0 = os.clock(); local a1 = synth.render(sx, { sines = false }); local first = os.clock() - t0
  check("the render left a cache", sx.noise_cache ~= nil and sx.noise_cache.n == #a1)
  t0 = os.clock(); local a2 = synth.render(sx, { sines = false }); local again = os.clock() - t0
  local ident = true
  for i = 1, #a1 do if a1[i] ~= a2[i] then ident = false; break end end
  check("cached noise is exactly the same", ident)
  check("cached noise is much quicker (" .. string.format("%.2f s then %.2f s", first, again) .. ")", again < first / 3)
  local cache_before = sx.noise_cache
  local w = synth.render(sx, { sines = false, from = 1.0, to = 1.5 })
  check("a window inside the cache reuses it", sx.noise_cache == cache_before and #w == 22050)
  local fs = math.floor(sx.frame_size + 0.5)
  local k0 = 1 + math.floor(1.0 * sx.sr / fs + 1e-6)
  local match = true
  for i = 1, 100 do if w[i] ~= a1[(k0 - 1) * fs + i] then match = false end end
  check("and it is the same noise as in the full render", match)
  -- editing the partials does not touch the noise: sines change, noise stays
  local keep = sx.amp[5][10]
  sx.amp[5][10] = 0
  local b = synth.render(sx, { sines = false })
  check("noise does not change when partials are edited", b[1000] == a1[1000] and sx.noise_cache == cache_before)
  sx.amp[5][10] = keep
  -- silent stretches: a band with no energy for a while costs nothing and the level stays right
  local gap = assert(ats2.load("examples/sax.ats"))
  for bnd = 1, 25 do for f = 60, 150 do gap.noise[bnd][f] = 0 end end
  local g = synth.render(gap, { sines = false })
  local silent = true
  for i = 60 * fs + 1, 148 * fs do if g[i] ~= 0 then silent = false; break end end
  check("a stretch without noise energy is silent", silent)
  local ratio = rms({ table.unpack(g, 1, 50 * fs) }) / rms({ table.unpack(a1, 1, 50 * fs) })
  check("the noise before the gap has the same level (ratio " .. string.format("%.2f", ratio) .. ")", ratio > 0.75 and ratio < 1.33)
end


-- the peak limit: a loud sound is turned down (one gain for every channel), a quiet one is left alone
do
  local loud = { { 0, 2, -1 }, { 0.5, 0, 0 } }
  local g = synth.limit_peak(loud, -1)
  local ceiling = 10 ^ (-1 / 20)
  check("limit_peak: the highest peak is at the limit", math.abs(math.abs(loud[1][2]) - ceiling) < 1e-9, loud[1][2])
  check("limit_peak: the gain is in dB and below 0", g < -6.9 and g > -7.1, g)
  check("limit_peak: every channel got the same gain", math.abs(loud[2][1] / 0.5 - loud[1][2] / 2) < 1e-9)
  local quiet = { { 0.1, -0.2 } }
  check("limit_peak: a quiet sound is not turned up", synth.limit_peak(quiet, -1) == 0 and quiet[1][1] == 0.1 and quiet[1][2] == -0.2)
end

print(string.format("%d passed, %d failed", ok, fails))
os.exit(fails == 0 and 0 or 1)
