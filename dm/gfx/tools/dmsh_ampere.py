#!/usr/bin/env python3
"""Switch 2 (NVN2) shaders: what the build reads of their control section. The code itself is Ampere machine code, which the translator decodes and emits
natively (dmsh_xlate job arch sm86: Ryujinx.Graphics.Shader's Decoders/DecoderAmpere.cs and Instructions/InstEmitAmpere*.cs).

An NVN2 control section has version 0xc9 (NVN's have version 1 and are 0x880 bytes); its length at +0x30 in BNSH files (0 elsewhere), the register count at +0x4c,
compute's thread group at +0x58. +0x38 is the length of the instructions (the 0x80-byte SPH version 4 of the graphics stages included), +0x40 that rounded up to
0x100, +0x44 the code area's: between the last two lies the shader's c1 constant segment (0x100 bytes in vertex shaders, none in pixel shaders), as NVN's
+0x700 / +0x704 delimit it."""
import struct

CTL_MAGIC, CTL_VERSION = 0x98761234, 0xc9


def is_nvn2(ctl):
    """An NVN2 control section: magic, version 0xc9"""
    return len(ctl) >= 0x48 and struct.unpack_from('<II', ctl) == (CTL_MAGIC, CTL_VERSION)


def code_len(ctl):   # the code area
    return struct.unpack_from('<I', ctl, 0x44)[0]


def inst_len(ctl):   # the instructions (SPH included)
    return struct.unpack_from('<I', ctl, 0x38)[0]


def c1_segment(ctl, code):   # the c1 constant segment at the end of the code area
    a, e = struct.unpack_from('<II', ctl, 0x40)
    return code[a:e] if a <= e <= len(code) else b''


def compact_segments(ctl, code):
    """Instruction and c1 segments of a compact 201.7/201.11 code area.

    +0x38 is the exact instruction length (including a graphics SPH), +0x40
    rounds it to 0x100, and +0x44 ends the code area after an optional 0x100
    c1 jump-table segment. Treating the whole area as instructions both decodes
    c1 data as code and leaves BRX without the table which names its targets.
    """
    if len(ctl) < 0x48:
        raise ValueError('compact NVN2 control section is truncated')
    inst = struct.unpack_from('<I', ctl, 0x38)[0]
    rounded = struct.unpack_from('<I', ctl, 0x40)[0]
    area = struct.unpack_from('<I', ctl, 0x44)[0]
    if not (0 < inst <= rounded <= area == len(code) and
            rounded == (inst + 0xff) & ~0xff and area - rounded in (0, 0x100)):
        raise ValueError(f'compact NVN2 code layout is invalid ({inst:#x}, {rounded:#x}, {area:#x}, actual {len(code):#x})')
    return code[:inst], code[rounded:area]


def compute_layout(ctl):
    """Native compute c0 tables, counted by this shader's control section.

    The native Ampere emitter maps this same layout to canonical NVN tables
    (InstEmitAmpere.AMapC0). The optional lowering bridge preserves native
    offsets, so its reflection and runtime must retain the layout instead.
    """
    if len(ctl) < 0xd8 or not is_nvn2(ctl):
        raise ValueError('NVN2 compute control section is truncated or invalid')
    u, s, t, separate, samplers, images = ctl[0xb1:0xb7]
    push, size = ctl[0xa9] * 4, struct.unpack_from('<H', ctl, 0xba)[0]
    if separate or samplers or any(ctl[0xb7:0xb9]):
        raise ValueError('NVN2 compute separate descriptor tables are not measured')
    ub = 0x10 + ((push + 15) & ~15)
    sb, tb = ub + 16 * u, ub + 16 * (u + s)
    ib = tb + 8 * t
    if u > 16 or s > 16 or t > 128 or images > 8 or push > 256 or ib + 8 * images > size:
        raise ValueError('NVN2 compute resource counts exceed their driver buffer')
    return dict(push_bytes=push, size=size, ubo_base=ub, ubo_count=u,
                ssbo_base=sb, ssbo_count=s, tex_base=tb, tex_count=t,
                img_base=ib, img_count=images)
