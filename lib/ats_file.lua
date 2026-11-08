-- ats_file.lua -- reader for Csound/ATS ".ats" analysis files (Lua 5.3+).
--
-- Written from the published file layout (the same one Csound's ATS opcodes
-- read), not ported from any code. Layout: a header of 10 doubles
--   magic(123.0) sr frame-size window-size partials frames ampmax frqmax dur type
-- followed by one record per frame, all doubles:
--   type 1: time, (amp, freq) x P
--   type 2: time, (amp, freq, phase) x P
--   type 3: time, (amp, freq) x P, 25 noise-band energies
--   type 4: time, (amp, freq, phase) x P, 25 noise-band energies
-- Little-endian is expected; a big-endian file is detected by its magic number.

local M = {}

M.NUM_NOISE_BANDS = 25
-- Critical-band (Bark) edges of the 25 ATS noise bands, in Hz.
M.CRITICAL_BAND_EDGES = {
  0, 100, 200, 300, 400, 510, 630, 770, 920, 1080, 1270, 1480, 1720,
  2000, 2320, 2700, 3150, 3700, 4400, 5300, 6400, 7700, 9500, 12000, 15500, 20000 }

local NOTE_NAMES = { "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" }

-- "A4 +3c" style name for a frequency in Hz (A4 = 440 Hz).
function M.note_name(freq)
  if not freq or freq <= 0 then return "-" end
  local midi = 69 + 12 * math.log(freq / 440) / math.log(2)
  local n = math.floor(midi + 0.5)
  local cents = math.floor((midi - n) * 100 + 0.5)
  local name = NOTE_NAMES[(n % 12) + 1] .. tostring(math.floor(n / 12) - 1)
  if cents == 0 then return name end
  return string.format("%s %+dc", name, cents)
end

-- Returns a table, or nil plus an error message.
--   .sr .frame_size .window_size .partials .frames .ampmax .frqmax .dur .type
--   .times[f]                       frame times in seconds
--   .amp[p][f] .frq[p][f]           per partial, per frame
--   .pha[p][f]                      only when .has_phase
--   .noise[b][f]                    only when .has_noise (b = 1..25)
--   .noise_max                      largest noise value (for scaling)
function M.load(path)
  local fh, err = io.open(path, "rb")
  if not fh then return nil, "cannot open file: " .. tostring(err) end
  local s = fh:read("a")
  fh:close()
  if #s < 80 then return nil, "file too short for an ATS header" end

  local endian = "<"
  local magic = string.unpack("<d", s, 1)
  if magic ~= 123.0 then
    magic = string.unpack(">d", s, 1)
    if magic ~= 123.0 then return nil, "not an ATS file (magic number is not 123)" end
    endian = ">"
  end

  local h = { string.unpack(endian .. "dddddddddd", s, 1) }
  local d = {
    sr = h[2], frame_size = h[3], window_size = h[4],
    partials = math.floor(h[5] + 0.5), frames = math.floor(h[6] + 0.5),
    ampmax = h[7], frqmax = h[8], dur = h[9], type = math.floor(h[10] + 0.5),
  }
  if d.type < 1 or d.type > 4 then return nil, "unknown ATS type " .. tostring(d.type) end
  if d.partials < 1 or d.frames < 1 then return nil, "no partials or frames in header" end

  local P, NF = d.partials, d.frames
  d.has_phase = (d.type == 2 or d.type == 4)
  d.has_noise = (d.type == 3 or d.type == 4)
  local per_partial = d.has_phase and 3 or 2
  local per_frame = 1 + per_partial * P + (d.has_noise and M.NUM_NOISE_BANDS or 0)
  if #s < 80 + 8 * per_frame * NF then
    return nil, string.format("file is smaller than its header says (%d bytes, need %d)",
                              #s, 80 + 8 * per_frame * NF)
  end

  d.times, d.amp, d.frq = {}, {}, {}
  for p = 1, P do d.amp[p] = {}; d.frq[p] = {} end
  if d.has_phase then d.pha = {}; for p = 1, P do d.pha[p] = {} end end
  if d.has_noise then
    d.noise = {}
    for b = 1, M.NUM_NOISE_BANDS do d.noise[b] = {} end
  end
  d.noise_max = 0

  local fmt = endian .. string.rep("d", per_frame)
  local pos = 81
  for f = 1, NF do
    local v = { string.unpack(fmt, s, pos) }
    pos = v[per_frame + 1]
    d.times[f] = v[1]
    local k = 2
    for p = 1, P do
      d.amp[p][f] = v[k]; d.frq[p][f] = v[k + 1]
      if d.has_phase then d.pha[p][f] = v[k + 2] end
      k = k + per_partial
    end
    if d.has_noise then
      for b = 1, M.NUM_NOISE_BANDS do
        local n = v[k + b - 1]
        d.noise[b][f] = n
        if n > d.noise_max then d.noise_max = n end
      end
    end
  end
  return d
end

-- Writes `d` (as returned by M.load, possibly edited) to `path` in little-endian ATS format.
-- opts.phase = true keeps the phase data (only if d has it); the default drops it, because
-- edits make the stored phases wrong. Noise bands are kept when d has them.
-- ampmax and frqmax in the header are recomputed from the active points. Returns true, or nil + message.
function M.save(path, d, opts)
  opts = opts or {}
  local with_phase = opts.phase and d.has_phase
  local type_
  if d.has_noise then type_ = with_phase and 4 or 3 else type_ = with_phase and 2 or 1 end
  local P, NF = d.partials, d.frames
  local ampmax, frqmax = 0, 0
  for p = 1, P do
    local a, fr = d.amp[p], d.frq[p]
    for f = 1, NF do
      if a[f] > 0 then
        if a[f] > ampmax then ampmax = a[f] end
        if fr[f] > frqmax then frqmax = fr[f] end
      end
    end
  end
  local out = { string.pack("<dddddddddd", 123.0, d.sr, d.frame_size, d.window_size,
                            P, NF, ampmax, frqmax, d.dur, type_) }
  local per_partial = with_phase and 3 or 2
  local per_frame = 1 + per_partial * P + (d.has_noise and M.NUM_NOISE_BANDS or 0)
  local fmt = "<" .. string.rep("d", per_frame)
  local v = {}
  for f = 1, NF do
    v[1] = d.times[f]
    local k = 2
    for p = 1, P do
      v[k] = d.amp[p][f]; v[k + 1] = d.frq[p][f]
      if with_phase then v[k + 2] = d.pha[p][f] end
      k = k + per_partial
    end
    if d.has_noise then
      for b = 1, M.NUM_NOISE_BANDS do v[k + b - 1] = d.noise[b][f] end
    end
    out[#out + 1] = string.pack(fmt, table.unpack(v, 1, per_frame))
  end
  local fh, err = io.open(path, "wb")
  if not fh then return nil, "cannot write file: " .. tostring(err) end
  fh:write(table.concat(out))
  fh:close()
  return true
end

return M
