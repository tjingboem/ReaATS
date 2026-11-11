REAATS_SHOW_AUDITION_TEXT = true                         -- (the messages of AUDITION are not shown in the real editor; these tests read them)
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
exit_fns = {}
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
  atexit = function(fn) exit_fns[#exit_fns + 1] = fn end,
  EnumerateFiles = function(dir, i)
    local list = {}
    local ph = io.popen('ls "' .. dir .. '" 2>/dev/null'); for l in ph:lines() do list[#list + 1] = l end; ph:close()
    return list[i + 1]
  end,
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
local function sweep(x0, y0, x1, y1)                                       -- a rubber-band drag (Esc first: no old selection with its box and dots is in the way)
  gfx.mouse_cap = 0; script.keys = { 27 }; frame(); gfx.mouse_x, gfx.mouse_y = 5, 5; frame()                     -- Esc: no old selection with its box and dots is in the way
  gfx.mouse_cap = 1; gfx.mouse_x, gfx.mouse_y = x0, y0; frame()
  gfx.mouse_x, gfx.mouse_y = x1, y1; frame(); gfx.mouse_cap = 0; frame(); frame()
end

-- 0. temporary files that an earlier editor left behind (old by the time in their names) are removed at the start, recent ones are not
do
  local tmp = assert(os.getenv("TMPDIR"))
  local old = tmp .. "/reaats_audition_1100000000_111111_1.wav"
  local old_job = tmp .. "/reaats_1100000000_111111_s2_ch1_edits.bin"
  local fresh = string.format("%s/reaats_audition_%d_222222_1.wav", tmp, os.time())
  local other = tmp .. "/reaats_not_ours.txt"
  for _, f in ipairs({ old, old_job, fresh, other }) do local fh = io.open(f, "w"); fh:write("x"); fh:close() end
  start(scratch .. "mc_ch2.ats")
  local function exists(f) local fh = io.open(f, "r"); if fh then fh:close(); return true end return false end
  assert(not exists(old) and not exists(old_job), "old temporary files are removed at the start")
  assert(exists(fresh) and exists(other), "recent files and other files are left alone")
  os.remove(fresh); os.remove(other)
  print("old temporary files are removed at the start")
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

-- 4a. when the editor closes, its sounds are removed
do
  local wavs = {}
  for _, w in ipairs(previews) do wavs[#wavs + 1] = w end
  local function exists(f) local fh = io.open(f, "r"); if fh then fh:close(); return true end return false end
  local before = 0
  for _, w in ipairs(wavs) do if exists(w) then before = before + 1 end end
  assert(before > 0, "there are sounds to remove")
  for _, fn in ipairs(exit_fns) do fn() end
  local last = previews[#previews]
  assert(not exists(last), "the last sound is removed when the editor closes")
  print("sounds are removed when the editor closes")
end

-- 4b. a right-click shows the whole file, and the fallback when the Python program fails
do
  press(102)
  for _ = 1, 4 do gfx.mouse_wheel = 120; strings = {}; frame() end                 -- zoom in on time
  gfx.mouse_x, gfx.mouse_y = 5, 5
  local n_prev = #previews
  -- a right-click without a drag shows the whole file again (the view was zoomed in above); a right-drag pans instead
  gfx.mouse_x, gfx.mouse_y, gfx.mouse_cap = 500, 250, 2; frame(); gfx.mouse_cap = 0; strings = {}; frame()
  assert(saw("whole file in view"), "right-click: the whole file: " .. tostring(saw("view") or saw("whole")))
  for _ = 1, 4 do gfx.mouse_x, gfx.mouse_y, gfx.mouse_wheel = 500, 250, 120; frame() end
  clock_skew = clock_skew + 30                                                       -- (the old status message has gone)
  gfx.mouse_x, gfx.mouse_y, gfx.mouse_cap = 500, 250, 2; frame(); gfx.mouse_x = 600; frame(); gfx.mouse_cap = 0; strings = {}; frame()
  assert(not saw("whole file in view"), "a right-drag pans, it does not fit the view")
  press(102)
  gfx.mouse_x, gfx.mouse_y = 5, 5
  do local l1 = lanes_now()[1]; press(102); sweep(65, 105, 1040, 100 + l1.h - 5); press(6579564) end          -- (an edit: else the sound made before is used)
  break_py = true
  n_prev = #previews
  press(97)
  until_done(function() return #previews > n_prev end)
  assert(saw("Lua synthesis") and saw("Python failed with: boom"), "the failure is told and the built-in synthesis took over: " .. tostring(saw("auditioning")))
  break_py = false
  print("right-click shows the whole file; the fall back on Lua when the Python program fails")
end

-- 4c. nothing changed since the sound was made: AUDITION plays it again, or starts in the middle of it, without making it again
do
  press(102)
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

-- 4d. copy, cut and paste: the selected points of every green channel, pasted at the playhead into the same channels, one undo step
do
  press(102)
  gfx.mouse_x, gfx.mouse_y = 5, 5
  local function ruler2(frac) gfx.mouse_x, gfx.mouse_y, gfx.mouse_cap = 62 + 988 * frac, 100 + 486 + 6, 1; frame(); gfx.mouse_cap = 0; frame(); gfx.mouse_x, gfx.mouse_y = 5, 5 end
  strings = {}; frame()
  while saw("^%d%*$") do press(26, 4); strings = {}; frame() end                    -- start without unsaved changes (undo what the tests above left)
  press(22); assert(saw("nothing copied yet"), "paste with an empty clipboard says so: " .. tostring(saw("copied") or saw("paste")))
  local lane1 = lanes_now()[1]
  sweep(65, 105, 600, 100 + lane1.h - 5)                                              -- the first half of the sound, all three channels
  strings = {}; frame()
  assert(saw("%(3 channels%)"), "three channels selected")
  press(3); strings = {}; frame()
  assert(saw("copied %d+ points from 3 channels"), "Ctrl+C: " .. tostring(saw("copied") or saw("select")))
  assert(not saw("^%d%*$"), "copying changes nothing")
  ruler2(0.4)
  press(22); strings = {}; frame()
  assert(saw("pasted %d+ points at [0-9.]+ s in 3 channels %(they are selected now%)"), "Ctrl+V: " .. tostring(saw("pasted") or saw("paste")))
  assert(saw("^1%*$") and saw("^2%*$") and saw("^3%*$"), "every channel has the paste")
  assert(saw("%(3 channels%)"), "the pasted points are selected, in all three channels")
  press(26, 4); strings = {}; frame()
  assert(not saw("^%d%*$"), "ONE Ctrl+Z takes the paste back from every channel")
  press(25, 4); strings = {}; frame()
  assert(saw("^1%*$") and saw("^3%*$"), "and Ctrl+Y does it again")
  press(26, 4)
  -- a channel that is red does not get its part
  click(led(2)); strings = {}; frame()
  press(22); strings = {}; frame()
  assert(saw("pasted %d+ points .* in 2 channels"), "channel 2 is red: the paste goes to 1 and 3 only: " .. tostring(saw("pasted")))
  assert(saw("^1%*$") and saw("^3%*$") and not saw("^2%*$"), "stars on 1 and 3")
  press(26, 4); click(led(2))
  -- cut = copy + delete; the clipboard can be pasted somewhere else
  sweep(65, 105, 300, 100 + lane1.h - 5)
  press(24); strings = {}; frame()
  assert(saw("^1%*$"), "Ctrl+X deletes what it copied")
  ruler2(0.8)
  press(22); strings = {}; frame()
  assert(saw("pasted"), "and the cut points can be pasted: " .. tostring(saw("pasted") or saw("paste")))
  press(26, 4); press(26, 4)
  print("copy, cut and paste work across the channels, in one undo step")
end

-- 4e. Ctrl+Shift+drag draws a lasso; the points inside the loop are selected, in every green channel; it adds to the selection
do
  press(102)
  gfx.mouse_x, gfx.mouse_y = 5, 5
  local lane1 = lanes_now()[1]
  local y_top, y_bot = 105, 100 + lane1.h - 5
  local function selected_count() strings = {}; frame(); local t = saw("^selected: (%d+) points"); return t and tonumber(t:match("^selected: (%d+)")) or 0, t end
  sweep(65, y_top, 600, y_bot)
  local n_box, t_box = selected_count()
  assert(n_box > 0 and t_box:find("3 channels"), "the box selected something in 3 channels: " .. tostring(t_box))
  press(27)
  assert(selected_count() == 0, "cleared")
  local function lasso_through(points, cap)
    gfx.mouse_cap = cap; gfx.mouse_x, gfx.mouse_y = points[1][1], points[1][2]; frame()
    for i = 2, #points do gfx.mouse_x, gfx.mouse_y = points[i][1], points[i][2]; frame() end
    strings = {}; frame(); cross_label = saw("^[%d%.]+ s   ")                   -- (while drawing: the crosshair says where the pointer is)
    gfx.mouse_cap = 0; frame(); frame(); gfx.mouse_x, gfx.mouse_y = 5, 5
  end
  -- the same rectangle, drawn as a loop with Ctrl+Shift held: the same points
  lasso_through({ { 65, y_top }, { 330, y_top }, { 600, y_top }, { 600, (y_top + y_bot) / 2 }, { 600, y_bot }, { 330, y_bot }, { 65, y_bot }, { 65, (y_top + y_bot) / 2 } }, 1 + 4 + 8)
  assert(cross_label, "while a lasso is drawn the crosshair shows time and frequency")
  local n_lasso, t_lasso = selected_count()
  assert(n_lasso == n_box and t_lasso:find("3 channels"), "the lasso round the same rectangle selects the same: " .. n_lasso .. " against " .. n_box)
  -- a triangle holds fewer points than the rectangle round it
  press(27)
  lasso_through({ { 65, y_bot }, { 332, y_top }, { 600, y_bot } }, 1 + 4 + 8)
  local n_tri = selected_count()
  assert(n_tri > 0 and n_tri < n_box, "a triangle selects part of the rectangle: " .. n_tri .. " of " .. n_box)
  -- a lasso adds to what is selected: a second loop is added to the first
  press(27)
  lasso_through({ { 65, y_top }, { 200, y_top }, { 200, y_bot }, { 65, y_bot } }, 1 + 4 + 8)
  local n_a = selected_count()
  lasso_through({ { 300, y_top }, { 450, y_top }, { 450, y_bot }, { 300, y_bot } }, 1 + 4 + 8)
  local n_ab = selected_count()
  assert(n_a > 0 and n_ab > n_a, "a second lasso adds: " .. n_a .. " then " .. n_ab)
  press(27)
  print("Ctrl+Shift+drag lasso selects the points inside the loop")
end

-- 4f. the playhead: the "|<" button shows where it is when it is not at the start, and Home or the button put it back at 0
do
  local function ruler3(frac) gfx.mouse_x, gfx.mouse_y, gfx.mouse_cap = 62 + 988 * frac, 100 + 486 + 6, 1; frame(); gfx.mouse_cap = 0; frame(); gfx.mouse_x, gfx.mouse_y = 5, 5 end
  press(102)
  ruler3(0.6); strings = {}; frame()
  assert(saw("^|<$"), "the small button (the layout makes it 20 px wide) shows only the arrow: " .. tostring(saw("|<")))
  clock_skew = clock_skew + 30
  press(1752132965); strings = {}; frame()
  assert(saw("playhead at the start"), "Home puts the playhead at the start: " .. tostring(saw("playhead") or "(no status)"))
  ruler3(0.6); strings = {}; frame()
  click(834, 41); strings = {}; frame()
  assert(saw("playhead at the start"), "a click on the button puts it back too: " .. tostring(saw("playhead") or "(no status)"))
  ruler3(0.3)
  press(6647396); strings = {}; frame()
  assert(saw("playhead at the end"), "End puts it at the end")
  press(1752132965)
  print("the playhead: shown on the |< button, Home and the button go to the start")
end

-- 4g. the box round the selection with dots that bend it: a corner dragged, Enter applies (one undo step, every green channel), Esc cancels
do
  press(102)
  gfx.mouse_x, gfx.mouse_y = 5, 5
  local lane1 = lanes_now()[1]
  local y_top, y_bot = 105, 100 + lane1.h - 5
  sweep(65, y_top, 600, y_bot)
  strings = {}; frame()
  assert(saw("%(3 channels%)"), "the selection to bend, in three channels")
  local function hold_and_drag(x, y, dx, dy, cap)
    gfx.mouse_cap = cap or 1; gfx.mouse_x, gfx.mouse_y = x, y; frame()
    gfx.mouse_x, gfx.mouse_y = x + dx / 2, y + dy / 2; frame()
    gfx.mouse_x, gfx.mouse_y = x + dx, y + dy; frame()
    strings = {}; frame()
  end
  local function let_go() gfx.mouse_cap = 0; frame(); gfx.mouse_x, gfx.mouse_y = 5, 5 end
  -- the top right corner of the box, dragged down 30 px
  hold_and_drag(600, y_top, 0, 30)
  local live = saw("^bend [%+%-][%d%.]+ st: Enter applies")
  assert(live and live:find("%-"), "dragging a corner dot shows the bend (down is negative): " .. tostring(live))
  assert(saw("^bend up to [%d%.]+ st"), "and the box says what it would do: " .. tostring(saw("bend up to")))
  let_go(); strings = {}; frame()
  assert(not saw("^%d%*$"), "nothing is changed before Enter")
  press(13); strings = {}; frame()
  assert(saw("^1%*$") and saw("^2%*$") and saw("^3%*$"), "Enter applies the bend in every green channel: " .. tostring(saw("bend") or "(no status)"))
  assert(saw("%(3 channels%)"), "the points stay selected after the bend")
  press(26, 4); strings = {}; frame()
  assert(not saw("^%d%*$"), "ONE Ctrl+Z takes the bend back from every channel")
  -- time: the top right corner dragged to the right is a stretch; Enter applies it (frames are made again), one undo step
  sweep(65, y_top, 600, y_bot)
  hold_and_drag(600, y_top, 50, 0)
  live = saw("^bend %+[%d%.]+ ms: Enter applies")
  assert(live, "dragging a corner sideways shows the time displacement: " .. tostring(saw("^bend")))
  assert(saw("^bend in time up to %d+ ms"), "and the box says what it would do: " .. tostring(saw("bend in")))
  let_go(); strings = {}; frame()
  assert(not saw("^%d%*$"), "nothing is changed before Enter")
  press(13); strings = {}; frame()
  assert(saw("^1%*$") and saw("^2%*$") and saw("^3%*$"), "Enter applies the stretch in every green channel: " .. tostring(saw("bend") or "(no status)"))
  assert(saw("%(3 channels%)"), "the stretched points stay selected")
  press(26, 4); strings = {}; frame()
  assert(not saw("^%d%*$"), "ONE Ctrl+Z takes the stretch back")
  -- with the Noise layer on, the noise bands in the box follow the stretch (the status says so); one undo step
  sweep(65, y_top, 600, y_bot)
  hold_and_drag(600, y_top, 50, 0); let_go()
  press(13); strings = {}; frame()
  assert(saw("and the noise"), "the noise follows the stretch: " .. tostring(saw("bend") or saw("points") or "(no status)"))
  press(26, 4); strings = {}; frame()
  assert(not saw("^%d%*$"), "ONE Ctrl+Z takes sines and noise back")
  -- a stretch past the end of the file makes the file longer, in every channel, as one undo step
  strings = {}; frame()
  clock_skew = clock_skew + 30; strings = {}; frame()                          -- (a message of the last action takes the place of the numbers for a while)
  assert(saw("   2%.00 s   "), "the file is 2.00 s: " .. tostring(saw("partials")))
  sweep(65, y_top, 1040, y_bot)
  hold_and_drag(1040, y_top, 200, 0); let_go()
  press(13); strings = {}; frame()
  assert(saw("the file is 0%.%d%d s longer now"), "the status says how much longer: " .. tostring(saw("bend") or "(no status)"))
  clock_skew = clock_skew + 30; strings = {}; frame()                          -- (a message of the last action takes the place of the numbers for a while)
  assert(saw("   2%.[1-6]%d s   "), "the duration in the header is longer now: " .. tostring(saw("partials")))
  assert(saw("^1%*$") and saw("^2%*$") and saw("^3%*$"), "every channel changed")
  press(26, 4); strings = {}; frame()
  clock_skew = clock_skew + 30; strings = {}; frame()                          -- (a message of the last action takes the place of the numbers for a while)
  assert(saw("   2%.00 s   ") and not saw("^%d%*$"), "ONE Ctrl+Z makes the file 2.00 s again, in every channel: " .. tostring(saw("partials")))
  press(25, 4); strings = {}; frame()
  clock_skew = clock_skew + 30; strings = {}; frame()                          -- (a message of the last action takes the place of the numbers for a while)
  assert(saw("   2%.[1-6]%d s   "), "Ctrl+Y makes it longer again: " .. tostring(saw("partials")))
  press(26, 4); strings = {}; frame()
  -- the handle in the middle of the right edge: dragged sideways it STRETCHES the box (the left edge stays), it does not move the selection
  sweep(65, y_top, 600, y_bot)
  local y_mid = math.floor((y_top + y_bot) / 2)
  hold_and_drag(600, y_mid, 60, 0)
  live = saw("^bend %+%d+ ms: Enter applies")
  assert(live and not saw("^move"), "the middle handle of the right edge stretches in time: " .. tostring(saw("^bend") or saw("^move") or "(nothing)"))
  let_go(); strings = {}; frame()
  assert(not saw("^%d%*$"), "nothing changes before Enter")
  press(13); strings = {}; frame()
  assert(saw("^1%*$") and saw("^3%*$") and saw("bend in time up to"), "Enter applies the stretch: " .. tostring(saw("bend") or "(none)"))
  press(26, 4); strings = {}; frame()
  assert(not saw("^%d%*$"), "and Ctrl+Z takes it back")
  -- a stretch to before 0 puts frames in front: everything in the file moves later; one undo step, every channel
  press(102)
  sweep(65, y_top, 1040, y_bot)
  hold_and_drag(65, y_top, -120, 0); let_go()
  press(13); strings = {}; frame()
  assert(saw("frames in front"), "frames are put in front of the file: " .. tostring(saw("bend") or "(no status)"))
  clock_skew = clock_skew + 30; strings = {}; frame()                          -- (a message of the last action takes the place of the numbers for a while)
  assert(saw("   2%.[1-4]%d s   "), "the file is longer: " .. tostring(saw("partials")))
  assert(saw("^1%*$") and saw("^2%*$") and saw("^3%*$"), "every channel changed")
  assert(saw("%(3 channels%)"), "the stretched points stay selected")
  press(26, 4); strings = {}; frame()
  clock_skew = clock_skew + 30; strings = {}; frame()                          -- (a message of the last action takes the place of the numbers for a while)
  assert(saw("   2%.00 s   ") and not saw("^%d%*$"), "ONE Ctrl+Z takes the frames in front away again, in every channel: " .. tostring(saw("partials")))
  press(25, 4); strings = {}; frame()
  clock_skew = clock_skew + 30; strings = {}; frame()                          -- (a message of the last action takes the place of the numbers for a while)
  assert(saw("   2%.[1-4]%d s   ") and saw("^1%*$"), "Ctrl+Y puts them back: " .. tostring(saw("partials")))
  press(26, 4); strings = {}; frame()
  press(102)
  -- the window follows the drag: with the pointer in the last stretch of the picture the view scrolls on, past the end of the file
  sweep(65, y_top, 1040, y_bot)
  gfx.mouse_cap = 1; gfx.mouse_x, gfx.mouse_y = 1040, y_top; frame()                 -- hold the top right corner ...
  gfx.mouse_x = 1070; frame()                                                         -- ... and keep the pointer at the right end of the picture
  local before_t = nil
  strings = {}; frame()
  assert(not saw("^2%.5 s$") and not saw("^3 s$"), "at first the picture ends at the end of the file (about 2 s)")
  for _ = 1, 40 do frame() end
  strings = {}; frame()
  assert(saw("^2%.5 s$") or saw("^3 s$") or saw("^3%.5 s$"), "the picture has scrolled on beyond the end of the file: " .. table.concat(strings, " / ", 1, math.min(#strings, 24)))
  assert(saw("^bend %+%d+ ms"), "the dragged corner went with it: " .. tostring(saw("^bend") or "(no status)"))
  local scrolled = tonumber(saw("^bend %+(%d+) ms") and saw("^bend %+(%d+) ms"):match("%+(%d+) ms"))
  for _ = 1, 40 do frame() end
  strings = {}; frame()
  local more = tonumber(saw("^bend %+(%d+) ms") and saw("^bend %+(%d+) ms"):match("%+(%d+) ms"))
  assert(more and scrolled and more > scrolled, "and it goes on as long as the pointer stays there: " .. tostring(scrolled) .. " then " .. tostring(more))
  let_go(); press(27)
  press(102)                                                                          -- (the whole file in view again for the next tests)
  -- both at once, and Ctrl keeps one direction only
  sweep(65, y_top, 600, y_bot)
  hold_and_drag(600, y_top, 40, -30)
  assert(saw("^bend [%+%-][%d%.]+ st  %+%d+ ms"), "up and later together: " .. tostring(saw("^bend")))
  let_go(); press(27)
  sweep(65, y_top, 600, y_bot)
  hold_and_drag(600, y_top, 40, -10, 1 + 4)
  assert(saw("^bend %+%d+ ms: Enter") and not saw("^bend [%+%-][%d%.]+ st"), "Ctrl: time only when the drag is mostly sideways: " .. tostring(saw("^bend")))
  let_go(); press(27)
  -- time cannot fold back: the left corner dragged far past the right edge does not move
  sweep(65, y_top, 600, y_bot)
  hold_and_drag(65, y_top, 1800, 0)
  let_go(); strings = {}; frame()
  press(13); strings = {}; frame()
  assert(saw("nothing to apply"), "a movement that would fold time back is refused: " .. tostring(saw("bend") or saw("nothing")))
  press(27)
  sweep(65, y_top, 600, y_bot)
  -- Esc cancels a bend that was shaped
  sweep(65, y_top, 600, y_bot)
  hold_and_drag(600, y_top, 0, 30); let_go()
  press(27); strings = {}; frame()
  assert(saw("bend cancelled") and not saw("^%d%*$") and saw("%(3 channels%)"), "Esc cancels the bend and keeps the selection: " .. tostring(saw("bend") or saw("selected")))
  press(13); strings = {}; frame()
  assert(saw("nothing to apply"), "Enter with a flat box says so")
  -- a border dot: Ctrl+click on the top edge adds one, it can be dragged along, and a right-click removes it
  hold_and_drag(332, y_top, 0, 30, 1 + 4); let_go()
  strings = {}; frame()
  assert(saw("^bend up to [%d%.]+ st"), "the new border dot bends the edge: " .. tostring(saw("bend") or "(nothing)"))
  clock_skew = clock_skew + 30
  gfx.mouse_x, gfx.mouse_y, gfx.mouse_cap = 332, y_top + 30, 2; frame(); gfx.mouse_cap = 0; strings = {}; frame()
  assert(saw("border dot removed"), "a right-click on a border dot removes it: " .. tostring(saw("border") or saw("whole")))
  press(18); strings = {}; frame()
  assert(saw("bend reset"), "Ctrl+R resets the box to flat")
  -- an arch: Ctrl+Shift+drag on an edge (not Alt: KDE moves the window with it); it is not a lasso
  hold_and_drag(200, y_top, 0, 30, 1 + 4 + 8); let_go()
  strings = {}; frame()
  assert(saw("^bend up to [%d%.]+ st") and saw("%(3 channels%)"), "Ctrl+Shift+drag on an edge arches it and keeps the selection: " .. tostring(saw("bend") or saw("selected")))
  press(18); strings = {}; frame()
  -- the box is applied when the selection goes (here: a click on empty space)
  hold_and_drag(600, y_top, 0, 30); let_go()
  click(900, 140)                                                                      -- a click on empty space: the selection goes, the bend is applied first
  strings = {}; frame()
  assert(saw("^1%*$") and saw("^3%*$"), "a bend that was shaped is applied when the selection changes: " .. tostring(saw("bend") or "(no status)"))
  press(26, 4); press(26, 4); strings = {}; frame()
  print("the box round the selection: corner dots bend it, Enter applies, Esc cancels, border dots")
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

-- 9. SPACE: pseudo-stereo and VBAP (the button cycles, the slider sets the amount, the OUT box the outputs; PRINT writes every output)
do
  start(scratch .. "mc_ch1.ats"); strings = {}; frame()
  local by = 6 + 9                                              -- (the top row of the layout)
  assert(saw("^3 channels$"), "SPACE starts on the channels as analysed (3 for this set), not greyed out: " .. tostring(saw("channel")))
  click(444 + 40, by); strings = {}; frame()
  assert(saw("^P%-STEREO$"), "a click on SPACE gives pseudo-stereo")
  click(444 + 40, by); strings = {}; frame()
  assert(saw("^VBAP$") and saw("^OUT$"), "the next click gives VBAP, with its OUT box")
  click(716 + 50, by); click(716 + 50, by); strings = {}; frame()
  assert(saw("^6$"), "a click on the OUT box adds an output (4 -> 6)")
  local kept = reaper.GetExtState("tjingboem_ATSViewer", "space")
  assert(kept:match("^3|") and kept:match("|6$"), "the setting is remembered: " .. tostring(kept))
  click(548 + 24, by); strings = {}; frame()
  assert(saw("spread 2[0-9]%%") or saw("spread 3[0-9]%%") or saw("spread 24%%"), "the slider sets the spread: " .. tostring(saw("spread") or saw("width")))
  click(444 + 40, by); strings = {}; frame()
  assert(saw("^3 channels$"), "and a third click is back at the channels as analysed")
end
print("SPACE: pseudo-stereo and VBAP controls OK")

-- 10. A with a selection plays the selection only (the sound is short: from just before the selection to just after it); Z zooms to it
do
  start(scratch .. "mc_ch1.ats"); strings = {}; frame()
  press(102)                                                    -- F: the whole file in view
  local lane1 = lanes_now()[1]
  local y_top, y_bot = 105, 100 + lane1.h - 5
  sweep(300, y_top, 420, y_bot)
  local n0 = #previews
  press(97)
  until_done(function() return #previews > n0 end)
  local info = wavinfo.read(previews[#previews])
  assert(info and info.frames > 100 and info.frames < 60000, "the selection's sound is short: " .. tostring(info and info.frames))
  assert(saw("the selection only"), "the status says it is the selection: " .. tostring(saw("auditioning")))
  press(122); strings = {}; frame()
  press(97)                                                     -- the zoomed view still has the selection: A again
  until_done(function() return #previews > n0 + 1 end)
  press(27); press(97)                                          -- no selection: A plays the whole sound again
  until_done(function() return #previews > n0 + 2 end)
  local whole = wavinfo.read(previews[#previews])
  assert(whole.frames > info.frames * 2, "without a selection A plays the whole sound: " .. tostring(whole.frames))
end
print("A plays the selection only, Z zooms to it")

-- 11. edge-scroll: a drag held at the right edge of the picture scrolls the view on (box, lasso, move)
do
  start(scratch .. "mc_ch1.ats"); strings = {}; frame()
  press(102)
  local lane1 = lanes_now()[1]
  local y_top, y_bot = 105, 100 + lane1.h - 5
  sweep(300, y_top, 420, y_bot)
  press(122)                                                    -- Z: a view that holds only a part of the file
  press(27)
  local function count() strings = {}; frame(); local t = saw("^selected: (%d+) points"); return t and tonumber(t:match("^selected: (%d+)")) or 0 end
  local right = math.floor(gfx.w) - 55
  local function drag_held(x0, x1, frames, cap)                -- press at x0, move to x1, hold there for some frames, let go
    gfx.mouse_cap = cap; gfx.mouse_x, gfx.mouse_y = x0, y_top; frame()
    gfx.mouse_x, gfx.mouse_y = (x0 + x1) / 2, y_bot; frame()
    gfx.mouse_x, gfx.mouse_y = x1, y_bot; frame()
    for _ = 1, frames do frame() end
    gfx.mouse_cap = 0; frame(); frame(); gfx.mouse_x, gfx.mouse_y = 5, 5
  end
  drag_held(80, right, 0, 1)
  local n_plain = count()
  press(27)
  drag_held(80, right, 40, 1)
  local n_held = count()
  assert(n_held > n_plain, "a box held at the right edge scrolls and selects more: " .. n_plain .. " then " .. n_held)
  press(27)
  drag_held(80, right, 0, 1 + 4 + 8)
  local l_plain = count()
  press(27)
  drag_held(80, right, 40, 1 + 4 + 8)
  local l_held = count()
  assert(l_held > l_plain, "a lasso held at the right edge scrolls and selects more: " .. l_plain .. " then " .. l_held)
  press(27)
end
print("edge-scroll works for a box and a lasso")

-- 13. a right-click with a selection opens the gain slider (+-20 dB): drag, APPLY changes the amplitude of the selection, one undo step; Esc cancels
do
  start(scratch .. "mc_ch1.ats"); strings = {}; frame()
  press(102)
  local lane1 = lanes_now()[1]
  local y_top, y_bot = 105, 100 + lane1.h - 5
  local function rclick(x, y) gfx.mouse_x, gfx.mouse_y, gfx.mouse_cap = x, y, 2; frame(); gfx.mouse_cap = 0; strings = {}; frame(); gfx.mouse_x, gfx.mouse_y = 5, 5 end
  rclick(500, 300)
  assert(saw("whole file in view") and not saw("Gain of the selection"), "no selection: a right-click shows the whole file: " .. tostring(saw("whole") or saw("Gain")))
  sweep(65, y_top, 1040, y_bot)
  rclick(500, 300)
  assert(saw("Gain of the selection") and saw("^%+0%.0 dB$"), "with a selection a right-click opens the slider: " .. tostring(saw("Gain") or "(nothing)"))
  -- Esc cancels
  press(27); strings = {}; frame()
  assert(not saw("Gain of the selection") and saw("gain cancelled") and not saw("^%d%*$"), "Esc closes it and changes nothing")
  rclick(500, 300)
  -- the slider at 3/4 of its track is +10 dB; the popup is at (370, 276), its track at x 386, 228 wide, y 310
  click(386 + 171, 315); strings = {}; frame()
  assert(saw("^%+10%.0 dB$"), "a click at three quarters of the track is +10 dB: " .. tostring(saw(" dB")))
  press(30064); strings = {}; frame()
  assert(saw("^%+10%.5 dB$"), "Up adds half a dB: " .. tostring(saw(" dB")))
  click(558 + 20, 276 + 66 + 9); strings = {}; frame()                                  -- APPLY
  assert(not saw("Gain of the selection") and saw("^1%*$") and saw("^2%*$") and saw("^3%*$"), "APPLY changes every green channel: " .. tostring(saw("gain") or "(no status)"))
  assert(saw("gain %+10%.5 dB"), "and the status says what it did: " .. tostring(saw("gain") or "(no status)"))
  -- the amplitude really changed: save and read the file (the selection holds the strongest point, so the maximum is 10.5 dB higher)
  for k = 1, 3 do os.remove(scratch .. "mc_edit_ch" .. k .. ".ats") end                  -- (an older save from another test must not be read)
  press(19); strings = {}; frame()
  local before = assert(ats.load(scratch .. "mc_ch1.ats"))
  local after = assert(ats.load(scratch .. "mc_edit_ch1.ats"))
  local ratio = after.ampmax / before.ampmax
  assert(math.abs(ratio - 10 ^ (10.5 / 20)) < 0.02 * 10 ^ (10.5 / 20), "the amplitude of the selection went up 10.5 dB: " .. ratio)
  os.remove(scratch .. "mc_edit_ch1.ats"); os.remove(scratch .. "mc_edit_ch2.ats"); os.remove(scratch .. "mc_edit_ch3.ats")
  press(26, 4); strings = {}; frame()
  assert(saw("^undo in 3 channels"), "ONE Ctrl+Z takes it back in every channel: " .. tostring(saw("undo") or "(no status)"))
end
print("right-click with a selection opens the gain slider")

-- 12. a move and a paste that go beyond the end of the file make it longer (every channel), one undo step each
do
  start(scratch .. "mc_ch1.ats"); strings = {}; frame()
  press(102)
  local lane1 = lanes_now()[1]
  local y_top, y_bot = 105, 100 + lane1.h - 5
  strings = {}; frame()
  clock_skew = clock_skew + 30; strings = {}; frame()                          -- (a message of the last action takes the place of the numbers for a while)
  assert(saw("   2%.00 s   "), "the file is 2.00 s: " .. tostring(saw("partials")))
  sweep(65, y_top, 1040, y_bot)
  for _ = 1, 25 do press(1919379572, 4) end                       -- Ctrl+Right: ten frames, 25 times
  strings = {}; frame()
  clock_skew = clock_skew + 30; strings = {}; frame()                          -- (a message of the last action takes the place of the numbers for a while)
  assert(not saw("   2%.00 s   "), "moving the selection past the end makes the file longer: " .. tostring(saw("partials")))
  assert(saw("^1%*$") and saw("^2%*$") and saw("^3%*$"), "in every channel")
  for _ = 1, 25 do press(26, 4) end
  strings = {}; frame()
  clock_skew = clock_skew + 30; strings = {}; frame()                          -- (a message of the last action takes the place of the numbers for a while)
  assert(saw("   2%.00 s   ") and not saw("^%d%*$"), "the undos make it 2.00 s again: " .. tostring(saw("partials")))
  -- before the start: the file gets frames in front
  sweep(65, y_top, 1040, y_bot)
  for _ = 1, 8 do press(1818584692, 4) end                        -- Ctrl+Left
  strings = {}; frame()
  clock_skew = clock_skew + 30; strings = {}; frame()                          -- (a message of the last action takes the place of the numbers for a while)
  assert(not saw("   2%.00 s   "), "moving the selection before the start makes the file longer: " .. tostring(saw("partials")))
  for _ = 1, 8 do press(26, 4) end
  strings = {}; frame()
  clock_skew = clock_skew + 30; strings = {}; frame()                          -- (a message of the last action takes the place of the numbers for a while)
  assert(saw("   2%.00 s   "), "and the undos take it back: " .. tostring(saw("partials")))
  -- a paste at the end of the file
  sweep(65, y_top, 1040, y_bot)
  press(3)                                                         -- Ctrl+C
  press(6647396)                                                   -- End: the playhead at the end
  press(22); strings = {}; frame()                                 -- Ctrl+V
  assert(saw("the file is [%d%.]+ s longer now"), "a paste at the end makes the file longer: " .. tostring(saw("pasted") or saw("paste")))
  clock_skew = clock_skew + 30; strings = {}; frame()                          -- (a message of the last action takes the place of the numbers for a while)
  assert(not saw("   2%.00 s   "), "the header shows it: " .. tostring(saw("partials")))
  press(26, 4); strings = {}; frame()
  clock_skew = clock_skew + 30; strings = {}; frame()                          -- (a message of the last action takes the place of the numbers for a while)
  assert(saw("   2%.00 s   "), "one Ctrl+Z takes the paste and the length back: " .. tostring(saw("partials")))
end
print("a move and a paste past the ends make the file longer")

-- 14. the messages of AUDITION are not shown (the real editor): not while the sound is prepared, not when it plays, not when Space stops it
do
  REAATS_SHOW_AUDITION_TEXT = false
  start(scratch .. "mc_ch1.ats"); strings = {}; frame()
  press(102)
  local n0 = #previews
  press(97)
  local frames = 0
  for _ = 1, 4000 do
    clock_skew = clock_skew + 0.05; strings = {}; frame()
    frames = frames + 1
    assert(not saw("^preparing") and not saw("^auditioning"), "no message while the sound is prepared or plays: " .. tostring(saw("preparing") or saw("auditioning")))
    if #previews > n0 then break end
    os.execute('sleep 0.02')
  end
  assert(#previews > n0, "the sound was played")
  strings = {}; frame()
  assert(not saw("^auditioning"), "and no message when it plays")
  press(32); strings = {}; frame()
  assert(not saw("audition stopped"), "Space stops it without a message")
  REAATS_SHOW_AUDITION_TEXT = true
end
print("AUDITION shows no text")

clean()
os.remove(scratch .. "mc.wav"); os.remove(scratch .. "mm_short.wav")
print("channel sets OK")
