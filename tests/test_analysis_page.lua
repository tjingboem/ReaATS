-- Run: lua5.4 tests/test_analysis_page.lua   (from the ReaATS folder)
-- The pure parts of the Analysis page: defaults, the arguments for the engine, the derived window values, file names.
package.path = "lib/?.lua;" .. package.path
reaper = { file_exists = function() return false end, GetExtState = function() return "" end }
local page = require("analysis_page")
local ok, fails = 0, 0
local function check(name, cond, extra)
  if cond then ok = ok + 1 else fails = fails + 1; print("FAIL: " .. name .. " " .. tostring(extra or "")) end
end
local function has(args, flag, value)
  for i, a in ipairs(args) do
    if a == flag then return value == nil or args[i + 1] == value end
  end
  return false
end

-- defaults match the engine's defaults (--help of the real engine lists every flag with its default)
local help = io.popen("python3 -I python/reaats_analyse.py --help 2>&1"):read("a")
local flags = 0
for key, f in pairs(page.FIELDS) do
  local list = {}
  for _, flag in ipairs({ f.cli or false, f.flag or false, f.flag_off or false }) do if flag then list[#list + 1] = flag end end
  for _, flag in ipairs(list) do
    flags = flags + 1
    check("the engine has " .. flag, help:find(flag, 1, true) ~= nil, key)
  end
end
check("checked every flag", flags == 24, flags)
for _, wt in ipairs(page.WINDOW_TYPES) do check("engine knows window type " .. wt, help:find(wt, 1, true) ~= nil, wt) end

-- arguments
local s = page.default_settings()
local a = page.build_args(s, "/x/in.wav", "/x/out.ats")
check("first two are the files", a[1] == "/x/in.wav" and a[2] == "/x/out.ats")
check("defaults: no start/duration/fft/window length", not has(a, "--start") and not has(a, "--duration") and not has(a, "--fft-size") and not has(a, "--window-length"))
check("defaults: lowest 20", has(a, "--lowest-frequency", "20"))
check("defaults: window type", has(a, "--window-type", "blackman-harris-4-1"))
check("defaults: hop 0.25", has(a, "--hop-size", "0.25"))
check("defaults: no flags for phase/noise/optimise", not has(a, "--no-phase") and not has(a, "--no-noise") and not has(a, "--no-optimize") and not has(a, "--mono-mix"))
check("always asks for the Lua summary", has(a, "--summary-format", "lua"))
s.lowest_frequency, s.start, s.duration, s.channels = 100, 0.5, 1.25, 2
s.window_type, s.fft_size, s.window_length = "hann", 8192, 2001
s.optimize, s.store_phase, s.store_noise, s.mono_mix, s.optimize_threshold_db = false, false, false, true, -50
a = page.build_args(s, "w.wav", "o.ats")
check("changed values go through", has(a, "--lowest-frequency", "100") and has(a, "--start", "0.5") and has(a, "--duration", "1.25")
  and has(a, "--channels", "2") and has(a, "--window-type", "hann") and has(a, "--fft-size", "8192") and has(a, "--window-length", "2001")
  and has(a, "--optimize-amp-threshold-db", "-50"))
check("switches become flags", has(a, "--no-optimize") and has(a, "--no-phase") and has(a, "--no-noise") and has(a, "--mono-mix"))

-- output names, the same as the engine's
local f1 = page.output_files("/m/a.ats", 1)
local f3 = page.output_files("/m/a.ats", 3)
check("one channel keeps the name", #f1 == 1 and f1[1] == "/m/a.ats")
check("three channels", #f3 == 3 and f3[1] == "/m/a_ch1.ats" and f3[3] == "/m/a_ch3.ats")

-- derived window values (compare with the engine on the sax example: -l 100 gave window 1765, hop 441, 219 frames)
local info = { rate = 44100, channels = 1, seconds = 95810 / 44100 }
local d = page.derived({ lowest_frequency = 100, window_cycles = 4, window_length = 0, hop_size = 0.25, fft_size = 0, start = 0, duration = 0 }, info)
check("window 1765", d.window == 1765, d.window)
check("hop 441", d.hop == 441, d.hop)
check("fft 2048", d.fft == 2048, d.fft)
check("frames about 219", math.abs(d.frames - 219) <= 1, d.frames)
check("window not too long", not d.too_long)
d = page.derived({ lowest_frequency = 1, window_cycles = 4, window_length = 0, hop_size = 0.25, fft_size = 0, start = 0, duration = 1.0 }, info)
check("window longer than the sound is flagged", d.too_long)
d = page.derived({ lowest_frequency = 100, window_cycles = 4, window_length = 1000, hop_size = 0.5, fft_size = 4096, start = 0.5, duration = 0 }, info)
check("forced window, fft, hop and start", d.window == 1000 and d.fft == 4096 and d.hop == 500 and math.abs(d.seconds - (95810 / 44100 - 0.5)) < 1e-9)

-- finding Python: the one REAPER is set to use comes first
local linux_ini = "[REAPER]\nverchk=0\npythonlibdll64=libpython3.12.so\npythonlibpath64=/usr/lib/x86_64-linux-gnu/\nother=1\n"
local c = page.python_candidates("\n" .. linux_ini, "Linux64", nil)
check("linux: the python of REAPER's setting is a candidate", (function() for _, p in ipairs(c) do if p == "/usr/bin/python3.12" then return true end end end)(), table.concat(c, " "))
check("linux: python3 is the last resort", c[#c] == "python3", c[#c])
local win_ini = "[REAPER]\npythonlibpath64=C:\\Python312\\\npythonlibdll64=python312.dll\n"
c = page.python_candidates("\n" .. win_ini, "Win64", nil)
check("windows: python.exe from the folder REAPER is set to", c[1] == "C:\\Python312\\python.exe", c[1])
check("windows: PATH names after it", (function() for _, p in ipairs(c) do if p == "python.exe" then return true end end end)())
c = page.python_candidates("\n[REAPER]\npythonlibpath64=/Library/Frameworks/Python.framework/Versions/3.11/lib\npythonlibdll64=libpython3.11.dylib\n", "OSX64", nil)
check("mac: the framework's bin folder", (function() for _, p in ipairs(c) do if p:find("../bin/python3.11", 1, true) then return true end end end)(), table.concat(c, " "))
c = page.python_candidates("", "Linux64", "/home/me/bin/python3")
check("a remembered python is tried first", c[1] == "/home/me/bin/python3")
c = page.python_candidates(nil, "Linux64", nil)
check("no ini: the usual places", #c >= 2)
-- the popup text
local t1 = page.python_help_text("none")
check("help: no python", t1:find("could not find Python", 1, true) and t1:find(page.PYTHON_URL, 1, true) and t1:find("Plug-ins > ReaScript", 1, true) and t1:find("Open the download page now?", 1, true))
check("help: numpy", page.python_help_text("numpy", "Python 3.12.3"):find("does not have the numpy package", 1, true) ~= nil)
check("help: old", page.python_help_text("old", "Python 3.6.1"):find("too old", 1, true) ~= nil)
check("help mentions the minimum version", t1:find("3.8", 1, true) ~= nil)

print(string.format("%d passed, %d failed", ok, fails))
os.exit(fails == 0 and 0 or 1)
