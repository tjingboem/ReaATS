-- Run: lua5.4 tests/test_cross_page_draw.lua   (from the ReaATS folder)
-- The CROSS page drawn with the real layout (lib/cross_layout.lua) and a fake gfx: no error, the labels of stacked sliders stand beside them, texts follow the width of their element.
local drawn = {}
local fake = { x = 0, y = 0, w = 1100, h = 640, mouse_x = 0, mouse_y = 0 }
setmetatable(fake, { __index = function() return function() return 0 end end })
fake.drawstr = function(s) drawn[#drawn + 1] = { s = s, x = fake.x, y = fake.y } end
fake.measurestr = function(s) return #s * 7, 14 end
gfx = fake
reaper = { time_precise = function() return 0 end, file_exists = function() return false end }
local layout = dofile("lib/cross_layout.lua")
local page = dofile("lib/cross_page.lua").new({ layout = layout, editor_state = function() return {} end, play_pos = function() return nil end })
page:say("a very long message that does not fit in its element at all, it goes on and on and on, and on, and on and on and on, so it has to be made to fit the width of it")
page:draw(1100, 640, 40)
local function find(pattern) for _, d in ipairs(drawn) do if d.s:find(pattern) then return d end end end
local ok = true
local function check(name, cond, extra) if not cond then ok = false; print("FAIL: " .. name .. " " .. tostring(extra or "")) end end
local sl = layout.el.sl_time
local lab = find("^Time tolerance$")
check("the label of the time slider stands beside it (left of it)", lab and lab.x < sl.x and math.abs(lab.y - (sl.y - 2)) < 6, lab and (lab.x .. "," .. lab.y))
local lab2 = find("^Frequency tolerance$")
check("and the second slider's label has its own row (18 px below the first)", lab2 and lab and lab2.y - lab.y == layout.el.sl_freq.y - sl.y, lab2 and lab2.y)
local msg = find("%.%.%.$")
check("the long message is cut to the width of its element with ...", msg and #msg.s * 7 <= layout.el.txt_message.w + 1, msg and #msg.s)
-- the block that plays lights up by its weight in the crossing (two copies of sax.ats, B half over the end of A)
do
  local pg = dofile("lib/cross_page.lua").new({ layout = layout, editor_state = function() return {} end, play_pos = function() return nil end })
  assert(pg:load("a", "examples/sax.ats")); assert(pg:load("b", "examples/sax.ats"))
  local tr = pg:transitions()[1]
  local a, b = tr.l, tr.r
  local w = select(1, pg:tol_of(tr))
  local line = pg:line_of(tr)
  local before, after = tr.lo + 0.01, tr.hi - 0.01
  if w >= tr.hi - tr.lo - 1e-9 then before, after = tr.lo + 0.001, tr.hi - 0.001 end
  check("before the band only the first sound plays", pg:play_intensity(a, tr.lo - 0.3) > 0.9 and pg:play_intensity(b, tr.lo - 0.3) == 0)
  local ia, ib = pg:play_intensity(a, line), pg:play_intensity(b, line)
  check("in the middle of the crossing both light up, each at about 0.7", math.abs(ia - 0.7071) < 0.02 and math.abs(ib - 0.7071) < 0.02, ia .. " " .. ib)
  check("after the crossing only the second sound plays", pg:play_intensity(a, tr.hi + 0.5) == 0 and pg:play_intensity(b, tr.hi + 0.1) > 0.9, pg:play_intensity(b, tr.hi + 0.1))
  pg.tol_time = 0
  check("with a hard line it switches at the line", pg:play_intensity(a, line - 0.05) > 0.9 and pg:play_intensity(b, line - 0.05) == 0 and pg:play_intensity(a, line + 0.05) == 0, pg:play_intensity(a, line + 0.05))
end
print(ok and "CROSS page draw OK: the real layout, labels beside the sliders, the message fits its element" or "FAILED")
os.exit(ok and 0 or 1)
