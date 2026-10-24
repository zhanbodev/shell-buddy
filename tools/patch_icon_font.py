"""Add our lizard to a COPY of a static TrueType monospace font (fonttools required)."""
import argparse
import re
from pathlib import Path
from fontTools.ttLib import TTFont, TTLibError
from fontTools.ttLib.tables._c_m_a_p import CmapSubtable
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.pens.transformPen import TransformPen

ROOT = Path(__file__).resolve().parents[1]
CODEPOINT = 0xF5000
GLYPH = "shellbuddy.lizard"


def patch(source, destination):
    source, destination = Path(source).resolve(), Path(destination).resolve()
    if source == destination or destination.exists():
        raise ValueError("Choose a new output path; existing fonts are never overwritten")
    font = TTFont(source)
    if "glyf" not in font or "fvar" in font:
        raise ValueError("Use a static TrueType .ttf font, not a collection, CFF, or variable font")
    if any(CODEPOINT in table.cmap for table in font["cmap"].tables if table.isUnicode()):
        raise ValueError("The source font already maps U+F5000; choose a different source")
    # A modified copy cannot retain the source font's signature.
    if "DSIG" in font:
        del font["DSIG"]
    cmap = font.getBestCmap()
    name = cmap.get(ord("M")) or cmap.get(ord(" "))
    if name is None:
        raise ValueError("The source font must contain ordinary monospaced text")
    advance = font["hmtx"][name][0]
    for char in "Mi0 ":
        if ord(char) in cmap and font["hmtx"][cmap[ord(char)]][0] != advance:
            raise ValueError("Choose a monospace source font")
    icon = TTFont(ROOT / "fonts/ShellBuddyIcons.ttf")
    shape = icon["glyf"][GLYPH]
    shape.recalcBounds(icon["glyf"])
    ascent, descent = font["hhea"].ascent, font["hhea"].descent
    # Preserve the mascot's proportions and the source font's one-cell advance.
    scale = min(advance * .94 / (shape.xMax - shape.xMin), (ascent - descent) * .85 / (shape.yMax - shape.yMin))
    tx = advance / 2 - (shape.xMin + shape.xMax) * scale / 2
    ty = (ascent + descent) / 2 - (shape.yMin + shape.yMax) * scale / 2
    pen = TTGlyphPen(None)
    icon.getGlyphSet()[GLYPH].draw(TransformPen(pen, (scale, 0, 0, scale, tx, ty)))
    order = font.getGlyphOrder()
    order.append(GLYPH)
    font.setGlyphOrder(order)
    font["glyf"][GLYPH] = pen.glyph()
    font["glyf"][GLYPH].recalcBounds(font["glyf"])
    font["hmtx"][GLYPH] = (advance, font["glyf"][GLYPH].xMin)
    font["maxp"].numGlyphs = len(order)
    tables = [t for t in font["cmap"].tables if t.isUnicode() and t.format == 12]
    if not tables:
        table = CmapSubtable.newSubtable(12)
        table.platformID, table.platEncID, table.language = 3, 10, 0
        table.cmap = dict(cmap)
        font["cmap"].tables.append(table)
        tables = [table]
    for table in tables:
        table.cmap[CODEPOINT] = GLYPH
    old_family = font["name"].getDebugName(16) or font["name"].getDebugName(1) or source.stem
    style = font["name"].getDebugName(2) or "Regular"
    family = old_family + " Shell Buddy"
    postscript = re.sub(r"[^A-Za-z0-9-]", "", family + "-" + style)[:63]
    names = {1: family, 2: style, 3: postscript + ";ShellBuddy-1.0", 4: family + " " + style, 6: postscript, 16: family, 17: style}
    # Keep source copyright and license records. Replace all localized family
    # records to prevent OS font caches from confusing this copy with its source.
    font["name"].names = [record for record in font["name"].names if record.nameID not in names]
    for name_id, value in names.items():
        font["name"].setName(value, name_id, 3, 1, 0x409)
    # Hinting instructions for original glyphs remain unchanged; our glyph is unhinted.
    font.save(destination)
    print(f"Created {destination}\nFont family: {family}\nSource unchanged: {source}")
    return family


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    try:
        patch(args.source, args.output)
    except (ValueError, OSError, TTLibError) as error:
        parser.exit(1, str(error) + "\n")
