-- Run: lua5.4 tests/mock_partials_knob.lua   (from the ReaATS folder)
-- The max-partials slider under the selection box: drag it down, see a live preview, Enter silences everything beyond the count
-- (Esc puts it back). Runs ATS_Editor.lua against a fake gfx/reaper, on a hand-built, single-channel fixture of 4 separate, flat
-- partials with known, distinct energies, so the ranking and the exact pixel geometry are both fully predictable.
local root = os.getenv("PWD")
local scratch = "/tmp/claude-1000/-home-tjingboem/6ca29d3f-340f-46ca-9b11-e579b6c375ee/scratchpad/"
local work = scratch .. "pk_test.ats"
local edited_path = scratch .. "pk_test_edit.ats"
local edited_path2 = scratch .. "pk_test_edit2.ats"
local edited_path3 = scratch .. "pk_test_edit3.ats"
os.remove(edited_path)
os.remove(edited_path2)
os.remove(edited_path3)

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
reaper = {
  time_precise = function() return os.clock() + clock_skew end,
  ExecProcess = function(cmd) local ph = io.popen(cmd .. " 2>&1"); local out = ph:read("a"); ph:close(); return out end,
  get_action_context = function() return true, root .. "/ATS_Editor.lua", 0, 0 end,
  GetExtState = function(_, key) return (key == "last_file") and work or "" end,
  SetExtState = function() end,
  ShowConsoleMsg = function() end,
  MB = function() return 6 end,
  JS_Dialog_BrowseForSaveFile = function() return 0, "" end,
  GetUserInputs = function() return false, "" end,
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
local fmin, fmax = 200, 1600                                                    -- the lowest and highest of the 4 partials
local view_f0, view_f1 = fmin / 1.4, fmax * 1.4                                 -- fit_view()'s own margin
local tmax = (NF - 1) * HOP
local function screen(t, fr) return px + t / tmax * pw, py + ph * (1 - (math.log(fr) - math.log(view_f0)) / (math.log(view_f1) - math.log(view_f0))) end

-- select the whole picture: a box from corner to corner selects all 4 partials
gfx.mouse_cap = 1; gfx.mouse_x, gfx.mouse_y = px + 2, py + 2; frame()
gfx.mouse_x, gfx.mouse_y = px + pw - 2, py + ph - 2; frame()
gfx.mouse_cap = 0; frame(); frame()
assert(saw("^selected: %d+ points in 4 partials"), "all 4 partials selected: " .. table.concat(strings, " / ", 1, math.min(#strings, 20)))
strings = {}; frame()
assert(saw("^max partials: 4 of 4$"), "the slider starts full, at the true count: " .. tostring(saw("max partials")))

-- the slider's own geometry: under the box, clamped to the lane's own bottom (see W.pk_rect)
local sx, sy, sw = px, py + ph - 12, pw
local function click_slider(frac)
  gfx.mouse_cap = 1; gfx.mouse_x, gfx.mouse_y = sx + frac * sw, sy + 5; strings = {}; frame()
end

local function all_zero(saved, p) for f = 1, NF do if saved.amp[p][f] ~= 0 then return false end end return true end
local function unchanged(saved, p, amp, freq) for f = 1, NF do if saved.amp[p][f] ~= amp or saved.frq[p][f] ~= freq then return false end end return true end

-- the slider is centred: at rest (the middle) nothing is dropped, dragging LEFT of centre keeps the N loudest (frac 0.25 keeps 2:
-- 200 Hz amp .9 = energy 45, 1600 Hz amp .7 = energy 35), dragging RIGHT of centre keeps the N weakest instead (frac 0.75 keeps 2:
-- 400 Hz amp .2 = energy 10, 800 Hz amp .5 = energy 25) -- tjingboem, 10 Nov 2026: "drag from right to left = keep the strongest,
-- drag from left to right = keep the weakest"
click_slider(0.25)
assert(saw("^keep 2 loudest of 4  Enter applies   Esc cancels$"), "live slider status, loud mode: " .. tostring(saw("loudest")))
gfx.mouse_cap = 0; frame()

-- Esc puts it back to the full count, with nothing changed
script.keys = { 27 }; strings = {}; frame(); frame()
assert(saw("^max partials: reset$"), "Esc resets the slider: " .. tostring(saw("max partials")))
assert(not saw(" %*   |"), "Esc applied nothing: no modified marker")
assert(saw("^max partials: 4 of 4$"), "back to the full count after Esc")

-- drag it down to 2 loudest again and apply it with Enter: the 2 quietest (400 Hz, 800 Hz) are silenced, the 2 loudest untouched
click_slider(0.25)
assert(saw("^keep 2 loudest of 4  Enter applies   Esc cancels$"))
gfx.mouse_cap = 0; frame()
script.keys = { 13 }; strings = {}; frame(); frame()
assert(saw("^kept the 2 loudest, silenced 2$"), "Enter applies the slider: " .. tostring(saw("kept") or saw("loudest")))
assert(saw(" %*   |"), "modified marker after Enter")
-- the slider re-ranks the very same frame, against the now-smaller set of real partials, and shows full (2 of 2): the preview
-- guard (pk.n >= pk.max) is true again right away, so the dimmed lines of the two that were just silenced are gone immediately,
-- not lingering a frame behind the actual silencing (tjingboem, 10 Nov 2026: "the moment i do Enter, the grey lines should disappear")
assert(saw("^max partials: 2 of 2$"), "the slider re-ranks immediately to the smaller, real count: " .. tostring(saw("max partials")))

-- the actual data: saved to disk, the 2 quietest are silent throughout, the 2 loudest and their frequencies are untouched
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

-- the mirror: drag RIGHT of centre to keep the 2 WEAKEST, eliminating the 2 loudest instead (undo clears the selection, so it is
-- made again first)
gfx.mouse_cap = 1; gfx.mouse_x, gfx.mouse_y = px + 2, py + 2; frame()
gfx.mouse_x, gfx.mouse_y = px + pw - 2, py + ph - 2; frame()
gfx.mouse_cap = 0; frame(); frame()
click_slider(0.75)
assert(saw("^keep 2 weakest of 4  Enter applies   Esc cancels$"), "live slider status, weak mode: " .. tostring(saw("weakest")))
gfx.mouse_cap = 0; frame()
script.keys = { 13 }; strings = {}; frame(); frame()
assert(saw("^kept the 2 weakest, silenced 2$"), "Enter applies the slider in weak mode: " .. tostring(saw("kept") or saw("weakest")))
script.keys = { 19 }; strings = {}; frame(); frame()
assert(saw("^saved pk_test_edit3%.ats"), "third save status missing: " .. tostring(saw("saved")))
saved = assert(ats.load(edited_path3))
assert(unchanged(saved, 2, 0.2, 400), "the quietest partial (400 Hz) is untouched in weak mode")
assert(unchanged(saved, 3, 0.5, 800), "the 3rd loudest partial (800 Hz) is untouched in weak mode")
assert(all_zero(saved, 1), "the loudest partial (200 Hz) is silenced in weak mode")
assert(all_zero(saved, 4), "the 2nd loudest partial (1600 Hz) is silenced in weak mode")

print("max-partials knob OK: ranks by total energy, previews live, Enter silences the rest in either direction, Esc and Ctrl+Z both put it back")
