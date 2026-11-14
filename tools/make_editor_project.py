#!/usr/bin/env python3
"""Make the ReaLayout project file of the ReaATS editor window from its layout JSON, so that ReaLayout starts from the layout the editor really uses.

    python3 tools/make_editor_project.py tools/reaATS_layout.json ~/Claude/ReaLayout/projects/reaats.js

(Open it with index.html?project=reaats. After editing in ReaLayout, Save to file, put the JSON in tools/ and run tools/gen_layout.py.)
The '_s' elements are the ones the editor reads (for one file and for a channel set alike); 'plot' and 'plot_s' are the picture without and with the channel row.
Bump STORAGE_VERSION when elements are added to the JSON: ReaLayout keeps the layout in the browser under the storage key, and an old stored layout
would hide the new elements (and a later export would drop them).
"""
import json
import sys

STORAGE_VERSION = 3


def q(s):
    return "'" + s.replace("\\", "\\\\").replace("'", "\\'") + "'"


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)
    els = json.load(open(sys.argv[1], encoding="utf-8"))
    lines = [
        "// ReaATS editor project for ReaLayout. Made by ReaATS/tools/make_editor_project.py from the layout that the editor reads (lib/layout.lua).",
        "// 1100 x 640, the default window. Open with index.html?project=reaats",
        "// Elements with '_s' are the ones the editor uses (one file or a channel set); 'plot' / 'plot_s' = the picture without / with the channel row.",
        "// The window can be resized: elements right of 72 % of the width hang on the right edge, below 85 % of the height on the bottom edge; the picture stretches.",
        "// Panel states: 'empty' = no file open yet (not used by the editor's layout), 'single' = one .ats file, 'set' = a channel set (3 channels).",
        "window.REALAYOUT_PROJECT = {",
        "  name: 'ReaATS',",
        "  id: 'reaats',",
        "  storageKey: 'reaats_layout_v%d'," % STORAGE_VERSION,
        "  viewStorageKey: 'reaats_layout_view_v%d'," % STORAGE_VERSION,
        "  canvas: { w: 1100, h: 640 },",
        "  knob: { labelTopOffset: 0, labelBlockH: 20 },",
        "  panels: [",
        "    {id:'editor', label:'EDITOR WINDOW', x:0, y:0, w:1100, h:640,",
        "     states:[{id:'empty',label:'No file yet'},{id:'single',label:'One file'},{id:'set',label:'Channel set (3)'}],",
        "     defaultState:'set'},",
        "  ],",
        "  elements: [",
    ]
    for e in els:
        lines.append("  {panel:%s, state:%s, id:%s, label:%s, shape:%s, x:%d, y:%d, w:%d, h:%d}," % (
            q(e["panel"]), q(e["state"]), q(e["id"]), q(e["label"]), q(e["shape"]), e["x"], e["y"], e["w"], e["h"]))
    lines += ["  ]", "};", ""]
    with open(sys.argv[2], "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))
    print("wrote %s (%d elements)" % (sys.argv[2], len(els)))


if __name__ == "__main__":
    main()
