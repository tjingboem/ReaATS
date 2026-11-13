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
        amp[p][f], frq[p][f] = a, fr
      end
      if noise then
        for b = 1, NB do
          local nb = d.noise[b]
          noise[b][f] = (nb[i] + (nb[j] - nb[i]) * u) * nscale
        end
      end
    end
  end
  return { amp = amp, frq = frq, noise = noise, partials = d.partials }
end

-- The runs of sound of every row: { p, f0, f1 }.
local function tracks_of(rs, F)
  local out = {}
  for p = 1, rs.partials do
    local a = rs.amp[p]
    local f = 1
    while f <= F do
      if a[f] > 0 then
        local f0 = f
        while f <= F and a[f] > 0 do f = f + 1 end
        out[#out + 1] = { p = p, f0 = f0, f1 = f - 1 }
      else
        f = f + 1
      end
    end
  end
  return out
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

  -- the crossover: s(f) = 0 before the grey area, 1 after it, a smooth step inside
  local ov0, ov1 = R.pos, math.min(endL, endR)
  local overlap = ov1 > ov0 + 1e-9
  local g0, g1, hard, tc
  local s = {}
  if overlap then
    tc = clamp(spec.line or (ov0 + ov1) / 2, ov0, ov1)
    local w = math.max(spec.tol_time or 0, 0)
    g0, g1 = math.max(tc - w / 2, ov0), math.min(tc + w / 2, ov1)
    hard = (g1 - g0) < hop
    for f = 1, F do
      local t = t_start + (f - 1) * hop
      if hard then s[f] = (t >= tc) and 1 or 0
      elseif t <= g0 then s[f] = 0
      elseif t >= g1 then s[f] = 1
      else s[f] = (1 - math.cos(PI * (t - g0) / (g1 - g0))) / 2 end
    end
  end
  local wL, wR = {}, {}
  for f = 1, F do
    if overlap then
      wL[f] = (s[f] >= 1) and 0 or math.cos(PI / 2 * s[f])
      wR[f] = (s[f] <= 0) and 0 or math.sin(PI / 2 * s[f])
    else
      wL[f], wR[f] = 1, 1
    end
  end

  local tL, tR = tracks_of(rL, F), tracks_of(rR, F)
  -- the thread frames: first frame at or after g0 .. last frame at or before g1
  local g0f, g1f
  if overlap and not hard then
    g0f = math.ceil((g0 - t_start) / hop - 1e-9) + 1
    g1f = math.floor((g1 - t_start) / hop + 1e-9) + 1
  end
  local out = {}                                                       -- the tracks of the result: { f0, amp = {}, frq = {} } (index f - f0 + 1)
  local pair_count = 0
  local used_L, used_R = {}, {}
  if g0f and g1f and g1f >= g0f then
    local cands = {}
    for li, tl in ipairs(tL) do
      if tl.f0 <= g0f then                                             -- the partial of L that goes on from before the grey area ...
        for ri, tr in ipairs(tR) do
          if tr.f1 >= g1f and tr.f0 <= g1f then                       -- ... and the partial of R that goes on after it
            local lo, hi = math.max(tl.f0, tr.f0, g0f), math.min(tl.f1, tr.f1, g1f)
            if hi - lo + 1 >= MIN_TOGETHER then                       -- they sound together for a few frames inside the grey area
              local sum = 0
              for f = lo, hi do sum = sum + math.abs(1200 * LOG(rR.frq[tr.p][f] / rL.frq[tl.p][f]) / LOG2) end
              local mean = sum / (hi - lo + 1)
              if mean <= (spec.tol_cents or 100) then cands[#cands + 1] = { li = li, ri = ri, cents = mean } end
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
        if not spec.count_only then
          local tl, tr = tL[c.li], tR[c.ri]
          local mt = { f0 = tl.f0, amp = {}, frq = {}, thread = true }
          for f = tl.f0, tr.f1 do
            local a, fr
            if f < g0f then a, fr = rL.amp[tl.p][f], rL.frq[tl.p][f]
            elseif f <= g1f then
              -- inside the grey area: the level moves linearly from L's to R's (a side that does not sound there counts as 0), the frequency moves in
              -- semitones while both sound, and is the one that sounds when only one does
              local sf = s[f]
              local aL = (f >= tl.f0 and f <= tl.f1) and rL.amp[tl.p][f] or 0
              local aR = (f >= tr.f0 and f <= tr.f1) and rR.amp[tr.p][f] or 0
              a = (1 - sf) * aL + sf * aR
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
  if spec.count_only then return nil, { pairs = pair_count } end
  local function weighted(tr, rs, w, used)
    for k, t in ipairs(tr) do
      if not used[k] then
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
  weighted(tL, rL, wL, used_L)
  weighted(tR, rR, wR, used_R)

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
    for b = 1, NB do
      local nb = {}
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
  if overlap then info.line, info.grey0, info.grey1, info.ov0, info.ov1 = tc - t_start, g0 - t_start, g1 - t_start, ov0 - t_start, ov1 - t_start end
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
