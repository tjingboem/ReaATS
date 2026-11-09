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
s = synth.render(d, { sines = false })
local expect = synth.NOISE_GAIN * math.sqrt(0.01 / (1765 * synth.NOISE_VARIANCE))
check("noise level", math.abs(rms(s, 100, #s - 100) / expect - 1) < 0.05, rms(s) .. " vs " .. expect)
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

print(string.format("%d passed, %d failed", ok, fails))
os.exit(fails == 0 and 0 or 1)
