"""Frostbite .cas shader discovery: stored NVN records and Oodle-compressed blocks."""
import os
import struct
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'tools'))
import shader_split as split


def shader_bytes():
    code = bytearray(0x100)
    code[:4] = split.GFX_MAGIC
    struct.pack_into('<I', code, 0x30, 0x461)  # vertex, VTG
    ctl = bytearray(split.CTL_MAGIC + bytes(0x87c))
    struct.pack_into('<I', ctl, 0x20, 0x880)
    struct.pack_into('<I', ctl, 0x704, len(code))
    return bytes(code), bytes(ctl)


class FrostbiteShaders(unittest.TestCase):
    def test_stored_record(self):
        code, ctl = shader_bytes()
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / 'a.cas'; p.write_bytes(code + ctl)
            out = []; split.frostbite_shaders(str(p), 'a.cas', out)
        self.assertEqual(len(out), 1)
        self.assertEqual(out[0][1:], ('vs', ctl, code))

    def test_large_packages_are_split_with_overlap(self):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / 'a.cas'; p.write_bytes(bytes(25))
            with mock.patch.object(split, 'FROSTBITE_CHUNK', 10), mock.patch.object(split, 'FROSTBITE_OVERLAP', 2):
                jobs, taken = split.frostbite_jobs([(str(p), 'a.cas')])
        self.assertEqual(taken, {str(p)})
        self.assertEqual([j[2] for j in jobs], [('frostbite', 0, 12), ('frostbite', 8, 22), ('frostbite', 18, 25)])

    def test_oodle_block(self):
        raw, ctl = shader_bytes()
        record = raw + ctl
        payload = b'\x8c\x0c' + bytes(4)
        header = struct.pack('>IBBH', len(record), 0x19, 0x70, len(payload))
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / 'a.cas'; p.write_bytes(header + payload)
            out = []
            with mock.patch.object(split, 'oodle_maybe', return_value=record) as decode:
                split.frostbite_shaders(str(p), 'a.cas', out)
        decode.assert_called_once_with(payload, len(record))
        self.assertEqual(len(out), 1)
        self.assertEqual(out[0][1:], ('vs', ctl, raw))


if __name__ == '__main__':
    unittest.main()
