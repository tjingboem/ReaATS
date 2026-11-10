-- analysis_page.lua -- the Analysis page of the ReaATS editor: every analysis option in one place, a source (the
-- selected item or a sound file: WAV, AIFF or FLAC), and an ANALYSE button that runs python/reaats_analyse.py and opens the result.
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
  jobs                = { kind = "num", label = "CPU cores (0 = automatic)", unit = "", min = 0, max = 256, step = 1, def = 0, int = true,
                          cli = "--jobs", omit_zero = true,
                          tip = "Channels are analysed at the same time, one per core. Automatic uses all cores but two (at least one). A single channel uses one core." },
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
  pack_rows           = { kind = "bool", label = "Share rows between tracks", def = true, flag_off = "--no-pack-rows",
                          tip = "Tracks that do not overlap in time use the same partial row. The sound is the same; the file of a long sound is 20 to 100 times smaller. Off gives every track its own row (the original ATS way)." },
}

local LEFT = { "start", "duration", "channels", "mono_mix", "lowest_frequency", "highest_frequency", "window_cycles",
               "window_type", "window_alpha", "window_beta", "hop_size", "fft_size", "window_length", "jobs" }
local RIGHT = { "amp_threshold_db", "frequency_deviation", "track_length", "min_segment_length", "min_gap_length",
                "last_peak_contribution", "smr_continuity", "optimize", "optimize_threshold_db" }
local OUTPUT = { "store_phase", "store_noise", "pack_rows" }
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

-- A length in seconds as minutes:seconds, for sounds of a minute or more ("8:56"); "" for shorter ones.
function M.clock(seconds)
  local total = math.floor((seconds or 0) + 0.5)
  if total < 60 then return "" end
  local h = total // 3600
  if h > 0 then return string.format("%d:%02d:%02d", h, (total % 3600) // 60, total % 60) end
  return string.format("%d:%02d", total // 60, total % 60)
end

-- The files the engine writes for `n` channels (the same naming as reaats_analyse.py).
function M.output_files(path, n)
  if n <= 1 then return { path } end
  local stem, ext = stem_ext(path)
  local list = {}
  for i = 1, n do list[i] = string.format("%s_ch%d%s", stem, i, ext) end
  return list
end

-- How many channels are analysed at the same time (the same rule as the engine): the number asked for, or all cores but two,
-- never more than the number of channels and never fewer than one.
function M.workers(s, cores, channels)
  local count = s.mono_mix and 1 or (channels or s.channels)
  local jobs = (s.jobs and s.jobs > 0) and s.jobs or math.max(1, (cores or 1) - 2)
  return math.max(1, math.min(jobs, count))
end

-- A long sound with a low amplitude threshold finds thousands of tiny partials (mostly noise) and can take hours: measured on
-- a 9 minute recording, 30 s took 52 s at -60 dB, 18 s at -50 dB, 10 s at -40 dB and 5 s at -30 dB. Returns a warning or nil.
function M.long_warning(s, info)
  if not info then return nil end
  local secs = (s.duration > 0) and math.min(s.duration, info.seconds - s.start) or (info.seconds - s.start)
  if secs > 90 and s.amp_threshold_db < -45 then
    return "Long sound, low threshold: this can take very long. Try -40 dB, or a shorter part."
  end
  return nil
end

-- Settings that make a good part of the sound end up in the noise bands (which then sound too loud), for a sound that is not very long.
-- Returns a line of advice or nil. (The page remembers its settings: -40 dB, chosen for a long recording, stays for the next sound.)
function M.noise_advice(s, info)
  if not info or s.mono_mix == nil then return nil end
  local secs = (s.duration > 0) and math.min(s.duration, info.seconds - s.start) or (info.seconds - s.start)
  local reasons = {}
  if secs <= 120 and s.amp_threshold_db > -55 then
    reasons[#reasons + 1] = string.format("a threshold of %d dB leaves out the quieter partials", s.amp_threshold_db)
  end
  if s.highest_frequency < 0.7 * (info.rate / 2) and s.highest_frequency < 15000 then
    reasons[#reasons + 1] = string.format("nothing above %d Hz is followed as partials", math.floor(s.highest_frequency))
  end
  if #reasons == 0 then return nil end
  return "Noise: " .. table.concat(reasons, " and ") .. "; that sound ends up in the noise bands and the noise will be loud. Try -60 dB and 20000 Hz."
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
function M.build_args(s, wav, out, result_file)
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
  if result_file then add("--result-file", result_file) end
  return a
end

-- ------------------------------------------------------------------ finding Python
M.PYTHON_URL = "https://www.python.org/downloads/"
M.MIN_PYTHON = "3.8"

-- Where a Python program could be, best first: the one REAPER is set to use for ReaScript (Preferences > Plug-ins >
-- ReaScript: reaper.ini has pythonlibpath64 and pythonlibdll64), then the usual places. `ini_text` is the text of
-- reaper.ini, `os_name` what reaper.GetOS() says. Pure, so it can be tested.
function M.python_candidates(ini_text, os_name, remembered)
  local list, seen = {}, {}
  local function add(path)
    if path and path ~= "" and not seen[path] then seen[path] = true; list[#list + 1] = path end
  end
  add(remembered)
  local libpath = (ini_text or ""):match("\npythonlibpath64=([^\r\n]*)")
  local libdll = (ini_text or ""):match("\npythonlibdll64=([^\r\n]*)")
  local win = os_name and os_name:find("Win") ~= nil
  local mac = os_name and os_name:find("OSX") ~= nil
  local version = libdll and (libdll:match("python(%d+%.%d+)") or libdll:match("python(%d)(%d%d)")) or nil
  if libdll and not libdll:match("python%d+%.%d+") then
    local a, b = libdll:match("python(%d)(%d%d?)")      -- python312.dll -> 3.12
    if a then version = a .. "." .. b end
  end
  if libpath and libpath ~= "" then
    local dir = libpath:gsub("[/\\]+$", "")
    local sep = win and "\\" or "/"
    if win then
      add(dir .. sep .. "python.exe")
      add(dir .. sep .. ".." .. sep .. "python.exe")
    else
      if version then add(dir .. "/python" .. version) end
      add(dir .. "/python3")
      add(dir .. "/../bin/python3")
      if version then add(dir .. "/../bin/python" .. version) end
    end
  end
  if win then
    add("python.exe"); add("python3.exe"); add("py.exe")
  elseif mac then
    add("/opt/homebrew/bin/python3"); add("/usr/local/bin/python3"); add("/usr/bin/python3"); add("python3")
  else
    if version then add("/usr/bin/python" .. version) end
    add("/usr/bin/python3"); add("/usr/local/bin/python3"); add("python3")
  end
  return list
end

-- The text of the popup when no usable Python is found. `problem` is "none", "numpy" or "old"; `found` the Python seen.
function M.python_help_text(problem, found)
  local lines = {}
  if problem == "numpy" then
    lines[#lines + 1] = "ReaATS found Python" .. (found and (" (" .. found .. ")") or "") .. ", but it does not have the numpy package that the analysis needs."
  elseif problem == "old" then
    lines[#lines + 1] = "ReaATS found Python" .. (found and (" (" .. found .. ")") or "") .. ", but that version is too old."
  else
    lines[#lines + 1] = "ReaATS could not find Python. The analysis needs it."
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "What to do:"
  lines[#lines + 1] = "1. Download Python " .. M.MIN_PYTHON .. " or newer (64-bit) from " .. M.PYTHON_URL .. " and install it."
  lines[#lines + 1] = "    On Windows, tick 'Add python.exe to PATH' in the installer."
  lines[#lines + 1] = "2. Install numpy: open a terminal and run   python3 -m pip install numpy   (on Windows: python -m pip install numpy)."
  lines[#lines + 1] = "3. Tell REAPER where Python is: Options > Preferences > Plug-ins > ReaScript. Tick 'Enable Python for use with ReaScript'"
  lines[#lines + 1] = "    and fill in the folder of the Python you installed (and the Python file in the field below it). ReaATS uses that setting"
  lines[#lines + 1] = "    to find Python. Then restart REAPER."
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Open the download page now?"
  return table.concat(lines, "\n")
end

local function open_url(url)
  if reaper.CF_ShellExecute then reaper.CF_ShellExecute(url); return end
  local os_name = reaper.GetOS and reaper.GetOS() or ""
  if os_name:find("Win") then reaper.ExecProcess('cmd.exe /c start "" "' .. url .. '"', -1)
  elseif os_name:find("OSX") then reaper.ExecProcess("open " .. url, -1)
  else reaper.ExecProcess("xdg-open " .. url, -1) end
end
M.open_url = open_url

local function q(path) return path:find("%s") and ('"' .. path .. '"') or path end      -- quote only when needed

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
  math.randomseed(os.time() + math.floor(reaper.time_precise() * 1000))      -- (once: the job ids are drawn from this)
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

-- Finds a Python that can run the engine; remembers it. Returns true, or false after setting self.python_problem.
function Page:find_python(force)
  if self.python and not force then return true end
  local engine = self.env.script_dir .. "/python/reaats_analyse.py"
  local ini = ""
  if reaper.get_ini_file then
    local fh = io.open(reaper.get_ini_file(), "r")
    if fh then ini = "\n" .. fh:read("a"); fh:close() end
  end
  local remembered = (not force) and reaper.GetExtState(self.env.ext_section, "python_exe") or nil
  local problem, found = "none", nil
  for _, exe in ipairs(M.python_candidates(ini, reaper.GetOS and reaper.GetOS() or "Linux64", remembered)) do
    local absolute = exe:find("[/\\]") ~= nil
    if not absolute or reaper.file_exists(exe) then
      local reply = reaper.ExecProcess(string.format("%s %s --check", q(exe), q(engine)), 20000) or ""
      local status, py, extra = reply:match("CHECK (%a+) ?(%S*) ?(%S*)")
      local version = reply:match("python=(%S+)")
      if status == "ok" then
        self.python = { exe = exe, version = version, numpy = reply:match("numpy=(%S+)"), cores = tonumber(reply:match("cores=(%d+)")) }
        self.python_problem = nil
        reaper.SetExtState(self.env.ext_section, "python_exe", exe, true)
        return true
      elseif status == "missing" then
        problem, found = "numpy", "Python " .. tostring(version)
      elseif status == "old" and problem == "none" then
        problem, found = "old", "Python " .. tostring(version)
      end
    end
  end
  self.python = nil
  self.python_problem = { kind = problem, found = found }
  return false
end

-- The popup: what is missing, what to install, and an offer to open the download page.
function Page:python_popup()
  local pr = self.python_problem or { kind = "none" }
  local answer = reaper.MB(M.python_help_text(pr.kind, pr.found), "ReaATS: Python is needed for the analysis", 4)
  if answer == 6 then open_url(M.PYTHON_URL) end
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
  self.pre, self.suggest, self.view = nil, nil, nil                 -- (what was seen of the previous sound)
  self.s.channels = info.channels                          -- a new sound: analyse all its channels (lower it by hand if you want fewer)
  if not self.out_custom then self.out = unique_out(wav) end
  self:say(nil)
  return true
end

-- ----------------------------------------------------------------- looking at the sound first
-- python/reaats_prescan.py takes a second or two: the average spectrum, the lowest strong partial, the highest frequency with content, the
-- loudness over time, and settings that suit the sound. The page shows them in a view of their own, and the suggested settings in red next
-- to the fields they belong to (click one to use it).
function Page:prescan()
  if not self.wav then self:say("Choose a sound first.", true); return end
  if not self:find_python() then self:say("Python is needed to look at the sound. See the message that opened.", true); self:python_popup(); return end
  local script = self.env.script_dir .. "/python/reaats_prescan.py"
  if not reaper.file_exists(script) then self:say("The program that looks at the sound is missing: " .. script, true); return end
  local args = {}
  if self.s.start > 0 then args[#args + 1] = string.format(" --start %.6f", self.s.start) end
  if self.s.duration > 0 then args[#args + 1] = string.format(" --duration %.6f", self.s.duration) end
  local reply = reaper.ExecProcess(string.format("%s %s %s%s", q(self.python.exe), q(script), q(self.wav), table.concat(args)), 60000) or ""
  local body = reply:match("PRESCAN (%b{})")
  local pre = body and self.env.serial.deserialize(body)
  if type(pre) ~= "table" or type(pre.curve) ~= "table" then
    self:say("Could not look at the sound: " .. ((reply:match("ERROR ([^\n]*)")) or (reply == "" and "no answer" or reply:gsub("%s+", " "):sub(1, 160))), true)
    return
  end
  self.pre, self.suggest, self.view = pre, pre.suggest, "pre"
  self:say(nil)
end

-- Uses a suggested setting (the red value of a field).
function Page:apply_suggestion(key)
  local sg, f = self.suggest and self.suggest[key], FIELDS[key]
  if not sg or not f then return end
  local v = clamp(sg.v, f.min or sg.v, f.max or sg.v)
  if f.int then v = math.floor(v + 0.5) end
  self.s[key] = v
  self.suggest[key] = nil
end

local SUGGEST_ORDER = { "lowest_frequency", "highest_frequency", "amp_threshold_db", "hop_size", "window_cycles" }

function Page:apply_all_suggestions()
  for _, key in ipairs(SUGGEST_ORDER) do self:apply_suggestion(key) end
  self.view = nil                                                    -- nothing left to see here once they're all used: go straight back
  self:say("The suggested settings are used.")
end

function Page:use_selected_item()
  local item = reaper.GetSelectedMediaItem(0, 0)
  if not item then self:say("Select an item in REAPER first.", true); return end
  local take = reaper.GetActiveTake(item)
  if not take or reaper.TakeIsMIDI(take) then self:say("The selected item has no audio take.", true); return end
  local src = reaper.GetMediaItemTake_Source(take)
  local path = reaper.GetMediaSourceFileName(src, "")
  local low = path:lower()
  if not (low:match("%.wav$") or low:match("%.aiff?$") or low:match("%.aifc$") or low:match("%.flac$")) then
    self:say("The item's file is not a WAV, AIFF or FLAC file (" .. basename(path) .. "). Render it to WAV first (Glue, or File > Render) and select the new item.", true)
    return
  end
  if not self:set_source(path) then return end
  local offs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
  local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local rate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
  self.s.start = offs
  self.s.duration = len * ((rate and rate > 0) and rate or 1)
  if self.info and offs + self.s.duration > self.info.seconds then            -- an item can end a few samples past the file
    self.s.duration = math.max(self.info.seconds - offs, 0)
  end
  self.out_custom = false
  self.out = unique_out(path)
  self:say("Item: the part of the file the item plays is analysed. Item volume, fades, FX and pitch are not applied.")
end

-- The extension list of the file dialog: only the sound files the analysis reads (nothing else is shown).
M.SOUND_FILTER = "Sound files (*.wav;*.flac;*.aif;*.aiff)\0*.wav;*.flac;*.aif;*.aiff\0\0"

function Page:choose_file()
  local ok, path
  if reaper.JS_Dialog_BrowseForOpenFiles then            -- (JS_ReaScriptAPI: a file type list; the REAPER dialog only offers one extension and "all files")
    local rv, chosen = reaper.JS_Dialog_BrowseForOpenFiles("Import Sound File (WAV, AIFF or FLAC)", self.wav and dirname(self.wav) or "",
      self.wav and basename(self.wav) or "", M.SOUND_FILTER, false)
    ok, path = (rv == 1), chosen
  else
    ok, path = reaper.GetUserFileNameForRead(self.wav or "", "Import Sound File (WAV, AIFF or FLAC)", "wav")
  end
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

-- A value is typed in the field itself: click it (all of it is selected, so the first key replaces it), type, then Enter (or Tab for
-- the next number, or a click elsewhere) accepts and Esc cancels.
function Page:begin_edit(key)
  self.edit = { key = key, text = fmt_num(self.s[key]), fresh = true }
end

function Page:commit_edit()
  local e = self.edit
  if not e then return end
  self.edit = nil
  local f = FIELDS[e.key]
  local text = e.text
  if text == "" then return end
  local v = tonumber(text)
  if not v then self:say("'" .. text .. "' is not a number.", true); return end
  v = clamp(v, f.min, f.max)
  if f.int then v = math.floor(v + 0.5) end
  self.s[e.key] = v
end

-- A typed character, from the editor's loop. Returns true when the page used it.
function Page:key(ch)
  local e = self.edit
  if not e and self.view == "pre" then                                 -- Esc closes the view of the sound (not the page)
    if ch == 27 then self.view = nil; return true end
    return false
  end
  if not e then return false end
  if ch == 27 then self.edit = nil; return true end                    -- Esc: cancel (and stay on the page)
  if ch == 13 or ch == 10 then self:commit_edit(); return true end
  if ch == 9 then                                                      -- Tab: accept, and go on to the next number
    local key = e.key
    self:commit_edit()
    local at
    for i, k in ipairs(ORDER) do if k == key then at = i end end
    for step = 1, #ORDER do
      local k = ORDER[((at or 0) + step - 1) % #ORDER + 1]
      if FIELDS[k].kind == "num" then self:begin_edit(k); break end
    end
    return true
  end
  if ch == 8 then                                                      -- Backspace
    if e.fresh then e.text = "" else e.text = e.text:sub(1, -2) end
    e.fresh = false
    return true
  end
  local c
  if (ch >= 48 and ch <= 57) or ch == 46 or ch == 45 or ch == 43 then c = string.char(ch)
  elseif ch == 44 then c = "."                                         -- a comma is a decimal point
  elseif ch == 101 or ch == 69 then c = "e" end
  if not c then return true end                                        -- (other keys do nothing while a value is typed)
  if e.fresh then e.text = ""; e.fresh = false end
  if #e.text < 16 then e.text = e.text .. c end
  return true
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
  if not self.wav or not self.info then return "Choose the sound first: use the selected item or choose a sound file." end
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
  -- Every job has files of its own (a second editor, a second page or another program must never read or delete them).
  local id = string.format("%d_%d", os.time(), math.random(100000, 999999))
  local argsfile = dir .. "/reaats_" .. id .. "_args.txt"
  local engine = self.env.script_dir .. "/python/reaats_analyse.py"
  if not reaper.file_exists(engine) then self:say("The analysis program is missing: " .. engine, true); return end
  if not self:find_python() then
    self:say("Python (" .. M.MIN_PYTHON .. " or newer, with numpy) is needed for the analysis. See the message that opened.", true)
    self:python_popup()
    return
  end
  -- start the engine in the background (ExecProcess with -1 returns at once); the page polls its files each frame
  local result = dir .. "/reaats_" .. id .. "_result.txt"
  for _, f in ipairs({ result, result .. ".started", result .. ".cancel", result .. ".tmp" }) do os.remove(f) end
  local fh = io.open(argsfile, "w")
  if not fh then self:say("Cannot write " .. argsfile, true); return end
  fh:write(table.concat(M.build_args(s, self.wav, out, result), "\n"), "\n")
  fh:close()
  reaper.ExecProcess(string.format("%s %s @%s", q(self.python.exe), q(engine), q(argsfile)), -1)
  self.job = { result = result, started = result .. ".started", cancel = result .. ".cancel", argsfile = argsfile,
               t0 = reaper.time_precise(), progress = 0, seen_start = false, cancelling = false }
  self:say(nil)
end

-- What the engine answered (the text of the result file): open the result, or say what went wrong.
function Page:handle_reply(reply, took)
  reply = reply or ""
  local result_text = reply:match("RESULT (%b{})")
  local summary = result_text and self.env.serial.deserialize(result_text)
  if type(summary) ~= "table" or type(summary.files) ~= "table" or #summary.files == 0 then
    local err = reply:match("ERROR ([^\n]*)")
    if not err then
      if reply == "" then err = "The analysis program did not answer."
      else err = (reply:gsub("%s+", " "):sub(1, 220)) end
    end
    if err == "cancelled" then self:say("Analysis cancelled.") else self:say("Analysis failed: " .. err, true) end
    return
  end
  summary.seconds_taken = took
  self.result = summary
  self:save_settings()
  local first = summary.files[1]
  local opened = self.env.on_open(first.file)
  local parts = {}                                              -- how long each step took (channel 1), to see where the time goes
  if type(first.timings) == "table" then
    for _, name in ipairs({ "tracking", "pruning", "rebuilding", "noise", "writing" }) do
      local t = first.timings[name]
      if t then parts[#parts + 1] = string.format("%s %.0f s", name, t) end
    end
  end
  self:say(string.format("Analysed in %.1f s: %d file(s). %s%s", took, #summary.files,
    opened and ("Channel 1 is open in the editor (" .. basename(first.file) .. ").") or "The first file could not be opened.",
    #parts > 0 and ("  Steps: " .. table.concat(parts, ", ") .. ".") or ""), not opened)
  self.env.set_status(string.format("analysed %s: %d partials, %d frames in %.1f s%s", basename(first.file), first.partials, first.frames, took,
    #parts > 0 and ("  (" .. table.concat(parts, ", ") .. ")") or ""))
  if opened and self.env.back then self.env.back() end                 -- the editor is shown at once (the ANALYSE button / Ctrl+A shows the page and its result again)
end

local function read_all(path)
  local fh = io.open(path, "r")
  if not fh then return nil end
  local t = fh:read("a")
  fh:close()
  return t
end

-- Called every frame by the editor: looks at what the background analysis has written.
function Page:poll()
  local job = self.job
  if not job then return end
  local now = reaper.time_precise()
  if reaper.file_exists(job.result) then
    local reply = read_all(job.result)
    for _, f in ipairs({ job.result, job.started, job.cancel, job.argsfile }) do os.remove(f) end
    self.job = nil
    self:handle_reply(reply, now - job.t0)
    return
  end
  local beat_text = read_all(job.started) or ""
  local p, stamp, stage = beat_text:match("^(%S+)%s+(%S+)%s*(.-)%s*$")
  p, stamp = tonumber(p), tonumber(stamp)
  if stage and stage ~= "" then job.stage = stage end                  -- what the program is busy with (its own words)
  if p then job.progress, job.seen_start = p, true end
  if stamp then job.beat = stamp end                          -- the program writes the time (seconds since 1970) every 2 s
  if job.cancelling and job.cancel_t and now - job.cancel_t > 8 then
    for _, f in ipairs({ job.result, job.started, job.cancel, job.argsfile }) do os.remove(f) end
    self.job = nil
    self:say("Analysis cancelled (the program did not answer; it may have stopped already).")
    return
  end
  if job.beat and os.time() - job.beat > 120 then
    for _, f in ipairs({ job.result, job.started, job.cancel, job.argsfile }) do os.remove(f) end
    self.job = nil
    self:say("The analysis program stopped answering (no sign of life for 2 minutes). It may have crashed. If the sound is long or noisy, "
      .. "try a higher amplitude threshold or a higher lowest frequency, or analyse a shorter part.", true)
    return
  end
  if not job.seen_start and now - job.t0 > 20 then
    self.job = nil
    self.python = nil                                           -- look again next time
    self:say("The analysis program did not start. Is Python installed? (Python was not found to run it.)", true)
  elseif now - job.t0 > 3600 then
    self.job = nil
    self:say("The analysis took more than an hour and was given up.", true)
  end
end

function Page:cancel_job()
  local job = self.job
  if not job or job.cancelling then return end
  local fh = io.open(job.cancel, "w")
  if fh then fh:write("stop"); fh:close() end
  job.cancelling = true
  job.cancel_t = reaper.time_precise()
end

function Page:import_ats()
  local ok, path = reaper.GetUserFileNameForRead("", "Import an ATS file (.ats)", "ats")
  if not ok or not path or path == "" then return end
  if self.env.on_open(path) then
    self.env.set_status("imported " .. basename(path))
    self.env.back()
  else
    self:say("Could not read " .. basename(path) .. " as an ATS file.", true)
  end
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
  local editing = self.edit and self.edit.key == key
  gfx.set(editing and 0.10 or 0.14, editing and 0.20 or 0.16, editing and 0.17 or 0.19, 1); gfx.rect(bx, y, box_w, 20, 1)
  if editing then gfx.set(0.45, 0.85, 0.6, 1) else gfx.set(0.4, 0.43, 0.48, 1) end
  gfx.rect(bx, y, box_w, 20, 0)
  local shown
  if editing then shown = self.edit.text
  elseif f.kind == "choice" then shown = (v == 0) and "automatic" or tostring(v) else shown = fmt_num(v) end
  gfx.set(1, 0.9, 0.6, 1)
  gfx.x, gfx.y = bx + 6, y + 3
  if editing and self.edit.fresh and shown ~= "" then                   -- all of it selected: the next key replaces it
    local sw = gfx.measurestr(shown)
    gfx.set(0.25, 0.45, 0.65, 1); gfx.rect(bx + 5, y + 2, sw + 2, 16, 1)
    gfx.set(1, 1, 1, 1); gfx.x, gfx.y = bx + 6, y + 3
  end
  gfx.drawstr(shown)
  if editing and (math.floor(reaper.time_precise() * 2) % 2 == 0) and not self.edit.fresh then       -- a blinking caret
    local cx = bx + 6 + gfx.measurestr(shown)
    gfx.set(1, 1, 1, 1); gfx.line(cx + 1, y + 3, cx + 1, y + 17, 1)
  end
  if f.kind == "num" and f.unit ~= "" then text(bx + box_w + 6, y + 3, f.unit, 0.55, 0.58, 0.63) end
  local sg = self.suggest and self.suggest[key]
  if sg and f.kind == "num" and not editing and math.abs(sg.v - v) > 1e-9 then              -- the suggestion, in red, outside the field
    local sx = bx + box_w + 6 + ((f.unit ~= "") and (gfx.measurestr(f.unit) + 12) or 0)
    local label = "-> " .. fmt_num(sg.v)                                                         -- an arrow and the value
    gfx.set(1, 0.35, 0.3, 1)
    gfx.x, gfx.y = sx, y + 3
    gfx.drawstr(label)
    self.hits[#self.hits + 1] = { x = sx - 2, y = y, w = gfx.measurestr(label) + 6, h = 20, tip = "Suggested: " .. sg.why .. "  (click to use it)", key = false,
                                  click = function() self:apply_suggestion(key) end }
  end
  if key == "jobs" and self.python and self.python.cores then
    text(bx + box_w + 6, y + 3, string.format("%d at once, of %d cores", M.workers(self.s, self.python.cores), self.python.cores), 0.55, 0.58, 0.63)
  end
  self.hits[#self.hits + 1] = {
    x = bx, y = y, w = box_w, h = 20, tip = f.tip, key = key,
    click = function()
      if f.kind == "num" then if not (self.edit and self.edit.key == key) then self:begin_edit(key) end
      else self:pick_choice(key) end
    end,
    wheel = function(notches, fine) self:step(key, notches, fine) end,
  }
end

function Page:heading(x, y, label)
  gfx.setfont(1, "Arial", 15)
  text(x, y, label, 0.55, 0.68, 0.92)
  gfx.set(0.55, 0.68, 0.92, 0.5)
  gfx.line(x, y + 19, x + 480, y + 19)
end

-- The view of the sound: the average spectrum on a log scale with the strong partials, the highest frequency with content and the
-- settings (white = as they are now, red = suggested), the loudness over time, and what the analysis would do with it.
function Page:draw_pre(W, H, top)
  local pre = self.pre
  gfx.set(0.09, 0.10, 0.12, 1)
  gfx.rect(0, top, W, H - top, 1)
  gfx.setfont(1, "Arial", 17)
  text(24, top + 6, "THE SOUND: " .. basename(self.wav or ""), 1, 1, 1)
  gfx.setfont(1, "Arial", 13)
  text(24, top + 30, string.format("%.2f s%s   %d Hz   loudest %.1f dB   the quietest tenth is %.0f dB below   (a quick look: the average over the sound)",
    pre.seconds, (pre.seconds >= 59.5) and ("  (" .. M.clock(pre.seconds) .. ")") or "", pre.rate, pre.peak_db, -pre.floor_db), 0.7, 0.74, 0.8)
  -- the spectrum
  local X0, Y0, PW, PH = 70, top + 70, W - 110, 250
  local nyq = pre.rate / 2
  local function fx(f) return X0 + math.log(math.max(f, 20) / 20) / math.log(nyq / 20) * PW end
  local function dy(db) return Y0 + clamp(-db, 0, 90) / 90 * PH end
  gfx.set(0.055, 0.065, 0.085, 1); gfx.rect(X0, Y0, PW, PH, 1)
  gfx.setfont(1, "Arial", 12)
  for _, db in ipairs({ -20, -40, -60, -80 }) do
    gfx.set(1, 1, 1, 0.08); gfx.line(X0, dy(db), X0 + PW, dy(db))
    text(X0 - 40, dy(db) - 6, string.format("%d dB", db), 0.55, 0.58, 0.63)
  end
  for _, f in ipairs({ 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000 }) do
    if f < nyq then
      gfx.set(1, 1, 1, 0.08); gfx.line(fx(f), Y0, fx(f), Y0 + PH)
      text(fx(f) - 12, Y0 + PH + 4, f >= 1000 and (tostring(f // 1000) .. "k") or tostring(f), 0.55, 0.58, 0.63)
    end
  end
  text(X0, Y0 - 18, "average spectrum (0 dB = the strongest)", 0.6, 0.63, 0.68)
  -- the settings: now (white) and suggested (red), for the lowest and the highest frequency
  local function marker(f, label, r, g, b, row)
    local x = fx(f)
    gfx.set(r, g, b, 0.9); gfx.line(x, Y0, x, Y0 + PH)
    text(x + 4, Y0 + 3 + row * 14, label, r, g, b)
  end
  marker(self.s.lowest_frequency, string.format("lowest now %s Hz", fmt_num(self.s.lowest_frequency)), 0.85, 0.85, 0.85, 0)
  marker(self.s.highest_frequency, string.format("highest now %s Hz", fmt_num(self.s.highest_frequency)), 0.85, 0.85, 0.85, 0)
  local sl, sh = self.suggest and self.suggest.lowest_frequency, self.suggest and self.suggest.highest_frequency
  if sl then marker(sl.v, string.format("suggested %s Hz", fmt_num(sl.v)), 1, 0.35, 0.3, 1) end
  if sh then marker(sh.v, string.format("suggested %s Hz", fmt_num(sh.v)), 1, 0.35, 0.3, 1) end
  -- the curve
  gfx.set(0.45, 0.8, 1, 1)
  local n = #pre.curve
  for i = 2, n do
    gfx.line(X0 + (i - 1.5) / n * PW, dy(pre.curve[i - 1]), X0 + (i - 0.5) / n * PW, dy(pre.curve[i]))
  end
  -- the strong partials
  for i, pk in ipairs(pre.peaks or {}) do
    local x, y = fx(pk.f), dy(pk.db)
    gfx.set(1, 0.9, 0.4, 1); gfx.circle(x, y, 3, 1)
    text(x - 14, y - 20 + ((i % 2) * -10), string.format("%s %d", pk.note, math.floor(pk.f + 0.5)), 1, 0.9, 0.5)
  end
  if pre.highest and pre.highest > 0 then
    gfx.set(0.4, 0.9, 0.5, 1)
    text(fx(pre.highest) - 30, Y0 + PH - 16, string.format("content up to %d Hz", math.floor(pre.highest)), 0.45, 0.9, 0.55)
  end
  -- the loudness over time
  local EY, EH = Y0 + PH + 40, 56
  text(X0, EY - 16, "loudness over time", 0.6, 0.63, 0.68)
  gfx.set(0.055, 0.065, 0.085, 1); gfx.rect(X0, EY, PW, EH, 1)
  local env = pre.envelope or {}
  gfx.set(0.9, 0.75, 0.4, 1)
  for i = 2, #env do
    local x0, x1 = X0 + (i - 2) / (#env - 1) * PW, X0 + (i - 1) / (#env - 1) * PW
    gfx.line(x0, EY + clamp(-env[i - 1], 0, 60) / 60 * EH, x1, EY + clamp(-env[i], 0, 60) / 60 * EH)
  end
  text(X0, EY + EH + 3, "0 s", 0.55, 0.58, 0.63)
  text(X0 + PW - 40, EY + EH + 3, string.format("%.1f s", pre.seconds), 0.55, 0.58, 0.63)
  -- the suggestions, and buttons
  local ty = EY + EH + 26
  gfx.setfont(1, "Arial", 13)
  for _, key in ipairs(SUGGEST_ORDER) do
    local sg = self.suggest and self.suggest[key]
    local f = FIELDS[key]
    if sg and f then
      text(24, ty, f.label .. ":", 0.8, 0.82, 0.86)
      text(240, ty, fmt_num(self.s[key]), 0.85, 0.85, 0.85)
      text(300, ty, "-> " .. fmt_num(sg.v), 1, 0.35, 0.3)
      text(380, ty, sg.why, 0.65, 0.68, 0.72)
      ty = ty + 17
    end
  end
  local by = math.min(ty + 8, H - 36)
  self:button(24, by, 200, 26, "Use all suggestions", { 0.5, 0.2, 0.18 }, function() self:apply_all_suggestions() end)
  self:button(236, by, 160, 26, "Back to the settings", { 0.25, 0.27, 0.32 }, function() self.view = nil end)
  gfx.setfont(1, "Arial", 13)
  text(410, by + 6, "Esc: back.  The suggestions also stand in red next to the settings.", 0.55, 0.58, 0.63)
end

function Page:draw(W, H, top)
  self.hits = {}
  if self.view == "pre" and self.pre then return self:draw_pre(W, H, top) end
  gfx.set(0.09, 0.10, 0.12, 1)
  gfx.rect(0, top, W, H - top, 1)
  local colw = math.floor((W - 60) / 2)
  local lx, rx = 24, 24 + colw + 12
  local y = top + 6
  gfx.setfont(1, "Arial", 17)
  text(lx, y, "ANALYSIS: make .ats files from a sound", 1, 1, 1)
  y = y + 28

  -- left column: source, then window and time
  -- Python status, top right: which Python the analysis will use, or a red hint (click for the help)
  if self.python == nil and self.python_problem == nil then self:find_python() end
  gfx.setfont(1, "Arial", 13)
  if self.python then
    text(rx, top + 9, string.format("Python %s, numpy %s", tostring(self.python.version), tostring(self.python.numpy)), 0.55, 0.85, 0.65)
    self:button(rx + 400, top + 5, 80, 20, "Check", { 0.25, 0.27, 0.32 }, function() self:find_python(true) end)
  else
    text(rx, top + 9, "Python not found (needed for the analysis)", 1, 0.6, 0.5)
    self:button(rx + 330, top + 5, 70, 20, "Help", { 0.45, 0.25, 0.2 }, function() self:python_popup() end)
    self:button(rx + 405, top + 5, 75, 20, "Check", { 0.25, 0.27, 0.32 }, function()
      if self:find_python(true) then self:say("Python found.") else self:say("Python is still not found.", true) end
    end)
  end
  self:heading(lx, y, "SOURCE")
  local ly = y + 26
  self:button(lx, ly, 160, 24, "Use selected item", { 0.18, 0.34, 0.26 }, function() self:use_selected_item() end)
  self:button(lx + 170, ly, 180, 24, "Import Sound File", { 0.2, 0.26, 0.4 }, function() self:choose_file() end)
  self:button(lx + 360, ly, 160, 24, "Import .ats File", { 0.36, 0.27, 0.16 }, function() self:import_ats() end)
  ly = ly + 32
  gfx.setfont(1, "Arial", 13)
  if self.wav then
    self:button(lx + 360, ly, 160, 24, "Inspect Sound File", { 0.34, 0.2, 0.3 }, function() self:prescan() end)
    text(lx, ly, "File: " .. (basename(self.wav)), 0.9, 0.9, 0.9)
    local i = self.info
    text(lx, ly + 16, string.format("%d Hz, %d channel(s), %d bit%s, %.2f s%s", i.rate, i.channels, i.bits, i.float and " float" or "", i.seconds,
      (i.seconds >= 59.5) and ("  (" .. M.clock(i.seconds) .. ")") or ""), 0.6, 0.63, 0.68)
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
    if warn then
      text(rx, ry + 16, "The window is longer than the part analysed: raise the lowest frequency.", 1, 0.7, 0.5)
    else
      local lw = M.long_warning(self.s, self.info)
      if lw then text(rx, ry + 16, lw, 1, 0.7, 0.5) end
      local na = (not lw) and M.noise_advice(self.s, self.info) or nil
      if na then text(rx, ry + 16, na, 1, 0.75, 0.45) end
    end
  end
  ry = ry + 38
  self.analyse_box = { x = rx, y = ry, w = 130, h = 30 }
  self:button(rx, ry, 130, 30, "ANALYSE", { 0.18, 0.42, 0.3 }, function() if not self.job then self:run() end end)
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
      text(rx, ry, string.format("channel %s: %s  (%d partials, %d frames, %.2f s%s)", tostring(f.channel), basename(f.file), f.partials, f.frames, f.duration,
        (f.duration >= 59.5) and (", " .. M.clock(f.duration)) or ""), 0.85, 0.87, 0.9)
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
  if self.job then self:draw_busy(W, H, top) end
end

-- While the analysis runs in the background: the page is dimmed, a big word blinks, the ANALYSE button blinks, a bar shows
-- how far it is, and Cancel stops it. Only Cancel can be clicked.
function Page:draw_busy(W, H, top)
  local job = self.job
  local now = reaper.time_precise()
  local on = (math.floor(now * 2) % 2) == 0
  gfx.set(0.04, 0.05, 0.07, 0.72)
  gfx.rect(0, top, W, H - top, 1)
  self.hits = {}
  local b = self.analyse_box
  if b then                                                      -- the button, blinking, on top of the dimming
    local c = on and { 0.25, 0.75, 0.45 } or { 0.10, 0.26, 0.17 }
    gfx.set(c[1], c[2], c[3], 1); gfx.rect(b.x, b.y, b.w, b.h, 1)
    gfx.set(0.6, 1, 0.75, 1); gfx.rect(b.x, b.y, b.w, b.h, 0)
    gfx.setfont(1, "Arial", 14)
    gfx.set(1, 1, 1, 1)
    local label = "ANALYZING..."
    gfx.x = b.x + (b.w - gfx.measurestr(label)) / 2; gfx.y = b.y + 8
    gfx.drawstr(label)
  end
  local cx, cy = W / 2, top + (H - top) / 2 - 40
  gfx.setfont(1, "Arial", 64)
  local word = job.cancelling and "CANCELLING..." or "ANALYZING..."
  local ww = gfx.measurestr(word)
  if on then gfx.set(0.65, 1, 0.78, 1) else gfx.set(0.30, 0.55, 0.38, 1) end
  gfx.x, gfx.y = cx - ww / 2, cy - 36
  gfx.drawstr(word)
  -- the bar
  local bw, bh = 560, 22
  local bx, by = cx - bw / 2, cy + 50
  gfx.set(0.14, 0.16, 0.19, 1); gfx.rect(bx, by, bw, bh, 1)
  gfx.set(0.25, 0.75, 0.45, 1); gfx.rect(bx, by, bw * math.min(math.max(job.progress or 0, 0), 1), bh, 1)
  gfx.set(0.5, 0.53, 0.58, 1); gfx.rect(bx, by, bw, bh, 0)
  gfx.setfont(1, "Arial", 16)
  text(cx - 150, by + 34, string.format("%d %%   |   %d s", math.floor((job.progress or 0) * 100 + 0.5), math.floor(now - job.t0)), 0.85, 0.9, 0.95)
  gfx.setfont(1, "Arial", 14)
  if job.stage then text(bx, by - 22, job.stage, 0.65, 0.85, 0.7) end        -- e.g. "rebuilding the sound from the partials"
  gfx.setfont(1, "Arial", 13)
  text(cx - 150, by + 62, "You can leave this page (Esc): the analysis goes on and the result opens in the editor.", 0.6, 0.63, 0.68)
  self:button(cx - 50, by + 90, 100, 28, job.cancelling and "..." or "Cancel", { 0.5, 0.22, 0.2 }, function() self:cancel_job() end)
end

-- Mouse state from the editor each frame. Returns true when the page used the click.
function Page:mouse(mx, my, cap, wheel)
  local used = false
  local down = (cap & 1) ~= 0
  if wheel ~= 0 then
    if self.edit then self:commit_edit() end
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
    if self.edit then                                                  -- a click anywhere else accepts what was typed
      local on_it = false
      for _, h in ipairs(self.hits) do
        if h.key == self.edit.key and mx >= h.x and mx < h.x + h.w and my >= h.y and my < h.y + h.h then on_it = true end
      end
      if not on_it then self:commit_edit() end
    end
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
