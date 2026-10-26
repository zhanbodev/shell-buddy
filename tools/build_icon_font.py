"""Build the project's terminal symbol font. Asset tooling only: pip install fonttools."""
from pathlib import Path
import re
import xml.etree.ElementTree as ET
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.pens.cu2quPen import Cu2QuPen
from fontTools.pens.transformPen import TransformPen
from fontTools.svgLib.path import parse_path

ROOT = Path(__file__).resolve().parents[1]
CODEPOINT = 0xF5000
GLYPH = "shellbuddy.lizard"
CAPS = {0xF5001: "shellbuddy.cap.left", 0xF5002: "shellbuddy.cap.right",
        0xF5003: "shellbuddy.cap.top.left", 0xF5004: "shellbuddy.cap.top.right",
        0xF5005: "shellbuddy.cap.bottom.left", 0xF5006: "shellbuddy.cap.bottom.right"}


def cap_shape(style, right=False):
    raw = TTGlyphPen(None)
    pen = TransformPen(raw, (-1, 0, 0, 1, 1000, 0)) if right else raw
    top, bottom, radius = 1000, -200, 200
    round_top, round_bottom = style != "bottom", style != "top"
    pen.moveTo((radius if round_top else 0, top))
    pen.lineTo((1000, top))
    pen.lineTo((1000, bottom))
    pen.lineTo((radius if round_bottom else 0, bottom))
    if round_bottom:
        pen.qCurveTo((0, bottom), (0, bottom + radius))
    pen.lineTo((0, top - radius if round_top else top))
    if round_top:
        pen.qCurveTo((0, top), (radius, top))
    pen.closePath()
    return raw.glyph()


def build():
    root = ET.parse(ROOT / "fonts/lizard.svg").getroot()
    raw = TTGlyphPen(None)
    # A square, fixed-pitch icon cell; patched fonts fit this outline to their cell.
    pen = Cu2QuPen(TransformPen(raw, (0.72, 0, 0, -0.72, 50, 905)), max_err=0.7, reverse_direction=True)
    for path in root:
        transform = path.get("transform", "")
        target = pen
        if transform:
            match = re.fullmatch(r"translate\(([-\d.]+)[ ,]+([-\d.]+)\)", transform)
            if not match:
                raise ValueError("Unsupported source transform: " + transform)
            target = TransformPen(pen, (1, 0, 0, 1, float(match[1]), float(match[2])))
        parse_path(path.attrib["d"], target)
    glyph = raw.glyph()
    empty = TTGlyphPen(None).glyph()
    builder = FontBuilder(1000, isTTF=True)
    builder.setupGlyphOrder([".notdef", "space", GLYPH, *CAPS.values()])
    builder.setupCharacterMap({32: "space", CODEPOINT: GLYPH, **CAPS})
    shapes = {".notdef": empty, "space": empty, GLYPH: glyph}
    for codepoint, name in CAPS.items():
        style = "top" if "top" in name else "bottom" if "bottom" in name else "both"
        shapes[name] = cap_shape(style, name.endswith("right"))
    builder.setupGlyf(shapes)
    glyph.recalcBounds(builder.font["glyf"])
    builder.setupHorizontalMetrics({".notdef": (1000, 0), "space": (1000, 0), GLYPH: (1000, glyph.xMin), **{name: (1000, 0) for name in CAPS.values()}})
    builder.setupHorizontalHeader(ascent=1000, descent=-200)
    builder.setupNameTable({"familyName": "Shell Buddy Icons", "styleName": "Regular", "uniqueFontIdentifier": "ShellBuddyIcons-Regular-1.1", "fullName": "Shell Buddy Icons Regular", "psName": "ShellBuddyIcons-Regular", "version": "Version 1.100"})
    builder.setupOS2(sTypoAscender=1000, sTypoDescender=-200, usWinAscent=1000, usWinDescent=200, fsType=0)
    builder.setupPost(isFixedPitch=1)
    # Fixed OpenType timestamp makes repeated asset builds byte-identical.
    builder.font["head"].fontRevision = 1.1
    builder.font["head"].created = builder.font["head"].modified = 3875644800
    builder.font.recalcTimestamp = False
    destination = ROOT / "fonts/ShellBuddyIcons.ttf"
    builder.save(destination)
    print(f"{destination}: {GLYPH} at U+{CODEPOINT:X}")


if __name__ == "__main__":
    build()
