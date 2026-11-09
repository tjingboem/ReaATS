-- wav_info.lua -- reads only the header of a sound file (no audio): sample rate, channels, bit depth, length. WAV, AIFF/AIFC and FLAC.
-- Understands PCM and float, the WAVE_FORMAT_EXTENSIBLE variant, extra chunks, and a data size that is not filled in.

local M = {}

-- The sample rate of an AIFF file: an 80-bit IEEE extended number (10 bytes, big endian).
local function extended(b)
  local se = string.unpack(">I2", b, 1)
  local m = string.unpack(">i8", b, 3)                                          -- (Lua reads 8 bytes as a signed integer)
  local mant = (m < 0) and (m + 2.0 ^ 64) or (m * 1.0)
  if (se & 0x7FFF) == 0 and m == 0 then return 0 end
  return mant * 2.0 ^ ((se & 0x7FFF) - 16383 - 63)
end

local function read_aiff(fh, size)
  local pos = 12
  while pos + 8 <= size do
    fh:seek("set", pos)
    local chunk = fh:read(8)
    if not chunk or #chunk < 8 then break end
    local id, csize = chunk:sub(1, 4), string.unpack(">I4", chunk, 5)
    if id == "COMM" then
      local body = fh:read(math.min(csize, 40))
      if not body or #body < 18 then break end
      local channels, frames, bits = string.unpack(">i2I4i2", body, 1)
      local rate = extended(body:sub(9, 18))
      local kind = (#body >= 22) and body:sub(19, 22) or "NONE"
      if channels < 1 or rate <= 0 then return nil, "unusable AIFF header" end
      if kind == "ulaw" or kind == "alaw" or kind == "ULAW" or kind == "ALAW" or kind == "ima4" or kind == "MAC3" or kind == "MAC6" then
        return nil, "this AIFC file is compressed (" .. kind .. "): only uncompressed AIFF is supported"
      end
      return { rate = math.floor(rate + 0.5), channels = channels, bits = bits, frames = frames, seconds = frames / rate,
               float = (kind == "fl32" or kind == "FL32" or kind == "fl64" or kind == "FL64"), format = "aiff" }
    end
    pos = pos + 8 + csize + (csize % 2)
  end
  return nil, "the AIFF file has no COMM chunk"
end

local function read_flac(fh)
  fh:seek("set", 4)
  local blockhead = fh:read(4)
  if not blockhead or #blockhead < 4 or (blockhead:byte(1) & 0x7F) ~= 0 then return nil, "the FLAC file has no STREAMINFO at its start" end
  local info = fh:read(34)
  if not info or #info < 34 then return nil, "the FLAC file ends in its header" end
  local v = string.unpack(">I8", info, 11)                                       -- rate 20 bits, channels-1 3, bits-1 5, samples 36
  local rate = (v >> 44) & 0xFFFFF
  local channels = ((v >> 41) & 7) + 1
  local bits = ((v >> 36) & 31) + 1
  local frames = v & 0xFFFFFFFFF
  if rate == 0 then return nil, "unusable FLAC header" end
  return { rate = rate, channels = channels, bits = bits, frames = frames, seconds = frames / rate, float = false, format = "flac" }
end

-- Returns { rate, channels, bits, frames, seconds, float, format } or nil plus a message.
function M.read(path)
  local fh, err = io.open(path, "rb")
  if not fh then return nil, "cannot open the file: " .. tostring(err) end
  local size = fh:seek("end")
  fh:seek("set", 0)
  local head = fh:read(12)
  if head and #head >= 12 and head:sub(1, 4) == "FORM" and (head:sub(9, 12) == "AIFF" or head:sub(9, 12) == "AIFC") then
    local info, msg = read_aiff(fh, size)
    fh:close()
    return info, msg
  end
  if head and #head >= 4 and head:sub(1, 4) == "fLaC" then
    local info, msg = read_flac(fh)
    fh:close()
    return info, msg
  end
  if not head or #head < 12 or (head:sub(1, 4) ~= "RIFF" and head:sub(1, 4) ~= "RF64") or head:sub(9, 12) ~= "WAVE" then
    fh:close()
    return nil, "not a sound file the analysis can read (WAV, AIFF or FLAC; render or export other formats to WAV first)"
  end
  local fmt, data_size
  local pos = 12
  while pos + 8 <= size do
    fh:seek("set", pos)
    local chunk = fh:read(8)
    if not chunk or #chunk < 8 then break end
    local id, csize = chunk:sub(1, 4), string.unpack("<I4", chunk, 5)
    if id == "fmt " then
      fmt = fh:read(math.min(csize, 40))
    elseif id == "data" then
      if csize == 0xFFFFFFFF or pos + 8 + csize > size then csize = size - (pos + 8) end
      data_size = csize
      break
    end
    pos = pos + 8 + csize + (csize & 1)
  end
  fh:close()
  if not fmt or #fmt < 16 or not data_size then return nil, "the WAV file has no fmt or data chunk" end
  local tag, channels, rate, _, _, bits = string.unpack("<I2I2I4I4I2I2", fmt)
  if tag == 0xFFFE and #fmt >= 26 then tag = string.unpack("<I2", fmt, 25) end
  if channels < 1 or bits < 8 then return nil, "the WAV file header is not valid" end
  local frames = data_size // (channels * (bits // 8))
  return { rate = rate, channels = channels, bits = bits, frames = frames, seconds = frames / rate, float = (tag == 3), tag = tag }
end

-- Cuts `count` frames, starting `offset` frames into the sound, out of a 32-bit float WAV as written by ReaATS (a 44-byte
-- header) into a new WAV file `dst`. Returns true, or nil plus a message. Used to start AUDITION in the middle of a sound that
-- has been made already, without making it again.
function M.slice(src, dst, offset, count)
  local fh, err = io.open(src, "rb")
  if not fh then return nil, "cannot open " .. tostring(src) .. ": " .. tostring(err) end
  local head = fh:read(44)
  if not head or #head < 44 or head:sub(1, 4) ~= "RIFF" or head:sub(9, 16) ~= "WAVEfmt " or head:sub(37, 40) ~= "data" then
    fh:close()
    return nil, "not a WAV file written by ReaATS"
  end
  local tag, nch, rate, _, align, bits = string.unpack("<I2I2I4I4I2I2", head, 21)
  if tag ~= 3 or bits ~= 32 then fh:close(); return nil, "only 32-bit float WAV files can be cut" end
  fh:seek("set", 44 + offset * align)
  local body = fh:read(count * align)
  fh:close()
  if not body or #body < count * align then return nil, "the piece lies outside the sound" end
  local out, err2 = io.open(dst, "wb")
  if not out then return nil, "cannot write " .. tostring(dst) .. ": " .. tostring(err2) end
  out:write("RIFF", string.pack("<I4", 36 + #body), "WAVE")
  out:write("fmt ", string.pack("<I4I2I2I4I4I2I2", 16, 3, nch, rate, rate * align, align, 32))
  out:write("data", string.pack("<I4", #body), body)
  out:close()
  return true
end

return M
