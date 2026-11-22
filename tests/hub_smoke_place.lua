-- hub_smoke_place.lua (19 November 2026): the real ReaATS.lua opens at the saved place in a REAPER of its own and writes its place back. RT_ATS = the ReaATS folder, RT_OUT = results folder.
local ATS, out_dir = os.getenv("RT_ATS"), os.getenv("RT_OUT")
local lines, pass, fail = {}, 0, 0
local function report(ok, name, detail)
  if ok then pass = pass + 1 else fail = fail + 1 end
  lines[#lines + 1] = string.format("%s  %s%s", ok and "PASS" or "FAIL", name, detail and ("  -- " .. tostring(detail)) or "")
end
local function finish()
  lines[#lines + 1] = ""
  lines[#lines + 1] = string.format("RESULT: %d passed, %d failed", pass, fail)
  lines[#lines + 1] = "DONE"
  local f = io.open(out_dir .. "/results.txt", "w"); f:write(table.concat(lines, "\n"), "\n"); f:close()
end
-- the editor asks once (a popup) whether Python is there; nobody answers a popup in a test
reaper.MB = function() return 1 end
reaper.ShowMessageBox = reaper.MB
reaper.get_action_context = function() return true, ATS .. "/ReaATS.lua", 0, 0, 0, 0, 0 end
local queue = {}
reaper.defer = function(f) queue[#queue + 1] = f end
local function frames(n)
  for _ = 1, n do
    local q = queue; queue = {}
    for _, f in ipairs(q) do
      local ok, err = pcall(f)
      if not ok then report(false, "a frame ran without error", err); return false end
    end
  end
  return true
end
reaper.SetExtState("tjingboem_WindowPlace", "place_ReaATS", "150,120,900,600", true)     -- dragged and resized there in an earlier run
reaper.DeleteExtState("tjingboem_WindowPlace", "gfx_offset_ReaATS", true)
local ok, err = pcall(dofile, ATS .. "/ReaATS.lua")
report(ok, "the editor starts", err)
report(frames(20), "20 frames are drawn without a script error")
local ids = reaper.GetExtState("tjingboem_WindowPlace", "wins")
local stamp = reaper.GetExtState("tjingboem_WindowPlace", "win_" .. (ids:match("[^;]+") or ""))
local tool, x, y, w, h = stamp:match("^([^|]*)|(-?%d+)|(-?%d+)|(%d+)|(%d+)|")
report(tool == "ReaATS", "the editor is in the list of open windows", stamp)
report(tonumber(w) == 900 and tonumber(h) == 600, "the window has the saved SIZE (900 x 600)", stamp)
-- the place the editor reports is in the coordinates gfx.init wants: after the offset is learned it must be the place that was asked for
report(math.abs((tonumber(x) or 0) - 150) <= 2 and math.abs((tonumber(y) or 0) - 120) <= 2, "and reports the saved POSITION (150, 120) in gfx.init's own coordinates", stamp)
local off = reaper.GetExtState("tjingboem_WindowPlace", "gfx_offset_ReaATS")
report(off:match("^(-?%d+),(-?%d+)$") ~= nil, "the difference between the asked and the real position was learned and kept", off)
reaper.DeleteExtState("tjingboem_WindowPlace", "place_ReaATS", true)
reaper.DeleteExtState("tjingboem_WindowPlace", "gfx_offset_ReaATS", true)
finish()
