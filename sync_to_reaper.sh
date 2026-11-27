#!/bin/bash
# One-way sync: git repo (source of truth) -> REAPER's live Scripts copy.
# Never run this in reverse -- REAPER's copy is disposable, this one isn't.
# Load ReaATS.lua from the live copy in REAPER's Actions list (once per machine).
rsync -av --delete \
  --exclude='.git' \
  --exclude='sync_to_reaper.sh' --exclude='toolbar_icons' \
  ~/Claude/ReaATS/ /home/tjingboem/.config/REAPER/Scripts/tjingboem/ReaATS/
mkdir -p ~/.config/REAPER/Data/toolbar_icons && cp ~/Claude/ReaATS/toolbar_icons/*.png ~/.config/REAPER/Data/toolbar_icons/   # toolbar icon (90x30, 3 states)
