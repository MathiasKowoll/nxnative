"""The shared NSO loader (dm/tools/nso_segments.py), with a synthetic LZ4 module and no game data."""
from pathlib import Path
import struct
import sys
import unittest

TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS))
import lz4.block
import nso_segments


def synth_nso():
    text, ro, data, bss = b'NSOtext', b'rodat', b'data', 4
    ctext = lz4.block.compress(text, store_size=False)
    off_ro, off_data = 0x100 + len(ctext), 0x100 + len(ctext) + len(ro)
    h = bytearray(0x100)
    struct.pack_into('<4s', h, 0, b'NSO0')
    struct.pack_into('<I', h, 0xc, 1)       # text compressed, LZ4 (no ZBIC bit)
    for i, (fo, mo, sz) in enumerate([(0x100, 0, len(text)), (off_ro, len(text), len(ro)), (off_data, len(text) + len(ro), len(data))]):
        struct.pack_into('<III', h, 0x10 + i * 0x10, fo, mo, sz)
    struct.pack_into('<I', h, 0x3c, bss)
    struct.pack_into('<III', h, 0x60, len(ctext), len(ro), len(data))
    return bytes(h) + ctext + ro + data


class NsoSegments(unittest.TestCase):
    def test_lz4_nso_loads_segments_and_bss(self):
        img, flags, segs, bss, compressed = nso_segments.load(synth_nso())
        self.assertEqual(flags, 1)
        self.assertEqual(bss, 4)
        self.assertEqual([s[2] for s in segs], [7, 5, 4])
        self.assertEqual(compressed[1:], (5, 4))
        self.assertEqual(bytes(img[:7]), b'NSOtext')
        self.assertEqual(bytes(img[7:12]), b'rodat')
        self.assertEqual(bytes(img[12:16]), b'data')
        self.assertEqual(len(img), 20)
        self.assertEqual(bytes(img[16:]), b'\0' * 4)

    def test_rejects_a_file_that_is_not_an_nso(self):
        with self.assertRaises(ValueError):
            nso_segments.load(b'NRO0' + b'\0' * 0x100)


if __name__ == '__main__':
    unittest.main()
