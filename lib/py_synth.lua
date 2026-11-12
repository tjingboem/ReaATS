-- py_synth.lua -- runs python/reaats_synth.py in the background (ExecProcess) and follows it through its files, so that the
-- editor can keep drawing. The job has the same shape as the jobs of ats_synth.lua: job.step(budget) -> done?, job.progress
-- 0..1, job.cancel(); when done: job.wav (the file written), job.t_start, job.dur, job.sr, job.nchan, or job.error.
-- Every job has files of its own (a second editor or the analysis must never read or delete them).
local M = {}

local function q(s) s = tostring(s); return s:find("%s") and ('"' .. s .. '"') or s end         -- quote only when needed (as the Analysis page does)

local function read_all(path)
  local fh = io.open(path, "r")
  if not fh then return nil end
  local t = fh:read("a")
  fh:close()
  return t
end

local orphans = {}               -- cancelled jobs whose program may still be running: their files are removed later

-- Removes the files of cancelled jobs once their program has answered (or after a minute). Called every frame; cheap.
function M.sweep()
  if #orphans == 0 then return end
  local now = os.time()
  for i = #orphans, 1, -1 do
    local o = orphans[i]
    if reaper.file_exists(o.result) or now - o.t > 60 then
      for _, f in ipairs(o.files) do os.remove(f) end
      table.remove(orphans, i)
    end
  end
end

-- opts: exe, script, files (the .ats files, one per channel), temp (those of the files to delete afterwards), wav, dir, id,
-- from, to, sines, noise, seed, mixdown ("stereo" or nil), spatial ({ mode = "pseudo"|"vbap", amount, channels } or nil). Returns the job, or nil and a message.
function M.start(opts)
  local result = string.format("%s/reaats_%s_synth_result.txt", opts.dir, opts.id)
  local argsfile = string.format("%s/reaats_%s_synth_args.txt", opts.dir, opts.id)
  local own = { result, result .. ".started", result .. ".cancel", result .. ".tmp", argsfile }
  for _, f in ipairs(own) do os.remove(f) end
  local args = { "--out", opts.wav, "--result-file", result, "--seed", tostring(opts.seed or 12345) }
  if opts.from and opts.from > 0 then args[#args + 1] = "--from"; args[#args + 1] = string.format("%.9f", opts.from) end
  if opts.to and opts.to > 0 then args[#args + 1] = "--to"; args[#args + 1] = string.format("%.9f", opts.to) end
  if opts.sines == false then args[#args + 1] = "--no-sines" end
  if opts.phase == false then args[#args + 1] = "--no-phase" end
  if opts.noise == false then args[#args + 1] = "--no-noise" end
  if opts.cache_dir then args[#args + 1] = "--cache-dir"; args[#args + 1] = opts.cache_dir end
  if opts.mixdown then args[#args + 1] = "--mixdown"; args[#args + 1] = opts.mixdown end
  if opts.spatial and opts.spatial.mode ~= "off" then
    args[#args + 1] = "--spatial"; args[#args + 1] = opts.spatial.mode
    args[#args + 1] = "--spatial-amount"; args[#args + 1] = string.format("%.4f", opts.spatial.amount or 1)
    args[#args + 1] = "--spatial-channels"; args[#args + 1] = tostring(opts.spatial.channels or 2)
  end
  if opts.select then for i = 1, #opts.files do args[#args + 1] = "--select"; args[#args + 1] = opts.select[i] or "-" end end
  if opts.edits then for i = 1, #opts.files do args[#args + 1] = "--edits"; args[#args + 1] = opts.edits[i] or "-" end end
  for _, f in ipairs(opts.files) do args[#args + 1] = f end
  local fh = io.open(argsfile, "w")
  if not fh then return nil, "cannot write " .. argsfile end
  fh:write(table.concat(args, "\n"), "\n")
  fh:close()
  reaper.ExecProcess(string.format("%s %s --args-file %s", q(opts.exe), q(opts.script), q(argsfile)), -1)

  local job = { progress = 0, done = false, wav = opts.wav }
  local t0, seen, cancelled_at = reaper.time_precise(), false, nil
  local function files_to_remove()
    local list = { table.unpack(own) }
    for _, f in ipairs(opts.temp or {}) do list[#list + 1] = f end
    return list
  end
  local function finish(err)
    for _, f in ipairs(files_to_remove()) do os.remove(f) end
    if err then job.error = err end
    job.done = true
  end
  function job.step()
    if job.done then return true end
    if reaper.file_exists(result) then
      local reply = read_all(result) or ""
      local t_start, dur, sr, nch, gain = reply:match("^OK (%S+) (%S+) (%S+) (%S+) ?(%S*)")
      if t_start and reaper.file_exists(opts.wav) then
        job.t_start, job.dur, job.sr, job.nchan, job.progress = tonumber(t_start), tonumber(dur), tonumber(sr), tonumber(nch), 1
        job.gain_db = tonumber(gain) or 0                                 -- how far the sound was turned down to stay under the peak limit (0: not)
        finish(nil)
      else
        local msg = reply:match("ERROR ([^\n]*)") or (reply == "" and "the synthesis program gave no answer" or reply:gsub("%s+", " "):sub(1, 200))
        finish(msg)
      end
      return true
    end
    local text = read_all(result .. ".started")
    local p, stamp = (text or ""):match("^(%S+)%s+(%S+)")
    p, stamp = tonumber(p), tonumber(stamp)
    if p then job.progress, seen = p, true end
    if stamp then job.beat = stamp end
    local now = reaper.time_precise()
    if not seen and now - t0 > 20 then finish("the synthesis program did not start")
    elseif job.beat and os.time() - job.beat > 30 then finish("the synthesis program stopped answering")
    elseif now - t0 > 1800 then finish("the synthesis took more than 30 minutes and was given up") end
    return job.done
  end
  function job.cancel()
    if job.done then return end
    local cf = io.open(result .. ".cancel", "w")
    if cf then cf:write("stop"); cf:close() end
    orphans[#orphans + 1] = { result = result, files = files_to_remove(), t = os.time() }
    job.done, job.cancelled = true, true
  end
  return job
end

return M
