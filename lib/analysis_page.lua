-- analysis_page.lua -- the Analysis page of the ReaATS editor: every analysis option in one place, a source (the
-- selected item or a WAV file), and an ANALYSE button that runs python/reaats_analyse.py and opens the result.
--
-- The page is immediate-mode: draw() paints it and records the clickable areas, mouse() acts on them.
-- env (given to M.new): serial (lib/reaats_serial.lua), wav_info (lib/wav_info.lua), script_dir, ext_section,
--   on_open(path) -> boolean   opens an .ats file in the editor
--   set_status(msg)            the status row of the editor
--   redraw()                   paints one frame now (used while the analysis runs)
--   back()                     returns to the editor
-- The options are the ones of docs/analysis_options.md that the Python engine has (not Csound's -T and -S).

local M = {}

-- ------------------------------------------------------------------ the options
local WINDOW_TYPES = { "blackman-exact", "blackman", "blackman-harris-3-1", "blackman-harris-3-2", "blackman-harris-4-1",
  "blackman-harris-4-2", "rectangular", "parzen", "welch", "kaiser", "gaussian", "poisson", "cauchy", "connes",
  "exponential", "bartlett", "riemann", "tukey", "hamming", "hann", "hann-poisson" }
local FFT_SIZES = { 0, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536, 131072 }     -- 0 = automatic

-- kind: num | choice | bool. cli: the engine option; omit_zero: leave the option out when the value is 0.
local FIELDS = {
  start               = { kind = "num", label = "Start", unit = "s", min = 0, max = 1e6, step = 0.1, def = 0, cli = "--start", omit_zero = true,
                          tip = "Where the analysis starts in the sound." },
  duration            = { kind = "num", label = "Duration (0 = to the end)", unit = "s", min = 0, max = 1e6, step = 0.1, def = 0, cli = "--duration", omit_zero = true,
                          tip = "How much of the sound is analysed." },
  channels            = { kind = "num", label = "Channels to analyse", unit = "", min = 1, max = 64, step = 1, def = 1, int = true, cli = "--channels",
                          tip = "Each channel is analysed on its own into its own .ats file (name_ch1.ats, name_ch2.ats, ...)." },
  mono_mix            = { kind = "bool", label = "Mix all channels to mono first", def = false, flag = "--mono-mix",
                          tip = "Analyse the average of all channels as one sound." },
  lowest_frequency    = { kind = "num", label = "Lowest frequency", unit = "Hz", min = 1, max = 20000, step = 5, def = 20, cli = "--lowest-frequency",
                          tip = "The window is 'window cycles' periods of this frequency long. Low = long window." },
  highest_frequency   = { kind = "num", label = "Highest frequency", unit = "Hz", min = 20, max = 96000, step = 100, def = 20000, cli = "--highest-frequency",
                          tip = "Highest frequency analysed (capped at half the sample rate)." },
  window_cycles       = { kind = "num", label = "Window cycles", unit = "", min = 1, max = 64, step = 0.5, def = 4, cli = "--window-cycles",
                          tip = "How many periods of the lowest frequency fit in the window." },
  window_type         = { kind = "choice", label = "Window type", values = WINDOW_TYPES, def = "blackman-harris-4-1", cli = "--window-type",
                          tip = "The FFT window." },
  window_alpha        = { kind = "num", label = "Window alpha (Tukey)", unit = "", min = 0, max = 1, step = 0.05, def = 0.5, cli = "--window-alpha",
                          tip = "Parameter of the Tukey window." },
  window_beta         = { kind = "num", label = "Window beta", unit = "", min = 0, max = 50, step = 0.1, def = 1.0, cli = "--window-beta",
                          tip = "Parameter of windows that take a beta (for example Kaiser)." },
  hop_size            = { kind = "num", label = "Hop size (of the window)", unit = "", min = 0.01, max = 1, step = 0.05, def = 0.25, cli = "--hop-size",
                          tip = "Distance between frames as a fraction of the window." },
  fft_size            = { kind = "choice", label = "FFT size (0 = automatic)", values = FFT_SIZES, def = 0, cli = "--fft-size", omit_zero = true,
                          tip = "Force an FFT size." },
  window_length       = { kind = "num", label = "Window length (0 = automatic)", unit = "samples", min = 0, max = 1e6, step = 64, def = 0, int = true,
                          cli = "--window-length", omit_zero = true, tip = "Force the window length in samples." },
  amp_threshold_db    = { kind = "num", label = "Amplitude threshold", unit = "dB", min = -140, max = 0, step = 1, def = -60, cli = "--amp-threshold-db",
                          tip = "The quietest peak that counts. Raise it for noisy sounds." },
  frequency_deviation = { kind = "num", label = "Frequency deviation", unit = "", min = 0.001, max = 2, step = 0.01, def = 0.1, cli = "--frequency-deviation",
                          tip = "Largest relative frequency change between frames when peaks are matched into a track." },
  track_length        = { kind = "num", label = "Track length", unit = "frames", min = 1, max = 100, step = 1, def = 3, int = true, cli = "--track-length",
                          tip = "Frames used to smooth a track's frequency." },
  min_segment_length  = { kind = "num", label = "Minimum segment length", unit = "frames", min = 1, max = 1000, step = 1, def = 3, int = true, cli = "--min-segment-length",
                          tip = "Shorter track pieces are dropped." },
  min_gap_length      = { kind = "num", label = "Minimum gap length", unit = "frames", min = 1, max = 1000, step = 1, def = 3, int = true, cli = "--min-gap-length",
                          tip = "Longer gaps in a track are not bridged." },
  last_peak_contribution = { kind = "num", label = "Last peak contribution", unit = "", min = 0, max = 1, step = 0.05, def = 0, cli = "--last-peak-contribution",
                          tip = "Extra weight of the previous frame when a track is smoothed." },
  smr_continuity      = { kind = "num", label = "SMR contribution", unit = "", min = 0, max = 1, step = 0.05, def = 0, cli = "--smr-continuity",
                          tip = "Share of the signal-to-mask ratio in the cost of matching a peak (Csound's atsa uses 0.5)." },
  optimize            = { kind = "bool", label = "Optimise (prune) the tracks", def = true, flag_off = "--no-optimize",
                          tip = "Post-processing: drop quiet and short tracks." },
  optimize_threshold_db = { kind = "num", label = "Optimise threshold (0 = off)", unit = "dB", min = -140, max = 0, step = 1, def = 0,
                          cli = "--optimize-amp-threshold-db", omit_zero = true, tip = "Extra amplitude threshold in the pruning." },
  store_phase         = { kind = "bool", label = "Store the phase", def = true, flag_off = "--no-phase",
                          tip = "File type 4 (with noise) instead of 3." },
  store_noise         = { kind = "bool", label = "Store the noise bands", def = true, flag_off = "--no-noise",
                          tip = "The residual and its 25 bands. Off is faster." },
}

local LEFT = { "start", "duration", "channels", "mono_mix", "lowest_frequency", "highest_frequency", "window_cycles",
               "window_type", "window_alpha", "window_beta", "hop_size", "fft_size", "window_length" }
local RIGHT = { "amp_threshold_db", "frequency_deviation", "track_length", "min_segment_length", "min_gap_length",
                "last_peak_contribution", "smr_continuity", "optimize", "optimize_threshold_db" }
local OUTPUT = { "store_phase", "store_noise" }
local ORDER = {}
for _, list in ipairs({ LEFT, RIGHT, OUTPUT }) do for _, k in ipairs(list) do ORDER[#ORDER + 1] = k end end
M.FIELDS, M.WINDOW_TYPES = FIELDS, WINDOW_TYPES

-- ------------------------------------------------------------------ helpers
local function clamp(x, a, b) if x < a then return a elseif x > b then return b else return x end end
local function basename(p) return p:match("([^/\\]+)$") or p end
local function dirname(p) return p:match("^(.*)[/\\]") or "." end
local function stem_ext(p)
  local stem, ext = p:match("^(.*)(%.[^./\\]+)$")
  return stem or p, ext or ""
end
local function fmt_num(v)
  if v == math.floor(v) and math.abs(v) < 1e9 then return string.format("%d", v) end
  return string.format("%.4g", v)
end

function M.default_settings()
  local s = {}
  for key, f in pairs(FIELDS) do s[key] = f.def end
  return s
end

-- The files the engine writes for `n` channels (the same naming as reaats_analyse.py).
function M.output_files(path, n)
  if n <= 1 then return { path } end
  local stem, ext = stem_ext(path)
  local list = {}
  for i = 1, n do list[i] = string.format("%s_ch%d%s", stem, i, ext) end
  return list
end

-- What the window will be like, from the sound and the settings (the same arithmetic as the engine).
function M.derived(s, info)
  if not info then return nil end
  local sr = info.rate
  local m
  if s.window_length > 0 then
    m = s.window_length
  else
    m = math.floor((1 / s.lowest_frequency) * s.window_cycles * sr)
    if m % 2 == 0 then m = m + 1 end
  end
  local hop = math.max(math.floor(m * s.hop_size), 1)
  local fft = (s.fft_size > 0) and s.fft_size or 1
  if s.fft_size <= 0 then while fft < m do fft = fft * 2 end end
  local avail = info.seconds - s.start
  local secs = (s.duration > 0) and math.min(s.duration, avail) or avail
  local total = math.max(math.floor(secs * sr), 0)
  return { window = m, window_ms = m / sr * 1000, hop = hop, hop_ms = hop / sr * 1000, fft = fft,
           frames = math.ceil(total / hop) + 1, seconds = secs, total = total, too_long = (m > total) }
end

-- The engine's command line, one argument per entry (written one per line to an argument file, so nothing needs quoting).
function M.build_args(s, wav, out)
  local a = { wav, out }
  local function add(...) for _, v in ipairs({ ... }) do a[#a + 1] = tostring(v) end end
  for _, key in ipairs(ORDER) do
    local f, v = FIELDS[key], s[key]
    if f.cli and not (f.omit_zero and (v == 0 or v == nil)) then
      if f.kind == "num" and f.int then v = math.floor(v + 0.5) end
      add(f.cli, (type(v) == "number") and fmt_num(v) or v)
    elseif f.flag and v then
      add(f.flag)
    elseif f.flag_off and not v then
      add(f.flag_off)
    end
  end
  add("--summary-format", "lua")
  return a
end

local function find_python()
  for _, c in ipairs({ "/usr/bin/python3", "/usr/local/bin/python3", "/opt/homebrew/bin/python3" }) do
    if reaper.file_exists(c) then return c end
  end
  return "python3"
end

-- ------------------------------------------------------------------ the page
local Page = {}
Page.__index = Page

function M.new(env)
  local self = setmetatable({}, Page)
  self.env = env
  self.s = M.default_settings()
  self.wav, self.info, self.out, self.out_custom = nil, nil, nil, false
  self.message, self.message_bad = nil, false
  self.result = nil
  self.hits = {}
  self.prev_down = false
  self.busy = false
  -- remembered settings
  local saved = reaper.GetExtState(env.ext_section, "analysis_settings")
  if saved ~= "" then
    local t = env.serial.deserialize(saved)
    if type(t) == "table" then
      for key, f in pairs(FIELDS) do
        local v = t[key]
        if f.kind == "num" and type(v) == "number" then self.s[key] = clamp(v, f.min, f.max)
        elseif f.kind == "bool" and type(v) == "boolean" then self.s[key] = v
        elseif f.kind == "choice" and v ~= nil then
          for _, c in ipairs(f.values) do if c == v then self.s[key] = v end end
        end
      end
    end
  end
  return self
end

function Page:say(msg, bad) self.message, self.message_bad = msg, bad or false end

function Page:save_settings()
  local ok, enc = pcall(self.env.serial.serialize, self.s)
  if ok then reaper.SetExtState(self.env.ext_section, "analysis_settings", enc, true) end
end

local function unique_out(wav)
  local stem = stem_ext(wav)
  local path = stem .. ".ats"
  local n = 2
  while reaper.file_exists(path) do
    path = string.format("%s_%d.ats", stem, n)
    n = n + 1
  end
  return path
end

function Page:set_source(wav)
  local info, err = self.env.wav_info.read(wav)
  if not info then
    self.wav, self.info = nil, nil
    self:say("Cannot use this file: " .. tostring(err), true)
    return false
  end
  self.wav, self.info, self.result = wav, info, nil
  self.s.channels = clamp(self.s.channels, 1, info.channels)
  if not self.out_custom then self.out = unique_out(wav) end
  self:say(nil)
  return true
end

function Page:use_selected_item()
  local item = reaper.GetSelectedMediaItem(0, 0)
  if not item then self:say("Select an item in REAPER first.", true); return end
  local take = reaper.GetActiveTake(item)
  if not take or reaper.TakeIsMIDI(take) then self:say("The selected item has no audio take.", true); return end
  local src = reaper.GetMediaItemTake_Source(take)
  local path = reaper.GetMediaSourceFileName(src, "")
  if not path:lower():match("%.wav$") then
    self:say("The item's file is not a WAV (" .. basename(path) .. "). Render it to WAV first (Glue, or File > Render) and select the new item.", true)
    return
  end
  if not self:set_source(path) then return end
  local offs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
  local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local rate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
  self.s.start = offs
  self.s.duration = len * ((rate and rate > 0) and rate or 1)
  self.out_custom = false
  self.out = unique_out(path)
  self:say("Item: the part of the file the item plays is analysed. Item volume, fades, FX and pitch are not applied.")
end

function Page:choose_file()
  local ok, path = reaper.GetUserFileNameForRead(self.wav or "", "Choose a WAV file to analyse", "wav")
  if ok and path and path ~= "" then
    self.s.start, self.s.duration = 0, 0
    self:set_source(path)
  end
end

function Page:choose_output()
  if not self.wav then return end
  local suggested = self.out or unique_out(self.wav)
  local path
  if reaper.JS_Dialog_BrowseForSaveFile then
    local rv, chosen = reaper.JS_Dialog_BrowseForSaveFile("Analysis result (.ats)", dirname(suggested), basename(suggested),
      "ATS files (*.ats)\0*.ats\0All files (*.*)\0*.*\0\0")
    if rv ~= 1 or not chosen or chosen == "" then return end
    path = chosen
  else
    local ok, text = reaper.GetUserInputs("Analysis result", 1, "full path of the .ats file,extrawidth=420", suggested)
    if not ok or text == "" then return end
    path = text
  end
  if not path:lower():match("%.ats$") then path = path .. ".ats" end
  self.out, self.out_custom = path, true
end

function Page:set_defaults(csound)
  local keep = { channels = self.s.channels, mono_mix = self.s.mono_mix, start = self.s.start, duration = self.s.duration }
  self.s = M.default_settings()
  for k, v in pairs(keep) do self.s[k] = v end
  if csound then self.s.smr_continuity = 0.5 end            -- the one default that differs from the Python package
  self:say(csound and "Csound atsa defaults (its SMR contribution is 0.5)." or "Defaults of the Python engine.")
end

function Page:edit_num(key)
  local f = FIELDS[key]
  local ok, text = reaper.GetUserInputs(f.label, 1, (f.unit ~= "" and f.unit or "value") .. ",extrawidth=60", fmt_num(self.s[key]))
  if not ok then return end
  local v = tonumber(text)
  if not v then self:say("'" .. text .. "' is not a number.", true); return end
  v = clamp(v, f.min, f.max)
  if f.int then v = math.floor(v + 0.5) end
  self.s[key] = v
end

function Page:pick_choice(key)
  local f = FIELDS[key]
  local items, current = {}, 0
  for i, v in ipairs(f.values) do
    local label = (v == 0) and "automatic" or tostring(v)
    items[i] = (v == self.s[key]) and ("!" .. label) or label
    if v == self.s[key] then current = i end
  end
  gfx.x, gfx.y = gfx.mouse_x, gfx.mouse_y
  local n = gfx.showmenu(table.concat(items, "|"))
  if n and n > 0 then self.s[key] = f.values[n] end
end

function Page:step(key, notches, fine)
  local f = FIELDS[key]
  if f.kind == "num" then
    local st = f.step * (fine and 0.1 or 1)
    local v = self.s[key] + notches * st
    if f.int then v = math.floor(v + 0.5) end
    self.s[key] = clamp(tonumber(string.format("%.6g", v)), f.min, f.max)
  elseif f.kind == "choice" then
    local idx = 1
    for i, v in ipairs(f.values) do if v == self.s[key] then idx = i end end
    self.s[key] = f.values[clamp(idx + (notches > 0 and 1 or -1), 1, #f.values)]
  end
end

-- ------------------------------------------------------------------ running the engine
function Page:validate()
  if not self.wav or not self.info then return "Choose the sound first: use the selected item or choose a WAV file." end
  local s = self.s
  if s.highest_frequency <= s.lowest_frequency then return "The highest frequency must be above the lowest frequency." end
  if s.channels > self.info.channels and not s.mono_mix then
    return string.format("The file has %d channel(s); 'Channels to analyse' is %d.", self.info.channels, s.channels)
  end
  if s.start >= self.info.seconds then return "The start is beyond the end of the sound." end
  return nil
end

function Page:run()
  local bad = self:validate()
  if bad then self:say(bad, true); return end
  local s, info = self.s, self.info
  local n = s.mono_mix and 1 or s.channels
  local out = self.out or unique_out(self.wav)
  for _, p in ipairs(M.output_files(out, n)) do
    if reaper.file_exists(p) and self.out_custom then
      if reaper.MB("Replace this file?\n\n" .. p, "ReaATS: analysis", 4) ~= 6 then self:say("Not analysed (the file was kept)."); return end
    end
  end
  local dir = (os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "")
  local argsfile = dir .. "/reaats_analysis_args.txt"
  local fh = io.open(argsfile, "w")
  if not fh then self:say("Cannot write " .. argsfile, true); return end
  fh:write(table.concat(M.build_args(s, self.wav, out), "\n"), "\n")
  fh:close()
  local engine = self.env.script_dir .. "/python/reaats_analyse.py"
  if not reaper.file_exists(engine) then self:say("The analysis program is missing: " .. engine, true); return end
  self.busy = true
  self:say("Analysing ... REAPER waits until it is done.")
  self.env.redraw()
  local t0 = reaper.time_precise()
  local function q(path) return path:find("%s") and ('"' .. path .. '"') or path end      -- quote only when needed
  local reply = reaper.ExecProcess(string.format("%s %s @%s", q(find_python()), q(engine), q(argsfile)), 600000)
  local took = reaper.time_precise() - t0
  self.busy = false
  os.remove(argsfile)
  reply = reply or ""
  local result_text = reply:match("RESULT (%b{})")
  local summary = result_text and self.env.serial.deserialize(result_text)
  if type(summary) ~= "table" or type(summary.files) ~= "table" or #summary.files == 0 then
    local err = reply:match("ERROR ([^\n]*)")
    if not err then
      if reply:find("No module named") then
        err = "Python needs the numpy package (for example: python3 -m pip install numpy)."
      elseif reply == "" then
        err = "The analysis program did not answer. Is Python 3 installed?"
      else
        err = (reply:gsub("%s+", " "):sub(1, 220))
      end
    end
    self:say("Analysis failed: " .. err, true)
    return
  end
  summary.seconds_taken = took
  self.result = summary
  self:save_settings()
  local first = summary.files[1]
  local opened = self.env.on_open(first.file)
  self:say(string.format("Analysed in %.1f s: %d file(s). %s", took, #summary.files,
    opened and ("Channel 1 is open in the editor (" .. basename(first.file) .. ").") or "The first file could not be opened."), not opened)
  self.env.set_status(string.format("analysed %s: %d partials, %d frames (%.1f s)", basename(first.file), first.partials, first.frames, took))
end

-- ------------------------------------------------------------------ drawing
local function text(x, y, s, r, g, b, a)
  gfx.set(r or 0.85, g or 0.87, b or 0.9, a or 1)
  gfx.x, gfx.y = x, y
  gfx.drawstr(s)
end

function Page:button(x, y, w, h, label, rgb, action)
  gfx.set(rgb[1], rgb[2], rgb[3], 1)
  gfx.rect(x, y, w, h, 1)
  gfx.set(rgb[1] + 0.25, rgb[2] + 0.25, rgb[3] + 0.25, 1)
  gfx.rect(x, y, w, h, 0)
  gfx.setfont(1, "Arial", 14)
  gfx.set(1, 1, 1, 1)
  gfx.x = x + (w - gfx.measurestr(label)) / 2
  gfx.y = y + (h - 14) / 2 - 1
  gfx.drawstr(label)
  self.hits[#self.hits + 1] = { x = x, y = y, w = w, h = h, click = action }
end

function Page:field(x, y, key, label_w, box_w)
  local f = FIELDS[key]
  local v = self.s[key]
  gfx.setfont(1, "Arial", 14)
  text(x, y + 3, f.label, 0.8, 0.82, 0.86)
  local bx = x + label_w
  if f.kind == "bool" then
    gfx.set(0.4, 0.43, 0.48, 1); gfx.rect(bx, y + 2, 16, 16, 0)
    if v then gfx.set(0.45, 0.8, 0.6, 1); gfx.rect(bx + 3, y + 5, 10, 10, 1) end
    self.hits[#self.hits + 1] = { x = x, y = y, w = label_w + 30, h = 20, click = function() self.s[key] = not self.s[key] end, tip = f.tip }
    return
  end
  gfx.set(0.14, 0.16, 0.19, 1); gfx.rect(bx, y, box_w, 20, 1)
  gfx.set(0.4, 0.43, 0.48, 1); gfx.rect(bx, y, box_w, 20, 0)
  local shown
  if f.kind == "choice" then shown = (v == 0) and "automatic" or tostring(v) else shown = fmt_num(v) end
  gfx.set(1, 0.9, 0.6, 1)
  gfx.x, gfx.y = bx + 6, y + 3
  gfx.drawstr(shown)
  if f.kind == "num" and f.unit ~= "" then text(bx + box_w + 6, y + 3, f.unit, 0.55, 0.58, 0.63) end
  self.hits[#self.hits + 1] = {
    x = bx, y = y, w = box_w, h = 20, tip = f.tip,
    click = function() if f.kind == "num" then self:edit_num(key) else self:pick_choice(key) end end,
    wheel = function(notches, fine) self:step(key, notches, fine) end,
  }
end

function Page:heading(x, y, label)
  gfx.setfont(1, "Arial", 15)
  text(x, y, label, 0.55, 0.68, 0.92)
  gfx.set(0.55, 0.68, 0.92, 0.5)
  gfx.line(x, y + 19, x + 480, y + 19)
end

function Page:draw(W, H, top)
  self.hits = {}
  gfx.set(0.09, 0.10, 0.12, 1)
  gfx.rect(0, top, W, H - top, 1)
  local colw = math.floor((W - 60) / 2)
  local lx, rx = 24, 24 + colw + 12
  local y = top + 6
  gfx.setfont(1, "Arial", 17)
  text(lx, y, "ANALYSIS: make .ats files from a sound", 1, 1, 1)
  y = y + 28

  -- left column: source, then window and time
  self:heading(lx, y, "SOURCE")
  local ly = y + 26
  self:button(lx, ly, 160, 24, "Use selected item", { 0.18, 0.34, 0.26 }, function() self:use_selected_item() end)
  self:button(lx + 170, ly, 180, 24, "Choose WAV file...", { 0.2, 0.26, 0.4 }, function() self:choose_file() end)
  ly = ly + 32
  gfx.setfont(1, "Arial", 13)
  if self.wav then
    text(lx, ly, "File: " .. (basename(self.wav)), 0.9, 0.9, 0.9)
    local i = self.info
    text(lx, ly + 16, string.format("%d Hz, %d channel(s), %d bit%s, %.2f s", i.rate, i.channels, i.bits, i.float and " float" or "", i.seconds), 0.6, 0.63, 0.68)
  else
    text(lx, ly, "No sound chosen yet.", 0.95, 0.8, 0.5)
  end
  ly = ly + 40
  self:heading(lx, ly, "WINDOW AND TIME")
  ly = ly + 26
  for _, key in ipairs(LEFT) do
    self:field(lx, ly, key, 210, 120)
    ly = ly + 25
  end

  -- right column: peaks and tracks, output, derived values, buttons, result
  local ry = y
  self:heading(rx, ry, "PEAKS AND TRACKS")
  ry = ry + 26
  for _, key in ipairs(RIGHT) do
    self:field(rx, ry, key, 210, 120)
    ry = ry + 25
  end
  ry = ry + 6
  self:heading(rx, ry, "OUTPUT")
  ry = ry + 26
  for _, key in ipairs(OUTPUT) do
    self:field(rx, ry, key, 210, 120)
    ry = ry + 25
  end
  gfx.setfont(1, "Arial", 13)
  text(rx, ry + 2, "Result: " .. (self.out and basename(self.out) or "(after choosing a sound)"), 0.8, 0.82, 0.86)
  self:button(rx + 330, ry - 1, 150, 22, "Change...", { 0.2, 0.26, 0.4 }, function() self:choose_output() end)
  ry = ry + 30

  local d = M.derived(self.s, self.info)
  if d then
    local warn = d.too_long
    text(rx, ry, string.format("Window %d samples (%.0f ms), FFT %d, hop %d samples (%.0f ms), about %d frames", d.window, d.window_ms, d.fft, d.hop, d.hop_ms, d.frames),
      warn and 1 or 0.7, warn and 0.7 or 0.75, warn and 0.5 or 0.8)
    if warn then text(rx, ry + 16, "The window is longer than the part analysed: raise the lowest frequency.", 1, 0.7, 0.5) end
  end
  ry = ry + 38
  self:button(rx, ry, 130, 30, self.busy and "ANALYSING..." or "ANALYSE", { 0.18, 0.42, 0.3 }, function() if not self.busy then self:run() end end)
  self:button(rx + 140, ry, 110, 30, "Defaults", { 0.25, 0.27, 0.32 }, function() self:set_defaults(false) end)
  self:button(rx + 260, ry, 130, 30, "Csound defaults", { 0.25, 0.27, 0.32 }, function() self:set_defaults(true) end)
  self:button(rx + 400, ry, 80, 30, "BACK", { 0.4, 0.22, 0.2 }, function() self.env.back() end)
  ry = ry + 40

  gfx.setfont(1, "Arial", 13)
  if self.message then
    local r, g, b = 0.6, 0.95, 0.6
    if self.message_bad then r, g, b = 1, 0.6, 0.5 end
    -- wrap to the column
    local line, lines = "", {}
    for word in self.message:gmatch("%S+") do
      if gfx.measurestr(line .. " " .. word) > colw then lines[#lines + 1] = line; line = word else line = (line == "") and word or (line .. " " .. word) end
    end
    lines[#lines + 1] = line
    for i, l in ipairs(lines) do text(rx, ry + (i - 1) * 16, l, r, g, b) end
    ry = ry + #lines * 16 + 6
  end
  if self.result then
    for _, f in ipairs(self.result.files) do
      text(rx, ry, string.format("channel %s: %s  (%d partials, %d frames, %.2f s)", tostring(f.channel), basename(f.file), f.partials, f.frames, f.duration), 0.85, 0.87, 0.9)
      local file = f.file
      self:button(rx + 400, ry - 3, 80, 20, "Open", { 0.2, 0.26, 0.4 }, function()
        if self.env.on_open(file) then self:say("Opened " .. basename(file) .. " in the editor.") else self:say("Could not open " .. basename(file), true) end
      end)
      ry = ry + 24
    end
  end
  -- hover tip at the bottom
  local mx, my = gfx.mouse_x, gfx.mouse_y
  for i = #self.hits, 1, -1 do
    local h = self.hits[i]
    if h.tip and mx >= h.x and mx < h.x + h.w and my >= h.y and my < h.y + h.h then
      gfx.setfont(1, "Arial", 13)
      text(lx, H - 24, h.tip, 0.7, 0.78, 0.9)
      break
    end
  end
  gfx.setfont(1, "Arial", 12)
  text(lx, H - 42, "Click a value to type it; the mouse wheel changes it (Shift: finer). Esc goes back to the editor.", 0.5, 0.53, 0.58)
end

-- Mouse state from the editor each frame. Returns true when the page used the click.
function Page:mouse(mx, my, cap, wheel)
  local used = false
  local down = (cap & 1) ~= 0
  if wheel ~= 0 then
    for i = #self.hits, 1, -1 do
      local h = self.hits[i]
      if h.wheel and mx >= h.x and mx < h.x + h.w and my >= h.y and my < h.y + h.h then
        h.wheel(wheel / 120, (cap & 8) ~= 0)
        used = true
        break
      end
    end
  end
  if down and not self.prev_down then
    for i = #self.hits, 1, -1 do
      local h = self.hits[i]
      if h.click and mx >= h.x and mx < h.x + h.w and my >= h.y and my < h.y + h.h then
        h.click()
        used = true
        break
      end
    end
  end
  self.prev_down = down
  return used
end

return M
