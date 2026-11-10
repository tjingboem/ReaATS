# Installing ReaATS

ReaATS is a REAPER Lua script with a Python analysis backend. The script itself
is cross-platform (it detects the OS at runtime and looks for Python in the
right places for Windows, macOS or Linux), but *getting the files into REAPER*
differs slightly per platform.

## 1. Requirements

- REAPER
- Python 3.8+ with numpy, reachable by REAPER. Either:
  - a `python3` (macOS/Linux) or `python`/`py` (Windows) on PATH, or
  - Python configured under REAPER's own
    Options > Preferences > Plug-ins > ReaScript > "Enable Python for use with ReaScript"
    (ReaATS reads that setting and uses it to find Python; it looks there first).
  - Install numpy with `python3 -m pip install numpy` (Windows: `python -m pip install numpy`).
    On Linux, `sudo apt-get install python3-numpy` also works and avoids pip.
- If numpy (or Python) is missing, ReaATS shows a popup with these same instructions
  when you try to analyse a file — it doesn't fail silently.

## 2. Where REAPER's Scripts folder is

| OS      | Path |
|---------|------|
| Linux   | `~/.config/REAPER/Scripts/` |
| macOS   | `~/Library/Application Support/REAPER/Scripts/` |
| Windows | `%APPDATA%\REAPER\Scripts\` |

(REAPER > Options > Show REAPER resource path in explorer/finder also opens this
folder directly, on any OS.)

## 3. Install

Copy the whole ReaATS folder (`ATS_Editor.lua`, `lib/`, `python/`, `icons/`, etc.)
into that Scripts folder, e.g. as `Scripts/ReaATS/` (any subfolder name works).

- **Linux/macOS**: `rsync` and `bash` are available by default. This repo ships
  `sync_to_reaper.sh`, a one-way sync (repo -> REAPER's copy) for Linux. On macOS,
  copy it and change the destination path to the macOS Scripts path above before
  running it.
- **Windows**: there's no bash/rsync by default. Either copy the folder manually
  (drag-and-drop, or File Explorer), or use `robocopy` from a terminal, e.g.:
  ```
  robocopy "C:\path\to\ReaATS" "%APPDATA%\REAPER\Scripts\ReaATS" /E /PURGE /XD .git
  ```

Then in REAPER: Actions > Show action list > New action... > Load ReaScript...,
and pick `ATS_Editor.lua` from the copy you just placed in the Scripts folder.

## 4. Updating

Whenever the script changes, close and reopen the ReaATS editor window in REAPER
— a running Lua script keeps its old code loaded, so edits only take effect after
a restart of the script. A `build DD Mon HH:MM` stamp is drawn bottom-right in the
editor to confirm which version is running.
