"""Keep current and compact NVN2 shader-key layouts disjoint."""

import hashlib
import os
from pathlib import Path
import struct
import sys
import unittest


ROOT = Path(__file__).resolve().parents[2]
os.environ.setdefault("DM_GAME", "0100000000010000")
sys.path.insert(0, str(ROOT / "gfx/tools"))

import shader_split as split  # noqa: E402


class Nvn2ShaderKeyTests(unittest.TestCase):
    @staticmethod
    def compact_control(stage=5, code_size=16):
        control = bytearray(0xD8)
        control[:4] = split.CTL_MAGIC
        struct.pack_into("<2I", control, 4, 201, 11)
        struct.pack_into("<I", control, 0x30, len(control))
        struct.pack_into("<I", control, 0x40, code_size)
        struct.pack_into("<I", control, 0x54, stage << 16)
        control[0x58] = 32
        return control

    def test_compact_201_11_hashes_complete_control(self):
        code = bytes(range(256))
        control = bytearray(0xD8)
        control[:4] = split.CTL_MAGIC
        struct.pack_into("<2I", control, 4, 201, 11)
        struct.pack_into("<I", control, 0x30, len(control))
        struct.pack_into("<I", control, 0x40, len(code))
        struct.pack_into("<I", control, 0x54, 6 << 16)
        control[0x58] = 32

        self.assertIsNotNone(split.compact_control(control))
        self.assertFalse(split.nvn2_ctl(control))
        expected = hashlib.sha256(bytes(control) + code).hexdigest()[:16]
        self.assertEqual(split.skey(control, code), expected)

    def test_current_nvn2_normalizes_48_byte_control(self):
        code = bytes(range(64))
        control = bytearray(0xD8)
        control[:4] = split.CTL_MAGIC
        struct.pack_into("<2I", control, 4, 201, 12)
        struct.pack_into("<I", control, 0x30, len(control))
        struct.pack_into("<I", control, 0x44, len(code))

        self.assertTrue(split.nvn2_ctl(control))
        normalized = bytearray(control[:split.NVN2_KEY_CTL])
        normalized[0x30:0x34] = bytes(4)
        expected = hashlib.sha256(bytes(normalized) + code).hexdigest()[:16]
        self.assertEqual(split.skey(control, code), expected)

    def test_compact_bahs_and_ndsr_records_are_read(self):
        control = self.compact_control()
        bahs = bytearray(0x300)
        struct.pack_into("<II", bahs, 0x18, 0x100, 0x200)
        struct.pack_into("<IIIi", bahs, 0, 0, 0, len(control), 0x40)
        bahs[0x40:0x40 + len(control)] = control
        self.assertEqual([(stage, len(code)) for _, stage, _, code in split.bahs_shaders(bytes(bahs), "fixture")], [("cs", 16)])

        ndsr = bytearray(0x300)
        ndsr[:4] = b"NDSR"
        struct.pack_into("<4I", ndsr, 0x10, 0x40, len(control) << 4, 0x200, 0)
        ndsr[0x40:0x40 + len(control)] = control
        self.assertEqual([(stage, len(code)) for _, stage, _, code in split.ndsr_shaders(bytes(ndsr), "fixture")], [("cs", 16)])


if __name__ == "__main__":
    unittest.main()
