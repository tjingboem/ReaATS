#!/usr/bin/env python3
"""Make the ReaLayout project file of the CROSS page from its layout JSON, so that ReaLayout starts from the layout the page really uses.

    python3 tools/make_cross_project.py tools/reaATS_Cross_layout.json ~/Claude/ReaLayout/projects/reaats_cross.js

(Open it with index.html?project=reaats_cross. After editing in ReaLayout, Save to file, put the JSON in tools/ and run tools/gen_cross_layout.py.)
"""
import json
import sys


def q(s):
    return "'" + s.replace("\\", "\\\\").replace("'", "\\'") + "'"


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)
    els = json.load(open(sys.argv[1], encoding="utf-8"))
    lines = [
        "// ReaATS CROSS page project for ReaLayout. Made by ReaATS/tools/make_cross_project.py from the layout that the page reads (lib/cross_layout.lua).",
        "// 1100 x 640, the page starts 40 px from the top. Open with index.html?project=reaats_cross",
        "// Ids: btn_* buttons, txt_* texts, lane_a / lane_b the lanes (both take the x and width of lane_a), ruler, sl_time / sl_freq sliders.",
        "// What is left out uses the page's built-in place.",
        "window.REALAYOUT_PROJECT = {",
        "  name: 'ReaATS CROSS',",
        "  id: 'reaats_cross',",
        "  storageKey: 'reaats_cross_layout_v4',",
        "  viewStorageKey: 'reaats_cross_layout_view_v4',",
        "  canvas: { w: 1100, h: 640 },",
        "  knob: { labelTopOffset: 0, labelBlockH: 20 },",
        "  panels: [",
        "    {id:'cross', label:'CROSS PAGE', x:0, y:40, w:1100, h:600},",
        "  ],",
        "  elements: [",
    ]
    for e in els:
        lines.append("  {panel:'cross', state:'*', id:%s, label:%s, shape:%s, x:%d, y:%d, w:%d, h:%d}," % (q(e["id"]), q(e["label"]), q(e["shape"]), e["x"], e["y"], e["w"], e["h"]))
    lines += ["  ]", "};", ""]
    open(sys.argv[2], "w", encoding="utf-8").write("\n".join(lines))
    print("wrote %s (%d elements)" % (sys.argv[2], len(els)))


if __name__ == "__main__":
    main()
