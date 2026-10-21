#!/usr/bin/env python3
"""Draw the two Review 2 diagrams as SVG (and PNG through headless Chrome).

  python scripts/review2_diagrams.py

  docs/review2/ER_CORRECTED.svg / .png        1. Conceptual ER Diagram - Chen notation
  docs/review2/RELATIONAL_SCHEMA.svg / .png   2. Relational Schema - tables, PKs and FKs

  python scripts/review2_diagrams.py --verify-db <database>   compare diagram 1 with the catalog
  python scripts/review2_diagrams.py --audit-svg <file.svg>   compare a Chen SVG with the model
  python scripts/review2_diagrams.py --render <file.svg> <width> <height> [--font-dir DIR]
      render any SVG (e.g. the team's ER_CHEN_PRESENTATION.svg, ER_READING_GUIDE.svg) to the
      PNG next to it; --font-dir supplies DejaVuSans.ttf / DejaVuSans-Bold.ttf when that
      font is not installed (otherwise the browser substitutes Arial)

Every coordinate is written here, so the layout is reproducible and can be
edited. Before writing, the script checks the geometry: no two shapes or
labels overlap, and no connector line passes through a shape or label
other than the two it joins. It exits non-zero if a check fails.
No network access, no third-party packages.
"""

import math
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "docs" / "review2"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
FONT = "Helvetica, Arial, sans-serif"
INK, MUTED, PAPER = "#1d1d1f", "#55555a", "#ffffff"


# =========================================================================
# geometry helpers shared by the checks
# =========================================================================
class Shape:
    def __init__(self, kind, cx, cy, hw, hh, name):
        self.kind, self.cx, self.cy, self.hw, self.hh, self.name = kind, cx, cy, hw, hh, name

    def contains(self, x, y, pad=0.0):
        dx, dy = abs(x - self.cx), abs(y - self.cy)
        hw, hh = self.hw + pad, self.hh + pad
        if self.kind == "ellipse":
            return (dx / hw) ** 2 + (dy / hh) ** 2 <= 1
        if self.kind == "diamond":
            return dx / hw + dy / hh <= 1
        return dx <= hw and dy <= hh

    def bbox(self, pad=0.0):
        return (self.cx - self.hw - pad, self.cy - self.hh - pad,
                self.cx + self.hw + pad, self.cy + self.hh + pad)


def boxes_overlap(a, b):
    return not (a[2] <= b[0] or b[2] <= a[0] or a[3] <= b[1] or b[3] <= a[1])


def segment_hits(shape, x1, y1, x2, y2, pad=2.0):
    n = max(2, int(math.hypot(x2 - x1, y2 - y1) / 2))
    return any(shape.contains(x1 + (x2 - x1) * i / n, y1 + (y2 - y1) * i / n, pad)
               for i in range(n + 1))


def text_width(s, size, bold=False):
    # Conservative Helvetica estimate (wide characters counted wider).
    w = 0.0
    for ch in s:
        if ch in "MW@%":
            w += 0.86
        elif ch.isupper() or ch in "_&#":
            w += 0.70
        elif ch in "il.,:;'|!()[] ":
            w += 0.30
        else:
            w += 0.56
    return w * size * (1.08 if bold else 1.0)


def run_checks(shapes, segments, title):
    """shapes: list[Shape]; segments: list of (x1, y1, x2, y2, {allowed names})."""
    problems = []
    for i, a in enumerate(shapes):
        for b in shapes[i + 1:]:
            if boxes_overlap(a.bbox(3), b.bbox(3)) and _real_overlap(a, b):
                problems.append(f"overlap: {a.name} / {b.name}")
    for x1, y1, x2, y2, allowed in segments:
        for s in shapes:
            if s.name not in allowed and segment_hits(s, x1, y1, x2, y2):
                problems.append(f"line {sorted(allowed)} crosses {s.name}")
    # Lines that only touch at a shared end point are fine (orientation 0);
    # a proper crossing anywhere else is reported.
    for i, (a1, b1, c1, d1, al1) in enumerate(segments):
        for (a2, b2, c2, d2, al2) in segments[i + 1:]:
            if _segments_cross(a1, b1, c1, d1, a2, b2, c2, d2):
                problems.append(f"lines cross: {sorted(al1)} x {sorted(al2)}")
    print(f"   layout check {title}: {len(shapes)} shapes/labels, {len(segments)} line segments, "
          f"{'OK' if not problems else str(len(problems)) + ' PROBLEM(S)'}")
    for p in problems:
        print(f"     - {p}")
    return problems


def _real_overlap(a, b):
    # sample the smaller shape's border
    small, big = (a, b) if a.hw * a.hh < b.hw * b.hh else (b, a)
    for k in range(72):
        t = 2 * math.pi * k / 72
        x = small.cx + small.hw * math.cos(t)
        y = small.cy + small.hh * math.sin(t)
        if big.contains(x, y, 3):
            return True
    return big.contains(small.cx, small.cy, 3)


def _segments_cross(x1, y1, x2, y2, x3, y3, x4, y4):
    def orient(ax, ay, bx, by, cx, cy):
        v = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
        return 0 if abs(v) < 1e-9 else (1 if v > 0 else -1)
    o1, o2 = orient(x1, y1, x2, y2, x3, y3), orient(x1, y1, x2, y2, x4, y4)
    o3, o4 = orient(x3, y3, x4, y4, x1, y1), orient(x3, y3, x4, y4, x2, y2)
    return o1 * o2 < 0 and o3 * o4 < 0


def check_text_fits(items, title):
    """items: (text, font_size, bold, available_width, where)."""
    problems = [f"text too wide in {where}: {text[:40]}..."
                for text, size, bold, avail, where in items
                if text_width(text, size, bold) * 1.06 > avail]
    print(f"   text-fit check {title}: {len(items)} lines, "
          f"{'OK' if not problems else str(len(problems)) + ' PROBLEM(S)'}")
    for p in problems:
        print(f"     - {p}")
    return problems


def render_png(svg_path, width, height, font_dir=None):
    """Screenshot the SVG with headless Chrome. On macOS Chrome writes the
    file and may then keep running, so wait for the file and stop it.
    font_dir: optional folder with DejaVuSans.ttf and DejaVuSans-Bold.ttf,
    declared as the 'DejaVu Sans' family for this render only."""
    png = svg_path.with_suffix(".png")
    if not Path(CHROME).exists():
        print(f"   (Chrome not found: {png.name} not rendered)")
        return
    faces = ""
    if font_dir:
        for weight, fname in (("normal", "DejaVuSans.ttf"), ("bold", "DejaVuSans-Bold.ttf")):
            font = Path(font_dir).resolve() / fname
            if not font.exists():
                raise SystemExit(f"font file not found: {font}")
            faces += (f"@font-face{{font-family:'DejaVu Sans';font-weight:{weight};"
                      f"src:url('{font.as_uri()}')}}")
    with tempfile.TemporaryDirectory() as tmp:
        html, shot = Path(tmp) / "render.html", Path(tmp) / "shot.png"
        html.write_text("<!doctype html><html><head><meta charset='utf-8'><style>" + faces +
                        "html,body{margin:0;padding:0;background:#fff}</style></head>"
                        f"<body>{svg_path.read_text()}</body></html>")
        proc = subprocess.Popen(
            [CHROME, "--headless", "--disable-gpu", "--no-first-run", "--no-default-browser-check",
             "--disable-extensions", "--hide-scrollbars", "--force-device-scale-factor=1",
             "--allow-file-access-from-files",
             f"--user-data-dir={tmp}/profile", f"--window-size={width},{height}",
             f"--screenshot={shot}", html.as_uri()],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline, last_size = time.time() + 90, -1
        while time.time() < deadline:
            size = shot.stat().st_size if shot.exists() else -1
            if size > 0 and size == last_size:
                break
            last_size = size
            time.sleep(0.5)
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
        if not shot.exists():
            raise SystemExit(f"Chrome did not produce {png.name}")
        shutil.copyfile(shot, png)
    print(f"   rendered {png.relative_to(ROOT)} ({width}x{height})")


# =========================================================================
# 1. Conceptual ER diagram (Chen notation)
# =========================================================================
ER_W, ER_H = 2400, 2010
ENT_HW, ENT_HH = 125, 34          # entity rectangle half sizes
REL_HW, REL_HH = 112, 54          # relationship diamond half sizes

ENTITIES = {                      # name: (cx, cy)
    "USER": (760, 330), "WATCHLIST": (1640, 330),
    "ALERT_RULE": (760, 820), "INSTRUMENT": (1640, 820),
    "ALERT_EVENT": (760, 1310), "PRICE_TICK": (1640, 1310),
}
# relationship: (cx, cy, entity_a, card_a, total_a, entity_b, card_b, total_b)
RELATIONSHIPS = {
    "OWNS":         (1200, 330, "USER", "1", False, "WATCHLIST", "N", True),
    "CREATES":      (760, 575, "USER", "1", False, "ALERT_RULE", "N", True),
    "CONTAINS":     (1640, 575, "WATCHLIST", "M", False, "INSTRUMENT", "N", False),
    "MONITORS":     (1200, 820, "ALERT_RULE", "N", True, "INSTRUMENT", "1", False),
    "GENERATES":    (760, 1065, "ALERT_RULE", "1", False, "ALERT_EVENT", "N", True),
    "HAS_TICK":     (1640, 1065, "INSTRUMENT", "1", False, "PRICE_TICK", "N", True),
    "TRIGGERED_BY": (1200, 1310, "ALERT_EVENT", "N", True, "PRICE_TICK", "1", False),
}
# attribute: (owner, cx, cy, is_key)  - owner is an entity, relationship or composite
ATTRIBUTES = [
    ("USER", "user_id", 400, 200, True), ("USER", "username", 360, 285, True),
    ("USER", "email", 360, 370, True), ("USER", "created_at", 400, 455, False),
    ("WATCHLIST", "watchlist_id", 2010, 240, True), ("WATCHLIST", "name", 2060, 330, False),
    ("WATCHLIST", "created_at", 2010, 420, False),
    ("CONTAINS", "added_at", 1395, 575, False),
    ("INSTRUMENT", "instrument_id", 2010, 640, True), ("INSTRUMENT", "listing", 2030, 735, True),
    ("listing", "exchange", 2290, 690, False), ("listing", "symbol", 2290, 782, False),
    ("INSTRUMENT", "name", 2060, 835, False), ("INSTRUMENT", "quote_currency", 2030, 915, False),
    ("INSTRUMENT", "is_active", 1965, 995, False),
    ("ALERT_RULE", "rule_id", 400, 680, True), ("ALERT_RULE", "direction", 350, 755, False),
    ("ALERT_RULE", "threshold", 340, 830, False), ("ALERT_RULE", "cooldown_seconds", 370, 905, False),
    ("ALERT_RULE", "is_active", 415, 980, False), ("ALERT_RULE", "created_at", 485, 1050, False),
    ("ALERT_EVENT", "event_id", 420, 1250, True), ("ALERT_EVENT", "fired_at", 420, 1370, False),
    ("PRICE_TICK", "tick_id", 2020, 1170, True), ("PRICE_TICK", "observed_at", 2070, 1245, False),
    ("PRICE_TICK", "price", 2095, 1320, False), ("PRICE_TICK", "volume", 2075, 1395, False),
    ("PRICE_TICK", "source", 2010, 1470, False), ("PRICE_TICK", "source_event_id", 1830, 1530, False),
    ("PRICE_TICK", "ingested_at", 1560, 1530, False),
]
ATTR_FONT, ENT_FONT, REL_FONT, CARD_FONT = 18, 22, 18, 24
NOTE = (300, 1420, 1420, 1580)   # integrity note box: x1, y1, x2, y2
NOTE_LINES = [
    ("Integrity rule (not a relationship): ", "the ALERT_RULE and the PRICE_TICK of one ALERT_EVENT"),
    ("", "must belong to the same INSTRUMENT. Checked by trigger trg_alert_events_check_instrument on"),
    ("", "INSERT / UPDATE OF rule_id, tick_id of alert_events. Later instrument_id changes on alert_rules"),
    ("", "or price_ticks are NOT checked by the database; no application path makes them."),
]
TEXT_ITEMS = []                  # (text, size, bold, available width, where) for the fit check


def er_svg():
    shapes, segments, out = [], [], []
    add = out.append

    ent_shape = {n: Shape("rect", x, y, ENT_HW, ENT_HH, n) for n, (x, y) in ENTITIES.items()}
    rel_shape = {n: Shape("diamond", v[0], v[1], REL_HW, REL_HH, n) for n, v in RELATIONSHIPS.items()}
    attr_shape, attr_owner = {}, {}
    for owner, label, x, y, key in ATTRIBUTES:
        rx = max(62, text_width(label, ATTR_FONT) / 2 + 24)
        uid = f"{owner}.{label}"
        attr_shape[uid] = Shape("ellipse", x, y, rx, 27, uid)
        attr_owner[uid] = owner
    shapes += list(ent_shape.values()) + list(rel_shape.values()) + list(attr_shape.values())

    def center_of(name):
        if name in ent_shape:
            return ent_shape[name]
        if name in rel_shape:
            return rel_shape[name]
        return next(s for k, s in attr_shape.items() if k.endswith("." + name))

    lines_svg, labels_svg = [], []

    # attribute connectors (plain single lines, no arrows)
    for uid, s in attr_shape.items():
        owner = center_of(attr_owner[uid])
        segments.append((s.cx, s.cy, owner.cx, owner.cy, {uid, owner.name}))
        lines_svg.append(f'<line x1="{s.cx}" y1="{s.cy}" x2="{owner.cx}" y2="{owner.cy}" '
                         f'stroke="{INK}" stroke-width="1.6"/>')

    # relationship connectors: single = partial, double = total participation
    for rname, (rx, ry, ea, ca, ta, eb, cb, tb) in RELATIONSHIPS.items():
        for ent, card, total in ((ea, ca, ta), (eb, cb, tb)):
            ex, ey = ENTITIES[ent]
            segments.append((rx, ry, ex, ey, {rname, ent}))
            dx, dy = ex - rx, ey - ry
            length = math.hypot(dx, dy)
            ux, uy = dx / length, dy / length
            nx, ny = -uy, ux
            if total:
                for off in (-4.2, 4.2):
                    lines_svg.append(
                        f'<line x1="{rx + nx * off:.1f}" y1="{ry + ny * off:.1f}" '
                        f'x2="{ex + nx * off:.1f}" y2="{ey + ny * off:.1f}" stroke="{INK}" stroke-width="2"/>')
            else:
                lines_svg.append(f'<line x1="{rx}" y1="{ry}" x2="{ex}" y2="{ey}" '
                                 f'stroke="{INK}" stroke-width="2"/>')
            # cardinality label just outside the diamond, beside its line
            t = (REL_HW if abs(ux) > abs(uy) else REL_HH) + 30
            lx, ly = rx + ux * t, ry + uy * t
            side = 22
            px, py = (lx, ly - side) if abs(ux) > abs(uy) else (lx + side, ly)
            labels_svg.append(f'<text x="{px:.1f}" y="{py + 8:.1f}" font-size="{CARD_FONT}" '
                              f'font-weight="700" text-anchor="middle" fill="{INK}">{card}</text>')
            shapes.append(Shape("rect", px, py, 10, 13, f"card {rname}/{ent}"))

    # integrity note (dashed), linked to ALERT_EVENT by a dashed line
    nx1, ny1, nx2, ny2 = NOTE
    note_shape = Shape("rect", (nx1 + nx2) / 2, (ny1 + ny2) / 2, (nx2 - nx1) / 2, (ny2 - ny1) / 2,
                       "integrity note")
    shapes.append(note_shape)
    ax, ay = ENTITIES["ALERT_EVENT"]
    segments.append((ax, ay, ax, ny1, {"ALERT_EVENT", "integrity note"}))

    # ---------------- write SVG ----------------
    add(f'<svg xmlns="http://www.w3.org/2000/svg" width="{ER_W}" height="{ER_H}" '
        f'viewBox="0 0 {ER_W} {ER_H}" font-family="{FONT}">')
    add(f'<title>Conceptual ER Diagram - Chen Notation</title>')
    add(f'<rect width="{ER_W}" height="{ER_H}" fill="{PAPER}"/>')
    add(f'<text x="{ER_W / 2}" y="62" font-size="38" font-weight="700" text-anchor="middle" fill="{INK}">'
        f'1. Conceptual ER Diagram — Chen Notation</text>')
    add(f'<text x="{ER_W / 2}" y="102" font-size="21" text-anchor="middle" fill="{MUTED}">'
        f'Real-Time Stock Market Watchlist &amp; Alert System · 6 entity types · 7 relationship types · '
        f'participation and cardinality derived from sql/00_schema.sql</text>')
    out.extend(lines_svg)
    add(f'<line x1="{ax}" y1="{ay}" x2="{ax}" y2="{ny1}" stroke="{MUTED}" stroke-width="1.6" '
        f'stroke-dasharray="7 6"/>')

    for n, s in ent_shape.items():
        add(f'<rect x="{s.cx - ENT_HW}" y="{s.cy - ENT_HH}" width="{2 * ENT_HW}" height="{2 * ENT_HH}" '
            f'fill="{PAPER}" stroke="{INK}" stroke-width="2.4"/>')
        add(f'<text x="{s.cx}" y="{s.cy + 8}" font-size="{ENT_FONT}" font-weight="700" '
            f'text-anchor="middle" fill="{INK}">{n}</text>')
    for n, s in rel_shape.items():
        pts = f"{s.cx},{s.cy - REL_HH} {s.cx + REL_HW},{s.cy} {s.cx},{s.cy + REL_HH} {s.cx - REL_HW},{s.cy}"
        add(f'<polygon points="{pts}" fill="{PAPER}" stroke="{INK}" stroke-width="2.2"/>')
        add(f'<text x="{s.cx}" y="{s.cy + 6}" font-size="{REL_FONT if len(n) < 11 else 16}" '
            f'font-weight="700" text-anchor="middle" fill="{INK}">{n}</text>')
    for owner, label, x, y, key in ATTRIBUTES:
        s = attr_shape[f"{owner}.{label}"]
        add(f'<ellipse cx="{x}" cy="{y}" rx="{s.hw:.1f}" ry="{s.hh}" fill="{PAPER}" '
            f'stroke="{INK}" stroke-width="1.6"/>')
        deco = ' text-decoration="underline"' if key else ""
        add(f'<text x="{x}" y="{y + 6}" font-size="{ATTR_FONT}" text-anchor="middle" '
            f'fill="{INK}"{deco}>{label}</text>')
    out.extend(labels_svg)

    add(f'<rect x="{nx1}" y="{ny1}" width="{nx2 - nx1}" height="{ny2 - ny1}" rx="8" fill="#f6f6f7" '
        f'stroke="{MUTED}" stroke-width="1.6" stroke-dasharray="7 6"/>')
    for k, (bold, rest) in enumerate(NOTE_LINES):
        head = f'<tspan font-weight="700">{escape(bold)}</tspan>' if bold else ""
        add(f'<text x="{nx1 + 18}" y="{ny1 + 34 + 34 * k}" font-size="17" fill="{INK}">'
            f'{head}{escape(rest)}</text>')
        TEXT_ITEMS.append((bold + rest, 17, bool(bold), nx2 - nx1 - 36, "integrity note"))

    # ---------------- legends ----------------
    top = 1600
    shapes += _er_legends(out, top)
    add('</svg>')
    return "\n".join(out), shapes, segments


def _er_legends(out, top):
    add = out.append
    boxes = [(40, top, 760, 1975, "Notation (Chen, as in the course template)"),
             (790, top, 1705, 1975, "Keys"),
             (1735, top, 2360, 1975, "Reading notes")]
    shapes = []
    for x1, y1, x2, y2, title in boxes:
        add(f'<rect x="{x1}" y="{y1}" width="{x2 - x1}" height="{y2 - y1}" rx="10" fill="#fafafa" '
            f'stroke="#c8c8cc" stroke-width="1.4"/>')
        add(f'<text x="{x1 + 20}" y="{y1 + 36}" font-size="21" font-weight="700" fill="{INK}">{title}</text>')
        shapes.append(Shape("rect", (x1 + x2) / 2, (y1 + y2) / 2, (x2 - x1) / 2, (y2 - y1) / 2, title))

    # notation symbols
    x, y = 60, top + 78
    rows = [
        ("rect", "ENTITY TYPE (rectangle)"),
        ("ellipse", "attribute (oval)"),
        ("key", "key attribute (underlined)"),
        ("composite", "composite attribute: listing = (exchange, symbol)"),
        ("diamond", "RELATIONSHIP TYPE (diamond)"),
        ("double", "total participation: every entity takes part (NOT NULL FK)"),
        ("single", "partial participation"),
        ("card", "cardinality ratio 1 : N, or M : N for many-to-many"),
    ]
    for kind, text in rows:
        cy = y
        if kind == "rect":
            add(f'<rect x="{x}" y="{cy - 15}" width="110" height="30" fill="#fff" stroke="{INK}" stroke-width="2"/>')
        elif kind in ("ellipse", "key"):
            add(f'<ellipse cx="{x + 55}" cy="{cy}" rx="55" ry="16" fill="#fff" stroke="{INK}" stroke-width="1.6"/>')
            deco = ' text-decoration="underline"' if kind == "key" else ""
            add(f'<text x="{x + 55}" y="{cy + 5}" font-size="15" text-anchor="middle" fill="{INK}"{deco}>'
                f'{"key" if kind == "key" else "attr"}</text>')
        elif kind == "composite":
            add(f'<line x1="{x + 30}" y1="{cy}" x2="{x + 95}" y2="{cy - 8}" stroke="{INK}" stroke-width="1.4"/>')
            add(f'<line x1="{x + 30}" y1="{cy}" x2="{x + 95}" y2="{cy + 10}" stroke="{INK}" stroke-width="1.4"/>')
            add(f'<ellipse cx="{x + 30}" cy="{cy}" rx="30" ry="13" fill="#fff" stroke="{INK}" stroke-width="1.4"/>')
            add(f'<ellipse cx="{x + 95}" cy="{cy - 9}" rx="16" ry="8" fill="#fff" stroke="{INK}" stroke-width="1.2"/>')
            add(f'<ellipse cx="{x + 95}" cy="{cy + 11}" rx="16" ry="8" fill="#fff" stroke="{INK}" stroke-width="1.2"/>')
        elif kind == "diamond":
            add(f'<polygon points="{x + 55},{cy - 17} {x + 110},{cy} {x + 55},{cy + 17} {x},{cy}" '
                f'fill="#fff" stroke="{INK}" stroke-width="2"/>')
        elif kind == "double":
            add(f'<line x1="{x}" y1="{cy - 4}" x2="{x + 110}" y2="{cy - 4}" stroke="{INK}" stroke-width="2"/>')
            add(f'<line x1="{x}" y1="{cy + 4}" x2="{x + 110}" y2="{cy + 4}" stroke="{INK}" stroke-width="2"/>')
        elif kind == "single":
            add(f'<line x1="{x}" y1="{cy}" x2="{x + 110}" y2="{cy}" stroke="{INK}" stroke-width="2"/>')
        elif kind == "card":
            add(f'<text x="{x + 55}" y="{cy + 8}" font-size="22" font-weight="700" text-anchor="middle" '
                f'fill="{INK}">1 · N · M</text>')
        add(f'<text x="{x + 132}" y="{cy + 6}" font-size="17" fill="{INK}">{escape(text)}</text>')
        TEXT_ITEMS.append((text, 17, False, 760 - (x + 132) - 16, "notation legend"))
        y += 36

    # keys
    key_lines = [
        ("USER", "user_id;  username;  email   (three separate keys, all underlined)"),
        ("INSTRUMENT", "instrument_id;  listing = (exchange, symbol)   (composite key)"),
        ("WATCHLIST", "watchlist_id;  name is unique per owning USER  →  (user_id, name)"),
        ("PRICE_TICK", "tick_id;  (source, source_event_id) unique per INSTRUMENT"),
        ("", "→  (source, instrument_id, source_event_id)"),
        ("ALERT_RULE", "rule_id;  (direction, threshold) unique per USER and INSTRUMENT"),
        ("", "→  (user_id, instrument_id, direction, threshold)"),
        ("ALERT_EVENT", "event_id;  at most one event per (ALERT_RULE, PRICE_TICK)  →  (rule_id, tick_id)"),
    ]
    y = top + 76
    for ent, text in key_lines:
        if ent:
            add(f'<text x="810" y="{y}" font-size="16.5" font-weight="700" fill="{INK}">{ent}</text>')
        add(f'<text x="945" y="{y}" font-size="16.5" fill="{INK}">{escape(text)}</text>')
        TEXT_ITEMS.append((text, 16.5, False, 1705 - 945 - 16, "keys legend"))
        y += 30
    for k, line in enumerate(["A key that includes a relationship cannot be drawn as an underlined attribute;",
                              "after mapping it becomes a UNIQUE constraint of the table (see the relational schema)."]):
        add(f'<text x="810" y="{y + 8 + 24 * k}" font-size="15.5" fill="{MUTED}">{escape(line)}</text>')
        TEXT_ITEMS.append((line, 15.5, False, 1705 - 810 - 16, "keys legend"))

    # reading notes
    notes = [
        "watchlist_items is NOT an entity: it is the",
        "M:N relationship CONTAINS (attribute added_at),",
        "mapped to its own table.",
        "ALERT_EVENT is an associative entity: it records",
        "that a rule fired on a tick, but has its own key",
        "event_id and attribute fired_at.",
        "volume is the only optional attribute (NULL =",
        "unknown). Foreign keys, data types and ON DELETE",
        "rules are implementation details: they appear",
        "only in diagram 2, the relational schema.",
    ]
    y = top + 76
    for i, line in enumerate(notes):
        add(f'<text x="1755" y="{y}" font-size="16.5" fill="{INK}">{escape(line)}</text>')
        TEXT_ITEMS.append((line, 16.5, False, 2360 - 1755 - 16, "reading notes"))
        y += 27 + (12 if i in (2, 5) else 0)
    return shapes


# =========================================================================
# 2. Relational schema
# =========================================================================
RS_W, RS_H = 1720, 1650
TW, TH0, TR = 420, 44, 30           # table width, header height, row height
TABLES = {  # name: (x, top, [(column, type, marks, is_pk)])
    "users": (80, 170, [("user_id", "BIGINT", "PK", True), ("username", "TEXT", "AK1", False),
                        ("email", "TEXT", "AK2", False), ("created_at", "TIMESTAMPTZ", "", False)]),
    "watchlists": (1100, 170, [("watchlist_id", "BIGINT", "PK", True), ("user_id", "BIGINT", "FK, AK1", False),
                               ("name", "TEXT", "AK1", False), ("created_at", "TIMESTAMPTZ", "", False)]),
    "watchlist_items": (1100, 420, [("watchlist_id", "BIGINT", "PK, FK", True),
                                    ("instrument_id", "BIGINT", "PK, FK", True),
                                    ("added_at", "TIMESTAMPTZ", "", False)]),
    "instruments": (1100, 640, [("instrument_id", "BIGINT", "PK", True), ("exchange", "TEXT", "AK1", False),
                                ("symbol", "TEXT", "AK1", False), ("name", "TEXT", "", False),
                                ("quote_currency", "TEXT", "", False), ("is_active", "BOOLEAN", "", False)]),
    "alert_rules": (80, 560, [("rule_id", "BIGINT", "PK", True), ("user_id", "BIGINT", "FK, AK1", False),
                              ("instrument_id", "BIGINT", "FK, AK1", False), ("direction", "TEXT", "AK1", False),
                              ("threshold", "NUMERIC(18,8)", "AK1", False), ("cooldown_seconds", "INTEGER", "", False),
                              ("is_active", "BOOLEAN", "", False), ("created_at", "TIMESTAMPTZ", "", False)]),
    "alert_events": (80, 1000, [("event_id", "BIGINT", "PK", True), ("rule_id", "BIGINT", "FK, AK1", False),
                                ("tick_id", "BIGINT", "FK, AK1", False), ("fired_at", "TIMESTAMPTZ", "", False)]),
    "price_ticks": (1100, 1000, [("tick_id", "BIGINT", "PK", True), ("instrument_id", "BIGINT", "FK, AK1", False),
                                 ("observed_at", "TIMESTAMPTZ", "", False), ("price", "NUMERIC(18,8)", "", False),
                                 ("volume", "NUMERIC(24,8)", "NULL", False), ("source", "TEXT", "AK1", False),
                                 ("source_event_id", "TEXT", "AK1", False), ("ingested_at", "TIMESTAMPTZ", "", False)]),
}
# FK arrows: (constraint name, child table, parent table, path points)
def _row_y(table, column):
    x, top, cols = TABLES[table]
    k = [c[0] for c in cols].index(column)
    return top + TH0 + TR * k + TR / 2


ARROWS = [
    ("fk_watchlists_user", "watchlists", "users", [(1100, _row_y("watchlists", "user_id")), (800, None), (None, _row_y("users", "user_id") - 7), (500, None)]),
    ("fk_watchlist_items_watchlist", "watchlist_items", "watchlists", [(1520, _row_y("watchlist_items", "watchlist_id")), (1570, None), (None, _row_y("watchlists", "watchlist_id")), (1520, None)]),
    ("fk_watchlist_items_instrument", "watchlist_items", "instruments", [(1520, _row_y("watchlist_items", "instrument_id")), (1610, None), (None, _row_y("instruments", "instrument_id") - 7), (1520, None)]),
    ("fk_alert_rules_instrument", "alert_rules", "instruments", [(500, _row_y("alert_rules", "instrument_id")), (800, None), (None, _row_y("instruments", "instrument_id")), (1100, None)]),
    ("fk_alert_rules_user", "alert_rules", "users", [(500, _row_y("alert_rules", "user_id")), (545, None), (None, _row_y("users", "user_id") + 7), (500, None)]),
    ("fk_price_ticks_instrument", "price_ticks", "instruments", [(1520, _row_y("price_ticks", "instrument_id")), (1650, None), (None, _row_y("instruments", "instrument_id") + 7), (1520, None)]),
    ("fk_alert_events_rule", "alert_events", "alert_rules", [(80, _row_y("alert_events", "rule_id")), (40, None), (None, _row_y("alert_rules", "rule_id")), (80, None)]),
    ("fk_alert_events_tick", "alert_events", "price_ticks", [(500, _row_y("alert_events", "tick_id")), (800, None), (None, _row_y("price_ticks", "tick_id")), (1100, None)]),
]
ON_DELETE = [("fk_watchlists_user", "watchlists.user_id → users", "CASCADE"),
             ("fk_alert_rules_user", "alert_rules.user_id → users", "CASCADE"),
             ("fk_watchlist_items_watchlist", "watchlist_items.watchlist_id → watchlists", "CASCADE"),
             ("fk_watchlist_items_instrument", "watchlist_items.instrument_id → instruments", "RESTRICT"),
             ("fk_alert_rules_instrument", "alert_rules.instrument_id → instruments", "RESTRICT"),
             ("fk_price_ticks_instrument", "price_ticks.instrument_id → instruments", "RESTRICT"),
             ("fk_alert_events_rule", "alert_events.rule_id → alert_rules", "CASCADE"),
             ("fk_alert_events_tick", "alert_events.tick_id → price_ticks", "RESTRICT")]


def _resolve(path):
    pts, (x, y) = [], path[0]
    pts.append((x, y))
    for px, py in path[1:]:
        x = px if px is not None else x
        y = py if py is not None else y
        pts.append((x, y))
    return pts


def relational_svg():
    out, shapes, segments = [], [], []
    add = out.append
    add(f'<svg xmlns="http://www.w3.org/2000/svg" width="{RS_W}" height="{RS_H}" '
        f'viewBox="0 0 {RS_W} {RS_H}" font-family="{FONT}">')
    add('<title>Relational Schema - Tables, PKs and FKs</title>')
    add('<defs><marker id="arrow" markerWidth="12" markerHeight="10" refX="11" refY="5" orient="auto">'
        f'<path d="M0,0 L12,5 L0,10 z" fill="{INK}"/></marker></defs>')
    add(f'<rect width="{RS_W}" height="{RS_H}" fill="{PAPER}"/>')
    add(f'<text x="{RS_W / 2}" y="62" font-size="36" font-weight="700" text-anchor="middle" fill="{INK}">'
        f'2. Relational Schema — Tables, PKs and FKs</text>')
    add(f'<text x="{RS_W / 2}" y="100" font-size="19" text-anchor="middle" fill="{MUTED}">'
        f'Logical design mapped from diagram 1 · column names and types exactly as in sql/00_schema.sql '
        f'(checked by sql/verify_spec.sql)</text>')

    for name, (x, top, cols) in TABLES.items():
        h = TH0 + TR * len(cols)
        shapes.append(Shape("rect", x + TW / 2, top + h / 2, TW / 2, h / 2, name))

    for name, child, parent, path in ARROWS:
        pts = _resolve(path)
        for (x1, y1), (x2, y2) in zip(pts, pts[1:]):
            segments.append((x1, y1, x2, y2, {child, parent}))
        d = " ".join(f"{'M' if i == 0 else 'L'}{px},{py}" for i, (px, py) in enumerate(pts))
        add(f'<path d="{d}" fill="none" stroke="{INK}" stroke-width="1.8" marker-end="url(#arrow)"/>')

    for name, (x, top, cols) in TABLES.items():
        h = TH0 + TR * len(cols)
        add(f'<rect x="{x}" y="{top}" width="{TW}" height="{h}" fill="{PAPER}" stroke="{INK}" stroke-width="2"/>')
        add(f'<rect x="{x}" y="{top}" width="{TW}" height="{TH0}" fill="#ececef" stroke="{INK}" stroke-width="2"/>')
        add(f'<text x="{x + 16}" y="{top + 29}" font-size="21" font-weight="700" fill="{INK}">{name}</text>')
        for k, (col, typ, marks, pk) in enumerate(cols):
            cy = top + TH0 + TR * k + TR / 2
            if k:
                add(f'<line x1="{x}" y1="{cy - TR / 2}" x2="{x + TW}" y2="{cy - TR / 2}" stroke="#d9d9dd"/>')
            deco = ' text-decoration="underline" font-weight="700"' if pk else ""
            add(f'<text x="{x + 16}" y="{cy + 6}" font-size="16.5" fill="{INK}"{deco}>{col}</text>')
            add(f'<text x="{x + 190}" y="{cy + 6}" font-size="15" fill="{MUTED}">{typ}</text>')
            add(f'<text x="{x + TW - 14}" y="{cy + 6}" font-size="15" font-weight="700" text-anchor="end" '
                f'fill="{INK}">{marks}</text>')
            TEXT_ITEMS.append((col, 16.5, pk, 190 - 16 - 6, f"table {name}: column name"))
            TEXT_ITEMS.append((typ + "   " + marks, 15, True, TW - 190 - 14, f"table {name}: type + marks"))

    # legend + ON DELETE table
    top = 1330
    add(f'<rect x="40" y="{top}" width="{RS_W - 80}" height="{RS_H - top - 30}" rx="10" fill="#fafafa" '
        f'stroke="#c8c8cc" stroke-width="1.4"/>')
    legend = [
        "PK = primary key (underlined) · FK = foreign key; the arrow points to the referenced primary key",
        "AKn = column of alternate (candidate) key n; columns with the same n form ONE composite UNIQUE constraint",
        "NULL = nullable column; every other column is NOT NULL · all keys are named constraints in the DDL",
    ]
    y = top + 38
    for line in legend:
        add(f'<text x="64" y="{y}" font-size="17" fill="{INK}">{escape(line)}</text>')
        TEXT_ITEMS.append((line, 17, False, RS_W - 40 - 64 - 16, "relational legend"))
        y += 30
    add(f'<text x="64" y="{y + 14}" font-size="18" font-weight="700" fill="{INK}">'
        f'Foreign keys and ON DELETE (from pg_constraint)</text>')
    y += 46
    for i, (fk, what, action) in enumerate(ON_DELETE):
        col_x = 64 if i < 4 else 880
        row_y = y + (i % 4) * 28
        add(f'<text x="{col_x}" y="{row_y}" font-size="15.5" fill="{INK}">{escape(what)}</text>')
        add(f'<text x="{col_x + 700}" y="{row_y}" font-size="15.5" font-weight="700" text-anchor="end" '
            f'fill="{INK}">{action}</text>')
    add('</svg>')
    return "\n".join(out), shapes, segments


# =========================================================================
# 3. Does diagram 1 match the real database? (read-only catalog queries)
# =========================================================================
ER_TO_TABLE = {"USER": "users", "WATCHLIST": "watchlists", "INSTRUMENT": "instruments",
               "ALERT_RULE": "alert_rules", "ALERT_EVENT": "alert_events",
               "PRICE_TICK": "price_ticks", "CONTAINS": "watchlist_items"}
REL_TO_FK = {"OWNS": ["fk_watchlists_user"], "CREATES": ["fk_alert_rules_user"],
             "CONTAINS": ["fk_watchlist_items_watchlist", "fk_watchlist_items_instrument"],
             "MONITORS": ["fk_alert_rules_instrument"], "GENERATES": ["fk_alert_events_rule"],
             "HAS_TICK": ["fk_price_ticks_instrument"], "TRIGGERED_BY": ["fk_alert_events_tick"]}
# keys that include a relationship (shown in the Keys legend, not underlined)
LEGEND_COMPOSITE_KEYS = {"watchlists": {"user_id", "name"},
                         "price_ticks": {"source", "instrument_id", "source_event_id"},
                         "alert_rules": {"user_id", "instrument_id", "direction", "threshold"},
                         "alert_events": {"rule_id", "tick_id"}}


def _psql_rows(db, sql):
    psql = shutil.which("psql") or "/opt/homebrew/opt/postgresql@18/bin/psql"
    p = subprocess.run([psql, "-X", "-At", "-F", "|", "-v", "ON_ERROR_STOP=1", "-d", db, "-c", sql],
                       text=True, capture_output=True, check=True)
    return [line.split("|") for line in p.stdout.splitlines() if line]


def verify_against_catalog(db):
    print(f"Diagram 1 (conceptual ER) compared with the PostgreSQL catalog of database {db}")
    tables = "('" + "','".join(ER_TO_TABLE.values()) + "')"
    columns = {}
    for t, c in _psql_rows(db, f"""SELECT table_name, column_name FROM information_schema.columns
                                  WHERE table_schema = 'public' AND table_name IN {tables}"""):
        columns.setdefault(t, set()).add(c)
    fks = {}
    for name, child, parent, cols, notnull, unique_alone in _psql_rows(db, """
        SELECT c.conname, c.conrelid::regclass, c.confrelid::regclass,
               string_agg(a.attname, ',' ORDER BY a.attnum), bool_and(a.attnotnull),
               EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = c.conrelid AND i.indisunique
                         AND i.indkey::int2[] @> c.conkey AND c.conkey @> i.indkey::int2[])
        FROM pg_constraint c
        JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY (c.conkey)
        WHERE c.contype = 'f' AND c.connamespace = 'public'::regnamespace
        GROUP BY c.oid, c.conname, c.conrelid, c.confrelid, c.conkey"""):
        fks[name] = (child, parent, set(cols.split(",")), notnull == "t", unique_alone == "t")
    keys = {}
    for t, kind, cols in _psql_rows(db, """
        SELECT c.conrelid::regclass, c.contype,
               string_agg(a.attname, ',' ORDER BY a.attnum)
        FROM pg_constraint c
        JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY (c.conkey)
        WHERE c.contype IN ('p', 'u') AND c.connamespace = 'public'::regnamespace
        GROUP BY c.oid, c.conrelid, c.contype"""):
        keys.setdefault(t, []).append((kind, set(cols.split(","))))

    problems = []

    def report(ok, text):
        print(f"   {'OK      ' if ok else 'MISMATCH'} {text}")
        if not ok:
            problems.append(text)

    # 1. attributes = table columns minus foreign-key columns
    er_attrs = {}
    for owner, label, *_ in ATTRIBUTES:
        target = "INSTRUMENT" if owner == "listing" else owner
        if label != "listing":                       # composite: only its components are columns
            er_attrs.setdefault(target, set()).add(label)
    fk_cols = {}
    for child, _p, cols, _n, _u in fks.values():
        fk_cols.setdefault(child, set()).update(cols)
    for ent, table in ER_TO_TABLE.items():
        expected = columns.get(table, set()) - fk_cols.get(table, set())
        report(er_attrs.get(ent, set()) == expected,
               f"{ent:<12} attributes = {table} columns without FK columns: {sorted(expected)}")

    # 2. every FK is drawn exactly once as (part of) a relationship
    drawn = [fk for lst in REL_TO_FK.values() for fk in lst]
    report(sorted(drawn) == sorted(fks), f"8 relationships lines cover all {len(fks)} foreign keys exactly once")

    # 3. cardinality and participation of every relationship
    for rel, (_x, _y, ea, ca, ta, eb, cb, tb) in RELATIONSHIPS.items():
        if rel == "CONTAINS":
            pk = next(cols for kind, cols in keys["watchlist_items"] if kind == "p")
            both = set().union(*(fks[f][2] for f in REL_TO_FK[rel]))
            report(pk == both and (ca, cb) == ("M", "N") and not ta and not tb,
                   "CONTAINS is M:N: watchlist_items PK = (watchlist_id, instrument_id) = its two FKs; "
                   "both sides partial")
            continue
        child, parent, cols, notnull, unique_alone = fks[REL_TO_FK[rel][0]]
        one, many = (ea, eb) if ca == "1" else (eb, ea)
        many_total = tb if many == eb else ta
        one_total = ta if one == ea else tb
        ok = (ER_TO_TABLE[many] == child and ER_TO_TABLE[one] == parent and not unique_alone
              and many_total == notnull and not one_total)
        report(ok, f"{rel:<12} {one} 1 : N {many} (FK {child}.{','.join(sorted(cols))} not unique alone); "
                   f"{many} total = FK NOT NULL ({notnull}); {one} partial")

    # 4. underlined keys = PK + single-column UNIQUE; composite listing = UNIQUE(exchange, symbol)
    underlined = {}
    for owner, label, _x, _y, is_key in ATTRIBUTES:
        if is_key and owner in ENTITIES and label != "listing":
            underlined.setdefault(owner, set()).add(label)
    for ent, table in ER_TO_TABLE.items():
        if ent == "CONTAINS":
            continue
        single = {next(iter(c)) for kind, c in keys.get(table, []) if len(c) == 1}
        report(underlined.get(ent, set()) == single,
               f"{ent:<12} underlined keys {sorted(underlined.get(ent, set()))} = single-column PK/UNIQUE {sorted(single)}")
    report(any(c == {"exchange", "symbol"} for _k, c in keys["instruments"]),
           "INSTRUMENT composite key listing = UNIQUE (exchange, symbol)")
    for table, cols in LEGEND_COMPOSITE_KEYS.items():
        report(any(c == cols for _k, c in keys.get(table, [])),
               f"Keys legend: {table} ({', '.join(sorted(cols))}) is a declared UNIQUE constraint")

    # 5. completeness: nothing in the database is left out of the diagram
    all_tables = {t for (t,) in _psql_rows(db, """SELECT c.relname FROM pg_class c
                  WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'r'""")}
    report(sorted(all_tables) == sorted(ER_TO_TABLE.values()) and len(all_tables) == 7,
           f"7 tables = 6 entity types + 1 M:N relationship (CONTAINS); catalog has {len(all_tables)}: "
           f"{', '.join(sorted(all_tables))}")
    n_1n = sum(1 for r in RELATIONSHIPS if r != "CONTAINS")
    report(len(fks) == n_1n + 2,
           f"8 foreign keys = {n_1n} one-to-many relationships x 1 FK + 1 many-to-many relationship x 2 FKs")
    drawn_keys = []                                    # every key the diagram expresses, as (table, columns)
    for ent, cols in underlined.items():
        drawn_keys += [(ER_TO_TABLE[ent], {c}) for c in cols]
    drawn_keys.append(("instruments", {"exchange", "symbol"}))                    # composite attribute
    drawn_keys += [(t, c) for t, c in LEGEND_COMPOSITE_KEYS.items()]              # Keys legend
    drawn_keys.append(("watchlist_items", set().union(*(fks[f][2] for f in REL_TO_FK["CONTAINS"]))))
    catalog_keys = [(t, c) for t, lst in keys.items() for _k, c in lst]
    missing = [k for k in catalog_keys if k not in drawn_keys]
    extra = [k for k in drawn_keys if k not in catalog_keys]
    report(not missing and not extra and len(catalog_keys) == 14,
           f"all {len(catalog_keys)} PRIMARY KEY/UNIQUE constraints are expressed by the diagram "
           f"(underlined: {sum(len(v) for v in underlined.values())}, composite attribute: 1, Keys legend: "
           f"{len(LEGEND_COMPOSITE_KEYS)}, M:N relationship: 1)" + (f"; missing {missing}" if missing else "")
           + (f"; extra {extra}" if extra else ""))
    # A parent side can only be TOTAL if something rejects parent rows without children. CHECK cannot
    # look at other tables and an FK only constrains the child, so it would have to be a trigger that
    # raises an error. List the triggers on parent tables and whether their functions can raise.
    parents = sorted({fks[f][1] for f in fks})
    trig = _psql_rows(db, f"""SELECT c.relname, t.tgname, p.proname,
                         (pg_get_functiondef(p.oid) ~* '\\mRAISE\\M') AS can_raise
                         FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_proc p ON p.oid = t.tgfoid
                         WHERE NOT t.tgisinternal AND c.relname IN ('{"','".join(parents)}')""")
    rejecting = [r for r in trig if r[3] == "t"]
    report(not rejecting,
           "no trigger on a parent table can reject a row: "
           + (", ".join(f"{r[1]} on {r[0]} (function {r[2]} contains no RAISE: it only creates "
                        f"alert events, conditionally)" for r in trig) or "none exist")
           + " -> every 'one' side and both CONTAINS sides are partial")
    childless = _psql_rows(db, """
        SELECT 'instruments without price_ticks (HAS_TICK)', count(*) FROM instruments i
         WHERE NOT EXISTS (SELECT 1 FROM price_ticks t WHERE t.instrument_id = i.instrument_id)
        UNION ALL
        SELECT 'instruments without alert_rules (MONITORS)', count(*) FROM instruments i
         WHERE NOT EXISTS (SELECT 1 FROM alert_rules r WHERE r.instrument_id = i.instrument_id)
        UNION ALL
        SELECT 'alert_rules without alert_events (GENERATES)', count(*) FROM alert_rules r
         WHERE NOT EXISTS (SELECT 1 FROM alert_events e WHERE e.rule_id = r.rule_id)
        UNION ALL
        SELECT 'price_ticks without alert_events (TRIGGERED_BY)', count(*) FROM price_ticks t
         WHERE NOT EXISTS (SELECT 1 FROM alert_events e WHERE e.tick_id = t.tick_id)""")
    report(all(int(c) > 0 for _l, c in childless),
           "data also shows childless parents: " + "; ".join(f"{label} = {c}" for label, c in childless)
           + " (users without watchlists or rules and empty watchlists occur in the committed DML and "
             "transaction demos, 02_dml.out and 16_transactions.out)")

    print(f"RESULT: {'diagram matches the catalog' if not problems else str(len(problems)) + ' mismatch(es)'}")
    return 1 if problems else 0


# =========================================================================
# 4. Audit ANOTHER Chen diagram from its SVG source (e.g. a team-drawn one):
#    rebuild entities, attributes, keys, relationships, cardinality and
#    participation from the geometry and compare them with the model above,
#    which --verify-db checks against the catalog.
# =========================================================================
def audit_svg(path):
    import xml.etree.ElementTree as ET
    root = ET.parse(path).getroot()
    tag = lambda e: e.tag.split("}")[-1]
    f = lambda e, k: float(e.get(k))
    texts, lines, shapes = [], [], []
    for e in root.iter():
        t = tag(e)
        if t == "text":
            texts.append({"s": (e.text or "").strip(), "x": f(e, "x"), "y": f(e, "y"),
                          "size": float(e.get("font-size", "16"))})
        elif t == "line":
            lines.append((f(e, "x1"), f(e, "y1"), f(e, "x2"), f(e, "y2")))
        elif t == "ellipse":
            shapes.append(Shape("ellipse", f(e, "cx"), f(e, "cy"), f(e, "rx"), f(e, "ry"), ""))
        elif t == "rect" and float(e.get("width")) < 1000:          # skip the page background
            w, h = f(e, "width"), f(e, "height")
            shapes.append(Shape("rect", f(e, "x") + w / 2, f(e, "y") + h / 2, w / 2, h / 2, ""))
        elif t == "polygon":
            pts = [tuple(map(float, p.split(","))) for p in e.get("points").split()]
            xs, ys = [p[0] for p in pts], [p[1] for p in pts]
            shapes.append(Shape("diamond", (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2,
                                (max(xs) - min(xs)) / 2, (max(ys) - min(ys)) / 2, ""))
    for s in shapes:                                   # label = the text drawn inside the shape
        inside = [t for t in texts if s.contains(t["x"], t["y"] - t["size"] * 0.35, 2)]
        s.name = max(inside, key=lambda t: t["size"])["s"] if inside else "?"

    # underlines: short horizontal lines just below an attribute label
    underlined, connectors = set(), []
    for x1, y1, x2, y2 in lines:
        hit = None
        if abs(y1 - y2) < 0.5:
            for t in texts:
                half = text_width(t["s"], t["size"]) / 2 + 12
                if 0 < y1 - t["y"] < 12 and abs((x1 + x2) / 2 - t["x"]) < 15 and abs(x2 - x1) <= 2 * half:
                    hit = t
        if hit:
            underlined.add(hit["s"] + f"@{hit['x']:.0f},{hit['y']:.0f}")
        else:
            connectors.append((x1, y1, x2, y2))

    def touching(x, y):
        best = min(shapes, key=lambda s: _boundary_gap(s, x, y))
        return best if _boundary_gap(best, x, y) < 8 else None

    attr_links, rel_lines = [], {}
    for x1, y1, x2, y2 in connectors:
        a, b = touching(x1, y1), touching(x2, y2)
        if not a or not b or a is b:
            print(f"   UNRESOLVED line ({x1:.0f},{y1:.0f})-({x2:.0f},{y2:.0f})")
            continue
        kinds = {a.kind, b.kind}
        if kinds == {"diamond", "rect"}:
            d, r = (a, b) if a.kind == "diamond" else (b, a)
            rel_lines.setdefault((d.name, r.name), []).append((x1, y1, x2, y2))
        else:
            attr_links.append((a, b))

    def attr_key(s):
        return any(u.startswith(s.name + "@") and abs(float(u.split("@")[1].split(",")[0]) - s.cx) < 25
                   for u in underlined)

    found_attrs = set()
    for a, b in attr_links:
        att, owner = (a, b) if a.kind == "ellipse" and b.kind != "ellipse" else (b, a)
        if a.kind == "ellipse" and b.kind == "ellipse":       # composite: component -> composite
            att, owner = (a, b) if a.name in ("exchange", "symbol") else (b, a)
        found_attrs.add((owner.name, att.name, attr_key(att)))
    expected_attrs = {(o, l, k) for o, l, _x, _y, k in ATTRIBUTES}

    found_rels = {}
    for (rel, ent), segs in rel_lines.items():
        cards = []
        for t in texts:
            if t["s"] in ("1", "N", "M"):
                for x1, y1, x2, y2 in segs:
                    cards.append((_point_segment(t["x"], t["y"] - 10, x1, y1, x2, y2), t["s"]))
        card = min(cards)[1] if cards else "?"
        found_rels[(rel, ent)] = (card, len(segs) >= 2)
    expected_rels = {}
    for rel, (_x, _y, ea, ca, ta, eb, cb, tb) in RELATIONSHIPS.items():
        expected_rels[(rel, ea)] = (ca, ta)
        expected_rels[(rel, eb)] = (cb, tb)

    problems = []
    def report(ok, text):
        print(f"   {'OK      ' if ok else 'MISMATCH'} {text}")
        if not ok:
            problems.append(text)

    print(f"Chen diagram {path} compared element by element with the verified model")
    ents = sorted(s.name for s in shapes if s.kind == "rect")
    report(ents == sorted(ENTITIES), f"entity types: {', '.join(ents)}")
    rels = sorted(s.name for s in shapes if s.kind == "diamond")
    report(rels == sorted(RELATIONSHIPS), f"relationship types: {', '.join(rels)}")
    report(found_attrs == expected_attrs,
           f"{len(found_attrs)} attributes with owner and key underline match the model"
           + (f"; missing {sorted(expected_attrs - found_attrs)}" if expected_attrs - found_attrs else "")
           + (f"; extra/different {sorted(found_attrs - expected_attrs)}" if found_attrs - expected_attrs else ""))
    for k in sorted(expected_rels):
        want, got = expected_rels[k], found_rels.get(k)
        report(got == want, f"{k[0]:<12} side {k[1]:<12} cardinality {want[0]}, "
                            f"{'total (double line)' if want[1] else 'partial (single line)'}"
                            + ("" if got == want else f" — drawn as {got}"))
    report(len(found_rels) == len(expected_rels), f"{len(found_rels)} relationship sides drawn, "
                                                  f"{len(expected_rels)} expected")
    print(f"RESULT: {'diagram content matches the verified model' if not problems else str(len(problems)) + ' mismatch(es)'}")
    return 1 if problems else 0


def _boundary_gap(s, x, y):
    dx, dy = x - s.cx, y - s.cy
    if s.kind == "ellipse":
        r = math.hypot(dx / s.hw, dy / s.hh)
        return abs(r - 1) * min(s.hw, s.hh) if r > 0 else min(s.hw, s.hh)
    if s.kind == "diamond":
        return abs(abs(dx) / s.hw + abs(dy) / s.hh - 1) * min(s.hw, s.hh)
    ox, oy = abs(dx) - s.hw, abs(dy) - s.hh                     # rectangle
    if ox <= 0 and oy <= 0:
        return min(-ox, -oy)
    return math.hypot(max(ox, 0), max(oy, 0))


def _point_segment(px, py, x1, y1, x2, y2):
    vx, vy = x2 - x1, y2 - y1
    t = max(0.0, min(1.0, ((px - x1) * vx + (py - y1) * vy) / (vx * vx + vy * vy or 1)))
    return math.hypot(px - x1 - t * vx, py - y1 - t * vy)


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--verify-db":
        return verify_against_catalog(sys.argv[2])
    if len(sys.argv) == 3 and sys.argv[1] == "--audit-svg":
        return audit_svg(sys.argv[2])
    if len(sys.argv) in (5, 7) and sys.argv[1] == "--render":
        font_dir = sys.argv[6] if len(sys.argv) == 7 and sys.argv[5] == "--font-dir" else None
        if len(sys.argv) == 7 and font_dir is None:
            raise SystemExit("usage: --render <file.svg> <width> <height> [--font-dir DIR]")
        render_png(Path(sys.argv[2]).resolve(), int(sys.argv[3]), int(sys.argv[4]), font_dir)
        return 0
    OUT.mkdir(parents=True, exist_ok=True)
    failed = False
    for fname, builder, size in (("ER_CORRECTED.svg", er_svg, (ER_W, ER_H)),
                                 ("RELATIONAL_SCHEMA.svg", relational_svg, (RS_W, RS_H))):
        TEXT_ITEMS.clear()
        svg, shapes, segments = builder()
        failed |= bool(run_checks(shapes, segments, fname))
        failed |= bool(check_text_fits(TEXT_ITEMS, fname))
        path = OUT / fname
        path.write_text(svg + "\n")
        print(f"   wrote {path.relative_to(ROOT)}")
        render_png(path, *size)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
