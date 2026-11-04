"""Native compute resources must keep their declared slots, not discovery order."""
import ast
import os
from pathlib import Path
import re
import struct
import sys
import tempfile
import unittest

TOOLS = Path(__file__).resolve().parents[1] / 'tools'
sys.path.insert(0, str(TOOLS))
import dmsh_abi as abi
import dmsh_ampere
import dmsh_geometry


def control(push_words=0):
    c = bytearray(0xd8)
    struct.pack_into('<III', c, 0, 0x98761234, 201, 11)
    c[0xa9] = push_words
    c[0xb1:0xb7] = bytes([7, 6, 6, 0, 0, 2])
    struct.pack_into('<H', c, 0xba, 0x120 + ((push_words * 4 + 15) & ~15))
    return c


def reflector():
    tree = ast.parse((TOOLS / 'dmsh_build.py').read_text())
    ns = dict(re=re, abi=abi, dmsh_geometry=dmsh_geometry, SSBO={'cs': abi.C0_SSBO_CS})
    names = {'reflect', 'decode_nvn2_direct'}
    exec(compile(ast.Module(body=[n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name in names], type_ignores=[]), 'dmsh_build.py', 'exec'), ns)
    return ns['reflect']


class ComputeLayout(unittest.TestCase):
    def compact_job(self, stage, stage_index, c1=b''):
        tree = ast.parse((TOOLS / 'dmsh_build.py').read_text())
        ns = dict(os=os, sys=sys, struct=struct, dmsh_ampere=dmsh_ampere, FACTS={})
        names = {'job_for', 'compact_nvn2_stage', 'compact_nvn2_control_size'}
        exec(compile(ast.Module(body=[n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name in names], type_ignores=[]), 'dmsh_build.py', 'exec'), ns)
        ctl = control(3)
        struct.pack_into('<I', ctl, 0x30, len(ctl))
        struct.pack_into('<I', ctl, 0x54, stage_index << 16)
        code = bytes.fromhex('4d790000000000000000800300ea0f00')
        rounded = (len(code) + 0xff) & ~0xff
        struct.pack_into('<I', ctl, 0x38, len(code))
        struct.pack_into('<I', ctl, 0x3c, 0xc)  # unrelated compact-control field
        struct.pack_into('<II', ctl, 0x40, rounded, rounded + len(c1))
        code_area = code + bytes(rounded - len(code)) + c1
        with tempfile.TemporaryDirectory() as work:
            job, returned_c1 = ns['job_for']('synthetic', stage + '_test', bytes(0x38) + code_area + ctl, work)
            return job, returned_c1, Path(job['code']).read_bytes(), code

    def test_compact_compute_uses_native_frontend_without_optional_bridge(self):
        job, c1, written, code = self.compact_job('cs', 5)
        self.assertEqual(job['arch'], 'sm86')
        self.assertEqual(job['nvn2_cs'], [7, 6, 6, 0x130, 12])
        self.assertEqual(written, code)
        self.assertNotIn('nvn2_layout', job)  # canonical tables after native translation
        self.assertEqual(c1, b'')

    def test_compact_graphics_uses_native_frontend_and_keeps_c1(self):
        for stage, stage_index, c1 in (('vs', 0, bytes(range(256))), ('ps', 1, b'')):
            with self.subTest(stage=stage):
                job, returned_c1, written, code = self.compact_job(stage, stage_index, c1)
                self.assertEqual(job['arch'], 'sm86')
                self.assertEqual(job['stage'], stage)
                self.assertEqual(written, code)
                self.assertEqual(bytes.fromhex(job['c1']), c1)
                self.assertEqual(returned_c1, c1)
                self.assertNotIn('nvn2', job)

    def test_push_alignment_and_declared_tables(self):
        l = dmsh_ampere.compute_layout(control(3))
        self.assertEqual((l['push_bytes'], l['ubo_base'], l['ssbo_base'], l['tex_base'], l['img_base']), (12, 0x20, 0x90, 0xf0, 0x120))

    def test_rejects_truncated_or_unmeasured_layouts(self):
        for kind in ('truncated', 'undersized', 'separate'):
            c = control()
            if kind == 'truncated': c = c[:0xb4]
            elif kind == 'undersized': struct.pack_into('<H', c, 0xba, 0x80)
            else: c[0xb4] = 1
            with self.subTest(kind=kind), self.assertRaises(ValueError): dmsh_ampere.compute_layout(c)

    def test_storage_and_uniform_pointers_survive_compiler_reordering(self):
        reflect = reflector()
        for offsets in ((0xb0, 0xd0, 0x60, 0x70), (0x70, 0xb0, 0x60, 0xd0)):
            declarations = '\n'.join(f'device Data* cp_s{i} [[id({i})]];' for i in range(4))
            msl = 'struct spvDescriptorSetBuffer0 {' + declarations + '};'
            rows = [dict(binding=10+i, cb_slot=0, cb_offset=o//4, flags=int(o >= 0x80)) for i, o in enumerate(offsets)]
            result = reflect('synthetic', 'cs', msl, dict(sbufs=list(reversed(rows)), nvn2_compute=True, nvn2_layout=dmsh_ampere.compute_layout(control())))
            expected = {0xb0: (abi.KIND_SBUF, 3), 0xd0: (abi.KIND_SBUF, 5), 0x60: (abi.KIND_UBO_PTR, 5), 0x70: (abi.KIND_UBO_PTR, 6)}
            self.assertEqual([(b['kind'], b['reg']) for b in result], [expected[o] for o in offsets])

    def test_texture_and_image_offsets_use_separate_tables(self):
        msl = '''struct spvDescriptorSetBuffer0 {
            texture2d<float> cp_t_tcb_38 [[id(0)]];
            sampler cp_t_tcb_38Smplr [[id(1)]];
            texture2d<float> cp_i_tcb_46 [[id(2)]];
        };'''
        result = reflector()('synthetic', 'cs', msl, dict(sbufs=[], nvn2_compute=True, nvn2_texture_buffer=0, nvn2_layout=dmsh_ampere.compute_layout(control())))
        self.assertEqual([(b['kind'], b['reg']) for b in result], [(abi.KIND_TEX, 0), (abi.KIND_SAMP_TEX, 0), (abi.KIND_IMG, 1)])


if __name__ == '__main__': unittest.main()
