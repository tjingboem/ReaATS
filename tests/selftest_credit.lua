-- selftest_credit.lua (19 November 2026): the vertical "tjingboem productions" (lib/credit.lua) inside a REAPER of its own (RT_ATS = the ReaATS folder).
local ATS = os.getenv("RT_ATS")
local Credit = dofile(ATS .. "/lib/credit.lua")
local lines, pass, fail = {}, 0, 0
local function report(ok, name, detail)
  if ok then pass = pass + 1 else fail = fail + 1 end
  lines[#lines + 1] = string.format("%s  %s%s", ok and "PASS" or "FAIL", name, detail and ("  -- " .. tostring(detail)) or "")
end
gfx.init("credit", 300, 300)
local c = Credit.new("tjingboem productions", 12):build()
report(c.mode == "rotated" or c.mode == "stacked", "the text was built (mode " .. c.mode .. ")", #c.px)
report(c.h > c.w * 3, "it is tall and narrow (written vertically)", string.format("%d wide, %d tall", c.w, c.h))
local maxx, maxy = 0, 0
for _, p in ipairs(c.px) do if p[1] > maxx then maxx = p[1] end; if p[2] > maxy then maxy = p[2] end end
report(maxx < c.w and maxy < c.h, "every pixel lies inside the rectangle it reports")

-- the quarter turn, on a synthetic picture: bright on the LEFT half (the start of the text) must be bright at the TOP afterwards
do
  local lit = {}
  for y = 0, 12 do for x = 0, 59 do if x < 30 then lit[#lit + 1] = { x, y, 1 } end end end
  local rot = Credit.rotate_cw(lit, 13)
  local top, bottom, maxx, maxy = 0, 0, 0, 0
  for _, p in ipairs(rot) do
    if p[2] < 30 then top = top + 1 else bottom = bottom + 1 end
    if p[1] > maxx then maxx = p[1] end; if p[2] > maxy then maxy = p[2] end
  end
  report(top > 0 and bottom == 0, "the start of the text ends up at the top (reads top to bottom)", string.format("top %d, bottom %d", top, bottom))
  report(maxx == 12 and maxy == 29, "the picture is 13 wide and 60 tall after the turn", string.format("%d, %d", maxx, maxy))
end

local x0, y0 = c.corner(300, 300, 6)
report(x0 + c.w <= 294 and y0 + c.h <= 294 and x0 > 0 and y0 > 0, "the corner position keeps it inside the window", string.format("%d,%d", x0, y0))
report(c.hit(x0, y0, x0 + 2, y0 + 2) and not c.hit(x0, y0, x0 - 5, y0), "the hit test: inside yes, outside no")
-- it draws without error
gfx.dest = -1
local ok, err = pcall(c.draw, x0, y0, 0.55, 0.55, 0.55)
report(ok, "drawing it works", err)

lines[#lines + 1] = ""
lines[#lines + 1] = string.format("RESULT: %d passed, %d failed", pass, fail)
lines[#lines + 1] = "DONE"
local f = io.open(os.getenv("RT_OUT") .. "/results.txt", "w"); f:write(table.concat(lines, "\n"), "\n"); f:close()
