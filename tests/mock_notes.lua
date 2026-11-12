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
local items, repeat_state, cursor, play_state, loop_range = {}, 0, 2.0, 0, { 0, 0 }
local selected_track = nil                                       -- (no track selected: a new one is made)
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
  GetSelectedTrack = function() return selected_track end,
  -- for the AUDITION item (a temporary MIDI item, tagged)
  CountMediaItems = function() return #items end,
  GetMediaItem = function(_, i) return items[i + 1] end,
  GetMediaItem_Track = function() return "TRACK" end,
  GetSetMediaItemInfo_String = function(it, key, val, set)
    if key:find("^P_EXT:") then if set then it.tag = val; return true, val end return true, it.tag or "" end
    return true, ""
  end,
  DeleteTrackMediaItem = function(_, it) for i, x in ipairs(items) do if x == it then table.remove(items, i) break end end; calls.deleted = (calls.deleted or 0) + 1 end,
  UpdateArrange = function() end,
  GetSetMediaItemTakeInfo_String = function() return true end,
  SetMediaItemInfo_Value = function(it, key, v) it[key] = v end,
  ColorToNative = function() return 0 end,
  GetSetRepeatEx = function(_, v) if v >= 0 then repeat_state = v end return repeat_state end,
  SetEditCurPos = function(t) cursor = t end,
  OnPlayButton = function() calls.play = (calls.play or 0) + 1; play_state = 1 end,
  OnStopButton = function() calls.stop = (calls.stop or 0) + 1; play_state = 0 end,
  GetPlayState = function() return play_state end,
  GetSet_LoopTimeRange = function(set, _, a, b) if set then loop_range = { a, b } end return loop_range[1], loop_range[2] end,
  SetOnlyTrackSelected = function() end,
  GetTrack = function() return "TRACK" end,
  GetSetMediaTrackInfo_String = function(_, _, v) calls.name = v; return true end,
  GetCursorPosition = function() return cursor end,
  CreateNewMIDIItemInProj = function(_, a, b) local it = { a, b, ["D_POSITION"] = a, ["D_LENGTH"] = b - a }; calls.item = it; items[#items + 1] = it; return it end,
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
local BIASY = PY + 42 + 5
local EXPORT, CANCEL, AUDITION, FLAT = { PX + 216 + 10, PY + 96 + 9 }, { PX + 152 + 10, PY + 96 + 9 }, { PX + 16 + 10, PY + 96 + 9 }, { PX + 100 + 10, PY + 96 + 9 }
local TOP, BOTTOM2 = 70 + 1, 70 + 516 - 2                                 -- (the picture: 62, 70, 988 x 516; its top is 15 notes, its bottom 1)
local function y_of(n) return math.min(math.max(math.floor(70 + 516 - (n - 1) / 14 * 516 + 0.5), 71), 70 + 516 - 1) end      -- (inside the picture: 15 notes at its top, 1 at its bottom)
local function open_panel() dialog_calls, calls = 0, {}; strings = {}; mouse(126 + 10, 30 + 9); strings = {}; frame() end
strings = {}; frame()
assert(saw("EXPORT %.ats FILE"), "the export button is renamed")
assert(saw("EXPORT NOTES"), "the notes button is drawn")

-- the panel opens, with sliders, and no text box
open_panel()
assert(dialog_calls == 0, "no popup text box any more")
assert(saw("Export notes %(the whole sound%)") and saw("Favour") and saw("Neutral") and saw("Low partials"), "the panel is drawn")
assert(saw("found 4 partials: 2 notes on 2 channels, 2 left out"), "live line at the start: the red line is flat at 2 notes: " .. tostring(saw("found")))
-- Cancel does nothing
mouse(CANCEL[1], CANCEL[2])
assert(not calls.buf and saw("^export notes cancelled"), "cancel does nothing")
-- Esc does nothing
open_panel(); script.keys = { 27 }; frame(); assert(not calls.buf, "Esc does nothing")
-- a click outside does nothing
open_panel(); mouse(900, 20); assert(not calls.buf and saw("^export notes cancelled"), "a click outside the picture and the panel cancels")

-- the preference starts at 0.5, and the far left of its slider is neutral
open_panel()
assert(saw("low partials 0.50"), "bias starts at 0.5: " .. tostring(saw("low partials")))
gfx.mouse_cap = 1; gfx.mouse_x, gfx.mouse_y = track_x("bias", 0), BIASY; frame(); gfx.mouse_cap = 0; strings = {}; frame()
assert(saw("^neutral$"), "far left = neutral")
assert(not saw("Max notes"), "there is no Max notes slider any more")
assert(not saw("click in the picture"), "and no text about clicking in the picture")
-- two notes: the red line drawn flat at 2 (two points between the ends at the start and the end of the sound)
mouse(64, y_of(2)); mouse(1048, y_of(2)); strings = {}; frame()
assert(saw("found 4 partials: 2 notes on 2 channels, 2 left out"), "live line follows the envelope: " .. tostring(saw("found")))
mouse(EXPORT[1], EXPORT[2])
assert(calls.buf and calls.track and calls.name == "ReaATS notes", "the notes were put on a new track")
assert(calls.item[1] == 2.0 and not calls.item.tag, "at the edit cursor, and not tagged as an audition item")
local fh = assert(io.open(mid, "rb")); local smf = fh:read("a"); fh:close()
assert(smf:sub(1, 4) == "MThd" and smf:find("MTrk", 1, true), "a MIDI file was written")
assert(saw("^2 notes %(4 partials found, 2 weaker left out%) on 2 MPE channels"), "status: " .. tostring(saw("notes")))
-- the two strongest (0.9 at 200 Hz = G3, 0.7 at 1600 Hz = G6) are the ones that were kept
local function has(pitch) for ch = 1, 15 do if smf:find(string.char(0x90 | ch, pitch), 1, true) then return true end end end
assert(has(55), "G3 (200 Hz) is in the file")
assert(has(91), "G6 (1600 Hz) is in the file")
assert(not has(67), "the quiet 400 Hz partial (G4) is left out")

-- a second export does not overwrite the first, and Enter exports; with the red line left flat at 2 two notes sound
open_panel()
script.keys = { 13 }; frame()
local f2 = io.open(scratch .. "notes_test_notes2.mid", "rb"); assert(f2, "the second file has its own name"); f2:close()
assert(saw("^2 notes %(4 partials found, 2 weaker left out%)"), "two with the default red line: " .. tostring(saw("notes")))
assert(saw("project is not saved"), "no project folder: the status says the files are next to the sound")

-- favour low partials: the slider all the way to the right reads "low partials 2.00"; one note (the red line flat at 1) is counted on the live line
open_panel()
mouse(64, y_of(1)); mouse(1048, y_of(1))
gfx.mouse_cap = 1; gfx.mouse_x, gfx.mouse_y = track_x("bias", 1), BIASY; frame(); gfx.mouse_cap = 0; strings = {}; frame()
assert(saw("low partials 2%.00"), "bias slider at the right end: " .. tostring(saw("low partials")))
assert(saw("found 4 partials: 1 notes on 1 channels, 3 left out"), "live line: " .. tostring(saw("found")))
script.keys = { 27 }; frame()
os.remove(mid); os.remove(scratch .. "notes_test_notes2.mid")

-- the red envelope over the picture (12 Nov 2026): a click adds a point, a right-click removes one, FLAT takes it away
do
  local function live() local f = saw("^found %d+ partials: (%d+) notes") if f then return tonumber(f:match("^found %d+ partials: (%d+) notes")) end end
  local function refresh() strings = {}; frame() end
  local BOTTOM = 70 + 516 - 2                                          -- (the picture: 62, 70, 988 x 516): the bottom of it is 1 note
  open_panel()
  assert(live() == 2, "the red line is flat at 2 notes to begin with: " .. tostring(live()))
  mouse(262, y_of(15)); refresh()
  mouse(762, y_of(15)); refresh()
  local with_env = live()
  assert(with_env and with_env > 2, "15 notes in the middle: more notes, some of them cut short at the ends: " .. tostring(with_env))
  -- dragging a point moves it (up: more room again)
  gfx.mouse_cap = 1; gfx.mouse_x, gfx.mouse_y = 262, BOTTOM; frame()
  gfx.mouse_x, gfx.mouse_y = 262, 70 + 5; frame(); gfx.mouse_cap = 0; frame(); refresh()
  mouse(762, BOTTOM); refresh()
  -- a right-click on a point removes it
  gfx.mouse_cap = 2; gfx.mouse_x, gfx.mouse_y = 762, BOTTOM; frame(); gfx.mouse_cap = 0; frame(); refresh()
  -- FLAT takes the envelope away: the slider is live again, the notes as before
  mouse(FLAT[1], FLAT[2]); refresh()
  assert(live() == 2, "FLAT gives the flat line (2 notes) back: " .. tostring(live()))
  -- an exported envelope says so
  mouse(262, BOTTOM); mouse(762, BOTTOM)
  mouse(EXPORT[1], EXPORT[2]); strings = {}; frame()
  assert(saw("following the envelope"), "the status says the export followed the envelope: " .. tostring(saw("notes")))
  os.remove(mid)
end

-- AUDITION (12 Nov 2026): a temporary MIDI item on the selected track, rewritten live, the transport plays it; STOP, Esc and EXPORT remove it
do
  items = {}                                                           -- (the real items of the exports above are no concern here)
  selected_track = nil
  open_panel(); mouse(AUDITION[1], AUDITION[2]); strings = {}; frame()
  assert(saw("select a track with an instrument first") and #items == 0 and not calls.play, "audition needs a selected track: " .. tostring(saw("audition")))
  mouse(CANCEL[1], CANCEL[2])
  selected_track = "TRACK"
  repeat_state, cursor, loop_range, play_state = 0, 2.0, { 5, 9 }, 0
  open_panel(); mouse(AUDITION[1], AUDITION[2]); strings = {}; frame()
  assert(#items == 1 and items[1].tag == "1", "AUDITION makes one tagged item")
  assert(items[1][1] == 2.0, "at the edit cursor")
  assert(calls.play == 1 and repeat_state == 1, "the transport plays, in a loop")
  assert(loop_range[1] == 2.0, "the time selection is the item")
  assert(saw("^STOP$"), "the button says STOP")
  local len1 = #calls.buf
  -- a change of the envelope rewrites the item (after a quarter of a second)
  mouse(64, y_of(1)); mouse(1048, y_of(1))
  clock_skew = clock_skew + 0.4; strings = {}; frame()
  assert(#items == 1 and #calls.buf < len1, "the item is rewritten with fewer notes: " .. len1 .. " -> " .. #calls.buf)
  -- STOP removes the item and puts everything back
  mouse(AUDITION[1], AUDITION[2]); strings = {}; frame()
  assert(#items == 0 and calls.stop == 1 and repeat_state == 0 and cursor == 2.0 and loop_range[1] == 5 and loop_range[2] == 9, "STOP takes the item away and restores Repeat, the cursor and the time selection")
  -- Esc does the same, and so does stopping the transport by hand
  mouse(AUDITION[1], AUDITION[2]); assert(#items == 1)
  script.keys = { 27 }; frame(); assert(#items == 0 and repeat_state == 0, "Esc stops the audition and closes the panel")
  open_panel(); mouse(AUDITION[1], AUDITION[2]); frame(); assert(#items == 1)
  play_state = 0; clock_skew = clock_skew + 0.3; frame(); frame()
  assert(#items == 0, "the transport was stopped by hand: the audition ends and the item is deleted")
  -- EXPORT while auditioning: the temporary item goes, the real one stays
  mouse(CANCEL[1], CANCEL[2])
  open_panel(); mouse(AUDITION[1], AUDITION[2]); assert(#items == 1)
  mouse(EXPORT[1], EXPORT[2])
  assert(#items == 1 and not items[1].tag, "EXPORT removes the audition item and makes the real one")
  items = {}
  os.remove(mid)
  selected_track = nil
end

-- a selected track: the notes go on it, no new track is made (12 Nov 2026)
selected_track = "SELECTED"
open_panel(); script.keys = { 13 }; frame()
assert(calls.buf and not calls.track and not calls.name, "with a selected track no new track is made")
assert(saw("on the selected track"), "the status says where the item is: " .. tostring(saw("notes")))
selected_track = nil
os.remove(mid)

-- a saved project: the file goes in <project folder>/ReaATS
os.execute("rm -rf " .. scratch .. "notes_proj; mkdir -p " .. scratch .. "notes_proj")
reaper.EnumProjects = function() return {}, scratch .. "notes_proj/piece.rpp" end
reaper.RecursiveCreateDirectory = function(d) os.execute("mkdir -p '" .. d .. "'"); return 1 end
open_panel(); script.keys = { 13 }; frame(); strings = {}; frame()                    -- (the strings of the frames before are not the status of this export)
local inproj = scratch .. "notes_proj/ReaATS/notes_test_notes1.mid"
local f3 = io.open(inproj, "rb"); assert(f3, "the MIDI file is in the project's ReaATS folder"); f3:close()
assert(not io.open(mid, "rb"), "and not next to the sound")
assert(saw("^%d+ notes") and not saw("project is not saved"), "no warning when the project is saved: " .. tostring(saw("notes")))
os.execute("rm -rf " .. scratch .. "notes_proj")
reaper.EnumProjects, reaper.RecursiveCreateDirectory = nil, nil
print("EXPORT NOTES OK: renamed export button, slider panel with a live line, cancel/Esc/outside, MIDI file, new track, strongest partials kept, numbered files")
