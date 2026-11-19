--[[----------------------------------------------------------------------------
  WindowPlace.lua — "open a window where it was last dragged to" (19 November 2026, corrections list item 21)

  tjingboem: "show the opening windows on the position where I dragged it to. Unless there are pinned windows of course", and it has to work on every
  system, not only his. So nothing here depends on one operating system: only REAPER's own ExtState and reaper.my_getViewport (the screen rectangle of a
  given rectangle; REAPER reports top and bottom the other way round on macOS, so they are normalised) and ReaImGui's window position and size calls
  (made by the tool, see below). Where a system does not let programs place their windows (Wayland, some window managers) the window simply opens where
  the system puts it.

  How it works
    * The place of a tool (x, y, width, height) is kept in REAPER's own settings file (persistent ExtState, section tjingboem_WindowPlace, key place_<tool>).
      It is saved when an UNPINNED window of the tool has been moved or resized by the user and then stayed in place for half a second, and when it closes.
      A window that merely opened at a place that was chosen for it (beside a pinned window) is not "moved by the user" and saves nothing.
    * At opening: initial() gives the place, or nil (then the tool does nothing and the system decides). A place that lies on no screen any more (a
      monitor was unplugged) is dropped; one that is bigger than its screen is made to fit; the title bar always stays on the screen.
    * Pinned windows (any tool that uses this module) are announced in non-persistent ExtState (win_<id>: tool, place, pinned, time stamp renewed from
      the window's own frame loop). A new window that would land on a pinned window opens beside it: to its right, below it, to its left, or stepped down
      and to the right like cascaded windows, whichever comes first and lies on the screen and covers no pinned window. A pinned window never moves.
  A tool does:   local Place = dofile(<folder> .. "WindowPlace.lua").new("ReaMaskM")
    before its first Begin:   local r = Place.initial()  → if r then SetNextWindowPos(ctx, r.x, r.y, Cond_Once); SetNextWindowSize(ctx, r.w, r.h, Cond_Once) end
    every frame after Begin:  Place.frame(GetWindowPos(ctx), GetWindowSize(ctx), pinned)
    when the window closes:   Place.close()
--------------------------------------------------------------------------------]]

local M = {}
M.SECTION = "tjingboem_WindowPlace"
M.STABLE  = 0.5      -- seconds a moved window has to stay in place before its place is saved
M.ALIVE   = 2.0      -- a window whose stamp is older than this is gone
M.EVERY   = 0.5      -- how often a window renews its stamp
M.GAP     = 12       -- pixels between a new window and the pinned one it moves aside for
M.STEP    = 32       -- the cascade step (about a title bar)
M.MAX_OVERLAP = 0.25 -- a new window may cover this much of ITSELF with pinned windows before it moves

-- ------------------------------------------------------------------ pure helpers (no REAPER calls)
local function norm(l, t, r, b) return { l = math.min(l, r), t = math.min(t, b), r = math.max(l, r), b = math.max(t, b) } end

-- the area where two rectangles {x,y,w,h} overlap
function M.overlap(a, b)
  local w = math.min(a.x + a.w, b.x + b.w) - math.max(a.x, b.x)
  local h = math.min(a.y + a.h, b.y + b.h) - math.max(a.y, b.y)
  if w <= 0 or h <= 0 then return 0 end
  return w * h
end

-- is the middle of the rectangle inside the screen {l,t,r,b}?
function M.center_on(rect, s)
  local cx, cy = rect.x + rect.w / 2, rect.y + rect.h / 2
  return cx >= s.l and cx <= s.r and cy >= s.t and cy <= s.b
end

-- Make the rectangle fit the screen: not bigger than it, moved inside it (so the title bar is on the screen).
function M.fit(rect, s)
  local sw, sh = s.r - s.l, s.b - s.t
  local w, h = math.min(rect.w, sw), math.min(rect.h, sh)
  local x = math.max(s.l, math.min(rect.x, s.r - w))
  local y = math.max(s.t, math.min(rect.y, s.b - h))
  return { x = x, y = y, w = w, h = h }
end

-- how much of `rect` is covered by the pinned rectangles (0..1)
local function covered(rect, pinned)
  local sum = 0
  for _, p in ipairs(pinned) do sum = sum + M.overlap(rect, p) end
  return sum / math.max(rect.w * rect.h, 1)
end

-- Where to open `rect` so that it does not lie on pinned windows: itself when it is free enough, else beside the pinned window it overlaps most
-- (right, below, left), else cascaded. Always a place that lies on the screen.
function M.pick_free(rect, pinned, s)
  if #pinned == 0 or covered(rect, pinned) <= M.MAX_OVERLAP then return rect end
  local cands = {}
  local worst, wa = nil, 0
  for _, p in ipairs(pinned) do local a = M.overlap(rect, p); if a > wa then worst, wa = p, a end end
  if worst then
    cands[#cands + 1] = { x = worst.x + worst.w + M.GAP, y = rect.y, w = rect.w, h = rect.h }                 -- to its right
    cands[#cands + 1] = { x = rect.x, y = worst.y + worst.h + M.GAP, w = rect.w, h = rect.h }                 -- below it
    cands[#cands + 1] = { x = worst.x - rect.w - M.GAP, y = rect.y, w = rect.w, h = rect.h }                  -- to its left
  end
  for k = 1, 10 do cands[#cands + 1] = { x = rect.x + k * M.STEP, y = rect.y + k * M.STEP, w = rect.w, h = rect.h } end
  for _, c in ipairs(cands) do
    local inside = M.fit(c, s)
    -- (a candidate that had to be moved to fit the screen is not the place that was meant: skip it)
    if math.abs(inside.x - c.x) < 1 and math.abs(inside.y - c.y) < 1 and inside.w == c.w and inside.h == c.h
       and covered(c, pinned) <= M.MAX_OVERLAP then
      return c
    end
  end
  return M.fit({ x = rect.x + M.STEP, y = rect.y + M.STEP, w = rect.w, h = rect.h }, s)
end

local function parse_place(v)
  local x, y, w, h = tostring(v or ""):match("^(-?%d+),(-?%d+),(%d+),(%d+)$")
  if not x then return nil end
  x, y, w, h = tonumber(x), tonumber(y), tonumber(w), tonumber(h)
  if w < 100 or h < 60 then return nil end          -- not a window
  return { x = x, y = y, w = w, h = h }
end
M.parse_place = parse_place

-- ------------------------------------------------------------------ the tool's window
-- deps (for tests): viewport(l,t,r,b) -> l,t,r,b of the screen's work area; now() -> seconds; get(key), set(key, value, persist), del(key)
function M.new(tool, deps)
  deps = deps or {}
  local get = deps.get or function(k) return reaper.GetExtState(M.SECTION, k) end
  local set = deps.set or function(k, v, persist) reaper.SetExtState(M.SECTION, k, v, persist and true or false) end
  local del = deps.del or function(k) reaper.DeleteExtState(M.SECTION, k, false) end
  local now = deps.now or function() return reaper.time_precise() end
  local viewport = deps.viewport or function(l, t, r, b)
    if not reaper.my_getViewport then return nil end
    local a, c, d, e = reaper.my_getViewport(0, 0, 0, 0, l, t, r, b, true)      -- the work area of the screen the rectangle is on / nearest to (the second rectangle is the input)
    if not a then return nil end
    return a, c, d, e
  end

  local self = { tool = tool, baseline = nil, last = nil, seen_at = 0, saved = nil, moved = false, stamp_at = 0, pinned = false }
  self.id = string.format("%x%x", math.floor(now() * 1000) % 0xFFFFFF, math.random(0, 0xFFFFFF))

  local function screen_of(rect)
    local l, t, r, b = viewport(rect.x, rect.y, rect.x + rect.w, rect.y + rect.h)
    if not l then return nil end
    return norm(l, t, r, b)
  end

  -- the rectangles of the pinned windows that are open (any tool), not this one
  local function pinned_rects()
    local out, t_now = {}, now()
    for id in get("wins"):gmatch("[^;]+") do
      if id ~= self.id then
        local tool, x, y, w, h, p, t = get("win_" .. id):match("^([^|]*)|(-?%d+)|(-?%d+)|(%d+)|(%d+)|([01])|([%d%.]+)$")
        if tool and p == "1" and t_now - tonumber(t) < M.ALIVE then
          out[#out + 1] = { x = tonumber(x), y = tonumber(y), w = tonumber(w), h = tonumber(h) }
        end
      end
    end
    return out
  end

  -- The place for a new window, or nil (the tool does nothing: the system decides).
  function self.initial()
    local rect = parse_place(get("place_" .. tool))
    if not rect then return nil end
    local s = screen_of(rect)
    if not s or not M.center_on(rect, s) then return nil end        -- the place is on no screen any more
    rect = M.fit(rect, s)
    rect = M.pick_free(rect, pinned_rects(), s)
    self.saved = parse_place(get("place_" .. tool))
    self.baseline = { x = rect.x, y = rect.y, w = rect.w, h = rect.h }   -- what the window is given: not the user's doing
    return rect
  end

  local function stamp(x, y, w, h, pinned)
    local ids, found = {}, false
    local t_now = now()
    for id in get("wins"):gmatch("[^;]+") do
      local _, _, _, _, _, _, t = get("win_" .. id):match("^([^|]*)|(-?%d+)|(-?%d+)|(%d+)|(%d+)|([01])|([%d%.]+)$")
      if id == self.id then found = true; ids[#ids + 1] = id
      elseif t and t_now - tonumber(t) < M.ALIVE then ids[#ids + 1] = id end     -- forget windows that are gone
    end
    if not found then ids[#ids + 1] = self.id end
    set("wins", table.concat(ids, ";"), false)
    set("win_" .. self.id, string.format("%s|%d|%d|%d|%d|%d|%.3f", tool, x, y, w, h, pinned and 1 or 0, t_now), false)
    self.stamp_at = t_now
  end

  local function save_place(r)
    set("place_" .. tool, string.format("%d,%d,%d,%d", r.x, r.y, r.w, r.h), true)
    self.saved = { x = r.x, y = r.y, w = r.w, h = r.h }
  end

  local function moved_from_baseline(r)
    local b = self.baseline
    return math.abs(r.x - b.x) > 2 or math.abs(r.y - b.y) > 2 or math.abs(r.w - b.w) > 2 or math.abs(r.h - b.h) > 2
  end

  -- Once per frame, with the window's position and size (ReaImGui: GetWindowPos, GetWindowSize) and whether it is pinned.
  function self.frame(x, y, w, h, pinned)
    if not x or not w then return end
    x, y, w, h = math.floor(x + 0.5), math.floor(y + 0.5), math.floor(w + 0.5), math.floor(h + 0.5)
    local r = { x = x, y = y, w = w, h = h }
    local t = now()
    if not self.baseline then self.baseline = { x = x, y = y, w = w, h = h } end      -- no saved place: the place the system gave
    if (pinned and true or false) ~= self.pinned or t - self.stamp_at >= M.EVERY then
      self.pinned = pinned and true or false
      stamp(x, y, w, h, self.pinned)
    end
    if self.pinned then return end                                  -- a pinned window never sets the place of the next one
    if not self.last or math.abs(r.x - self.last.x) > 0 or math.abs(r.y - self.last.y) > 0 or r.w ~= self.last.w or r.h ~= self.last.h then
      self.last, self.seen_at = r, t
      return
    end
    if t - self.seen_at >= M.STABLE and moved_from_baseline(r)
       and (not self.saved or self.saved.x ~= r.x or self.saved.y ~= r.y or self.saved.w ~= r.w or self.saved.h ~= r.h) then
      save_place(r)
    end
  end

  function self.close()
    if self.last and not self.pinned and self.baseline and moved_from_baseline(self.last)
       and (not self.saved or self.saved.x ~= self.last.x or self.saved.y ~= self.last.y or self.saved.w ~= self.last.w or self.saved.h ~= self.last.h) then
      save_place(self.last)
    end
    local ids = {}
    for id in get("wins"):gmatch("[^;]+") do if id ~= self.id then ids[#ids + 1] = id end end
    set("wins", table.concat(ids, ";"), false)
    del("win_" .. self.id)
  end

  return self
end

return M
