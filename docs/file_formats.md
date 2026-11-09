# File formats -- what ReaATS reads and writes

ONE format: the Csound/ATS file (.ats; types 1-4, little or big endian in, little endian out; with or without phase and the 25
noise bands). WAV is read by the analysis. A stereo or multichannel sound is a SET of .ats files, name_ch1.ats, name_ch2.ats, ...

SDIF (the format SPEAR uses) was considered and DROPPED by tjingboem on 9 Nov 2026: "Drop SDIF". Do not propose it again.
