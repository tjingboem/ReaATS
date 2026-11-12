-- ats_synth.lua -- renders ATS data (see ats_file.lua) to audio in pure Lua, so ReaATS does not need
-- Csound to be heard.
--
-- Method (the standard ATS resynthesis, described in the ATS papers and implemented in the BSD-3
-- licensed Python package pyatsyn, whose phase-less sine path this follows in structure -- see
-- THIRD-PARTY-NOTICES.md):
--   sines : one oscillator per partial; between two frames its amplitude changes linearly. WITH stored phases
--           (11 Nov 2026, tjingboem: "the one with phase ... pops out more, an oomph") every track is played with the
--           cubic phase of McAulay and Quatieri between its frames (add_sines_phase), the waveform of the original;
--           a track that an edit touched is rebuilt from its frequencies. WITHOUT stored phases (or with opts.phase =
--           false) the frequency changes linearly and the phase is the running sum of the frequency (add_sines).
--   noise : per critical band, white noise is band-limited and multiplied by that band's energy
--           envelope. The ATS file stores noise as energy per band; the amplitude of the band is
--           sqrt(energy / (window_size * 0.04)) (0.04 = the noise variance assumed by the ATS analysis).
--           The band-limiting here is a 4th-order Butterworth band-pass (two biquads), not a
--           brick-wall FFT filter, and the overall noise level is calibrated against Csound's own
--           ATS noise resynthesis (NOISE_GAIN below), so the two sound about equally loud.
-- Output is a Lua array of samples (floats, 1-based) and the sample rate.

local M = {}

local sin, cos, sqrt, floor, pi = math.sin, math.cos, math.sqrt, math.floor, math.pi
local TWO_PI = 2 * pi

M.NOISE_VARIANCE = 0.04       -- the variance the ATS analysis assumes for the noise (a property of the format)
M.NOISE_GAIN_CORRECTED = 0.20  -- with the bandwidth correction (the default): calibrated so that the noise has the power of the real residual
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

-- The sines with the phases stored in the file (the Lua twin of add_track_phase in python/reaats_synth.py; the method is described there):
-- a track (consecutive frames with an amplitude) is played with the cubic phase of McAulay and Quatieri between its frames, a cosine as in
-- pyatsyn; a track with an edited cell (dirty[p][f]) has its phases rebuilt from its frequencies, starting from its stored first phase (the rule of
-- ats_file.update_phases); at the start the sine fades in and at the end it fades out, at the frequency of its first and last frame.
local function add_sines_phase(d, out, n, k0, dirty)
  local fs = floor(d.frame_size + 0.5)
  local nf = d.frames
  local w_scale = TWO_PI / d.sr
  local rebuild_k = d.frame_size / d.sr * pi
  local T = fs
  for p = 1, d.partials do
    local amp, frq, pha, dp = d.amp[p], d.frq[p], d.pha and d.pha[p], dirty and dirty[p]
    local f = k0
    while f <= nf do
      if amp[f] > 0 then
        local f0 = f
        local touched = false
        while f <= nf and amp[f] > 0 do
          if dp and dp[f] then touched = true end
          f = f + 1
        end
        local f1 = f - 1
        -- frames f0 .. f1 (and the fade in front and behind): th, om, am
        local th, om, am, first = {}, {}, {}, f0
        local last_f
        local ok = true
        for i = f0, f1 do                                       -- a frequency of 0 takes the value of the nearest frame that has one
          local v = frq[i]
          if v <= 0 then
            v = last_f
            if not v then for j = i + 1, f1 do if frq[j] > 0 then v = frq[j]; break end end end
            if not v then ok = false; break end
          end
          om[#om + 1] = v
          last_f = v
        end
        if ok then
          local fr = om                                          -- (Hz, for the rebuild)
          local cnt = f1 - f0 + 1
          local tb = {}
          for j = 1, cnt do tb[j] = pha and pha[f0 + j - 1] or 0 end
          if touched then
            local ph = tb[1]
            for j = 2, cnt do ph = ph + (fr[j - 1] + fr[j]) * rebuild_k; tb[j] = ph end
          end
          local o, a = {}, {}
          for j = 1, cnt do o[j] = fr[j] * w_scale; a[j] = amp[f0 + j - 1] end
          local kb = f0
          if f0 - 1 >= k0 then                                    -- the fade in
            table.insert(tb, 1, tb[1] - o[1] * T); table.insert(o, 1, o[1]); table.insert(a, 1, 0)
            kb = f0 - 1
          end
          if f1 + 1 <= nf then                                    -- the fade out
            tb[#tb + 1] = tb[#tb] + o[#o] * T; o[#o + 1] = o[#o]; a[#a + 1] = 0
          end
          for s = 1, #tb - 1 do
            local base = (kb + s - 1 - k0) * fs
            if base >= n then break end
            local th0, th1, om0, om1, a0, a1 = tb[s], tb[s + 1], o[s], o[s + 1], a[s], a[s + 1]
            local m = floor(((th0 + om0 * T - th1) + (om1 - om0) * T / 2) / TWO_PI + 0.5)
            local dd = th1 - th0 - om0 * T + TWO_PI * m
            local alpha = 3 * dd / (T * T) - (om1 - om0) / T
            local beta = -2 * dd / (T * T * T) + (om1 - om0) / (T * T)
            local da = (a1 - a0) / T
            local count = T
            if base + count > n then count = n - base end
            for t = 0, count - 1 do
              out[base + t + 1] = out[base + t + 1] + (a0 + da * t) * cos(th0 + om0 * t + alpha * t * t + beta * t * t * t)
            end
          end
        end
      else
        f = f + 1
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

-- The filters of band b: high-pass at its lower edge (not for the first band) then low-pass at its upper edge, each 2nd order,
-- twice (a 4th-order Butterworth band-pass). Each stage keeps its own state.
local function band_stages(b, nyq, sr)
  local lo, hi = EDGES[b], math.min(EDGES[b + 1], nyq * 0.98)
  local stages = {}
  if lo > 0 then
    local b0, b1, b2, a1, a2 = biquad("hp", lo, sr)
    stages[#stages + 1] = { b0, b1, b2, a1, a2, 0, 0, 0, 0 }
    stages[#stages + 1] = { b0, b1, b2, a1, a2, 0, 0, 0, 0 }
  end
  local b0, b1, b2, a1, a2 = biquad("lp", hi, sr)
  stages[#stages + 1] = { b0, b1, b2, a1, a2, 0, 0, 0, 0 }
  stages[#stages + 1] = { b0, b1, b2, a1, a2, 0, 0, 0, 0 }
  return stages
end

-- The factor that makes band b's filtered noise have unit RMS. It only depends on the filter and the noise source, so it
-- is worked out once per sample rate: the output power of white noise through the filters is the variance of the source
-- times the sum of the squares of the filters' impulse response.
local band_norms = {}
local rng_variance = nil
local function band_norm(b, nyq, sr)
  local per_rate = band_norms[sr]
  if not per_rate then per_rate = {}; band_norms[sr] = per_rate end
  if per_rate[b] then return per_rate[b] end
  if not rng_variance then
    local rng, acc, N = make_rng(777), 0, 200000
    for _ = 1, N do local r = rng(); acc = acc + r * r end
    rng_variance = acc / N
  end
  local stages = band_stages(b, nyq, sr)
  local power = 0
  for i = 1, 16384 do
    local x = (i == 1) and 1 or 0
    for s = 1, #stages do
      local st = stages[s]
      local y = st[1] * x + st[2] * st[6] + st[3] * st[7] - st[4] * st[8] - st[5] * st[9]
      st[7], st[6] = st[6], x
      st[9], st[8] = st[8], y
      x = y
    end
    power = power + x * x
  end
  per_rate[b] = 1 / sqrt(power * rng_variance)
  return per_rate[b]
end

-- Adds the noise bands into out[1..n]. Only the stretches where a band sounds are made (a band's silent frames cost
-- nothing); the filters start from rest at the beginning of each stretch, where the envelope is zero anyway. The four filter
-- stages and the noise source are written out in the inner loop with local variables: it runs millions of times.
local function add_noise(d, out, n, seed, k0, shape)
  local fs = floor(d.frame_size + 0.5)
  local nyq = d.sr / 2
  local rs = seed or 12345                                          -- the state of make_rng's generator
  local corrected = (shape ~= "classic")
  local amp_scale = (corrected and M.NOISE_GAIN_CORRECTED or M.NOISE_GAIN) / sqrt(d.window_size * M.NOISE_VARIANCE)
  local last = d.frames - 1
  -- Bandwidth correction: the analysis stores for every band the AVERAGE squared magnitude of its FFT bins (equalised so that the bands
  -- add up to the energy of the residual), not the energy of the band. Played as it is, the noise is too loud in the narrow low bands
  -- and too soft in the wide high ones. Every band's power is multiplied by its width over the energy-weighted mean width of that
  -- frame: the energy of a frame stays what it was and the bands get their right share of it.
  local width, wbar = {}, {}
  for b = 1, 25 do width[b] = math.max(math.min(EDGES[b + 1], nyq) - EDGES[b], 0) end
  if corrected then
    for k = k0, d.frames do
      local se, sw = 0, 0
      for b = 1, 25 do
        local e = d.noise[b][k]
        if e > 0 then se, sw = se + e, sw + e * width[b] end
      end
      wbar[k] = (se > 0) and (sw / se) or 1
    end
  end
  local c10, c11, c12, c13, c14, xa1, xb1, ya1, yb1
  local c20, c21, c22, c23, c24, xa2, xb2, ya2, yb2
  local c30, c31, c32, c33, c34, xa3, xb3, ya3, yb3
  local c40, c41, c42, c43, c44, xa4, xb4, ya4, yb4
  for b = 1, 25 do
    local nb = d.noise[b]
    if EDGES[b] < nyq * 0.98 then
      local stages = band_stages(b, nyq, d.sr)
      while #stages < 4 do table.insert(stages, 1, { 1, 0, 0, 0, 0, 0, 0, 0, 0 }) end     -- the first band has no high-pass: pass-through stages
      c10, c11, c12, c13, c14 = table.unpack(stages[1], 1, 5)
      c20, c21, c22, c23, c24 = table.unpack(stages[2], 1, 5)
      c30, c31, c32, c33, c34 = table.unpack(stages[3], 1, 5)
      c40, c41, c42, c43, c44 = table.unpack(stages[4], 1, 5)
      local norm = band_norm(b, nyq, d.sr) * amp_scale
      local wb = width[b]
      local k = k0
      while k <= last do
        if nb[k] > 0 or nb[k + 1] > 0 then
          local k_end = k                                        -- the run of sounding segments k .. k_end
          while k_end + 1 <= last and (nb[k_end + 1] > 0 or nb[k_end + 2] > 0) do k_end = k_end + 1 end
          if (k - k0) * fs >= n then break end
          xa1, xb1, ya1, yb1 = 0, 0, 0, 0
          xa2, xb2, ya2, yb2 = 0, 0, 0, 0
          xa3, xb3, ya3, yb3 = 0, 0, 0, 0
          xa4, xb4, ya4, yb4 = 0, 0, 0, 0
          for kk = k, k_end do
            local base = (kk - k0) * fs
            if base >= n then break end
            local count = fs
            if base + count > n then count = n - base end
            local a0, a1
            if corrected then
              a0, a1 = sqrt(nb[kk] * wb / wbar[kk]) * norm, sqrt(nb[kk + 1] * wb / wbar[kk + 1]) * norm
            else
              a0, a1 = sqrt(nb[kk]) * norm, sqrt(nb[kk + 1]) * norm
            end
            local a, da = a0, (a1 - a0) / fs
            for i = base + 1, base + count do
              rs = (rs * 1103515245 + 12345) % 2147483648
              local x = rs / 1073741824 - 1
              local y
              y = c10 * x + c11 * xa1 + c12 * xb1 - c13 * ya1 - c14 * yb1
              xb1, xa1, yb1, ya1 = xa1, x, ya1, y
              x = y
              y = c20 * x + c21 * xa2 + c22 * xb2 - c23 * ya2 - c24 * yb2
              xb2, xa2, yb2, ya2 = xa2, x, ya2, y
              x = y
              y = c30 * x + c31 * xa3 + c32 * xb3 - c33 * ya3 - c34 * yb3
              xb3, xa3, yb3, ya3 = xa3, x, ya3, y
              x = y
              y = c40 * x + c41 * xa4 + c42 * xb4 - c43 * ya4 - c44 * yb4
              xb4, xa4, yb4, ya4 = xa4, x, ya4, y
              x = y
              out[i] = out[i] + a * x
              a = a + da
            end
            if kk % 16 == 0 then tick((b - 1 + (kk - k0) / math.max(last - k0 + 1, 1)) / 25) end
          end
          k = k_end + 1
        else
          k = k + 1
        end
      end
    end
    tick(b / 25)
  end
end

-- The noise does not depend on the partials, so it is made once and kept (in the data table, d.noise_cache) while you edit
-- and audition again. A cached stretch is reused when the new request lies inside it. ANYTHING THAT CHANGES d.noise MUST SET
-- d.noise_cache = nil. A global limit keeps the memory in check: the oldest caches are dropped first.
local CACHE_LIMIT = 12000000                      -- samples in all caches together (a Lua number takes 16 bytes)
local cache_log = {}
local function drop_old_caches(keep)
  local total = 0
  local alive = {}
  for _, e in ipairs(cache_log) do
    local d = e.ref[1]
    if d and d.noise_cache == e.entry then alive[#alive + 1] = e; total = total + e.entry.n end
  end
  while total > CACHE_LIMIT and #alive > 1 do
    local e = table.remove(alive, 1)
    if e.entry ~= keep then
      if e.ref[1] then e.ref[1].noise_cache = nil end
      total = total - e.entry.n
    end
  end
  cache_log = alive
end

-- Returns the noise array and the offset to add to the index (sample i of the request is nz[off + i]).
local function noise_signal(d, n, seed, k0, shape)
  local fs = floor(d.frame_size + 0.5)
  seed = seed or 12345
  shape = shape or "corrected"
  local c = d.noise_cache
  if c and c.seed == seed and c.shape == shape and c.k0 <= k0 and (k0 - c.k0) * fs + n <= c.n then
    return c.nz, (k0 - c.k0) * fs, true
  end
  local nz = {}
  for i = 1, n do nz[i] = 0 end
  add_noise(d, nz, n, seed, k0, shape)
  local entry = { seed = seed, shape = shape, k0 = k0, n = n, nz = nz }
  d.noise_cache = entry
  cache_log[#cache_log + 1] = { ref = setmetatable({ d }, { __mode = "v" }), entry = entry }
  drop_old_caches(entry)
  return nz, 0, false
end

-- Renders d. opts: sines (default true), noise (default true; needs noise data), seed, from (seconds: start there; the start
-- is moved back to the beginning of its frame; to: stop at this time). Returns samples (a 1-based Lua array), the sample rate and the time in the
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
  if opts.to and opts.to > 0 then n = math.min(n, floor(opts.to * d.sr) - (k0 - 1) * fs) end       -- stop at `to` seconds
  if n < 1 then return nil, "nothing to play after this point" end
  local out = {}
  for i = 1, n do out[i] = 0 end
  local both = use_sines and use_noise
  if use_sines then
    base, span = 0, both and 0.15 or 1
    if d.has_phase and d.pha and opts.phase ~= false then add_sines_phase(d, out, n, k0, opts.dirty) else add_sines(d, out, n, k0) end
  end
  if use_noise then
    base, span = both and 0.15 or 0, both and 0.85 or 1
    local nz, off = noise_signal(d, n, opts.seed, k0, opts.noise_shape)
    for i = 1, n do out[i] = out[i] + nz[off + i] end
    tick(1)
  end
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
  local function start_sub()                                      -- (opts.dirty_list[i]: the cells that were edited in channel i, for the phase)
    sub = M.render_job(list[index], setmetatable({ dirty = opts.dirty_list and opts.dirty_list[index] }, { __index = opts }))
  end
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
-- Turns the channels (arrays of samples) down, all by the same gain, when the highest peak is above `limit_db` (dBFS, default -1). Returns the gain in dB
-- (0 when nothing was done). A quieter sound is not turned up. The same rule as the Python program (--peak-limit).
function M.limit_peak(chans, limit_db)
  limit_db = limit_db or -1.0
  local peak = 0
  for _, c in ipairs(chans) do
    for i = 1, #c do local v = c[i]; if v < 0 then v = -v end; if v > peak then peak = v end end
  end
  local ceiling = 10 ^ (limit_db / 20)
  if peak <= ceiling or peak <= 0 then return 0 end
  local g = ceiling / peak
  for _, c in ipairs(chans) do for i = 1, #c do c[i] = c[i] * g end end
  return 20 * math.log(g, 10)
end
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
