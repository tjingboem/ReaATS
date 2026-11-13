-- Run: lua5.4 tests/mock_cross.lua   (from the ReaATS folder)
-- The CROSS button and page: two blocks (A, B), dragging, the cut, the red line, the sliders, MAKE RESULT (a new file that opens in the editor).
-- Runs ATS_Editor.lua against a fake gfx/reaper; A = the 4 flat partials of the shared fixture, B = a second analysis with two partials.
local root = os.getenv("PWD")
local scratch = "/tmp/claude-1000/-home-tjingboem/6ca29d3f-340f-46ca-9b11-e579b6c375ee/scratchpad/"
local work = scratch .. "cx_test.ats"
local edited_path = scratch .. "cx_test_edit.ats"
local edited_path2 = scratch .. "cx_test_edit2.ats"
local edited_path3 = scratch .. "cx_test_edit3.ats"
local edited_path4 = scratch .. "cx_test_edit4.ats"
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

local load_path = nil
local strings = {}
gfx = { w = 1100, h = 640, mouse_x = 0, mouse_y = 0, mouse_cap = 0, mouse_wheel = 0, x = 0, y = 0, a = 1, dest = -1 }
for _, n in ipairs({ "set", "rect", "line", "circle", "setimgdim", "setfont", "update", "init", "blit" }) do gfx[n] = function() return 0 end end
gfx.drawstr = function(s) strings[#strings + 1] = s end
gfx.measurestr = function(s) return #s * 7, 14 end
local script = { keys = {} }
gfx.getchar = function() return table.remove(script.keys, 1) or 0 end
local deferred
local clock_skew = 0
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
  JS_Dialog_BrowseForOpenFiles = function() return 1, load_path end,
  PCM_Source_CreateFromFile = function() return nil end,
  GetUserInputs = function() dialog_calls = dialog_calls + 1; return dialog_ok, dialog_text end,
  file_exists = function(p) local f = io.open(p, "rb"); if f then f:close() return true end return false end,
  GetUserFileNameForRead = function() return true, work end,
  defer = function(fn) deferred = fn end,
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

-- the exact plot geometry for one channel at 1100x640 (ATS_Editor.lua's own MARGIN_L/T/R/B), and the view fit_view() lands on
local px, py, pw, ph = 62, 70, 988, 516

-- the button's own geometry (W.max_partials_rect, from the layout): (284, 6), 150 x 18, in the top row

-- sound B: two flat partials, 205 Hz and 800 Hz, 0.6 s long (60 frames of 10 ms), made by the analysis in real life
local second = scratch .. "cx_second.ats"
do
  local m = { sr = 44100, frame_size = 441, window_size = 1764, partials = 2, frames = 60, dur = 0.6, has_phase = false, has_noise = false, amp = {}, frq = {}, times = {} }
  for f = 1, 60 do m.times[f] = (f - 1) * HOP end
  for p, fr in ipairs({ 205, 800 }) do m.amp[p], m.frq[p] = {}, {}; for f = 1, 60 do m.amp[p][f], m.frq[p][f] = 0.3, fr end end
  assert(ats.save(second, m))
end
local function click(x, y) gfx.mouse_cap = 1; gfx.mouse_x, gfx.mouse_y = x, y; frame(); gfx.mouse_cap = 0; frame() end
local function drag(x0, y0, x1, y1) gfx.mouse_cap = 1; gfx.mouse_x, gfx.mouse_y = x0, y0; frame(); gfx.mouse_x, gfx.mouse_y = (x0 + x1) // 2, (y0 + y1) // 2; frame(); gfx.mouse_x, gfx.mouse_y = x1, y1; frame(); gfx.mouse_cap = 0; frame() end
local last_col, orange_lines = {}, 0
local old_set = gfx.set
gfx.set = function(r, g, b, a) last_col = { r, g, b, a }; return old_set(r, g, b, a) end
gfx.line = function()
  local c = last_col
  if c[1] and ((math.abs(c[1] - 1) < 1e-6 and math.abs(c[2] - 0.62) < 1e-6 and math.abs(c[3] - 0.1) < 1e-6) or (math.abs(c[1] - 0.45) < 1e-6 and math.abs(c[2] - 0.25) < 1e-6)) then orange_lines = orange_lines + 1 end
  return 0
end
local thumb_blits = 0
local blit_x = {}
gfx.blit = function(src, _, _, _, _, _, _, dx) if src and src >= 20 then thumb_blits = thumb_blits + 1; blit_x[src] = dx end return 0 end
strings = {}; frame()
assert(saw("^CROSS$"), "the CROSS button is drawn")
assert(not saw("^MASTER$"), "and the MASTER button is gone")

-- the button opens the page
click(394 + 10, 6 + 9); strings = {}; frame()
assert(saw("CROSS: sound A flows into sound B"), "the page opens: " .. tostring(saw("CROSS")))
assert(saw("sound A: load an .ats file") and saw("sound B: load an .ats file"), "two empty blocks")
-- Esc goes back to the editor, the button opens it again
script.keys = { 27 }; frame(); strings = {}; frame()
assert(not saw("CROSS: sound A flows into sound B"), "Esc returns")
click(394 + 10, 6 + 9); strings = {}; frame()
assert(saw("CROSS: sound A flows into sound B"), "and the button opens it again")

-- A = the sound that is open in the editor (it was opened with O: a file, not modified)
click(356 + 10, 84 + 10); strings = {}; frame()
assert(saw("cx_test%.ats") and saw("used 0%.00 %- 0%.49 s of 0%.50 s"), "A is the open sound: " .. tostring(saw("cx_test") or saw("unsaved") or saw("no sound")))
-- B from a file (the open-file dialog is a stub)
load_path = second
click(40 + 10, 40 + 188 + 10); strings = {}; frame()
assert(saw("cx_second%.ats"), "B is loaded: " .. tostring(saw("loaded") or saw("cx_second")))
if os.getenv("REAATS_LOW_MEMORY") then       -- run with REAATS_LOW_MEMORY=1.0: any free memory counts as low
  assert(saw("WARNING: memory is low"), "the low-memory warning is shown")
else
  assert(not saw("WARNING: memory is low"), "no warning with plenty of memory")
end
assert(thumb_blits > 0, "the low resolution images of the sounds are drawn (image buffers 20 and 21)")
-- B starts half over the end of A: there is an overlap, so there is a red line
assert(saw("the red line"), "the red line is there inside the overlap: " .. tostring(saw("overlap")))

-- a double-click on block B opens that sound in the editor; "B = THE OPEN SOUND" brings the file back
click(700, 300); click(700, 300); strings = {}; frame()
assert(saw("cx_second%.ats is open in the editor"), "a double-click opens the sound in the editor: " .. tostring(saw("open in the editor") or saw("unsaved") or saw("CROSS")))
assert(not saw("CROSS: sound A flows into sound B"), "the page is left")
click(394 + 10, 6 + 9); strings = {}; frame()
assert(saw("CROSS: sound A flows into sound B"), "and the button brings it back")
click(356 + 10, 40 + 188 + 10); strings = {}; frame()
assert(saw("the sound of the editor is B now: cx_second%.ats"), "USE THE EDITOR'S SOUND AS B: " .. tostring(saw("loaded") or saw("unsaved") or saw("no sound")))
-- how many threads the recipe would make is counted (A's 200 and 800 Hz meet B's 205 and 800 Hz inside the overlap)
assert(saw("^2 threads: partials of A and B that sound together"), "the page counts the threads: " .. tostring(saw("thread")))
-- the time tolerance slider: its left end is a hard line
click(40, 40 + 394 + 5); strings = {}; frame()
assert(saw("^hard line$"), "the slider at its left end: hard line: " .. tostring(saw("s$")))
click(40 + 150, 40 + 394 + 5); strings = {}; frame()
assert(not saw("^hard line$"), "moved: a time tolerance")

-- the cut: drag the right handle of A to the left (A ends at 0.49 s, x = 629 in this window): less of A is used
drag(629, 160, 529, 160); strings = {}; frame()
local used = saw("used 0%.00 %- 0%.4%d s of 0%.50 s")
assert(used and not used:find("0%.49 s of"), "the right handle was dragged: A is cut: " .. tostring(saw("used")))

-- MAKE RESULT: a new file that opens in the editor
local expected = scratch .. "cx_test_cross1.ats"
os.remove(expected)
click(40 + 20, 40 + 434 + 10); strings = {}; frame()
local f = io.open(expected, "rb")
assert(f, "the result file was written next to A: " .. tostring(saw("cannot") or saw("result")))
f:close()
assert(saw("cx_test_cross1%.ats") or saw("partials in %d+ rows"), "the editor shows the result: " .. tostring(saw("cross") or saw("partials")))
assert(not saw("CROSS: sound A flows into sound B"), "the page is left, the editor shows the picture")
-- the editor draws the threads in blinking orange over the result (bright and dim, so over a second both states are drawn)
do
  local before = orange_lines
  for i = 1, 8 do clock_skew = clock_skew + 0.2; strings = {}; frame() end
  assert(orange_lines > before, "the orange blinking partials are drawn in the editor: " .. orange_lines .. " lines")
end
-- the threads are told, and the red line can be dragged in the editor: the page takes the new place
assert(saw("%d+ thread"), "the status tells the threads: " .. tostring(saw("thread") or saw("rows")))
do
  local r0 = assert(ats.load(expected))
  local tmax = r0.times[r0.frames]
  local line_before
  click(394 + 10, 6 + 9); strings = {}; frame()
  line_before = tonumber((saw("the red line  ([%d%.]+) s") or ""):match("the red line  ([%d%.]+) s"))
  script.keys = { 27 }; frame(); strings = {}; frame()
  assert(line_before, "the page tells where the red line is: " .. tostring(saw("red line")))
  -- the line in the editor is at (line - start) / tmax of the picture (62 .. 1050); drag its handle 120 px to the right
  local x_line = 62 + (line_before - 0) / tmax * 988
  drag(math.floor(x_line), 70 + 4, math.floor(x_line) + 120, 70 + 4)
  strings = {}; frame()
  assert(saw("^the red line: [%d%.]+ s"), "the line moves in the editor: " .. tostring(saw("red line") or saw("selected")))
  click(394 + 10, 6 + 9); strings = {}; frame()
  local line_after = tonumber((saw("the red line  ([%d%.]+) s") or ""):match("the red line  ([%d%.]+) s"))
  assert(line_after and line_after > line_before + 0.01, "the CROSS page has the new place: " .. tostring(line_before) .. " -> " .. tostring(line_after))
  script.keys = { 27 }; frame(); strings = {}; frame()
end
-- loading a sound again on the page does not make the open result forget its red line and its blinking partials (this was lost once: the result was dropped on every load)
do
  click(394 + 10, 6 + 9); load_path = second; click(40 + 10, 40 + 188 + 10)
  script.keys = { 27 }; frame(); strings = {}; frame()
  local before = orange_lines
  for i = 1, 8 do clock_skew = clock_skew + 0.2; strings = {}; frame() end
  assert(orange_lines > before, "the orange blinking partials are still drawn after a sound was loaded again: " .. orange_lines)
end
-- the result is a real analysis: it opens, it has more than one partial
local r = assert(ats.load(expected))
assert(r.partials >= 2 and r.dur > 0.49, "the result has the length of both: " .. r.dur .. " s, " .. r.partials .. " rows")
-- a second result does not overwrite the first
click(394 + 10, 6 + 9); strings = {}; frame()
click(40 + 20, 40 + 434 + 10); strings = {}; frame()
local f2 = io.open(scratch .. "cx_test_cross2.ats", "rb")
assert(f2, "the second result has its own name"); f2:close()
-- B dragged far to the right: the used parts no longer overlap: no transition
click(394 + 10, 6 + 9); strings = {}; frame()
drag(700, 300, 1000, 300); strings = {}; frame()
assert(saw("do not overlap"), "no overlap: " .. tostring(saw("overlap") or saw("red line")))
-- the red line is drawn over the result without a crash (a few frames)
strings = {}; frame(); frame()
-- EDIT B jumps to the editor with sound B; what is saved there comes back as B, at the same place (the image does not move)
do
  click(394 + 10, 6 + 9); strings = {}; frame()
  click(356 + 10, 40 + 188 + 10); strings = {}; frame()                       -- USE THE EDITOR'S SOUND AS B (the result that is open): a long sound
  strings = {}; frame()
  load_path = second
  click(40 + 10, 40 + 188 + 10); strings = {}; frame()                        -- LOAD B: the second sound again
  local x_before = blit_x[21]
  assert(x_before, "the image of B is drawn")
  click(158 + 10, 40 + 188 + 10); strings = {}; frame()                       -- EDIT B IN THE EDITOR
  assert(saw("cx_second%.ats is open in the editor"), "EDIT B jumps to the editor with B: " .. tostring(saw("open in the editor") or saw("unsaved") or saw("CROSS")))
  assert(not saw("CROSS: sound A flows into sound B"), "the page is left")
  script.keys = { 1 }; frame(); script.keys = { 30064 }; frame()              -- Ctrl+A, Up: everything one semitone higher
  strings = {}; frame()                                                       -- NO Ctrl+S: nothing is saved
  click(394 + 10, 6 + 9); strings = {}; frame()
  assert(saw("B has the changes made in the editor"), "the changed sound comes back as B from memory: " .. tostring(saw("changes") or saw("save") or saw("CROSS")))
  assert(not io.open(scratch .. "cx_second_edit.ats", "rb"), "and nothing was written")
  local fq = io.open(scratch .. "cx_second_edit.ats", "rb"); if fq then fq:close() end
  assert(blit_x[21] and math.abs(blit_x[21] - x_before) < 0.5, "and stays where B was: " .. tostring(x_before) .. " -> " .. tostring(blit_x[21]))
  -- the editor's sound used as A replaces A from memory too
  click(394 + 10, 6 + 9); strings = {}; frame()
  click(356 + 10, 40 + 44 + 10); strings = {}; frame()
  assert(saw("the sound of the editor is A now"), "USE THE EDITOR'S SOUND AS A needs no saving: " .. tostring(saw("save") or saw("sound")))
  assert(not saw("save it first"), "no demand to save")
  script.keys = { 27 }; frame()
end
os.remove(expected); os.remove(scratch .. "cx_test_cross2.ats"); os.remove(second)
print("CROSS page OK: button, page, A from the open sound, B from a file, the red line, the sliders, MAKE RESULT opens a new numbered file in the editor")
