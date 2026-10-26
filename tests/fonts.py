"""Offline font tooling checks. Run with a Python environment containing fonttools."""
import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import TTFont

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('patch_icon_font', ROOT / 'tools/patch_icon_font.py')
patcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patcher)


def fixture(path):
    builder = FontBuilder(1000, isTTF=True)
    names = ['.notdef', 'space', 'M', 'i', 'zero']
    builder.setupGlyphOrder(names)
    builder.setupCharacterMap({32: 'space', ord('M'): 'M', ord('i'): 'i', ord('0'): 'zero'})
    pen = TTGlyphPen(None)
    pen.moveTo((50,0)); pen.lineTo((250,700)); pen.lineTo((500,0)); pen.closePath()
    shapes = {name: TTGlyphPen(None).glyph() for name in names}
    shapes['M'] = pen.glyph()
    builder.setupGlyf(shapes)
    builder.setupHorizontalMetrics({name: (600, 0) for name in names})
    builder.setupHorizontalHeader(ascent=900, descent=-200)
    builder.setupNameTable({'familyName': 'Test Mono', 'styleName': 'Regular', 'fullName': 'Test Mono Regular', 'psName': 'TestMono-Regular'})
    builder.setupOS2(sTypoAscender=900, sTypoDescender=-200, usWinAscent=900, usWinDescent=200)
    builder.setupPost(isFixedPitch=1)
    builder.save(path)


class Fonts(unittest.TestCase):
    def test_shipped_font_has_our_glyph_and_no_dinosaur(self):
        font = TTFont(ROOT / 'fonts/ShellBuddyIcons.ttf', checkChecksums=2)
        self.assertEqual(font.getBestCmap()[0xF5000], 'shellbuddy.lizard')
        self.assertNotIn(0xF1362, font.getBestCmap())
        glyph = font['glyf']['shellbuddy.lizard']
        self.assertGreater(glyph.numberOfContours, 0)
        self.assertGreater(glyph.xMax, glyph.xMin)
        self.assertEqual(font['hmtx']['shellbuddy.lizard'][0], font['hmtx']['space'][0])
        self.assertEqual(font['name'].getDebugName(1), 'Shell Buddy Icons')
        self.assertIn('1.100', font['name'].getDebugName(5))
        for cp in range(0xF5001, 0xF5007):
            name = font.getBestCmap()[cp]
            self.assertEqual(font['hmtx'][name][0], 1000)
            cap = font['glyf'][name]
            self.assertEqual((cap.xMin, cap.xMax, cap.yMin, cap.yMax), (0, 1000, -200, 1000))

    def test_patch_preserves_source_text_metrics_and_changes_family(self):
        with tempfile.TemporaryDirectory() as directory:
            source, output = Path(directory)/'source.ttf', Path(directory)/'patched.ttf'
            fixture(source)
            original = source.read_bytes()
            patcher.patch(source, output)
            self.assertEqual(source.read_bytes(), original)
            font = TTFont(output, checkChecksums=2)
            self.assertEqual(font['hmtx']['M'], (600, 0))
            before = TTFont(source)
            self.assertEqual(font['glyf']['M'].getCoordinates(font['glyf']), before['glyf']['M'].getCoordinates(before['glyf']))
            self.assertEqual(font['hmtx']['shellbuddy.lizard'][0], 600)
            self.assertEqual(font.getBestCmap()[0xF5000], 'shellbuddy.lizard')
            self.assertEqual(font['name'].getDebugName(1), 'Test Mono Shell Buddy')
            for cp in range(0xF5001, 0xF5007):
                name = font.getBestCmap()[cp]
                self.assertEqual(font['hmtx'][name][0], 600)
                cap = font['glyf'][name]
                self.assertEqual((cap.xMin, cap.xMax, cap.yMin, cap.yMax), (0, 600, -200, 900))
            self.assertTrue(all(record.toUnicode() != 'Test Mono' for record in font['name'].names if record.nameID in (1,16)))
            glyph = font['glyf']['shellbuddy.lizard']
            self.assertGreaterEqual(glyph.xMin, 0)
            self.assertLessEqual(glyph.xMax, 600)
            self.assertGreaterEqual(glyph.yMin, -200)
            self.assertLessEqual(glyph.yMax, 900)
            with self.assertRaises(ValueError): patcher.patch(source, source)
            with self.assertRaises(ValueError): patcher.patch(source, output)
            with self.assertRaises(ValueError): patcher.patch(output, Path(directory)/'again.ttf')

    def test_cap_only_slot_collision_rejects_without_writing(self):
        from fontTools.ttLib.tables._c_m_a_p import CmapSubtable
        with tempfile.TemporaryDirectory() as directory:
            source, output = Path(directory)/'source.ttf', Path(directory)/'patched.ttf'
            fixture(source)
            font = TTFont(source)
            table = CmapSubtable.newSubtable(12)
            table.platformID, table.platEncID, table.language = 3, 10, 0
            table.cmap = dict(font.getBestCmap())
            table.cmap[0xF5004] = 'M'
            font['cmap'].tables.append(table)
            font.save(source)
            original = source.read_bytes()
            with self.assertRaises(ValueError): patcher.patch(source, output)
            self.assertFalse(output.exists())
            self.assertEqual(source.read_bytes(), original)

    def test_asset_build_is_reproducible(self):
        spec = importlib.util.spec_from_file_location('build_icon_font', ROOT/'tools/build_icon_font.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        font = ROOT/'fonts/ShellBuddyIcons.ttf'
        original = hashlib.sha256(font.read_bytes()).digest()
        module.build()
        self.assertEqual(hashlib.sha256(font.read_bytes()).digest(), original)


if __name__ == '__main__':
    unittest.main(verbosity=2)
