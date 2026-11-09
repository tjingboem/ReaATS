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
local break_py = false
local open_choice = nil
local function key(sec, k) return sec .. "|" .. k end
gfx = { w = 1100, h = 640, mouse_x = 0, mouse_y = 0, mouse_cap = 0, mouse_wheel = 0, x = 0, y = 0, a = 1, dest = -1 }
for _, n in ipairs({ "set", "rect", "line", "circle", "setimgdim", "setfont", "update", "init" }) do gfx[n] = function() return 0 end end
local blits = {}
gfx.blit = function(src, _, _, _, _, _, h, _, dy) blits[#blits + 1] = { src = src, y = dy, h = h }; return 0 end
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
  ExecProcess = function(cmd, timeout)
    if timeout == -1 then                                          -- in the background, as in REAPER
      if break_py and cmd:find("reaats_synth", 1, true) then       -- a synthesis program that fails: it answers with an error
        local argsfile = cmd:match("%-%-args%-file (%S+)")
        local fh = io.open(argsfile, "r"); local args = fh:read("a"); fh:close()
        local result = args:match("%-%-result%-file\n([^\n]+)")
        local rf = io.open(result, "w"); rf:write("ERROR boom\n"); rf:close()
        return ""
      end
      os.execute(cmd .. " >/dev/null 2>&1 &")
      return ""
    end
    local ph = io.popen(cmd .. " 2>&1"); local out = ph:read("a"); ph:close(); return out
  end,
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
  for _ = 1, max_frames or 4000 do clock_skew = clock_skew + 0.05; strings = {}; frame(); if done() then return true end; os.execute('sleep 0.02') end
  error("it never finished; strings: " .. table.concat(strings, " / ", 1, math.min(#strings, 25)))
end
local ats = dofile("lib/ats_file.lua")
local wavinfo = dofile("lib/wav_info.lua")
local function button(i) return 62 + (i - 1) * 104 + 15, 87 end          -- the centre of channel button i (the header has the extra row)
local function slider(i, frac) return 62 + (i - 1) * 104 + 34 + math.floor(62 * frac), 87 end   -- a point on channel i's slider
local function led(i) return 62 + (i - 1) * 104 + 15, 74 end                -- the LED above button i
local MODE = { 62 + 3 * 104 + 4 + 50, 87 }                                 -- the STACK / OVERLAY button
local function lanes_now() blits = {}; strings = {}; frame(); return blits end
local function sweep(x0, y0, x1, y1)                                       -- a rubber-band drag
  gfx.mouse_cap = 1; gfx.mouse_x, gfx.mouse_y = x0, y0; frame()
  gfx.mouse_x, gfx.mouse_y = x1, y1; frame(); gfx.mouse_cap = 0; frame(); frame()
end

-- 1. opening one channel file opens the whole set; every channel is on, in a stack
start(scratch .. "mc_ch2.ats"); strings = {}; frame()
assert(saw("^mc_ch%d%.ats"), "the header shows a channel file: " .. tostring(saw("ats")))
assert(saw("^1$") and saw("^2$") and saw("^3$"), "a button for every channel")
assert(saw("^STACK$"), "the view starts as a stack")
local b = lanes_now()
assert(#b == 3 and b[1].y < b[2].y and b[2].y < b[3].y and b[1].h == b[2].h, "three lanes under each other: " .. #b)
print("opening mc_ch2.ats opens the set of 3: three lanes in a stack")

-- 2. buttons switch channels ON/OFF; one always stays on; Tab solos; V / the mode button give the overlay
click(button(3)); b = lanes_now()
assert(#b == 2 and b[1].h > 200, "channel 3 off: two taller lanes (" .. #b .. ")")
click(button(3)); b = lanes_now()
assert(#b == 3, "channel 3 on again")
click(button(1)); click(button(2)); b = lanes_now()
assert(#b == 1 and b[1].h == 486, "only channel 3 is on: a single full lane")
click(button(3)); strings = {}; frame()
assert(saw("at least one channel stays on"), "the last channel cannot be switched off")
click(button(1)); click(button(2))
press(9); b = lanes_now()
assert(#b == 1, "Tab: only channel 1")
press(9); press(9); b = lanes_now()
assert(#b == 1, "Tab twice more: only channel 3")
press(9); b = lanes_now()
assert(#b == 3, "Tab after the last channel: all again")
click(MODE[1], MODE[2]); b = lanes_now()
assert(#b == 1 and b[1].h == 486 and saw("^OVERLAY$"), "OVERLAY: all channels in one lane")
press(118); b = lanes_now()
assert(#b == 3 and saw("^STACK$"), "V goes back to the stack")
print("channel buttons switch ON/OFF (one stays on), Tab solos, STACK/OVERLAY")

-- 3. visibility sliders: 20 % .. 100 %, only on screen
click(MODE[1], MODE[2])
click(slider(1, 0)); assert(saw("channel 1 visibility 20 %%"), "the slider's left end is 20 %: " .. tostring(saw("visib")))
click(slider(1, 0.5)); assert(saw("channel 1 visibility 60 %%"), "the middle is 60 %: " .. tostring(saw("visib")))
click(slider(1, 1)); assert(saw("channel 1 visibility 100 %%"), "the right end is 100 %")
click(button(2)); click(slider(2, 0.5)); strings = {}; frame()
assert(not saw("channel 2 visibility"), "an OFF channel's slider does nothing")
click(button(2)); click(MODE[1], MODE[2])
print("visibility sliders give 20 % to 100 %")

-- 4. a region selects and every edit applies to every ON channel, as ONE undo step
press(102)                                                                    -- fit
local lane1 = lanes_now()[1]
sweep(65, 105, 1040, 100 + lane1.h - 5)
strings = {}; frame()
assert(saw("%(3 channels%)"), "the selection covers all three channels: " .. tostring(saw("selected") or "(no selection text)"))
press(6579564)
strings = {}; frame()
assert(saw("^1%*$") and saw("^2%*$") and saw("^3%*$"), "the delete reached every channel")
press(26, 4); strings = {}; frame()
assert(not saw("^%d%*$"), "ONE Ctrl+Z undoes it in every channel")
press(25, 4); strings = {}; frame()
assert(saw("^1%*$") and saw("^2%*$") and saw("^3%*$"), "and Ctrl+Y does it again in every channel")
press(26, 4)
-- with channel 2 off, only 1 and 3 are edited
click(button(2)); press(102)
lane1 = lanes_now()[1]
sweep(65, 105, 1040, 100 + lane1.h - 5)
press(6579564); strings = {}; frame()
assert(saw("^1%*$") and saw("^3%*$") and not saw("^2%*$"), "channel 2 is off: it is not edited")
press(26, 4); click(button(2))
print("a region and every edit apply to all ON channels; one undo step")

-- 4b. the LEDs: green = editable, red = left alone (and the channel stays visible)
click(led(2)); strings = {}; frame()
assert(saw("channel 2 is not editable"), "LED 2 turns red: " .. tostring(saw("channel 2") or "(no status)"))
assert(#lanes_now() == 3, "a red channel is still shown")
lane1 = lanes_now()[1]
sweep(65, 105, 1040, 100 + lane1.h - 5)
assert(saw("%(2 channels%)"), "the selection covers only the green channels: " .. tostring(saw("selected") or "(none)"))
press(6579564); strings = {}; frame()
assert(saw("^1%*$") and saw("^3%*$") and not saw("^2%*$"), "a red channel is not edited")
press(26, 4)
click(led(1)); click(led(3)); click(led(1)); click(led(3)); strings = {}; frame()
click(led(2)); strings = {}; frame()
assert(saw("channel 2 is editable"), "LED 2 turns green again")
print("LEDs: green = edited together, red = left alone")

-- 4. AUDITION plays all channels
local n_prev = #previews
press(97)
until_done(function() return #previews > n_prev end)
local info = wavinfo.read(previews[#previews])
assert(info and info.channels == 2 and info.float and info.frames > 80000, "the audition sound is mixed down to stereo: " .. tostring(info and info.channels))
assert(saw("3 channels mixed down to stereo"), "the status says so: " .. tostring(saw("auditioning")))
assert(saw("Python synthesis"), "the sound was made by the Python program: " .. tostring(saw("auditioning")))
print("AUDITION: 3 channels mixed down to a stereo sound of " .. info.frames .. " samples")

-- 4b. how much AUDITION plays (button and L), and the fallback when the Python program fails
do
  press(108); strings = {}; frame()
  assert(saw("as much as the window shows"), "L: the window length: " .. tostring(saw("AUDITION")))
  assert(saw("^plays: WINDOW$"), "the button says so")
  press(102)
  for _ = 1, 4 do gfx.mouse_wheel = 120; strings = {}; frame() end                 -- zoom in on time: a short window
  gfx.mouse_x, gfx.mouse_y = 5, 5
  local n_prev = #previews
  press(97)
  until_done(function() return #previews > n_prev end)
  local info = wavinfo.read(previews[#previews])
  assert(info.frames < 60000, "only the window is played: " .. info.frames .. " samples")
  press(108); press(108); press(108)                                                 -- 5 s, 15 s, END
  do local l1 = lanes_now()[1]; press(102); sweep(65, 105, 1040, 100 + l1.h - 5); press(6579564) end          -- (an edit: else the sound made before is used)
  break_py = true
  n_prev = #previews
  press(97)
  until_done(function() return #previews > n_prev end)
  assert(saw("Lua synthesis") and saw("Python failed with: boom"), "the failure is told and the built-in synthesis took over: " .. tostring(saw("auditioning")))
  break_py = false
  print("AUDITION length (button/L) and the fall back on Lua when the Python program fails")
end

-- 4c. nothing changed since the sound was made: AUDITION plays it again, or starts in the middle of it, without making it again
do
  press(102)
  press(108); press(108)                                                           -- length back to END (it was WINDOW, then 5 s, 15 s)
  press(108); press(108); strings = {}; frame()
  local function audition_now()                                                    -- plays at once when it can; else waits for the sound
    local n0 = #previews
    press(97)
    until_done(function() return #previews > n0 end)
    return previews[#previews]
  end
  gfx.mouse_x, gfx.mouse_y = 5, 5
  -- the playhead at the start: makes the whole sound (a new data revision first: an edit and its undo)
  local lane1 = lanes_now()[1]
  sweep(65, 105, 1040, 100 + lane1.h - 5); press(6579564); press(26, 4)
  local ruler_y = 100 + 486 + 6
  local function ruler(frac) gfx.mouse_x, gfx.mouse_y, gfx.mouse_cap = 62 + 988 * frac, ruler_y, 1; frame(); gfx.mouse_cap = 0; frame(); gfx.mouse_x, gfx.mouse_y = 5, 5 end
  ruler(0)
  local w1 = audition_now()
  local full = wavinfo.read(w1).frames
  assert(full > 80000, "the first AUDITION made the whole sound: " .. full)
  -- the same again: the same file
  local n0 = #previews
  press(97); strings = {}; frame()
  assert(#previews == n0 + 1 and previews[#previews] == w1 and saw("replayed"), "the same file again: " .. tostring(saw("auditioning")))
  -- the middle of the sound: a piece cut out, no new rendering (it starts at once)
  ruler(0.5)
  n0 = #previews
  press(97); strings = {}; frame()
  assert(#previews == n0 + 1, "it starts at once, in the next frame")
  local w2 = previews[#previews]
  assert(w2 ~= w1 and saw("from the sound already made"), "a piece of the sound: " .. tostring(saw("auditioning")))
  local half = wavinfo.read(w2).frames
  assert(half > full * 0.4 and half < full * 0.6, "about half of it: " .. half .. " of " .. full)
  assert(saw("auditioning from 1%.0%d s") or saw("auditioning from 0%.9%d s") or saw("auditioning from 1%.1%d s"), "from the middle: " .. tostring(saw("auditioning")))
  -- an edit makes a new sound
  sweep(65, 105, 1040, 100 + lane1.h - 5); press(6579564)
  local w3 = audition_now()
  assert(w3 ~= w1 and w3 ~= w2 and not saw("replayed") and not saw("already made"), "after an edit a new sound is made: " .. tostring(saw("auditioning")))
  press(26, 4)                                                                       -- undo: the data changes again
  local w4 = audition_now()
  assert(not saw("already made"), "undo is a change too")
  print("AUDITION replays the sound, or starts in its middle, while nothing has changed")
end

-- 5. PRINT makes a multichannel item and the track gets room for it
press(16)
until_done(function() return project.tracks[1] and project.tracks[1].items[1] ~= nil and saw("^printed") end)
local item = project.tracks[1].items[1]
local pinfo = wavinfo.read(item.src)
assert(pinfo.channels == 3, "the printed WAV has 3 channels")
assert(project.tracks[1].nchan >= 4 and project.tracks[1].nchan % 2 == 0, "the track needs an even number of channels, at least 3: " .. project.tracks[1].nchan)
local state = dofile("lib/reaats_serial.lua").deserialize(projext["ReaATS_ItemSettings|" .. item.guid])
assert(state and #state.files == 3 and type(state.channel) == "number" and state.files[2]:match("mc_ch2%.ats$"), "the item remembers the files of the set")
print("PRINT: a 3-channel WAV, the track has " .. project.tracks[1].nchan .. " channels, the item remembers all 3 files")

-- 6. Ctrl+S saves the whole set; it opens as a set again
press(102)
lane1 = lanes_now()[1]
sweep(65, 105, 1040, 100 + lane1.h - 5)
press(6579564)
press(19, 4); strings = {}; frame()
for k = 1, 3 do assert(reaper.file_exists(scratch .. "mc_edit_ch" .. k .. ".ats"), "mc_edit_ch" .. k .. ".ats should exist") end
assert(not saw("^%d%*$"), "after saving no channel has unsaved changes")
local e2 = assert(ats.load(scratch .. "mc_edit_ch2.ats")); local e1 = assert(ats.load(scratch .. "mc_edit_ch1.ats"))
local active2 = 0; for p = 1, e2.partials do for f = 1, e2.frames do if e2.amp[p][f] > 0 then active2 = active2 + 1 end end end
assert(active2 < 100, "the edited channel 2 has (almost) nothing left, the saved copy shows it: " .. active2)
start(scratch .. "mc_edit_ch3.ats"); strings = {}; frame()
assert(saw("^1$") and saw("^2$") and saw("^3$"), "the saved set opens as a set again")
print("Ctrl+S saves every channel as mc_edit_chK.ats; the set opens again")

-- 7. Export chooses a name for the whole set
chosen_save = scratch .. "xp.ats"
press(19, 4 + 8)
for k = 1, 3 do assert(reaper.file_exists(scratch .. "xp_ch" .. k .. ".ats"), "xp_ch" .. k .. ".ats should exist") end
print("Export writes xp_ch1.ats ... xp_ch3.ats")

-- 8. channel files that do not fit together open alone; a single file has no buttons
start(scratch .. "mm_ch1.ats"); strings = {}; frame(); strings = {}; frame()
assert(not saw("^3$") and not saw("^STACK$"), "a set whose channels differ in length opens as one file")
assert(saw("do not have the same frame grid"), "and says why: " .. tostring(saw("grid") or saw("channel")))
copy(scratch .. "mc_ch1.ats", scratch .. "mc.ats")
start(scratch .. "mc.ats"); strings = {}; frame()
assert(not saw("^3$") and not saw("^STACK$"), "a file that is not name_chK.ats has no channel buttons")
print("mismatching channel files and single files open alone")

clean()
os.remove(scratch .. "mc.wav"); os.remove(scratch .. "mm_short.wav")
print("channel sets OK")
