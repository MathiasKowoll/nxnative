"""Execute translated Maxwell PRMT on Metal, with exact integer readback."""
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
TOOLS = ROOT / 'dm/gfx/tools'
TABLE = ROOT / 'dm/third_party/ryujinx/src/Ryujinx.Graphics.Shader/Decoders/InstTable.cs'


def opcode(emitter):
    pattern = re.search(r'Add\("([01x]{64})",[^\n]*InstEmit\.' + emitter + r'\s*,', TABLE.read_text())[1]
    return int(pattern.replace('x', '0'), 2) | (7 << 16)


def program(form, mode, selector):
    # A and C are data; B is the selector. All non-immediate operands are
    # uniform reads so the test also exercises dynamic (not constant-folded) IR.
    mov = lambda reg, word: opcode('MovC') | reg | (3 << 34) | (word << 20)
    instructions = [mov(0, 0), mov(1, 1), mov(2, 2)]
    prmt = opcode('Prmt' + form) | (mode << 48)  # dest = srcA = R0 (aliasing)
    if form == 'R': prmt |= (2 << 20) | (1 << 39)
    elif form == 'I': prmt |= (selector << 20) | (1 << 39)
    elif form == 'C': prmt |= (3 << 34) | (2 << 20) | (1 << 39)
    else: prmt |= (3 << 34) | (1 << 20) | (2 << 39)
    instructions += [prmt, opcode('Exit') | 15]
    header = bytearray(0x50)
    struct.pack_into('<I', header, 0, (5 << 10) | (3 << 5) | 2)
    struct.pack_into('<I', header, 0x48, 1)  # output R0 as target 0, component x
    for n, inst in enumerate(instructions):
        if n % 3 == 0: header += bytes(8)  # Maxwell scheduling word
        header += struct.pack('<Q', inst)
    return header


def expected(a, b, selector, mode):
    data = struct.pack('<II', a, b)
    s = selector & 3
    # PTX ISA prmt mode table, output bytes in little-endian order.
    indices = {
        1: [s, s+1, s+2, s+3],
        2: [s, (s-1) % 8, (s-2) % 8, (s-3) % 8],
        3: [s]*4,
        4: [[0,1,2,3], [1,1,2,3], [2,2,2,3], [3,3,3,3]][s],
        5: [[0,0,0,0], [0,1,1,1], [0,1,2,2], [0,1,2,3]][s],
        6: [0,1,0,1] if s % 2 == 0 else [2,3,2,3],
    }
    if mode: return int.from_bytes(bytes(data[i] for i in indices[mode]), 'little')
    result = []
    for i in range(4):
        nibble = (selector >> (4*i)) & 15
        value = data[nibble & 7]
        result.append((255 if value & 128 else 0) if nibble & 8 else value)
    return int.from_bytes(bytes(result), 'little')


@unittest.skipUnless(os.environ.get('DMSH_TEST_XLATE'), 'set DMSH_TEST_XLATE to the offline translator')
class PrmtCompiler(unittest.TestCase):
    def test_all_forms_modes_and_sign_replication(self):
        def run(args):
            r = subprocess.run([str(x) for x in args], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            return r.stdout
        with tempfile.TemporaryDirectory(prefix='prmt-') as td:
            work = Path(td); jobs = []; cases = []
            for mode in range(7):
                selectors = [0x5410, 0x3210, 0x7654, 0xfedc, 0xba98, 0x8f07, 0xffff] if mode == 0 else list(range(4))
                for form in ('R', 'I', 'C', 'Rc'):
                    for selector in selectors:
                        key = f'prmt_{form}_{mode}_{selector if form == "I" else 0}'
                        if not any(j['key'] == key for j in jobs):
                            code = work / (key + '.bin'); code.write_bytes(program(form, mode, selector))
                            jobs.append(dict(key=key, stage='ps', code=str(code), fout={'0':'uint'}, debug=True, reduced=True))
                        for a, b in ((0x89ab01ef, 0x237f80cd), (0x00ff7f80, 0xfe018100)):
                            cases.append(dict(key=key, values=[a,b,selector,0], expected=expected(a,b,selector,mode)))
            jobfile = work/'jobs.json'; jobfile.write_text(json.dumps(jobs))
            run([os.environ['DMSH_TEST_XLATE'], jobfile, work])
            for job in jobs:
                key = job['key']
                res = json.loads((work/(key+'.res.json')).read_text())
                self.assertFalse(res.get('error'), res)
                self.assertFalse(any('not implemented' in n for n in res.get('notes', [])), res)
                msl = run([TOOLS/'spirv_cross_bin/spirv-cross', '--msl', '--msl-version', '20300', work/(key+'.spv')])
                msl += '\nvertex float4 test_vertex(uint v [[vertex_id]]) { return float4(v==1?3.0:-1.0,v==2?3.0:-1.0,0,1); }\n'
                (work/(key+'.metal')).write_text(msl)
            (work/'cases.json').write_text(json.dumps(cases))
            run(['clang','-fobjc-arc',Path(__file__).with_name('t_prmt.m'),'-framework','Foundation','-framework','Metal','-o',work/'test'])
            output = run([work/'test',work])
            self.assertIn(f'{len(cases)} exact integer results passed', output)
            print(output.strip())


if __name__ == '__main__': unittest.main()
