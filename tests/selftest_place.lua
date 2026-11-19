-- selftest_place.lua (19 November 2026): WindowPlace.lua. The logic is tested with a stand-in for REAPER (plain Lua, any system: lua5.4 tests/selftest_place.lua);
-- when it runs inside REAPER (RT_OUT set) the real ExtState and reaper.my_getViewport are checked as well.
local here = (debug.getinfo(1, "S").source:match("^@(.*)$") or ""):match("^(.*)/tests/[^/]*$") or "."
local P = dofile((os.getenv("RT_ATS") or here) .. "/lib/window_place.lua")
local lines, pass, fail = {}, 0, 0
local function report(ok, name, detail)
  if ok then pass = pass + 1 else fail = fail + 1 end
  lines[#lines + 1] = string.format("%s  %s%s", ok and "PASS" or "FAIL", name, detail and ("  -- " .. tostring(detail)) or "")
end
local function rs(r) return r and string.format("%d,%d,%d,%d", r.x, r.y, r.w, r.h) or "nil" end

-- a stand-in for REAPER's ExtState, clock and screen
local function world(screens)
  local w = { store = {}, persist = {}, t = 100, screens = screens or { { 0, 0, 1920, 1080 } }, writes = 0 }
  w.deps = {
    get = function(k) return w.store[k] or "" end,
    set = function(k, v, persist) w.store[k] = v; if persist then w.persist[k] = v; w.writes = w.writes + 1 end end,
    del = function(k) w.store[k] = nil end,
    now = function() return w.t end,
    viewport = function(l, t, r, b)                       -- the screen that contains the middle of the rectangle, else the nearest
      local cx, cy = (l + r) / 2, (t + b) / 2
      local best, bd = w.screens[1], math.huge
      for _, s in ipairs(w.screens) do
        local dx = math.max(s[1] - cx, 0, cx - s[3]); local dy = math.max(s[2] - cy, 0, cy - s[4])
        local d = dx * dx + dy * dy
        if d < bd then best, bd = s, d end
      end
      return best[1], best[2], best[3], best[4]
    end,
  }
  return w
end
local function run_frames(win, w, rect, pinned, seconds)
  for i = 1, math.floor(seconds / 0.1) do w.t = w.t + 0.1; win.frame(rect.x, rect.y, rect.w, rect.h, pinned) end
end

-- ------------------------------------------------------------ pure helpers
report(P.overlap({ x = 0, y = 0, w = 100, h = 100 }, { x = 50, y = 50, w = 100, h = 100 }) == 2500, "overlap of two rectangles")
report(P.overlap({ x = 0, y = 0, w = 100, h = 100 }, { x = 200, y = 0, w = 100, h = 100 }) == 0, "no overlap")
local scr = { l = 0, t = 0, r = 1920, b = 1080 }
local fit = P.fit({ x = 1800, y = 1000, w = 800, h = 600 }, scr)
report(fit.x + fit.w <= 1920 and fit.y + fit.h <= 1080 and fit.w == 800 and fit.h == 600, "a window that sticks out of the screen is moved inside", rs(fit))
fit = P.fit({ x = 10, y = 10, w = 4000, h = 3000 }, scr)
report(fit.w == 1920 and fit.h == 1080 and fit.x == 0 and fit.y == 0, "a window bigger than the screen is made to fit", rs(fit))
report(P.center_on({ x = 100, y = 100, w = 200, h = 200 }, scr) and not P.center_on({ x = 3000, y = 100, w = 200, h = 200 }, scr), "the middle of the window decides whether it is on the screen")
local free = P.pick_free({ x = 100, y = 100, w = 400, h = 300 }, {}, scr)
report(rs(free) == "100,100,400,300", "no pinned window: the place stays")
local pinned = { { x = 100, y = 100, w = 400, h = 300 } }
local moved = P.pick_free({ x = 100, y = 100, w = 400, h = 300 }, pinned, scr)
report(P.overlap(moved, pinned[1]) == 0 and moved.x == 100 + 400 + P.GAP, "a pinned window is there: the new one opens to its right", rs(moved))
local at_right = { { x = 1400, y = 100, w = 500, h = 300 } }
moved = P.pick_free({ x = 1400, y = 100, w = 500, h = 300 }, at_right, scr)
report(P.overlap(moved, at_right[1]) == 0 and moved.x + moved.w <= 1920 and moved.x >= 0, "no room to the right: it goes below or to the left, on the screen", rs(moved))
local everywhere = { { x = 0, y = 0, w = 1920, h = 1080 } }
moved = P.pick_free({ x = 100, y = 100, w = 400, h = 300 }, everywhere, scr)
report(moved.x >= 0 and moved.y >= 0 and moved.x + moved.w <= 1920 and moved.y + moved.h <= 1080, "a pinned window covers the whole screen: it still opens on the screen (cascaded)", rs(moved))
local ok_parse = P.parse_place("-200,50,800,600")
report(ok_parse and ok_parse.x == -200 and P.parse_place("1,2,3") == nil and P.parse_place("10,10,20,20") == nil, "saved places are read back, rubbish is refused")

-- ------------------------------------------------------------ one tool
local w = world()
local a = P.new("ReaMaskM", w.deps)
report(a.initial() == nil, "no saved place: the system decides (nil)")
run_frames(a, w, { x = 640, y = 220, w = 1200, h = 650 }, false, 2)          -- the window opened where the system put it
report(w.writes == 0, "a window that stays where it opened saves nothing")
run_frames(a, w, { x = 300, y = 150, w = 1200, h = 650 }, false, 0.3)
report(w.writes == 0, "a moved window is not saved at once (it must stay in place for half a second)")
run_frames(a, w, { x = 300, y = 150, w = 1200, h = 650 }, false, 1)
report(w.persist["place_ReaMaskM"] == "300,150,1200,650", "after the user moved it and it stayed: the place is saved (persistent)", w.persist["place_ReaMaskM"])
local writes = w.writes
run_frames(a, w, { x = 300, y = 150, w = 1200, h = 650 }, false, 2)
report(w.writes == writes, "it is not saved again while nothing changes")
local b = P.new("ReaMaskM", w.deps)
local r = b.initial()
report(rs(r) == "300,150,1200,650", "a new window of the tool opens where the last one was dragged to", rs(r))
run_frames(b, w, r, false, 3)
report(w.writes == writes, "and a window that opened at the saved place saves nothing")
local other = P.new("ReaShapeM", w.deps)
report(other.initial() == nil, "another tool has its own place")

-- ------------------------------------------------------------ pinned windows
local w2 = world()
local p1 = P.new("ReaMaskM", w2.deps)
p1.initial(); run_frames(p1, w2, { x = 640, y = 220, w = 1200, h = 650 }, false, 1)
run_frames(p1, w2, { x = 100, y = 100, w = 800, h = 500 }, false, 1)           -- dragged to 100,100,800x500: the place
report(w2.persist["place_ReaMaskM"] == "100,100,800,500", "set-up: the place is 100,100 800x500")
run_frames(p1, w2, { x = 100, y = 100, w = 800, h = 500 }, true, 1)            -- the user pins it
local p2 = P.new("ReaMaskM", w2.deps)
local r2 = p2.initial()
report(r2 and P.overlap(r2, { x = 100, y = 100, w = 800, h = 500 }) == 0, "a pinned window sits at the saved place: the new window opens beside it", rs(r2))
run_frames(p1, w2, { x = 500, y = 400, w = 800, h = 500 }, true, 2)            -- the pinned window is dragged around
report(w2.persist["place_ReaMaskM"] == "100,100,800,500", "a pinned window never sets the place")
run_frames(p2, w2, r2, false, 2)
report(w2.persist["place_ReaMaskM"] == "100,100,800,500", "a window that was moved aside for a pinned one saves nothing")
-- the pinned window goes away: the new window opens at the saved place again
p1.close()
local p3 = P.new("ReaMaskM", w2.deps)
report(rs(p3.initial()) == "100,100,800,500", "the pinned window is closed: the saved place is free again")
-- a stale stamp (a crashed pinned window) does not count
local w3 = world()
local q1 = P.new("ReaMaskM", w3.deps)
q1.initial(); run_frames(q1, w3, { x = 0, y = 0, w = 800, h = 500 }, false, 1); run_frames(q1, w3, { x = 100, y = 100, w = 800, h = 500 }, false, 1)
run_frames(q1, w3, { x = 100, y = 100, w = 800, h = 500 }, true, 1)
w3.t = w3.t + 10                                                               -- the pinned window stopped answering
local q2 = P.new("ReaMaskM", w3.deps)
report(rs(q2.initial()) == "100,100,800,500", "a pinned window that stopped stamping (crashed) is ignored")

-- ------------------------------------------------------------ screens
local w4 = world({ { 0, 0, 1920, 1080 } })
w4.store["place_ReaMaskM"] = "2500,200,800,600"                             -- saved on a monitor that is gone
w4.persist["place_ReaMaskM"] = w4.store["place_ReaMaskM"]
report(P.new("ReaMaskM", w4.deps).initial() == nil, "the saved place is on no screen any more: the default (nil)")
local w5 = world({ { 0, 0, 1920, 1080 }, { 1920, 0, 3840, 1080 } })
w5.store["place_ReaMaskM"] = "2500,200,800,600"
report(rs(P.new("ReaMaskM", w5.deps).initial()) == "2500,200,800,600", "the same place with a second monitor: it is used")
local w6 = world({ { 0, 0, 1366, 768 } })
w6.store["place_ReaMaskM"] = "100,100,1900,1000"                            -- saved on a big screen, now a small one
local r6 = P.new("ReaMaskM", w6.deps).initial()
report(r6 and r6.w <= 1366 and r6.h <= 768 and r6.x >= 0 and r6.y >= 0, "a saved window bigger than the screen now: made to fit", rs(r6))
local w7 = world(); w7.deps.viewport = function(l, t, r, b) return 0, 1080, 1920, 0 end     -- macOS gives top and bottom the other way round
w7.store["place_ReaMaskM"] = "100,100,800,600"
report(rs(P.new("ReaMaskM", w7.deps).initial()) == "100,100,800,600", "top and bottom reported the other way round (macOS): still works")
local w8 = world(); w8.deps.viewport = function() return nil end                  -- no way to ask for the screen
w8.store["place_ReaMaskM"] = "100,100,800,600"
report(P.new("ReaMaskM", w8.deps).initial() == nil, "the screen cannot be asked: the default (nil)")

-- ------------------------------------------------------------ closing
local w9 = world()
local c1 = P.new("ReaMaskM", w9.deps)
c1.initial(); run_frames(c1, w9, { x = 640, y = 220, w = 1200, h = 650 }, false, 1)
run_frames(c1, w9, { x = 50, y = 60, w = 1000, h = 600 }, false, 0.2)           -- moved, then closed before it was "stable"
c1.close()
report(w9.persist["place_ReaMaskM"] == "50,60,1000,600", "a window that is closed right after a move still saves its place")
report(w9.store["wins"] == "" and w9.store["win_" .. c1.id] == nil, "a closed window leaves the list of open windows")

-- ------------------------------------------------------------ inside REAPER: the real ExtState and the real screen
if reaper and os.getenv("RT_OUT") then
  local real = P.new("SelftestTool")
  real.initial()
  run_frames = nil
  reaper.SetExtState(P.SECTION, "place_SelftestTool", "10,10,300,200", true)
  local again = P.new("SelftestTool")
  local rr = again.initial()
  report(rr ~= nil and rr.w == 300, "REAPER: a saved place is read back from the real ExtState and checked against the real screen", rs(rr))
  reaper.DeleteExtState(P.SECTION, "place_SelftestTool", true)
  local l, t, r, b = reaper.my_getViewport(0, 0, 0, 0, 100, 100, 400, 300, true)
  report(l ~= nil and r > l and b ~= t, "REAPER: my_getViewport answers", string.format("%s %s %s %s", l, t, r, b))
end

lines[#lines + 1] = ""
lines[#lines + 1] = string.format("RESULT: %d passed, %d failed", pass, fail)
if os.getenv("RT_OUT") then
  lines[#lines + 1] = "DONE"
  local f = io.open(os.getenv("RT_OUT") .. "/results.txt", "w"); f:write(table.concat(lines, "\n"), "\n"); f:close()
else
  print(table.concat(lines, "\n"))
end
