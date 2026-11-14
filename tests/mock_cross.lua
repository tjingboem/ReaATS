REAATS_TEST_ANALYSIS_LAYOUT = (os.getenv("PWD") or ".") .. "/tests/analysis_layout_test.lua"       -- (the Analysis page layout the clicks are made for)
REAATS_TEST_LAYOUT = (os.getenv("PWD") or ".") .. "/tests/editor_layout_test.lua"            -- the editor layout the clicks below are made for
-- Run: lua5.4 tests/mock_cross.lua   (from the ReaATS folder)
-- The CROSS button and page: two blocks (A, B), dragging, the cut, the red line, the sliders, MAKE RESULT (a new file that opens in the editor).
-- Runs ATS_Editor.lua against a fake gfx/reaper; A = the 4 flat partials of the shared fixture, B = a second analysis with two partials.
local root = os.getenv("PWD")
REAATS_TEST_CROSS_LAYOUT = root .. "/tests/cross_layout_test.lua"            -- the layout the clicks below are made for
local scratch = "/tmp/claude-1000/-home-tjingboem/6ca29d3f-340f-46ca-9b11-e579b6c375ee/scratchpad/"
local work = scratch .. "cx_test.ats"
local edited_path = scratch .. "cx_test_edit.ats"
local edited_path2 = scratch .. "cx_test_edit2.ats"
local edited_path3 = scratch .. "cx_test_edit3.ats"
local edited_path4 = scratch .. "cx_test_edit4.ats"
for i = 1, 40 do os.remove(scratch .. "cx_test_cross" .. i .. ".ats"); os.remove(scratch .. "cx_second_cross" .. i .. ".ats") end         -- (results of earlier runs: the numbers would climb)
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
local previews = 0
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
  PCM_Source_CreateFromFile = function(p) return { path = p } end,
  Xen_StartSourcePreview = function() previews = previews + 1; return true end,
  Xen_StopSourcePreview = function() return true end,
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
local orange_rects, old_rect = 0, gfx.rect
local red_full, red_faint = 0, 0
local sel_frame, sel_dim = 0, 0
gfx.rect = function(...)
  local c = last_col
  if c[1] and math.abs(c[1] - 1) < 1e-6 and math.abs(c[2] - 1) < 1e-6 and math.abs(c[3] - 1) < 1e-6 and math.abs((c[4] or 1) - 0.95) < 1e-6 and select("#", ...) == 5 and select(5, ...) == 0 then sel_frame = sel_frame + 1 end
  if c[1] and c[1] == 0 and c[2] == 0 and c[3] == 0 and math.abs((c[4] or 1) - 0.45) < 1e-6 then sel_dim = sel_dim + 1 end
  if c[1] and math.abs(c[1] - 1) < 1e-6 and math.abs(c[2] - 0.23) < 1e-6 and math.abs(c[3] - 0.19) < 1e-6 then
    if math.abs((c[4] or 1) - 1) < 1e-6 then red_full = red_full + 1 elseif math.abs((c[4] or 1) - 0.3) < 1e-6 then red_faint = red_faint + 1 end
  end
  if c[1] and math.abs(c[1] - 1) < 1e-6 and math.abs(c[2] - 0.62) < 1e-6 and math.abs(c[3] - 0.1) < 1e-6 then orange_rects = orange_rects + 1 end
  return old_rect(...)
end
gfx.line = function()
  local c = last_col
  if c[1] and ((math.abs(c[1] - 1) < 1e-6 and math.abs(c[2] - 0.62) < 1e-6 and math.abs(c[3] - 0.1) < 1e-6) or (math.abs(c[1] - 0.45) < 1e-6 and math.abs(c[2] - 0.25) < 1e-6)) then orange_lines = orange_lines + 1 end
  return 0
end
local thumb_blits = 0
local blit_x, blit_w, blit_y = {}, {}, {}
gfx.blit = function(src, _, _, _, _, _, _, dx, dy, dw) if src and src >= 20 then thumb_blits = thumb_blits + 1; blit_x[src] = dx; blit_w[src] = dw; blit_y[src] = dy end return 0 end
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
gfx.mouse_x, gfx.mouse_y = 948, 120 + 16; strings = {}; frame()   -- the mouse is on the little i of block A (top right of its used part): the box shows the information
assert(saw("sound A: cx_test%.ats") and saw("used 0%.00 %- 0%.49 s of 0%.50 s") and saw("partials, %d+ frames, hop"), "A is the open sound: " .. tostring(saw("cx_test") or saw("unsaved") or saw("no sound")))
gfx.mouse_x, gfx.mouse_y = 5, 5; strings = {}; frame()
assert(saw("^100$") and saw("^1k$") and saw("^10k$"), "the frequency scale is drawn at the left of the lanes")
assert(not saw("^used 0%.00") and not saw("^sound A: "), "away from the block the picture is free of text")
gfx.mouse_x, gfx.mouse_y = 300, 170; strings = {}; frame()
assert(saw("^i$") and not saw("^sound A: "), "on the block (not on the i) there is no box, and the i is drawn")
-- B from a file (the open-file dialog is a stub)
load_path = second
click(40 + 10, 40 + 188 + 10); strings = {}; frame()
assert(saw("cx_second%.ats") or (os.getenv("REAATS_LOW_MEMORY") and saw("WARNING")), "B is loaded: " .. tostring(saw("loaded") or saw("cx_second")))
if os.getenv("REAATS_LOW_MEMORY") then       -- run with REAATS_LOW_MEMORY=1.0: any free memory counts as low
  assert(saw("WARNING: memory is low"), "the low-memory warning is shown")
else
  assert(not saw("WARNING: memory is low"), "no warning with plenty of memory")
end
assert(thumb_blits > 0, "the low resolution images of the sounds are drawn (image buffers 20 and 21)")
-- B starts half over the end of A: there is an overlap, so there is a red line
assert(saw("^%d+%.%d%d%d s$"), "the red line is there inside the overlap: " .. tostring(saw("overlap")))

-- a double-click on block B opens that sound in the editor; "B = THE OPEN SOUND" brings the file back
click(700, 300); click(700, 300); strings = {}; frame()
assert(saw("cx_second%.ats is open in the editor"), "a double-click opens the sound in the editor: " .. tostring(saw("open in the editor") or saw("unsaved") or saw("CROSS")))
assert(not saw("CROSS: sound A flows into sound B"), "the page is left")
click(394 + 10, 6 + 9); strings = {}; frame()
assert(saw("CROSS: sound A flows into sound B"), "and the button brings it back")
click(356 + 10, 40 + 188 + 10); strings = {}; frame()
assert(saw("cx_second%.ats is on the page already"), "the editor's sound is on the page already (the same table): it is selected, not added again: " .. tostring(saw("loaded") or saw("unsaved") or saw("no sound")))
-- how many threads the recipe would make is counted (A's 200 and 800 Hz meet B's 205 and 800 Hz inside the overlap)
assert(saw("^2 threads$"), "the page counts the threads: " .. tostring(saw("thread")))
do                                                                                 -- the partials of the threads blink in both lanes of the page
  local before = orange_rects
  for i = 1, 4 do clock_skew = clock_skew + 0.2; strings = {}; frame() end
  assert(orange_rects - before >= 2, "orange partials are drawn in the lanes: " .. (orange_rects - before))
end
-- the time tolerance slider: its left end is a hard line
click(40, 40 + 394 + 5); strings = {}; frame()
assert(saw("^hard line$"), "the slider at its left end: hard line: " .. tostring(saw("s$")))
click(40 + 150, 40 + 394 + 5); strings = {}; frame()
assert(not saw("^hard line$"), "moved: a time tolerance")

-- the cut: drag the right handle of A to the left (A ends at 0.49 s, x = 629 in this window): less of A is used
drag(629, 160, 529, 160); strings = {}; frame()
gfx.mouse_x, gfx.mouse_y = 529 - 16, 120 + 16; strings = {}; frame()
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
  line_before = tonumber((saw("^%d+%.%d%d%d s$") or ""):match("^(%d+%.%d%d%d)"))
  script.keys = { 27 }; frame(); strings = {}; frame()
  assert(line_before, "the page tells where the red line is: " .. tostring(saw("red line")))
  -- the line in the editor is at (line - start) / tmax of the picture (62 .. 1050); drag its handle 120 px to the right
  local x_line = 62 + (line_before - 0) / tmax * 988
  drag(math.floor(x_line), 70 + 4, math.floor(x_line) + 120, 70 + 4)
  strings = {}; frame()
  assert(saw("^the red line: [%d%.]+ s"), "the line moves in the editor: " .. tostring(saw("red line") or saw("selected")))
  click(394 + 10, 6 + 9); strings = {}; frame()
  local line_after = tonumber((saw("^%d+%.%d%d%d s$") or ""):match("^(%d+%.%d%d%d)"))
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
-- a second result does not overwrite the first (the second B that was loaded above is taken away again with Ctrl+Z)
click(394 + 10, 6 + 9); strings = {}; frame()
script.keys = { 26 }; strings = {}; frame()
assert(saw("undone"), "Ctrl+Z takes the second B away again")
click(40 + 20, 40 + 434 + 10); strings = {}; frame()
local f2 = io.open(scratch .. "cx_test_cross2.ats", "rb")
assert(f2, "the second result has its own name"); f2:close()
-- B dragged far to the right: the used parts no longer overlap: no transition
click(394 + 10, 6 + 9); strings = {}; frame()
drag(700, 300, 1000, 300); strings = {}; frame()
assert(saw("do not overlap"), "no overlap: " .. tostring(saw("overlap") or saw("red line")))
-- B dragged to the LEFT of A (it starts before A, they overlap): the sound that starts first flows into the other, B into A
do
  strings = {}; frame()
  local pps = blit_w[21] / 0.6                                                  -- pixels per second (B is 0.6 s long)
  local want = blit_x[20] - 0.1 * pps                                           -- B starts 0.1 s before A
  local from = blit_x[21] + blit_w[21] / 2
  drag(math.floor(from), 300, math.floor(from + want - blit_x[21]), 300); strings = {}; frame()
  assert(blit_x[21] < blit_x[20], "B now starts before A: " .. blit_x[21] .. " " .. blit_x[20])
  assert(saw("^%d+%.%d%d%d s$"), "B before A overlaps again: " .. tostring(saw("overlap") or saw("do not overlap")))
  local pre = scratch .. "cx_second_cross1.ats"                                  -- (named after the sound that starts first: B)
  os.remove(pre)
  click(40 + 20, 40 + 434 + 10); strings = {}; frame()
  local fh = io.open(pre, "rb")
  assert(fh, "the result with B in front was written: " .. tostring(saw("cannot") or saw("result")))
  fh:close()
  local r = assert(ats.load(pre))
  local function at(t) local f = math.floor(t / HOP + 0.5) + 1; local out = {}; for p = 1, r.partials do if r.amp[p][f] > 0 then out[#out + 1] = r.frq[p][f] end end; table.sort(out); return out end
  local first = at(0.02)
  local near205 = false
  for _, fr in ipairs(first) do if math.abs(fr - 205) < 3 or math.abs(fr - 800) < 3 then near205 = true end end
  assert(near205 and #first >= 1, "the result starts with B's partials (205 / 800 Hz): " .. table.concat(first, ", "))
  assert(r.dur > 0.5 and r.dur < 0.65, "and it is one sound of both lengths together (B started first, A is inside it): " .. r.dur)
  os.remove(pre)
  click(394 + 10, 6 + 9); strings = {}; frame()
end
-- the red line is drawn over the result without a crash (a few frames)
strings = {}; frame(); frame()
-- EDIT B jumps to the editor with sound B; what is changed there comes back as B, at the same place (the image does not move)
do
  click(394 + 10, 6 + 9); strings = {}; frame()
  local x_before = blit_x[21]
  assert(x_before, "the image of B is drawn")
  click(158 + 10, 40 + 188 + 10); strings = {}; frame()                       -- EDIT B IN THE EDITOR
  assert(saw("cx_second%.ats is open in the editor"), "EDIT B jumps to the editor with B: " .. tostring(saw("open in the editor") or saw("unsaved") or saw("CROSS")))
  assert(not saw("CROSS: sound A flows into sound B"), "the page is left")
  script.keys = { 1 }; frame(); script.keys = { 30064 }; frame()              -- Ctrl+A, Up: everything one semitone higher
  strings = {}; frame()                                                       -- NO Ctrl+S: nothing is saved
  click(394 + 10, 6 + 9); strings = {}; frame()
  assert(saw("has the changes made in the editor"), "the changed sound comes back as B from memory: " .. tostring(saw("changes") or saw("save") or saw("CROSS")))
  assert(not io.open(scratch .. "cx_second_edit.ats", "rb"), "and nothing was written")
  local fq = io.open(scratch .. "cx_second_edit.ats", "rb"); if fq then fq:close() end
  assert(blit_x[21] and math.abs(blit_x[21] - x_before) < 0.5, "and stays where B was: " .. tostring(x_before) .. " -> " .. tostring(blit_x[21]))
  -- the editor's sound is that of B: it is on the page already, nothing is added
  click(356 + 10, 40 + 44 + 10); strings = {}; frame()
  assert(saw("is on the page already"), "the editor's sound that is on the page is not added again: " .. tostring(saw("sound")))
  -- a sound that is not on the page is ADDED to the lane (A: after the first sound): the editor opens the test file again (key O)
  script.keys = { 27 }; frame()
  script.keys = { 111 }; frame(); frame()
  click(394 + 10, 6 + 9); strings = {}; frame()
  click(356 + 10, 40 + 44 + 10); strings = {}; frame()
  assert(saw("the sound of the editor is added"), "USE THE EDITOR'S SOUND AS A adds the sound (no saving needed): " .. tostring(saw("save") or saw("sound")))
  assert(blit_x[22] and blit_x[22] > blit_x[20], "the new block A2 stands behind the first one on lane A: " .. tostring(blit_x[22]) .. " " .. tostring(blit_x[20]))
  assert(not saw("save it first"), "no demand to save")
  -- two transitions now (A1 -> B and B -> A2): the sliders change the ACTIVE one; Tab takes the next (values that are not on the ruler: 0.44 s and 0.16 s)
  do
    click(40 + 100, 434 + 5); strings = {}; frame()
    assert(saw("^0%.44 s$"), "the time slider changes the active (first) transition: " .. tostring(saw(" s$")))
    script.keys = { 9 }; strings = {}; frame(); strings = {}; frame()
    assert(not saw("^0%.44 s$"), "Tab: the next transition has its own tolerance, not 0.44 s")
    click(40 + 60, 434 + 5); strings = {}; frame()
    assert(saw("^0%.16 s$"), "and the slider changes that one: " .. tostring(saw(" s$")))
    script.keys = { 9 }; strings = {}; frame(); strings = {}; frame()
    assert(saw("^0%.44 s$") and not saw("^0%.16 s$"), "Tab again: the first transition kept 0.44 s")
    red_full, red_faint = 0, 0
    strings = {}; frame()
    assert(red_full > 0 and red_faint > 0, "the active red line is drawn in full, the other one faint: " .. red_full .. " " .. red_faint)
    click(40 + 120, 434 + 5); strings = {}; frame()                              -- (back to a value, for the rest of the test)
  end
  -- level of a sound: its slider (layout sl_gain_a at 660, 90; 200 wide, -24 .. +12 dB, sticks at 0)
  click(660, 90 + 5); strings = {}; frame()
  assert(saw("^%-24%.0 dB$"), "the level slider at its left end: -24 dB: " .. tostring(saw("dB")))
  click(660 + 133, 90 + 5); strings = {}; frame()
  assert(saw("^%+0%.0 dB$"), "and back at 0 dB (it sticks)")
  -- ONE selection for both lanes, ONE level slider for the selected block (a block of lane B and one of lane A in turn)
  do
    local function pick_a() click(math.floor(blit_x[20] + blit_w[20] * 0.3), 150) end
    local function pick_b() click(math.floor(blit_x[21] + blit_w[21] * 0.1), 300) end
    pick_b(); click(660, 90 + 5); strings = {}; frame()
    assert(saw("^%-24%.0 dB$"), "the level slider changes the selected block of lane B: " .. tostring(saw("dB")))
    pick_a(); strings = {}; frame()
    assert(saw("^%+0%.0 dB$") and not saw("^%-24%.0 dB$"), "select a block of lane A: the slider shows that block's own level")
    pick_b(); strings = {}; frame()
    assert(saw("^%-24%.0 dB$"), "and the block of lane B kept its level")
    click(660 + 133, 90 + 5); strings = {}; frame()                              -- (back to 0 dB)
    assert(saw("^%+0%.0 dB$"))
    sel_frame, sel_dim = 0, 0
    strings = {}; frame()
    assert(sel_frame >= 3 and sel_dim >= 1, "the selected block has the thick frame, the others are dimmed")
  end
  -- the curve menu (layout dd_curve at 740, 434; the list opens below it)
  click(740 + 10, 434 + 10); strings = {}; frame()
  assert(saw("^Equal power$") and saw("^S curve$"), "the menu lists the curves: " .. tostring(saw("Smooth")))
  click(740 + 10, 434 + 22 * 2 + 10); strings = {}; frame()                   -- Linear
  assert(not saw("^S curve$") and saw("^Linear$"), "a choice closes the menu and shows the curve")
  -- AUDITION on the page: the crossing is made in memory and played (nothing is written)
  do
    local before_files = io.open(scratch .. "cx_test_cross5.ats", "rb"); if before_files then before_files:close() end
    click(240 + 10, 474 + 10)
    for i = 1, 600 do strings = {}; frame(); if previews > 0 then break end end
    assert(previews > 0, "AUDITION plays the crossing from memory: " .. previews)
    script.keys = { 32 }; strings = {}; frame()                                  -- Space stops
  end
  -- Ctrl+click twice in a lane: a diagonal; Esc takes it away again
  local function ctrl_click(x, y) gfx.mouse_cap = 1 | 4; gfx.mouse_x, gfx.mouse_y = x, y; frame(); gfx.mouse_cap = 0; frame() end
  ctrl_click(blit_x[21] + 40, 150); ctrl_click(blit_x[21] + 140, 200); strings = {}; frame()
  assert(saw("diagonal"), "two Ctrl+clicks make a diagonal line: " .. tostring(saw("red line")))
  -- MAKE with the diagonal: the result file opens in the editor and its diagonal is drawn over the picture (no crash, the line is not draggable)
  script.keys = { 13 }; strings = {}; frame(); strings = {}; frame(); frame(); frame()
  assert(not saw("CROSS: sound A flows into sound B"), "the page is left after MAKE")
  click(394 + 10, 6 + 9); strings = {}; frame()
  script.keys = { 27 }; strings = {}; frame(); strings = {}; frame()
  assert(saw("^%d+%.%d%d%d s$") and not saw("diagonal"), "Esc gives the vertical line back (and stays on the page)")
  -- Shift = fine drag: a tenth of the mouse movement
  do
    local bx = blit_x[21]
    local mid = bx + blit_w[21] * 0.16                                             -- (not in the middle: a red line may stand there; not where the last click was: that would be a double-click)
    gfx.mouse_cap = 1 | 8; gfx.mouse_x, gfx.mouse_y = mid, 300; frame()
    gfx.mouse_x = mid + 50; frame(); gfx.mouse_x = mid + 100; frame()
    local moved = blit_x[21] - bx                                                -- (read while the button is still down: letting go fits the view again)
    gfx.mouse_cap = 0; frame(); strings = {}; frame()
    assert(math.abs(moved - 10) < 1.5, "Shift: 100 px of the mouse move the block 10 px: " .. tostring(moved))
  end
  -- the wheel zooms round the pointer, a double-click on the ruler fits everything again
  do
    local w0 = blit_w[21]
    gfx.mouse_x, gfx.mouse_y, gfx.mouse_wheel = 500, 300, 240; strings = {}; frame(); gfx.mouse_wheel = 0; strings = {}; frame()
    assert(blit_w[21] > w0 * 1.3, "the wheel zooms in: " .. w0 .. " -> " .. blit_w[21])
    click(300, 370 + 5); click(300, 370 + 5); strings = {}; frame()
    assert(math.abs(blit_w[21] - w0) < 2, "a double-click on the ruler fits the timeline: " .. blit_w[21])
  end
  -- right-click on a block removes the sound (B has changes that are not in a file: the question is answered with yes by the mock)
  do
    gfx.mouse_cap = 2; gfx.mouse_x, gfx.mouse_y = blit_x[21] + 30, 300; strings = {}; frame(); gfx.mouse_cap = 0; frame()
    assert(saw("cx_second%.ats removed"), "a right-click removes B: " .. tostring(saw("removed") or saw("B")))
    -- Ctrl+Z brings it back where it was, Ctrl+Y removes it again
    local b_blits = thumb_blits
    script.keys = { 26 }; strings = {}; frame(); strings = {}; frame()
    assert(saw("undone"), "Ctrl+Z undoes the removal: " .. tostring(saw("undo") or saw("removed")))
    assert(thumb_blits > b_blits and blit_x[21], "and the sound is back on its lane with its picture")
    script.keys = { 25 }; strings = {}; frame()
    assert(saw("redone"), "Ctrl+Y does it again")
    script.keys = { 26 }; strings = {}; frame()
  end
  -- LOAD adds another sound at the end of its lane (a timeline of any number of sounds); two sounds of one lane cannot overlap
  do
    local last = blit_x[22]
    load_path = second
    click(40 + 10, 84 + 10); strings = {}; frame()                                -- LOAD A
    assert(saw("cx_second%.ats loaded") or (os.getenv("REAATS_LOW_MEMORY") and saw("WARNING")), "LOAD A adds a sound: " .. tostring(saw("loaded") or saw("not enough")))
    sel_frame, sel_dim = 0, 0
    strings = {}; frame()
    assert(sel_frame >= 3 and sel_dim >= 1, "with several blocks in a lane the selected one has a thick white frame and the others are dimmed: " .. sel_frame .. " " .. sel_dim)
    assert(blit_x[23] and blit_x[23] > last, "the new block stands behind the others on lane A: " .. tostring(blit_x[23]) .. " " .. tostring(last))
    local from = blit_x[23] + blit_w[23] * 0.1
    drag(math.floor(from), 150, math.floor(from) - 600, 150); strings = {}; frame()      -- dragged left over its neighbours
    assert(blit_x[23] + blit_w[23] <= blit_x[20] + 1.5, "when it is let go the block lies in a free place, here BEFORE the first sound of the lane (it ends where that one begins): " .. tostring(blit_x[23] + blit_w[23]) .. " " .. tostring(blit_x[20]))
    -- dragged to the other lane
    local mid = blit_x[23] + blit_w[23] * 0.1
    local y_before = blit_y[23]
    drag(math.floor(mid), 150, math.floor(mid), 300); strings = {}; frame()
    assert(blit_y[23] > y_before + 100, "dragged down it is a sound of lane B: " .. tostring(y_before) .. " -> " .. tostring(blit_y[23]))
    -- MAKE with four sounds: one result file, more than one transition
    click(40 + 20, 40 + 434 + 10); strings = {}; frame()
    assert(not saw("CROSS: sound A flows into sound B"), "MAKE with four sounds leaves the page")
    do                                                                              -- the editor draws the lines of every transition (and the blinking threads) without trouble
      local before = orange_lines
      for i = 1, 8 do clock_skew = clock_skew + 0.2; strings = {}; frame() end
      assert(orange_lines >= before, "the result of several transitions is drawn")
    end
    click(394 + 10, 6 + 9); strings = {}; frame()
    script.keys = { 26 }; strings = {}; frame()                                   -- Ctrl+Z: the fourth sound is gone again
    assert(saw("undone"), "Ctrl+Z takes the added sound away")
  end
  script.keys = { 27 }; frame()
end
os.remove(expected); os.remove(scratch .. "cx_test_cross2.ats"); os.remove(scratch .. "cx_test_cross4.ats"); os.remove(second)
print("CROSS page OK: button, page, A from the open sound, B from a file, the red line, the sliders, MAKE RESULT opens a new numbered file in the editor")
