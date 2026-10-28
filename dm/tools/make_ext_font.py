#!/usr/bin/env python3
# Generate a stand-in for the "Nintendo extension" shared font (nintendo_ext.ttf): controller-button icons at the original private-use code points (A/B/X/Y, L/R/ZL/ZR/SL/SR, +/−, D-pad, stick direction arrows).
# The host has no original system fonts; button icons in game text (e.g. Mario's GameMsg/Key.msbt: U+E0E0 = A button) render as "?" when the glyph is missing. Letters come from macOS's Arial Rounded Bold, knocked out of a solid plate.
# Usage: make_ext_font.py out.ttf [letter-font.ttf] [--style nintendo|playstation]; needs fontTools (pip install fonttools).
# --style playstation: the same code points with the symbols of a Sony controller's buttons in the same position (see build()).
import math, sys
from fontTools.ttLib import TTFont
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.reverseContourPen import ReverseContourPen
from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.recordingPen import RecordingPen

EM, ASC, DESC = 1000, 880, -120
CY, R = 350, 450          # icon centre height and circle radius: -100 to 800, sitting on the baseline

def area(c): return sum(c[i][0] * c[i - 1][1] - c[i - 1][0] * c[i][1] for i in range(len(c))) / 2
def contour(pen, pts, hole=False):
    # solid clockwise, hole counter-clockwise (TrueType convention, nonzero winding)
    if (area(pts) > 0) != hole: pts = pts[::-1]
    k = next(i for i, p in enumerate(pts) if p[2]); pts = pts[k:] + pts[:k]
    pen.moveTo(pts[0][:2]); offs = []
    for x, y, on in pts[1:]:
        if not on: offs.append((x, y)); continue
        if offs: pen.qCurveTo(*offs, (x, y)); offs = []
        else: pen.lineTo((x, y))
    if offs: pen.qCurveTo(*offs, pts[0][:2])
    pen.closePath()
def circle(cx, cy, r, n=8):
    pts = []
    for i in range(n):
        a = 2 * math.pi * i / n; b = a + math.pi / n; rr = r / math.cos(math.pi / n)
        pts += [(round(cx + r * math.cos(a)), round(cy + r * math.sin(a)), 1), (round(cx + rr * math.cos(b)), round(cy + rr * math.sin(b)), 0)]
    return pts
def rrect(x0, y0, x1, y1, rad):
    rad = min(rad, (x1 - x0) / 2, (y1 - y0) / 2)
    return [(x0 + rad, y1, 1), (x1 - rad, y1, 1), (x1, y1, 0), (x1, y1 - rad, 1), (x1, y0 + rad, 1), (x1, y0, 0), (x1 - rad, y0, 1),
            (x0 + rad, y0, 1), (x0, y0, 0), (x0, y0 + rad, 1), (x0, y1 - rad, 1), (x0, y1, 0)]
def rect(x0, y0, x1, y1): return [(x0, y1, 1), (x1, y1, 1), (x1, y0, 1), (x0, y0, 1)]
def rot(pts, cx, cy, deg):
    a = math.radians(deg); c, s = math.cos(a), math.sin(a)
    return [(round(cx + (x - cx) * c - (y - cy) * s), round(cy + (x - cx) * s + (y - cy) * c), on) for x, y, on in pts]

class Letters:
    def __init__(self, path):
        self.f = TTFont(path); self.gs = self.f.getGlyphSet(); self.cmap = self.f.getBestCmap()
    def knock(self, pen, text, cx, cy, h):
        # knock text out of the plate, centred at (cx, cy) with height h
        names = [self.cmap[ord(ch)] for ch in text]; x = 0; parts = []
        for nm in names: parts.append((nm, x)); x += self.gs[nm].width
        bp = BoundsPen(self.gs)
        for nm, dx in parts: self.gs[nm].draw(TransformPen(bp, (1, 0, 0, 1, dx, 0)))
        x0, y0, x1, y1 = bp.bounds; s = h / (y1 - y0)
        ox, oy = cx - (x0 + x1) / 2 * s, cy - (y0 + y1) / 2 * s
        # Knocked out = opposite direction to the plate. Fonts differ in outer-contour direction (TrueType clockwise, converted fonts often counter-clockwise); flip based on the largest contour's direction
        rec = RecordingPen()
        for nm, dx in parts: self.gs[nm].draw(TransformPen(rec, (s, 0, 0, s, ox + dx * s, oy)))
        rings, cur = [], []
        for op, args in rec.value:
            if op == 'moveTo': cur = [args[0]]; rings.append(cur)
            elif op in ('lineTo', 'qCurveTo', 'curveTo'): cur.extend(a for a in args if a is not None)
        big = max(rings, key=lambda c: abs(area(c)))
        rec.replay(ReverseContourPen(pen) if area(big) < 0 else pen)

def cross(cx, cy, half, arm):   # D-pad outline (one closed ring)
    a, h = arm / 2, half
    return [(cx - a, cy + h, 1), (cx + a, cy + h, 1), (cx + a, cy + a, 1), (cx + h, cy + a, 1), (cx + h, cy - a, 1), (cx + a, cy - a, 1),
            (cx + a, cy - h, 1), (cx - a, cy - h, 1), (cx - a, cy - a, 1), (cx - h, cy - a, 1), (cx - h, cy + a, 1), (cx - a, cy + a, 1)]

def ps_face(shape):   # PlayStation face-button symbol, knocked out of the round plate as an outline (ring)
    def d(pen, cx):
        contour(pen, circle(cx, CY, R))
        if shape == 'circle':
            contour(pen, circle(cx, CY, 255), hole=True); contour(pen, circle(cx, CY, 175))
        elif shape == 'cross':   # one closed ring: the plus outline turned 45 degrees (two overlapping holes would fill their overlap under nonzero winding)
            contour(pen, rot(cross(cx, CY, 270, 95), cx, CY, 45), hole=True)
        elif shape == 'square':
            contour(pen, rect(cx - 225, CY - 225, cx + 225, CY + 225), hole=True); contour(pen, rect(cx - 150, CY - 150, cx + 150, CY + 150))
        elif shape == 'triangle':   # centroid on CY: apex +270, base -135
            tri = lambda s: [(round(cx), round(CY + 270 * s), 1), (round(cx + 234 * s), round(CY - 135 * s), 1), (round(cx - 234 * s), round(CY - 135 * s), 1)]
            contour(pen, tri(1), hole=True); contour(pen, tri(0.5))
    return d

def ps_options(pen, cx):   # Options: three bars
    contour(pen, circle(cx, CY, R))
    for dy in (-140, 0, 140): contour(pen, rect(cx - 230, CY + dy - 42, cx + 230, CY + dy + 42), hole=True)

def ps_create(pen, cx):   # Create: three short rays that do not touch (disjoint holes)
    contour(pen, circle(cx, CY, R))
    for deg in (90, 210, 330):
        contour(pen, rot(rect(cx + 90, CY - 45, cx + 300, CY + 45), cx, CY, deg), hole=True)

def build(out, letter_font, style='nintendo'):
    """style 'nintendo' draws the Switch's lettered buttons; 'playstation' draws, at the same code points, the symbol of the button a
    DualSense / DualShock has in that POSITION: the host maps controllers by position (front_mac.m: right A, bottom B, top X, left Y),
    so A = circle, B = cross, X = triangle, Y = square; L/R/ZL/ZR = L1/R1/L2/R2, + / - = Options / Create, stick presses L3 / R3."""
    ps = style == 'playstation'
    L = Letters(letter_font); glyphs = {}; adv = {}; cmap = {}
    def glyph(name, codes, width, draw):
        pen = TTGlyphPen(None); draw(pen, width / 2); glyphs[name] = pen.glyph(); adv[name] = width
        for c in codes: cmap[c] = name
    def round_btn(t):
        def d(pen, cx): contour(pen, circle(cx, CY, R)); L.knock(pen, t, cx, CY, 470)
        return d
    def plate(t, w, h=620, th=400):
        def d(pen, cx): contour(pen, rrect(cx - w / 2, CY - h / 2, cx + w / 2, CY + h / 2, 220)); L.knock(pen, t, cx, CY, th)
        return d
    def sign(minus):
        def d(pen, cx):
            contour(pen, circle(cx, CY, R)); t, l = 70, 250
            if minus: contour(pen, rect(cx - l, CY - t, cx + l, CY + t), hole=True)
            else: contour(pen, cross(cx, CY, l, 2 * t), hole=True)
        return d
    def dpad(arm_dir):   # None = all solid; otherwise only one arm filled
        def d(pen, cx):
            contour(pen, cross(cx, CY, R, 320))
            if arm_dir is None: return
            contour(pen, cross(cx, CY, R - 55, 320 - 110), hole=True)
            arm = rect(cx - 105, CY + 105, cx + 105, CY + R - 55)
            contour(pen, rot(arm, cx, CY, {'up': 0, 'left': 90, 'down': 180, 'right': 270}[arm_dir]))
        return d
    def arrow(deg):
        def d(pen, cx):
            p = [(-380, 105, 1), (60, 105, 1), (60, 310, 1), (420, 0, 1), (60, -310, 1), (60, -105, 1), (-380, -105, 1)]
            contour(pen, rot([(cx + x, CY + y, on) for x, y, on in p], cx, CY, deg))
        return d
    def stick(t):
        def d(pen, cx):
            contour(pen, circle(cx, CY, R)); contour(pen, circle(cx, CY, R - 70), hole=True); contour(pen, circle(cx, CY, 300))
            if t: L.knock(pen, t, cx, CY, 300)
        return d

    pen = TTGlyphPen(None); glyphs['.notdef'] = pen.glyph(); adv['.notdef'] = 500
    faces = dict(zip('ABXY', ['circle', 'cross', 'triangle', 'square']))
    for i, t in enumerate(['A', 'B', 'X', 'Y']): glyph('btn' + t, [0xE0A0 + i, 0xE0E0 + i], 1000, ps_face(faces[t]) if ps else round_btn(t))
    shoulders = {'L': 'L1', 'R': 'R1', 'ZL': 'L2', 'ZR': 'R2'} if ps else {}
    for i, (t, w) in enumerate([('L', 900), ('R', 900), ('ZL', 1200), ('ZR', 1200), ('SL', 1200), ('SR', 1200)]):
        if t in shoulders: w = 1200
        glyph('btn' + t, [0xE0A4 + i, 0xE0E4 + i], w + 100, plate(shoulders.get(t, t), w))
    glyph('btnPlus', [0xE0B5, 0xE0EF], 1000, ps_options if ps else sign(False)); glyph('btnMinus', [0xE0B6, 0xE0F0], 1000, ps_create if ps else sign(True))
    glyph('dpad', [0xE0EA], 1000, dpad(None))
    for c, dr in [(0xE0AB, 'right'), (0xE0AC, 'down'), (0xE0AD, 'up'), (0xE0AE, 'left')]: glyph('dpad_' + dr, [c, c + 0x40], 1000, dpad(dr))
    for c, (nm, deg) in zip(range(0xE090, 0xE098), [('right', 0), ('left', 180), ('up', 90), ('down', 270), ('rightup', 45), ('rightdown', 315), ('leftdown', 225), ('leftup', 135)]):
        glyph('arrow_' + nm, [c], 1000, arrow(deg))
    glyph('stick', [0xE100], 1000, stick(None)); glyph('stickL', [0xE101, 0xE0C1], 1000, stick('L3' if ps else 'L')); glyph('stickR', [0xE102, 0xE0C2], 1000, stick('R3' if ps else 'R'))

    order = ['.notdef'] + sorted(n for n in glyphs if n != '.notdef')
    fb = FontBuilder(EM, isTTF=True)
    fb.setupGlyphOrder(order); fb.setupCharacterMap(cmap); fb.setupGlyf(glyphs)
    glyf = fb.font['glyf']
    for n in order: glyf[n].recalcBounds(glyf)
    fb.setupHorizontalMetrics({n: (adv[n], getattr(glyf[n], 'xMin', 0)) for n in order})
    fb.setupHorizontalHeader(ascent=ASC, descent=DESC)
    fb.setupNameTable({'familyName': 'DM Nintendo Extension Stand-in' + (' (PlayStation)' if ps else ''), 'styleName': 'Regular'})
    fb.setupOS2(sTypoAscender=ASC, sTypoDescender=DESC, sTypoLineGap=0, usWinAscent=ASC, usWinDescent=-DESC)
    fb.setupPost(); fb.save(out)
    print('%s: %d glyphs, %d code points' % (out, len(order), len(cmap)))

if __name__ == '__main__':
    args = sys.argv[1:]; style = 'nintendo'
    if '--style' in args:
        i = args.index('--style'); style = args[i + 1] if i + 1 < len(args) else ''; del args[i:i + 2]
    if style not in ('nintendo', 'playstation'): sys.exit('--style is nintendo or playstation')
    if not args: sys.exit('usage: make_ext_font.py out.ttf [letter-font.ttf] [--style nintendo|playstation]')
    build(args[0], args[1] if len(args) > 1 else '/System/Library/Fonts/Supplemental/Arial Rounded Bold.ttf', style)
