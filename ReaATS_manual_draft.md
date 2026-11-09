# ReaATS

## What it does

ReaATS is a partial editor for REAPER, in the spirit of SPEAR. It opens ATS analysis files, the files that Csound's ATS opcodes use, and shows the sound inside them: a set of sine waves (the partials) that each follow their own frequency and loudness through time, plus the noise that is left over. You select parts of the partials, delete them, transpose them or move them, listen to the result, and put the result in your project as a new sample.

An ATS file is not a recording. A sound is analysed into partials, the sine waves that make up its pitched part, and a residual, the rest, stored as the energy in 25 bands. ATS can build the sound back from these two things. Because every partial is a separate line, you can change one harmonic of a saxophone and leave the rest alone, which you cannot do in an ordinary waveform.

ReaATS is a Lua script that runs inside REAPER on Linux. It makes the sound itself, so it does not need any other program to play or print an edited sound.

## What you need

- REAPER, with the script loaded from the action list.
- The SWS extension, for AUDITION. PRINT does not need it.
- An .ats file. A small example, sax.ats, comes with ReaATS in the examples folder. To make your own you need Python 3 with numpy, for the analysis program that comes with ReaATS (see the Analysis page, below). Csound is not needed for anything.

Only Linux has been tried. Temporary files go to the temporary folder (TMPDIR, or /tmp).

## Installing

Put the ReaATS folder (ATS_Editor.lua and the lib folder next to it) in REAPER's Scripts folder, for example Scripts/tjingboem/ReaATS. In REAPER open Actions, Show action list, choose ReaScript: Load and pick ATS_Editor.lua. Run it from the list, or give it a shortcut or a toolbar button.

The first time, ReaATS asks for an .ats file. After that it reopens the file you used last. The lib folder must stay next to the script: it holds the reader and writer for .ats files and the editing logic.

## Making an .ats file: the Analysis page

The ANALYSE button, at the top right of the window (or Ctrl+A), opens the Analysis page. It is there even when no .ats file is open yet. The page analyses a sound into .ats files and opens the result in the editor. Esc, or the BACK button, returns to the editor.

**Importing an .ats file.** The button Import .ats file... on the page opens an existing .ats file, for example one that you made with Csound, and returns to the editor. It does the same as the O key in the editor.

**Choosing the sound.** Select an audio item in REAPER and click Use selected item. Only the part of the file that the item plays is analysed, from its start offset for its length. Volume, fades, effects and pitch changes on the item are not applied, because the analysis reads the file itself. Or click Choose WAV file... and pick any WAV file. The sound must be a WAV file (PCM, 8 to 32 bit, or float). If the item's file is another format, render it to WAV first (Glue, or File, Render) and select the new item. The page shows the sample rate, the channels and the length of the sound.

**The options.** The page has every option of the analysis. Click a value to type a new one, or point at it and use the mouse wheel (Shift for finer steps). Point at an option to see a short explanation at the bottom. The line under the options shows what the settings mean for this sound: the window length in samples and milliseconds, the FFT size, the hop and the number of frames. It warns when the window is longer than the part that is analysed.

| Option | What it sets | Default |
|---|---|---|
| Start, Duration | Where to start and how long to analyse, in seconds. 0 means the whole sound. | 0 |
| Channels to analyse | How many channels are analysed, each into a file of its own (see below). | 1 |
| Mix all channels to mono first | Analyse the average of all channels as one sound. | off |
| CPU cores | How many channels are analysed at the same time, one per core. 0 is automatic: all cores but two, so that REAPER keeps room to play, and at least one. Next to the box the page shows how many run at once. It does nothing for a single channel. | 0 |
| Lowest frequency | The analysis window is four cycles of this frequency long, so a low value gives a long window: good frequency detail, but fast changes are smeared in time. Set it a little below the lowest note in the sound. | 20 Hz |
| Highest frequency | The highest frequency analysed. | 20000 Hz |
| Window cycles | How many periods of the lowest frequency fit in the window. | 4 |
| Window type, alpha, beta | The FFT window and its parameters. | blackman-harris-4-1 |
| Hop size | The distance between frames, as a fraction of the window. | 0.25 |
| FFT size, Window length | Force a value instead of the automatic one. | automatic |
| Amplitude threshold | The quietest peak that counts. Raise it for noisy sounds. | -60 dB |
| Frequency deviation | The largest relative frequency change between two frames when peaks are matched into a track. | 0.1 |
| Track length, Minimum segment length, Minimum gap length | How tracks are smoothed, how short a piece may be, and how long a gap may be bridged, in frames. | 3 |
| Last peak contribution, SMR contribution | How much the previous frame and the signal-to-mask ratio count when peaks are matched. | 0, 0 |
| Optimise, Optimise threshold | Prune quiet and short tracks afterwards, with an extra threshold if wanted. | on |
| Store the phase, Store the noise bands | What goes into the file. Without noise bands the analysis is faster. | both on |

The buttons Defaults and Csound defaults reset the options. Csound's analyser differs in one default only: the SMR contribution is 0.5. Your settings are remembered the next time. Csound's analyser has two options that this one has not: the SMR threshold and the minimum segment SMR.

**Analysing.** Click ANALYSE. The analysis runs in the background while the page shows it at work: the page is dimmed, the big word ANALYZING... blinks, the ANALYSE button blinks, and a bar shows how far the analysis is, with the percentage and the seconds so far. Cancel stops the analysis and leaves no file behind. You can also leave the page with Esc: the analysis goes on, and the result opens in the editor when it is done. The page then shows what was made, and the first file is open in the editor. The result is saved next to the sound as name.ats. If that name exists, name_2.ats is used. With Change... you choose another place and name, and ReaATS asks before it replaces a file.

**Several channels.** With Channels to analyse set to 2 or more, each channel is analysed on its own with the same options and written to its own file: name_ch1.ats, name_ch2.ats, and so on. All the files of a set have the same frame size, number of frames and length. The channels are analysed at the same time on separate cores of your computer, so a set of channels takes much less time than one channel after the other: in a test, 8 channels of 20 seconds took 11 seconds instead of 30. The result is exactly the same files as when the channels are analysed one after the other. The files only get their real names when every channel is done, so a cancelled analysis leaves nothing behind and does not touch a file that was there before. The editor opens the first channel. The Open buttons on the page open the others, one at a time. Editing channels together is not built yet.

**What it needs.** The analysis is done by a small program that comes with ReaATS, python/reaats_analyse.py. It needs Python 3.8 or newer and the numpy package on your computer, and nothing else. REAPER users usually have Python already. ReaATS looks for it in the place REAPER is set to use for ReaScript (Options, Preferences, Plug-ins, ReaScript), and then in the usual places. The top right of the Analysis page shows which Python it found and which numpy, and a Check button looks again.

If ReaATS cannot find a Python that will do, a window opens when you click ANALYSE. It says what is missing: no Python, no numpy, or a Python that is too old. It tells you to download Python from python.org and install it, to install numpy (python3 -m pip install numpy) and to tell REAPER where Python is, in Options, Preferences, Plug-ins, ReaScript. It also offers to open the download page. After you have done this, click Check on the page, or restart REAPER, and try again. There is no analysis without Python.

The program also works from a terminal, for scripts:

python3 python/reaats_analyse.py sound.wav sound.ats --lowest-frequency 100

python3 python/reaats_analyse.py --help lists all the options. The analysis is the one of the pyatsyn package. Csound's own analyser, csound -U atsa sound.wav sound.ats -l 100, makes files that ReaATS can open too, and so do ATSA and ATSH. If the analysis sounds wrong, try a different lowest frequency first. For a sound whose lowest note is above 100 Hz, try 100. A noisy sound with a low threshold can break into thousands of tracks and take a long time; raise the amplitude threshold then.

## The window

The picture is time from left to right and frequency from bottom to top, on a logarithmic scale, so every octave has the same height. The Hz labels are on the left and the note names on the right. At first the labels show only the C's, and zooming in shows more notes.

- Every sine partial is a line. The brighter the line, the louder the partial at that moment. Partials more than 80 dB below the loudest are not drawn, but they stay in the file.
- The faint orange layer behind the lines is the noise, shown in its 25 bands. The checkbox Noise layer, at the top right, switches it on and off.
- The line at the top gives the file name, the number of partials and frames, the length, the sample rate and the distance between frames. A star after the name means there are changes that have not been saved.
- Moving the mouse over the picture shows the time, the frequency and the note name. When the mouse is close to a partial, that partial turns white and its number, frequency and level are shown.
- Selected points are pink.
- The playhead is a yellow line across the picture, with a marker on the time ruler and its time in a small label. It shows where AUDITION starts, and it moves while the sound plays.
- A green message on the third line at the top reports what the last action did. The buttons AUDITION, PRINT and EXPORT .ats and the Noise layer checkbox are at the top right.

## Looking around

| Control | What it does |
|---|---|
| Mouse wheel | Zoom in time, around the mouse. |
| Ctrl + mouse wheel | Zoom in frequency, around the mouse. |
| Shift + mouse wheel | Scroll in time. |
| Right or middle mouse button, drag | Pan in time and frequency. |
| F or Home | Fit the view to the whole file. |
| P | Show or hide the partials. |
| N | Show or hide the noise layer (the same as the checkbox). |

## Selecting

Drag with the left mouse button to draw a box. Every point of every partial inside the box is selected. Hold Shift while you start the box to add to the selection. A click on empty space clears the selection, and so does Esc. A second Esc closes the window.

A selection is made of points: one partial at one moment (one frame). This means you can select a piece of a partial and leave the rest. The header line shows how many points and partials are selected and the time and frequency range they cover.

## Editing

All edits work on the selected points.

- **Delete** makes the points silent. Their amplitude becomes 0, which is how ATS marks a partial that is not sounding.
- **Up and Down** transpose the points by a semitone. Shift makes it 10 cents and Ctrl makes it an octave.
- **Dragging** a selected point moves the whole selection. Press on one of the pink points to start. Sideways movement shifts the points in time, in whole frames, because the file stores one value per frame. Vertical movement changes the frequency continuously. Hold Shift to lock the drag to the direction you start in. While you drag, the selection dims and a lighter copy shows where it will land.
- **Left and Right** move the selection one frame in time. Ctrl makes it ten frames.
- **Ctrl+Z** undoes the last edit, and **Ctrl+Y** redoes it. Ctrl+Shift+Z redoes too.

A piece of a partial that moves keeps its own row in the file if the place it moves to is empty. If that row is busy there, the piece goes into the nearest row that is silent, and if there is none it gets a new row. Nothing is ever written over other data, so two partials can sit at the same time and frequency and both sound. A move cannot take points outside the first and last frame of the file. A file can therefore end up with more partials than the original.

After a move or a transposition the selection stays with the points, so you can go on with the same selection.

## Saving

Ctrl+S saves the changes next to the original as a new file, name_edit.ats. If that file exists, the next one is name_edit2.ats, and so on. The original is never overwritten.

The saved file keeps the phase information (file type 4 when the file has noise bands). Pieces of partials that you did not touch keep the phase of the original. A piece that you changed gets new phases that follow its new frequencies, so the file stays consistent: programs that use the phase, such as pyatsyn, play the edited partials correctly, and Csound reads the file as well. If the opened file had no phase, phases are made for every partial. The largest amplitude and frequency in the file header are recalculated from the edited data.

The EXPORT .ats button, at the top right, or Ctrl+Shift+S, lets you choose the folder and the name of the .ats file. It uses a file dialog (this needs the JS_ReaScriptAPI extension, which most REAPER installations with ReaPack have) or, without it, a box in which you type the full path. The ending .ats is added if you leave it out, and ReaATS asks before it replaces a file that already exists. Use it to export a file for Csound or another program, and to put the file where you want it. Like Ctrl+S, it keeps the phase.

The saved files are standard ATS files. Csound reads them with its ATS opcodes, and so do other ATS programs. Opening works the other way round: O opens any ATS file, including the files Csound's own analyser makes.

O opens another file. R loads the file you opened again from disk and drops all changes since.

## Listening: AUDITION

The AUDITION button, or the A key, plays the edited sound. ReaATS builds the sound from the current data, the sines from the partials and the noise from the 25 noise bands, writes it to a temporary WAV file and plays that through REAPER's preview. Your project is not touched. The sound is made first, which takes a moment: for two seconds of sound about a tenth of a second for the sines and about a second more for the noise bands, and longer sounds take proportionally longer. While it is being made, the AUDITION button blinks, a small bar with the percentage shows under the button, and the status line shows how far it is, so you know the sound will start soon. The sound starts by itself when it is ready. Space stops the sound, and cancels the sound that is still being made. If you change the data while the sound is being made, it is cancelled too, because it would not match any more.

**The playhead.** AUDITION starts at the playhead. Click anywhere in the picture, on empty space, to put the playhead there. That click also clears the selection. You can also click on the time ruler, the strip with the seconds under the picture, or drag along the ruler to move the playhead. While the sound plays, the playhead moves along the picture. When the sound ends, or when you stop it with Space, the playhead goes back to where you put it, so you can listen to the same place again. The sound starts at the beginning of the analysis frame that holds the playhead, which is at most one frame, 10 ms in the example file, before it. PRINT also starts at the playhead (see below).

What you hear follows what you see. With P off you hear only the noise, with N off only the sines, and with both off nothing is played. This lets you listen to the two parts of a sound separately.

The sines come out at the level of the original. The noise bands are about 30 dB quieter, as they were in the analysis. The sound was checked against Csound's own ATS resynthesis of the example file: the level is the same, within a tenth of a dB, for the sines, the noise and the two together. The noise bands are made with filtered noise, so a band is slightly softer at its edges than in the original program and sounds a little different, but its level follows the file. AUDITION needs the SWS extension. If it is missing, the status message says so, and the WAV is still made.

## Putting the result in the project: PRINT

The PRINT button, or Ctrl+P, turns the current sound into a sample on a track. The sound is made first, as for AUDITION: the PRINT button blinks and a bar with the percentage shows under it. Esc cancels a print that is still being made, and so does a change to the data. ReaATS first saves unsaved changes as name_edit.ats, then renders a permanent WAV next to the .ats file, called name_print1.wav, and puts it on the selected track at the edit cursor. If no track is selected, a new track called ReaATS is made. Each press makes a new numbered file, and nothing is overwritten.

PRINT starts at the playhead, like AUDITION: the printed sound runs from the playhead to the end of the sound, so with the playhead at 0 you get the whole sound. The status line says where the print started, for example "printed 1.2 s from 1.00 s". As for AUDITION, the sound starts at the beginning of the analysis frame that holds the playhead. ReaATS remembers the start with the item, and when ReaSnap restores a snapshot the playhead comes back to it.

The WAV lives next to the .ats file and not inside the project. Copy it with the project if you move the project to another computer.

## ReaSnap

ReaATS works the same without ReaSnap. If you use ReaSnap, it can remember and bring back what you were doing, using the contract ReaSnap describes for its tools.

- PRINT writes the settings that made the item into the project, under the item: the .ats file, the view (time and frequency range) and the state of the partials and noise switches.
- Restoring a snapshot opens the editor on that file with the same view. If the .ats file has been moved or deleted, the editor says so and opens the file you used last instead.
- The window title carries the number ReaSnap gives it, such as ATS Editor #2, and Close All in ReaSnap closes the editor of that project.

ReaATS is in ReaSnap's list of tools. The command ID in that list depends on where the script was loaded in REAPER, so on another computer ReaSnap needs the ID of that computer's ATS_Editor.lua.

## All controls

| Control | What it does |
|---|---|
| Left drag | Select with a box. With Shift: add to the selection. |
| Left drag on a selected point | Move the selection. With Shift: one direction only. |
| Click on empty space | Clear the selection. |
| Right or middle drag | Pan. |
| Mouse wheel | Zoom in time. With Ctrl: zoom in frequency. With Shift: scroll in time. |
| Delete | Silence the selected points. |
| Up and Down | Transpose by a semitone. Shift: 10 cents. Ctrl: an octave. |
| Left and Right | Move one frame in time. Ctrl: ten frames. |
| Ctrl+Z, Ctrl+Y | Undo, redo. |
| Ctrl+S | Save as name_edit.ats. |
| EXPORT .ats, Ctrl+Shift+S | Export an .ats file: choose the folder and the name. |
| ANALYSE, Ctrl+A | Open the Analysis page. |
| A, AUDITION | Play the edited sound, from the playhead. |
| Click on the picture, or click or drag on the time ruler | Set the playhead. |
| Space | Stop the sound. |
| Ctrl+P, PRINT | Put the edited sound on a track, from the playhead. |
| P, N | Show or hide the partials, the noise. This also decides what is heard. |
| F, Home | Fit the view. |
| O, R | Open a file, reload the file. |
| Esc | Clear the selection, then close the window. |

## Good to know

- The file stores one value per frame, and the frames are evenly spaced. In the example file they are 10 ms apart. Moves in time snap to whole frames.
- ReaATS never overwrites the original .ats file. Saved changes always go to a new file.
- The temporary WAV files of AUDITION are kept in the temporary folder, numbered. The older ones are deleted after four auditions.
- Not built yet: analysis straight from an item in REAPER, playing only the selection, changing amplitudes, copy and paste, and stretching in time.
- Keep the original .ats file. A saved file is a new file, but the phases of changed partials are calculated and not measured.
