"""dmsh_build.py's Mac compile runs the tools xcrun names with the SDK xcrun sets, without going through xcrun each time: the library must be byte-identical to the
xcrun form (MAC_METAL, which MAC_RECORD names and the compile cache keys on). Needs Xcode's Metal toolchain; skipped without it."""
import ast
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

TOOLS = Path(__file__).resolve().parents[2] / 'gfx/tools'
MSL = '''#include <metal_stdlib>
using namespace metal;
struct V { float4 p [[position]]; float2 uv; };
fragment float4 fs(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant float4 *c [[buffer(0)]]) {
    float4 r = 0; for (int i = 0; i < 8; i++) r += t.sample(s, in.uv + c[i].xy) * c[i].z; return r;
}
kernel void k(device float *o [[buffer(0)]], uint i [[thread_position_in_grid]]) { o[i] = precise::sqrt(float(i)) * 0.5f; }
'''


def metal_toolchain():
    if not shutil.which('xcrun'): return False
    return subprocess.run(['xcrun', '-sdk', 'macosx', 'metal', '--version'], capture_output=True).returncode == 0


@unittest.skipUnless(metal_toolchain(), 'no Metal toolchain (xcodebuild -downloadComponent MetalToolchain)')
class MacCompile(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, self.tmp)
        tree = ast.parse((TOOLS / 'dmsh_build.py').read_text())
        keep = []
        for n in tree.body:   # MAC_METAL, the tool cache and the two functions, as the build defines them
            if isinstance(n, ast.FunctionDef) and n.name in ('mac_tools', 'mac_compile'): keep.append(n)
            elif isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id in ('MAC_METAL', '_MAC_TOOLS') for t in n.targets): keep.append(n)
        self.ns = dict(os=os, subprocess=subprocess)
        exec(compile(ast.Module(body=keep, type_ignores=[]), 'dmsh_build.py', 'exec'), self.ns)

    def test_byte_identical_to_the_xcrun_form(self):
        msl = self.tmp / 's.metal'; msl.write_text(MSL)
        self.ns['mac_compile'](str(msl), str(self.tmp / 'd.air'), str(self.tmp / 'd.metallib'))
        subprocess.run([*self.ns['MAC_METAL'], str(msl), '-o', str(self.tmp / 'x.air')], check=True)
        subprocess.run(['xcrun', '-sdk', 'macosx', 'metallib', str(self.tmp / 'x.air'), '-o', str(self.tmp / 'x.metallib')], check=True)
        self.assertEqual((self.tmp / 'd.air').read_bytes(), (self.tmp / 'x.air').read_bytes(), 'the AIR differs from the xcrun form')
        self.assertEqual((self.tmp / 'd.metallib').read_bytes(), (self.tmp / 'x.metallib').read_bytes(), 'the library differs from the xcrun form')

    def test_the_flags_are_the_records(self):   # the direct compile passes exactly MAC_METAL's flags after the tool
        self.assertEqual(self.ns['MAC_METAL'][:4], ['xcrun', '-sdk', 'macosx', 'metal'])
        src = (TOOLS / 'dmsh_build.py').read_text()
        self.assertIn('[metal, *MAC_METAL[4:], msl', src)

    def test_a_compile_error_still_fails(self):
        bad = self.tmp / 'bad.metal'; bad.write_text('#include <metal_stdlib>\nfragment float4 f() { return undefined_thing; }\n')
        with self.assertRaises(subprocess.CalledProcessError):
            self.ns['mac_compile'](str(bad), str(self.tmp / 'b.air'), str(self.tmp / 'b.metallib'))


if __name__ == '__main__':
    unittest.main()
