-- Run: lua5.4 tests/test_wav_info.lua   (from the ReaATS folder)
package.path = "lib/?.lua;" .. package.path
local wav = require("wav_info")
local ok, fails = 0, 0
local function check(name, cond, extra)
  if cond then ok = ok + 1 else fails = fails + 1; print("FAIL: " .. name .. " " .. tostring(extra or "")) end
end
local tmp = "/tmp/claude-1000/-home-tjingboem/6ca29d3f-340f-46ca-9b11-e579b6c375ee/scratchpad/wi_test.wav"
local function make(tag, channels, rate, bits, frames, opts)
  opts = opts or {}
  local fmt = string.pack("<I2I2I4I4I2I2", tag, channels, rate, rate * channels * bits // 8, channels * bits // 8, bits)
  if opts.extensible then
    fmt = string.pack("<I2I2I4I4I2I2", 0xFFFE, channels, rate, rate * channels * bits // 8, channels * bits // 8, bits)
      .. string.pack("<I2I2I4", 22, bits, 3) .. string.pack("<I2", tag) .. string.rep("\0", 14)
  end
  local payload = string.rep("\0", frames * channels * (bits // 8))
  local chunks = "fmt " .. string.pack("<I4", #fmt) .. fmt
  if opts.extra then chunks = chunks .. "LIST" .. string.pack("<I4", 5) .. "abcde" .. "\0" end
  chunks = chunks .. "data" .. string.pack("<I4", opts.data_size or #payload) .. payload
  local f = io.open(tmp, "wb"); f:write("RIFF", string.pack("<I4", 4 + #chunks), "WAVE", chunks); f:close()
end
make(1, 2, 44100, 16, 44100)
local i = assert(wav.read(tmp))
check("stereo 16 bit", i.rate == 44100 and i.channels == 2 and i.bits == 16 and i.frames == 44100 and math.abs(i.seconds - 1) < 1e-9 and not i.float)
make(1, 1, 48000, 24, 96000); i = assert(wav.read(tmp))
check("mono 24 bit 2 s", i.rate == 48000 and i.channels == 1 and i.bits == 24 and math.abs(i.seconds - 2) < 1e-9)
make(3, 3, 96000, 32, 1000); i = assert(wav.read(tmp))
check("three channels float", i.channels == 3 and i.float and i.frames == 1000 and i.rate == 96000)
make(1, 2, 44100, 16, 100, { extensible = true, extra = true }); i = assert(wav.read(tmp))
check("extensible and an extra chunk", i.channels == 2 and i.frames == 100)
make(1, 1, 44100, 16, 100, { data_size = 0xFFFFFFFF }); i = assert(wav.read(tmp))
check("streamed data size", i.frames == 100, i.frames)
local f = io.open(tmp, "wb"); f:write("this is not a wav file at all"); f:close()
local bad, err = wav.read(tmp)
check("rejects other files", bad == nil and err:find("not a sound file"), err)
check("missing file", wav.read("/nonexistent/x.wav") == nil)
os.remove(tmp)
-- slice: a piece cut out of a 2-channel float WAV
do
  local synth = dofile("lib/ats_synth.lua")
  local l, r = {}, {}
  for i = 1, 1000 do l[i] = i / 1000; r[i] = -i / 1000 end
  local src, dst = tmp .. ".src.wav", tmp .. ".dst.wav"
  assert(synth.write_wav_channels(src, { l, r }, 44100))
  check("slice: ok", wav.slice(src, dst, 100, 300) == true)
  local i2 = wav.read(dst)
  check("slice: 300 frames, 2 channels, float, same rate", i2 and i2.frames == 300 and i2.channels == 2 and i2.float and i2.rate == 44100)
  local fh = io.open(dst, "rb"); local data = fh:read("a"); fh:close()
  local first_l, first_r = string.unpack("<ff", data, 45)
  check("slice: starts at frame 101", math.abs(first_l - 0.101) < 1e-6 and math.abs(first_r + 0.101) < 1e-6, first_l)
  local last_l = string.unpack("<f", data, 45 + 299 * 8)
  check("slice: ends at frame 400", math.abs(last_l - 0.400) < 1e-6, last_l)
  check("slice: a piece beyond the end is refused", wav.slice(src, dst, 900, 300) == nil)
  check("slice: a file that is not ReaATS's WAV is refused", wav.slice(tmp, dst, 0, 1) == nil)
  os.remove(src); os.remove(dst)
end
-- AIFF and FLAC: the header only
do
  local function ext(rate)                                       -- an 80-bit extended number
    local e = math.floor(math.log(rate, 2))
    local mant = math.tointeger(rate) << (63 - e)                     -- (the top bit set: the same bits as an unsigned number)
    return string.pack(">I2", e + 16383) .. string.pack(">I8", mant)
  end
  local function aiff(rate, ch, frames, bits, comp)
    local comm = string.pack(">i2I4i2", ch, frames, bits) .. ext(rate) .. (comp and (comp .. "\7not cmp") or "")
    local ssnd = string.pack(">I4I4", 0, 0) .. string.rep("\0", frames * ch * (bits // 8))
    local body = (comp and "AIFC" or "AIFF") .. "COMM" .. string.pack(">I4", #comm) .. comm .. "SSND" .. string.pack(">I4", #ssnd) .. ssnd
    return "FORM" .. string.pack(">I4", #body) .. body
  end
  local function put(path, bytes) local fh = io.open(path, "wb"); fh:write(bytes); fh:close() end
  local a = tmp .. ".aif"
  put(a, aiff(44100, 2, 1000, 16))
  local i = wav.read(a)
  check("aiff: rate, channels, bits, frames", i and i.rate == 44100 and i.channels == 2 and i.bits == 16 and i.frames == 1000 and i.format == "aiff", i and i.rate)
  check("aiff: seconds", i and math.abs(i.seconds - 1000 / 44100) < 1e-9)
  put(a, aiff(48000, 1, 480, 24))
  i = wav.read(a)
  check("aiff: 48000 Hz, 24 bit, mono", i and i.rate == 48000 and i.channels == 1 and i.bits == 24 and i.frames == 480)
  put(a, aiff(22050, 2, 100, 32, "fl32"))
  i = wav.read(a)
  check("aifc: float and 22050 Hz", i and i.rate == 22050 and i.float == true and i.bits == 32, i and i.rate)
  put(a, aiff(44100, 2, 100, 16, "sowt"))
  check("aifc: little endian is fine", wav.read(a) ~= nil)
  put(a, aiff(44100, 2, 100, 8, "ulaw"))
  local bad, msg = wav.read(a)
  check("aifc: compressed is refused", bad == nil and msg:find("compressed"), msg)
  os.remove(a)
  local f = tmp .. ".flac"
  local v = (44100 << 44) | (1 << 41) | (15 << 36) | 441000
  put(f, "fLaC" .. string.char(0x80, 0, 0, 34) .. string.pack(">I2I2", 4096, 4096) .. string.rep("\0", 6) .. string.pack(">I8", v) .. string.rep("\0", 16))
  i = wav.read(f)
  check("flac: rate, channels, bits, samples", i and i.rate == 44100 and i.channels == 2 and i.bits == 16 and i.frames == 441000 and i.format == "flac", i and i.rate)
  check("flac: seconds", i and math.abs(i.seconds - 10) < 1e-9)
  put(f, "fLaC" .. string.char(0x80, 0, 0, 34) .. "short")
  check("flac: a header that ends early is refused", wav.read(f) == nil)
  os.remove(f)
end
print(string.format("%d passed, %d failed", ok, fails))
os.exit(fails == 0 and 0 or 1)
