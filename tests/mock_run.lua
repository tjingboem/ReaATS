-- Run: lua5.4 tests/mock_run.lua   (from the ATSEditor folder)
-- Runs ATS_Editor.lua against a fake `gfx` and `reaper` with scripted input, to catch
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
local previews = {}
local destroyed, stops = 0, 0
local scratch = "/tmp/claude-1000/-home-tjingboem/6ca29d3f-340f-46ca-9b11-e579b6c375ee/scratchpad/"
local work = scratch .. "mock_sax.ats"                 -- the viewer edits a COPY, never examples/sax.ats
do
  local src = assert(io.open(root .. "/examples/sax.ats", "rb")); local data = src:read("a"); src:close()
  local dst = assert(io.open(work, "wb")); dst:write(data); dst:close()
  os.remove(scratch .. "mock_sax_edit.ats")
end
reaper = {
  time_precise = function() return os.clock() end,
  ExecProcess = function(cmd, timeout) local ph = io.popen(cmd .. " 2>&1"); local out = ph:read("a"); ph:close(); return out end,
  PCM_Source_CreateFromFile = function(path) return { path = path } end,
  PCM_Source_Destroy = function() destroyed = destroyed + 1 end,
  Xen_StartSourcePreview = function(src) previews[#previews + 1] = src.path; return true end,
  Xen_StopSourcePreview = function() stops = stops + 1 end,
  get_action_context = function() return true, root .. "/ATS_Editor.lua", 0, 0 end,
  GetExtState = function() return work end,
  SetExtState = function() end,
  file_exists = function(p) local f = io.open(p, "rb"); if f then f:close() return true end return false end,
  GetUserFileNameForRead = function() return true, work end,
  defer = function(fn) deferred = fn end,
}
dofile("ATS_Editor.lua")
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
-- moving: Right arrow, then a mouse drag on a selected point
do
  local ats0 = dofile("lib/ats_file.lua")
  script.keys = { 114 }; frame(); script.keys = { 102 }; frame()               -- reload the copy, fit the view
  gfx.mouse_cap = 1; gfx.mouse_x, gfx.mouse_y = 65, 55; frame()                -- select the left part of the plot (t < ~1.2 s)
  gfx.mouse_x, gfx.mouse_y = 600, 600; frame()
  gfx.mouse_cap = 0; frame(); frame()
  gfx.mouse_cap = 0
  script.keys = { 1919379572 }; strings = {}; frame(); frame()                 -- Right
  assert(saw("^move %+0 frames") == nil)
  gfx.mouse_cap = 0
  -- screen position of partial 1 at frame 101, replicating the viewer's fit
  local d0 = ats0.load(work)
  local thr = d0.ampmax * 10 ^ (-80 / 20)
  local fmin, fmax = math.huge, 0
  for p = 1, d0.partials do for f = 1, d0.frames do
    if d0.amp[p][f] > thr and d0.frq[p][f] > 0 then
      fmin = math.min(fmin, d0.frq[p][f]); fmax = math.max(fmax, d0.frq[p][f]) end end end
  local f0, f1 = math.max(10, fmin / 1.4), math.min(40000, fmax * 1.4)
  local px, py, pw, ph = 62, 52, 988, 550
  local tmax = d0.times[d0.frames]
  local function screen(t, fr) return px + t / tmax * pw, py + ph * (1 - (math.log(fr) - math.log(f0)) / (math.log(f1) - math.log(f0))) end
  local x, y = screen(d0.times[101], d0.frq[1][101])
  local frame_px = pw * 0.01 / tmax
  -- the selection is one frame to the right after the Right key, so grab the point there
  x = x + frame_px
  gfx.mouse_cap = 1; gfx.mouse_x, gfx.mouse_y = x, y; frame()
  gfx.mouse_x, gfx.mouse_y = x + 30, y - 20; frame(); frame()
  gfx.mouse_cap = 0; strings = {}; frame(); frame()
  local expected = math.floor(30 / frame_px + 0.5)
  assert(saw("^move %+" .. expected .. " frames"), "drag move status missing, expected +" .. expected .. ": "
         .. table.concat(strings, " / ", 1, math.min(#strings, 30)))
  gfx.mouse_cap = 4; script.keys = { 26 }; strings = {}; frame(); frame()
  assert(saw("^undo move"), "undo of the drag move missing")
  gfx.mouse_cap = 0
  print("move OK: arrow and drag (+" .. expected .. " frames), undo works")
end

-- editing: transpose, delete, undo, redo, save
local ats = dofile("lib/ats_file.lua")
gfx.mouse_cap = 0
gfx.mouse_cap = 1; gfx.mouse_x, gfx.mouse_y = 100, 100; frame()              -- select a big box again (R/O reloaded the file)
gfx.mouse_x, gfx.mouse_y = 900, 560; frame()
gfx.mouse_cap = 0; frame(); frame()
script.keys = { 30064 }; strings = {}; frame(); frame()
assert(saw("^transpose %+1%.00 st"), "transpose status missing")
script.keys = { 6579564 }; strings = {}; frame(); frame()
assert(saw("^delete: "), "delete status missing")
assert(saw(" %*   |"), "modified marker missing")
gfx.mouse_cap = 4
script.keys = { 26 }; strings = {}; frame(); frame()
assert(saw("^undo delete"), "undo status missing")
gfx.mouse_cap = 4
script.keys = { 25 }; strings = {}; frame(); frame()
assert(saw("^redo delete"), "redo status missing")
gfx.mouse_cap = 4
script.keys = { 19 }; strings = {}; frame(); frame()
assert(saw("^saved mock_sax_edit%.ats"), "save status missing; strings: " .. table.concat(strings, " / ", 1, math.min(#strings, 40)))
gfx.mouse_cap = 0
local orig = ats.load(root .. "/examples/sax.ats")
local edited = assert(ats.load(scratch .. "mock_sax_edit.ats"))
local zeros, moved = 0, 0
for p = 1, orig.partials do for f = 1, orig.frames do
  if orig.amp[p][f] > 0 and edited.amp[p][f] == 0 then zeros = zeros + 1 end
end end
assert(zeros > 1000, "deleted points should be silent in the saved file, got " .. zeros)
assert(edited.type == 3 and not edited.has_phase, "edited file should be saved without phase")
print(string.format("edit round trip OK: %d points silenced in the saved file (type %d)", zeros, edited.type))
-- audition: render with the real Csound and 'play' through the mocked preview
do
  local function wav_info(path)
    local f = io.open(path, "rb"); if not f then return nil end
    local size = f:seek("end"); f:close(); return size
  end
  gfx.mouse_cap = 0
  script.keys = { 97 }; strings = {}; frame(); frame()                          -- A
  assert(#previews == 1, "audition did not start a preview; strings: " .. table.concat(strings, " / ", 1, math.min(#strings, 40)))
  local size = wav_info(previews[1])
  assert(size and size > 300000, "rendered WAV missing or too short: " .. tostring(size))
  assert(saw("^auditioning [%d%.]+ s %(sines %+ noise%)"), "status should say sines + noise")
  script.keys = { 112 }; frame()                                                -- P off: noise only
  script.keys = { 97 }; strings = {}; frame(); frame()
  assert(#previews == 2 and saw("%(noise%)"), "noise-only audition expected")
  script.keys = { 112 }; frame(); script.keys = { 110 }; frame()                -- P on, N off: sines only
  script.keys = { 97 }; strings = {}; frame(); frame()
  assert(#previews == 3 and saw("%(sines%)"), "sines-only audition expected")
  script.keys = { 112 }; frame(); script.keys = { 112 }; frame()                -- P off, then on again
  script.keys = { 110 }; frame()                                                -- N on again
  script.keys = { 32 }; strings = {}; frame(); frame()                          -- Space stops
  assert(saw("audition stopped"), "stop status missing")
  assert(destroyed == 0, "preview sources must never be destroyed from the script")
  assert(previews[1] ~= previews[2] and previews[2] ~= previews[3], "every render needs its own WAV name")
  assert(stops >= 1, "an audition during a running preview should stop it first")
  print("audition OK: 3 renders with real Csound (sines+noise, noise, sines); stops=" .. stops .. ", destroyed=" .. destroyed)
  for _, w in ipairs(previews) do os.remove(w) end
  os.remove("/tmp/reaats_audition.ats"); os.remove("/tmp/reaats_audition.csd")
end
-- a plain click on empty space clears the selection
gfx.mouse_cap = 1; gfx.mouse_x, gfx.mouse_y = 500, 400; frame()
gfx.mouse_cap = 0; strings = {}; frame(); frame()
assert(not saw("^selected:"), "plain click should clear the selection")
local line_before = calls.line or 0
script.keys = { 102 }; frame()                                              -- fit -> full re-render
print(string.format("one full render: %d line calls, %d rect calls", (calls.line or 0) - line_before, calls.rect or 0))
-- Esc: clears a selection first, then closes
gfx.mouse_cap = 1; gfx.mouse_x, gfx.mouse_y = 65, 55; frame()                -- whole plot (earlier box was deleted)
gfx.mouse_x, gfx.mouse_y = 1040, 600; frame()
gfx.mouse_cap = 0; frame(); strings = {}; frame()
assert(saw("^selected:"), "selection expected before Esc")
script.keys = { 27 }; frame()
strings = {}; frame()
assert(not saw("^selected:"), "first Esc should clear the selection")
script.keys = { 27 }
local fn = deferred; deferred = nil; fn()
assert(deferred == nil, "second Esc should stop the loop")
print(string.format("mock run OK: %d frames, %.2f s CPU", #steps + 2, os.clock() - t0))
