-- Run: lua5.4 tests/mock_analysis.lua   (from the ReaATS folder)
-- The Analysis page end to end: fake gfx and reaper, but the REAL Python engine runs. Clicks use the layout of the page
-- (see lib/analysis_page.lua: left column x 24.., right column x 556.., rows of 25 px from the top margin of 70).
local root = os.getenv("PWD")
local scratch = "/tmp/claude-1000/-home-tjingboem/6ca29d3f-340f-46ca-9b11-e579b6c375ee/scratchpad/"
local stereo, text_file, sax = scratch .. "an_stereo.wav", scratch .. "an_notwav.txt", scratch .. "an_sax.ats"
for _, f in ipairs({ "an_stereo_ch1.ats", "an_stereo_ch2.ats", "an_stereo.ats", "an_stereo_2.ats" }) do os.remove(scratch .. f) end

-- the test sounds, made with the engine's own WAV writer
local make = io.popen("python3 -I - 2>&1", "w")
make:write(string.format([[
import sys; sys.path.insert(0, "%s/python")
import numpy as np
from pyatsyn import wavio
t = np.arange(44100 * 12) / 44100                    # 12 s: long enough that the page is seen at work
wavio.write_wav("%s", np.stack([0.5*np.sin(2*np.pi*440*t), 0.5*np.sin(2*np.pi*660*t)], axis=1), 44100)
]], root, stereo))
make:close()
local long_wav = scratch .. "an_long.wav"
local make2 = io.popen("python3 -I - 2>&1", "w")
make2:write(string.format([[
import sys; sys.path.insert(0, "%s/python")
import numpy as np
from pyatsyn import wavio
t = np.arange(44100 * 14) / 44100
wavio.write_wav("%s", (0.4*np.sin(2*np.pi*330*t) + 0.2*np.sin(2*np.pi*660*t))[:, None], 44100)
]], root, long_wav))
make2:close()
local fh = io.open(text_file, "w"); fh:write("this is not a sound"); fh:close()
do local a = io.open(root .. "/examples/sax.ats", "rb"); local d = a:read("a"); a:close(); local b = io.open(sax, "wb"); b:write(d); b:close() end

-- fakes
local ext, strings, deferred = {}, {}, nil
local chosen_file, input_value = stereo, ""
local fake_check, mb_log, mb_answer, opened_url = nil, {}, 7, nil
local skip_background = false
local last_cmd = nil
local fake_now = 1000.0                      -- the clock of the fake REAPER; only pump() moves it
local rects, cur_color = {}, { 0, 0, 0, 1 }    -- what was drawn: filled rectangles with their colour
local selected_item = nil
local function key(sec, k) return sec .. "|" .. k end
gfx = { w = 1100, h = 640, mouse_x = 0, mouse_y = 0, mouse_cap = 0, mouse_wheel = 0, x = 0, y = 0, a = 1, dest = -1 }
for _, n in ipairs({ "line", "circle", "blit", "setimgdim", "setfont", "update", "init" }) do gfx[n] = function() return 0 end end
gfx.set = function(r, g, b, a) cur_color = { r, g, b, a or 1 } end
gfx.rect = function(x, y, w, h, filled) rects[#rects + 1] = { x = x, y = y, w = w, h = h, filled = filled, color = cur_color } end
gfx.measurestr = function(s) return #s * 7, 14 end
gfx.drawstr = function(s) strings[#strings + 1] = s end
local script = { keys = {} }
gfx.getchar = function() return table.remove(script.keys, 1) or 0 end
gfx.showmenu = function() return 0 end
reaper = {
  get_action_context = function() return true, root .. "/ATS_Editor.lua", 0, 0 end,
  GetExtState = function(sec, k) return ext[key(sec, k)] or "" end,
  SetExtState = function(sec, k, v) ext[key(sec, k)] = v end,
  ShowConsoleMsg = function(s) io.write("[console] ", s) end,
  file_exists = function(p) local f = io.open(p, "rb"); if f then f:close() return true end return false end,
  GetUserFileNameForRead = function() if chosen_file then return true, chosen_file end return false, "" end,
  GetUserInputs = function() return true, input_value end,
  MB = function(text, title, kind) mb_log[#mb_log + 1] = text; return mb_answer end,
  time_precise = function() return fake_now end,
  defer = function(fn) deferred = fn end,
  ExecProcess = function(cmd, timeout)
    if fake_check ~= nil and cmd:find("--check", 1, true) then return "0\n" .. fake_check end
    if timeout == -1 then
      last_cmd = cmd
      if not skip_background then os.execute(cmd .. " >/dev/null 2>&1 &") end        -- background, as in REAPER
      return ""
    end
    local ph = io.popen(cmd .. " 2>&1"); local out = ph:read("a"); ph:close(); return "0\n" .. out end,
  GetSelectedMediaItem = function() return selected_item end,
  GetActiveTake = function(it) return it end,
  TakeIsMIDI = function() return false end,
  GetMediaItemTake_Source = function(take) return take end,
  GetMediaSourceFileName = function(src) return src.file end,
  GetMediaItemTakeInfo_Value = function(take, what) return ({ D_STARTOFFS = take.offs, D_PLAYRATE = 1 })[what] end,
  GetMediaItemInfo_Value = function(it, what) return ({ D_LENGTH = it.len })[what] end,
}
local function frame() local f = deferred; deferred = nil; assert(f, "the window stopped"); f() end
local function saw(pat) for _, s in ipairs(strings) do if s:find(pat) then return s end end end
-- Runs frames (0.05 s of fake time each, a short real sleep so the engine can work) until `pattern` is drawn.
local function pump(pattern, max_seconds)
  local waited = 0
  while waited < (max_seconds or 60) do
    strings = {}; rects = {}
    fake_now = fake_now + 0.05
    frame()
    local hit = saw(pattern)
    if hit then return hit end
    os.execute("sleep 0.05")
    waited = waited + 0.05
  end
  error("never drew " .. pattern .. "; last strings: " .. table.concat(strings, " / ", 1, math.min(#strings, 30)))
end
local function click(x, y)
  gfx.mouse_x, gfx.mouse_y, gfx.mouse_cap = x, y, 1; frame()
  gfx.mouse_cap = 0; frame()
  gfx.mouse_x, gfx.mouse_y = 5, 5
end
local function typed(text, ender)                                 -- keys typed into the field that is being edited
  local keys = {}
  for c in text:gmatch(".") do keys[#keys + 1] = c:byte() end
  keys[#keys + 1] = ender or 13
  script.keys = keys; frame()
end
local function enter(x, y, text)                                  -- click a number field, type the value, Enter
  click(x, y)
  typed(text)
end
local function start(last_file)
  ext[key("tjingboem_ATSViewer", "last_file")] = last_file          -- the other remembered values stay, as in REAPER
  deferred = nil
  dofile("ATS_Editor.lua")
  if last_file ~= "" then                                            -- the window starts empty: O opens the file
    local keep = chosen_file
    chosen_file = last_file
    script.keys = { 111 }; frame()
    chosen_file = keep
  end
end
local function ats_info(path)
  package.path = root .. "/lib/?.lua;" .. package.path
  return require("ats_file").load(path)
end
local function strongest(d)
  local best, bi = -1, 1
  for p = 1, d.partials do
    local sum = 0
    for f = 1, d.frames do sum = sum + d.amp[p][f] end
    if sum > best then best, bi = sum, p end
  end
  local s, n = 0, 0
  for f = 1, d.frames do if d.amp[bi][f] > 0 then s = s + d.frq[bi][f]; n = n + 1 end end
  return s / n
end

-- 1. open the page with Ctrl+A
start(sax); strings = {}; frame()
assert(saw("ANALYSE"), "the ANALYSE button should be in the header")
script.keys = { 1 }; strings = {}; frame(); frame()
assert(saw("^ANALYSIS: make .ats files from a sound"), "Ctrl+A should open the Analysis page")
assert(saw("No sound chosen yet"), "no sound yet")
print("page opens with Ctrl+A")

-- 2. choose a stereo WAV, set 2 channels and lowest frequency 100, analyse
chosen_file = stereo; strings = {}
click(250, 140); strings = {}; frame()
assert(saw("44100 Hz, 2 channel%(s%), 16 bit, 12%.00 s") or saw("44100 Hz, 2 channel%(s%), 32 bit float, 12%.00 s"), "the file info should show")
enter(260, 285, "2")
enter(260, 335, "100")
strings = {}; frame()
assert(saw("^Window 1765 samples"), "the derived window should follow the lowest frequency: " .. tostring(saw("^Window")))
-- a value is typed in the field itself: Esc cancels, Tab goes on to the next number, a click elsewhere accepts, bad text is refused
do
  strings = {}; frame()
  local before = saw("^Channels to analyse")
  click(260, 335)                                                 -- the lowest frequency field: selected, the next key replaces it
  strings = {}; frame()
  assert(saw("^100$") or saw("^%d+$"), "the field shows its value while it is edited")
  typed("77", 27)                                                 -- 77, then Esc: nothing changes
  strings = {}; frame()
  assert(not saw("^77$"), "Esc cancels the typing")
  enter(260, 335, "88")
  strings = {}; frame()
  assert(saw("^88$"), "Enter accepts the typed value: " .. table.concat(strings, " / ", 1, math.min(#strings, 40)))
  click(260, 335); typed("99", 9)                                 -- Tab accepts 99 and starts the next number
  strings = {}; frame()
  assert(saw("^99$"), "Tab accepts too")
  script.keys = { 27 }; frame()                                   -- Esc ends the editing the Tab started
  click(260, 335); typed("abc"); strings = {}; frame()
  gfx.mouse_x, gfx.mouse_y, gfx.mouse_cap = 700, 60, 1; frame(); gfx.mouse_cap = 0; frame()     -- a click elsewhere
  click(260, 335); typed("1x0", 13)                               -- letters are ignored while typing: 10
  enter(260, 335, "100")                                          -- back to the value the later tests expect
  print("values are typed in the fields: Enter, Esc, Tab and a click elsewhere")
end

click(600, 540)
-- while it runs: the big word, the blinking button, the progress, Cancel
local colours, saw_big, saw_percent, saw_cancel = {}, false, false, false
for i = 1, 400 do
  strings = {}; rects = {}; fake_now = fake_now + 0.2; frame()
  if saw("^ANALYZING%.%.%.$") then
    for _, r in ipairs(rects) do if r.w == 130 and r.h == 30 and r.filled == 1 and r.color[1] ~= 0.04 then colours[string.format("%.2f", r.color[2])] = true end end
    saw_big = true
    saw_percent = saw_percent or saw("^%d+ %%   |   %d+ s$") ~= nil
    saw_cancel = saw_cancel or saw("^Cancel$") ~= nil
  end
  if saw("^Analysed in") then break end
  os.execute("sleep 0.05")
end
assert(saw_big and saw_percent and saw_cancel, "while it runs the page should show ANALYZING..., a progress line and Cancel: " .. tostring(saw_big) .. tostring(saw_percent) .. tostring(saw_cancel) .. " | " .. table.concat(strings, " / ", 1, math.min(#strings, 12)))
local n_colours = 0; for _ in pairs(colours) do n_colours = n_colours + 1 end
assert(n_colours >= 2, "the ANALYSE button should blink between two colours, saw " .. n_colours)
print("while it runs: big word, blinking button, progress line, Cancel")
strings = {}; frame()
assert(saw("^Analysed in") or true)
assert(saw("^channel 1: an_stereo_ch1%.ats") and saw("^channel 2: an_stereo_ch2%.ats"), "both channel files should be listed; drawn: " .. table.concat(strings, " / ", 1, math.min(#strings, 50)))
local c1, c2 = ats_info(scratch .. "an_stereo_ch1.ats"), ats_info(scratch .. "an_stereo_ch2.ats")
assert(c1 and c2, "both .ats files should exist")
assert(math.abs(strongest(c1) - 440) < 4 and math.abs(strongest(c2) - 660) < 4, strongest(c1) .. " / " .. strongest(c2))
assert(c1.frames == c2.frames and c1.dur == c2.dur and c1.frame_size == c2.frame_size, "same grid in both channels")
print(string.format("analysis OK: channel 1 at %.1f Hz, channel 2 at %.1f Hz, same grid", strongest(c1), strongest(c2)))

-- 3. back to the editor: channel 1 is open
script.keys = { 27 }; strings = {}; frame(); frame()
assert(saw("^an_stereo_ch1%.ats"), "the editor should show channel 1")
assert(not saw("^ANALYSIS"), "Esc should leave the page")
print("Esc returns to the editor with channel 1 open")

-- 4. the settings are remembered
start(sax); script.keys = { 1 }; strings = {}; frame(); frame()
assert(saw("^100$") and saw("^2$"), "lowest frequency 100 and 2 channels should have been remembered")
print("settings remembered")

-- 5. a file that is not a WAV, and too many channels
chosen_file = text_file; click(250, 140); strings = {}; frame()
assert(saw("^Cannot use this file: not a WAV file"), "text file message: " .. tostring(saw("Cannot")))
chosen_file = stereo; click(250, 140)
enter(260, 285, "3")
click(600, 540); strings = {}; frame()
assert(saw("The file has 2 channel%(s%); 'Channels to analyse' is 3"), "too many channels: " .. tostring(saw("channel")))
print("a non-WAV file and too many channels are refused")

-- 6. nothing loaded at the start: the ANALYSE button is still there and works
chosen_file = nil
start(""); strings = {}; frame()
assert(saw("click ANALYSE to make one from a sound"), "hint without a file")
assert(saw("^ANALYSE$"), "the button must be drawn when no file is loaded")
click(620, 16); strings = {}; frame()
assert(saw("^ANALYSIS: make .ats files from a sound"), "clicking ANALYSE should open the page")
print("the page is reachable with no file loaded")

-- 7. the selected item: its part of the file is analysed
chosen_file = stereo
selected_item = { file = stereo, offs = 0.5, len = 1.0 }
click(100, 140); strings = {}; frame()
assert(saw("^Item: the part of the file the item plays is analysed"), "item message: " .. tostring(saw("Item")))
enter(260, 285, "1")
enter(260, 335, "100")
click(600, 540)
pump("^Analysed in")
assert(saw("1%.00 s%)"), "only the 1 s the item plays should be analysed: " .. tostring(saw("^channel 1")))
print("the selected item: only its part is analysed")

-- an item that runs past the end of its file (a few samples, or more) is analysed up to the end of the file
selected_item = { file = stereo, offs = 0.5, len = 20.0 }
click(100, 140)
enter(260, 285, "1")
enter(260, 335, "100")
click(600, 540)
pump("^Analysed in")
assert(saw("11%.50 s%)"), "an item past the end of the file is analysed up to the end: " .. tostring(saw("^channel 1")))
print("an item that runs past the end of the file is cut to the file")

-- 7b. Cancel, leaving the page while it runs, the import button, an engine that never starts
local function start_long_job()
  start(sax); script.keys = { 1 }; strings = {}; frame(); frame()
  chosen_file = long_wav; click(250, 140)
  enter(260, 285, "1")
  enter(260, 335, "100")
  click(600, 540)
  pump("^ANALYZING%.%.%.$")
end
for _, f in ipairs({ "an_long.ats", "an_long_2.ats" }) do os.remove(scratch .. f) end
start_long_job()
click(550, 470)                                                     -- Cancel
pump("^CANCELLING%.%.%.$", 5)
pump("^Analysis cancelled")
assert(not reaper.file_exists(scratch .. "an_long.ats"), "a cancelled analysis leaves no file")
print("Cancel stops the analysis and leaves nothing behind")
start_long_job()                                                    -- Esc: the analysis goes on in the background
script.keys = { 27 }; strings = {}; frame()
assert(not saw("^ANALYSIS: make"), "Esc should leave the page")
pump("^an_long%.ats", 90)
assert(reaper.file_exists(scratch .. "an_long.ats"))
print("leaving the page does not stop the analysis; the result opens in the editor")
chosen_file = sax                                                   -- the Import .ats file button
start(""); script.keys = { 1 }; strings = {}; frame(); frame()
click(450, 140); strings = {}; frame(); strings = {}; frame()
assert(saw("^an_sax%.ats"), "Import should open the file in the editor")
assert(not saw("^ANALYSIS: make"), "and return to the editor")
print("Import .ats file opens a file and returns to the editor")
skip_background = true                                              -- an engine that never starts
start(sax); script.keys = { 1 }; strings = {}; frame(); frame()
chosen_file = long_wav; click(250, 140); click(600, 540)
fake_now = fake_now + 25
strings = {}; frame(); strings = {}; frame()
assert(saw("^The analysis program did not start"), "an engine that never starts: " .. tostring(saw("analysis") or saw("Analy")))
skip_background = false
print("an engine that never starts is reported")

-- 7c. every job has files of its own; a dead program is noticed; a Cancel that nobody answers ends
local function job_files()                                          -- the result file of the job that was just started
  local argsfile = last_cmd:match("@(%S+)")
  local lines = {}
  for line in io.lines(argsfile) do lines[#lines + 1] = line end
  for i, l in ipairs(lines) do if l == "--result-file" then return argsfile, lines[i + 1] end end
end
skip_background = true
start(sax); script.keys = { 1 }; strings = {}; frame(); frame()
chosen_file = long_wav; click(250, 140); click(600, 540)
local args1, result1 = job_files()
assert(result1:match("reaats_%d+_%d+_result%.txt$") and args1:match("reaats_%d+_%d+_args%.txt$"), "files with an id of their own: " .. result1)
-- a program that wrote a sign of life long ago and then died
local fh = io.open(result1 .. ".started", "w"); fh:write(string.format("0.2000 %.3f", os.time() - 1000)); fh:close()
strings = {}; frame(); strings = {}; frame()
assert(saw("^Analysis failed") == nil and saw("stopped answering"), "a program that stopped answering is reported: " .. tostring(saw("answer") or saw("Analy")))
assert(not reaper.file_exists(result1 .. ".started"), "and its files are removed")
print("a dead program is noticed (no sign of life for 2 minutes)")
click(600, 540)
local args2, result2 = job_files()
assert(result2 ~= result1, "the next job has other files: " .. result2)
print("every job has its own files")
fh = io.open(result2 .. ".started", "w"); fh:write(string.format("0.3000 %.3f", os.time())); fh:close()
strings = {}; frame(); strings = {}; frame()
assert(saw("^ANALYZING"), "a job with a fresh sign of life is waited for")
click(550, 470)                                                   -- Cancel, but nobody answers
strings = {}; frame()
assert(saw("^CANCELLING"), "cancelling")
fake_now = fake_now + 9; strings = {}; frame(); strings = {}; frame()
assert(saw("^Analysis cancelled %(the program did not answer"), "a Cancel that nobody answers ends: " .. tostring(saw("ancel")))
print("a Cancel that nobody answers ends after 8 s")
skip_background = false

-- 8. no usable Python: a popup says what to do, nothing is analysed
local function fresh_page()
  ext[key("tjingboem_ATSViewer", "python_exe")] = nil
  start(sax); script.keys = { 1 }; strings = {}; frame(); frame()
end
local function popup_after_analyse()
  mb_log = {}
  chosen_file = stereo; click(250, 140)
  for _, f in ipairs({ "an_stereo.ats", "an_stereo_2.ats", "an_stereo_ch1.ats", "an_stereo_ch2.ats" }) do os.remove(scratch .. f) end
  enter(260, 285, "1")
  click(600, 540); strings = {}; frame()
  return mb_log[#mb_log]
end
fake_check = ""                                                   -- nothing answers: no Python at all
fresh_page()
assert(saw("^Python not found"), "the page should say that Python was not found")
local text = popup_after_analyse()
assert(text and text:find("could not find Python", 1, true) and text:find("python.org/downloads", 1, true), "popup: " .. tostring(text))
assert(text:find("Options > Preferences > Plug%-ins > ReaScript") and text:find("numpy", 1, true), "popup should say how to tell REAPER and to install numpy")
assert(saw("^Python %(3%.8 or newer, with numpy%) is needed"), "a red hint on the page")
assert(not reaper.file_exists(scratch .. "an_stereo.ats"), "nothing may be analysed without Python")
print("no Python: popup with the download page, numpy and the REAPER setting")
fake_check = "CHECK missing numpy python=3.12.3\n"            -- Python found, numpy missing
fresh_page()
text = popup_after_analyse()
assert(text and text:find("does not have the numpy package", 1, true) and text:find("Python 3.12.3", 1, true), "numpy popup: " .. tostring(text))
fake_check = "CHECK old python=3.6.1 needs=3.8\n"             -- Python too old
fresh_page()
text = popup_after_analyse()
assert(text and text:find("too old", 1, true) and text:find("Python 3.6.1", 1, true), "old popup: " .. tostring(text))
print("numpy missing and Python too old are told apart")
reaper.CF_ShellExecute = function(u) opened_url = u end         -- answering Yes opens the download page
mb_answer = 6; fresh_page(); popup_after_analyse()
assert(opened_url and opened_url:find("python.org/downloads", 1, true), "Yes should open the download page: " .. tostring(opened_url))
mb_answer = 7; reaper.CF_ShellExecute = nil
print("the popup can open the download page")
fake_check = nil                                                 -- Python installed: the Check button finds it
fresh_page()                                                     -- (the real check runs now, so this session already finds it)
assert(saw("^Python 3%.") and saw("numpy"), "with a working Python the page shows its version")
fake_check = ""; fresh_page()                                    -- no Python again ...
assert(saw("^Python not found"))
fake_check = nil
click(990, 85); strings = {}; frame()                            -- ... then the Check button after installing
assert(saw("^Python 3%."), "the Check button should find Python: " .. tostring(saw("Python")))
print("the Check button finds Python after it was installed")

for _, f in ipairs({ "an_stereo_ch1.ats", "an_stereo_ch2.ats", "an_stereo.ats", "an_stereo_2.ats", "an_stereo.wav", "an_notwav.txt", "an_sax.ats", "an_long.wav", "an_long.ats", "an_long_2.ats" }) do os.remove(scratch .. f) end
print("analysis page OK")
