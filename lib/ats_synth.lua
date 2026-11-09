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

-- A render can run in small steps (render_job below): while one runs, `hook` is called with how far it is (0..1) and
-- may yield. The loops call tick() at convenient points; `base` and `span` place the current part (sines, noise) in 0..1.
local hook = nil
local base, span = 0, 1
local function tick(frac) if hook then hook(base + span * frac) end end

-- Adds all partials into out[1..n].
local function add_sines(d, out, n, k0)
  local fs = floor(d.frame_size + 0.5)
  local w_scale = TWO_PI / d.sr
  for p = 1, d.partials do
    local amp, frq = d.amp[p], d.frq[p]
    local phase = 0
    for k = k0, d.frames - 1 do
      local base = (k - k0) * fs
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
    tick(p / d.partials)
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
local function add_noise(d, out, n, seed, k0)
  local fs = floor(d.frame_size + 0.5)
  local nyq = d.sr / 2
  local rng = make_rng(seed)
  local amp_scale = M.NOISE_GAIN / sqrt(d.window_size * M.NOISE_VARIANCE)
  for b = 1, 25 do
    local nb = d.noise[b]
    local any = false
    for f = k0, d.frames do if nb[f] > 0 then any = true; break end end
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
        if i % 16384 == 0 then tick((b - 1 + i / n * 0.8) / 25) end
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
      for k = k0, d.frames - 1 do
        local base = (k - k0) * fs
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
    tick(b / 25)
  end
end

-- Renders d. opts: sines (default true), noise (default true; needs noise data), seed, from (seconds: start there; the start
-- is moved back to the beginning of its frame). Returns samples (a 1-based Lua array), the sample rate and the time in the
-- sound at which the samples start, or nil plus a message.
function M.render(d, opts)
  opts = opts or {}
  local use_sines = opts.sines ~= false
  local use_noise = (opts.noise ~= false) and d.has_noise
  if not use_sines and not use_noise then return nil, "nothing to render (sines and noise are both off)" end
  local fs = floor(d.frame_size + 0.5)
  local n_total = floor(d.dur * d.sr)
  local last = (d.frames - 1) * fs
  if last < n_total then n_total = last end
  if n_total < 1 then return nil, "the file has no sound" end
  local k0 = 1
  if opts.from and opts.from > 0 then k0 = math.min(1 + floor(opts.from * d.sr / fs + 1e-6), d.frames - 1) end
  local n = n_total - (k0 - 1) * fs
  if n < 1 then return nil, "nothing to play after this point" end
  local out = {}
  for i = 1, n do out[i] = 0 end
  local both = use_sines and use_noise
  if use_sines then base, span = 0, both and 0.15 or 1; add_sines(d, out, n, k0) end
  if use_noise then base, span = both and 0.15 or 0, both and 0.85 or 1; add_noise(d, out, n, opts.seed, k0) end
  base, span = 0, 1
  return out, d.sr, (k0 - 1) * fs / d.sr
end

-- The same render, in steps, so that a window can keep drawing while it runs. job.step(seconds) works for about that long
-- (CPU time) and returns true when the job is finished; job.progress is 0..1; when done, job.samples, job.sr and job.t_start
-- are the results of M.render (job.samples is nil and job.error the message when it failed); job.cancel() drops it.
-- Only one job may run at a time.
function M.render_job(d, opts)
  local job = { progress = 0, done = false }
  local deadline = 0
  local co = coroutine.create(function()
    hook = function(frac)
      job.progress = frac
      if os.clock() >= deadline and coroutine.isyieldable() then coroutine.yield() end
    end
    local samples, sr, t_start = M.render(d, opts)
    hook = nil
    if samples then job.samples, job.sr, job.t_start = samples, sr, t_start else job.error = sr end
    job.progress, job.done = 1, true
  end)
  function job.step(budget)
    if job.done then return true end
    deadline = os.clock() + (budget or 0.03)
    local ok, err = coroutine.resume(co)
    if not ok then hook = nil; job.error, job.done = tostring(err), true end
    return job.done
  end
  function job.cancel()
    hook = nil
    base, span = 0, 1
    job.done, job.cancelled = true, true
  end
  return job
end

-- Mixes any number of channels down to stereo for listening: the channels are spread from left to right (channel 1 hard
-- left, the last hard right, the others in between, constant power) and the level is set so that neither side gets louder
-- than one channel would. Returns { left, right }. Two channels are returned as they are (channel 1 left, 2 right).
function M.mix_to_stereo(chans)
  local n = #chans
  if n <= 2 then return chans end
  local gl, gr, sl, sr_ = {}, {}, 0, 0
  for k = 1, n do
    local pan = (k - 1) / (n - 1)                                 -- 0 = left, 1 = right
    gl[k], gr[k] = math.cos(pan * pi / 2), math.sin(pan * pi / 2)
    sl, sr_ = sl + gl[k] * gl[k], sr_ + gr[k] * gr[k]
  end
  local norm = 1 / math.sqrt(math.max(sl, sr_))
  local len = 0
  for _, c in ipairs(chans) do if #c > len then len = #c end end
  local left, right = {}, {}
  for i = 1, len do
    local l, r = 0, 0
    for k = 1, n do
      local v = chans[k][i] or 0
      l, r = l + gl[k] * v, r + gr[k] * v
    end
    left[i], right[i] = l * norm, r * norm
  end
  return { left, right }
end

-- Several channels, each rendered like M.render_job, one after the other; the progress covers all of them. `list` is an
-- array of data tables (all with the same frame grid). When done: job.channels (an array of sample arrays), job.samples (the
-- first one), job.sr, job.t_start; job.error and no samples if any channel failed.
function M.render_multi_job(list, opts)
  local job = { progress = 0, done = false }
  local index, sub = 1, nil
  job.channels = {}
  local function start_sub() sub = M.render_job(list[index], opts) end
  start_sub()
  function job.step(budget)
    if job.done then return true end
    local t_end = os.clock() + (budget or 0.03)
    while not job.done do
      local left = t_end - os.clock()
      if sub.step(math.max(left, 0.001)) then
        if not sub.samples then job.error, job.done = sub.error or "a channel failed", true; break end
        job.channels[index] = sub.samples
        if index == 1 then job.sr, job.t_start = sub.sr, sub.t_start end
        index = index + 1
        if index > #list then
          job.samples, job.progress, job.done = job.channels[1], 1, true
          break
        end
        start_sub()
      end
      job.progress = (index - 1 + sub.progress) / #list
      if os.clock() >= t_end then break end
    end
    return job.done
  end
  function job.cancel()
    if sub then sub.cancel() end
    job.done, job.cancelled = true, true
  end
  return job
end

-- Writes a 32-bit float WAV with one channel per array in `chans` (interleaved). Shorter channels are padded with silence.
function M.write_wav_channels(path, chans, sr)
  local nch = #chans
  local n = 0
  for _, c in ipairs(chans) do if #c > n then n = #c end end
  local fh, err = io.open(path, "wb")
  if not fh then return nil, "cannot write " .. tostring(path) .. ": " .. tostring(err) end
  local data_bytes = n * nch * 4
  fh:write("RIFF", string.pack("<I4", 36 + data_bytes), "WAVE")
  fh:write("fmt ", string.pack("<I4I2I2I4I4I2I2", 16, 3, nch, sr, sr * 4 * nch, 4 * nch, 32))
  fh:write("data", string.pack("<I4", data_bytes))
  local fmt = "<" .. string.rep("f", nch)
  local buf = {}
  for i = 1, n do
    local row = {}
    for c = 1, nch do row[c] = chans[c][i] or 0 end
    buf[#buf + 1] = string.pack(fmt, table.unpack(row, 1, nch))
    if #buf >= 2048 then fh:write(table.concat(buf)); buf = {} end
  end
  if #buf > 0 then fh:write(table.concat(buf)) end
  fh:close()
  return true
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
