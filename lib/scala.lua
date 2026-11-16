-- Scala scale files (.scl) and snapping a frequency to a scale. Pure Lua, no REAPER.
-- tjingboem, 16 Nov 2026: Scala mode = autotune of partials to a Scala scale (see CLAUDE.md).
--
-- The .scl format: lines that start with "!" are comments. The first other line is a description (it may be empty), the second the number of
-- notes N, then N lines with one degree each: a number with a point is CENTS, a number with a slash (or a whole number) is a RATIO. The unison (1/1, 0 cents)
-- is not listed; the LAST degree is the period (usually 2/1 = 1200 cents) after which the pattern repeats.
local M = {}

local function log2(x) return math.log(x) / math.log(2) end

-- One degree line -> cents, or nil and a reason. Anything after the first word (a comment) is ignored.
function M.degree_cents(line)
  local w = line:match("^%s*(%S+)")
  if not w then return nil, "empty degree line" end
  if w:find("[%./]") and not w:find("/") then                    -- cents: contains a point and no slash
    local c = tonumber(w)
    if not c then return nil, "not a number: " .. w end
    return c
  end
  local a, b = w:match("^(%d+)/(%d+)$")
  if a then
    a, b = tonumber(a), tonumber(b)
    if a <= 0 or b <= 0 then return nil, "bad ratio: " .. w end
    return 1200 * log2(a / b)
  end
  local n = w:match("^(%d+)$")
  if n then
    n = tonumber(n)
    if n <= 0 then return nil, "bad ratio: " .. w end
    return 1200 * log2(n)
  end
  local c = tonumber(w)                                          -- e.g. "-5" or "1e2": read as cents
  if c then return c end
  return nil, "not a number: " .. w
end

-- text -> { description, degrees = { cents of each listed degree, the last is the period }, period = cents, count } or nil and a reason.
function M.parse(text)
  local lines = {}
  for line in (text:gsub("\r", "") .. "\n"):gmatch("(.-)\n") do
    if not line:match("^%s*!") then lines[#lines + 1] = line end
  end
  if #lines < 2 then return nil, "this is not a Scala file (no description and count)" end
  local description = lines[1]:gsub("^%s+", ""):gsub("%s+$", "")
  local count = tonumber(lines[2]:match("^%s*(%d+)"))
  if not count or count < 1 then return nil, "the note count is missing" end
  local degrees = {}
  for i = 1, count do
    local line = lines[2 + i]
    if not line then return nil, string.format("the file lists %d degrees, %d were expected", #degrees, count) end
    local c, why = M.degree_cents(line)
    if not c then return nil, string.format("degree %d: %s", i, why) end
    degrees[i] = c
  end
  local period = degrees[count]
  if period <= 0 then return nil, "the last degree (the period) must be above 0 cents" end
  return { description = description, degrees = degrees, period = period, count = count }
end

function M.load(path)
  local f = io.open(path, "rb")
  if not f then return nil, "cannot open " .. path end
  local text = f:read("a")
  f:close()
  local sc, why = M.parse(text)
  if sc then sc.path = path; sc.name = path:match("([^/\\]+)$") or path end
  return sc, why
end

-- Cents above the root of the degree k of period j (k = 0 is the root itself: the unison; k = 1 .. count-1 the listed degrees before the period).
local function degree(sc, j, k)
  return j * sc.period + (k == 0 and 0 or sc.degrees[k])
end

-- Every line of the grid between two cents values (relative to the root, offset NOT included): sorted list of { c = cents, period = j, k = degree number }.
-- k = 0 is the root of a period.
function M.lines(sc, c_lo, c_hi)
  local out = {}
  local j0, j1 = math.floor(c_lo / sc.period) - 1, math.floor(c_hi / sc.period) + 1
  for j = j0, j1 do
    for k = 0, sc.count - 1 do
      local c = degree(sc, j, k)
      if c >= c_lo and c <= c_hi then out[#out + 1] = { c = c, period = j, k = k } end
    end
  end
  table.sort(out, function(a, b) return a.c < b.c end)
  return out
end

-- The cents of the line nearest to `c` (relative to the root, with the grid moved by `offset` cents).
function M.nearest(sc, c, offset)
  local x = c - (offset or 0)
  local j = math.floor(x / sc.period)
  local best, bestd = nil, math.huge
  for jj = j - 1, j + 1 do
    for k = 0, sc.count - 1 do
      local g = degree(sc, jj, k)
      local d = math.abs(g - x)
      if d < bestd then best, bestd = g, d end
    end
  end
  return best + (offset or 0)
end

-- A frequency moved towards the nearest line by `intensity` (0 = stays, 1 = on the line), the way is walked in the logarithm of the frequency
-- (so half is half way in cents).
function M.snap(sc, root_hz, offset, f, intensity)
  if f <= 0 or intensity <= 0 then return f end
  local c = 1200 * log2(f / root_hz)
  local target = M.nearest(sc, c, offset)
  local c2 = c + math.min(intensity, 1) * (target - c)
  return root_hz * 2 ^ (c2 / 1200)
end

-- The intensity of an envelope { {t, v}, ... } (sorted by t, v in 0..1) at the time t: straight lines between the points, held before the first and after the last.
function M.env_at(points, t)
  local n = #points
  if n == 0 then return 1 end
  if t <= points[1].t then return points[1].v end
  if t >= points[n].t then return points[n].v end
  for i = 2, n do
    local a, b = points[i - 1], points[i]
    if t <= b.t then
      if b.t == a.t then return b.v end
      return a.v + (b.v - a.v) * (t - a.t) / (b.t - a.t)
    end
  end
  return points[n].v
end

-- "2/1" or "1200.0 cents" for the period of a scale (for the hover box).
function M.period_text(sc)
  local r = 2 ^ (sc.period / 1200)
  local near = math.floor(r * 1000 + 0.5) / 1000
  if math.abs(sc.period - 1200) < 0.01 then return "2/1 (1200 cents)" end
  return string.format("%.2f cents (ratio %.3f)", sc.period, near)
end

return M
