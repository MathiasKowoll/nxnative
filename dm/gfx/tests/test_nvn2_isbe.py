"""Tests for the bounded NVN2 ISBE instruction inventory."""

from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import nvn2_isbe


def instruction(opcode: int, **fields: int) -> bytes:
    raw = opcode
    for name, (offset, count) in {
        "predicate": (12, 4),
        "destination": (16, 8),
        "offset_register": (24, 8),
        "data_register": (32, 8),
        "immediate_offset": (40, 16),
        "memory_type": (74, 2),
        "access_type": (76, 2),
        "skew": (78, 1),
        "output": (79, 1),
    }.items():
        value = fields.get(name, 0)
        if value >= 1 << count:
            raise ValueError(name)
        raw |= value << offset
    return raw.to_bytes(16, "little")


class IsbeDecoderTests(unittest.TestCase):
    def test_decodes_write_fields(self):
        decoded = nvn2_isbe.decode_instruction(
            instruction(
                nvn2_isbe.ISBEWR,
                predicate=7,
                offset_register=4,
                data_register=9,
                immediate_offset=0x10,
                memory_type=2,
                access_type=3,
                skew=1,
                output=1,
            ),
            0x160,
        )
        self.assertEqual(decoded.opcode, "ISBEWR")
        self.assertEqual(decoded.offset, 0x160)
        self.assertIsNone(decoded.destination_register)
        self.assertEqual(decoded.offset_register, 4)
        self.assertEqual(decoded.data_register, 9)
        self.assertEqual(decoded.immediate_offset, 0x10)
        self.assertEqual(decoded.memory_type, "b32")
        self.assertEqual(decoded.access_type, "attribute")
        self.assertTrue(decoded.skew)
        self.assertTrue(decoded.output)

    def test_decodes_read_fields(self):
        decoded = nvn2_isbe.decode_instruction(
            instruction(
                nvn2_isbe.ISBERD,
                destination=12,
                offset_register=255,
                memory_type=0,
                access_type=0,
            )
        )
        self.assertEqual(decoded.opcode, "ISBERD")
        self.assertEqual(decoded.destination_register, 12)
        self.assertEqual(decoded.offset_register, 255)
        self.assertIsNone(decoded.data_register)
        self.assertEqual(decoded.memory_type, "u8")
        self.assertEqual(decoded.access_type, "map")

    def test_scan_is_bounded_and_skips_other_opcodes(self):
        code = bytes(0x80) + bytes(16) + instruction(nvn2_isbe.ISBEWR) + bytes(16)
        decoded = nvn2_isbe.scan_code(code)
        self.assertEqual(len(decoded), 1)
        self.assertEqual(decoded[0].offset, 0x90)
        with self.assertRaises(ValueError):
            nvn2_isbe.scan_code(code[:-1])
        with self.assertRaises(ValueError):
            nvn2_isbe.decode_instruction(bytes(15))


if __name__ == "__main__":
    unittest.main()
