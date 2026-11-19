-- ============================================================
--   WindowRegistry.lua
--   "One window is enough, except when pinned" (tjingboem, 19 November 2026).
--
--   Every open ReaATS window keeps a time stamp and its pin state in REAPER's ExtState (section ReaATS_Windows), written from
--   the window's OWN frame loop (at most twice a second; nothing runs in the background). A window that is started while another,
--   UNPINNED window is alive does not open: it hands what it was started with (the settings from ReaSnap's S button, or nothing) over to
--   that window and ends. A pinned window is left alone and a new window opens next to it. A window that crashed leaves a stale stamp
--   behind; stamps older than 2 seconds count as "not open".
-- ============================================================
local M = {}
M.SECTION = "ReaATS_Windows"
M.ALIVE = 2.0       -- seconds after which a stamp is stale
M.EVERY = 0.5       -- how often a window renews its stamp

local function get(key) return reaper.GetExtState(M.SECTION, key) end
local function set(key, v) reaper.SetExtState(M.SECTION, key, v, false) end

local function ids()
  local t = {}
  for id in get("ids"):gmatch("[^;]+") do t[#t + 1] = id end
  return t
end
local function save_ids(t) set("ids", table.concat(t, ";")) end

-- age and pin state of one window, nil when it has no (or a stale) stamp
local function status(id)
  local t, p = get("w_" .. id):match("^([%d%.]+)|([01])$")
  if not t then return nil end
  return tonumber(t), p == "1"
end

function M.new()
  local self = { last = 0, pinned = false, registered = false }
  self.id = string.format("%x%x", math.floor(reaper.time_precise() * 1000) % 0xFFFFFF, math.random(0, 0xFFFFFF))

  -- the id of another window that is open and not pinned, or nil
  function self.other_unpinned_alive()
    local now = reaper.time_precise()
    for _, id in ipairs(ids()) do
      if id ~= self.id then
        local t, pinned = status(id)
        if t and now - t < M.ALIVE and not pinned then return id end
      end
    end
    return nil
  end

  function self.stamp()
    set("w_" .. self.id, string.format("%.3f|%d", reaper.time_precise(), self.pinned and 1 or 0))
    self.last = reaper.time_precise()
  end

  function self.register()
    local now, keep = reaper.time_precise(), {}
    for _, id in ipairs(ids()) do                      -- forget windows that are gone
      local t = status(id)
      if id ~= self.id and t and now - t < M.ALIVE then keep[#keep + 1] = id end
    end
    keep[#keep + 1] = self.id
    save_ids(keep)
    self.registered = true
    self.stamp()
  end

  -- called every frame by the window itself: renews the stamp at most every M.EVERY seconds, at once when the pin changed
  function self.heartbeat(pinned)
    if not self.registered then return end
    local changed = (pinned ~= self.pinned)
    self.pinned = pinned
    if changed or reaper.time_precise() - self.last >= M.EVERY then self.stamp() end
  end

  function self.unregister()
    if not self.registered then return end
    self.registered = false
    local keep = {}
    for _, id in ipairs(ids()) do if id ~= self.id then keep[#keep + 1] = id end end
    save_ids(keep)
    reaper.DeleteExtState(M.SECTION, "w_" .. self.id, false)
    reaper.DeleteExtState(M.SECTION, "handover_" .. self.id, false)
  end

  -- what another window handed over to this one (a string, possibly empty), or nil
  function self.take_handover()
    local v = get("handover_" .. self.id)
    if v == "" then return nil end
    reaper.DeleteExtState(M.SECTION, "handover_" .. self.id, false)
    return (v == "-") and "" or v
  end

  return self
end

-- hand over to window `id`: payload is the encoded settings or "" (just bring the window forward)
function M.hand_over(id, payload)
  set("handover_" .. id, (payload == "") and "-" or payload)
end

return M
