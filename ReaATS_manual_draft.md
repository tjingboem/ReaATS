# ReaATS

## What it does

ReaATS is a partial editor for REAPER, in the spirit of SPEAR. It opens ATS analysis files, the files that Csound's ATS opcodes use, and shows the sound inside them: a set of sine waves (the partials) that each follow their own frequency and loudness through time, plus the noise that is left over. You select parts of the partials, delete them, transpose them or move them, listen to the result, and put the result in your project as a new sample.

An ATS file is not a recording. A sound is analysed into partials, the sine waves that make up its pitched part, and a residual, the rest, stored as the energy in 25 bands. ATS can build the sound back from these two things. Because every partial is a separate line, you can change one harmonic of a saxophone and leave the rest alone, which you cannot do in an ordinary waveform.

ReaATS is a Lua script that runs inside REAPER on Linux. The sound is made by Csound.

## What you need

- REAPER, with the script loaded from the action list.
- The SWS extension, for AUDITION. PRINT does not need it.
- Csound, for AUDITION and PRINT. It was tried with Csound 7.0. ReaATS looks for it at /usr/local/bin/csound, /usr/bin/csound and /opt/csound/bin/csound, and otherwise expects it on the path.
- An .ats file. Csound can make one itself, see Making an .ats file, below. A small example, sax.ats, comes with ReaATS in the examples folder.

Only Linux has been tried. Temporary files go to the temporary folder (TMPDIR, or /tmp).

## Installing

Put the ReaATS folder (ATS_Editor.lua and the lib folder next to it) in REAPER's Scripts folder, for example Scripts/tjingboem/ReaATS. In REAPER open Actions, Show action list, choose ReaScript: Load and pick ATS_Editor.lua. Run it from the list, or give it a shortcut or a toolbar button.

The first time, ReaATS asks for an .ats file. After that it reopens the file you used last. The lib folder must stay next to the script: it holds the reader and writer for .ats files and the editing logic.

## Making an .ats file

Csound has the analysis program built in. From a terminal:

csound -U atsa sound.wav sound.ats -l 100

Use a mono file. The settings that matter most:

| Flag | What it sets | Default |
|---|---|---|
| -l | The lowest frequency to analyse. The analysis window is four cycles of this frequency long, so a low value gives a long window: good frequency detail, but fast changes are smeared in time. Set it a little below the lowest note in the sound. | 20 Hz |
| -H | The highest frequency to analyse. | 20000 Hz |
| -b and -e | Where to start and how long to analyse, in seconds. | whole file |
| -h | The distance between frames, as a fraction of the window. | 0.25 |
| -m | The quietest peak that counts, in dB. | -60 |
| -F | The file type. 4 stores amplitude, frequency, phase and noise. 3 stores amplitude, frequency and noise. | 4 |

If the analysis sounds wrong, try a different -l first. For a sound whose lowest note is above 100 Hz, try -l 100. Other programs that write ATS files, such as ATSA and ATSH, or the Python package pyatsyn, make files ReaATS can open too. The analysis does not happen inside ReaATS yet.

## The window

The picture is time from left to right and frequency from bottom to top, on a logarithmic scale, so every octave has the same height. The Hz labels are on the left and the note names on the right. At first the labels show only the C's, and zooming in shows more notes.

- Every sine partial is a line. The brighter the line, the louder the partial at that moment. Partials more than 80 dB below the loudest are not drawn, but they stay in the file.
- The faint orange layer behind the lines is the noise, shown in its 25 bands. The checkbox Noise layer, at the top right, switches it on and off.
- The line at the top gives the file name, the number of partials and frames, the length, the sample rate and the distance between frames. A star after the name means there are changes that have not been saved.
- Moving the mouse over the picture shows the time, the frequency and the note name. When the mouse is close to a partial, that partial turns white and its number, frequency and level are shown.
- Selected points are pink.
- A green message at the top right reports what the last action did.

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

The saved file has no phase information (file type 3). The stored phases belong to the original sound and are wrong once the partials are changed, and Csound's own ATS opcodes ignore phase anyway. The largest amplitude and frequency in the file header are recalculated from the edited data.

O opens another file. R loads the file you opened again from disk and drops all changes since.

## Listening: AUDITION

The AUDITION button, or the A key, plays the edited sound. ReaATS writes the current data to a temporary .ats file, lets Csound make a WAV from it (atsadd for the sines and atsaddnz for the noise bands) and plays the WAV through REAPER's preview. Your project is not touched. For a sound of two seconds this takes about a tenth of a second, and REAPER waits for it. Space stops the sound.

What you hear follows what you see. With P off you hear only the noise, with N off only the sines, and with both off nothing is played. This lets you listen to the two parts of a sound separately.

The sines come out at the level of the original. The noise bands are about 30 dB quieter, as they were in the analysis. AUDITION needs the SWS extension. If it is missing, the status message says so, and the WAV is still made.

## Putting the result in the project: PRINT

The PRINT button, or Ctrl+P, turns the current sound into a sample on a track. ReaATS first saves unsaved changes as name_edit.ats, then renders a permanent WAV next to the .ats file, called name_print1.wav, and puts it on the selected track at the edit cursor. If no track is selected, a new track called ReaATS is made. Each press makes a new numbered file, and nothing is overwritten.

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
| A, AUDITION | Play the edited sound. |
| Space | Stop the sound. |
| Ctrl+P, PRINT | Put the edited sound on a track. |
| P, N | Show or hide the partials, the noise. This also decides what is heard. |
| F, Home | Fit the view. |
| O, R | Open a file, reload the file. |
| Esc | Clear the selection, then close the window. |

## Good to know

- The file stores one value per frame, and the frames are evenly spaced. In the example file they are 10 ms apart. Moves in time snap to whole frames.
- ReaATS never overwrites the original .ats file. Saved changes always go to a new file.
- Temporary files, the audition .ats, .csd and the numbered WAV files, are kept in the temporary folder. The older WAV files are deleted after four auditions.
- Not built yet: analysis straight from an item in REAPER, playing only the selection, changing amplitudes, copy and paste, and stretching in time.
- Keep the original .ats file. Saved files have no phase.
