#!/usr/bin/env python3
"""Make the ReaLayout project file of the Analysis page from its layout JSON, so that ReaLayout starts from the layout the page really uses.

    python3 tools/make_analysis_project.py tools/reaATS_Analyses_layout.json ~/Claude/ReaLayout/projects/reaats_analysis.js

(Open it with index.html?project=reaats_analysis. After editing in ReaLayout, Save to file, put the JSON in tools/ and run tools/gen_analysis_layout.py.)
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
        "// ReaATS Analysis page project for ReaLayout. Made by ReaATS/tools/make_analysis_project.py from the layout that the page reads (lib/analysis_layout.lua).",
        "// 1100 x 640, the page starts 40 px from the top. Open with index.html?project=reaats_analysis",
        "// Ids: hdr_* headings, btn_* buttons, txt_* texts, fld_<key> the box of a field (or a whole switch), lbl_<key> its label, unit_<key> its unit.",
        "// What is not here is not drawn (the page then writes it at the bottom left: a message, a hover tip, a warning that Python was not found).",
        "window.REALAYOUT_PROJECT = {",
        "  name: 'ReaATS Analysis',",
        "  id: 'reaats_analysis',",
        "  storageKey: 'reaats_analysis_layout_v3',",
        "  viewStorageKey: 'reaats_analysis_layout_view_v3',",
        "  canvas: { w: 1100, h: 640 },",
        "  knob: { labelTopOffset: 0, labelBlockH: 20 },",
        "  panels: [",
        "    {id:'analysis', label:'ANALYSIS PAGE', x:0, y:40, w:1100, h:600},",
        "  ],",
        "  elements: [",
    ]
    for e in els:
        lines.append("  {panel:'analysis', state:'*', id:%s, label:%s, shape:%s, x:%d, y:%d, w:%d, h:%d}," % (q(e["id"]), q(e["label"]), q(e["shape"]), e["x"], e["y"], e["w"], e["h"]))
    lines += ["  ]", "};", ""]
    open(sys.argv[2], "w", encoding="utf-8").write("\n".join(lines))
    print("wrote %s (%d elements)" % (sys.argv[2], len(els)))


if __name__ == "__main__":
    main()
