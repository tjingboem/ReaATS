-- Run: lua5.4 tests/mock_run.lua   (from the ATSEditor folder)
-- Runs ATS_Viewer.lua against a fake `gfx` and `reaper` with scripted input, to catch
-- runtime errors (nothing is drawn). Also counts the draw calls of one cache render.
local root = os.getenv("PWD")
local calls = {}
local function count(name) return function(...) calls[name] = (calls[name] or 0) + 1; return 0 end end
gfx = { w = 1100, h = 640, mouse_x = 0, mouse_y = 0, mouse_cap = 0, mouse_wheel = 0, x = 0, y = 0, a = 1, dest = -1 }
for _, n in ipairs({ "set", "rect", "line", "blit", "setimgdim", "setfont", "update", "init" }) do gfx[n] = count(n) end
local strings = {}
gfx.drawstr = function(s) strings[#strings + 1] = s end
gfx.measurestr = function(s) return #s * 7, 14 end
local script = { keys = {}, frame = 0 }
gfx.getchar = function() return table.remove(script.keys, 1) or 0 end
local deferred
reaper = {
  get_action_context = function() return true, root .. "/ATS_Viewer.lua", 0, 0 end,
  GetExtState = function() return root .. "/examples/sax.ats" end,
  SetExtState = function() end,
  file_exists = function(p) local f = io.open(p, "rb"); if f then f:close() return true end return false end,
  GetUserFileNameForRead = function() return true, root .. "/examples/sax.ats" end,
  defer = function(fn) deferred = fn end,
}
dofile("ATS_Viewer.lua")
local function frame(setup)
  if setup then setup() end
  local fn = deferred; deferred = nil
  assert(fn, "viewer stopped unexpectedly")
  fn()
end
local steps = {
  function() gfx.mouse_x, gfx.mouse_y = 400, 300 end,                       -- hover
  function() gfx.mouse_x, gfx.mouse_y = 300, 200 end,                       -- hover elsewhere
  function() gfx.mouse_wheel = 120 end,                                     -- zoom time in
  function() gfx.mouse_wheel = -120 end,                                    -- zoom time out
  function() gfx.mouse_wheel = 120; gfx.mouse_cap = 4 end,                  -- ctrl: zoom freq
  function() gfx.mouse_wheel = 120; gfx.mouse_cap = 8 end,                  -- shift: scroll
  function() gfx.mouse_cap = 1; gfx.mouse_x, gfx.mouse_y = 400, 300 end,    -- press
  function() gfx.mouse_x, gfx.mouse_y = 430, 320 end,                       -- drag
  function() gfx.mouse_cap = 0 end,                                         -- release (box select)
  function() strings = {} end,
  function() gfx.mouse_cap = 1; gfx.mouse_x, gfx.mouse_y = 100, 100 end,    -- big box
  function() gfx.mouse_x, gfx.mouse_y = 900, 560 end,
  function() gfx.mouse_cap = 0 end,
  function() strings = {} end,
  function() gfx.mouse_cap = 1 + 8; gfx.mouse_x, gfx.mouse_y = 120, 120 end, -- Shift: add a second box
  function() gfx.mouse_x, gfx.mouse_y = 300, 300 end,
  function() gfx.mouse_cap = 0 end,
  function() gfx.mouse_cap = 2; gfx.mouse_x, gfx.mouse_y = 400, 300 end,    -- right drag pans
  function() gfx.mouse_x, gfx.mouse_y = 450, 330 end,
  function() gfx.mouse_cap = 0 end,
  function() strings = {} end,
  function() script.keys = { 110 } end,                                     -- N noise off
  function() script.keys = { 112 } end,                                     -- P partials off
  function() script.keys = { 112 } end,                                     -- P on
  function() script.keys = { 110 } end,                                     -- N on
  function() script.keys = { 102 } end,                                     -- F fit
  function() script.keys = { 114 } end,                                     -- R reload
  function() script.keys = { 111 } end,                                     -- O open (mock dialog)
  function() gfx.mouse_cap = 0; gfx.mouse_x, gfx.mouse_y = 400, 300 end,
  function() gfx.mouse_x, gfx.mouse_y, gfx.mouse_cap = gfx.w - 120, 16, 1 end,   -- click the Noise checkbox
  function() gfx.mouse_cap = 0 end,
  function() gfx.mouse_x, gfx.mouse_y, gfx.mouse_cap = gfx.w - 120, 16, 1 end,   -- and again
  function() gfx.mouse_cap = 0 end,
  function() for i = 1, 12 do gfx.mouse_wheel = 120; gfx.mouse_cap = 4; gfx.mouse_x, gfx.mouse_y = 400, 300; end end, -- zoom frequency far in
  function() gfx.mouse_wheel = 120; gfx.mouse_cap = 4 end,
  function() gfx.mouse_wheel = 120; gfx.mouse_cap = 4 end,
  function() gfx.mouse_cap = 0; script.keys = { 102 } end,
  function() gfx.w, gfx.h = 700, 420 end,                                   -- resize
  function() gfx.w, gfx.h = 1100, 640 end,
}
local function saw(pattern)
  for _, s in ipairs(strings) do if s:find(pattern) then return s end end
end
local t0 = os.clock()
for i, s in ipairs(steps) do frame(s) end
frame()                                                                     -- one more frame so the summary text is drawn
local summary = saw("^selected:")
assert(summary, "no selection summary after box selects")
print(summary)
-- a plain click on empty space clears the selection
gfx.mouse_cap = 1; gfx.mouse_x, gfx.mouse_y = 500, 400; frame()
gfx.mouse_cap = 0; strings = {}; frame(); frame()
assert(not saw("^selected:"), "plain click should clear the selection")
local line_before = calls.line or 0
script.keys = { 102 }; frame()                                              -- fit -> full re-render
print(string.format("one full render: %d line calls, %d rect calls", (calls.line or 0) - line_before, calls.rect or 0))
-- Esc: clears a selection first, then closes
gfx.mouse_cap = 1; gfx.mouse_x, gfx.mouse_y = 100, 100; frame()
gfx.mouse_x, gfx.mouse_y = 900, 560; frame()
gfx.mouse_cap = 0; frame(); strings = {}; frame()
assert(saw("^selected:"), "selection expected before Esc")
script.keys = { 27 }; frame()
strings = {}; frame()
assert(not saw("^selected:"), "first Esc should clear the selection")
script.keys = { 27 }
local fn = deferred; deferred = nil; fn()
assert(deferred == nil, "second Esc should stop the loop")
print(string.format("mock run OK: %d frames, %.2f s CPU", #steps + 2, os.clock() - t0))
