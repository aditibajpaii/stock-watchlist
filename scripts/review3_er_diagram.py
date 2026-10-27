#!/usr/bin/env python3
"""Draw the Review 3 ER diagram (Chen notation) as a PNG.

    python scripts/review3_er_diagram.py

Writes docs/review3/ER_DIAGRAM_REVIEW3.png. Needs matplotlib.

Rules followed (Review 2 feedback):
  - no arrowheads: every connector is a plain line
  - no weak entity: watchlist membership is the M:N relationship CONTAINS
    (with its own attribute added_at), not a "Watchlist_item" entity
  - no foreign-key / join-only attributes on any entity (no user_id on
    WATCHLIST, no instrument_id on PRICE_TICK, no rule_id/tick_id on
    ALERT_EVENT, ...). Links are shown only by relationship diamonds.
"""
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Ellipse, Polygon, Rectangle

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "docs" / "review3" / "ER_DIAGRAM_REVIEW3.png"

INK = "#1d1d1f"
FILL_E = "#eef3f8"
FILL_R = "#fdf6e7"
FILL_A = "#ffffff"
W, H = 29.0, 19.0

fig = plt.figure(figsize=(W * 0.55, H * 0.55), dpi=200)
ax = fig.add_axes([0, 0, 1, 1])
ax.set_xlim(0, W)
ax.set_ylim(0, H)
ax.axis("off")

ENT_W, ENT_H = 3.2, 1.0
REL_W, REL_H = 2.6, 1.3
shapes = {}


def entity(name, x, y):
    ax.add_patch(Rectangle((x - ENT_W / 2, y - ENT_H / 2), ENT_W, ENT_H,
                           fc=FILL_E, ec=INK, lw=1.6, zorder=3))
    ax.text(x, y, name, ha="center", va="center", fontsize=13, weight="bold",
            color=INK, zorder=4)
    shapes[name] = ("E", x, y)


def relation(name, x, y):
    pts = [(x - REL_W / 2, y), (x, y + REL_H / 2), (x + REL_W / 2, y), (x, y - REL_H / 2)]
    ax.add_patch(Polygon(pts, closed=True, fc=FILL_R, ec=INK, lw=1.6, zorder=3))
    ax.text(x, y, name, ha="center", va="center", fontsize=9.5, weight="bold",
            color=INK, zorder=4)
    shapes[name] = ("R", x, y)


def attr(label, x, y, owner, key=False, w=2.5):
    """Attribute oval joined to its owner by a plain line."""
    ox, oy = shapes[owner][1], shapes[owner][2]
    ax.plot([x, ox], [y, oy], color=INK, lw=1.0, zorder=1)
    ax.add_patch(Ellipse((x, y), w, 0.7, fc=FILL_A, ec=INK, lw=1.1, zorder=3))
    t = ax.text(x, y, label, ha="center", va="center", fontsize=10, color=INK, zorder=4)
    if key:  # underline the key attribute (width measured from the rendered text)
        bb = t.get_window_extent(renderer=fig.canvas.get_renderer())
        bb = bb.transformed(ax.transData.inverted())
        ax.plot([bb.x0, bb.x1], [y - 0.2, y - 0.2], color=INK, lw=1.0, zorder=4)
    return t


def sub_attr(label, x, y, parent_xy, w=2.0):
    """Component of a composite attribute (joined to the parent oval)."""
    ax.plot([x, parent_xy[0]], [y, parent_xy[1]], color=INK, lw=1.0, zorder=1)
    ax.add_patch(Ellipse((x, y), w, 0.65, fc=FILL_A, ec=INK, lw=1.1, zorder=3))
    ax.text(x, y, label, ha="center", va="center", fontsize=10, color=INK, zorder=4)


def link(a, b, total=False, card=None, card_at=None):
    """Plain line between an entity and a relationship.
    total=True draws a double line (total participation)."""
    ax_, ay = shapes[a][1], shapes[a][2]
    bx, by = shapes[b][1], shapes[b][2]
    if total:
        dx, dy = bx - ax_, by - ay
        ln = (dx * dx + dy * dy) ** 0.5
        px, py = -dy / ln * 0.07, dx / ln * 0.07
        for s in (1, -1):
            ax.plot([ax_ + s * px, bx + s * px], [ay + s * py, by + s * py],
                    color=INK, lw=1.3, zorder=1)
    else:
        ax.plot([ax_, bx], [ay, by], color=INK, lw=1.3, zorder=1)
    if card:
        ax.text(card_at[0], card_at[1], card, ha="center", va="center",
                fontsize=13, weight="bold", color="#b3261e", zorder=5)


# ---------------------------------------------------------------- layout
LX, RX, MX = 8.0, 20.0, 14.0
W_PAD = 0         # left column, right column, middle
Y1, Y2, Y3 = 15.2, 9.4, 3.6          # three rows
YM1, YM2 = (Y1 + Y2) / 2, (Y2 + Y3) / 2

entity("USER", LX, Y1)
entity("WATCHLIST", RX, Y1)
entity("ALERT_RULE", LX, Y2)
entity("INSTRUMENT", RX, Y2)
entity("ALERT_EVENT", LX, Y3)
entity("PRICE_TICK", RX, Y3)

relation("OWNS", MX, Y1)
relation("CREATES", LX, YM1)
relation("CONTAINS", RX, YM1)
relation("MONITORS", MX, Y2)
relation("GENERATES", LX, YM2)
relation("HAS_TICK", RX, YM2)
relation("TRIGGERED_BY", MX, Y3)

# relationships (cardinality labels sit next to the entity end)
link("USER", "OWNS", card="1", card_at=(LX + 2.0, Y1 + 0.35))
link("WATCHLIST", "OWNS", total=True, card="N", card_at=(RX - 2.0, Y1 + 0.35))
link("USER", "CREATES", card="1", card_at=(LX + 0.35, Y1 - 0.95))
link("ALERT_RULE", "CREATES", total=True, card="N", card_at=(LX + 0.35, Y2 + 0.95))
link("WATCHLIST", "CONTAINS", card="M", card_at=(RX + 0.35, Y1 - 0.95))
link("INSTRUMENT", "CONTAINS", card="N", card_at=(RX + 0.35, Y2 + 0.95))
link("ALERT_RULE", "MONITORS", total=True, card="N", card_at=(LX + 2.0, Y2 + 0.35))
link("INSTRUMENT", "MONITORS", card="1", card_at=(RX - 2.0, Y2 + 0.35))
link("ALERT_RULE", "GENERATES", card="1", card_at=(LX + 0.35, Y2 - 0.95))
link("ALERT_EVENT", "GENERATES", total=True, card="N", card_at=(LX + 0.35, Y3 + 0.95))
link("INSTRUMENT", "HAS_TICK", card="1", card_at=(RX + 0.35, Y2 - 0.95))
link("PRICE_TICK", "HAS_TICK", total=True, card="N", card_at=(RX + 0.35, Y3 + 0.95))
link("ALERT_EVENT", "TRIGGERED_BY", total=True, card="N", card_at=(LX + 2.0, Y3 + 0.35))
link("PRICE_TICK", "TRIGGERED_BY", card="1", card_at=(RX - 2.0, Y3 + 0.35))

# ---------------------------------------------------------------- attributes
AL, AR = LX - 4.6, RX + 4.6          # attribute columns
# USER
attr("user_id", AL, Y1 + 1.5, "USER", key=True)
attr("username", AL, Y1 + 0.5, "USER")
attr("email", AL, Y1 - 0.5, "USER")
attr("created_at", AL, Y1 - 1.5, "USER")
# WATCHLIST
attr("watchlist_id", AR, Y1 + 1.0, "WATCHLIST", key=True)
attr("name", AR, Y1, "WATCHLIST")
attr("created_at", AR, Y1 - 1.0, "WATCHLIST")
# CONTAINS (relationship attribute)
attr("added_at", RX - 3.6, YM1, "CONTAINS", w=2.2)
# ALERT_RULE
attr("rule_id", AL, Y2 + 2.0, "ALERT_RULE", key=True)
attr("direction", AL, Y2 + 1.2, "ALERT_RULE")
attr("threshold", AL, Y2 + 0.4, "ALERT_RULE")
attr("cooldown_seconds", AL, Y2 - 0.4, "ALERT_RULE", w=3.0)
attr("is_active", AL, Y2 - 1.2, "ALERT_RULE")
attr("created_at", AL, Y2 - 2.0, "ALERT_RULE")
# INSTRUMENT (listing = exchange + symbol is a composite attribute)
attr("instrument_id", AR, Y2 + 2.0, "INSTRUMENT", key=True)
attr("listing", AR - 0.4, Y2 + 1.0, "INSTRUMENT", w=2.0)
sub_attr("exchange", AR + 2.4, Y2 + 1.55, (AR - 0.4, Y2 + 1.0))
sub_attr("symbol", AR + 2.4, Y2 + 0.55, (AR - 0.4, Y2 + 1.0))
attr("name", AR, Y2 - 0.1, "INSTRUMENT")
attr("quote_currency", AR, Y2 - 1.0, "INSTRUMENT", w=2.8)
attr("is_active", AR, Y2 - 1.9, "INSTRUMENT")
# ALERT_EVENT
attr("event_id", AL, Y3 + 0.6, "ALERT_EVENT", key=True)
attr("fired_at", AL, Y3 - 0.6, "ALERT_EVENT")
# PRICE_TICK
attr("tick_id", AR, Y3 + 2.0, "PRICE_TICK", key=True)
attr("observed_at", AR, Y3 + 1.2, "PRICE_TICK")
attr("price", AR, Y3 + 0.4, "PRICE_TICK")
attr("volume", AR, Y3 - 0.4, "PRICE_TICK")
attr("source", AR, Y3 - 1.2, "PRICE_TICK")
attr("source_event_id", AR, Y3 - 2.0, "PRICE_TICK", w=3.0)
attr("ingested_at", RX - 1.0, Y3 - 2.3, "PRICE_TICK", w=2.4)

OUT.parent.mkdir(parents=True, exist_ok=True)
fig.savefig(OUT, dpi=200, facecolor="white")

# trim the empty white margin around the drawing
from PIL import Image, ImageChops
img = Image.open(OUT).convert("RGB")
box = ImageChops.difference(img, Image.new("RGB", img.size, "white")).getbbox()
pad = 40
img.crop((max(box[0] - pad, 0), max(box[1] - pad, 0),
          min(box[2] + pad, img.width), min(box[3] + pad, img.height))).save(OUT)
print("wrote", OUT)
