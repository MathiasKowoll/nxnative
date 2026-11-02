"""A SIMD load between a switch bound and dispatch does not overwrite its GPR index."""
import ast
from pathlib import Path
import re
import struct
import sys
import unittest
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM

TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS))
from nso_asm import ADRP, ADDI, ADDR, BR


class SimdDispatch(unittest.TestCase):
    def run_dispatch(self, load):
        image = bytearray(0x5000)
        targets = [44, 48, 52, 56, 60, 64]
        for i, target in enumerate(targets): struct.pack_into('<i', image, 0x4000 + 4 * i, target - 24)
        words = [ADRP(17, 0, 0x4000), ADDI(17, 17, 0), 0x39401641, 0x7100143f,
                 0x54000108, load, 0x10000012, 0xb8a17a22, ADDR(18, 18, 2), 0x1e270100, BR(18)]
        words += [0xd65f03c0] * 6
        md = Cs(CS_ARCH_ARM64, CS_MODE_ARM); md.detail = True
        instructions = list(md.disasm(struct.pack('<' + 'I' * len(words), *words), 0))
        tree = ast.parse((TOOLS / 'patch_nso.py').read_text())
        scope = {'re': re, 'struct': struct, 'IMG': image}
        names = {'num', 'table_base', 'table_cands', 'jump_adr_offsets'}
        exec(compile(ast.Module(body=[n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name in names], type_ignores=[]), 'recognizers', 'exec'), scope)
        return scope['jump_adr_offsets'](instructions, 10), targets

    def test_simd_index_number_is_independent(self):
        actual, expected = self.run_dispatch(0xbd400e41)   # ldr s1, [x18, #12]
        self.assertEqual(actual, expected)

    def test_real_index_write_still_rejected(self):
        actual, _ = self.run_dispatch(0xb9400e41)          # ldr w1, [x18, #12]
        self.assertIsNone(actual)


if __name__ == '__main__': unittest.main()
