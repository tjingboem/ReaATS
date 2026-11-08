#!/usr/bin/env python3
"""Builds the .odt manual in the look of the MidiCloud / ReaAC / Spectral Transfer manuals from a markdown draft.

House look (as in ReaAC/doc/manual_src/restyle_house.py and restyle_tables.py): pale yellow page (#ffffbd), Arial 10 pt,
Heading 1 and 2 dark blue (#1f3864) with a blue rule (#2e75b6) below, Heading 3 lighter blue, title page with the title in
black serif, "user guide" in big blue, "tjingboem productions" and the month; tables 6.69 in wide, header row dark blue with white
bold text, first column shaded light blue (#d0e4f5) and bold, 9 pt text, thin grey borders.

Usage: make_manual.py <draft.md> <out.odt> [Month Year]
Source markup (a small subset): '# ' title, '## ' chapter (Heading 1), '### ' section (Heading 2), '- ' bullet, '| a | b |' table
(second line '|---|' marks the header row), '**bold**' inside a line. A line starting 'Draft text' is skipped. The first chapter
starts on a new page.
"""
import sys, re, zipfile, datetime
from xml.sax.saxutils import escape

src, dst = sys.argv[1], sys.argv[2]
month = sys.argv[3] if len(sys.argv) > 3 else datetime.date.today().strftime('%B %Y')

lines = open(src, encoding='utf8').read().split('\n')
title = 'ReaATS'
blocks = []   # ('h1'|'h2'|'p'|'ul'|'table', data)
i = 0
while i < len(lines):
    ln = lines[i]
    if not ln.strip(): i += 1; continue
    if ln.startswith('# '): title = ln[2:].strip(); i += 1; continue
    if ln.startswith('Draft text'): i += 1; continue
    if ln.startswith('## '): blocks.append(('h1', ln[3:].strip())); i += 1; continue
    if ln.startswith('### '): blocks.append(('h2', ln[4:].strip())); i += 1; continue
    if ln.startswith('- '):
        items = []
        while i < len(lines) and lines[i].startswith('- '): items.append(lines[i][2:].strip()); i += 1
        blocks.append(('ul', items)); continue
    if ln.startswith('|'):
        rows = []
        while i < len(lines) and lines[i].startswith('|'):
            cells = [c.strip() for c in lines[i].strip().strip('|').split('|')]
            rows.append(cells); i += 1
        header = len(rows) > 1 and all(re.fullmatch(r':?-+:?', c) for c in rows[1])
        if header: rows.pop(1)
        blocks.append(('table', (header, rows))); continue
    para = [ln.strip()]; i += 1
    while i < len(lines) and lines[i].strip() and not re.match(r'(#|- |\|)', lines[i]):
        para.append(lines[i].strip()); i += 1
    blocks.append(('p', ' '.join(para)))

def inline(t):
    t = escape(t)
    return re.sub(r'\*\*(.+?)\*\*', r'<text:span text:style-name="Bold">\1</text:span>', t)

TOTAL = 6.6929
auto = []   # automatic styles for tables
body = []
n_tables = 0
first_h1 = True
for kind, d in blocks:
    if kind == 'h1':
        st = 'ChapterBreak1' if first_h1 else 'Heading_20_1'
        first_h1 = False
        body.append('<text:h text:style-name="%s" text:outline-level="1">%s</text:h>' % (st, inline(d)))
    elif kind == 'h2':
        body.append('<text:h text:style-name="Heading_20_2" text:outline-level="2">%s</text:h>' % inline(d))
    elif kind == 'p':
        body.append('<text:p text:style-name="Text_20_body">%s</text:p>' % inline(d))
    elif kind == 'ul':
        body.append('<text:list text:style-name="ManualList">' + ''.join(
            '<text:list-item><text:p text:style-name="ManualBullet">%s</text:p></text:list-item>' % inline(x) for x in d) + '</text:list>')
    elif kind == 'table':
        header, rows = d
        n_tables += 1; k = n_tables
        ncol = max(len(r) for r in rows)
        weights = []
        for j in range(ncol):
            lens = [len(r[j]) for r in rows if j < len(r)]
            avg = sum(lens) / len(lens)
            weights.append(min(max(avg, 7), 60) ** 0.8)
        s = sum(weights); widths = [w / s * TOTAL for w in weights]
        for j, w in enumerate(widths):
            auto.append('<style:style style:name="Col%d_%d" style:family="table-column"><style:table-column-properties style:column-width="%.4fin"/></style:style>' % (k, j, w))
        t = ['<table:table table:name="Table%d" table:style-name="HouseTbl">' % k]
        t += ['<table:table-column table:style-name="Col%d_%d"/>' % (k, j) for j in range(ncol)]
        def row(cells, head):
            out = '<table:table-row>'
            for j in range(ncol):
                txt = inline(cells[j]) if j < len(cells) else ''
                cs = 'HouseHead' if head else ('HouseShade' if j == 0 else 'HouseCell')
                ps = 'HouseHeadText' if head else ('HouseBold' if j == 0 else 'HouseText')
                out += '<table:table-cell table:style-name="%s" office:value-type="string"><text:p text:style-name="%s">%s</text:p></table:table-cell>' % (cs, ps, txt)
            return out + '</table:table-row>'
        if header:
            t.append('<table:table-header-rows>' + row(rows[0], True) + '</table:table-header-rows>')
            rows = rows[1:]
        t += [row(r, False) for r in rows]
        t.append('</table:table>')
        body.append(''.join(t))
        body.append('<text:p text:style-name="Text_20_body"/>')

NS = ('xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" '
      'xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" '
      'xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0" xmlns:svg="urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0" '
      'xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0" xmlns:xlink="http://www.w3.org/1999/xlink" '
      'xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:meta="urn:oasis:names:tc:opendocument:xmlns:meta:1.0" '
      'xmlns:number="urn:oasis:names:tc:opendocument:xmlns:datastyle:1.0"')
FONTS = ('<office:font-face-decls>'
         '<style:font-face style:name="Arial" svg:font-family="Arial" style:font-family-generic="swiss" style:font-pitch="variable"/>'
         '<style:font-face style:name="Liberation Serif" svg:font-family="&apos;Liberation Serif&apos;" style:font-family-generic="roman" style:font-pitch="variable"/>'
         '</office:font-face-decls>')
def tp(size, bold=False, color=None, font='Arial'):
    c = ' fo:color="%s"' % color if color else ''
    b = ' fo:font-weight="bold" style:font-weight-asian="bold" style:font-weight-complex="bold"' if bold else ''
    return ('<style:text-properties style:font-name="%s" fo:font-family="%s"%s fo:font-size="%spt"%s style:font-size-asian="%spt" style:font-size-complex="%spt"/>'
            % (font, font, c, size, b, size, size))
RULE = ('fo:padding-left="0in" fo:padding-right="0in" fo:padding-top="0in" fo:padding-bottom="0.0555in" fo:border-left="none" fo:border-right="none" '
        'fo:border-top="none" fo:border-bottom="0.99pt solid #2e75b6"')
def hstyle(name, display, lvl, margins, rule, text):
    return ('<style:style style:name="%s" style:display-name="%s" style:family="paragraph" style:parent-style-name="Standard" '
            'style:next-style-name="Text_20_body" style:default-outline-level="%d" style:class="text">'
            '<style:paragraph-properties %s %s fo:keep-with-next="always"/>%s</style:style>' % (name, display, lvl, margins, RULE if rule else '', text))
PAD = 'fo:padding-left="0.0833in" fo:padding-right="0.0833in" fo:padding-top="0.0417in" fo:padding-bottom="0.0417in" fo:border="0.1pt solid #cccccc"'

styles = ('<?xml version="1.0" encoding="UTF-8"?><office:document-styles %s office:version="1.2">' % NS + FONTS +
  '<office:styles>'
  '<style:default-style style:family="paragraph"><style:paragraph-properties fo:orphans="2" fo:widows="2"/>' + tp(10) + '</style:default-style>'
  '<style:style style:name="Standard" style:family="paragraph" style:class="text"><style:paragraph-properties fo:margin-top="0in" fo:margin-bottom="0in"/>' + tp(10) + '</style:style>'
  '<style:style style:name="Text_20_body" style:display-name="Text body" style:family="paragraph" style:parent-style-name="Standard" style:class="text">'
  '<style:paragraph-properties fo:margin-top="0in" fo:margin-bottom="0.0555in"/>' + tp(10) + '</style:style>'
  + hstyle('Heading_20_1', 'Heading 1', 1, 'fo:margin-top="0.25in" fo:margin-bottom="0.0835in"', True, tp(20, True, '#1f3864'))
  + hstyle('Heading_20_2', 'Heading 2', 2, 'fo:margin-top="0.25in" fo:margin-bottom="0.0835in"', True, tp(16, True, '#1f3864'))
  + hstyle('Heading_20_3', 'Heading 3', 3, 'fo:margin-top="0.1945in" fo:margin-bottom="0.0555in"', False, tp(13, True, '#2e75b6')) +
  '<style:style style:name="Footer" style:family="paragraph" style:parent-style-name="Standard"><style:paragraph-properties fo:text-align="center"/>' + tp(9, False, '#666666') + '</style:style>'
  '<text:list-style style:name="ManualList"><text:list-level-style-bullet text:level="1" text:bullet-char="•">'
  '<style:list-level-properties text:space-before="0.2961in" text:min-label-width="0.1965in"/></text:list-level-style-bullet></text:list-style>'
  '</office:styles>'
  '<office:automatic-styles>'
  '<style:page-layout style:name="pm1"><style:page-layout-properties fo:page-width="8.2677in" fo:page-height="11.6929in" style:print-orientation="portrait" '
  'fo:margin-top="0.7874in" fo:margin-bottom="0.7874in" fo:margin-left="0.7874in" fo:margin-right="0.7874in" fo:background-color="#ffffbd" draw:fill="solid" draw:fill-color="#ffffbd"/>'
  '<style:footer-style><style:header-footer-properties fo:min-height="0.2in" fo:margin-top="0.1in"/></style:footer-style></style:page-layout>'
  '</office:automatic-styles>'
  '<office:master-styles><style:master-page style:name="Standard" style:page-layout-name="pm1"><style:footer><text:p text:style-name="Footer">'
  '<text:page-number text:select-page="current"/></text:p></style:footer></style:master-page></office:master-styles></office:document-styles>')

TITLE_AUTO = (
  '<style:style style:name="TitleMain" style:family="paragraph" style:parent-style-name="Standard"><style:paragraph-properties fo:text-align="center" fo:margin-top="2.6in" fo:margin-bottom="0.1in"/>' + tp(28, True, '#000000', 'Liberation Serif') + '</style:style>'
  '<style:style style:name="TitleUserGuide" style:family="paragraph" style:parent-style-name="Standard"><style:paragraph-properties fo:text-align="center" fo:margin-top="0.1in" fo:margin-bottom="0.5in"/>' + tp(36, True, '#1f3864') + '</style:style>'
  '<style:style style:name="TitleLine" style:family="paragraph" style:parent-style-name="Standard"><style:paragraph-properties fo:text-align="center" fo:margin-bottom="0.06in"/>' + tp(12, False, None, 'Liberation Serif') + '</style:style>'
  '<style:style style:name="ChapterBreak1" style:family="paragraph" style:parent-style-name="Heading_20_1" style:next-style-name="Text_20_body"><style:paragraph-properties fo:break-before="page"/></style:style>'
  '<style:style style:name="Bold" style:family="text"><style:text-properties fo:font-weight="bold" style:font-weight-asian="bold" style:font-weight-complex="bold"/></style:style>'
  '<style:style style:name="ManualBullet" style:family="paragraph" style:parent-style-name="Text_20_body" style:list-style-name="ManualList"><style:paragraph-properties fo:margin-bottom="0.04in"/></style:style>'
  '<style:style style:name="HouseTbl" style:family="table"><style:table-properties style:width="6.6929in" fo:margin-top="0.0785in" fo:margin-bottom="0.1576in" table:align="left"/></style:style>'
  '<style:style style:name="HouseShade" style:family="table-cell"><style:table-cell-properties fo:background-color="#d0e4f5" ' + PAD + '/></style:style>'
  '<style:style style:name="HouseHead" style:family="table-cell"><style:table-cell-properties fo:background-color="#1f3864" ' + PAD + '/></style:style>'
  '<style:style style:name="HouseCell" style:family="table-cell"><style:table-cell-properties ' + PAD + '/></style:style>'
  '<style:style style:name="HouseHeadText" style:family="paragraph" style:parent-style-name="Standard">' + tp(9, True, '#ffffff') + '</style:style>'
  '<style:style style:name="HouseBold" style:family="paragraph" style:parent-style-name="Standard">' + tp(9, True) + '</style:style>'
  '<style:style style:name="HouseText" style:family="paragraph" style:parent-style-name="Standard">' + tp(9) + '</style:style>')

title_page = ('<text:p text:style-name="TitleMain">%s</text:p><text:p text:style-name="TitleUserGuide">user guide</text:p>'
              '<text:p text:style-name="TitleLine">tjingboem productions</text:p><text:p text:style-name="TitleLine">%s</text:p>' % (escape(title), escape(month)))
content = ('<?xml version="1.0" encoding="UTF-8"?><office:document-content %s office:version="1.2">' % NS + FONTS +
           '<office:automatic-styles>' + TITLE_AUTO + ''.join(auto) + '</office:automatic-styles>'
           '<office:body><office:text>' + title_page + ''.join(body) + '</office:text></office:body></office:document-content>')
meta = ('<?xml version="1.0" encoding="UTF-8"?><office:document-meta %s office:version="1.2"><office:meta><dc:title>%s manual</dc:title>'
        '<dc:creator>tjingboem productions</dc:creator><dc:language>en-GB</dc:language></office:meta></office:document-meta>' % (NS, escape(title)))
manifest = ('<?xml version="1.0" encoding="UTF-8"?><manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.2">'
            '<manifest:file-entry manifest:full-path="/" manifest:media-type="application/vnd.oasis.opendocument.text"/>'
            '<manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/>'
            '<manifest:file-entry manifest:full-path="styles.xml" manifest:media-type="text/xml"/>'
            '<manifest:file-entry manifest:full-path="meta.xml" manifest:media-type="text/xml"/></manifest:manifest>')
import xml.dom.minidom
for name, x in (('content', content), ('styles', styles), ('meta', meta), ('manifest', manifest)):
    xml.dom.minidom.parseString(x.encode('utf8'))
with zipfile.ZipFile(dst, 'w') as z:
    z.writestr('mimetype', 'application/vnd.oasis.opendocument.text', compress_type=zipfile.ZIP_STORED)
    z.writestr('META-INF/manifest.xml', manifest, compress_type=zipfile.ZIP_DEFLATED)
    z.writestr('content.xml', content, compress_type=zipfile.ZIP_DEFLATED)
    z.writestr('styles.xml', styles, compress_type=zipfile.ZIP_DEFLATED)
    z.writestr('meta.xml', meta, compress_type=zipfile.ZIP_DEFLATED)
print('wrote', dst, '-', n_tables, 'tables,', len(blocks), 'blocks')
