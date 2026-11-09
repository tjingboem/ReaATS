# Stereo and multichannel sound -- the design (tjingboem, 9 Nov 2026)

tjingboem: "we should, for analysis, be able to set the number of channels. These are loaded separately in the
Editor. Using Shift while editing changes all channels, but the user can switch between them and make individual
edits. Common factor is the edit window and the stereo or multichannel sound is of the same duration."

NOT built yet. An .ats file stays mono (one set of partials, standard Csound format); a stereo or multichannel
sound is a SET of .ats files, one per channel.

## Analysis
- The Analysis page has a setting for the number of channels (1 up to the channels in the sound file).
- Each channel is analysed on its own with the same options, so all files have the same frame size, window size,
  frame count and duration (the "common factor": one shared time axis / edit window).
- Output: one .ats file per channel (name_ch1.ats, name_ch2.ats, ...). Every file is a normal Csound-compatible
  .ats file and can also be opened alone. Partial numbers do NOT correspond between channels.
- (Possible extra choices, not asked for: mid/side, a mono mix.)

## Editor
- The channels of a set are loaded separately; one channel is shown and edited at a time, and the user switches
  between them (channel buttons CH 1, CH 2, ...; keys). The view (time and frequency range), the window and the
  duration are shared, so switching channel keeps the picture in place.
- Which channels are edited: DECIDED 9 Nov 2026, replacing the earlier LINK button idea (tjingboem: "i decided
  differently. If we see the number of channels as individual buttons, like channels 1 2 3, then we can click which
  ones we want to edit at the same time"). The editor shows one toggle button per channel (1, 2, 3, ...). Every
  button that is on is edited; selecting and every edit (delete, transpose, move) apply to all channels that are on,
  and only to those. One channel on = individual edits. Shift keeps its existing uses.
  Proposed (not confirmed): the channels that are on are all drawn, overlaid, each in its own colour tint, so you see
  what you are editing; the hover readout names the channel of the nearest partial.
- A slider per channel (tjingboem, 9 Nov 2026: "sliders that will blend in that channel"; asked what it blends:
  ANSWER "how visible the channel is on screen"). The slider (0-100 %) sets how strongly that channel is drawn when
  several channels are shown on top of each other, so channels can be compared in the picture. It changes neither
  the edits nor the sound: which channels are EDITED is decided by the channel buttons only, and AUDITION / PRINT
  always render every channel. DECIDED (tjingboem, 9 Nov 2026): a channel that is ON for
  editing is always drawn at at least 20 %, so an edit is never made on something you cannot see (no warning mark
  needed). DECIDED (tjingboem, 9 Nov 2026: "turned off = 0%"): a channel that is
  OFF is not drawn at all (0 %), so the slider only matters for channels that are ON, where it runs from 20 % to 100 %.
- How an edit on several channels works: partials differ per channel, so a selection is a time-frequency REGION (the
  box) that is applied to the own points of every channel that is on; delete / transpose / move then act on each channel's
  selected points by the same amount (same frames, same ratio).
- One undo history for the set: an edit on several channels is one undo step.
- All channel files must have the same frame size, frame count, sample rate and duration; the editor refuses a set
  that does not match and says why.
- AUDITION / PRINT: render a multichannel WAV, channel i from file i (the Lua synthesis already makes one channel
  at a time; the WAV writer needs more than one channel; the track gets enough channels).
- EXPORT: every channel file (name_ch1_edit.ats, ...), phases kept.
- ReaSnap: the item settings list the files of the set.
