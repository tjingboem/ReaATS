-- Run: lua5.4 tests/test_py_synth.lua   (from the ReaATS folder; needs python3 with numpy)
-- The Python synthesis (python/reaats_synth.py) against the Lua synthesis, and the background job (lib/py_synth.lua).
local root = os.getenv("PWD")
local scratch = os.getenv("TMPDIR") or "/tmp"
local ok_n, fail_n = 0, 0
local function check(name, cond, extra)
  if cond then ok_n = ok_n + 1 else fail_n = fail_n + 1; print("FAIL: " .. name .. " " .. (extra or "")) end
end
local ats = dofile("lib/ats_file.lua")
local synth = dofile("lib/ats_synth.lua")
local py_synth = dofile("lib/py_synth.lua")
local script = root .. "/python/reaats_synth.py"

local function run(args)
  local ph = io.popen("python3 -I " .. script .. " " .. args .. " 2>&1"); local out = ph:read("a"); ph:close(); return out
end
local function read_wav(path)                                  -- 32-bit float WAV written by either side: channels, samples per channel
  local fh = assert(io.open(path, "rb")); local s = fh:read("a"); fh:close()
  local nch = string.unpack("<I2", s, 23)
  local n = (#s - 44) // 4 // nch
  local chans = {}
  for c = 1, nch do chans[c] = {} end
  local pos = 45
  for i = 1, n do for c = 1, nch do chans[c][i] = string.unpack("<f", s, pos); pos = pos + 4 end end
  return chans, string.unpack("<I4", s, 25)
end
local function rms(a) local s = 0; for i = 1, #a do s = s + a[i] * a[i] end; return math.sqrt(s / #a) end
local function corr(a, b)
  local n = math.min(#a, #b); local sa, sb, sab = 0, 0, 0
  for i = 1, n do sa = sa + a[i] * a[i]; sb = sb + b[i] * b[i]; sab = sab + a[i] * b[i] end
  return sab / math.sqrt(sa * sb)
end

local sax = assert(ats.load("examples/sax.ats"))
local sax_path = root .. "/examples/sax.ats"
local out = scratch .. "/ps_test.wav"

-- sines: the same sound as the Lua synthesis
run("--no-noise --out " .. out .. " " .. sax_path)
local py, sr = read_wav(out)
local lua_s = synth.render(sax, { sines = true, noise = false })
check("sines: same length", #py[1] == #lua_s, #py[1] .. " vs " .. #lua_s)
check("sines: same sample rate", sr == 44100)
check("sines: Python equals Lua (correlation " .. string.format("%.5f", corr(py[1], lua_s)) .. ")", corr(py[1], lua_s) > 0.9995)
check("sines: same level", math.abs(20 * math.log(rms(py[1]) / rms(lua_s), 10)) < 0.05)

-- noise: the same level (a different random sequence, so within a dB or so)
run("--no-sines --out " .. out .. " " .. sax_path)
local pn = read_wav(out)
local lua_n = synth.render(sax, { sines = false, noise = true })
local diff_db = 20 * math.log(rms(pn[1]) / rms(lua_n), 10)
check("noise: level within 1.5 dB of the Lua synthesis (" .. string.format("%.2f dB", diff_db) .. ")", math.abs(diff_db) < 1.5)

-- from / to
run("--no-noise --from 0.5 --to 1.0 --out " .. out .. " " .. sax_path)
local pw = read_wav(out)
check("--from/--to: 0.5 s of sound", #pw[1] == 22050, tostring(#pw[1]))
local lua_w = synth.render(sax, { sines = true, noise = false, from = 0.5, to = 1.0 })
check("--from/--to: same length as Lua", #lua_w == #pw[1])
check("--from/--to: equals the Lua window (corr " .. string.format("%.5f", corr(pw[1], lua_w)) .. ")", corr(pw[1], lua_w) > 0.999)

-- several channels, with and without the stereo mixdown
local three = { sax_path, sax_path, sax_path }
run("--no-noise --out " .. out .. " " .. table.concat(three, " "))
local c3 = read_wav(out)
check("3 channels: a 3-channel WAV", #c3 == 3)
run("--no-noise --mixdown stereo --out " .. out .. " " .. table.concat(three, " "))
local st = read_wav(out)
check("mixdown: a stereo WAV", #st == 2)
local lua_mix = synth.mix_to_stereo({ lua_s, lua_s, lua_s })
check("mixdown: equals the Lua mixdown", corr(st[1], lua_mix[1]) > 0.999 and corr(st[2], lua_mix[2]) > 0.999)
run("--no-noise --mixdown stereo --out " .. out .. " " .. sax_path .. " " .. sax_path)
check("mixdown: two channels stay two channels as they are", #read_wav(out) == 2)

-- the noise cache: the second render uses the file; editing partials does not change the noise, so it still hits
local cache = scratch .. "/ps_cache_" .. math.random(100000, 999999)
os.execute("rm -rf " .. cache)
run("--no-sines --cache-dir " .. cache .. " --out " .. out .. " " .. sax_path)
local n1 = read_wav(out)
local function cache_files() local ph = io.popen("ls " .. cache .. " 2>/dev/null | grep -c noise_"); local n = tonumber(ph:read("a")); ph:close(); return n end
check("cache: one file after the first render", cache_files() == 1)
run("--no-sines --cache-dir " .. cache .. " --out " .. out .. " " .. sax_path)
local n2 = read_wav(out)
local same = #n1[1] == #n2[1]
for i = 1, #n1[1] do if math.abs(n1[1][i] - n2[1][i]) > 1e-7 then same = false; break end end
check("cache: the same noise again", same)
local edited = scratch .. "/ps_edit_" .. math.random(100000, 999999) .. ".ats"
local ed = assert(ats.load("examples/sax.ats"))
for f = 1, ed.frames do ed.amp[3][f] = 0 end                 -- delete partial 3
assert(ats.save(edited, ed, { phase = false }))
run("--cache-dir " .. cache .. " --out " .. out .. " " .. edited)
check("cache: an edit of the partials reuses the noise (still one file)", cache_files() == 1)
local with_edit = read_wav(out)
local full_orig = synth.render(sax, { sines = true, noise = false })
check("cache: and the edited sound is different from the original", math.abs(rms(with_edit[1]) - rms(full_orig)) > 0)
os.remove(edited)
os.execute("rm -rf " .. cache)

-- channels in parallel (one process each) give exactly the sound of one after the other
do
  local a1, a3 = scratch .. "/ps_j1.wav", scratch .. "/ps_j3.wav"
  run("--jobs 1 --out " .. a1 .. " " .. table.concat(three, " "))
  run("--jobs 3 --out " .. a3 .. " " .. table.concat(three, " "))
  local f1 = io.open(a1, "rb"); local d1 = f1:read("a"); f1:close()
  local f3 = io.open(a3, "rb"); local d3 = f3:read("a"); f3:close()
  check("parallel: the same file as one after the other", d1 == d3 and #d1 > 1000)
  local r = read_wav(a3)
  check("parallel: three channels that differ (each has its own noise)", #r == 3 and corr(r[1], r[2]) < 0.9999)
  local msg2 = run("--jobs 2 --out " .. a3 .. " " .. sax_path .. " " .. scratch .. "/does_not_exist.ats")
  check("parallel: an error in one channel is reported", msg2:find("ERROR"), msg2)
  os.remove(a1); os.remove(a3)
end

-- edits not yet in the file: the program reads the file and applies the edited cells (no copy of the whole file is written)
do
  local ed = assert(ats.load("examples/sax.ats"))
  local cells = {}
  for f = 1, ed.frames do ed.amp[3][f] = 0; cells[#cells + 1] = { 3, f }; end
  for f = 20, 90 do ed.frq[7][f] = ed.frq[7][f] * 1.5; cells[#cells + 1] = { 7, f } end       -- partial 7 up a fifth, frames 20-90
  local full_path = scratch .. "/ps_full_" .. math.random(100000, 999999) .. ".ats"
  assert(ats.save(full_path, ed, { phase = false }))
  local ep = scratch .. "/ps_edits_" .. math.random(100000, 999999) .. ".bin"
  local fh = io.open(ep, "wb")
  for _, c in ipairs(cells) do fh:write(string.pack("<dddd", c[1], c[2], ed.amp[c[1]][c[2]], ed.frq[c[1]][c[2]])) end
  fh:close()
  local a, b = scratch .. "/ps_ed_a.wav", scratch .. "/ps_ed_b.wav"
  run("--out " .. a .. " " .. full_path)                                       -- the whole edited data written to a file
  run("--out " .. b .. " --edits " .. ep .. " " .. sax_path)                     -- the original file plus the edits
  local fa = io.open(a, "rb"); local da = fa:read("a"); fa:close()
  local fb = io.open(b, "rb"); local db = fb:read("a"); fb:close()
  check("edits: the original file plus the edits sounds exactly like the edited data written out", da == db and #da > 1000)
  local plain = scratch .. "/ps_ed_c.wav"
  run("--out " .. plain .. " " .. sax_path)
  local fc = io.open(plain, "rb"); local dc = fc:read("a"); fc:close()
  check("edits: and differs from the original", dc ~= db)
  local m2 = run("--out " .. a .. " --edits " .. ep .. " --edits - " .. sax_path)
  check("edits: --edits must be given for every file", m2:find("ERROR"), m2)
  -- edits that ADD ROWS (a paste or a move into rows the file does not have): the program makes them too
  local grown = assert(ats.load("examples/sax.ats"))
  local extra, cells2 = grown.partials + 1, {}
  local ed2 = dofile("lib/ats_edit.lua")
  ed2.add_rows(grown, 2)
  for f = 30, 60 do grown.amp[extra][f] = 0.2; grown.frq[extra][f] = 880 end
  for f = 30, 60 do grown.amp[extra + 1][f] = 0.1; grown.frq[extra + 1][f] = 1320 end
  local full2 = scratch .. "/ps_rows_" .. math.random(100000, 999999) .. ".ats"
  assert(ats.save(full2, grown, { phase = false }))
  local ep2 = scratch .. "/ps_rowedits_" .. math.random(100000, 999999) .. ".bin"
  local fh2 = io.open(ep2, "wb")
  for r = extra, extra + 1 do for f = 30, 60 do fh2:write(string.pack("<dddd", r, f, grown.amp[r][f], grown.frq[r][f])) end end
  fh2:close()
  local ra, rb = scratch .. "/ps_ra.wav", scratch .. "/ps_rb.wav"
  run("--no-noise --out " .. ra .. " " .. full2)
  run("--no-noise --out " .. rb .. " --edits " .. ep2 .. " " .. sax_path)
  local fa2 = io.open(ra, "rb"); local da2 = fa2:read("a"); fa2:close()
  local fb2 = io.open(rb, "rb"); local db2 = fb2:read("a"); fb2:close()
  check("edits: rows that the file does not have are made from the edits", da2 == db2 and #da2 > 1000)
  for _, f in ipairs({ full2, ep2, ra, rb }) do os.remove(f) end
  for _, f in ipairs({ full_path, ep, a, b, plain }) do os.remove(f) end
end

-- edits that make the sound LONGER (a stretch past the end): the program extends the file by the number of frames in the record of partial 0
do
  local ed3 = dofile("lib/ats_edit.lua")
  local base = assert(ats.load("examples/sax.ats"))
  local grown = assert(ats.load("examples/sax.ats"))
  ed3.add_frames(grown, 30)
  for f = 215, 245 do grown.amp[2][f] = 0.15; grown.frq[2][f] = 500 + f end              -- sound in the new frames, in a row the file has
  local full3 = scratch .. "/ps_long_" .. math.random(100000, 999999) .. ".ats"
  assert(ats.save(full3, grown, { phase = false }))
  local ep3 = scratch .. "/ps_longedits_" .. math.random(100000, 999999) .. ".bin"
  local fh3 = io.open(ep3, "wb")
  fh3:write(string.pack("<dddd", 0, grown.frames, grown.dur, 0))                          -- the record: the file now has this many frames
  for f = 215, 245 do fh3:write(string.pack("<dddd", 2, f, grown.amp[2][f], grown.frq[2][f])) end
  fh3:close()
  local la, lb = scratch .. "/ps_la.wav", scratch .. "/ps_lb.wav"
  run("--no-noise --out " .. la .. " " .. full3)
  run("--no-noise --out " .. lb .. " --edits " .. ep3 .. " " .. sax_path)
  local fa3 = io.open(la, "rb"); local da3 = fa3:read("a"); fa3:close()
  local fb3 = io.open(lb, "rb"); local db3 = fb3:read("a"); fb3:close()
  check("longer: the original file plus the edits sounds exactly like the longer data written out", da3 == db3 and #da3 > 1000, #da3 .. " " .. #db3)
  local plain3 = scratch .. "/ps_lc.wav"
  run("--no-noise --out " .. plain3 .. " " .. sax_path)
  local fc3 = io.open(plain3, "rb"); local dc3 = fc3:read("a"); fc3:close()
  check("longer: and the sound is longer than the file's own", #da3 > #dc3, #da3 .. " vs " .. #dc3)
  local noise_full = scratch .. "/ps_ln.wav"
  run("--out " .. noise_full .. " --edits " .. ep3 .. " " .. sax_path)
  local fd = io.open(noise_full, "rb"); local dd = fd:read("a"); fd:close()
  check("longer: with the noise too (zeros after the old end)", #dd == #da3)
  for _, f in ipairs({ full3, ep3, la, lb, plain3, noise_full }) do os.remove(f) end
end

-- edits that put frames IN FRONT (a stretch to before 0): everything of the file is later, the record of partial 0 says by how much
do
  local ed4 = dofile("lib/ats_edit.lua")
  local grown = assert(ats.load("examples/sax.ats"))
  ed4.prepend_frames(grown, 12)
  ed4.add_frames(grown, 5)
  for f = 2, 30 do grown.amp[3][f] = 0.2; grown.frq[3][f] = 400 + f end               -- sound in the new frames at the start
  grown.amp[1][40] = grown.amp[1][40] * 0.5                                              -- and an edit of the file's own sound (it is later by 12 frames)
  local full4 = scratch .. "/ps_front_" .. math.random(100000, 999999) .. ".ats"
  assert(ats.save(full4, grown, { phase = false }))
  local ep4 = scratch .. "/ps_frontedits_" .. math.random(100000, 999999) .. ".bin"
  local fh4 = io.open(ep4, "wb")
  fh4:write(string.pack("<dddd", 0, grown.frames, grown.dur, 12))                       -- the file now has this many frames, 12 of them in front
  for f = 2, 30 do fh4:write(string.pack("<dddd", 3, f, grown.amp[3][f], grown.frq[3][f])) end
  fh4:write(string.pack("<dddd", 1, 40, grown.amp[1][40], grown.frq[1][40]))
  fh4:close()
  local ma, mb = scratch .. "/ps_ma.wav", scratch .. "/ps_mb.wav"
  run("--out " .. ma .. " " .. full4)
  run("--out " .. mb .. " --edits " .. ep4 .. " " .. sax_path)
  local fa4 = io.open(ma, "rb"); local da4 = fa4:read("a"); fa4:close()
  local fb4 = io.open(mb, "rb"); local db4 = fb4:read("a"); fb4:close()
  check("front: the original file plus the edits sounds exactly like the data written out (with noise)", da4 == db4 and #da4 > 1000, #da4 .. " " .. #db4)
  for _, f in ipairs({ full4, ep4, ma, mb }) do os.remove(f) end
end

-- errors are told, not crashes
local msg = run("--out " .. out .. " " .. scratch .. "/does_not_exist.ats")
check("a missing file is reported", msg:find("ERROR"), msg)
msg = run("--no-sines --no-noise --out " .. out .. " " .. sax_path)
check("nothing to render is reported", msg:find("ERROR nothing to render"), msg)

-- the background job, with a fake reaper that starts the program in the background
local clock_skew = 0
reaper = {
  ExecProcess = function(cmd, timeout)
    assert(not cmd:find("@", 1, true), "no @ word: " .. cmd)                    -- (the arguments go in --args-file PATH)
    os.execute(cmd .. " >/dev/null 2>&1 &"); return ""
  end,
  file_exists = function(p) local f = io.open(p, "rb"); if f then f:close(); return true end return false end,
  time_precise = function() return os.clock() + clock_skew end,
}
local function start(extra)
  local o = { exe = "python3", script = script, files = { sax_path }, temp = {}, wav = scratch .. "/ps_job.wav", dir = scratch,
              id = "t" .. math.random(100000, 999999) }
  for k, v in pairs(extra or {}) do o[k] = v end
  os.remove(o.wav)
  return py_synth.start(o), o
end
local function wait(job, limit)
  local t = os.time()
  while not job.step() do
    os.execute("sleep 0.05")
    if os.time() - t > (limit or 30) then return false end
  end
  return true
end
local job, o = start({ sines = true, noise = true })
check("job: finishes", wait(job))
check("job: answer", job.wav == o.wav and job.nchan == 1 and math.abs(job.dur - 2.17) < 0.1 and job.t_start == 0 and job.sr == 44100,
  tostring(job.error) .. " " .. tostring(job.dur))
check("job: the WAV exists", reaper.file_exists(o.wav))
check("job: its files are gone", not reaper.file_exists(scratch .. "/reaats_" .. o.id .. "_synth_result.txt")
  and not reaper.file_exists(scratch .. "/reaats_" .. o.id .. "_synth_result.txt.started"))
os.remove(o.wav)

-- three channels as one background job (they are made in parallel): progress, the answer
do
  local j, oo = start({ files = { sax_path, sax_path, sax_path }, sines = true, noise = true })
  check("job with 3 channels: finishes", wait(j))
  check("job with 3 channels: answer", j.nchan == 3 and not j.error, tostring(j.error))
  os.remove(oo.wav)
end

-- temp .ats files are removed when the job ends
local tmp_ats = scratch .. "/ps_temp_" .. math.random(100000, 999999) .. ".ats"
assert(ats.save(tmp_ats, sax, { phase = false }))
job, o = start({ files = { tmp_ats }, temp = { tmp_ats }, sines = true, noise = false })
check("job with temp file: finishes", wait(job))
check("job: the temporary .ats is deleted", not reaper.file_exists(tmp_ats))
os.remove(o.wav)

-- the folder of the temporary files has a space in its name (the program is started with --args-file "path with space")
do
  local spaced = scratch .. "/dir with space " .. math.random(100000, 999999)
  os.execute("mkdir -p '" .. spaced .. "'")
  local j, oo = start({ dir = spaced, wav = spaced .. "/o.wav", sines = true, noise = false })
  check("job: a folder with a space in its name works", j and wait(j) and not j.error, tostring(j and j.error))
  os.execute("rm -rf '" .. spaced .. "'")
end

-- an error in the program
job = start({ files = { scratch .. "/nope.ats" } })
check("job: error comes back", wait(job) and job.error and job.error:find("nope.ats"), tostring(job.error))

-- cancel
job, o = start({ sines = true, noise = true })
job.cancel()
check("job: cancelled", job.done and job.cancelled)
os.execute("sleep 1")
py_synth.sweep()
check("job: cancelled files are swept", not reaper.file_exists(scratch .. "/reaats_" .. o.id .. "_synth_args.txt"))
os.remove(o.wav)

-- a program that never starts
job = start({ exe = "/nonexistent/python" })
clock_skew = 25
check("job: 'did not start' after 20 s", job.step() and job.error and job.error:find("did not start"), tostring(job.error))
clock_skew = 0

print(string.format("%d passed, %d failed", ok_n, fail_n))
os.exit(fail_n == 0 and 0 or 1)
