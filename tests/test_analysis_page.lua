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
check("checked every flag", flags == 26, flags)
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
check("no result file unless asked", not has(a, "--result-file"))
check("background mode asks for a result file", has(page.build_args(s, "/x/in.wav", "/x/out.ats", "/tmp/r.txt"), "--result-file", "/tmp/r.txt"))
s.lowest_frequency, s.start, s.duration, s.channels = 100, 0.5, 1.25, 2
s.window_type, s.fft_size, s.window_length = "hann", 8192, 2001
s.optimize, s.store_phase, s.store_noise, s.mono_mix, s.optimize_threshold_db = false, false, false, true, -50
a = page.build_args(s, "w.wav", "o.ats")
check("changed values go through", has(a, "--lowest-frequency", "100") and has(a, "--start", "0.5") and has(a, "--duration", "1.25")
  and has(a, "--channels", "2") and has(a, "--window-type", "hann") and has(a, "--fft-size", "8192") and has(a, "--window-length", "2001")
  and has(a, "--optimize-amp-threshold-db", "-50"))
check("switches become flags", has(a, "--no-optimize") and has(a, "--no-phase") and has(a, "--no-noise") and has(a, "--mono-mix"))

-- cores
check("jobs: not passed unless set", not has(page.build_args(page.default_settings(), "a.wav", "o.ats"), "--jobs"))
local sj = page.default_settings(); sj.jobs = 3
check("jobs: passed when set", has(page.build_args(sj, "a.wav", "o.ats"), "--jobs", "3"))
check("workers: automatic leaves two cores", page.workers({ jobs = 0, channels = 8, mono_mix = false }, 8) == 6)
check("workers: never more than the channels", page.workers({ jobs = 0, channels = 2, mono_mix = false }, 8) == 2)
check("workers: asked for 4 of 8 channels", page.workers({ jobs = 4, channels = 8, mono_mix = false }, 8) == 4)
check("workers: never fewer than one", page.workers({ jobs = 0, channels = 4, mono_mix = false }, 2) == 1)
check("workers: mono mix is one channel", page.workers({ jobs = 0, channels = 4, mono_mix = true }, 8) == 1)

-- the long-sound warning
do
  local long = { rate = 48000, channels = 2, seconds = 536.5 }
  local base = page.default_settings()
  check("a long sound at -60 dB is warned about", page.long_warning(base, long) ~= nil)
  local s40 = page.default_settings(); s40.amp_threshold_db = -40
  check("at -40 dB it is not", page.long_warning(s40, long) == nil)
  check("a short sound at -60 dB is not", page.long_warning(base, { rate = 48000, channels = 1, seconds = 20 }) == nil)
  local part = page.default_settings(); part.duration = 30
  check("a short part of a long sound is not", page.long_warning(part, long) == nil)
  local from = page.default_settings(); from.start = 500
  check("a short rest of a long sound is not", page.long_warning(from, long) == nil)
  check("no sound, no warning", page.long_warning(base, nil) == nil)
end

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

check("clock: under a minute shows nothing", page.clock(59.2) == "" and page.clock(2.17) == "")
check("clock: 536 s is 8:56", page.clock(536.4) == "8:56")
check("clock: rounds to the second, 59.6 s is 1:00", page.clock(59.6) == "1:00")
check("clock: an hour and more", page.clock(3725) == "1:02:05")
-- advice about settings that put a lot of the sound into the noise
do
  local info = { rate = 44100, channels = 1, seconds = 20 }
  local s = page.default_settings()
  check("advice: the defaults give none", page.noise_advice(s, info) == nil)
  s.amp_threshold_db = -40
  local a = page.noise_advice(s, info)
  check("advice: -40 dB on a short sound", a and a:find("%-40 dB") and a:find("loud"), a)
  s.amp_threshold_db = -60; s.highest_frequency = 5000
  a = page.noise_advice(s, info)
  check("advice: a low highest frequency", a and a:find("5000 Hz"), a)
  s.highest_frequency = 20000; s.amp_threshold_db = -40
  check("advice: none for a long sound", page.noise_advice(s, { rate = 48000, channels = 2, seconds = 536 }) == nil)
  check("advice: none without a sound", page.noise_advice(s, nil) == nil)
end

-- the values that the suggestions changed are shown in red on the settings page, until they are changed by hand (tjingboem, 11 Nov 2026)
do
  local colour, drawn = { 0, 0, 0 }, {}
  gfx = { w = 1100, h = 640, x = 0, y = 0, mouse_x = 0, mouse_y = 0, mouse_cap = 0 }
  function gfx.set(r, g, b) colour = { r, g, b } end
  function gfx.setfont() end
  function gfx.rect() end
  function gfx.line() end
  function gfx.circle() end
  function gfx.measurestr(t) return #t * 7 end
  function gfx.drawstr(t) drawn[#drawn + 1] = { s = t, r = colour[1], g = colour[2], b = colour[3] } end
  reaper.time_precise = function() return 1000 end
  reaper.SetExtState = function() end
  local layout = dofile("lib/analysis_layout.lua")
  local pg = page.new({ layout = layout, serial = { deserialize = function() return nil end }, ext_section = "x", script_dir = ".", set_status = function() end,
                        on_open = function() return true end, back = function() end, redraw = function() end, wav_info = {} })
  pg.python = { exe = "python3", version = "3.12", numpy = "1", cores = 4 }
  pg.wav, pg.info, pg.out = "/m/a.wav", { rate = 44100, channels = 1, bits = 16, float = false, seconds = 5 }, "/m/a.ats"
  pg.s.lowest_frequency, pg.s.amp_threshold_db, pg.s.hop_size = 20, -60, 0.25
  pg.suggest = { lowest_frequency = { v = 210, why = "x" }, amp_threshold_db = { v = -60, why = "y" }, hop_size = { v = 0.125, why = "z" }, window_cycles = { v = 4, why = "w" } }
  local function value_colour(text)
    drawn = {}
    pg:draw(1100, 640, 40)
    for _, d in ipairs(drawn) do if d.s == text then return d end end
  end
  local before = value_colour("210")
  check("before: a value is not red", before == nil)                      -- (the old value 20 is drawn, 210 only as a suggestion arrow)
  pg:apply_all_suggestions()
  check("what a suggestion changed is marked", pg.changed.lowest_frequency and pg.changed.hop_size, "")
  check("what it did not change is not marked", not pg.changed.amp_threshold_db and not pg.changed.window_cycles)
  pg.view = nil
  local lf = value_colour("210")
  check("the changed value is drawn in red", lf and lf.r > 0.9 and lf.g < 0.5, lf and (lf.r .. "," .. lf.g))
  local thr = value_colour("-60")
  check("an unchanged value keeps its colour", thr and thr.g > 0.8, thr and thr.g)
  pg:begin_edit("hop_size")
  check("typing in a field takes the red away", not pg.changed.hop_size)
  pg.edit = nil
  pg:step("lowest_frequency", 1, false)
  check("the mouse wheel takes it away too", not pg.changed.lowest_frequency)
  pg.changed.amp_threshold_db = true
  pg:set_defaults(false)
  check("Defaults clears the red", next(pg.changed) == nil)
end

print(string.format("%d passed, %d failed", ok, fails))
os.exit(fails == 0 and 0 or 1)
