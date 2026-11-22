-- hub_smoke.lua (19 November 2026): runs the real ReaATS.lua for a number of frames inside a REAPER of its own (RT_ATS = the ReaATS folder,
-- RT_OUT = results folder) and checks that it starts and draws without a script error, that it keeps to one window unless pinned, that a window
-- started while another unpinned one is open hands its settings over and does not open, and that a window that follows an item whose file is
-- missing says so and carries on. The editor runs by reaper.defer(loop): driven here frame by frame.
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

local real_ctx = reaper.get_action_context
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
local Serial = dofile(ATS .. "/lib/reaats_serial.lua")

-- 1. started the way ReaSnap starts a window: with a project identity, so it follows
reaper.SetExtState("ReaSculpt_Registry", "pending_ReaATS_project_identity", "/test/project.rpp", false)
local ok, err = pcall(dofile, ATS .. "/ReaATS.lua")
report(ok, "the editor starts", err)
report(#queue == 1, "it has a frame loop")
report(frames(20), "20 frames are drawn without a script error")
report(reaper.GetExtState("ReaATS_Windows", "ids") ~= "", "the open window is in the registry", reaper.GetExtState("ReaATS_Windows", "ids"))

-- 2. following an item whose settings name a file that is not there: no crash, the window carries on
reaper.InsertTrackAtIndex(0, true)
local tr = reaper.GetTrack(0, 0)
local item = reaper.CreateNewMIDIItemInProj(tr, 0, 4, false)
Serial.write_item_state(item, "ReaATS", Serial.serialize({ file = "/nonexistent/none_ch1.ats", from = 0, name = "none", view = { t0 = 0, t1 = 1, f0 = 40, f1 = 8000 }, partials = true, noise = true }))
reaper.SelectAllMediaItems(0, false); reaper.SetMediaItemSelected(item, true)
report(frames(10), "selecting an item whose .ats file is missing: the window carries on")
report(Serial.read_item_state(item, "ReaATS") ~= nil, "the item's settings can be read back with the editor's own reader")

-- 3. a second editor while the first is open: does not open, hands over
reaper.SetExtState("ReaSculpt_Registry", "pending_ReaATS_settings", Serial.serialize({ file = "/nonexistent/other_ch1.ats", name = "other" }), false)
local n_before = #queue
local ok2, err2 = pcall(dofile, ATS .. "/ReaATS.lua")
report(ok2, "a second editor starts without an error", err2)
report(#queue == n_before, "the second editor did not open a window", #queue - n_before)
report(reaper.GetExtState("ReaSculpt_Registry", "pending_ReaATS_settings") == "", "it took the pending settings away so nobody applies them twice")
report(frames(10), "the first window runs on and takes what was handed over")

-- 4. the first window pinned: a new editor opens its own window
local id = reaper.GetExtState("ReaATS_Windows", "ids"):match("[^;]+")
reaper.SetExtState("ReaATS_Windows", "w_" .. id, string.format("%.3f|1", reaper.time_precise()), false)
n_before = #queue
local ok3, err3 = pcall(dofile, ATS .. "/ReaATS.lua")
report(ok3 and #queue == n_before + 1, "with the open window pinned, a new editor opens its own window", err3 or (#queue - n_before))
report(frames(10), "both windows run")

reaper.get_action_context = real_ctx
finish()
