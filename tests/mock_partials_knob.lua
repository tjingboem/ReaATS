-- Run: lua5.4 tests/mock_partials_knob.lua   (from the ReaATS folder)
-- The MAX PARTIALS button (bottom left, where the keyboard-shortcut hint lines used to be): greyed out with no selection, otherwise
-- opens REAPER's own text-input dialog (positive: keep that many loudest, negative: that many weakest) and applies right away, one
-- undo step. Runs ATS_Editor.lua against a fake gfx/reaper, on a hand-built, single-channel fixture of 4 separate, flat partials
-- with known, distinct energies, so the ranking is fully predictable.
local root = os.getenv("PWD")
local scratch = "/tmp/claude-1000/-home-tjingboem/6ca29d3f-340f-46ca-9b11-e579b6c375ee/scratchpad/"
local work = scratch .. "pk_test.ats"
local edited_path = scratch .. "pk_test_edit.ats"
local edited_path2 = scratch .. "pk_test_edit2.ats"
local edited_path3 = scratch .. "pk_test_edit3.ats"
local edited_path4 = scratch .. "pk_test_edit4.ats"
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
local bx, by = 284 + 10, 6 + 9
local function click_button()
  dialog_calls = 0
  gfx.mouse_cap = 1; gfx.mouse_x, gfx.mouse_y = bx, by; strings = {}; frame()
  gfx.mouse_cap = 0; frame()
end

local function all_zero(saved, p) for f = 1, NF do if saved.amp[p][f] ~= 0 then return false end end return true end
local function unchanged(saved, p, amp, freq) for f = 1, NF do if saved.amp[p][f] ~= amp or saved.frq[p][f] ~= freq then return false end end return true end

-- with nothing selected the button is greyed out and does nothing: no dialog opens, the click instead falls through to an ordinary
-- (empty) box-select on the picture
click_button()
assert(dialog_calls == 0, "no selection: the button must not open the dialog")

-- select the whole picture: a box from corner to corner selects all 4 partials. The drag starts exactly at the plot's own edge
-- (px, py) -- inside it, as a mouse-down must be -- and overshoots past the far edge on the way out, which the box-select clamps
-- back to exactly px+pw/py+ph: t_of(px) and t_of(px+pw) then land on exactly view.t0/view.t1 (0 and tmax), so frame 1 and frame NF
-- are both genuinely included, not just "close enough" -- the fix below only silences what is actually selected, so a selection
-- that silently missed the very first or last frame would leave it behind and fail the all-silenced checks that follow.
gfx.mouse_cap = 1; gfx.mouse_x, gfx.mouse_y = px, py + 2; frame()
gfx.mouse_x, gfx.mouse_y = px + pw + 50, py + ph + 50; frame()
gfx.mouse_cap = 0; frame(); frame()
assert(saw("^selected: %d+ points in 4 partials"), "all 4 partials selected: " .. table.concat(strings, " / ", 1, math.min(#strings, 20)))
strings = {}; frame()
assert(saw("MAX PARTIALS"), "the button is drawn: " .. tostring(saw("MAX")))

-- cancelling the dialog changes nothing
dialog_ok, dialog_text = false, ""
click_button()
assert(dialog_calls == 1, "the dialog opened with a selection")
assert(not saw(" %*$"), "Cancel applied nothing: no modified marker")

-- a non-numeric answer is refused, nothing changes
dialog_ok, dialog_text = true, "abc"
click_button()
assert(saw("^max partials: not a number$"), "non-numeric input refused: " .. tostring(saw("max partials")))
assert(not saw(" %*$"), "a refused answer applied nothing")

-- a positive count keeps the N LOUDEST (200 Hz amp .9 = energy 45, 1600 Hz amp .7 = energy 35), silencing the 2 quietest
dialog_ok, dialog_text = true, "2"
click_button()
assert(saw("^kept the 2 loudest, silenced 2$"), "positive count keeps the loudest: " .. tostring(saw("kept") or saw("loudest")))
assert(saw(" %*$"), "modified marker after applying")

script.keys = { 19 }; strings = {}; frame(); frame()
assert(saw("^saved pk_test_edit%.ats"), "save status missing: " .. table.concat(strings, " / ", 1, math.min(#strings, 20)))
local saved = assert(ats.load(edited_path))
assert(unchanged(saved, 1, 0.9, 200), "the loudest partial (200 Hz) is untouched")
assert(unchanged(saved, 4, 0.7, 1600), "the 2nd loudest partial (1600 Hz) is untouched")
assert(all_zero(saved, 2), "the quietest partial (400 Hz) is silenced")
assert(all_zero(saved, 3), "the 3rd loudest partial (800 Hz) is silenced")

-- undo restores the 2 silenced partials (saved again, to check the actual data rather than trust the status line alone)
script.keys = { 26 }; strings = {}; frame(); frame()
assert(saw("^undo max partials$"), "undo status missing: " .. tostring(saw("undo")))
script.keys = { 19 }; strings = {}; frame(); frame()
assert(saw("^saved pk_test_edit2%.ats"), "second save status missing (never overwrites): " .. tostring(saw("saved")))
saved = assert(ats.load(edited_path2))
assert(unchanged(saved, 2, 0.2, 400), "undo restores the previously-silenced 400 Hz partial")
assert(unchanged(saved, 3, 0.5, 800), "undo restores the previously-silenced 800 Hz partial")

-- the mirror: a NEGATIVE count keeps the N WEAKEST instead, silencing the 2 loudest (undo clears the selection, made again first)
gfx.mouse_cap = 1; gfx.mouse_x, gfx.mouse_y = px, py + 2; frame()
gfx.mouse_x, gfx.mouse_y = px + pw + 50, py + ph + 50; frame()
gfx.mouse_cap = 0; frame(); frame()
dialog_ok, dialog_text = true, "-2"
click_button()
assert(saw("^kept the 2 weakest, silenced 2$"), "negative count keeps the weakest: " .. tostring(saw("kept") or saw("weakest")))
script.keys = { 19 }; strings = {}; frame(); frame()
assert(saw("^saved pk_test_edit3%.ats"), "third save status missing: " .. tostring(saw("saved")))
saved = assert(ats.load(edited_path3))
assert(unchanged(saved, 2, 0.2, 400), "the quietest partial (400 Hz) is untouched in weak mode")
assert(unchanged(saved, 3, 0.5, 800), "the 3rd loudest partial (800 Hz) is untouched in weak mode")
assert(all_zero(saved, 1), "the loudest partial (200 Hz) is silenced in weak mode")
assert(all_zero(saved, 4), "the 2nd loudest partial (1600 Hz) is silenced in weak mode")

-- the regression: select only a MIDDLE STRETCH of the picture, not the whole thing -- a dropped partial must only be silenced where
-- it was actually selected, never outside that stretch on the very same row, even though every partial here is one continuous run
-- spanning the whole file (tjingboem, 10 Nov 2026, with screenshots: "also outside the selection on the left things were removed,
-- as if that was part of the selection... only the selection should be affected")
-- R reloads the pristine fixture from disk first: the earlier tests left partials 1 and 4 silenced in the live data (never
-- undone), and reload also clears the still-active full selection -- dragging a NEW box while clicking down on an already-
-- selected point would move the existing selection instead of starting a fresh, smaller one.
script.keys = { 114 }; strings = {}; frame()
gfx.mouse_cap = 1; gfx.mouse_x, gfx.mouse_y = px + 200, py + 2; frame()
gfx.mouse_x, gfx.mouse_y = px + pw - 200, py + ph - 2; frame()
gfx.mouse_cap = 0; frame(); frame()
local sel_msg = saw("^selected: %d+ points in 4 partials   ([%d%.]+)%-([%d%.]+) s")
assert(sel_msg, "a middle stretch is selected: " .. tostring(sel_msg))
local t0, t1 = sel_msg:match("([%d%.]+)%-([%d%.]+) s")
t0, t1 = tonumber(t0), tonumber(t1)
assert(t0 > 0.05 and t1 < 0.44, "the selection leaves real margin on both sides: " .. t0 .. "-" .. t1)
dialog_ok, dialog_text = true, "2"                                  -- keep the 2 loudest, silence the 2 quietest, but ONLY inside the selection
click_button()
assert(saw("^kept the 2 loudest, silenced 2$"), "applies as usual on a partial selection: " .. tostring(saw("kept")))
script.keys = { 19 }; strings = {}; frame(); frame()
assert(saw("^saved pk_test_edit4%.ats"), "fourth save status missing: " .. tostring(saw("saved")))
saved = assert(ats.load(edited_path4))
local lo, hi = math.floor(t0 / HOP) + 1, math.floor(t1 / HOP) + 1       -- the selected frame range, from the reported time range
for _, p in ipairs({ 2, 3 }) do                                        -- the 2 quietest: silenced INSIDE the selection...
  for f = lo, hi do assert(saved.amp[p][f] == 0, string.format("partial %d frame %d should be silenced (inside selection)", p, f)) end
  -- ...but perfectly intact just outside it, on either side, on the very same row
  assert(saved.amp[p][1] == PARTIALS[p].amp and saved.frq[p][1] == PARTIALS[p].freq,
         string.format("partial %d is untouched well BEFORE the selection (frame 1)", p))
  assert(saved.amp[p][NF] == PARTIALS[p].amp and saved.frq[p][NF] == PARTIALS[p].freq,
         string.format("partial %d is untouched well AFTER the selection (frame %d)", p, NF))
end
assert(unchanged(saved, 1, 0.9, 200), "the loudest partial is untouched everywhere, selected or not")
assert(unchanged(saved, 4, 0.7, 1600), "the 2nd loudest partial is untouched everywhere, selected or not")

print("MAX PARTIALS button OK: greyed out with no selection, ranks by total energy, positive keeps the loudest, negative the weakest, undo restores, and only ever touches the actual selection")
