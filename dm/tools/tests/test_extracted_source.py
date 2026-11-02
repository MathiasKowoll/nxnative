"""Loose-dump identity must come from bounded NPDM metadata, never the folder name."""
from pathlib import Path
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from extracted_source import inspect


class ExtractedSources(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.base = self.root / 'base'; self.exefs = self.base / 'exefs'
        self.exefs.mkdir(parents=True); (self.base / 'romfs').mkdir()
        for name in ('main', 'sdk'): (self.exefs / name).write_bytes(b'NSO0')
        self.npdm = bytearray(0xa0); self.npdm[:4] = b'META'; self.npdm[0xc] = 0x37
        struct.pack_into('<II', self.npdm, 0x70, 0x80, 0x20)
        self.npdm[0x80:0x84] = b'ACI0'
        struct.pack_into('<Q', self.npdm, 0x90, 0x0400C3F00006E000)
        self.save()

    def save(self): (self.exefs / 'main.npdm').write_bytes(self.npdm)

    def test_root_base_exefs_and_main_resolve_to_same_source(self):
        for folder in (self.root, self.base, self.exefs, self.exefs / 'main'):
            source = inspect(folder)
            self.assertEqual(source.title_id, '0400C3F00006E000')
            self.assertTrue(source.switch2)
            self.assertEqual(source.romfs, (self.base / 'romfs').resolve())

    def test_switch_one_is_not_misclassified(self):
        struct.pack_into('<Q', self.npdm, 0x90, 0x0100152000022000); self.save()
        self.assertFalse(inspect(self.root).switch2)

    def test_truncated_access_control_is_rejected(self):
        struct.pack_into('<II', self.npdm, 0x70, 0x80, 0x100); self.save()
        with self.assertRaisesRegex(ValueError, 'ACI0 range'): inspect(self.root)

    def test_embedded_fake_magic_does_not_replace_header_offsets(self):
        struct.pack_into('<II', self.npdm, 0x70, 0, 0); self.save()
        with self.assertRaisesRegex(ValueError, 'ACI0 range'): inspect(self.root)

    def test_32bit_is_rejected_before_build(self):
        self.npdm[0xc] = 0x36; self.save()
        with self.assertRaisesRegex(ValueError, '32-bit ARM'): inspect(self.root)

    def test_incomplete_pair_is_rejected(self):
        (self.base / 'romfs').rmdir()
        with self.assertRaisesRegex(ValueError, 'ExeFS/RomFS pair'): inspect(self.root)

    def test_ambiguous_dump_is_rejected(self):
        (self.root / 'exefs').mkdir(); (self.root / 'romfs').mkdir()
        with self.assertRaisesRegex(ValueError, 'exactly one'): inspect(self.root)


if __name__ == '__main__': unittest.main()
