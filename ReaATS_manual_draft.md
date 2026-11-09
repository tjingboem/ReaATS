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

ReaATS starts with an empty window: it does not reopen the file you used last. Press O to open an .ats file, or click ANALYSE to make one from a sound. The lib folder must stay next to the script: it holds the reader and writer for .ats files and the editing logic.

## Making an .ats file: the Analysis page

The ANALYSE button, at the top right of the window (or Ctrl+A), opens the Analysis page. It is there even when no .ats file is open yet. The page analyses a sound into .ats files and opens the result in the editor. Esc, or the BACK button, returns to the editor.

**Importing an .ats file.** The button Import .ats file... on the page opens an existing .ats file, for example one that you made with Csound, and returns to the editor. It does the same as the O key in the editor.

**Choosing the sound.** Select an audio item in REAPER and click Use selected item. Only the part of the file that the item plays is analysed, from its start offset for its length. Volume, fades, effects and pitch changes on the item are not applied, because the analysis reads the file itself. Or click Choose WAV file... and pick any WAV file. The sound must be a WAV file (PCM, 8 to 32 bit, or float). If the item's file is another format, render it to WAV first (Glue, or File, Render) and select the new item. The page shows the sample rate, the channels and the length of the sound, in seconds and, for a minute or more, also as minutes:seconds (536 seconds is 8:56).

**The options.** The page has every option of the analysis. Click a value to type a new one, or point at it and use the mouse wheel (Shift for finer steps). Point at an option to see a short explanation at the bottom. The line under the options shows what the settings mean for this sound: the window length in samples and milliseconds, the FFT size, the hop and the number of frames. It warns when the window is longer than the part that is analysed.

| Option | What it sets | Default |
|---|---|---|
| Start, Duration | Where to start and how long to analyse, in seconds. 0 means the whole sound. | 0 |
| Channels to analyse | How many channels are analysed, each into a file of its own (see below). When you choose a sound, this is set to all its channels. | all |
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
| Share rows between tracks | Tracks that do not overlap in time use the same partial row of the file, with one silent frame between them. The sound is exactly the same, and the file of a long sound is 20 to 100 times smaller: 240 seconds of music gave 8894 rows and a file of 4.9 GB, and about 100 rows and a file of some tens of MB when rows are shared. Switch it off only if you want every track to have a row of its own, as the original ATS analysis does. A row then holds several unrelated tracks one after another, so a row is no longer "one partial". | on |

The buttons Defaults and Csound defaults reset the options. Csound's analyser differs in one default only: the SMR contribution is 0.5. Your settings are remembered the next time. Csound's analyser has two options that this one has not: the SMR threshold and the minimum segment SMR.

**Analysing.** Click ANALYSE. The analysis runs in the background while the page shows it at work: the page is dimmed, the big word ANALYZING... blinks, the ANALYSE button blinks, and a bar shows how far the analysis is, with the percentage and the seconds so far. Cancel stops the analysis and leaves no file behind. If the analysis program has stopped answering, for example because it crashed, the page notices after two minutes without a sign of life and says so, so the page never waits forever. A Cancel that the program does not answer ends after 8 seconds. You can also leave the page with Esc: the analysis goes on, and the result opens in the editor when it is done. The page then shows what was made, and the first file is open in the editor. The result is saved next to the sound as name.ats. If that name exists, name_2.ats is used. With Change... you choose another place and name, and ReaATS asks before it replaces a file.

**Several channels.** With Channels to analyse set to 2 or more, each channel is analysed on its own with the same options and written to its own file: name_ch1.ats, name_ch2.ats, and so on. All the files of a set have the same frame size, number of frames and length. The channels are analysed at the same time on separate cores of your computer, so a set of channels takes much less time than one channel after the other: in a test, 8 channels of 20 seconds took 11 seconds instead of 30. The result is exactly the same files as when the channels are analysed one after the other. The files only get their real names when every channel is done, so a cancelled analysis leaves nothing behind and does not touch a file that was there before. The editor opens the first channel. The Open buttons on the page open the others, one at a time.

**What it needs.** The analysis is done by a small program that comes with ReaATS, python/reaats_analyse.py. It needs Python 3.8 or newer and the numpy package on your computer, and nothing else. REAPER users usually have Python already. ReaATS looks for it in the place REAPER is set to use for ReaScript (Options, Preferences, Plug-ins, ReaScript), and then in the usual places. The top right of the Analysis page shows which Python it found and which numpy, and a Check button looks again.

If ReaATS cannot find a Python that will do, a window opens when you click ANALYSE. It says what is missing: no Python, no numpy, or a Python that is too old. It tells you to download Python from python.org and install it, to install numpy (python3 -m pip install numpy) and to tell REAPER where Python is, in Options, Preferences, Plug-ins, ReaScript. It also offers to open the download page. After you have done this, click Check on the page, or restart REAPER, and try again. There is no analysis without Python.

The program also works from a terminal, for scripts:

python3 python/reaats_analyse.py sound.wav sound.ats --lowest-frequency 100

python3 python/reaats_analyse.py --help lists all the options. The analysis is the one of the pyatsyn package. Csound's own analyser, csound -U atsa sound.wav sound.ats -l 100, makes files that ReaATS can open too, and so do ATSA and ATSH. If the analysis sounds wrong, try a different lowest frequency first. For a sound whose lowest note is above 100 Hz, try 100. The time an analysis takes depends mostly on how many peaks it finds, not on how long the sound is. A long or noisy recording with the default threshold of -60 dB finds thousands of tiny partials, most of them noise, and can take hours. In one test, the first 30 seconds of a 9 minute recording took 52 seconds at -60 dB, 18 seconds at -50 dB, 10 seconds at -40 dB and 5 seconds at -30 dB. So for long sounds, music and field recordings, raise the amplitude threshold to about -40 dB, or analyse a shorter part with Start and Duration. The page shows a warning when a long sound is set to a low threshold. The noise that the many tiny partials would have caught is stored in the noise bands anyway.

## The window

The picture is time from left to right and frequency from bottom to top, on a logarithmic scale, so every octave has the same height. The Hz labels are on the left and the note names on the right. At first the labels show only the C's, and zooming in shows more notes.

- Every sine partial is a line. The brighter the line, the louder the partial at that moment. Partials more than 80 dB below the loudest are not drawn, but they stay in the file.
- The faint orange layer behind the lines is the noise, shown in its 25 bands. The checkbox Noise layer, at the top right, switches it on and off. The checkbox Sine layer, just under it, does the same for the partial lines. The two layers can be shown alone or together. The same switches decide what you hear in AUDITION and what PRINT makes: with Sine layer off you hear only the noise, and with Noise layer off only the sines. While the sine layer is off you cannot select partials, so that no edit is made on something that is hidden.
- The line at the top gives the file name, the number of partials and frames, the length, the sample rate and the distance between frames. A star after the name means there are changes that have not been saved.
- Moving the mouse over the picture shows the time, the frequency and the note name. When the mouse is close to a partial, that partial turns white and its number, frequency and level are shown.
- Selected points are pink.
- The playhead is a yellow line across the picture, with a marker on the time ruler and its time in a small label. It shows where AUDITION and PRINT start, and it moves while the sound plays. Home puts it at the start (the |< button under PRINT does the same and shows where it is).
- A green message on the third line at the top reports what the last action did. The buttons AUDITION, PRINT and EXPORT .ats and the Noise layer checkbox are at the top right.

## Looking around

| Control | What it does |
|---|---|
| Mouse wheel | Zoom in time, around the mouse. |
| Ctrl + mouse wheel | Zoom in frequency, around the mouse. |
| Shift + mouse wheel | Scroll in time. |
| Right or middle mouse button, drag | Pan in time and frequency. |
| Right-click (no drag) | Show the whole file, like F. The same as in ReaShapeM. |
| F or Home | Fit the view to the whole file. |
| P | Show or hide the partials. |
| N | Show or hide the noise layer (the same as the checkbox). |

## Selecting

**Lasso.** Hold Alt and drag to draw a freehand loop. When you let go, the loop is closed and the points inside it are selected, in every channel that is on and green, like a box. Hold Shift as well to add the loop to the selection you have. A lasso follows a curved line of partials much better than a box. On many Linux desktops Alt+drag is used by the window manager to move windows, so the loop does not reach ReaATS. If that happens, change the modifier of the window manager (in GNOME: gsettings set org.gnome.desktop.wm.preferences mouse-button-modifier '<Super>') or tell the developer, and another key can be used.

Drag with the left mouse button to draw a box. Every point of every partial inside the box is selected. Hold Shift while you start the box to add to the selection. A click on empty space clears the selection, and so does Esc. A second Esc closes the window.

A selection is made of points: one partial at one moment (one frame). This means you can select a piece of a partial and leave the rest. The header line shows how many points and partials are selected and the time and frequency range they cover.

## Editing

All edits work on the selected points.

- **Delete** makes the points silent. Their amplitude becomes 0, which is how ATS marks a partial that is not sounding.
- **Up and Down** transpose the points by a semitone. Shift makes it 10 cents and Ctrl makes it an octave.
- **Dragging** a selected point moves the whole selection. Press on one of the pink points to start. Sideways movement shifts the points in time, in whole frames, because the file stores one value per frame. Vertical movement changes the frequency continuously. Hold Shift to lock the drag to the direction you start in. While you drag, the selection dims and a lighter copy shows where it will land.
- **Left and Right** move the selection one frame in time. Ctrl makes it ten frames.
- **Ctrl+C, Ctrl+X and Ctrl+V** copy, cut and paste, see below.
- **Ctrl+Z** undoes the last edit, and **Ctrl+Y** redoes it. Ctrl+Shift+Z redoes too.

A piece of a partial that moves keeps its own row in the file if the place it moves to is empty. If that row is busy there, the piece goes into the nearest row that is silent, and if there is none it gets a new row. Nothing is ever written over other data, so two partials can sit at the same time and frequency and both sound. A move cannot take points outside the first and last frame of the file. A file can therefore end up with more partials than the original.

After a move or a transposition the selection stays with the points, so you can go on with the same selection.

**Copy, cut and paste.** Select points and press Ctrl+C to copy them. Ctrl+X copies and then deletes them. Put the playhead where you want the copy (click in the picture or on the time ruler) and press Ctrl+V: the points are pasted so that the first copied point lands at the playhead, with the same frequencies and amplitudes. You can paste as often as you like, at other places, and in a file you open later in the same editor window. The pasted points are selected, so you can move them, transpose them or bend them right away. A paste works like a move: it never writes over other sound. A piece goes into the same row when the place is empty, otherwise into the nearest silent row, otherwise into a new row. Points that would land after the end of the file are left out, and the status line says how many. With several channels, a copy takes the selected points of every channel that is on and green, and a paste puts every channel's points back into the channel with the same number, if that channel is on and green now. The channels keep their timing against each other. One Ctrl+Z takes a paste back from all the channels at once.

## Stereo and multichannel sounds

A stereo or multichannel analysis gives one .ats file per channel: name_ch1.ats, name_ch2.ats and so on (see the Analysis page). When you open one of them in the editor, with O or with the Open buttons on the Analysis page, ReaATS finds the others and opens the whole set at the channel you picked. The files must have the same frame size, the same number of frames and the same length, as they do when they come from one analysis. If they do not fit together, or one is missing, ReaATS opens the file you chose alone and the status line says why.

**Channel buttons.** With two or more channels there is an extra row under the header with a button for each channel (1, 2, 3, ...), each in its own colour, and a slider next to it. A button is a switch: click it to turn that channel on or off. A channel that is on is drawn; a channel that is off is not drawn and is not edited. One channel always stays on. A star on a button means that channel has changes that are not saved.

**Which channels are edited: the LEDs.** Above each channel button is a small LED. Green means the channel is edited together with the other green channels; red means it is left alone. Click the LED to change it. Selecting, delete, transpose and move go only to channels that are green and switched on. A red channel stays visible, it just cannot be changed, and it loses its selection when it turns red. All LEDs start green.

**Stack and overlay.** The button at the end of the row, or the V key, chooses how the channels that are on are shown. In STACK each channel has its own lane, one under the other, with the same time axis and the same frequency range, so you can compare the channels at a glance; the lanes are named ch 1, ch 2 and so on. In OVERLAY all the channels are drawn in one picture, each in its own colour (the louder the partial, the brighter the colour). Tab shows one channel alone, the next one each time you press it, and after the last channel all channels again.

**Visibility sliders.** The slider next to a button sets how strongly that channel is drawn, from 20 % to 100 %. Use it in the overlay to push one channel into the background, or in the stack to dim a lane. It only changes the picture, never the edits and never the sound: AUDITION and PRINT always use every channel. A channel that is off counts as 0 %.

**Editing channels together.** A selection box selects the same time and frequency region in every channel that is on, each channel selecting its own points. Delete, transpose and move (with the arrow keys or by dragging a selected point) then apply to all those channels at once, and the header shows the total. Switch channels off to edit only some of them. An edit in several channels is one step for Ctrl+Z and Ctrl+Y: one press undoes it in every channel it touched.

**Listening: AUDITION.** AUDITION plays all channels together, from the playhead. REAPER's preview is stereo, so a set with more than two channels is mixed down to stereo for listening: channel 1 goes to the left, the last channel to the right, and the channels in between are spread evenly between them. The level is set so that the mixdown is not louder than one channel would be. A set of exactly two channels is played as it is, channel 1 left and channel 2 right. The status line says "3 channels mixed down to stereo" when this happens. The partials and noise switches count for all channels.

**Printing: PRINT.** PRINT keeps all the channels. It makes one multichannel WAV file, one channel of sound for each channel file, from the playhead, and puts it on the selected track. A track needs room for the channels, so ReaATS raises the number of channels of that track to the next even number that is large enough, for example 4 for a sound of 3 channels. REAPER itself must be set up for multichannel use: route the track's channels to where you want them, for example to the outputs of your interface. The item remembers all the files of the set, and ReaSnap brings the whole set back.

## Saving

Ctrl+S saves the changes next to the original as a new file, name_edit.ats. If that file exists, the next one is name_edit2.ats, and so on. The original is never overwritten. For a set of channels, every channel is saved, as name_edit_ch1.ats, name_edit_ch2.ats and so on, so that the saved set opens as a set again.

The saved file keeps the phase information (file type 4 when the file has noise bands). Pieces of partials that you did not touch keep the phase of the original. A piece that you changed gets new phases that follow its new frequencies, so the file stays consistent: programs that use the phase, such as pyatsyn, play the edited partials correctly, and Csound reads the file as well. If the opened file had no phase, phases are made for every partial. The largest amplitude and frequency in the file header are recalculated from the edited data.

The EXPORT .ats button, at the top right, or Ctrl+Shift+S, lets you choose the folder and the name of the .ats file. It uses a file dialog (this needs the JS_ReaScriptAPI extension, which most REAPER installations with ReaPack have) or, without it, a box in which you type the full path. The ending .ats is added if you leave it out, and ReaATS asks before it replaces a file that already exists. Use it to export a file for Csound or another program, and to put the file where you want it. Like Ctrl+S, it keeps the phase. For a set of channels you choose one name, and every channel is written from it: choose mysound.ats and you get mysound_ch1.ats, mysound_ch2.ats and so on. ReaATS asks before it replaces any of them.

The saved files are standard ATS files. Csound reads them with its ATS opcodes, and so do other ATS programs. Opening works the other way round: O opens any ATS file, including the files Csound's own analyser makes.

O opens another file. R loads the file you opened again from disk and drops all changes since.

## Listening: AUDITION

The AUDITION button, or the A key, plays the edited sound. ReaATS builds the sound from the current data, the sines from the partials and the noise from the 25 noise bands, writes it to a temporary WAV file and plays that through REAPER's preview. Your project is not touched. The sound is made first, which takes a moment. How long depends on how the sound is made (see below). While it is being made, the AUDITION button blinks, a small bar with the percentage shows under the button, and the status line shows how far it is, so you know the sound will start soon. The sound starts by itself when it is ready. Space stops the sound, and cancels the sound that is still being made. If you change the data while the sound is being made, it is cancelled too, because it would not match any more.

**How fast it is made.** If Python with numpy is installed (it is needed for the Analysis page anyway), ReaATS makes the sound in a program that runs in the background (python/reaats_synth.py). Your edited data is handed to it in temporary files, and the window does not freeze. Without Python, or if that program fails, ReaATS makes the sound itself, in small steps (the status line says what happened and which one made the sound: "Python synthesis" or "Lua synthesis"). Both give the same sound: the sines are identical, and the noise has the same level (it is made from random numbers, so it is a different realisation each time you analyse, but it sounds the same). Three things make repeated listening quick:
- The noise does not change when you edit partials, so ReaATS keeps it. The first AUDITION of a sound makes the noise, the next ones, after you edit, only make the sines. The Python program keeps it in a folder reaats_noise_cache in the temporary folder (at most 40 files, 400 MB), the built-in synthesis keeps it in memory (about 21 MB for 30 seconds of one channel).
- If nothing has changed since the last sound was made, AUDITION does not make it again. When the sound is not longer than two minutes, the first AUDITION makes the whole sound, from its beginning, and starts at the playhead. After that you can put the playhead anywhere and press AUDITION: the sound starts at once, as a piece cut out of the sound already made, and the same place again plays the same file. It counts as unchanged while the data, the Sine layer and Noise layer switches and the number of channels are the same. Any edit, undo, redo or newly loaded file makes a new sound. The status line says "replayed" or "from the sound already made" when this happens.
- With the Python program, the channels of a set are made at the same time, one per core of your computer (all cores but two, so that REAPER keeps room). The sound is exactly the same as when they are made one after the other. In a test with 30 seconds of sound, two channels took 3.4 seconds instead of 5.1, and four channels 5.9 instead of 10.0 (1.5 seconds when the noise was kept from an earlier sound).
- A band of noise that is silent for a while costs nothing in that stretch.

For a 30 second sound with 69 partials: the built-in synthesis needs about 9 seconds the first time and 1.6 seconds after that; the Python program 2.7 seconds the first time and 0.9 seconds after that.

**The playhead.** AUDITION starts at the playhead. Click anywhere in the picture, on empty space, to put the playhead there. That click also clears the selection. You can also click on the time ruler, the strip with the seconds under the picture, or drag along the ruler to move the playhead. While the sound plays, the playhead moves along the picture. When the sound ends, or when you stop it with Space, the playhead goes back to where you put it, so you can listen to the same place again. The sound starts at the beginning of the analysis frame that holds the playhead, which is at most one frame, 10 ms in the example file, before it. PRINT also starts at the playhead (see below).

What you hear follows what you see. With P off you hear only the noise, with N off only the sines, and with both off nothing is played. This lets you listen to the two parts of a sound separately.

The sines come out at the level of the original. The noise is made from the 25 noise bands in the file, as filtered noise.

**The level of the noise.** The ATS analysis stores for each noise band the average power per FFT bin, not the power of the whole band. A wide band, such as 3700-4400 Hz, holds much more energy than a narrow one, such as 200-300 Hz, with the same stored value. Csound's ATS synthesis plays the stored values as they are, so the narrow low bands come out too loud and the wide high bands too soft: in a test with a real recording the noise was 7 dB too loud at 200-800 Hz and 5 dB too soft above 4 kHz, and 3.7 dB too loud overall. The low bands are where most music lives, which makes the noise sound much too loud and dark. ReaATS therefore corrects it: every band's power is multiplied by its width, divided by the mean width of that moment, so that the energy of the moment stays the same and every band gets its right share. The overall level is set so that the synthesized noise has the same power as the real residual of the sound (the part that the partials did not describe): in two tests it came within 0.3 dB, and the spread between the bands went from 4.2 dB to 1.8 dB. If you want the Csound level and shape, the Python program can be given --noise-shape classic, and the synthesis of the editor can be told noise_shape = "classic"; this is what the sound would be in Csound's own ATS synthesis, within a tenth of a dB. AUDITION needs the SWS extension. If it is missing, the status message says so, and the WAV is still made.

## Putting the result in the project: PRINT

The PRINT button, or Ctrl+P, turns the current sound into a sample on a track. The sound is made first, as for AUDITION: the PRINT button blinks and a bar with the percentage shows under it. Esc cancels a print that is still being made, and so does a change to the data. ReaATS first saves unsaved changes as name_edit.ats, then renders a permanent WAV next to the .ats file, called name_print1.wav, and puts it on the selected track at the edit cursor. If no track is selected, a new track called ReaATS is made. Each press makes a new numbered file, and nothing is overwritten.

**Important: PRINT starts at the playhead, like AUDITION.** The printed sound runs from the playhead to the end of the sound, so only with the playhead at 0 do you get the whole sound. A click on empty space in the picture, or on the time ruler, moves the playhead, so check it before you print: the small button under PRINT, marked |<, shows where the playhead is ("|< 62.3 s", in amber, when it is not at the start, and "|< start" when it is). Click that button, or press Home, to put the playhead back at 0. End puts it at the end. When you press PRINT with the playhead away from the start, the status line says "preparing the print FROM 62.30 s". The status line says where the print started, for example "printed 1.2 s from 1.00 s". As for AUDITION, the sound starts at the beginning of the analysis frame that holds the playhead. ReaATS remembers the start with the item, and when ReaSnap restores a snapshot the playhead comes back to it.

The WAV lives next to the .ats file and not inside the project. Copy it with the project if you move the project to another computer.

## A side use: removing noise

ReaATS is made for creative work: to take a sound apart, change it and make something new from it. Cleaning a recording is not what it was built for, but it comes with the way it works, and it is useful to know. An analysis splits a sound in two: the partials, the sine lines you see in the picture, and the noise, the orange layer behind them. A sound that is made again from the partials alone is a sound without the noise. That also makes it possible to remove noise from sounds that have clear pitched parts, such as a voice, a wind instrument, a string, a bowed or plucked note, or a recording with a steady hum. It is not a filter: the clean sound is built again from the analysis, so you are listening to a resynthesis. This chapter shows how to do it with what ReaATS has now.

**Step 1: analyse so that the noise is left out of the partials.** On the Analysis page three options decide how much of the noise the analysis follows as if it were music:
- Raise the Amplitude threshold, for example from -60 dB to -50 or -40 dB. Hiss is made of many quiet peaks, and a higher threshold does not follow them. The partials that remain are the louder ones. A higher threshold also makes the analysis much faster.
- Raise the Minimum segment length, for example from 3 to 6 or 10 frames. Noise produces short, flickering tracks; this drops every track shorter than that.
- Keep Optimise on, so that the quiet and short tracks are pruned afterwards.
Set the Lowest frequency a little below the lowest note you want to keep (for a voice 70 Hz instead of 20 Hz), so that the window is not longer than it needs to be. Leave Store the noise bands on: you need the noise bands to hear the difference and to decide how much to keep.

**Step 2: listen with and without the noise.** Open the result and press A for AUDITION. Then switch the Noise layer off (the checkbox at the top right, or the N key) and press A again. This is the denoised sound. Because the noise layer is shown in orange you can also see what you are taking away. Switching the layer on and off while the same sound plays again is the quickest way to judge it: if the sound is still alive without the noise, you are almost done.

**Step 3: remove what is left in the partials.** Even with a high threshold some noise stays in the sine layer. You see it as faint, short, scattered lines, often in the high frequencies, and as long straight lines that never change: a hum at 50 or 60 Hz and its multiples, or the whine of a fan. Drag a box around them and press Delete. Zoom in with the mouse wheel to separate them from the notes you want. The box selects only the points inside it, so a note that crosses the box is not deleted as a whole. With a stereo or multichannel sound the box and Delete apply to every channel whose LED is green, and Ctrl+Z undoes it in all of them at once. AUDITION again after each step: the data is the only thing you change, the recording is never touched.

**Step 4: print it.** With the Noise layer switched off, press Ctrl+P or the PRINT button. The clean sound is made as a WAV file next to the .ats file and put on the selected track (or a new track) at the edit cursor as a new item. The original item stays where it is: put the new one on another track, or mute the original, to compare. Put the ReaATS playhead at 0 if you want the whole sound. ReaATS saves your edits as name_edit.ats first, so you can come back to them, and ReaSnap brings the settings back (see PRINT).

**What to expect.**
- The result is a resynthesis. What is not a partial is gone: breath, the consonants of speech, the pluck of a string, the click of a key and other noisy parts of the sound that belong to it. If the sound feels thin, dry or "watery", the noise layer is carrying too much of the character to be left out. The noise layer is all or nothing at present: there is no control for a part of its level, so you cannot yet keep it 12 dB down.
- Noise that sits under a partial is not removed from that partial. It is only removed when the noise is a separate track, or in the noise bands.
- A threshold that is too high removes the quiet end of a note, for example the decay of a long tone. Lower it a little, and make a new analysis, when notes end too early.
- The quality depends on the analysis. Pitched sounds with steady noise work best. Dense music with many instruments, or a sound that is mostly noise, gives a messy picture that is hard to clean by hand.
- A higher threshold removes more of the noise and makes the analysis faster.

## ReaSnap

ReaATS works the same without ReaSnap. If you use ReaSnap, it can remember and bring back what you were doing, using the contract ReaSnap describes for its tools.

- PRINT writes the settings that made the item into the project, under the item: the .ats file, the view (time and frequency range) and the state of the partials and noise switches.
- Restoring a snapshot opens the editor on that file with the same view. If the .ats file has been moved or deleted, the editor says so and stays empty.
- The window title carries the number ReaSnap gives it, such as ATS Editor #2, and Close All in ReaSnap closes the editor of that project.

ReaATS is in ReaSnap's list of tools. The command ID in that list depends on where the script was loaded in REAPER, so on another computer ReaSnap needs the ID of that computer's ATS_Editor.lua.

## All controls

| Control | What it does |
|---|---|
| Left drag | Select with a box. With Shift: add to the selection. |
| Alt + left drag | Select with a lasso: draw a loop round the points. With Shift: add to the selection. |
| Left drag on a selected point | Move the selection. With Shift: one direction only. |
| Click on empty space | Clear the selection. |
| Right or middle drag | Pan. |
| Mouse wheel | Zoom in time. With Ctrl: zoom in frequency. With Shift: scroll in time. |
| Delete | Silence the selected points. |
| Up and Down | Transpose by a semitone. Shift: 10 cents. Ctrl: an octave. |
| Left and Right | Move one frame in time. Ctrl: ten frames. |
| Ctrl+C, Ctrl+X, Ctrl+V | Copy, cut, paste the selected points. The paste starts at the playhead. |
| Ctrl+Z, Ctrl+Y | Undo, redo. |
| Ctrl+S | Save as name_edit.ats. |
| EXPORT .ats, Ctrl+Shift+S | Export an .ats file: choose the folder and the name. |
| ANALYSE, Ctrl+A | Open the Analysis page. |
| A, AUDITION | Play the edited sound, from the playhead. |
| Click on the picture, or click or drag on the time ruler | Set the playhead. |
| Space | Stop the sound. |
| Ctrl+P, PRINT | Put the edited sound on a track, from the playhead. |
| P, N, the checkboxes Sine layer and Noise layer | Show or hide the partials, the noise. This also decides what is heard. |
| F, right-click | Fit the view (the whole file). |
| Home, the |< button under PRINT | Put the playhead at the start of the sound. The button shows where the playhead is. End: at the end. |
| Tab | Show one channel alone, the next each time; after the last, all channels again. |
| V, the STACK / OVERLAY button | Channels under each other, or in one picture. |
| The channel buttons and sliders | Switch a channel on or off; how visible it is (20-100 %). |
| O, R | Open a file, reload the file. |
| Esc | Clear the selection, then close the window. |

## Good to know
- Long, dense analyses used to be enormous, because every track got a row of its own in the file. With Share rows between tracks (on by default) the file only has as many rows as there are tracks at the same moment, so a long sound is no longer a problem in the file. The editor holds all the numbers of the analysis in memory, about twice the size of the .ats files. Opening a new analysis first lets go of the one that is open. On Linux, ReaATS looks at how much memory the computer has free before it loads, and if the analysis does not fit it does not load it and tells you how much it needs. In that case analyse again with a higher Amplitude threshold (-50 or -40 dB) or a higher Lowest frequency, or analyse one channel at a time. The same measures make the analysis faster.

- The file stores one value per frame, and the frames are evenly spaced. In the example file they are 10 ms apart. Moves in time snap to whole frames.
- ReaATS never overwrites the original .ats file. Saved changes always go to a new file.
- The temporary WAV files of AUDITION are kept in the temporary folder, numbered. The older ones are deleted after four auditions.
- Not built yet: analysis straight from an item in REAPER, playing only the selection, changing amplitudes, copy and paste, and stretching in time.
- Keep the original .ats file. A saved file is a new file, but the phases of changed partials are calculated and not measured.
