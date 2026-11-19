# ReaATS manual: additions of 19 November 2026

Written for tjingboem to paste into `docs/ReaATS.odt` by hand. The ODT itself has not been touched.
Plain text, in the manual's own style. Each part says where it belongs.
The window features (B) are written for ReaATS' own window, which is a gfx window and has no title bar of its own.


## A. Replacements in existing paragraphs (PRINT and ReaSnap)

### A1. In "Printing: PRINT" (multichannel paragraph), replace the last sentence

Old:
> The item remembers all the files of the set, and ReaSnap brings the whole set back.

New:
> The item keeps the settings of the set on itself: the files of all channels, the name, the view and the partials. A copy of the item carries them too, and ReaSnap brings the whole set back (see Settings on the item, and windows).

### A2. In "Where the files go" / "Good to know", replace the paragraph "The settings that ReaSnap keeps with a printed item ..."

Old:
> The settings that ReaSnap keeps with a printed item name the .ats file by its full path. On another computer, open the file from the ReaATS folder by hand (the O key) if the path is not the same.

New:
> The settings that a printed item carries name the .ats file by its full path. On another computer, open the file from the ReaATS folder by hand (the O key) if the path is not the same.

### A3. At the end of the paragraph "PRINT: putting the result in the project", add one sentence

> The printed item carries ReaATS' settings (see Settings on the item, and windows).


## B. New section: "Settings on the item, and windows"

Place: after "Saving and exchanging files", or as the last numbered chapter before "All controls". Your choice.

### Settings on the item

When PRINT puts a sound on a track, the item gets ReaATS' settings: the .ats file (or the files of all channels), its name, the view of the picture, the switches and the partials. They sit on the item itself. A copy of the item carries them, so you can copy a printed item, move it, and still open it again later. In ReaSnap, select the item and press S on ReaATS' row: the editor opens with the settings of that item. A snapshot of ReaSnap brings the item back with them.

If the .ats file is no longer where it was, ReaATS cannot open it. The window stays as it is and nothing is lost. Open the file by hand with O.

### One window

Only one ReaATS window is open at a time. If you start ReaATS while another one is open, the second one does not open: it hands what ReaSnap gave it (the settings of an item) to the open window and ends. Pin the open window (see below) when you want to keep it and have another one.

REAPER asks "Terminate or New instance?" when a script is started a second time. Choose New instance and tick Remember.

ReaATS cannot bring its window to the front by itself. If you do not see it, it is behind another window.

### Follow

A window that ReaSnap has started follows the item you select: it opens the settings of the selected item, when that item carries ReaATS settings. An item without ReaATS settings leaves the window as it is. A window that you opened from the Actions list never follows the selection.

Following replaces what is open. If you have unsaved changes in any channel, ReaATS asks first, in a small menu:
- save the changes, then load the item;
- discard the changes and load the item;
- stay as you are.

The question does not come when the file of the item is already open: then only the view, the switches and the playhead are set from the item. While a sound is still being made, nothing is loaded.

### The pin

The words "tjingboem productions" at the bottom right of the window, along the right edge, are the pin. Click them: they turn blue and the window stays as it is. A pinned window does not follow the selection and is never handed over to. Click again to let go. Use the pin when you want to compare two sounds in two windows.

### The place

ReaATS remembers where you put its window and how large it was, and opens there next time. A new window opens beside a pinned one, so it does not cover it. A window that is docked has no place of its own. If you move the window to another screen, the new place is remembered after a short moment, and also when you close it.


## C. Rows for the tables

### C1. "The Editor: mouse" (Key or mouse | What it does)

| Key or mouse | What it does |
|---|---|
| Click on "tjingboem productions" (bottom right) | Pins the window (blue); another click lets go. A pinned window does not follow the selection. |

### C2. "All controls", wherever the ReaSnap or window items belong

Nothing else is needed: the pin is the only new control.


## What I could not check

- How the pin looks in your real window: letters turned along the edge, or stacked upright (a fallback). The text above says only "along the right edge".
- Windows and macOS: the saved position is corrected by an offset that is measured on the first frames. Only tested on Linux (KDE, X11).
- The ask-first menu and the click on the pin were not tried on a real screen, only the logic.
