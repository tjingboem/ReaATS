-- Run: lua5.4 tests/mock_notes.lua   (from the ReaATS folder)
-- The EXPORT NOTES button: asks how many partials, writes <name>_notes1.mid next to the .ats file and puts the notes on a new track.
-- Fixture: 4 flat partials (200, 400, 800, 1600 Hz) with amplitudes 0.9, 0.2, 0.5, 0.7.
local root = os.getenv("PWD")
local scratch = "/tmp/claude-1000/-home-tjingboem/6ca29d3f-340f-46ca-9b11-e579b6c375ee/scratchpad/"
local work = scratch .. "notes_test.ats"
local edited_path = scratch .. "notes_test_edit.ats"
local edited_path2 = scratch .. "notes_test_edit2.ats"
local edited_path3 = scratch .. "notes_test_edit3.ats"
local edited_path4 = scratch .. "notes_test_edit4.ats"
os.remove(edited_path)
os.remove(edited_path2)
os.remove(edited_path3)
os.remove(edited_path4)

local ats = dofile("lib/ats_file.lua")
local NF, HOP = 50, 0.01
local PARTIALS = {                            -- p, freq (Hz), amplitude -- energy = amp * NF
  { p = 1, freq = 200,  amp = 0.9 },           -- energy 45 (loudest)
  { p = 2, freq = 400,  amp = 0.2 },           -- energy 10 (quietest)
  { p = 3, freq = 800,  amp = 0.5 },           -- energy 25
  { p = 4, freq = 1600, amp = 0.7 },           -- energy 35
}
local d = { sr = 44100, frame_size = 441, window_size = 1764, partials = 4, frames = NF, dur = NF * HOP,
            has_phase = false, has_noise = false, amp = {}, frq = {}, times = {} }
for f = 1, NF do d.times[f] = (f - 1) * HOP end
for _, t in ipairs(PARTIALS) do
  d.amp[t.p], d.frq[t.p] = {}, {}
  for f = 1, NF do d.amp[t.p][f], d.frq[t.p][f] = t.amp, t.freq end
end
assert(ats.save(work, d))

local strings = {}
gfx = { w = 1100, h = 640, mouse_x = 0, mouse_y = 0, mouse_cap = 0, mouse_wheel = 0, x = 0, y = 0, a = 1, dest = -1 }
for _, n in ipairs({ "set", "rect", "line", "circle", "setimgdim", "setfont", "update", "init", "blit" }) do gfx[n] = function() return 0 end end
gfx.drawstr = function(s) strings[#strings + 1] = s end
gfx.measurestr = function(s) return #s * 7, 14 end
local script = { keys = {} }
gfx.getchar = function() return table.remove(script.keys, 1) or 0 end
local deferred
local clock_skew = 0
local calls = {}
local dialog_calls, dialog_ok, dialog_text = 0, false, ""
reaper = {
  time_precise = function() return os.clock() + clock_skew end,
  ExecProcess = function(cmd) local ph = io.popen(cmd .. " 2>&1"); local out = ph:read("a"); ph:close(); return out end,
  get_action_context = function() return true, root .. "/ATS_Editor.lua", 0, 0 end,
  GetExtState = function(_, key) return (key == "last_file") and work or "" end,
  SetExtState = function() end,
  ShowConsoleMsg = function() end,
  MB = function() return 6 end,
  JS_Dialog_BrowseForSaveFile = function() return 0, "" end,
  GetUserInputs = function() dialog_calls = dialog_calls + 1; return dialog_ok, dialog_text end,
  file_exists = function(p) local f = io.open(p, "rb"); if f then f:close() return true end return false end,
  GetUserFileNameForRead = function() return true, work end,
  defer = function(fn) deferred = fn end,
  CountTracks = function() return 0 end,
  InsertTrackAtIndex = function() calls.track = true end,
  GetTrack = function() return "TRACK" end,
  GetSetMediaTrackInfo_String = function(_, _, v) calls.name = v; return true end,
  GetCursorPosition = function() return 2.0 end,
  CreateNewMIDIItemInProj = function(_, a, b) calls.item = { a, b }; return "ITEM" end,
  GetActiveTake = function() return "TAKE" end,
  MIDI_GetPPQPosFromProjTime = function(_, t) return t * 960 end,
  MIDI_SetAllEvts = function(_, buf) calls.buf = buf; return true end,
  UpdateItemInProject = function() end,
  Undo_BeginBlock = function() end, Undo_EndBlock = function() end,
}
dofile("ATS_Editor.lua")
script.keys = { 111 }; do local f = deferred; deferred = nil; f() end          -- O: open the fixture


local function frame(setup)
  if setup then setup() end
  local fn = deferred; deferred = nil
  assert(fn, "viewer stopped unexpectedly")
  fn()
end
local function saw(pattern) for _, s in ipairs(strings) do if s:find(pattern) then return s end end return nil end
local mid = scratch .. "notes_test_notes1.mid"
os.remove(mid); os.remove(scratch .. "notes_test_notes2.mid")
local function mouse(x, y) gfx.mouse_cap = 1; gfx.mouse_x, gfx.mouse_y = x, y; frame(); gfx.mouse_cap = 0; frame() end
local PX, PY = 126, 30 + 18 + 4                                         -- the panel opens under the button
local function track_x(which, frac) return PX + 16 + math.floor(268 * frac + 0.5) end
local MAXY, BIASY, EXPORT, CANCEL = PY + 40 + 5, PY + 88 + 5, { PX + 218 + 10, PY + 134 + 9 }, { PX + 150 + 10, PY + 134 + 9 }
local function open_panel() dialog_calls, calls = 0, {}; strings = {}; mouse(126 + 10, 30 + 9); strings = {}; frame() end
strings = {}; frame()
assert(saw("EXPORT %.ats FILE"), "the export button is renamed")
assert(saw("EXPORT NOTES"), "the notes button is drawn")

-- the panel opens, with sliders, and no text box
open_panel()
assert(dialog_calls == 0, "no popup text box any more")
assert(saw("Export notes %(the whole sound%)") and saw("Max notes") and saw("Favour") and saw("Neutral") and saw("Low partials"), "the panel is drawn")
assert(saw("found 4 partials: 4 notes on 4 channels, 0 left out"), "live line at the start (15 notes at most): " .. tostring(saw("found")))
-- Cancel does nothing
mouse(CANCEL[1], CANCEL[2])
assert(not calls.buf and saw("^export notes cancelled"), "cancel does nothing")
-- Esc does nothing
open_panel(); script.keys = { 27 }; frame(); assert(not calls.buf, "Esc does nothing")
-- a click outside does nothing
open_panel(); mouse(700, 400); assert(not calls.buf, "a click outside cancels")

-- max notes 2: the slider at 1/14 of its length
open_panel()
gfx.mouse_cap = 1; gfx.mouse_x, gfx.mouse_y = track_x("max", 1 / 14), MAXY; frame()
gfx.mouse_cap = 0; strings = {}; frame()
assert(saw("Max notes") and saw("^2$"), "the value shows 2")
assert(saw("found 4 partials: 2 notes on 2 channels, 2 left out"), "live line follows the slider: " .. tostring(saw("found")))
-- the preference starts at 0.5, and the far left of its slider is neutral
assert(saw("low partials 0.50"), "bias starts at 0.5: " .. tostring(saw("low partials")))
gfx.mouse_cap = 1; gfx.mouse_x, gfx.mouse_y = track_x("bias", 0), BIASY; frame(); gfx.mouse_cap = 0; strings = {}; frame()
assert(saw("^neutral$"), "far left = neutral")
mouse(EXPORT[1], EXPORT[2])
assert(calls.buf and calls.track and calls.name == "ReaATS notes", "the notes were put on a new track")
assert(calls.item[1] == 2.0, "at the edit cursor")
local fh = assert(io.open(mid, "rb")); local smf = fh:read("a"); fh:close()
assert(smf:sub(1, 4) == "MThd" and smf:find("MTrk", 1, true), "a MIDI file was written")
assert(saw("^2 notes %(4 partials found, 2 weaker left out%) on 2 MPE channels"), "status: " .. tostring(saw("notes")))
-- the two strongest (0.9 at 200 Hz = G3, 0.7 at 1600 Hz = G6) are the ones that were kept
local function has(pitch) for ch = 1, 15 do if smf:find(string.char(0x90 | ch, pitch), 1, true) then return true end end end
assert(has(55), "G3 (200 Hz) is in the file")
assert(has(91), "G6 (1600 Hz) is in the file")
assert(not has(67), "the quiet 400 Hz partial (G4) is left out")

-- the values are remembered: reopening shows 2 again (ExtState is a stub here, so check the sliders after a full-right drag)
-- a second export does not overwrite the first, and Enter exports; 15 notes at most = all four
open_panel()
gfx.mouse_cap = 1; gfx.mouse_x, gfx.mouse_y = track_x("max", 1), MAXY; frame()
gfx.mouse_cap = 0; frame()
script.keys = { 13 }; frame()
local f2 = io.open(scratch .. "notes_test_notes2.mid", "rb"); assert(f2, "the second file has its own name"); f2:close()
assert(saw("^4 notes %(4 partials found%)"), "all four with 15: " .. tostring(saw("notes")))

-- favour low partials: one voice, the bias slider all the way to the right keeps the 200 Hz partial instead of the stronger... all four
-- partials have flat amplitudes 0.9 (200), 0.2 (400), 0.5 (800), 0.7 (1600): with max 1 and neutral the loudest (200) wins either way,
-- so the check is on the live line instead: it must say "1 notes" and the slider value must read "low partials 2.00"
open_panel()
gfx.mouse_cap = 1; gfx.mouse_x, gfx.mouse_y = track_x("max", 0), MAXY; frame(); gfx.mouse_cap = 0; frame()
gfx.mouse_cap = 1; gfx.mouse_x, gfx.mouse_y = track_x("bias", 1), BIASY; frame(); gfx.mouse_cap = 0; strings = {}; frame()
assert(saw("low partials 2%.00"), "bias slider at the right end: " .. tostring(saw("low partials")))
assert(saw("found 4 partials: 1 notes on 1 channels, 3 left out"), "live line: " .. tostring(saw("found")))
script.keys = { 27 }; frame()
os.remove(mid); os.remove(scratch .. "notes_test_notes2.mid")
print("EXPORT NOTES OK: renamed export button, slider panel with a live line, cancel/Esc/outside, MIDI file, new track, strongest partials kept, numbered files")
