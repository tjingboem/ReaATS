-- Run: lua5.4 tests/test_layout.lua   (from the ReaATS folder). Checks lib/layout.lua (made by tools/gen_layout.py from the ReaLayout file) and the generator.
local ok, fails = 0, 0
local function check(name, cond, extra)
  if cond then ok = ok + 1 else fails = fails + 1; print("FAIL: " .. name .. " " .. tostring(extra or "")) end
end
local L = dofile("lib/layout.lua")
check("reference size", L.ref_w == 1100 and L.ref_h == 640)
local need = { "hdr_info_s", "hdr_partial_s", "hdr_selinfo_s", "btn_analyse_s", "btn_export_s", "btn_notes_s", "btn_print_s", "btn_start_s", "btn_audition_s", "chk_noise_s",
               "chk_sine_s", "ch1_led", "ch1_btn", "ch1_slider", "ch2_btn", "btn_stackmode", "plot", "plot_s", "btn_maxpart_s", "btn_space_s",
               "space_slider_s", "space_pct_s", "space_out_s" }
for _, id in ipairs(need) do
  local e = L.el[id]
  check("element " .. id, e and e.w > 0 and e.h > 0 and (e.ax == "l" or e.ax == "r") and (e.ay == "t" or e.ay == "b"), id)
  if e then check(id .. " is inside the window", e.x >= 0 and e.y >= 0 and e.x + e.w <= L.ref_w and e.y + e.h <= L.ref_h, id) end
end
local p = L.el.plot
check("margins follow the picture", L.margins[1] == p.x and L.margins[2] == L.ref_w - (p.x + p.w) and L.margins[3] == p.y and L.margins[4] == L.ref_h - (p.y + p.h))
check("channel row height is the difference of the two pictures", L.margins[5] == L.el.plot_s.y - p.y)

-- the Analysis page layout (lib/analysis_layout.lua, from the ReaLayout file): every field of the page has its box (and its label unless it is a switch)
do
  package.path = "lib/?.lua;" .. package.path
  reaper = { file_exists = function() return false end, GetExtState = function() return "" end }
  local page = require("analysis_page")
  local A = dofile("lib/analysis_layout.lua")
  for key, f in pairs(page.FIELDS) do
    check("analysis layout: box of " .. key, A.el["fld_" .. key] ~= nil, key)
    if f.kind ~= "bool" then check("analysis layout: label of " .. key, A.el["lbl_" .. key] ~= nil, key) end
  end
  for _, id in ipairs({ "hdr_source", "hdr_window_and_time", "hdr_peaks_and_tracks", "hdr_output", "btn_use_selected_item", "btn_import_sound_file",
                        "btn_import_ats_file", "btn_inspect_sound_file", "txt_file", "btn_analyse", "btn_defaults", "btn_editor" }) do
    check("analysis layout: " .. id, A.el[id] ~= nil, id)
  end
  for id, e in pairs(A.el) do
    check("analysis layout: " .. id .. " is inside the window width", e.x >= 0 and (e.x + e.w <= 1100 or id:find("^txt_")) and e.w > 0 and e.h > 0, id)   -- (the width of a text is a guess)
  end
end

-- the generator refuses a layout that lacks an element, and says which
local function run(cmd) local h = io.popen(cmd .. " 2>&1"); local o = h:read("a"); h:close(); return o end
local tmp = (os.getenv("TMPDIR") or "/tmp") .. "/reaats_layout_test_" .. os.time() .. ".json"
local fh = io.open(tmp, "w"); fh:write('[{"panel":"editor","state":"set","id":"plot","label":"p","shape":"box","x":62,"y":70,"w":988,"h":516}]'); fh:close()
local out = run("python3 tools/gen_layout.py " .. tmp .. " " .. tmp .. ".lua")
check("the generator names a missing element", out:find("missing in the layout") and out:find("btn_print_s"), out)
os.remove(tmp); os.remove(tmp .. ".lua")
print(string.format("%d passed, %d failed", ok, fails))
os.exit(fails == 0 and 0 or 1)
