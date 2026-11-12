-- Run: lua5.4 tests/test_ats_notes.lua   (from the ReaATS folder)
package.path = "lib/?.lua;" .. package.path
local notes = require("ats_notes")
local ok, fails = 0, 0
local function check(name, cond, extra)
  if cond then ok = ok + 1 else fails = fails + 1; print("FAIL: " .. name .. " " .. tostring(extra or "")) end
end
local function make(P, NF)
  local d = { sr = 44100, frame_size = 441, partials = P, frames = NF, ampmax = 1.0, amp = {}, frq = {}, times = {} }
  for f = 1, NF do d.times[f] = (f - 1) * 0.01 end
  for p = 1, P do d.amp[p], d.frq[p] = {}, {}; for f = 1, NF do d.amp[p][f], d.frq[p][f] = 0, 0 end end
  return d
end
local function fill(d, p, f0, f1, freq, amp) for f = f0, f1 do d.amp[p][f], d.frq[p][f] = amp, freq end end
local function cents(c) return 440 * 2 ^ (c / 1200) end

-- one steady A4 at full level: one note on channel 1 (member), bend centred, pressure 127
do
  local d = make(1, 20); fill(d, 1, 3, 12, 440, 1.0)
  local r = notes.build(d, { max = 15 })
  check("one note", #r.notes == 1, #r.notes)
  local n = r.notes[1]
  check("A4 = 69", n.pitch == 69, n.pitch)
  check("member channel 1", n.ch == 1, n.ch)
  check("velocity full", n.vel == 127, n.vel)
  check("starts at frame 3 + lead", math.abs(n.t0 - (0.02 + notes.LEAD)) < 1e-9, n.t0)
  check("ends after frame 12, a little early", math.abs(n.t1 - (0.12 + notes.LEAD - 0.002)) < 1e-9, n.t1)
  local bends, press = {}, {}
  for _, c in ipairs(r.ccs) do if c.kind == "bend" then bends[#bends + 1] = c elseif c.kind == "press" then press[#press + 1] = c end end
  check("steady partial: one bend, one pressure", #bends == 1 and #press == 1, #bends .. "/" .. #press)
  check("bend centred", bends[1].a + 128 * bends[1].b == 8192, bends[1].a + 128 * bends[1].b)
  check("pressure 127", press[1].a == 127)
  check("the first values come before the note", bends[1].t < n.t0 and press[1].t < n.t0)
  check("1 member channel in use", r.members == 1)
end

-- inharmonic: 30 cents above A4 -> note 69, bend +30 cents; 70 cents -> note 70 (nearest), bend -30 cents
do
  local d = make(2, 20); fill(d, 1, 1, 10, cents(30), 0.5); fill(d, 2, 1, 10, cents(70), 0.5)
  local r = notes.build(d, {})
  local byp = {}
  for _, n in ipairs(r.notes) do byp[n.pitch] = n end
  check("30 cents -> 69", byp[69] ~= nil)
  check("70 cents -> 70", byp[70] ~= nil)
  local bendch = {}
  for _, c in ipairs(r.ccs) do if c.kind == "bend" then bendch[c.ch] = c.a + 128 * c.b end end
  local up = bendch[byp[69].ch] - 8192
  local dn = bendch[byp[70].ch] - 8192
  check("+30 cents = 30/48/100*8192 steps", math.abs(up - 30 / 4800 * 8192) <= 1, up)
  check("-30 cents", math.abs(dn + 30 / 4800 * 8192) <= 1, dn)
  check("pressure of amplitude 0.5 = 6 dB down", (function()
    for _, c in ipairs(r.ccs) do if c.kind == "press" then return math.abs(c.a - 127 * (1 - 6.0206 / 60)) < 1 end end
  end)())
end

-- a glissando is followed by the bend; a fade by the pressure
do
  local d = make(1, 30)
  for f = 1, 30 do d.amp[1][f] = 1 - (f - 1) * 0.03; d.frq[1][f] = cents((f - 1) * 3) end         -- up 87 cents in 29 frames
  local r = notes.build(d, {})
  local nb, np, lastb, lastp = 0, 0
  for _, c in ipairs(r.ccs) do
    if c.kind == "bend" then nb = nb + 1; lastb = c.a + 128 * c.b elseif c.kind == "press" then np = np + 1; lastp = c.a end
  end
  check("many bend values", nb >= 20, nb)
  check("many pressure values", np >= 10, np)
  check("pressure falls", lastp < 127, lastp)
  check("bend ends where the pitch is", math.abs((lastb - 8192) * 4800 / 8192 - (87 - 100 * (r.notes[1].pitch - 69))) < 2, lastb)
end

-- 20 simultaneous partials, max 15: the 15 strongest stay, on channels 1..15 with no overlap; none cut short
do
  local d = make(20, 30)
  for p = 1, 20 do fill(d, p, 1, 30, 200 * p, 0.01 * p) end
  local r = notes.build(d, { max = 15 })
  check("15 notes", #r.notes == 15, #r.notes)
  check("5 left out", r.dropped == 5, r.dropped)
  local chs, minamp = {}, 1
  for _, n in ipairs(r.notes) do chs[n.ch] = true end
  local c = 0 for ch = 1, 15 do if chs[ch] then c = c + 1 end end
  check("channels 1..15 all used once", c == 15 and r.members == 15)
  local pitches = {}
  for _, n in ipairs(r.notes) do pitches[n.pitch] = true end
  local weakest = math.floor(69 + 12 * math.log(200 * 6 / 440) / math.log(2) + 0.5)       -- partial 6 is the weakest kept
  local gone = math.floor(69 + 12 * math.log(200 * 5 / 440) / math.log(2) + 0.5)
  check("partial 6 kept", pitches[weakest] == true)
  check("partial 5 left out", pitches[gone] == nil)
  local r3 = notes.build(d, { max = 3 })
  check("max 3", #r3.notes == 3 and r3.members == 3)
end

-- channels are reused when notes do not overlap, and a track of a shared row counts as its own note
do
  local d = make(1, 40); fill(d, 1, 1, 10, 440, 1); fill(d, 1, 12, 20, 880, 1)
  local r = notes.build(d, { max = 1 })
  check("two tracks of one row = two notes", #r.notes == 2, #r.notes)
  check("one channel for both", r.members == 1 and r.notes[1].ch == r.notes[2].ch)
  check("the second starts after the first has ended", r.notes[2].t0 > r.notes[1].t1)
  local d2 = make(1, 40); fill(d2, 1, 1, 10, 440, 1); fill(d2, 1, 11, 20, 880, 1)         -- no silent frame between: one run
  check("no gap = one track", #notes.build(d2, {}).notes == 1)
end

-- short flicker is not a note; a selection cuts tracks to the selected cells
do
  local d = make(2, 30); fill(d, 1, 5, 6, 300, 1); fill(d, 2, 1, 30, 500, 1)
  local r = notes.build(d, {})
  check("a 2-frame track is left out", #r.notes == 1 and r.found == 1, #r.notes)
  local sel = { [2] = {} }
  for f = 10, 19 do sel[2][f] = true end
  local rs = notes.build(d, { sel = sel })
  check("selection: one note", #rs.notes == 1)
  check("selection: starts at frame 10", math.abs(rs.notes[1].t0 - (0.09 + notes.LEAD)) < 1e-9, rs.notes[1].t0)
  check("selection: ends after frame 19", math.abs(rs.notes[1].t1 - (0.19 + notes.LEAD - 0.002)) < 1e-9, rs.notes[1].t1)
  check("nothing selected that sounds: no notes", #notes.build(d, { sel = { [1] = { [20] = true } } }).notes == 0)
end

-- out-of-range pitches are skipped
do
  local d = make(1, 10); fill(d, 1, 1, 10, 5, 1)
  check("5 Hz is below MIDI 0", #notes.build(d, {}).notes == 0)
end

-- the set-up messages
do
  local d = make(2, 20); fill(d, 1, 1, 10, 440, 1); fill(d, 2, 1, 10, 660, 1)
  local r = notes.build(d, {})
  local got = {}
  for _, c in ipairs(r.ccs) do if c.kind == "cc" then got[#got + 1] = string.format("%d:%d=%d", c.ch, c.a, c.b) end end
  local s = table.concat(got, " ")
  check("MPE zone with 2 members on the master channel", s:find("0:101=0 0:100=6 0:6=2 0:38=0", 1, true) ~= nil, s)
  check("bend range 48 on member 1 and 2", s:find("1:101=0 1:100=0 1:6=48", 1, true) and s:find("2:101=0 2:100=0 2:6=48", 1, true), s)
  check("RPN reset after each", s:find("0:101=127 0:100=127", 1, true) ~= nil)
end

-- the MIDI file: read it back
local function read_smf(s)
  assert(s:sub(1, 4) == "MThd")
  local len, fmt, ntrk, div = string.unpack(">I4I2I2I2", s, 5)
  assert(s:sub(15, 18) == "MTrk")
  local tl = string.unpack(">I4", s, 19)
  local pos, last, tick, ev = 23, 0, 0, {}
  local stop = 22 + tl
  while pos <= stop do
    local v = 0
    repeat local b = s:byte(pos); pos = pos + 1; v = (v << 7) | (b & 127) until b < 128
    tick = tick + v
    local st = s:byte(pos); pos = pos + 1
    if st == 0xFF then
      local ty, l = s:byte(pos), s:byte(pos + 1); pos = pos + 2 + l
      ev[#ev + 1] = { tick = tick, meta = ty }
    else
      local hi = st & 0xF0
      local n = (hi == 0xC0 or hi == 0xD0) and 1 or 2
      ev[#ev + 1] = { tick = tick, st = hi, ch = st & 15, a = s:byte(pos), b = n == 2 and s:byte(pos + 1) or nil }
      pos = pos + n
    end
  end
  return { fmt = fmt, ntrk = ntrk, div = div, ev = ev, end_pos = pos - 1, stop = stop, size = #s }
end
do
  local d = make(2, 40); fill(d, 1, 3, 30, 440, 1); fill(d, 2, 5, 25, cents(1240), 0.3)
  local r = notes.build(d, { max = 15 })
  local m = read_smf(notes.smf(r))
  check("format 0, one track, 960 ppq", m.fmt == 0 and m.ntrk == 1 and m.div == 960)
  check("track length matches", m.end_pos == m.stop and m.size == m.stop, m.end_pos .. "/" .. m.stop)
  local on, off, last = 0, 0, nil
  local ticks_ok = true
  local prev = 0
  for _, e in ipairs(m.ev) do
    if e.st == 0x90 then on = on + 1 elseif e.st == 0x80 then off = off + 1 end
    if e.tick < prev then ticks_ok = false end
    prev = e.tick; last = e
  end
  check("2 note-ons, 2 note-offs", on == 2 and off == 2, on .. "/" .. off)
  check("ticks never go back", ticks_ok)
  check("ends with end-of-track", last.meta == 0x2F)
  local first_on
  for _, e in ipairs(m.ev) do if e.st == 0x90 and e.a == 69 then first_on = e break end end
  check("note 69 starts at tick of 0.03 s", first_on and first_on.tick == math.floor((0.02 + notes.LEAD) * 1920 + 0.5), first_on and first_on.tick)
  -- on every channel the bend and the range set-up come before the first note-on
  local before = {}
  for _, e in ipairs(m.ev) do
    if e.st == 0x90 and not before[e.ch] then before[e.ch] = (before[e.ch] == nil) and "on" end
  end
  local seen_bend = {}
  local order_ok = true
  for _, e in ipairs(m.ev) do
    if e.st == 0xE0 then seen_bend[e.ch] = true end
    if e.st == 0x90 and not seen_bend[e.ch] then order_ok = false end
  end
  check("a bend value precedes every note-on", order_ok)
  -- a long delta (VLQ over 127 ticks) round trip: the end of the first note is after more than 127 ticks
  check("the two notes sound on different channels", (function() local c = {} for _, e in ipairs(m.ev) do if e.st == 0x90 then c[e.ch] = true end end return c[1] and c[2] end)())
end

-- the buffer for REAPER: unpack it again
do
  local d = make(1, 20); fill(d, 1, 3, 12, 440, 1.0)
  local r = notes.build(d, {})
  local buf = notes.reaper_buffer(r, function(t) return t * 960 end, r.dur)       -- (a take at 60 bpm: 960 ticks a second)
  local pos, n, abs, kinds, monotone = 1, 0, 0, {}, true
  while pos <= #buf do
    local off, flag, msg
    off, flag, msg, pos = string.unpack("<i4Bs4", buf, pos)
    if off < 0 then monotone = false end
    abs = abs + off; n = n + 1; kinds[#kinds + 1] = msg:byte(1) & 0xF0
  end
  check("buffer parses to the last byte", pos == #buf + 1)
  check("offsets never negative", monotone)
  local on, off_, bend = 0, 0, 0
  for _, k in ipairs(kinds) do if k == 0x90 then on = on + 1 elseif k == 0x80 then off_ = off_ + 1 elseif k == 0xE0 then bend = bend + 1 end end
  check("buffer has the note and its bend", on == 1 and off_ == 1 and bend == 1, on .. off_ .. bend)
  check("ends with all notes off", kinds[#kinds] == 0xB0)
end

-- favour low partials: one voice, a quiet low partial against a loud high one
do
  local d = make(2, 20); fill(d, 1, 1, 15, 200, 0.5); fill(d, 2, 1, 15, 2000, 1.0)
  local function kept(bias) local r = notes.build(d, { max = 1, bias = bias }); return r.notes[1].pitch end
  local low, high = math.floor(69 + 12 * math.log(200 / 440) / math.log(2) + 0.5), math.floor(69 + 12 * math.log(2000 / 440) / math.log(2) + 0.5)
  check("no bias: the loud high partial", kept(0) == high, kept(0))
  check("bias 1: the low partial", kept(1) == low, kept(1))
  check("bias 0.2 is still the loud one", kept(0.2) == high, kept(0.2))
  check("bias nil = 0", kept(nil) == high)
end

-- the envelope: the number of notes allowed changes over time (12 Nov 2026)
do
  local d = make(10, 100)
  for p = 1, 10 do fill(d, p, 1, 100, 200 * p, 0.05 * p) end                  -- ten steady partials, the higher the stronger
  local c = notes.caps(d, nil, 6)
  check("caps: flat", c[1] == 6 and c[100] == 6)
  local ramp = { { t = 0, n = 1 }, { t = 0.99, n = 10 } }                    -- from 1 note to 10 notes over the whole file
  c = notes.caps(d, ramp, 15)
  check("caps: a ramp from 1 to 10", c[1] == 1 and c[100] == 10 and c[50] > 3 and c[50] < 8, c[1] .. " " .. c[50] .. " " .. c[100])
  check("caps: before the first and after the last point the values stay", notes.caps(d, { { t = 0.3, n = 4 }, { t = 0.6, n = 9 } }, 15)[1] == 4 and notes.caps(d, { { t = 0.3, n = 4 }, { t = 0.6, n = 9 } }, 15)[100] == 9)
  check("caps: limited to 1..15", notes.caps(d, { { t = 0, n = -3 }, { t = 0.5, n = 40 } }, 15)[1] == 1 and notes.caps(d, { { t = 0, n = -3 }, { t = 0.5, n = 40 } }, 15)[100] == 15)
  -- with the ramp the notes are cut short where there is no room, the strongest keep their places and start earliest
  local r = notes.build(d, { curve = ramp })
  local sounding = {}                                                         -- how many notes sound at the start, the middle and the end
  for _, n in ipairs(r.notes) do
    for _, probe in ipairs({ 0.05, 0.5, 0.95 }) do
      local tt = probe + notes.LEAD
      if n.t0 <= tt and tt < n.t1 then sounding[probe] = (sounding[probe] or 0) + 1 end
    end
  end
  check("envelope: 1 note at the start", sounding[0.05] == 1, sounding[0.05])
  check("envelope: 10 notes at the end", sounding[0.95] == 10, sounding[0.95])
  check("envelope: in between about half", sounding[0.5] >= 4 and sounding[0.5] <= 7, sounding[0.5])
  -- the strongest partial (10) is the one note at the start
  local first_pitch
  for _, n in ipairs(r.notes) do if n.t0 < 0.05 then first_pitch = n.pitch end end
  check("envelope: the strongest partial sounds at the start", first_pitch == math.floor(69 + 12 * math.log(2000 / 440) / math.log(2) + 0.5), first_pitch)
  -- no more than the room at any moment, whatever the channels do
  check("envelope: never more than 10 channels", r.members <= 10, r.members)
  -- without a curve it is as before: a flat number refuses a track whole, nothing is cut short
  local flat = notes.build(d, { max = 4 })
  check("flat: 4 notes", #flat.notes == 4)
  -- a flat envelope gives the same notes as the number
  local flat2 = notes.build(d, { max = 4, curve = { { t = 0, n = 4 }, { t = 1, n = 4 } } })
  check("a flat envelope gives the same as the number", #flat2.notes == 4)
  -- a dip: 8 notes, then 2, then 8 again: the weaker notes stop at the dip and new pieces start after it
  local dip = notes.build(d, { curve = { { t = 0, n = 8 }, { t = 0.3, n = 8 }, { t = 0.31, n = 2 }, { t = 0.6, n = 2 }, { t = 0.61, n = 8 } } })
  local at = function(tt) local c = 0 for _, n in ipairs(dip.notes) do if n.t0 <= tt + notes.LEAD and tt + notes.LEAD < n.t1 then c = c + 1 end end return c end
  check("dip: 8 notes before, 2 in the dip, 8 after", at(0.15) == 8 and at(0.45) == 2 and at(0.8) == 8, at(0.15) .. " " .. at(0.45) .. " " .. at(0.8))
  -- M.count agrees
  local tr = notes.tracks(d, nil)
  local kept, dropped, members = notes.count(tr, notes.caps(d, ramp, 15), d.frames, 0, true)
  check("count follows the envelope", kept == #r.notes, kept .. " vs " .. #r.notes)
end

print(string.format("ats_notes: %d checks passed, %d failed", ok, fails))
os.exit(fails == 0 and 0 or 1)
