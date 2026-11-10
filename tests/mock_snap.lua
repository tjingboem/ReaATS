-- Run: lua5.4 tests/mock_snap.lua   (from the ReaATS folder)
-- The ReaSnap side of the editor: window title number, snapshot restore, Close All. Fake gfx / reaper.
local root = os.getenv("PWD")
local scratch = "/tmp/claude-1000/-home-tjingboem/6ca29d3f-340f-46ca-9b11-e579b6c375ee/scratchpad/"
local Serial = dofile("lib/reaats_serial.lua")
local ext, strings, title = {}, {}, nil
local deferred
local clock = 100.0
local function key(sec, k) return sec .. "|" .. k end
gfx = { w = 1100, h = 640, mouse_x = 0, mouse_y = 0, mouse_cap = 0, mouse_wheel = 0, x = 0, y = 0, a = 1, dest = -1 }
for _, n in ipairs({ "set", "rect", "line", "circle", "blit", "setimgdim", "setfont", "update" }) do gfx[n] = function() return 0 end end
gfx.init = function(t) title = t end
gfx.measurestr = function(s) return #s * 7, 14 end
gfx.drawstr = function(s) strings[#strings + 1] = s end
gfx.getchar = function() return 0 end
reaper = {
  get_action_context = function() return true, root .. "/ATS_Editor.lua", 0, 0 end,
  GetExtState = function(sec, k) return ext[key(sec, k)] or "" end,
  SetExtState = function(sec, k, v) ext[key(sec, k)] = v end,
  ShowConsoleMsg = function(s) io.write("[console] ", s) end,
  file_exists = function(p) local f = io.open(p, "rb"); if f then f:close() return true end return false end,
  GetUserFileNameForRead = function() return false, "" end,
  time_precise = function() return clock end,
  defer = function(fn) deferred = fn end,
}
local function frame() local f = deferred; deferred = nil; assert(f, "viewer stopped"); f() end
local function saw(pat) for _, s in ipairs(strings) do if s:find(pat) then return s end end end

-- a snapshot as ReaSnap would hand it over: the file, a view, noise off
local file = scratch .. "snap_sax.ats"
do local a = io.open("examples/sax.ats", "rb"); local d = a:read("a"); a:close(); local b = io.open(file, "wb"); b:write(d); b:close() end
ext[key("ReaSculpt_Registry", "pending_ReaATS_settings")] =
  Serial.serialize({ file = file, name = "snap_sax.ats", view = { t0 = 0.5, t1 = 1.0, f0 = 200, f1 = 2000 }, partials = true, noise = false, from = 0.6 })
ext[key("ReaSculpt_Registry", "pending_ReaATS_instance_number")] = "2"
ext[key("ReaSculpt_Registry", "pending_ReaATS_project_identity")] = "projA"
ext[key("tjingboem_ATSViewer", "last_file")] = "/nonexistent/other.ats"          -- must be ignored

dofile("ATS_Editor.lua")
assert(title == "ATS Editor #2", "window title should carry the instance number, got " .. tostring(title))
assert(ext[key("ReaSculpt_Registry", "pending_ReaATS_settings")] == "", "pending settings must be consumed")
assert(ext[key("ReaSculpt_Registry", "pending_ReaATS_instance_number")] == "", "instance number must be consumed")
assert(ext[key("ReaSculpt_Registry", "pending_ReaATS_project_identity")] == "", "project identity must be consumed")
strings = {}; frame()
assert(saw("^snap_sax%.ats"), "the snapshot's file should be loaded")
-- the view was restored: the time axis labels start near 0.5 s, the frequency axis has 200 / 500 / 1k
assert(saw("^0%.6 s") or saw("^0%.5 s") or saw("^0%.7 s"), "time axis should follow the restored view")
assert(not saw("^2 s$"), "the restored view should not show the whole 2 s")
assert(saw("^0%.600 s$") or saw("^0%.59%d s$"), "the playhead should come back to where the print started")
print("restore OK: title '" .. title .. "', file and view restored")

-- Close All: another project does nothing; a stale signal does nothing; the right one closes
ext[key("ReaSculpt_Registry", "close_ReaATS_signal")] = "projB|200.5"
clock = clock + 1; frame()
ext[key("ReaSculpt_Registry", "close_ReaATS_signal")] = "projA|50.0"          -- older than this instance
clock = clock + 1; frame()
assert(deferred, "a signal for another project / from before the launch must not close the window")
ext[key("ReaSculpt_Registry", "close_ReaATS_signal")] = "projA|" .. (clock + 1)
clock = clock + 2; frame()
assert(deferred == nil, "a fresh signal for this project should close the window")
print("close all OK")

-- a snapshot whose file is gone: says so, falls back, does not crash
ext = {}
ext[key("ReaSculpt_Registry", "pending_ReaATS_settings")] = Serial.serialize({ file = "/nonexistent/gone.ats", view = {} })
ext[key("tjingboem_ATSViewer", "last_file")] = file
strings = {}; deferred = nil
dofile("ATS_Editor.lua")
frame()
assert(saw("^snapshot file not found: /nonexistent/gone%.ats"), "missing-file message expected")
assert(not saw("^snap_sax%.ats"), "the window stays empty: the last file is not reopened")
-- garbage in the pending slot: ignored with a console message
ext = {}
ext[key("ReaSculpt_Registry", "pending_ReaATS_settings")] = 'os.execute("echo no")'
ext[key("tjingboem_ATSViewer", "last_file")] = file
deferred = nil
dofile("ATS_Editor.lua")
frame()
-- no snapshot at all: the window starts empty, even though a last file is remembered
ext = {}
ext[key("tjingboem_ATSViewer", "last_file")] = file
strings = {}; deferred = nil
dofile("ATS_Editor.lua")
frame()
assert(not saw("^snap_sax%.ats"), "the last file must not be reopened at the start")
assert(not saw("Press O to open"), "the hint text was removed")
assert(saw("^ANALYSE$"), "the empty window still offers ANALYSE")
os.remove(file)
print("missing file / garbage / empty start OK")
