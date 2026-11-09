-- ats_edit.lua -- pure editing logic for ATS data (no REAPER calls, so it can be tested with plain Lua).
-- A selection is sel[p] = { [frame] = true }: partial p at that frame.

local M = {}

local function clamp(x, a, b) if x < a then return a elseif x > b then return b else return x end end

-- Appends n silent partial rows to d.
function M.add_rows(d, n)
  for _ = 1, n do
    local P = d.partials + 1
    d.amp[P], d.frq[P] = {}, {}
    if d.has_phase then d.pha[P] = {} end
    for f = 1, d.frames do
      d.amp[P][f], d.frq[P][f] = 0, 0
      if d.has_phase then d.pha[P][f] = 0 end
    end
    d.partials = P
  end
end

-- Removes rows beyond `n`.
function M.truncate_rows(d, n)
  for P = d.partials, n + 1, -1 do
    d.amp[P], d.frq[P] = nil, nil
    if d.has_phase then d.pha[P] = nil end
  end
  d.partials = math.min(d.partials, n)
end

-- The length of the file: appends k silent frames (every partial 0, the noise bands 0) after the last one, with the same spacing in time,
-- and makes the duration longer by k frames. All the channels of a set must be made equally long (the same frame grid).
function M.add_frames(d, k)
  local NF = d.frames
  local hop = d.frame_size / d.sr
  for f = NF + 1, NF + k do d.times[f] = d.times[NF] + (f - NF) * hop end
  for p = 1, d.partials do
    local amp, frq, pha = d.amp[p], d.frq[p], d.has_phase and d.pha[p] or nil
    for f = NF + 1, NF + k do
      amp[f], frq[f] = 0, 0
      if pha then pha[f] = 0 end
    end
  end
  if d.has_noise then
    for b = 1, #d.noise do for f = NF + 1, NF + k do d.noise[b][f] = 0 end end
  end
  d.frames = NF + k
  d.dur = d.dur + k * hop
end

-- Takes the frames after frame n away again (the way back of add_frames); `dur` is the duration to go back to.
function M.truncate_frames(d, n, dur)
  for f = d.frames, n + 1, -1 do d.times[f] = nil end
  for p = 1, d.partials do
    local amp, frq, pha = d.amp[p], d.frq[p], d.has_phase and d.pha[p] or nil
    for f = d.frames, n + 1, -1 do
      amp[f], frq[f] = nil, nil
      if pha then pha[f] = nil end
    end
  end
  if d.has_noise then
    for b = 1, #d.noise do for f = d.frames, n + 1, -1 do d.noise[b][f] = nil end end
  end
  d.frames = n
  if dur then d.dur = dur end
end

-- Makes the file longer AT THE START: k silent frames in front, so that everything in the file moves k frames later (frame f becomes
-- frame f + k). The first time stays where it was, the duration grows by k frames. Used when a stretch goes before 0.
function M.prepend_frames(d, k)
  local NF = d.frames
  local hop = d.frame_size / d.sr
  local function shifted(old)
    local new = {}
    for i = 1, k do new[i] = 0 end
    table.move(old, 1, NF, k + 1, new)
    return new
  end
  for p = 1, d.partials do
    d.amp[p], d.frq[p] = shifted(d.amp[p]), shifted(d.frq[p])
    if d.has_phase then d.pha[p] = shifted(d.pha[p]) end
  end
  if d.has_noise then for b = 1, #d.noise do d.noise[b] = shifted(d.noise[b]) end end
  local t1 = d.times[1]
  d.times = {}
  for f = 1, NF + k do d.times[f] = t1 + (f - 1) * hop end
  d.frames = NF + k
  d.dur = d.dur + k * hop
  d.front_frames = (d.front_frames or 0) + k                        -- (how many frames the file on disk is behind: for the synthesis of an unsaved edit)
end

-- The way back of prepend_frames: takes the first k frames away (frame f becomes f - k); `dur` is the duration to go back to.
function M.drop_front(d, k, dur)
  local NF = d.frames
  local function cut(arr)
    table.move(arr, k + 1, NF, 1)
    for i = NF - k + 1, NF do arr[i] = nil end
  end
  for p = 1, d.partials do
    cut(d.amp[p]); cut(d.frq[p])
    if d.has_phase then cut(d.pha[p]) end
  end
  if d.has_noise then for b = 1, #d.noise do cut(d.noise[b]) end end
  local t1 = d.times[1]
  for f = 1, NF - k do d.times[f] = t1 + (f - 1) * (d.frame_size / d.sr) end
  for f = NF - k + 1, NF do d.times[f] = nil end
  d.frames = NF - k
  if dur then d.dur = dur end
  d.front_frames = math.max((d.front_frames or 0) - k, 0)
end

-- Plans moving the selected points by `df` frames (integer) and a frequency factor `ratio`.
-- Nothing is changed in d. Every contiguous run of one partial moves together: it stays in its own
-- row when the destination cells are free, otherwise goes to the nearest row that is silent there,
-- otherwise to a new row. Nothing is ever overwritten. Phase values are not moved (stale after editing).
-- Returns nil (nothing to do) or a plan:
--   { changes = { {p,f,oa,na,of,nf}, ... }, sel = new selection, rows_before, rows_after, df, count }
function M.plan_move(d, sel, df, ratio)
  local NF, P0 = d.frames, d.partials
  local ny = d.sr / 2 - 1
  local fmin, fmax, count = math.huge, -math.huge, 0
  for _, frames in pairs(sel) do
    for f in pairs(frames) do
      count = count + 1
      if f < fmin then fmin = f end
      if f > fmax then fmax = f end
    end
  end
  if count == 0 then return nil end
  df = clamp(df, 1 - fmin, NF - fmax)          -- keep every point inside the file
  if df == 0 and ratio == 1 then return nil end

  -- runs of consecutive frames, per source row
  local rows = {}
  for p in pairs(sel) do rows[#rows + 1] = p end
  table.sort(rows)
  local runs = {}
  for _, p in ipairs(rows) do
    local fl = {}
    for f in pairs(sel[p]) do fl[#fl + 1] = f end
    table.sort(fl)
    local start, prev = fl[1], fl[1]
    for i = 2, #fl + 1 do
      local f = fl[i]
      if f == nil or f ~= prev + 1 then
        runs[#runs + 1] = { p = p, f0 = start, f1 = prev }
        start = f
      end
      prev = f
    end
  end

  local taken = {}
  local function free(q, f)
    if taken[q] and taken[q][f] then return false end
    if q > P0 then return true end
    if d.amp[q][f] <= 0 then return true end
    return (sel[q] and sel[q][f]) or false     -- a selected cell is vacated by the move
  end
  local function run_free(q, run)
    for f = run.f0 + df, run.f1 + df do if not free(q, f) then return false end end
    return true
  end
  local function choose(run)
    if run_free(run.p, run) then return run.p end
    for k = 1, P0 do
      local lo, hi = run.p - k, run.p + k
      if hi <= P0 and run_free(hi, run) then return hi end
      if lo >= 1 and run_free(lo, run) then return lo end
      if lo < 1 and hi > P0 then break end
    end
    local q = P0 + 1
    while not run_free(q, run) do q = q + 1 end
    return q
  end

  local order, by_key = {}, {}
  local function cell(q, f)
    local key = q * (NF + 1) + f
    local c = by_key[key]
    if not c then
      local oa = (q <= P0) and d.amp[q][f] or 0
      local of_ = (q <= P0) and d.frq[q][f] or 0
      c = { p = q, f = f, oa = oa, na = oa, of = of_, nf = of_ }
      by_key[key] = c
      order[#order + 1] = c
    end
    return c
  end

  for _, run in ipairs(runs) do                 -- first silence every source cell
    for f = run.f0, run.f1 do cell(run.p, f).na = 0 end
  end
  local newsel, rows_after = {}, P0
  for _, run in ipairs(runs) do                 -- then write the destinations
    local q = choose(run)
    if q > rows_after then rows_after = q end
    taken[q] = taken[q] or {}
    newsel[q] = newsel[q] or {}
    for f = run.f0, run.f1 do
      local nf_ = f + df
      taken[q][nf_] = true
      newsel[q][nf_] = true
      local c = cell(q, nf_)
      c.na = d.amp[run.p][f]
      c.nf = clamp(d.frq[run.p][f] * ratio, 1, ny)
    end
  end
  local changes = {}
  for _, c in ipairs(order) do
    if c.na ~= c.oa or c.nf ~= c.of then changes[#changes + 1] = c end
  end
  return { changes = changes, sel = newsel, rows_before = P0, rows_after = rows_after, df = df, count = count }
end

-- Plans pasting copied points: `pts` is a list of { p = source row, df = frames from the first copied frame, amp, frq } and the
-- copy starts at frame f0 of d. Like a move, nothing is overwritten: every contiguous run of one source row goes back in its own
-- row when the cells there are silent, otherwise in the nearest row that is silent for the whole run, otherwise in a new row.
-- Points that would land outside the file are dropped. Returns { changes, sel (the pasted cells), rows_before, rows_after,
-- count, dropped }; nil when nothing is left to paste.
function M.plan_paste(d, pts, f0)
  local NF, P0 = d.frames, d.partials
  local ny = d.sr / 2 - 1
  local by_row, dropped, count = {}, 0, 0
  for _, pt in ipairs(pts) do
    local f = f0 + pt.df
    if f >= 1 and f <= NF then
      local r = by_row[pt.p]
      if not r then r = {}; by_row[pt.p] = r end
      r[#r + 1] = { f = f, amp = pt.amp, frq = pt.frq }
      count = count + 1
    else
      dropped = dropped + 1
    end
  end
  if count == 0 then return nil end
  local rows = {}
  for p in pairs(by_row) do rows[#rows + 1] = p end
  table.sort(rows)
  local runs = {}
  for _, p in ipairs(rows) do
    local cells = by_row[p]
    table.sort(cells, function(a, b) return a.f < b.f end)
    local run = { p = p, cells = { cells[1] } }
    for i = 2, #cells do
      if cells[i].f == cells[i - 1].f + 1 then
        run.cells[#run.cells + 1] = cells[i]
      else
        runs[#runs + 1] = run
        run = { p = p, cells = { cells[i] } }
      end
    end
    runs[#runs + 1] = run
  end

  local taken = {}
  local function free(q, f)
    if taken[q] and taken[q][f] then return false end
    return q > P0 or d.amp[q][f] <= 0
  end
  local function run_free(q, run)
    for _, c in ipairs(run.cells) do if not free(q, c.f) then return false end end
    return true
  end
  local function choose(run)
    local start = math.min(run.p, P0)                                 -- (a row that the file does not have: start at its last row)
    if start >= 1 and run_free(start, run) then return start end
    for k = 1, P0 do
      local lo, hi = start - k, start + k
      if hi <= P0 and run_free(hi, run) then return hi end
      if lo >= 1 and run_free(lo, run) then return lo end
      if lo < 1 and hi > P0 then break end
    end
    local q = P0 + 1
    while not run_free(q, run) do q = q + 1 end
    return q
  end

  local changes, newsel, rows_after = {}, {}, P0
  for _, run in ipairs(runs) do
    local q = choose(run)
    if q > rows_after then rows_after = q end
    taken[q] = taken[q] or {}
    newsel[q] = newsel[q] or {}
    for _, c in ipairs(run.cells) do
      taken[q][c.f] = true
      newsel[q][c.f] = true
      changes[#changes + 1] = { p = q, f = c.f,
                                oa = (q <= P0) and d.amp[q][c.f] or 0, na = c.amp,
                                of = (q <= P0) and d.frq[q][c.f] or 0, nf = clamp(c.frq, 1, ny) }
    end
  end
  return { changes = changes, sel = newsel, rows_before = P0, rows_after = rows_after, count = count, dropped = dropped }
end

-- Plans moving the selected points by a map (t, f -> t', f'): a bend or a stretch of a box (lib/ats_warp.lua). Frequencies change point by
-- point. Time is different: the points of a track sit on the frames of the file, so every run of one row is made again on the frames that
-- lie between its new first and last time, from its points by straight lines (amplitude and frequency). A run that is stretched gets
-- more frames, a squeezed one fewer. Like a move and a paste it never overwrites sound: a run stays in its row when the frames it now
-- needs are silent there, else it goes to the nearest row that is silent for the whole run, else a new row. Frames before the first or
-- after the last frame of the file are dropped. Returns nil (nothing selected) or
--   { changes, sel (the new cells), rows_before, rows_after, count (points moved), dropped (runs that fell outside) }
function M.plan_warp(d, sel, map, opts)
  local NF, P0 = d.frames, d.partials
  local limit = NF + ((opts and opts.max_extra) or 0)                 -- the last frame a run may reach: the end of the file, or further when the file may grow
  local first_ok = 1 - ((opts and opts.max_front) or 0)                -- the first frame a run may reach: frame 1, or earlier (frames 0, -1 ...) when the file may grow at the start
  local times = d.times
  local hop = (times[NF] - times[1]) / math.max(NF - 1, 1)
  local ny = d.sr / 2 - 1
  local rows = {}
  for p in pairs(sel) do rows[#rows + 1] = p end
  table.sort(rows)
  local runs, count = {}, 0
  for _, p in ipairs(rows) do
    local fl = {}
    for f in pairs(sel[p]) do fl[#fl + 1] = f end
    table.sort(fl)
    local first, prev = fl[1], fl[1]
    for i = 2, #fl + 1 do
      local f = fl[i]
      if f == nil or f ~= prev + 1 then
        runs[#runs + 1] = { p = p, f0 = first, f1 = prev }
        first = f
      end
      prev = f
    end
    count = count + #fl
  end
  if #runs == 0 then return nil end

  -- every run: its points mapped, then made again on the frames
  local dropped = 0
  for _, run in ipairs(runs) do
    local n = run.f1 - run.f0 + 1
    local tp, ap, fp = {}, {}, {}
    for k = 1, n do
      local f = run.f0 + k - 1
      local t2, fr2 = map(times[f], d.frq[run.p][f])
      if k > 1 and t2 <= tp[k - 1] + 1e-9 then t2 = tp[k - 1] + 1e-9 end         -- (time must not go back)
      tp[k], ap[k], fp[k] = t2, d.amp[run.p][f], clamp(fr2, 1, ny)
    end
    local lo = math.ceil((tp[1] - times[1]) / hop - 1e-9) + 1
    local hi = math.floor((tp[n] - times[1]) / hop + 1e-9) + 1
    if hi < lo then                                                              -- the run lies between two frames: the nearest one
      lo = math.floor(((tp[1] + tp[n]) / 2 - times[1]) / hop + 0.5) + 1
      hi = lo
    end
    run.cells = {}
    local k = 1
    for f = math.max(lo, first_ok), math.min(hi, limit) do
      local tau = (f >= 1 and f <= NF) and times[f] or (f > NF and (times[NF] + (f - NF) * hop) or (times[1] + (f - 1) * hop))
      while k < n and tp[k + 1] < tau do k = k + 1 end
      local a, fr
      if n == 1 then
        a, fr = ap[1], fp[1]
      else
        local k2 = math.min(k + 1, n)
        local w = (tp[k2] > tp[k]) and clamp((tau - tp[k]) / (tp[k2] - tp[k]), 0, 1) or 0
        a, fr = ap[k] + (ap[k2] - ap[k]) * w, fp[k] + (fp[k2] - fp[k]) * w
      end
      run.cells[#run.cells + 1] = { f = f, amp = a, frq = fr }
    end
    if #run.cells == 0 then dropped = dropped + 1 end
  end

  local taken = {}
  local function free(q, f)
    if taken[q] and taken[q][f] then return false end
    if q > P0 or f > NF or f < 1 then return true end
    if d.amp[q][f] <= 0 then return true end
    return (sel[q] and sel[q][f]) or false                  -- a selected cell is vacated by the move
  end
  local function run_free(q, run)
    for _, c in ipairs(run.cells) do if not free(q, c.f) then return false end end
    return true
  end
  local function choose(run)
    if run_free(run.p, run) then return run.p end
    for k = 1, P0 do
      local lo, hi = run.p - k, run.p + k
      if hi <= P0 and run_free(hi, run) then return hi end
      if lo >= 1 and run_free(lo, run) then return lo end
      if lo < 1 and hi > P0 then break end
    end
    local q = P0 + 1
    while not run_free(q, run) do q = q + 1 end
    return q
  end

  local order, by_key = {}, {}
  local function cell(q, f)
    local key = q * (limit - first_ok + 2) + (f - first_ok)
    local c = by_key[key]
    if not c then
      local inside = (q <= P0 and f >= 1 and f <= NF)
      local oa = inside and d.amp[q][f] or 0
      local of_ = inside and d.frq[q][f] or 0
      c = { p = q, f = f, oa = oa, na = oa, of = of_, nf = of_ }
      by_key[key] = c
      order[#order + 1] = c
    end
    return c
  end
  for _, run in ipairs(runs) do                              -- first silence every source cell
    for f = run.f0, run.f1 do cell(run.p, f).na = 0 end
  end
  local newsel, rows_after, frames_after, first_frame = {}, P0, NF, 1
  for _, run in ipairs(runs) do                              -- then write the destinations
    if #run.cells > 0 then
      if run.cells[#run.cells].f > frames_after then frames_after = run.cells[#run.cells].f end
      if run.cells[1].f < first_frame then first_frame = run.cells[1].f end
      local q = choose(run)
      if q > rows_after then rows_after = q end
      taken[q] = taken[q] or {}
      newsel[q] = newsel[q] or {}
      for _, c in ipairs(run.cells) do
        taken[q][c.f] = true
        newsel[q][c.f] = true
        local cl = cell(q, c.f)
        cl.na, cl.nf = c.amp, c.frq
      end
    end
  end
  local changes = {}
  for _, c in ipairs(order) do
    if c.na ~= c.oa or c.nf ~= c.of then changes[#changes + 1] = c end
  end
  return { changes = changes, sel = newsel, rows_before = P0, rows_after = rows_after, frames_before = NF, frames_after = frames_after,
           frames_front = 1 - first_frame, count = count, dropped = dropped }
end

return M
