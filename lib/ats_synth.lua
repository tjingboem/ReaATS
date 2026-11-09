-- ats_synth.lua -- renders ATS data (see ats_file.lua) to audio in pure Lua, so ReaATS does not need
-- Csound to be heard.
--
-- Method (the standard ATS resynthesis, described in the ATS papers and implemented in the BSD-3
-- licensed Python package pyatsyn, whose phase-less sine path this follows in structure -- see
-- THIRD-PARTY-NOTICES.md):
--   sines : one oscillator per partial; between two frames its amplitude and its frequency change
--           linearly, and the phase is the running sum of the frequency. Stored phases are NOT used
--           (they are wrong after editing, and the saved files do not have them).
--   noise : per critical band, white noise is band-limited and multiplied by that band's energy
--           envelope. The ATS file stores noise as energy per band; the amplitude of the band is
--           sqrt(energy / (window_size * 0.04)) (0.04 = the noise variance assumed by the ATS analysis).
--           The band-limiting here is a 4th-order Butterworth band-pass (two biquads), not a
--           brick-wall FFT filter, and the overall noise level is calibrated against Csound's own
--           ATS noise resynthesis (NOISE_GAIN below), so the two sound about equally loud.
-- Output is a Lua array of samples (floats, 1-based) and the sample rate.

local M = {}

local sin, sqrt, floor, pi = math.sin, math.sqrt, math.floor, math.pi
local TWO_PI = 2 * pi

M.NOISE_VARIANCE = 0.04       -- the variance the ATS analysis assumes for the noise (a property of the format)
M.NOISE_GAIN = 0.30           -- calibrated against Csound's atsaddnz on examples/sax.ats: noise level within 0.1 dB overall

local EDGES = { 0, 100, 200, 300, 400, 510, 630, 770, 920, 1080, 1270, 1480, 1720,
                2000, 2320, 2700, 3150, 3700, 4400, 5300, 6400, 7700, 9500, 12000, 15500, 20000 }

-- Adds all partials into out[1..n].
local function add_sines(d, out, n)
  local fs = floor(d.frame_size + 0.5)
  local w_scale = TWO_PI / d.sr
  for p = 1, d.partials do
    local amp, frq = d.amp[p], d.frq[p]
    local phase = 0
    for k = 1, d.frames - 1 do
      local base = (k - 1) * fs
      if base >= n then break end
      local a0, a1, f0, f1 = amp[k], amp[k + 1], frq[k], frq[k + 1]
      if (a0 > 0 or a1 > 0) and (f0 > 0 or f1 > 0) then
        if f0 <= 0 then f0 = f1 elseif f1 <= 0 then f1 = f0 end
        local count = fs
        if base + count > n then count = n - base end
        local w, dw = f0 * w_scale, (f1 - f0) * w_scale / fs
        local a, da = a0, (a1 - a0) / fs
        for i = base + 1, base + count do
          out[i] = out[i] + a * sin(phase)
          phase = phase + w
          w = w + dw
          a = a + da
        end
        phase = phase % TWO_PI
      end
    end
  end
end

-- RBJ-cookbook 2nd-order Butterworth (Q = 1/sqrt2) low-pass / high-pass coefficients.
local function biquad(kind, fc, sr)
  local w0 = TWO_PI * fc / sr
  local cw, sw = math.cos(w0), sin(w0)
  local alpha = sw / (2 * 0.70710678)
  local b0, b1, b2
  if kind == "lp" then
    b0, b1, b2 = (1 - cw) / 2, 1 - cw, (1 - cw) / 2
  else
    b0, b1, b2 = (1 + cw) / 2, -(1 + cw), (1 + cw) / 2
  end
  local a0, a1, a2 = 1 + alpha, -2 * cw, 1 - alpha
  return b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0
end

-- Deterministic white noise (uniform in -1..1), so a render is repeatable.
local function make_rng(seed)
  local s = seed or 12345
  return function()
    s = (s * 1103515245 + 12345) % 2147483648
    return s / 1073741824 - 1
  end
end

-- Adds the noise bands into out[1..n].
local function add_noise(d, out, n, seed)
  local fs = floor(d.frame_size + 0.5)
  local nyq = d.sr / 2
  local rng = make_rng(seed)
  local amp_scale = M.NOISE_GAIN / sqrt(d.window_size * M.NOISE_VARIANCE)
  for b = 1, 25 do
    local nb = d.noise[b]
    local any = false
    for f = 1, d.frames do if nb[f] > 0 then any = true; break end end
    local lo, hi = EDGES[b], EDGES[b + 1]
    if any and lo < nyq * 0.98 then
      hi = math.min(hi, nyq * 0.98)
      -- band-limited noise: high-pass at lo (not for the first band) then low-pass at hi, each 2nd order, twice
      local stages = {}
      if lo > 0 then
        local b0, b1, b2, a1, a2 = biquad("hp", lo, d.sr)
        stages[#stages + 1] = { b0, b1, b2, a1, a2, 0, 0, 0, 0 }
        stages[#stages + 1] = { b0, b1, b2, a1, a2, 0, 0, 0, 0 }
      end
      do
        local b0, b1, b2, a1, a2 = biquad("lp", hi, d.sr)
        stages[#stages + 1] = { b0, b1, b2, a1, a2, 0, 0, 0, 0 }
        stages[#stages + 1] = { b0, b1, b2, a1, a2, 0, 0, 0, 0 }
      end
      local noise, sumsq = {}, 0
      for i = 1, n do
        local x = rng()
        for s = 1, #stages do
          local st = stages[s]
          local y = st[1] * x + st[2] * st[6] + st[3] * st[7] - st[4] * st[8] - st[5] * st[9]
          st[7], st[6] = st[6], x
          st[9], st[8] = st[8], y
          x = y
        end
        noise[i] = x
        sumsq = sumsq + x * x
      end
      local norm = (sumsq > 0) and (1 / sqrt(sumsq / n)) or 0          -- unit RMS
      for k = 1, d.frames - 1 do
        local base = (k - 1) * fs
        if base >= n then break end
        local e0, e1 = nb[k], nb[k + 1]
        if e0 > 0 or e1 > 0 then
          local count = fs
          if base + count > n then count = n - base end
          local a0, a1 = sqrt(e0) * amp_scale * norm, sqrt(e1) * amp_scale * norm
          local a, da = a0, (a1 - a0) / fs
          for i = base + 1, base + count do
            out[i] = out[i] + a * noise[i]
            a = a + da
          end
        end
      end
    end
  end
end

-- Renders d. opts: sines (default true), noise (default true; needs noise data), seed.
-- Returns samples (a 1-based Lua array) and the sample rate, or nil plus a message.
function M.render(d, opts)
  opts = opts or {}
  local use_sines = opts.sines ~= false
  local use_noise = (opts.noise ~= false) and d.has_noise
  if not use_sines and not use_noise then return nil, "nothing to render (sines and noise are both off)" end
  local n = floor(d.dur * d.sr)
  local last = (d.frames - 1) * floor(d.frame_size + 0.5)
  if last < n then n = last end
  if n < 1 then return nil, "the file has no sound" end
  local out = {}
  for i = 1, n do out[i] = 0 end
  if use_sines then add_sines(d, out, n) end
  if use_noise then add_noise(d, out, n, opts.seed) end
  return out, d.sr
end

-- Writes a mono 32-bit float WAV file.
function M.write_wav(path, samples, sr)
  local n = #samples
  local fh, err = io.open(path, "wb")
  if not fh then return nil, "cannot write " .. tostring(path) .. ": " .. tostring(err) end
  local data_bytes = n * 4
  fh:write("RIFF", string.pack("<I4", 36 + data_bytes), "WAVE")
  fh:write("fmt ", string.pack("<I4I2I2I4I4I2I2", 16, 3, 1, sr, sr * 4, 4, 32))
  fh:write("data", string.pack("<I4", data_bytes))
  local chunk = {}
  for i = 1, n, 4096 do
    local m = math.min(4095, n - i)
    for j = 0, m do chunk[j + 1] = samples[i + j] end
    fh:write(string.pack("<" .. string.rep("f", m + 1), table.unpack(chunk, 1, m + 1)))
  end
  fh:close()
  return true
end

return M
