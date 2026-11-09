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
t = np.arange(88200) / 44100
wavio.write_wav("%s", np.stack([0.5*np.sin(2*np.pi*440*t), 0.5*np.sin(2*np.pi*660*t)], axis=1), 44100)
]], root, stereo))
make:close()
local fh = io.open(text_file, "w"); fh:write("this is not a sound"); fh:close()
do local a = io.open(root .. "/examples/sax.ats", "rb"); local d = a:read("a"); a:close(); local b = io.open(sax, "wb"); b:write(d); b:close() end

-- fakes
local ext, strings, deferred = {}, {}, nil
local chosen_file, input_value = stereo, ""
local selected_item = nil
local function key(sec, k) return sec .. "|" .. k end
gfx = { w = 1100, h = 640, mouse_x = 0, mouse_y = 0, mouse_cap = 0, mouse_wheel = 0, x = 0, y = 0, a = 1, dest = -1 }
for _, n in ipairs({ "set", "rect", "line", "blit", "setimgdim", "setfont", "update", "init" }) do gfx[n] = function() return 0 end end
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
  MB = function() return 6 end,
  time_precise = function() return os.clock() end,
  defer = function(fn) deferred = fn end,
  ExecProcess = function(cmd, timeout) local ph = io.popen(cmd .. " 2>&1"); local out = ph:read("a"); ph:close(); return "0\n" .. out end,
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
local function click(x, y)
  gfx.mouse_x, gfx.mouse_y, gfx.mouse_cap = x, y, 1; frame()
  gfx.mouse_cap = 0; frame()
  gfx.mouse_x, gfx.mouse_y = 5, 5
end
local function start(last_file)
  ext[key("tjingboem_ATSViewer", "last_file")] = last_file          -- the other remembered values stay, as in REAPER
  deferred = nil
  dofile("ATS_Editor.lua")
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
assert(saw("44100 Hz, 2 channel%(s%), 16 bit, 2%.00 s") or saw("44100 Hz, 2 channel%(s%), 32 bit float, 2%.00 s"), "the file info should show")
input_value = "2"; click(260, 285)
input_value = "100"; click(260, 335)
strings = {}; frame()
assert(saw("^Window 1765 samples"), "the derived window should follow the lowest frequency: " .. tostring(saw("^Window")))
click(600, 515)
strings = {}; frame()
assert(saw("^Analysed in"), "analysis message missing: " .. table.concat(strings, " / ", 1, math.min(#strings, 60)))
assert(saw("^channel 1: an_stereo_ch1%.ats") and saw("^channel 2: an_stereo_ch2%.ats"), "both channel files should be listed")
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
input_value = "3"; click(260, 285)
click(600, 515); strings = {}; frame()
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
input_value = "1"; click(260, 285)
input_value = "100"; click(260, 335)
click(600, 515); strings = {}; frame()
assert(saw("^Analysed in"), "analysis of the item failed: " .. tostring(saw("failed") or saw("^Cannot")))
assert(saw("1%.00 s%)"), "only the 1 s the item plays should be analysed: " .. tostring(saw("^channel 1")))
print("the selected item: only its part is analysed")

for _, f in ipairs({ "an_stereo_ch1.ats", "an_stereo_ch2.ats", "an_stereo.ats", "an_stereo_2.ats", "an_stereo.wav", "an_notwav.txt", "an_sax.ats" }) do os.remove(scratch .. f) end
print("analysis page OK")
