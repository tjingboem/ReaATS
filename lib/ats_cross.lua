-- ats_cross.lua -- CROSS: sound A flows into sound B (tjingboem, 13 Nov 2026). Pure Lua, no REAPER calls.
--
-- Two sounds on equal terms, each a block on one timeline (`pos` = where the used part starts on the timeline, [t0, t1] = the used part of the file, the grey
-- box of the CROSS page). Where the used parts overlap there is the TRANSITION SPACE. A red line (vertical, `line` seconds on the timeline) sits inside it; the
-- grey area round it (`tol_time` seconds wide) is where both sounds overlap gradually. Before the grey area only the sound that starts first (L) sounds, after it
-- only the other (R); without an overlap nothing is faded: L, then R.
--   * Partials with no partner fade out (L) or in (R) on their own frequency, with equal-power weights cos / sin of the smooth step s(t).
--   * A PAIR is one L track (that goes on from before the grey area) and one R track (that goes on after it) that sound together for a few frames inside the
--     grey area and stay within `tol_cents` of each other on average there (one pair per track, the nearest first). They need not sound through the whole grey area. A pair is ONE THREAD: the partial of L until the grey area, then, in the grey area, a partial whose frequency moves from L's to
--     R's (in semitones: fL^(1-s) * fR^s) and whose level moves linearly from L's to R's, then the partial of R. Nobody is pulled onto the other: at the end R is
--     exactly on its own frequency. Shared frequencies are not made louder.
--   * The noise bands of both sounds are crossfaded with the same weights (squared, they are energies); the stored energy depends on the window size, so each
--     file's energy is converted to the window of sound A: E * window_A / window_file.
--   * The files may differ in hop, sample rate, window size, number of partials and type: both are resampled onto one frame grid (the smaller hop) by linear
--     interpolation of amplitude and frequency; phases are rebuilt from the frequencies afterwards (ats_file.update_phases).
-- The result is a new data table (type 4) with the tracks packed into as few rows as possible.
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
local ats = dofile(here .. "/ats_file.lua")

local M = {}

local LOG, EXP, PI = math.log, math.exp, math.pi
local LOG2 = LOG(2)
local NB = ats.NUM_NOISE_BANDS
local MIN_TOGETHER = 3                              -- frames that a partial of A and a partial of B must sound together inside the grey area to be one thread

local function clamp(x, lo, hi) if x < lo then return lo elseif x > hi then return hi end return x end

-- One side resampled onto the result grid: { amp[p][f], frq[p][f], noise[b][f] or nil } (zeros where the sound does not sound).
local function resample(side, grid)
  local d = side.d
  local F, hop, t_start = grid.F, grid.hop, grid.t_start
  local n, times = d.frames, d.times
  local amp, frq, noise = {}, {}, nil
  for p = 1, d.partials do amp[p], frq[p] = {}, {} end
  if d.has_noise then noise = {}; for b = 1, NB do noise[b] = {} end end
  local nscale = grid.window / d.window_size
  local gain = side.gain or 1                                         -- the level of this sound (a factor on the amplitudes, its square on the noise energy)
  local ngain = gain * gain
  local i = 1
  for f = 1, F do
    local ts = (t_start + (f - 1) * grid.hop) - side.pos + side.t0
    if ts < side.t0 - 1e-9 or ts > side.t1 + 1e-9 or ts < times[1] - 1e-9 or ts > times[n] + 1e-9 then
      for p = 1, d.partials do amp[p][f], frq[p][f] = 0, 0 end
      if noise then for b = 1, NB do noise[b][f] = 0 end end
    else
      while i < n - 1 and times[i + 1] <= ts do i = i + 1 end
      local j, u = i + 1, 0
      if j > n then j = n else u = clamp((ts - times[i]) / math.max(times[j] - times[i], 1e-12), 0, 1) end
      for p = 1, d.partials do
        local ap, fp = d.amp[p], d.frq[p]
        local a0, a1 = ap[i], ap[j]
        local a, fr = 0, 0
        if a0 > 0 and a1 > 0 then a, fr = a0 + (a1 - a0) * u, fp[i] + (fp[j] - fp[i]) * u
        elseif a0 > 0 then a, fr = a0 * (1 - u), fp[i]
        elseif a1 > 0 then a, fr = a1 * u, fp[j] end
        if a <= 0 then a, fr = 0, 0 end
        amp[p][f], frq[p][f] = a * gain, fr
      end
      if noise then
        for b = 1, NB do
          local nb = d.noise[b]
          noise[b][f] = (nb[i] + (nb[j] - nb[i]) * u) * nscale * ngain
        end
      end
    end
  end
  return { amp = amp, frq = frq, noise = noise, partials = d.partials }
end

-- The runs of sound of every row: { p, f0, f1, fm } (fm = the mean frequency in Hz, geometric).
local function tracks_of(rs, F)
  local out = {}
  for p = 1, rs.partials do
    local a, fq = rs.amp[p], rs.frq[p]
    local f = 1
    while f <= F do
      if a[f] > 0 then
        local f0, sum = f, 0
        while f <= F and a[f] > 0 do sum = sum + LOG(fq[f]); f = f + 1 end
        out[#out + 1] = { p = p, f0 = f0, f1 = f - 1, fm = EXP(sum / (f - f0)) }
      else
        f = f + 1
      end
    end
  end
  return out
end

-- The shape of the crossover s over the grey area (x runs 0..1) and the weights of a partial without a partner. `curve`:
--   "smooth" (the default): s is a cosine step, the weights are equal-power (cos / sin of s); "linear": s is a straight ramp, the weights 1-s and s;
--   "equal": s is a straight ramp, equal-power weights, and the level of a thread also follows cos / sin (louder in the middle where both sound);
--   "s": a steeper S (smootherstep): little happens at the ends, the change is quick in the middle.
local function shape_s(curve, x)
  if curve == "linear" or curve == "equal" then return x
  elseif curve == "s" then return x * x * x * (x * (6 * x - 15) + 10) end
  return (1 - math.cos(PI * x)) / 2
end
M.shape = shape_s                                                   -- (the CROSS page draws the curve in the grey area)
local function weights(curve, sv)
  if curve == "linear" then return 1 - sv, sv end
  return math.cos(PI / 2 * sv), math.sin(PI / 2 * sv)
end

-- spec = { a = { d, t0, t1, pos }, b = { d, t0, t1, pos }, line = seconds on the timeline, tol_time = seconds, tol_cents = cents }
-- Returns the data table of the result and an info table: { rows, frames, hop, pairs, overlap, line, grey0, grey1, ov0, ov1, t_start, threads = { {p, f0, f1} } }
-- (times in the result's own time, from 0; t_start = where that 0 lies on the timeline; the threads are rows and frames of the result).
function M.build(spec)
  local A, B = spec.a, spec.b
  for _, s in ipairs({ A, B }) do
    s.t0 = math.max(s.t0 or s.d.times[1], s.d.times[1])
    s.t1 = math.min(s.t1 or s.d.times[s.d.frames], s.d.times[s.d.frames])
    if s.t1 <= s.t0 then return nil, "the used part of a sound is empty" end
  end
  local L, R = A, B                                                 -- the sound that starts first flows into the other
  if B.pos < A.pos then L, R = B, A end
  local endL, endR = L.pos + (L.t1 - L.t0), R.pos + (R.t1 - R.t0)
  local t_start, t_end = math.min(L.pos, R.pos), math.max(endL, endR)
  local hop = math.min(A.d.frame_size / A.d.sr, B.d.frame_size / B.d.sr)
  local sr = math.max(A.d.sr, B.d.sr)
  local frame_size = math.max(1, math.floor(hop * sr + 0.5))
  hop = frame_size / sr
  local F = math.max(2, math.floor((t_end - t_start) / hop + 1e-9) + 1)
  local grid = { F = F, hop = hop, t_start = t_start, window = A.d.window_size }
  local rL, rR = resample(L, grid), resample(R, grid)

  -- the crossover: s = 0 before the grey area, 1 after it, a step (spec.curve) inside. A vertical red line (`spec.line`) crosses every partial at the same moment;
  -- with `spec.diag` = { t1, f1, t2, f2 } (a point low and a point high in the picture: seconds on the timeline, Hz) the moment follows the line: a partial
  -- crosses where the line passes its (mean) frequency, so the low ones can go first. Tracks and noise bands each take the profile of their own moment.
  local curve = spec.curve or "smooth"
  local ov0, ov1 = R.pos, math.min(endL, endR)
  local overlap = ov1 > ov0 + 1e-9
  local diag = spec.diag
  local tc_v, w_time = nil, math.max(spec.tol_time or 0, 0)
  if overlap then tc_v = clamp(spec.line or (ov0 + ov1) / 2, ov0, ov1) end
  local function tc_at(freq)
    if not diag then return tc_v end
    local lf1, lf2 = LOG(diag[2]), LOG(diag[4])
    local x = (lf2 ~= lf1) and clamp((LOG(math.max(freq, 1)) - lf1) / (lf2 - lf1), 0, 1) or 0
    return clamp(diag[1] + (diag[3] - diag[1]) * x, ov0, ov1)
  end
  local profiles = {}
  local function profile(tc)
    local key = 0
    if diag then
      key = math.floor((tc - ov0) / math.max(ov1 - ov0, 1e-9) * 63 + 0.5)
      tc = ov0 + key / 63 * (ov1 - ov0)
    end
    local pr = profiles[key]
    if pr then return pr end
    local g0, g1 = math.max(tc - w_time / 2, ov0), math.min(tc + w_time / 2, ov1)
    local hard = (g1 - g0) < hop
    pr = { tc = tc, g0 = g0, g1 = g1, hard = hard, s = {}, wL = {}, wR = {} }
    for f = 1, F do
      local t = t_start + (f - 1) * hop
      local sv
      if hard then sv = (t >= tc) and 1 or 0
      elseif t <= g0 then sv = 0
      elseif t >= g1 then sv = 1
      else sv = shape_s(curve, (t - g0) / (g1 - g0)) end
      pr.s[f] = sv
      local wl, wr = weights(curve, sv)
      pr.wL[f] = (sv >= 1) and 0 or wl
      pr.wR[f] = (sv <= 0) and 0 or wr
    end
    if not hard then
      pr.g0f = math.ceil((g0 - t_start) / hop - 1e-9) + 1
      pr.g1f = math.floor((g1 - t_start) / hop + 1e-9) + 1
    end
    profiles[key] = pr
    return pr
  end
  local ones = {}
  for f = 1, F do ones[f] = 1 end
  local function profile_of(freq) if overlap then return profile(tc_at(freq)) end return { wL = ones, wR = ones } end

  local tL, tR = tracks_of(rL, F), tracks_of(rR, F)
  local out = {}                                                       -- the tracks of the result: { f0, amp = {}, frq = {} } (index f - f0 + 1)
  local pair_count = 0
  local used_L, used_R = {}, {}
  local pair_info = {}                                                 -- for the CROSS page: where each thread is (seconds on the timeline, Hz)
  if overlap then
    local cands = {}
    for li, tl in ipairs(tL) do
      local pr = profile(tc_at(tl.fm))
      if pr.g0f and pr.g1f and pr.g1f >= pr.g0f and tl.f0 <= pr.g0f then   -- the partial of L that goes on from before the grey area ...
        local g0f, g1f = pr.g0f, pr.g1f
        for ri, tr in ipairs(tR) do
          if tr.f1 >= g1f and tr.f0 <= g1f then                       -- ... and the partial of R that goes on after it
            local lo, hi = math.max(tl.f0, tr.f0, g0f), math.min(tl.f1, tr.f1, g1f)
            if hi - lo + 1 >= MIN_TOGETHER then                       -- they sound together for a few frames inside the grey area
              local sum = 0
              for f = lo, hi do sum = sum + math.abs(1200 * LOG(rR.frq[tr.p][f] / rL.frq[tl.p][f]) / LOG2) end
              local mean = sum / (hi - lo + 1)
              if mean <= (spec.tol_cents or 100) then cands[#cands + 1] = { li = li, ri = ri, cents = mean, lo = lo, hi = hi } end
            end
          end
        end
      end
    end
    table.sort(cands, function(a, b) if a.cents ~= b.cents then return a.cents < b.cents end if a.li ~= b.li then return a.li < b.li end return a.ri < b.ri end)
    for _, c in ipairs(cands) do
      if not used_L[c.li] and not used_R[c.ri] then
        used_L[c.li], used_R[c.ri] = true, true
        pair_count = pair_count + 1
        local tl, tr = tL[c.li], tR[c.ri]
        local pr = profile(tc_at(tl.fm))
        local g0f, g1f = pr.g0f, pr.g1f
        pair_info[#pair_info + 1] = { fl = rL.frq[tl.p][c.lo], fr = rR.frq[tr.p][c.hi], t0 = t_start + (g0f - 1) * hop, t1 = t_start + (g1f - 1) * hop }
        if not spec.count_only then
          local mt = { f0 = tl.f0, amp = {}, frq = {}, thread = true }
          for f = tl.f0, tr.f1 do
            local a, fr
            if f < g0f then a, fr = rL.amp[tl.p][f], rL.frq[tl.p][f]
            elseif f <= g1f then
              -- inside the grey area: the level moves from L's to R's (a side that does not sound there counts as 0; linear, or cos / sin for the curve "equal"),
              -- the frequency moves in semitones while both sound, and is the one that sounds when only one does
              local sf = pr.s[f]
              local aL = (f >= tl.f0 and f <= tl.f1) and rL.amp[tl.p][f] or 0
              local aR = (f >= tr.f0 and f <= tr.f1) and rR.amp[tr.p][f] or 0
              if curve == "equal" then a = math.cos(PI / 2 * sf) * aL + math.sin(PI / 2 * sf) * aR
              else a = (1 - sf) * aL + sf * aR end
              if aL > 0 and aR > 0 then fr = EXP((1 - sf) * LOG(rL.frq[tl.p][f]) + sf * LOG(rR.frq[tr.p][f]))
              elseif aL > 0 then fr = rL.frq[tl.p][f]
              elseif aR > 0 then fr = rR.frq[tr.p][f]
              else fr = 0 end
              if a <= 0 then a, fr = 0, 0 end
            else a, fr = rR.amp[tr.p][f], rR.frq[tr.p][f] end
            mt.amp[f - tl.f0 + 1], mt.frq[f - tl.f0 + 1] = a, fr
          end
          out[#out + 1] = mt
        end
      end
    end
  end
  if spec.count_only then return nil, { pairs = pair_count, threads = pair_info, l_is_a = (L == A) } end
  local function weighted(tr, rs, which, used)
    for k, t in ipairs(tr) do
      if not used[k] then
        local w = profile_of(t.fm)[which]
        local f0, f1 = t.f0, t.f1
        while f0 <= f1 and w[f0] <= 0 do f0 = f0 + 1 end
        while f1 >= f0 and w[f1] <= 0 do f1 = f1 - 1 end
        if f1 >= f0 then
          local mt = { f0 = f0, amp = {}, frq = {} }
          for f = f0, f1 do mt.amp[f - f0 + 1], mt.frq[f - f0 + 1] = rs.amp[t.p][f] * w[f], rs.frq[t.p][f] end
          out[#out + 1] = mt
        end
      end
    end
  end
  weighted(tL, rL, "wL", used_L)
  weighted(tR, rR, "wR", used_R)

  -- pack the tracks into rows (a row is reused when the next track starts at least 2 frames after the last one ended)
  table.sort(out, function(a, b) return a.f0 < b.f0 end)
  local rows_end, row_of = {}, {}
  for k, t in ipairs(out) do
    local f1 = t.f0 + #t.amp - 1
    local r = nil
    for i = 1, #rows_end do if rows_end[i] + 2 <= t.f0 then r = i; break end end
    if not r then r = #rows_end + 1 end
    rows_end[r] = f1
    row_of[k] = r
  end
  local P = math.max(#rows_end, 1)
  local d = { sr = sr, frame_size = frame_size, window_size = A.d.window_size, partials = P, frames = F, dur = math.max(t_end - t_start, (F - 1) * hop),
              has_phase = false, has_noise = false, amp = {}, frq = {}, times = {}, noise_max = 0 }
  for f = 1, F do d.times[f] = (f - 1) * hop end
  for p = 1, P do
    local a, fr = {}, {}
    for f = 1, F do a[f], fr[f] = 0, 0 end
    d.amp[p], d.frq[p] = a, fr
  end
  for k, t in ipairs(out) do
    local a, fr = d.amp[row_of[k]], d.frq[row_of[k]]
    for i = 1, #t.amp do a[t.f0 + i - 1], fr[t.f0 + i - 1] = t.amp[i], t.frq[i] end
  end
  if rL.noise or rR.noise then
    d.has_noise, d.noise = true, {}
    local edges = ats.CRITICAL_BAND_EDGES
    for b = 1, NB do
      local nb = {}
      local pr = profile_of(math.sqrt(math.max(edges[b], 20) * math.max(edges[b + 1] or edges[b] * 1.2, 40)))     -- (a noise band crosses at the moment of its own frequency)
      local wL, wR = pr.wL, pr.wR
      for f = 1, F do
        local v = 0
        if rL.noise then v = v + wL[f] * wL[f] * rL.noise[b][f] end
        if rR.noise then v = v + wR[f] * wR[f] * rR.noise[b][f] end
        nb[f] = v
        if v > d.noise_max then d.noise_max = v end
      end
      d.noise[b] = nb
    end
  end
  ats.update_phases(d, nil)                                            -- (no phase in the data yet: every track gets its phases from its frequencies)
  local info = { rows = P, frames = F, hop = hop, pairs = pair_count, overlap = overlap, tracks = #out, t_start = t_start, threads = {} }
  for k, t in ipairs(out) do                                           -- the partials that carry the transition (the editor blinks them)
    if t.thread then info.threads[#info.threads + 1] = { p = row_of[k], f0 = t.f0, f1 = t.f0 + #t.amp - 1 } end
  end
  if overlap then
    local mid = profile(tc_at(diag and math.sqrt(diag[2] * diag[4]) or 1))
    info.line, info.grey0, info.grey1, info.ov0, info.ov1 = mid.tc - t_start, mid.g0 - t_start, mid.g1 - t_start, ov0 - t_start, ov1 - t_start
    if diag then info.diag = { diag[1] - t_start, diag[2], diag[3] - t_start, diag[4] } end
  end
  return d, info
end

-- How many threads a setting would make (no result is built; the same pairing as M.build). Returns the info { pairs }, or nil and a message.
function M.count(spec)
  spec.count_only = true
  local d, info = M.build(spec)
  spec.count_only = nil
  if d == nil and type(info) == "table" then return info end
  return nil, info
end

-- Builds the result and writes it as a type 4 file. Returns the info, or nil and a message.
function M.make(spec, path)
  local d, info = M.build(spec)
  if not d then return nil, info end
  local ok, err = ats.save(path, d, { phase = true })
  if not ok then return nil, err end
  return info
end

return M
