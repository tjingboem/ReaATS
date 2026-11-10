#!/bin/bash
# One-way sync: git repo (source of truth) -> REAPER's live Scripts copy.
# Never run this in reverse -- REAPER's copy is disposable, this one isn't.
# Load ATS_Editor.lua from the live copy in REAPER's Actions list (once per machine).
rsync -av --delete \
  --exclude='.git' \
  --exclude='sync_to_reaper.sh' \
  ~/Claude/ReaATS/ /home/tjingboem/.config/REAPER/Scripts/tjingboem/ReaATS/
