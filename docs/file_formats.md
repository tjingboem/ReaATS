# File formats -- what ReaATS reads and writes

Today: ONE format, the Csound/ATS file (.ats; types 1-4, little or big endian in, little endian out; with or without
phase and the 25 noise bands). Also reads WAV for the analysis.

## SDIF (asked by tjingboem, 9 Nov 2026: "SPEAR can also read SDIF format")
SPEAR's own format is SDIF (Sound Description Interchange Format, IRCAM/CNMAT), stream type 1TRC (sinusoidal tracks);
it also reads/exports text files and can import ATS. Not built in ReaATS. NOT on the list unless tjingboem says so.
If it is wanted:
- SDIF is binary, big-endian: a header, then frames (a time and a stream id), each with matrices. A 1TRC matrix has one
  row per sounding partial: index, frequency, amplitude, phase.
- Export ATS -> SDIF 1TRC is simple: one frame per ATS frame, one row per sounding partial (amplitude > 0). The 25
  noise bands have no place in 1TRC and would be lost (phase can be kept).
- Import SDIF -> ATS needs a decision because ATS has a fixed frame grid and a fixed number of partial rows: choose the
  hop (the median distance between SDIF frames or a value the user sets), put every track index in its own row,
  interpolate frequency and amplitude onto the grid, amplitude 0 where a track is absent; window size is not in SDIF
  (set to four hops or ask); no noise bands. The editor's row logic (ats_edit) already copes with rows that are silent in
  places.
- Effort: a reader and writer of about 200-300 lines of Lua with tests against files made by other tools (SPEAR,
  the Python package `pysdif3`/CNMAT tools if available on the machine); the exact byte layout must be checked against
  the SDIF specification before building.
- A second format worth the same effort: SPEAR's text format (par-text-frame-format), trivial to read and write.
