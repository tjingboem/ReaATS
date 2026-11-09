# Analysis options -- the spec for the future Analysis page

tjingboem, 9 Nov 2026: "all options as we find for analysis must be used in a yet to make Analyses page."
This is the list of every analysis option found so far, in the two analysers that exist: Csound's `atsa`
utility (ATSA 1.0, `csound -U atsa sound.wav out.ats [flags]`) and the Python package pyatsyn 1.0.0 (`tracker()`).
Both implement the ATS analysis of Di Liscia, Moss and Pampin. The page is NOT built; build it when tjingboem says so.
The page should show every option below, with the default, a one-line explanation, and the derived values that help
(window length in samples and ms, hop in ms, expected number of frames).

## Options both analysers have

| Option | Csound atsa | pyatsyn | Default | What it does |
|---|---|---|---|---|
| Start | -b | start | 0 s | Where the analysis starts. |
| Duration | -e | duration | to the end | How much of the sound is analysed. |
| Lowest frequency | -l | lowest_frequency | 20 Hz | Lowest frequency analysed; must be above 0. The window is `window cycles` periods of it long, so a low value gives a long window. |
| Highest frequency | -H | highest_frequency | 20000 Hz | Highest frequency analysed (capped at Nyquist). |
| Frequency deviation | -d | frequency_deviation | 0.1 | The largest relative change of a partial's frequency between two frames when peaks are matched into a track. |
| Window cycles | -c | window_cycles | 4 | How many periods of the lowest frequency fit in the analysis window. |
| Window type | -w | window_type | Blackman-Harris | The FFT window (lists below). |
| Hop size | -h | hop_size | 0.25 of the window | Distance between frames. |
| Amplitude threshold | -m | amp_threshold | -60 dB | The quietest peak that counts. |
| Track length | -t | track_length | 3 frames | Frames used to smooth a track's frequency. |
| Minimum segment length | -s | min_segment_length | 3 frames | Shorter track pieces are dropped. |
| Minimum gap length | -g | min_gap_length | 3 frames | Gaps in a track longer than this are not bridged. |
| Last peak contribution | -P | last_peak_contribution | 0 | Extra weight of the previous frame's values when a track is smoothed. |
| SMR contribution | -M | SMR_continuity | Csound 0.5, pyatsyn 0.0 | How much of the signal-to-mask ratio counts in the cost of matching a peak to a track. The two programs have different defaults. |

## Csound atsa only

| Option | Flag | Default | What it does |
|---|---|---|---|
| SMR threshold | -T | 30 dB SPL | Peaks below this signal-to-mask ratio are not used. |
| Minimum segment SMR | -S | 60 dB SPL | A track piece must reach this SMR to be kept. |
| File type | -F | 4 | 1 amplitude and frequency; 2 plus phase; 3 plus noise (residual); 4 phase and noise. |

Csound's window types (-w): 0 Blackman, 1 Blackman-Harris (default), 2 Hamming, 3 Hann (called VONHANN).

## pyatsyn only

| Option | Parameter | Default | What it does |
|---|---|---|---|
| FFT size | fft_size | automatic | Force an FFT size (a power of 2). |
| Window length | force_M | automatic | Force the window length in samples. |
| Own window | force_window | none | A window curve given by the user. |
| Window shape parameters | window_alpha, window_beta | 0.5, 1.0 | Parameters of the Tukey window (alpha) and of windows that take a beta. |
| Optimise | optimize | on | Post-processing of the tracks (pruning quiet and short ones). |
| Optimise threshold | optimize_amp_threshold | -60 dB | Extra amplitude threshold in that pruning. |
| Residual file | residual_file | none | Write the residual (what the sines do not explain) to a WAV; the noise bands are only calculated when this is given. |
| Save phase, save noise | ats_save(save_phase, save_noise) | both on | Which data go into the .ats file (the same choice as Csound's -F). |

Residual analysis (the noise bands) has its own settings in pyatsyn that are not reachable from `tracker()`:
minimum FFT size 4096, padding factor 2, "equalize" to the time-domain energy (off), the band edges (the 25 critical
bands), noise threshold -120 dB. Offer them on the page too (advanced section).

pyatsyn window types: blackman-exact, blackman, blackman-harris-3-1, blackman-harris-3-2, blackman-harris-4-1
(default), blackman-harris-4-2, rectangular, parzen, welch, kaiser, gaussian, poisson, cauchy, connes, exponential,
bartlett, riemann, tukey, hamming, hann, hann-poisson.

## Channels (tjingboem, 9 Nov 2026)

A setting for the number of channels to analyse. Each channel gets its own .ats file with the same options; see
`multichannel_design.md`.

## Notes for building the page

- One list of options, each marked with where it comes from. Presets: "Csound atsa defaults" and "pyatsyn defaults".
- The same settings must produce the same kind of file whichever program (or, later, our own Lua analysis) does the
  work; the output is always a standard Csound .ats file.
- The input must be a mono file (pyatsyn requires it; Csound was only tried with mono).
- Experience so far (the alto sax example): the default lowest frequency of 20 Hz made a long window and a poor
  result; 100 Hz sounded good. Show the window length next to the lowest-frequency field.
