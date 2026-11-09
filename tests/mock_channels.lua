-- Run: lua5.4 tests/mock_channels.lua   (from the ReaATS folder)
-- Channel sets in the editor: opening name_chK.ats opens the whole set, channel buttons and Tab, per-channel edits and undo,
-- AUDITION and PRINT play/print ALL channels, saving and exporting a set. Fake gfx and reaper; the REAL Python engine makes
-- the three-channel analysis.
local root = os.getenv("PWD")
local scratch = "/tmp/claude-1000/-home-tjingboem/6ca29d3f-340f-46ca-9b11-e579b6c375ee/scratchpad/"
local function clean() for _, f in ipairs({ "mc_ch1.ats", "mc_ch2.ats", "mc_ch3.ats", "mc_edit_ch1.ats", "mc_edit_ch2.ats", "mc_edit_ch3.ats",
  "mc_edit2_ch1.ats", "mc_edit2_ch2.ats", "mc_edit2_ch3.ats", "xp_ch1.ats", "xp_ch2.ats", "xp_ch3.ats", "mm_ch1.ats", "mm_ch2.ats", "mc.ats",
  "mc_print1.wav", "mc_print2.wav", "mc_edit_print1.wav", "mc_edit_print2.wav", "mc_edit2_print1.wav" }) do os.remove(scratch .. f) end end
clean()

local make = io.popen("python3 -I - 2>&1", "w")
make:write(string.format([=[
import sys, subprocess; sys.path.insert(0, "%s/python")
import numpy as np
from pyatsyn import wavio
t = np.arange(88200) / 44100
tone = lambda f: 0.5*np.sin(2*np.pi*f*t)
wavio.write_wav("%smc.wav", np.stack([tone(440), tone(660), tone(880)], axis=1), 44100)
wavio.write_wav("%smm_short.wav", np.stack([tone(440)[:44100]], axis=1), 44100)
for args in (["%smc.wav", "%smc.ats", "--channels", "3", "--jobs", "1", "--lowest-frequency", "100"],
             ["%smm_short.wav", "%smm_ch2.ats", "--lowest-frequency", "100"]):
    subprocess.run([sys.executable, "-I", "%s/python/reaats_analyse.py"] + args, check=True, capture_output=True)
]=], root, scratch, scratch, scratch, scratch, scratch, scratch, root))
make:close()
-- the engine wrote mc_ch1..3.ats and mm_ch2.ats; make mm_ch1.ats a copy of channel 1 (a different length than mm_ch2)
local function copy(a, b) local fa = assert(io.open(a, "rb")); local d = fa:read("a"); fa:close(); local fb = assert(io.open(b, "wb")); fb:write(d); fb:close() end
copy(scratch .. "mc_ch1.ats", scratch .. "mm_ch1.ats")

-- fakes
local ext, strings, deferred = {}, {}, nil
local project, projext = { tracks = {} }, {}
local previews = {}
local clock_skew = 0
local chosen_save, mb_answer = nil, 6
local open_choice = nil
local function key(sec, k) return sec .. "|" .. k end
gfx = { w = 1100, h = 640, mouse_x = 0, mouse_y = 0, mouse_cap = 0, mouse_wheel = 0, x = 0, y = 0, a = 1, dest = -1 }
for _, n in ipairs({ "set", "rect", "line", "blit", "setimgdim", "setfont", "update", "init" }) do gfx[n] = function() return 0 end end
gfx.measurestr = function(s) return #s * 7, 14 end
gfx.drawstr = function(s) strings[#strings + 1] = s end
local script = { keys = {} }
gfx.getchar = function() return table.remove(script.keys, 1) or 0 end
reaper = {
  get_action_context = function() return true, root .. "/ATS_Editor.lua", 0, 0 end,
  GetExtState = function(sec, k) return ext[key(sec, k)] or "" end,
  SetExtState = function(sec, k, v) ext[key(sec, k)] = v end,
  ShowConsoleMsg = function(s) io.write("[console] ", s) end,
  file_exists = function(p) local f = io.open(p, "rb"); if f then f:close() return true end return false end,
  time_precise = function() return os.clock() + clock_skew end,
  defer = function(fn) deferred = fn end,
  GetUserFileNameForRead = function() if open_choice then return true, open_choice end return false, "" end,
  JS_Dialog_BrowseForSaveFile = function() if chosen_save then return 1, chosen_save end return 0, "" end,
  MB = function() return mb_answer end,
  PCM_Source_CreateFromFile = function(path) return { path = path } end,
  Xen_StartSourcePreview = function(src) previews[#previews + 1] = src.path; return true end,
  Xen_StopSourcePreview = function() end,
  Undo_BeginBlock = function() end, Undo_EndBlock = function() end, UpdateArrange = function() end,
  CountTracks = function() return #project.tracks end,
  InsertTrackAtIndex = function(i) table.insert(project.tracks, i + 1, { items = {}, selected = false, nchan = 2 }) end,
  GetTrack = function(_, i) return project.tracks[i + 1] end,
  GetSelectedTrack = function() for _, t in ipairs(project.tracks) do if t.selected then return t end end end,
  SetOnlyTrackSelected = function(tr) for _, t in ipairs(project.tracks) do t.selected = (t == tr) end end,
  GetSetMediaTrackInfo_String = function(tr, what, val, set) if set then tr.name = val end return true, tr.name end,
  GetMediaTrackInfo_Value = function(tr, what) if what == "I_NCHAN" then return tr.nchan end return 0 end,
  SetMediaTrackInfo_Value = function(tr, what, v) if what == "I_NCHAN" then tr.nchan = v end return true end,
  InsertMedia = function(path) local t = reaper.GetSelectedTrack(); t.items[#t.items + 1] = { src = path, guid = "{G-" .. (#t.items + 1) .. "}" }; return true end,
  CountTrackMediaItems = function(tr) return #tr.items end,
  GetTrackMediaItem = function(tr, i) return tr.items[i + 1] end,
  GetActiveTake = function(it) return it end,
  GetMediaItemTake_Source = function(take) return take end,
  GetMediaSourceFileName = function(src) return src.src end,
  GetSetMediaItemInfo_String = function(it) return true, it.guid end,
  GetSetMediaItemTakeInfo_String = function(take, what, val, set) if set then take.name = val end return true, take.name end,
  SetProjExtState = function(_, sec, k, v) projext[sec .. "|" .. k] = v; return 1 end,
  GetProjExtState = function(_, sec, k) return 1, projext[sec .. "|" .. k] or "" end,
}
local function frame() local f = deferred; deferred = nil; assert(f, "the window stopped"); f() end
local function saw(pat) for _, s in ipairs(strings) do if s:find(pat) then return s end end end
local function drawn() strings = {}; frame(); return strings end
local function click(x, y) gfx.mouse_x, gfx.mouse_y, gfx.mouse_cap = x, y, 1; frame(); gfx.mouse_cap = 0; frame(); gfx.mouse_x, gfx.mouse_y = 5, 5 end
local function press(code, cap) gfx.mouse_cap = cap or 0; script.keys = { code }; strings = {}; frame(); gfx.mouse_cap = 0 end
local function start(last)                                      -- the window starts empty; O opens the file
  ext[key("tjingboem_ATSViewer", "last_file")] = last
  deferred = nil
  dofile("ATS_Editor.lua")
  open_choice = last
  script.keys = { 111 }; frame()
  open_choice = nil
end
local function until_done(done, max_frames)
  for _ = 1, max_frames or 4000 do clock_skew = clock_skew + 0.05; strings = {}; frame(); if done() then return true end end
  error("it never finished; strings: " .. table.concat(strings, " / ", 1, math.min(#strings, 25)))
end
local ats = dofile("lib/ats_file.lua")
local wavinfo = dofile("lib/wav_info.lua")
local function button(i) return 62 + (i - 1) * 40 + 18, 77 end           -- the centre of channel button i (the header has the extra row)

-- 1. opening one channel file opens the whole set, at that channel
start(scratch .. "mc_ch2.ats"); strings = {}; frame()
assert(saw("^mc_ch2%.ats"), "the header should show channel 2's file: " .. tostring(saw("ats")))
assert(saw("^channel 2 of 3"), "the set should be recognised: " .. tostring(saw("channel")))
assert(saw("^1$") and saw("^2$") and saw("^3$"), "a button for every channel")
print("opening mc_ch2.ats opens the set of 3, at channel 2")

-- 2. the buttons and Tab switch the channel
click(button(3)); strings = {}; frame()
assert(saw("^mc_ch3%.ats") and saw("^channel 3 of 3"), "button 3")
press(9)
assert(saw("^mc_ch1%.ats") and saw("^channel 1 of 3"), "Tab goes on to channel 1 after channel 3")
click(button(2)); strings = {}; frame()
assert(saw("^mc_ch2%.ats"), "button 2")
print("channel buttons and Tab switch channels")

-- 3. edits belong to one channel; undo is per channel
click(button(1)); press(102)                                                  -- channel 1, fit
gfx.mouse_cap = 1; gfx.mouse_x, gfx.mouse_y = 65, 100; frame()
gfx.mouse_x, gfx.mouse_y = 1040, 560; frame(); gfx.mouse_cap = 0; frame(); frame()
press(6579564)                                                                -- Delete in channel 1
strings = {}; frame()
assert(saw("^1%*$"), "channel 1 shows that it has unsaved changes: " .. table.concat(strings, " / ", 1, math.min(#strings, 30)))
click(button(2)); strings = {}; frame()
assert(saw("^1%*$") and not saw("%*   |"), "channel 2 has no changes of its own; button 1 keeps its star")
click(button(1)); press(26, 4); strings = {}; frame()                         -- Ctrl+Z in channel 1
assert(not saw("^1%*$"), "undo works in the channel that was edited")
print("edits and undo are per channel")

-- 4. AUDITION plays all channels
local n_prev = #previews
press(97)
until_done(function() return #previews > n_prev end)
local info = wavinfo.read(previews[#previews])
assert(info and info.channels == 2 and info.float and info.frames > 80000, "the audition sound is mixed down to stereo: " .. tostring(info and info.channels))
assert(saw("3 channels mixed down to stereo"), "the status says so: " .. tostring(saw("auditioning")))
print("AUDITION: 3 channels mixed down to a stereo sound of " .. info.frames .. " samples")

-- 5. PRINT makes a multichannel item and the track gets room for it
press(16)
until_done(function() return project.tracks[1] and project.tracks[1].items[1] ~= nil and saw("^printed") end)
local item = project.tracks[1].items[1]
local pinfo = wavinfo.read(item.src)
assert(pinfo.channels == 3, "the printed WAV has 3 channels")
assert(project.tracks[1].nchan >= 4 and project.tracks[1].nchan % 2 == 0, "the track needs an even number of channels, at least 3: " .. project.tracks[1].nchan)
local state = dofile("lib/reaats_serial.lua").deserialize(projext["ReaATS_ItemSettings|" .. item.guid])
assert(state and #state.files == 3 and state.channel == 1 and state.files[2]:match("mc_ch2%.ats$"), "the item remembers the files of the set")
print("PRINT: a 3-channel WAV, the track has " .. project.tracks[1].nchan .. " channels, the item remembers all 3 files")

-- 6. Ctrl+S saves the whole set; it opens as a set again
click(button(2)); press(102)
gfx.mouse_cap = 1; gfx.mouse_x, gfx.mouse_y = 65, 100; frame()
gfx.mouse_x, gfx.mouse_y = 1040, 560; frame(); gfx.mouse_cap = 0; frame(); frame()
press(6579564)
press(19, 4); strings = {}; frame()
for k = 1, 3 do assert(reaper.file_exists(scratch .. "mc_edit_ch" .. k .. ".ats"), "mc_edit_ch" .. k .. ".ats should exist") end
assert(not saw("^%d%*$"), "after saving no channel has unsaved changes")
local e2 = assert(ats.load(scratch .. "mc_edit_ch2.ats")); local e1 = assert(ats.load(scratch .. "mc_edit_ch1.ats"))
local active2 = 0; for p = 1, e2.partials do for f = 1, e2.frames do if e2.amp[p][f] > 0 then active2 = active2 + 1 end end end
assert(active2 < 100, "the edited channel 2 has (almost) nothing left, the saved copy shows it: " .. active2)
start(scratch .. "mc_edit_ch3.ats"); strings = {}; frame()
assert(saw("^channel 3 of 3"), "the saved set opens as a set again")
print("Ctrl+S saves every channel as mc_edit_chK.ats; the set opens again")

-- 7. Export chooses a name for the whole set
chosen_save = scratch .. "xp.ats"
press(19, 4 + 8)
for k = 1, 3 do assert(reaper.file_exists(scratch .. "xp_ch" .. k .. ".ats"), "xp_ch" .. k .. ".ats should exist") end
print("Export writes xp_ch1.ats ... xp_ch3.ats")

-- 8. channel files that do not fit together open alone; a single file has no buttons
start(scratch .. "mm_ch1.ats"); strings = {}; frame(); strings = {}; frame()
assert(not saw("^channel %d of"), "a set whose channels differ in length opens as one file")
assert(saw("do not have the same frame grid"), "and says why: " .. tostring(saw("grid") or saw("channel")))
copy(scratch .. "mc_ch1.ats", scratch .. "mc.ats")
start(scratch .. "mc.ats"); strings = {}; frame()
assert(not saw("^channel %d of") and not saw("^3$"), "a file that is not name_chK.ats has no channel buttons")
print("mismatching channel files and single files open alone")

clean()
os.remove(scratch .. "mc.wav"); os.remove(scratch .. "mm_short.wav")
print("channel sets OK")
