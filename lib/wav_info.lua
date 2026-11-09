-- wav_info.lua -- reads only the header of a WAV file (no audio): sample rate, channels, bit depth, length.
-- Understands PCM and float, the WAVE_FORMAT_EXTENSIBLE variant, extra chunks, and a data size that is not filled in.

local M = {}

-- Returns { rate, channels, bits, frames, seconds, float } or nil plus a message.
function M.read(path)
  local fh, err = io.open(path, "rb")
  if not fh then return nil, "cannot open the file: " .. tostring(err) end
  local size = fh:seek("end")
  fh:seek("set", 0)
  local head = fh:read(12)
  if not head or #head < 12 or (head:sub(1, 4) ~= "RIFF" and head:sub(1, 4) ~= "RF64") or head:sub(9, 12) ~= "WAVE" then
    fh:close()
    return nil, "not a WAV file (only WAV is supported; render or export the sound as WAV first)"
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

return M
