-- Run: lua5.4 tests/test_scala.lua   (from the ReaATS folder). The Scala file parser and the snapping maths.
local S = dofile("lib/scala.lua")
local n, bad = 0, 0
local function check(name, ok, extra) n = n + 1; if not ok then bad = bad + 1; print("FAIL " .. name .. (extra and (": " .. tostring(extra)) or "")) end end
local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-6) end

-- the format: comments, description, count, cents / ratios / whole numbers, the period last
local sc = assert(S.parse("! just.scl\n!\nJust major\n 7\n!\n 9/8\n 5/4\n 4/3\n 3/2\n 5/3\n 15/8\n 2/1\n"))
check("description", sc.description == "Just major")
check("count", sc.count == 7)
check("9/8 in cents", near(sc.degrees[1], 203.91, 0.01), sc.degrees[1])
check("period 2/1", near(sc.period, 1200, 1e-9))
local sc2 = assert(S.parse("12-tone\n12\n100.0\n200.0\n300.\n400.0\n500.0\n600.0\n700.0\n800.0\n900.0\n1000.0\n1100.0\n2\n"))
check("cents with a point", near(sc2.degrees[3], 300) and sc2.count == 12)
check("a whole number is a ratio (2 = 1200 cents)", near(sc2.period, 1200, 1e-9))
local sc3 = assert(S.parse("x\n2\n 3/2 a comment here\n 1200.000 cents\n"))
check("a comment after the number is ignored", near(sc3.degrees[1], 701.955, 0.01))
local empty = assert(S.parse("\n1\n2/1\n"))
check("empty description is allowed", empty.description == "" and empty.count == 1)
check("CRLF files", S.parse("d\r\n1\r\n1200.0\r\n") ~= nil)
check("too few degrees", S.parse("d\n3\n100.0\n200.0\n") == nil)
check("no count", S.parse("d\nabc\n") == nil)
check("a bad degree says which", select(2, S.parse("d\n2\n100.0\nfoo\n")):find("degree 2"))
check("zero ratio", S.parse("d\n1\n0/1\n") == nil)
check("negative period", S.parse("d\n1\n-100.0\n") == nil)

-- the grid: all periods up and down
local g = S.lines(sc2, -1250, 1250)
check("12 per octave over 2 octaves", #g == 25, #g)
check("lines are sorted", g[1].c < g[2].c)
local has0 = false; for _, l in ipairs(g) do if l.c == 0 and l.k == 0 then has0 = true end end
check("the root is a line", has0)

-- nearest line (12-tone scale)
check("nearest: 30 cents -> 0", near(S.nearest(sc2, 30), 0))
check("nearest: 70 cents -> 100", near(S.nearest(sc2, 70), 100))
check("nearest: -130 cents -> -100", near(S.nearest(sc2, -130), -100))
check("nearest: 1230 -> 1200 (the next period)", near(S.nearest(sc2, 1230), 1200))
check("an offset moves the grid: 30 cents with the grid at +40 -> 40", near(S.nearest(sc2, 30, 40), 40))
check("the just scale: 400 cents is nearer 5/4 (386.3) than 4/3 (498)", near(S.nearest(sc, 400), 1200 * math.log(5 / 4) / math.log(2), 1e-6))

-- snap: at full intensity on the line, at half half way, at 0 unchanged
local root = 200
local f = root * 2 ^ (30 / 1200)
check("snap 100 % lands on the root line", near(S.snap(sc2, root, 0, f, 1), root, 1e-6))
local half = S.snap(sc2, root, 0, f, 0.5)
check("snap 50 % is half way in cents", near(1200 * math.log(half / root) / math.log(2), 15, 1e-6))
check("snap 0 % does nothing", S.snap(sc2, root, 0, f, 0) == f)
local f2 = root * 2 ^ (170 / 1200)
check("a pitch glide turns into steps: 40 -> 0 and 60 -> 100 at full intensity",
  near(1200 * math.log(S.snap(sc2, root, 0, root * 2 ^ (40 / 1200), 1) / root) / math.log(2), 0, 1e-6)
  and near(1200 * math.log(S.snap(sc2, root, 0, root * 2 ^ (60 / 1200), 1) / root) / math.log(2), 100, 1e-6))
check("with an offset the root frequency itself is moved", near(1200 * math.log(S.snap(sc2, root, 25, root, 1) / root) / math.log(2), 25, 1e-6))

-- envelope
local env = { { t = 0, v = 1 }, { t = 1, v = 0 }, { t = 2, v = 0.5 } }
check("env before", S.env_at(env, -1) == 1)
check("env middle of a ramp", near(S.env_at(env, 0.5), 0.5))
check("env after", S.env_at(env, 5) == 0.5)
check("env flat", S.env_at({ { t = 0, v = 0.3 }, { t = 9, v = 0.3 } }, 4) == 0.3)

-- a file on disk
local path = (os.getenv("TMPDIR") or "/tmp") .. "/reaats_scala_test.scl"
local fh = io.open(path, "w"); fh:write("! t\nTest\n2\n 3/2\n 2/1\n"); fh:close()
local l = assert(S.load(path))
check("load: name and path", l.name == "reaats_scala_test.scl" and l.path == path and l.count == 2)
os.remove(path)
check("load: missing file", S.load(path) == nil)
check("period text", S.period_text(sc) == "2/1 (1200 cents)")

print(string.format("%d checks, %d failed", n, bad))
os.exit(bad == 0 and 0 or 1)
