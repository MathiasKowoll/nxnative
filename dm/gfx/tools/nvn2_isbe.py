#!/usr/bin/env python3
"""Decode NVN2 Ampere ISBE instructions for task/mesh bring-up.

This is an inventory and validation tool, not a shader translator. Field positions
follow Mesa NAK's MIT-licensed SM70 encoder. Keeping the decoder independent of the
GPL Eglantine experiment lets NXNative inspect captured programs without importing
that project's implementation.
"""

from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
import json
from pathlib import Path
from typing import Final


ISBERD: Final = 0x923
ISBEWR: Final = 0x927
MEMORY_TYPES: Final = ("u8", "u16", "b32", "reserved")
ACCESS_TYPES: Final = ("map", "patch", "primitive", "attribute")


@dataclass(frozen=True)
class IsbeInstruction:
    offset: int
    opcode: str
    predicate: int
    destination_register: int | None
    offset_register: int
    data_register: int | None
    immediate_offset: int
    memory_type: str
    access_type: str
    skew: bool
    output: bool


def _bits(raw: int, offset: int, count: int) -> int:
    return raw >> offset & ((1 << count) - 1)


def decode_instruction(instruction: bytes, offset: int = 0) -> IsbeInstruction | None:
    """Decode one 16-byte SM70+ instruction, or return None for another opcode."""
    if len(instruction) != 16:
        raise ValueError(f"an Ampere instruction is 16 bytes, got {len(instruction)}")
    raw = int.from_bytes(instruction, "little")
    opcode = _bits(raw, 0, 12)
    if opcode not in (ISBERD, ISBEWR):
        return None
    write = opcode == ISBEWR
    memory_type = _bits(raw, 74, 2)
    access_type = _bits(raw, 76, 2)
    return IsbeInstruction(
        offset=offset,
        opcode="ISBEWR" if write else "ISBERD",
        predicate=_bits(raw, 12, 4),
        destination_register=None if write else _bits(raw, 16, 8),
        offset_register=_bits(raw, 24, 8),
        data_register=_bits(raw, 32, 8) if write else None,
        immediate_offset=_bits(raw, 40, 16),
        memory_type=MEMORY_TYPES[memory_type],
        access_type=ACCESS_TYPES[access_type],
        skew=bool(_bits(raw, 78, 1)),
        output=bool(_bits(raw, 79, 1)),
    )


def scan_code(code: bytes, header_size: int = 0x80) -> list[IsbeInstruction]:
    """Return every ISBE operation after a bounded, aligned native header."""
    if header_size < 0 or header_size > len(code) or header_size % 16:
        raise ValueError(f"invalid native shader header size {header_size:#x}")
    if (len(code) - header_size) % 16:
        raise ValueError(
            f"native instruction span is not 16-byte aligned: {len(code) - header_size:#x}"
        )
    result: list[IsbeInstruction] = []
    for offset in range(header_size, len(code), 16):
        decoded = decode_instruction(code[offset : offset + 16], offset)
        if decoded is not None:
            result.append(decoded)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("code", type=Path, help="captured compact shader .code file")
    parser.add_argument("--header-size", type=lambda value: int(value, 0), default=0x80)
    parser.add_argument("--json", action="store_true", help="emit machine-readable JSON")
    args = parser.parse_args()
    instructions = scan_code(args.code.read_bytes(), args.header_size)
    if args.json:
        print(json.dumps([asdict(instruction) for instruction in instructions], indent=2))
    else:
        for instruction in instructions:
            fields = asdict(instruction)
            print(
                f"{fields['offset']:#06x} {fields['opcode']} pred={fields['predicate']:#x} "
                f"dst={fields['destination_register']} offset=r{fields['offset_register']}+"
                f"{fields['immediate_offset']:#x} data={fields['data_register']} "
                f"{fields['access_type']}.{fields['memory_type']} "
                f"skew={int(fields['skew'])} output={int(fields['output'])}"
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
