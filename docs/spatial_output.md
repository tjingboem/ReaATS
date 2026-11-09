# Spatial output -- pseudo-stereo and VBAP (tjingboem, 9 Nov 2026)

tjingboem: "Like we did in SpectralTransfer, i hope to create a pseudo stereo output by dividing the analysed channels
over a stereo output. Also VBAP. Add that to the list."

NOT built, on the list. What SpectralTransfer does (the model to follow; see ~/Claude/SpectralTransfer/CLAUDE.md):
- Three exclusive modes: STEREO, PSEUDO-STEREO, VBAP.
- Pseudo-stereo: the units (there: the filter bands) are divided over left and right by even/odd number; an amount knob
  blends between the full split and no width (default 50 %, because 100 % sounds hollow), with +6 dB makeup so the
  level matches stereo.
- VBAP: up to 8 outputs, a set number of active channels; a unit is panned between the two neighbouring speakers with a
  constant-power sine/cosine law (1-D, pairwise; written from the public description of Pulkki's method); a SPREAD
  amount; low frequencies (below 100 Hz) stay in the centre; the pan width grows with frequency.

ANSWERED 9 Nov 2026 by tjingboem: (a), "the partials of the sound". (b), placing whole analysed channels, is not asked for.

The question was: what is divided over the outputs?
  (a) the PARTIALS of the analysed sound (each partial has a frequency, like a band): even/odd partials left/right for
      pseudo-stereo, and VBAP by partial number or frequency, as the bands are in SpectralTransfer; or
  (b) the ANALYSED CHANNELS of a multichannel analysis set (docs/multichannel_design.md): channel files distributed
      over a stereo output (pseudo-stereo) or over the speakers of a VBAP setup.
  Both can exist: (b) places channels, (a) spreads the partials of each channel.
Where it would act: in the rendering for AUDITION and PRINT (the synthesis makes one mono sound per channel file today);
PRINT would then write a stereo or multichannel WAV.
