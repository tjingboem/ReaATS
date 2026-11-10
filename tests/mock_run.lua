no_py_synth = false
-- Run: lua5.4 tests/mock_run.lua   (from the ATSEditor folder)
-- Runs ATS_Editor.lua against a fake `gfx` and `reaper` with scripted input, to catch
-- runtime errors (nothing is drawn). Also counts the draw calls of one cache render.
local root = os.getenv("PWD")
local calls = {}
local function count(name) return function(...) calls[name] = (calls[name] or 0) + 1; return 0 end end
gfx = { w = 1100, h = 640, mouse_x = 0, mouse_y = 0, mouse_cap = 0, mouse_wheel = 0, x = 0, y = 0, a = 1, dest = -1 }
for _, n in ipairs({ "set", "rect", "line", "circle", "blit", "setimgdim", "setfont", "update", "init" }) do gfx[n] = count(n) end
local strings = {}
gfx.drawstr = function(s) strings[#strings + 1] = s end
gfx.measurestr = function(s) return #s * 7, 14 end
local script = { keys = {}, frame = 0 }
gfx.getchar = function() return table.remove(script.keys, 1) or 0 end
local deferred
local project, projext = { tracks = {} }, {}
local previews = {}
local clock_skew = 0
local destroyed, stops = 0, 0
local save_rv, save_choice, mb_calls, mb_answer = 1, nil, 0, 6
local scratch = "/tmp/claude-1000/-home-tjingboem/6ca29d3f-340f-46ca-9b11-e579b6c375ee/scratchpad/"
local work = scratch .. "mock_sax.ats"                 -- the viewer edits a COPY, never examples/sax.ats
do
  local src = assert(io.open(root .. "/examples/sax.ats", "rb")); local data = src:read("a"); src:close()
  local dst = assert(io.open(work, "wb")); dst:write(data); dst:close()
  os.remove(scratch .. "mock_sax_edit.ats")
end
reaper = {
  time_precise = function() return os.clock() + clock_skew end,
  ExecProcess = function(cmd, timeout) local ph = io.popen(cmd .. " 2>&1"); local out = ph:read("a"); ph:close(); return out end,
  PCM_Source_CreateFromFile = function(path) return { path = path } end,
  PCM_Source_Destroy = function() destroyed = destroyed + 1 end,
  Xen_StartSourcePreview = function(src) previews[#previews + 1] = src.path; return true end,
  Xen_StopSourcePreview = function() stops = stops + 1 end,
  get_action_context = function() return true, root .. "/ATS_Editor.lua", 0, 0 end,
  GetExtState = function(sec, key) return (key == "last_file") and work or "" end,
  SetExtState = function() end,
  ShowConsoleMsg = function() end,
  JS_Dialog_BrowseForSaveFile = function() return save_rv, save_choice end,
  GetUserInputs = function() return save_rv == 1, save_choice end,
  MB = function() mb_calls = mb_calls + 1; return mb_answer end,
  -- a tiny fake project for PRINT
  Undo_BeginBlock = function() end, Undo_EndBlock = function() end, UpdateArrange = function() end,
  CountTracks = function() return #project.tracks end,
  InsertTrackAtIndex = function(i) table.insert(project.tracks, i + 1, { items = {}, selected = false }) end,
  GetTrack = function(_, i) return project.tracks[i + 1] end,
  GetSelectedTrack = function() for _, t in ipairs(project.tracks) do if t.selected then return t end end end,
  SetOnlyTrackSelected = function(tr) for _, t in ipairs(project.tracks) do t.selected = (t == tr) end end,
  GetSetMediaTrackInfo_String = function(tr, what, val, set) if set then tr.name = val end return true, tr.name end,
  InsertMedia = function(path) local t = reaper.GetSelectedTrack(); t.items[#t.items + 1] = { src = path, guid = "{GUID-" .. (#t.items + 1) .. "}" }; return true end,
  CountTrackMediaItems = function(tr) return #tr.items end,
  GetTrackMediaItem = function(tr, i) return tr.items[i + 1] end,
  GetActiveTake = function(it) return it end,
  GetMediaItemTake_Source = function(take) return take end,
  GetMediaSourceFileName = function(src) return src.src end,
  GetSetMediaItemInfo_String = function(it, what, val, set) return true, it.guid end,
  GetSetMediaItemTakeInfo_String = function(take, what, val, set) if set then take.name = val end return true, take.name end,
  SetProjExtState = function(_, sec, key, val) projext[sec .. "|" .. key] = val; return 1 end,
  GetProjExtState = function(_, sec, key) return 1, projext[sec .. "|" .. key] or "" end,
  file_exists = function(p)
    if no_py_synth and p:find("reaats_synth.py", 1, true) then return false end         -- (tests of the built-in synthesis)
    local f = io.open(p, "rb"); if f then f:close() return true end return false end,
  GetUserFileNameForRead = function() return true, work end,
  defer = function(fn) deferred = fn end,
}
dofile("ATS_Editor.lua")
script.keys = { 111 }; do local f = deferred; deferred = nil; f() end            -- the window starts empty: O opens the file
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
-- moving: Right arrow, then a mouse drag on a selected point (free, with Ctrl = one axis only, with Shift = fine)
do
  local ats0 = dofile("lib/ats_file.lua")
  local d0 = ats0.load(work)
  local thr = d0.ampmax * 10 ^ (-80 / 20)
  local fmin, fmax = math.huge, 0
  for p = 1, d0.partials do for f = 1, d0.frames do
    if d0.amp[p][f] > thr and d0.frq[p][f] > 0 then
      fmin = math.min(fmin, d0.frq[p][f]); fmax = math.max(fmax, d0.frq[p][f]) end end end
  local f0, f1 = math.max(10, fmin / 1.4), math.min(40000, fmax * 1.4)
  local px, py, pw, ph = 62, 70, 988, 516
  local tmax = d0.times[d0.frames]
  local function screen(t, fr) return px + t / tmax * pw, py + ph * (1 - (math.log(fr) - math.log(f0)) / (math.log(f1) - math.log(f0))) end
  local frame_px = pw * 0.01 / tmax
  -- starts from a freshly loaded copy: select the left part, one frame to the right (Right key), drag the point at partial 1, frame 101
  local function drag(extra_cap, dx, dy)
    script.keys = { 114 }; frame(); script.keys = { 102 }; frame()               -- reload the copy, fit the view
    gfx.mouse_cap = 1; gfx.mouse_x, gfx.mouse_y = 65, 75; frame()                -- select the left part of the plot (t < ~1.2 s)
    gfx.mouse_x, gfx.mouse_y = 600, 600; frame()
    gfx.mouse_cap = 0; frame(); frame()
    gfx.mouse_cap = 0
    script.keys = { 1919379572 }; strings = {}; frame(); frame()                 -- Right
    local x, y = screen(d0.times[101], d0.frq[1][101])
    x = x + frame_px                                                             -- (the selection is one frame to the right)
    gfx.mouse_cap = 1 + extra_cap; gfx.mouse_x, gfx.mouse_y = x, y; frame()
    gfx.mouse_x, gfx.mouse_y = x + dx / 2, y + dy / 2; frame()
    gfx.mouse_x, gfx.mouse_y = x + dx, y + dy; frame(); frame()
    strings = {}; frame()                                                        -- (still dragging: the crosshair says what it will do)
    drag_label = saw("^[%+%-]%d+ frames   [%+%-][%d%.]+ st[^\n]*")
    gfx.mouse_cap = 0; strings = {}; frame(); frame()
  end
  gfx.mouse_cap = 0
  drag(0, 30, -20)
  local expected = math.floor(30 / frame_px + 0.5)
  assert(saw("^move %+" .. expected .. " frames"), "drag move status missing, expected +" .. expected .. ": "
         .. table.concat(strings, " / ", 1, math.min(#strings, 30)))
  assert(drag_label, "the crosshair shows the move while dragging")
  local free_st = tonumber(saw("^move [%+%-]%d+ frames, ([%+%-][%d%.]+) st"):match("frames, ([%+%-][%d%.]+) st"))
  assert(free_st and free_st > 0.5, "a free drag also changes the frequency: " .. tostring(free_st))
  gfx.mouse_cap = 4; script.keys = { 26 }; strings = {}; frame(); frame()
  assert(saw("^undo move"), "undo of the drag move missing")
  gfx.mouse_cap = 0
  -- Ctrl: one axis only (the one that moves most): time only, the frequency stays
  drag(4, 30, -20)
  assert(drag_label and drag_label:find("%(time only%)"), "the crosshair says which axis Ctrl keeps: " .. tostring(drag_label))
  assert(saw("^move %+" .. expected .. " frames, %+0%.00 st"), "Ctrl keeps the frequency: " .. tostring(saw("^move") or "(no move)"))
  gfx.mouse_cap = 4; script.keys = { 26 }; frame(); frame(); gfx.mouse_cap = 0
  drag(4, 6, -60)
  assert(saw("^move %+0 frames, %+[%d%.]+ st"), "Ctrl keeps the time when the drag is mostly vertical: " .. tostring(saw("^move") or "(no move)"))
  gfx.mouse_cap = 4; script.keys = { 26 }; frame(); frame(); gfx.mouse_cap = 0
  -- Shift: fine, a fifth of the mouse movement
  drag(8, 30, -20)
  local fine = math.floor(30 * 0.2 / frame_px + 0.5)
  assert(saw("^move %+" .. fine .. " frames"), "Shift moves a fifth as far: expected +" .. fine .. ": " .. tostring(saw("^move") or "(no move)"))
  local fine_st = tonumber(saw("^move [%+%-]%d+ frames, ([%+%-][%d%.]+) st"):match("frames, ([%+%-][%d%.]+) st"))
  assert(fine_st > 0 and math.abs(fine_st / free_st - 0.2) < 0.06, "and a fifth as far in frequency: " .. fine_st .. " against " .. free_st)
  gfx.mouse_cap = 4; script.keys = { 26 }; frame(); frame(); gfx.mouse_cap = 0
  print("move OK: arrow and drag (+" .. expected .. " frames), Ctrl locks the axis, Shift is fine, undo works")
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
assert(edited.type == 4 and edited.has_phase, "edited file should be saved with phase (type 4)")
print(string.format("edit round trip OK: %d points silenced in the saved file (type %d)", zeros, edited.type))
-- audition: render with the real Csound and 'play' through the mocked preview
do
  local function wav_info(path)
    local f = io.open(path, "rb"); if not f then return nil end
    local size = f:seek("end"); f:close(); return size
  end
  gfx.mouse_cap = 0
  local function key_audition()
    local n = #previews
    script.keys = { 97 }; strings = {}; frame()
    for _ = 1, 3000 do if #previews > n then break end; frame() end
    strings = {}; frame()
  end
  key_audition()                                                                -- A
  assert(#previews == 1, "audition did not start a preview; strings: " .. table.concat(strings, " / ", 1, math.min(#strings, 40)))
  local size = wav_info(previews[1])
  first_sound_size = size                                                       -- (the file itself is removed later: only the last few are kept)
  assert(size and size > 300000, "rendered WAV missing or too short: " .. tostring(size))
  assert(saw("^auditioning from [%d%.]+ s, [%d%.]+ s long %(sines %+ noise, %a+ synthesis%)"), "status: " .. tostring(saw("auditioning") or saw("failed") or saw("preparing")))
  script.keys = { 112 }; frame()                                                -- P off: noise only
  key_audition()
  assert(#previews == 2 and saw("%(noise, %a+ synthesis%)"), "noise-only audition expected")
  script.keys = { 112 }; frame(); script.keys = { 110 }; frame()                -- P on, N off: sines only
  key_audition()
  assert(#previews == 3 and saw("%(sines, %a+ synthesis%)"), "sines-only audition expected")
  script.keys = { 112 }; frame(); script.keys = { 112 }; frame()                -- P off, then on again
  script.keys = { 110 }; frame()                                                -- N on again
  script.keys = { 32 }; strings = {}; frame(); frame()                          -- Space stops
  assert(saw("audition stopped"), "stop status missing")
  assert(destroyed == 0, "preview sources must never be destroyed from the script")
  assert(previews[1] ~= previews[2] and previews[2] ~= previews[3], "every render needs its own WAV name")
  assert(stops >= 1, "an audition during a running preview should stop it first")
  -- the playhead: set it on the time ruler, AUDITION plays from there, the line moves, and it goes back
  local function label_time()                                 -- the number in the playhead label ("1.000 s")
    for _, str in ipairs(strings) do local v = str:match("^(%d+%.%d%d%d) s$"); if v then return tonumber(v) end end
  end
  script.keys = { 102 }; frame()                                -- F: fit the view, so the ruler is 0 .. the end
  local d1 = dofile("lib/ats_file.lua").load(work)
  local tmax = d1.times[d1.frames]
  local ruler_y = 70 + 516 + 10
  local function ruler_click(t)
    gfx.mouse_x, gfx.mouse_y, gfx.mouse_cap = 62 + 988 * t / tmax, ruler_y, 1; frame()
    gfx.mouse_cap = 0; strings = {}; frame()
  end
  strings = {}; frame()
  assert(label_time() == 0, "the playhead starts at 0, saw " .. tostring(label_time()))
  ruler_click(1.0)
  assert(math.abs(label_time() - 1.0) < 0.02, "a click on the ruler sets the playhead, saw " .. tostring(label_time()))
  local before = #previews
  script.keys = { 110 }; frame()                                -- N off: sines only (a small file, quick)
  key_audition()
  assert(#previews == before + 1, "audition should start from the playhead")
  assert(saw("^auditioning from 1%.0%d s"), "the status should say from 1.0 s: " .. tostring(saw("^auditioning")))
  local full_size, part_size = first_sound_size, wav_info(previews[#previews])
  assert(part_size < 0.7 * full_size, "the sound from 1.0 s is about half as long as the whole: " .. part_size .. " vs " .. full_size)
  clock_skew = clock_skew + 0.5; strings = {}; frame()
  assert(label_time() and label_time() > 1.3 and label_time() < 1.7, "the playhead moves while it plays, saw " .. tostring(label_time()))
  clock_skew = clock_skew + 10; strings = {}; frame(); strings = {}; frame()
  assert(math.abs(label_time() - 1.0) < 0.02, "when the sound has ended the playhead is back at its place, saw " .. tostring(label_time()))
  key_audition()
  clock_skew = clock_skew + 0.3
  script.keys = { 32 }; strings = {}; frame(); strings = {}; frame()
  assert(math.abs(label_time() - 1.0) < 0.02, "Space stops and the playhead returns, saw " .. tostring(label_time()))
  ruler_click(0.4)
  assert(math.abs(label_time() - 0.4) < 0.02, "a second click moves it")
  gfx.mouse_x, gfx.mouse_y, gfx.mouse_cap = 62 + 988 * 0.2 / tmax, ruler_y, 1; frame()          -- dragging on the ruler
  gfx.mouse_x = 62 + 988 * 0.7 / tmax; strings = {}; frame()
  assert(math.abs(label_time() - 0.7) < 0.02, "dragging on the ruler scrubs the playhead, saw " .. tostring(label_time()))
  gfx.mouse_cap = 0; frame()
  -- a plain click in the picture (not on a point, not a drag) also sets the playhead and clears the selection
  gfx.mouse_x, gfx.mouse_y, gfx.mouse_cap = 62 + 988 * 0.9 / tmax, 300, 1; frame()
  gfx.mouse_cap = 0; strings = {}; frame()
  assert(math.abs(label_time() - 0.9) < 0.02, "a click in the picture sets the playhead, saw " .. tostring(label_time()))
  assert(not saw("^selected:"), "and clears the selection")
  script.keys = { 110 }; frame()                                -- N on again for the tests that follow
  print("playhead OK: set on the ruler, audition from it, moves while playing, returns, scrubs")
  do local t = os.clock(); os.clock = function() t = t + 0.002; return t end end        -- a clock that ticks per call: a render step does a fixed amount of work
  no_py_synth = true                                                              -- the rest tests the built-in (Lua) synthesis: it works in steps
  -- while the sound is prepared: the AUDITION button blinks, the status shows the progress, Space or an edit cancels it
  do
    ruler_click(0)
    local real_set, real_rect = gfx.set, gfx.rect
    local cur, colours = { 0, 0, 0 }, {}
    gfx.set = function(r, g, b, a) cur = { r, g, b }; return real_set(r, g, b, a) end
    gfx.rect = function(x, y, w, h, f)
      if w == 86 and h == 20 and f == 1 then colours[string.format("%.2f", cur[2])] = true end
      return real_rect(x, y, w, h, f)
    end
    local n_before = #previews
    script.keys = { 97 }; strings = {}; frame()
    local saw_progress, frames_pending, saw_indicator = false, 0, false
    while true do
      clock_skew = clock_skew + 0.2
      strings = {}; frame()
      if saw("^preparing the sound %.%.%. %d+ %%") then saw_progress = true; frames_pending = frames_pending + 1 end
      if saw("^%d+ %%$") then saw_indicator = true end
      if #previews > n_before or frames_pending > 3000 then break end
    end
    gfx.set, gfx.rect = real_set, real_rect
    local n_colours = 0; for _ in pairs(colours) do n_colours = n_colours + 1 end
    assert(saw_progress and frames_pending > 3, "the status should show the preparation, in several frames: " .. frames_pending)
    assert(n_colours >= 2, "the AUDITION button should blink while the sound is prepared, saw " .. n_colours .. " colour(s)")
    assert(saw_indicator, "a percentage should show under the AUDITION button while the sound is prepared")
    assert(#previews == n_before + 1, "the sound starts when it is ready")
    -- Space while preparing: nothing is played
    local count = #previews
    do                                                                         -- a change of the data (an edit and its undo): else the last sound would be played again
      script.keys = { 102 }; frame()
      gfx.mouse_cap = 1; gfx.mouse_x, gfx.mouse_y = 65, 75; frame()
      gfx.mouse_x, gfx.mouse_y = 600, 560; frame(); gfx.mouse_cap = 0; frame(); frame()
      script.keys = { 6579564 }; frame()
      script.keys = { 26 }; gfx.mouse_cap = 4; frame(); gfx.mouse_cap = 0; frame()
    end
    script.keys = { 97 }; frame()                                              -- (the noise is cached now: a render is quick)
    script.keys = { 32 }; strings = {}; frame()
    for _ = 1, 400 do frame() end
    assert(#previews == count, "Space while the sound is prepared must cancel it")
    -- an edit while preparing: nothing is played, and it says so
    script.keys = { 102 }; frame()
    gfx.mouse_cap = 1; gfx.mouse_x, gfx.mouse_y = 65, 75; frame()
    gfx.mouse_x, gfx.mouse_y = 600, 560; frame(); gfx.mouse_cap = 0; frame(); frame()
    script.keys = { 97 }; frame()
    script.keys = { 30064 }; strings = {}; frame()                             -- Up: transpose the selection
    for _ = 1, 400 do frame() end
    assert(#previews == count, "an edit while preparing must cancel the sound")
    script.keys = { 26 }; gfx.mouse_cap = 4; frame(); gfx.mouse_cap = 0; frame()   -- Ctrl+Z: undo it
    print("the AUDITION button blinks while the sound is prepared; Space or an edit cancels it")
  end
  print("audition OK: 3 renders with the Lua synthesis (sines+noise, noise, sines); stops=" .. stops .. ", destroyed=" .. destroyed)
  for _, w in ipairs(previews) do os.remove(w) end
  os.remove("/tmp/reaats_audition.ats"); os.remove("/tmp/reaats_audition.csd")
end
-- print to track + ReaSnap item settings
do
  local ser = dofile("lib/reaats_serial.lua")
  -- an unsaved edit first: select the whole plot and delete it, so PRINT has to save the edit
  gfx.mouse_cap = 0
  gfx.mouse_cap = 1; gfx.mouse_x, gfx.mouse_y = 65, 75; frame()
  gfx.mouse_x, gfx.mouse_y = 1040, 540; frame()
  gfx.mouse_cap = 0; frame(); frame()
  script.keys = { 6579564 }; frame()                                           -- Delete: now modified
  gfx.mouse_cap = 0; strings = {}
  -- Ctrl+P: the print is prepared in steps; the PRINT button blinks and a percentage shows under it
  local real_set, real_rect = gfx.set, gfx.rect
  local cur, colours = { 0, 0, 0 }, {}
  gfx.set = function(r, g, b, a) cur = { r, g, b }; return real_set(r, g, b, a) end
  gfx.rect = function(x, y, w, h, f)
    if w == 62 and h == 20 and f == 1 then colours[string.format("%.2f", cur[2])] = true end
    return real_rect(x, y, w, h, f)
  end
  local function key_print()
    script.keys = { 16 }; strings = {}; frame()
    local pct_frames = 0
    for _ = 1, 3000 do
      clock_skew = clock_skew + 0.2
      strings = {}; frame()
      if saw("^%d+ %%$") then pct_frames = pct_frames + 1 end
      if saw("^printed") then break end
    end
    return pct_frames
  end
  local pct_frames = key_print()
  gfx.set, gfx.rect = real_set, real_rect
  local n_colours = 0; for _ in pairs(colours) do n_colours = n_colours + 1 end
  assert(pct_frames > 3, "a percentage should show under the PRINT button while it is prepared, in several frames: " .. pct_frames)
  assert(n_colours >= 2, "the PRINT button should blink while the print is prepared, saw " .. n_colours)
  assert(saw("^printed [%d%.]+ s from [%d%.]+ s %("), "print status missing: " .. table.concat(strings, " / ", 1, math.min(#strings, 40)))
  assert(#project.tracks == 1 and project.tracks[1].name == "ReaATS", "a ReaATS track should be created")
  local item = project.tracks[1].items[1]
  assert(item and item.src:match("_print1%.wav$"), "print item missing: " .. tostring(item and item.src))
  local f = io.open(item.src, "rb"); assert(f, "printed WAV missing"); local size = f:seek("end"); f:close()
  assert(size > 300000, "printed WAV too small")
  local stored = projext["ReaATS_ItemSettings|" .. item.guid]
  assert(stored and stored ~= "", "item settings not written under the item's GUID")
  local st = ser.deserialize(stored)
  assert(st and st.file:match("_edit%d*%.ats$") and io.open(st.file, "rb"), "stored state should name the saved edited .ats file")
  assert(st.view.t1 > st.view.t0 and st.view.f1 > st.view.f0 and st.partials == true and st.noise == true, "stored view/switches wrong")
  print("print OK: item " .. item.src:match("([^/]+)$") .. ", state -> " .. st.name)
  -- second print goes onto the same (selected) track with a new numbered WAV
  gfx.mouse_cap = 0; key_print()
  assert(#project.tracks == 1 and #project.tracks[1].items == 2 and project.tracks[1].items[2].src:match("_print2%.wav$"), "second print")
  -- printing from the playhead: only the sound from there, and the start is remembered with the item
  script.keys = { 102 }; frame()                                -- F: fit the view, so the ruler is 0 .. the end
  local dd = dofile("lib/ats_file.lua").load(work)
  local tmax2 = dd.times[dd.frames]
  local function ruler_click(t)
    gfx.mouse_x, gfx.mouse_y, gfx.mouse_cap = 62 + 988 * t / tmax2, 70 + 516 + 10, 1; frame()
    gfx.mouse_cap = 0; strings = {}; frame()
  end
  ruler_click(1.0)
  key_print()
  local third = project.tracks[1].items[3]
  assert(third and third.src:match("_print3%.wav$"), "third print missing")
  local sz1, sz3 = (function(p) local f = io.open(p, "rb"); local n = f:seek("end"); f:close(); return n end)(item.src),
                   (function(p) local f = io.open(p, "rb"); local n = f:seek("end"); f:close(); return n end)(third.src)
  assert(sz3 < 0.7 * sz1, "a print from 1.0 s is about half as long as the whole: " .. sz3 .. " vs " .. sz1)
  assert(saw("^printed [%d%.]+ s from 1%.0%d s"), "the status says where the print started: " .. tostring(saw("^printed")))
  local st3 = ser.deserialize(projext["ReaATS_ItemSettings|" .. third.guid])
  assert(st3 and math.abs(st3.from - 1.0) < 0.0101, "the item remembers where the print started, saw " .. tostring(st3 and st3.from))
  print("PRINT starts at the playhead and remembers it")
  ruler_click(0)
  -- Esc cancels a print that is being prepared: no item
  local items_before = #project.tracks[1].items
  script.keys = { 16 }; strings = {}; frame(); frame()
  script.keys = { 27 }; strings = {}; frame()
  for _ = 1, 400 do frame() end
  assert(#project.tracks[1].items == items_before, "Esc must cancel a print that is being prepared")
  print("PRINT blinks with a percentage under it; Esc cancels it")
  for _, it in ipairs(project.tracks[1].items) do os.remove(it.src) end
  os.remove(st.file)
end
-- Save as (Ctrl+Shift+S): chosen name, .ats appended, overwrite asks, cancel does nothing, fallback box
do
  local ats3 = dofile("lib/ats_file.lua")
  local target = scratch .. "saveas_test"
  local function size(p) local f = io.open(p, "rb"); if not f then return nil end local n = f:seek("end"); f:close(); return n end
  local function save_as_keys() gfx.mouse_cap = 8; script.keys = { 19 }; strings = {}; frame(); frame(); gfx.mouse_cap = 0 end
  os.remove(target .. ".ats")
  save_rv, save_choice = 1, target                                           -- no extension typed: .ats is added
  save_as_keys()
  assert(saw("^exported saveas_test%.ats %(with phase%)"), "export status missing: " .. table.concat(strings, " / ", 1, math.min(#strings, 40)))
  local saved = assert(ats3.load(target .. ".ats")); assert(saved.type == 4 and saved.has_phase, "save as: type 4 expected")
  local first_size = size(target .. ".ats")
  mb_calls, mb_answer = 0, 7                                                 -- the file exists: asks, answer no
  save_as_keys()
  assert(mb_calls == 1 and saw("^not exported"), "an existing file must be confirmed first")
  assert(size(target .. ".ats") == first_size)
  mb_calls, mb_answer = 0, 6                                                 -- answer yes: replaced
  save_as_keys()
  assert(mb_calls == 1 and saw("^exported saveas_test%.ats"), "yes should replace")
  save_rv = 0; mb_calls = 0; clock_skew = clock_skew + 10                    -- cancel: nothing happens (old status has expired)
  save_as_keys(); assert(not saw("^exported") and mb_calls == 0, "cancel must do nothing")
  reaper.JS_Dialog_BrowseForSaveFile = nil                                   -- no JS extension: a typed path is used
  save_rv, save_choice = 1, target .. "_typed.ats"; os.remove(target .. "_typed.ats")
  save_as_keys()
  assert(saw("^exported saveas_test_typed%.ats") and size(target .. "_typed.ats"), "typed-path fallback")
  -- the EXPORT .ats button does the same as Ctrl+Shift+S
  reaper.JS_Dialog_BrowseForSaveFile = function() return save_rv, save_choice end
  save_rv, save_choice = 1, target .. "_button.ats"; os.remove(target .. "_button.ats")
  gfx.mouse_x, gfx.mouse_y, gfx.mouse_cap = gfx.w - 128 - 96 - 72 - 112 + 20, 16, 1; strings = {}; frame()
  gfx.mouse_cap = 0; frame(); frame()
  assert(saw("^exported saveas_test_button%.ats") and size(target .. "_button.ats"), "the EXPORT button should open the export")
  os.remove(target .. ".ats"); os.remove(target .. "_typed.ats"); os.remove(target .. "_button.ats")
  print("save as OK: dialog, .ats added, overwrite confirmed, cancel, typed-path fallback")
end
-- the Sine layer checkbox (under the Noise layer checkbox) switches the partial lines
do
  script.keys = { 114 }; frame()                                  -- R: the original file again (the earlier tests deleted points)
  script.keys = { 102 }; frame()
  strings = {}; frame()
  assert(saw("^Sine layer$") and saw("^Noise layer$"), "both layer checkboxes should be drawn")
  local function click_at(x, y) gfx.mouse_x, gfx.mouse_y, gfx.mouse_cap = x, y, 1; frame(); gfx.mouse_cap = 0; frame() end
  local function lines_of_a_redraw()
    local start = calls.line or 0
    script.keys = { 102 }; frame()                                -- F forces the picture to be drawn again
    return (calls.line or 0) - start
  end
  local on_lines = lines_of_a_redraw()
  click_at(gfx.w - 120, 37)                                       -- Sine layer off
  local off_lines = lines_of_a_redraw()
  click_at(gfx.w - 120, 37)                                       -- and on again
  local back_lines = lines_of_a_redraw()
  assert(on_lines > off_lines + 500, "with the sine layer off the partial lines must not be drawn: " .. on_lines .. " vs " .. off_lines)
  assert(back_lines > off_lines + 500, "and they come back when it is switched on again")
  -- with the layer off nothing can be selected (an edit must never be made on something that is hidden)
  click_at(gfx.w - 120, 37)                                       -- off
  gfx.mouse_cap = 1; gfx.mouse_x, gfx.mouse_y = 65, 75; frame()
  gfx.mouse_x, gfx.mouse_y = 600, 560; frame(); gfx.mouse_cap = 0; strings = {}; frame()
  assert(not saw("^selected:"), "no selection while the sine layer is off")
  assert(saw("^the sine layer is off: switch it on to select partials"), "and it says why")
  click_at(gfx.w - 120, 37)                                       -- on again
  print("Sine layer checkbox: " .. on_lines .. " line calls with the layer, " .. off_lines .. " without")
end
-- a plain click on empty space clears the selection
gfx.mouse_cap = 1; gfx.mouse_x, gfx.mouse_y = 500, 400; frame()
gfx.mouse_cap = 0; strings = {}; frame(); frame()
assert(not saw("^selected:"), "plain click should clear the selection")
local line_before = calls.line or 0
script.keys = { 102 }; frame()                                              -- fit -> full re-render
print(string.format("one full render: %d line calls, %d rect calls", (calls.line or 0) - line_before, calls.rect or 0))
-- Esc: clears a selection, but no longer closes the window (tjingboem, 10 Nov 2026)
gfx.mouse_cap = 1; gfx.mouse_x, gfx.mouse_y = 65, 75; frame()                -- whole plot (earlier box was deleted)
gfx.mouse_x, gfx.mouse_y = 1040, 600; frame()
gfx.mouse_cap = 0; frame(); strings = {}; frame()
assert(saw("^selected:"), "selection expected before Esc")
script.keys = { 27 }; frame()
strings = {}; frame()
assert(not saw("^selected:"), "first Esc should clear the selection")
script.keys = { 27 }
local fn = deferred; deferred = nil; fn()
assert(deferred ~= nil, "a second Esc, with nothing left to clear, should not stop the loop")
print(string.format("mock run OK: %d frames, %.2f s CPU", #steps + 2, os.clock() - t0))
