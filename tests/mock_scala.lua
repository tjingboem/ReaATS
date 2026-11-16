REAATS_TEST_ANALYSIS_LAYOUT = (os.getenv("PWD") or ".") .. "/tests/analysis_layout_test.lua"
REAATS_TEST_LAYOUT = (os.getenv("PWD") or ".") .. "/tests/editor_layout_test.lua"
-- Run: lua5.4 tests/mock_scala.lua   (from the ReaATS folder)
-- SCALA mode (16 Nov 2026): the button, the Scala file, the root, the faint lines, a portion with its red envelope, the handle (the offset in cents), the hover of the root,
-- Enter (one undo step), Esc. Hand-built fixture: p1 200 Hz (the root), p2 about 430 Hz with a wobble of 1 %, p3 900 Hz (only to give the picture its range).
local root = os.getenv("PWD")
local scratch = "/tmp/claude-1000/-home-tjingboem/6ca29d3f-340f-46ca-9b11-e579b6c375ee/scratchpad/"
local work = scratch .. "sc_test.ats"
local scl = scratch .. "st12.scl"
for _, n in ipairs({ "sc_test_edit.ats", "sc_test_edit2.ats", "sc_test_edit3.ats", "sc_test_edit4.ats" }) do os.remove(scratch .. n) end
local fh = io.open(scl, "w")
fh:write("! st12.scl\n!\nTest scale, 12 equal steps\n 12\n!\n")
for k = 1, 11 do fh:write(string.format(" %d.0\n", k * 100)) end
fh:write(" 2/1\n"); fh:close()

local ats = dofile("lib/ats_file.lua")
local NF, HOP = 50, 0.01
local d = { sr = 44100, frame_size = 441, window_size = 1764, partials = 3, frames = NF, dur = NF * HOP,
            has_phase = false, has_noise = false, amp = {}, frq = {}, times = {} }
for f = 1, NF do d.times[f] = (f - 1) * HOP end
for p = 1, 3 do d.amp[p], d.frq[p] = {}, {} end
for f = 1, NF do
  local wob = (f % 2 == 0) and 1 or -1
  d.amp[1][f], d.frq[1][f] = 0.5, 200 * (1 + 0.01 * wob)
  d.amp[2][f], d.frq[2][f] = 0.4, 430 * (1 + 0.01 * wob)
  d.amp[3][f], d.frq[3][f] = 0.3, 900
end
assert(ats.save(work, d))

local strings, lines = {}, {}
gfx = { w = 1100, h = 640, mouse_x = 0, mouse_y = 0, mouse_cap = 0, mouse_wheel = 0, x = 0, y = 0, a = 1, dest = -1 }
for _, n in ipairs({ "set", "rect", "circle", "setimgdim", "setfont", "update", "init", "blit" }) do gfx[n] = function() return 0 end end
gfx.line = function(x1, y1, x2, y2) lines[#lines + 1] = { x1, y1, x2, y2 } end
gfx.drawstr = function(s) strings[#strings + 1] = s end
gfx.measurestr = function(s) return #s * 7, 14 end
local script = { keys = {} }
gfx.getchar = function() return table.remove(script.keys, 1) or 0 end
local deferred
reaper = {
  time_precise = function() return os.clock() end,
  ExecProcess = function(cmd) local ph = io.popen(cmd .. " 2>&1"); local out = ph:read("a"); ph:close(); return out end,
  get_action_context = function() return true, root .. "/ATS_Editor.lua", 0, 0 end,
  GetExtState = function(_, key) return (key == "last_file") and work or "" end,
  SetExtState = function() end,
  ShowConsoleMsg = function() end,
  MB = function() return 6 end,
  JS_Dialog_BrowseForSaveFile = function() return 0, "" end,
  GetUserInputs = function() return false, "" end,
  file_exists = function(p) local f = io.open(p, "rb"); if f then f:close() return true end return false end,
  GetUserFileNameForRead = function(_, _, ext) if ext == "scl" then return true, scl end return true, work end,
  defer = function(fn) deferred = fn end,
}
dofile("ATS_Editor.lua")
script.keys = { 111 }; do local f = deferred; deferred = nil; f() end

local function frame(setup)
  if setup then setup() end
  local fn = deferred; deferred = nil
  assert(fn, "editor stopped unexpectedly")
  fn()
end
local function saw(pattern) for _, s in ipairs(strings) do if s:find(pattern) then return s end end return nil end
local px, py, pw, ph = 62, 70, 988, 516
local F0, F1 = 200 * 0.99 / 1.4, 900 * 1.4
local function y_of(freq) return py + ph - math.log(freq / F0) / math.log(F1 / F0) * ph end
local function x_of(t) return px + t / ((NF - 1) * HOP) * pw end
local function click(x, y) gfx.mouse_cap = 1; gfx.mouse_x, gfx.mouse_y = x, y; frame(); gfx.mouse_cap = 0; frame(); frame() end
local function drag(x0, y0, x1, y1)
  gfx.mouse_cap = 1; gfx.mouse_x, gfx.mouse_y = x0, y0; frame()
  gfx.mouse_x, gfx.mouse_y = (x0 + x1) / 2, (y0 + y1) / 2; frame()
  gfx.mouse_x, gfx.mouse_y = x1, y1; frame()
  gfx.mouse_cap = 0; frame(); frame()
end
local function key(k) script.keys = { k }; strings = {}; frame(); frame() end
local function save_and_load()
  script.keys = { 19 }; strings = {}; frame(); frame()
  local name
  for _, n in ipairs({ "sc_test_edit.ats", "sc_test_edit2.ats", "sc_test_edit3.ats", "sc_test_edit4.ats" }) do
    local f = io.open(scratch .. n, "rb"); if f then f:close(); name = scratch .. n end
  end
  return assert(ats.load(name)), name
end
local function cents(a, b) return 1200 * math.log(a / b) / math.log(2) end
local function spread(a) local lo, hi = math.huge, -math.huge; for f = 1, NF do lo, hi = math.min(lo, a[f]), math.max(hi, a[f]) end return cents(hi, lo) end

-- the button starts the mode (the Scala file is chosen), it asks for the root
frame(); strings = {}; frame()
assert(saw("^SCALA$"), "the button is drawn: " .. tostring(saw("SCALA")))
click(731, 44)
strings = {}; frame()
assert(saw("SCALA: pick root"), "the mode waits for the root: " .. tostring(saw("SCALA")))

-- the root: a few frames of the 200 Hz partial. It is taken as the root and the mode asks for partials; the selection is cleared
drag(px, y_of(200 * 1.05), x_of(0.035), y_of(200 / 1.05))
strings = {}; frame()
assert(saw("SCALA: select partials"), "after the root: " .. tostring(saw("SCALA") or saw("root") or saw("one partial")))
assert(not saw("^selected:"), "the root selection is cleared")

-- the faint lines run from the root's time to the right edge, one per step of the scale: the line of 1 step up (212 Hz) starts at the root's time
lines = {}; frame()
local rx = x_of(0.015)
local function hline(freq)
  for _, l in ipairs(lines) do if math.abs(l[2] - l[4]) < 0.01 and math.abs(l[2] - y_of(freq)) < 1.5 and l[3] > px + pw - 5 then return l end end
end
for k = -12, 24 do
  local f = 200 * 2 ^ (k / 12)
  if f > F0 * 1.05 and f < F1 / 1.05 then
    local l = hline(f)
    assert(l, "a faint line at " .. k .. " steps (" .. string.format("%.1f", f) .. " Hz)")
    assert(math.abs(l[1] - rx) < 1.5, "the line starts at the root's time: " .. l[1] .. " vs " .. rx)
  end
end

-- hover on the root: only the root tells about the Scala file; away from it nothing
gfx.mouse_x, gfx.mouse_y = rx, y_of(200); strings = {}; frame()
assert(saw("st12.scl") and saw("Test scale, 12 equal steps") and saw("12 notes, period 2/1") and saw("root 20"), "hover on the root: " .. tostring(saw("st12") or saw("root")))
gfx.mouse_x, gfx.mouse_y = x_of(0.3), y_of(500); strings = {}; frame()
assert(not saw("st12.scl"), "nothing away from the root")

-- the portion: p2 whole. Enter: every point goes to the nearest line (1300 cents above the root: 424.6 Hz), the wobble is gone
drag(px, y_of(430 * 1.05), px + pw + 30, y_of(430 / 1.05))
strings = {}; frame()
key(13)
assert(saw("snapped 50 points"), "Enter snaps: " .. tostring(saw("snapped") or saw("select") or saw("nothing")))
local s1 = save_and_load()
local want = 200 * 2 ^ (13 / 12)
for f = 1, NF do assert(math.abs(s1.frq[2][f] - want) < 0.05, "p2 on the line at frame " .. f .. ": " .. s1.frq[2][f] .. " vs " .. want) end
assert(s1.amp[2][7] == d.amp[2][7], "the level stays")
assert(s1.frq[1][8] == d.frq[1][8] or math.abs(s1.frq[1][8] - d.frq[1][8]) < 0.1, "p1 was not selected: it stays")
assert(s1.frq[3][8] == 900, "p3 stays")
key(26)                                                                                 -- one undo step takes it all back
local s1b = save_and_load()
assert(math.abs(s1b.frq[2][8] - d.frq[2][8]) < 0.05, "undo: the wobble is back")

-- the red envelope: the end points are dragged down to 50 %: each point goes half way, the wobble is half as big
click(x_of(0.3), y_of(700))                                                              -- (a click on empty space clears the selection)
drag(px, y_of(430 * 1.05), px + pw + 30, y_of(430 / 1.05))
local f0sel = 430 * 0.99
local ybot = y_of(f0sel) + 6
local top = ybot - 32
drag(px + 0.5, top, px + 0.5, top + 16)                                                  -- the first end point down to 50 %
drag(x_of(0.49) + 0.5, top, x_of(0.49) + 0.5, top + 16)                                  -- the last one as well
strings = {}; frame()
assert(saw("^50%%$"), "the envelope shows its points: " .. tostring(saw("%%%%")))
key(13)
local s2 = save_and_load()
local before, after = spread(d.frq[2]), spread(s2.frq[2])
assert(after < before * 0.6 and after > before * 0.4, string.format("half intensity: the wobble is half (%.1f -> %.1f cents)", before, after))
key(26)

-- the handle moves the whole grid: up 20 px = a number of cents, written beside it
click(x_of(0.3), y_of(700))
local cpp = 1200 * math.log(F1 / F0) / math.log(2) / ph
local hx, hy = px + pw - 12, y_of(200)
drag(hx, hy, hx, hy - 20)
strings = {}; frame()
local want_label = string.format("%+d cents", math.floor(20 * cpp + 0.5))
assert(saw("^" .. want_label:gsub("%+", "%%+") .. "$"), "the offset is written beside the handle (" .. want_label .. "): " .. tostring(saw("cents")))
lines = {}; frame()
assert(hline(200 * 2 ^ ((20 * cpp) / 1200)), "the whole grid moved")
-- a right-click on the handle puts it back
gfx.mouse_cap = 2; gfx.mouse_x, gfx.mouse_y = hx, hy - 20; frame(); gfx.mouse_cap = 0; frame(); frame()
strings = {}; frame()
assert(saw("^%+0 cents$"), "right-click: back at 0: " .. tostring(saw("cents")))

-- Esc leaves the mode: the lines and the text go
key(27)
strings = {}; lines = {}; frame()
assert(not saw("SCALA:"), "Esc leaves the mode")
assert(not hline(212), "no faint lines any more")
-- the button again: a new start (the file is asked again), the same button leaves
click(731, 44)
strings = {}; frame()
assert(saw("SCALA: pick root"), "the button starts again")
click(731, 44)
strings = {}; frame()
assert(not saw("SCALA:"), "the same button leaves")

print("SCALA mode OK: button, root, faint lines from the root, hover on the root only, portion + Enter snaps (one undo step), red envelope intensity, the handle and its cents, Esc / the button leave")
