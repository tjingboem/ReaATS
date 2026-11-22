REAATS_TEST_ANALYSIS_LAYOUT = (os.getenv("PWD") or ".") .. "/tests/analysis_layout_test.lua"       -- (the Analysis page layout the clicks are made for)
REAATS_TEST_LAYOUT = (os.getenv("PWD") or ".") .. "/tests/editor_layout_test.lua"            -- the editor layout the clicks below are made for
-- Run: lua5.4 tests/mock_select_tools.lua   (from the ReaATS folder)
-- S (smooth), K (short partials panel) and H (harmonics of the partial under the pointer): hand-built fixture;
-- opens REAPER's own text-input dialog (positive: keep that many loudest, negative: that many weakest) and applies right away, one
-- undo step. Runs ReaATS.lua against a fake gfx/reaper, on a hand-built, single-channel fixture of 4 separate, flat partials
-- with known, distinct energies, so the ranking is fully predictable.
local root = os.getenv("PWD")
local scratch = "/tmp/claude-1000/-home-tjingboem/6ca29d3f-340f-46ca-9b11-e579b6c375ee/scratchpad/"
local work = scratch .. "st_test.ats"
local edited_path = scratch .. "st_test_edit.ats"
local edited_path2 = scratch .. "st_test_edit2.ats"
local edited_path3 = scratch .. "st_test_edit3.ats"
local edited_path4 = scratch .. "st_test_edit4.ats"
os.remove(edited_path)
os.remove(edited_path2)
os.remove(edited_path3)
os.remove(edited_path4)

local ats = dofile("lib/ats_file.lua")
local NF, HOP = 50, 0.01
-- p1 200 Hz with a wobble in level and pitch (alternating), p2 400 Hz and p3 600 Hz (its 2nd and 3rd harmonics), p4 700 Hz (not a harmonic of 200 Hz),
-- p5 900 Hz sounds only in frames 20-23 (4 frames = 40 ms: a short partial)
local d = { sr = 44100, frame_size = 441, window_size = 1764, partials = 5, frames = NF, dur = NF * HOP,
            has_phase = false, has_noise = false, amp = {}, frq = {}, times = {} }
for f = 1, NF do d.times[f] = (f - 1) * HOP end
for p = 1, 5 do d.amp[p], d.frq[p] = {}, {} end
for f = 1, NF do
  local wob = (f % 2 == 0) and 1 or -1
  d.amp[1][f], d.frq[1][f] = 0.5 * (1 + 0.3 * wob), 200 * (1 + 0.01 * wob)
  d.amp[2][f], d.frq[2][f] = 0.4, 400 * (1 + 0.01 * wob)
  d.amp[3][f], d.frq[3][f] = 0.3, 600 * (1 + 0.01 * wob)
  d.amp[4][f], d.frq[4][f] = 0.3, 700
  if f >= 20 and f <= 23 then d.amp[5][f], d.frq[5][f] = 0.3, 900 else d.amp[5][f], d.frq[5][f] = 0, 0 end
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
  get_action_context = function() return true, root .. "/ReaATS.lua", 0, 0 end,
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
dofile("ReaATS.lua")
script.keys = { 111 }; do local f = deferred; deferred = nil; f() end          -- O: open the fixture

local function frame(setup)
  if setup then setup() end
  local fn = deferred; deferred = nil
  assert(fn, "viewer stopped unexpectedly")
  fn()
end
local function saw(pattern) for _, s in ipairs(strings) do if s:find(pattern) then return s end end return nil end
local px, py, pw, ph = 62, 70, 988, 516
local function y_of(freq) local f0, f1 = 200 * 0.99 / 1.4, 900 * 1.4; return py + ph - math.log(freq / f0) / math.log(f1 / f0) * ph end
local function save_and_load()
  script.keys = { 19 }; strings = {}; frame(); frame()                                    -- Ctrl+S: saved as st_test_edit.ats (or the next free name)
  local name
  for _, p in ipairs({ edited_path, edited_path2, edited_path3, edited_path4 }) do
    local f = io.open(p, "rb"); if f then f:close(); name = p end
  end
  return assert(ats.load(name)), name
end
local function select_all() script.keys = { 1 }; strings = {}; frame(); frame() end
local function range(a) local lo, hi = math.huge, -math.huge; for f = 1, NF do if a[f] > 0 then lo, hi = math.min(lo, a[f]), math.max(hi, a[f]) end end return lo, hi end

-- S: smoothing. Everything selected; each press brings the wobble of p1 (level and pitch) down a little; the other partials, which wobble in pitch (p2, p3), follow
select_all()
assert(saw("^selected: %d+ points"), "all selected: " .. tostring(saw("selected")))
local a_lo0, a_hi0 = range(d.amp[1])
script.keys = { 115 }; strings = {}; frame(); frame()                                       -- S once
for i = 1, 5 do script.keys = { 115 }; frame(); frame() end                                  -- and five times more
local s1 = save_and_load()
local a_lo1, a_hi1 = range(s1.amp[1])
local f_lo1, f_hi1 = range(s1.frq[1])
assert((a_hi1 - a_lo1) < (a_hi0 - a_lo0) * 0.5, "smoothing six times: the wobble in the level is much smaller: " .. (a_hi0 - a_lo0) .. " -> " .. (a_hi1 - a_lo1))
assert((f_hi1 - f_lo1) < 200 * 0.02 * 0.5, "and the wobble in the pitch too: " .. (f_hi1 - f_lo1))
assert(s1.frq[4][10] == 700 and s1.amp[4][10] == 0.3, "a flat partial stays as it was")
script.keys = { 26, 26, 26, 26, 26, 26 }; for i = 1, 6 do frame() end                         -- (undo the six presses)

-- K: remove the partials that are shorter than X ms: p5 (4 frames = 40 ms) goes at 60 ms, the long ones stay
select_all()
script.keys = { 107 }; strings = {}; frame(); frame()
assert(saw("Short partials") and saw("under 0 ms"), "K opens the panel: " .. tostring(saw("Short") or saw("selected")))
for i = 1, 6 do script.keys = { 1919379572 }; frame() end                                    -- Right x6: +60 ms
strings = {}; frame()
assert(saw("under 60 ms") and saw("silences 1 of 5 partials"), "the panel counts what 60 ms would silence: " .. tostring(saw("silences") or saw("nothing") or saw("under")))
script.keys = { 13 }; strings = {}; frame(); frame()
assert(saw("silenced 1 partial shorter than 60 ms"), "Enter applies: " .. tostring(saw("silenced") or saw("short")))
local s2 = save_and_load()
local zero5 = true; for f = 1, NF do if s2.amp[5][f] ~= 0 then zero5 = false end end
assert(zero5, "the short partial is silenced")
assert(s2.amp[1][10] > 0 and s2.amp[2][10] > 0 and s2.amp[4][10] > 0, "the long ones stay")
script.keys = { 26 }; frame()

-- H: the harmonics of the partial under the pointer: 200 Hz -> 400 Hz and 600 Hz (700 Hz and 900 Hz are not on the series)
script.keys = { 27 }; frame()                                                                -- Esc: clear the selection
gfx.mouse_x, gfx.mouse_y = px + pw / 2, y_of(200)
script.keys = { 104 }; strings = {}; frame(); frame()
assert(saw("^selected the harmonics of %d+ Hz: 150 points in 3 partials"), "H selects 200, 400 and 600 Hz: " .. tostring(saw("selected") or saw("no partial") or saw("harmonics")))
-- H inside a selection: only its stretch of time and its range of frequencies is searched (the fundamental itself may lie outside it)
local function click_cap(x, y, cap) gfx.mouse_cap = cap; gfx.mouse_x, gfx.mouse_y = x, y; frame(); gfx.mouse_cap = 0; frame() end
script.keys = { 27 }; frame()
click_cap(px + pw / 2, y_of(400), 1 + 4)                                                      -- Ctrl+click on the 400 Hz line
click_cap(px + pw / 2, y_of(600), 1 + 8)                                                      -- Shift+click on the 600 Hz line: both selected
gfx.mouse_x, gfx.mouse_y = px + pw / 2, y_of(200)                                              -- the pointer on the 200 Hz line, outside the selection
script.keys = { 104 }; strings = {}; frame(); frame()
assert(saw("^selected the harmonics of %d+ Hz: 100 points in 2 partials"), "H inside a selection: only 400 and 600 Hz (the 200 Hz fundamental is outside it): " .. tostring(saw("selected") or saw("no partial") or saw("harmonics")))
-- T: transpose and level by typed values: +2 semitones and -6 dB for the whole selection
script.keys = { 27 }; frame()
select_all()
script.keys = { 116 }; strings = {}; frame(); frame()
assert(saw("Transpose and level") and saw("semitones") and saw("cents") and saw("level in dB"), "T opens the panel: " .. tostring(saw("selected") or saw("Transpose")))
for _, c in ipairs({ 50 }) do script.keys = { c }; frame() end                                   -- 2   (the first key replaces the 0)
script.keys = { 9 }; frame()                                                                     -- Tab: the cents field
for _, c in ipairs({ 51, 48 }) do script.keys = { c }; frame() end                               -- 30 cents on top of the 2 semitones
script.keys = { 9 }; frame()                                                                     -- Tab: the level field
for _, c in ipairs({ 45, 54 }) do script.keys = { c }; frame() end                               -- -6
script.keys = { 13 }; strings = {}; frame(); frame()
assert(saw("transposed %+2%.30 semitones, level %-6%.0 dB"), "Enter applies: " .. tostring(saw("transposed") or saw("nothing")))
local s3 = save_and_load()
assert(math.abs(s3.frq[4][10] - 700 * 2 ^ (2.30 / 12)) < 1e-6, "the pitch is 2 semitones and 30 cents up: " .. s3.frq[4][10])
assert(math.abs(s3.amp[4][10] - 0.3 * 10 ^ (-6 / 20)) < 1e-9, "the level is 6 dB down: " .. s3.amp[4][10])
script.keys = { 26 }; frame()
print("selection tools OK: S smooths the selection in small steps, K removes the partials shorter than X ms (a panel), H selects the harmonic series of the partial under the pointer")
os.remove(work); os.remove(edited_path); os.remove(edited_path2); os.remove(edited_path3); os.remove(edited_path4)
