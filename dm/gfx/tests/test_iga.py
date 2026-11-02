"""Crash's IGA/IGZ resources: bounded archive reads and NVN records."""
import os
from pathlib import Path
import struct
import sys
import tempfile
import unittest

os.environ.setdefault('DM_GAME', '010015100B514000')
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import shader_split


def igz_shader(stage='vs', control_len=0x880, code_off=0xae8):
    code = bytearray(0x100); code[:4] = shader_split.GFX_MAGIC
    struct.pack_into('<I', code, 0x30, (shader_split.STAGES.index(stage) + 1) << 10 | 1)
    ctl = bytearray(control_len); ctl[:4] = shader_split.CTL_MAGIC
    struct.pack_into('<I', ctl, 0x20, code_off)
    struct.pack_into('<I', ctl, 0x704, len(code))
    c = 0x100; data = bytearray(c + 0xae8 + len(code)); data[:4] = shader_split.IGZ
    data[c:c + len(ctl)] = ctl; data[c + code_off:c + code_off + len(code)] = code
    return bytes(data)


def iga_archive(member, member_name='shaders/test.igz'):
    name = member_name.encode() + b'\0'; files, align = 1, 0x800
    entry_off, names_off, data_off = 0x3c, 0x1800, 0x800
    data = bytearray(names_off + 4 + len(name)); data[:4] = shader_split.IGA
    struct.pack_into('<I', data, 4, 12); struct.pack_into('<I', data, 0xc, files); struct.pack_into('<I', data, 0x10, align)
    struct.pack_into('<I', data, 0x28, names_off)
    struct.pack_into('<IIII', data, entry_off, data_off, len(member), 0, 0xffffffff)
    struct.pack_into('<I', data, names_off, 4); data[names_off + 4:names_off + 4 + len(name)] = name
    if len(data) < data_off + len(member): data.extend(bytes(data_off + len(member) - len(data)))
    data[data_off:data_off + len(member)] = member
    return bytes(data)


def compact_shader(stage, runtime_size=False):
    ctl = bytearray(0xd8); code = bytes(0x100)
    struct.pack_into('<3I', ctl, 0, 0x98761234, 201, 11)
    struct.pack_into('<I', ctl, 0x30, 0 if runtime_size else len(ctl))
    struct.pack_into('<I', ctl, 0x40, len(code))
    struct.pack_into('<I', ctl, 0x54, stage << 16)
    if runtime_size: struct.pack_into('<I', ctl, 0xc4, len(ctl))
    return bytes(ctl), code


def compact_bnsh_with_address_table():
    data = bytearray(0x500); data[:8] = b'BNSH\0\0\0\0'; data[0x60:0x64] = b'grsc'
    struct.pack_into('<IQ', data, 0x7c, 1, 0xc0)
    struct.pack_into('<Q', data, 0xc0 + 0x10, 0x100)
    struct.pack_into('<Q', data, 0x100 + 8, 0x180)
    struct.pack_into('<QQII', data, 0x180 + 8, 0x200, 0x300, 0x200, 0xd8)
    ctl, code = compact_shader(0)
    data[0x200:0x200 + len(ctl)] = ctl
    data[0x300:0x300 + len(code)] = code
    data[0x400:0x410] = bytes(range(16))
    return bytes(data)


class IgaTests(unittest.TestCase):
    def test_igz_record_uses_offset_after_compiler_text(self):
        found = shader_split.igz_shaders(igz_shader(), '/shader')
        self.assertEqual(len(found), 1)
        self.assertEqual(found[0][1], 'vs')
        self.assertEqual(found[0][2][:4], shader_split.CTL_MAGIC)
        self.assertEqual(found[0][3][:4], shader_split.GFX_MAGIC)

    def test_iga_job_reads_one_raw_member(self):
        member = igz_shader('ps'); archive = iga_archive(member)
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / 'shaders.pak'; path.write_bytes(archive)
            entries = shader_split.iga_entries(str(path))
            self.assertEqual([name for name, _ in entries], ['shaders/test.igz'])
            self.assertEqual(shader_split.iga_read(str(path), entries[0][1]), member)
            result = shader_split.scan_file_in((str(path), 'shaders.pak', ('IGA', entries[0][0], entries[0][1])))
            self.assertEqual(len(result[1]), 1)

    def test_iga_jobs_use_magic_not_archive_extension_or_exact_shader_path(self):
        member = igz_shader('ps'); archive = iga_archive(member, 'assets/Render/ShaderProgram/test.igz')
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / 'bundle.bin'; path.write_bytes(archive)
            jobs, archives = shader_split.iga_jobs([(str(path), 'assets/content.bundle')])
            self.assertEqual(len(jobs), 1)
            self.assertIn(str(path), archives)
            self.assertEqual(jobs[0][2][1], 'assets/Render/ShaderProgram/test.igz')

    def test_iga_jobs_scan_a_small_hintless_igz_archive(self):
        member = igz_shader('ps'); archive = iga_archive(member, 'assets/effect/test.igz')
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / 'bundle.dat'; path.write_bytes(archive)
            jobs, _ = shader_split.iga_jobs([(str(path), 'assets/content.bundle')])
            self.assertEqual(len(jobs), 1)

    def test_igz_record_uses_short_control_length_for_ctr(self):
        found = shader_split.igz_shaders(igz_shader('ps', 0x850, 0x850), '/shader')
        self.assertEqual(len(found), 1)
        self.assertEqual(len(found[0][2]), 0x850)
        self.assertEqual(found[0][3][:4], shader_split.GFX_MAGIC)

    def test_nvn_dump_reads_host_control_and_code_files(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td); member = igz_shader('ps')
            c = member.find(shader_split.CTL_MAGIC); ctl = member[c:c + 0x880]
            code_off = struct.unpack_from('<I', ctl, 0x20)[0]; ncode = struct.unpack_from('<I', ctl, 0x704)[0]
            (path / '0123456789abcdef.ctl').write_bytes(ctl)
            (path / '0123456789abcdef.code').write_bytes(member[c + code_off:c + code_off + ncode])
            found = shader_split.nvn_dump_shaders(str(path), '/dump')
            self.assertEqual(len(found), 1)
            self.assertEqual(found[0][1], 'ps')

    def test_nvn2_dump_keeps_supplementary_address_table(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td); ctl, code = compact_shader(5)
            (path / '0123456789abcdef.ctl').write_bytes(ctl)
            (path / '0123456789abcdef.code').write_bytes(code)
            (path / '0123456789abcdef.extra').write_bytes(bytes(range(16)))
            found = shader_split.nvn_dump_shaders(str(path), '/dump')
            self.assertEqual(len(found), 1)
            self.assertEqual(found[0][2][0xd8:], bytes(range(16)))

    def test_nvn2_dump_uses_compact_stage_and_exact_control_size(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td)
            for key, stage, runtime in (('1111111111111111', 6, False), ('2222222222222222', 7, True)):
                ctl, code = compact_shader(stage, runtime)
                (path / f'{key}.ctl').write_bytes(ctl)
                (path / f'{key}.code').write_bytes(code)
            found = shader_split.nvn_dump_shaders(str(path), '/dump')
            self.assertEqual([record[1] for record in found], ['ts', 'ms'])
            self.assertEqual([shader_split.ctl_len(record[2]) for record in found], [0xd8, 0xd8])
            self.assertEqual([shader_split.STAGE_NAME[record[1]] for record in found], ['task', 'mesh'])

    def test_nvn2_facts_keep_ambiguous_control_words_raw(self):
        task, _ = compact_shader(6)
        task = bytearray(task); task[0x58:0x64] = bytes.fromhex('200000010000000000000000')
        mesh, _ = compact_shader(7)
        mesh = bytearray(mesh); mesh[0x58:0x64] = bytes.fromhex('200000010000010380004000')
        self.assertEqual(shader_split.compact_nvn2_facts(task, 'ts'), {
            'local': [32, 1, 1],
            'nvn2_control_words': [0x01000020, 0, 0],
        })
        self.assertEqual(shader_split.compact_nvn2_facts(mesh, 'ms'), {
            'local': [32, 1, 1],
            'nvn2_control_words': [0x01000020, 0x03010000, 0x00400080],
        })
        mesh[0x58] = 0
        self.assertIsNone(shader_split.compact_nvn2_facts(mesh, 'ms'))
        self.assertIsNone(shader_split.compact_nvn2_facts(task, 'ms'))

    def test_nvn2_compute_facts_read_dimensions_and_shared_memory(self):
        compute, _ = compact_shader(5)
        compute = bytearray(compute)
        struct.pack_into('<4I', compute, 0x58, 4, 4, 4, 0x901)
        self.assertEqual(shader_split.compact_nvn2_facts(compute, 'cs'), {
            'local': [4, 4, 4],
            'shared': 0x910,
        })
        struct.pack_into('<3I', compute, 0x58, 1024, 2, 1)
        self.assertIsNone(shader_split.compact_nvn2_facts(compute, 'cs'))

    def test_nvn2_bnsh_excludes_supplementary_address_table(self):
        found = shader_split.bnsh_shaders(compact_bnsh_with_address_table(), 0, '/main')
        self.assertEqual(len(found), 1)
        self.assertEqual(found[0][1], 'vs')
        self.assertEqual(len(found[0][3]), 0x100)
        self.assertEqual(found[0][3], bytes(0x100))
        self.assertEqual(found[0][2][0xd8:0xe8], bytes(range(16)))


if __name__ == '__main__':
    unittest.main()
