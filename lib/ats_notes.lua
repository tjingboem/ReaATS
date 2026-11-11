-- ats_notes.lua -- the strongest partials of an ATS file as MPE notes (tjingboem, 11 Nov 2026).
--
-- A partial that sounds from one silent frame to the next is a TRACK. Every track becomes one MIDI note on a channel of its own
-- (MPE lower zone: master channel 1, member channels 2..16, so at most 15 partials sound at the same moment):
--   note number   the semitone nearest to the track's mean pitch (weighted by amplitude);
--   pitch bend    the distance of the partial from that semitone, frame by frame, in the MPE default range of +-48 semitones (so the
--                 inharmonic offsets and every drift or vibrato of the partial are kept; 14 bit, about 0.6 cent per step);
--   pressure      the amplitude, frame by frame (channel pressure, 7 bit, so it is mapped in dB: 127 = the loudest amplitude of the
--                 file, 0 = 60 dB below that);
--   velocity      the pressure of the first frame (at least 1).
-- Which tracks are kept: the tracks are ranked by their total energy (the sum of their amplitudes, as the MAX PARTIALS button does; with a
-- bias the energy is divided by (mean frequency / 500 Hz) ^ bias, so the fundamental and the low harmonics win voices from the formant region) and
-- admitted one by one, strongest first, as long as fewer than `max` tracks sound at any frame of their length. No note is ever cut
-- short or stolen; a weaker track that would be the 16th voice is simply left out.
-- Without a selection the whole file is used; with one (sel[p][f] = true, as in the editor) only the selected cells, so a track
-- is cut to the selected stretch of it.

local M = {}

M.BEND_RANGE = 48          -- semitones, the MPE default for member channels (also sent as RPN 0 at the start)
M.DB_RANGE = 60            -- pressure 0 is this many dB below the loudest amplitude of the file
M.BIAS_REF = 500           -- Hz: the energy of a track is divided by (its frequency / this) ^ bias, so a low bias is a preference for low partials
M.MIN_FRAMES = 3           -- shorter tracks are flicker, not notes
M.LEAD = 0.01              -- seconds of silence before everything: the set-up messages come first
M.PPQ = 960                -- ticks per quarter note of the MIDI file; at 120 bpm that is 1920 ticks a second
M.TICKS_PER_SEC = 1920

local LOG = math.log
local function midi_of(freq) return 69 + 12 * LOG(freq / 440) / LOG(2) end

local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end

-- The tracks of the file (or of the selection): { p, f0, f1, energy } for every run of sounding frames of at least `min_frames`.
function M.tracks(d, sel, min_frames)
  min_frames = min_frames or M.MIN_FRAMES
  local out = {}
  local function scan(p, list)
    local amp, frq = d.amp[p], d.frq[p]
    local start, prev, energy, fsum = nil, nil, 0, 0
    local n = list and #list or d.frames
    local function close()
      if start and prev - start + 1 >= min_frames then out[#out + 1] = { p = p, f0 = start, f1 = prev, energy = energy, freq = fsum / energy } end
      start, prev, energy, fsum = nil, nil, 0, 0
    end
    for i = 1, n + 1 do
      local f = (i <= n) and (list and list[i] or i) or nil
      local on = f and amp[f] > 0 and frq[f] > 0
      if on and prev and f == prev + 1 then
        prev, energy, fsum = f, energy + amp[f], fsum + amp[f] * frq[f]
      else
        close()
        if on then start, prev, energy, fsum = f, f, amp[f], amp[f] * frq[f] end
      end
    end
  end
  if sel then
    for p, frames in pairs(sel) do
      local list = {}
      for f in pairs(frames) do list[#list + 1] = f end
      table.sort(list)
      if #list > 0 then scan(p, list) end
    end
  else
    for p = 1, d.partials do scan(p) end
  end
  return out
end

-- Admits the strongest tracks, at most `max` sounding at any frame, and gives each a member channel (2..16 as 1..15 here: ch is 1-based
-- among the member channels). Returns the admitted tracks (each with .ch) and how many were left out.
function M.allocate(tracks, max, frames, bias)
  bias = bias or 0
  for _, t in ipairs(tracks) do
    t.score = (bias > 0) and t.energy * (math.max(t.freq, 50) / M.BIAS_REF) ^ (-bias) or t.energy
  end
  table.sort(tracks, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    if a.f0 ~= b.f0 then return a.f0 < b.f0 end
    return a.p < b.p
  end)
  local occ, kept = {}, {}
  for f = 1, frames do occ[f] = 0 end
  for _, t in ipairs(tracks) do
    local ok = true
    for f = t.f0, t.f1 do if occ[f] >= max then ok = false; break end end
    if ok then
      for f = t.f0, t.f1 do occ[f] = occ[f] + 1 end
      kept[#kept + 1] = t
    end
  end
  table.sort(kept, function(a, b) if a.f0 ~= b.f0 then return a.f0 < b.f0 end return a.p < b.p end)
  local busy = {}                                  -- channel -> the last frame it is in use
  for _, t in ipairs(kept) do
    local ch = 1
    while busy[ch] and busy[ch] >= t.f0 do ch = ch + 1 end
    t.ch = ch
    busy[ch] = t.f1
  end
  return kept, #tracks - #kept
end

-- How many notes a setting would give, without making them (for the panel's live line): kept, dropped, members (channels in use).
function M.count(tracks, max, frames, bias)
  local kept, dropped = M.allocate(tracks, clamp(math.floor(max + 0.5), 1, 15), frames, bias)
  local members = 0
  for _, t in ipairs(kept) do if t.ch > members then members = t.ch end end
  return #kept, dropped, members
end

-- The notes and the controller moves.
--   d    the loaded ATS data (amp, frq, times, frames, partials, ampmax)
--   opts { max = 1..15, sel = selection or nil, bias = 0 (energy only) .. 2 (strongly prefers low partials) }
-- Returns { notes = { {ch, pitch, vel, t0, t1} }, ccs = { {t, ch, kind = "bend"|"press"|"cc", a, b} }, members, found, dropped, dur }
-- ch is the MIDI channel 0..15 (member channels are 1..15). Times in seconds, from 0 (everything starts LEAD later).
function M.build(d, opts)
  opts = opts or {}
  local max = clamp(math.floor((opts.max or 15) + 0.5), 1, 15)
  local tracks = opts.tracks or M.tracks(d, opts.sel, opts.min_frames)      -- (opts.tracks: found before by M.tracks; M.allocate reorders them)
  local found = #tracks
  local kept, dropped = M.allocate(tracks, max, d.frames, opts.bias)
  local ref = d.ampmax
  if not ref or ref <= 0 then
    ref = 0
    for p = 1, d.partials do for f = 1, d.frames do if d.amp[p][f] > ref then ref = d.amp[p][f] end end end
  end
  if ref <= 0 then ref = 1 end
  local times = d.times
  local hop = (d.frame_size and d.sr and d.sr > 0) and (d.frame_size / d.sr) or 0.02
  local function frame_end(f)
    if times[f + 1] then return times[f + 1] end
    if times[f - 1] then return times[f] + (times[f] - times[f - 1]) end
    return times[f] + hop
  end
  local function pressure(a)
    if a <= 0 then return 0 end
    return clamp(math.floor(127 * (1 + 20 * LOG(a / ref) / LOG(10) / M.DB_RANGE) + 0.5), 0, 127)
  end

  local notes, ccs, members, last_end = {}, {}, 0, 0
  for _, t in ipairs(kept) do
    local amp, frq = d.amp[t.p], d.frq[t.p]
    local sum, wsum = 0, 0
    for f = t.f0, t.f1 do sum, wsum = sum + amp[f] * midi_of(frq[f]), wsum + amp[f] end
    local note = math.floor(sum / wsum + 0.5)
    if note >= 0 and note <= 127 then
      local ch = t.ch
      if ch > members then members = ch end
      local sent_bend, sent_press
      for f = t.f0, t.f1 do
        local tm = times[f] + M.LEAD
        if f == t.f0 then tm = tm - 0.001 end                       -- the first values come just before the note
        local b = clamp(math.floor(8192 + (midi_of(frq[f]) - note) / M.BEND_RANGE * 8192 + 0.5), 0, 16383)
        local pr = pressure(amp[f])
        if not sent_bend or math.abs(b - sent_bend) >= 2 then
          ccs[#ccs + 1] = { t = tm, ch = ch, kind = "bend", a = b & 127, b = b >> 7 }
          sent_bend = b
        end
        if not sent_press or pr ~= sent_press then
          ccs[#ccs + 1] = { t = tm, ch = ch, kind = "press", a = pr, b = 0 }
          sent_press = pr
        end
      end
      local t0 = times[t.f0] + M.LEAD
      local t1 = frame_end(t.f1) + M.LEAD - 0.002                    -- (a little early: the next note on this channel may start at once)
      notes[#notes + 1] = { ch = ch, pitch = note, vel = math.max(1, pressure(amp[t.f0])), t0 = t0, t1 = t1 }
      if t1 > last_end then last_end = t1 end
    end
  end
  -- The set-up: the MPE zone on the master channel (RPN 6: how many member channels) and the bend range of every member channel (RPN 0).
  local function rpn(ch, msb, lsb, v)
    for _, m in ipairs({ { 101, msb }, { 100, lsb }, { 6, v }, { 38, 0 }, { 101, 127 }, { 100, 127 } }) do
      ccs[#ccs + 1] = { t = 0, ch = ch, kind = "cc", a = m[1], b = m[2] }
    end
  end
  if members > 0 then
    rpn(0, 0, 6, members)
    for ch = 1, members do rpn(ch, 0, 0, M.BEND_RANGE) end
  end
  for i, c in ipairs(ccs) do c.i = i end                        -- (table.sort is not stable: keep the order of equal times)
  table.sort(ccs, function(a, b) if a.t ~= b.t then return a.t < b.t end return a.i < b.i end)
  table.sort(notes, function(a, b) return a.t0 < b.t0 end)
  return { notes = notes, ccs = ccs, members = members, found = found, dropped = dropped, dur = last_end }
end

-- Every message of the result, in the order it must be played: { t = seconds, tick = at 1920 ticks a second, data = the raw MIDI bytes }.
-- At the same tick: set-up first, then note-offs, bends, pressure and last the note-ons (so a bend always arrives before its note).
function M.events(res)
  local ev = {}
  local function tick(t) return math.floor(t * M.TICKS_PER_SEC + 0.5) end
  for _, c in ipairs(res.ccs) do
    local data
    if c.kind == "bend" then data = string.char(0xE0 | c.ch, c.a, c.b)
    elseif c.kind == "press" then data = string.char(0xD0 | c.ch, c.a)
    else data = string.char(0xB0 | c.ch, c.a, c.b) end
    ev[#ev + 1] = { t = c.t, tick = tick(c.t), order = (c.kind == "cc") and 0 or (c.kind == "bend" and 2 or 3), data = data }
  end
  for _, n in ipairs(res.notes) do
    ev[#ev + 1] = { t = n.t1, tick = tick(n.t1), order = 1, data = string.char(0x80 | n.ch, n.pitch, 0) }
    ev[#ev + 1] = { t = n.t0, tick = tick(n.t0), order = 4, data = string.char(0x90 | n.ch, n.pitch, n.vel) }
  end
  for i, e in ipairs(ev) do e.i = i end
  table.sort(ev, function(a, b)
    if a.tick ~= b.tick then return a.tick < b.tick end
    if a.order ~= b.order then return a.order < b.order end
    return a.i < b.i
  end)
  return ev
end

-- A Standard MIDI File (format 0, one track, 120 bpm) of the result, as a string.
function M.smf(res)
  local ev = M.events(res)
  local function vlq(v)
    local s = string.char(v & 127)
    v = v >> 7
    while v > 0 do s = string.char((v & 127) | 128) .. s; v = v >> 7 end
    return s
  end
  local out, prev = { "\0\255\3\12ReaATS notes", "\0\255\81\3\7\161\32" }, 0       -- track name, tempo 500000 us per quarter note
  for _, e in ipairs(ev) do
    out[#out + 1] = vlq(e.tick - prev) .. e.data
    prev = e.tick
  end
  out[#out + 1] = "\0\255\47\0"
  local body = table.concat(out)
  return "MThd" .. string.pack(">I4I2I2I2", 6, 0, 1, M.PPQ) .. "MTrk" .. string.pack(">I4", #body) .. body
end

-- The same messages as the buffer that REAPER's MIDI_SetAllEvts takes: ppq_of(t) gives the position in ticks of the take for a time in
-- seconds from the start of the item. One call instead of thousands of MIDI_InsertCC calls (each of which sorts the take again).
function M.reaper_buffer(res, ppq_of, end_t)
  local parts, prev = {}, 0
  for _, e in ipairs(M.events(res)) do
    local ppq = math.floor(ppq_of(e.t) + 0.5)
    if ppq < prev then ppq = prev end
    parts[#parts + 1] = string.pack("<i4Bs4", ppq - prev, 0, e.data)
    prev = ppq
  end
  local last = math.max(prev, math.floor(ppq_of(end_t) + 0.5))
  parts[#parts + 1] = string.pack("<i4Bs4", last - prev, 0, "\xB0\x7B\x00")          -- all notes off at the end, as REAPER writes it
  return table.concat(parts)
end

return M
