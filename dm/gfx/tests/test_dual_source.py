"""Dual-source variants preserve the original MRT entry and shader semantics."""
import ast
from pathlib import Path
import re
import unittest
import sys

tools = Path(__file__).resolve().parents[1] / 'tools'
sys.path.insert(0, str(tools))
import dmsh_fetch
ns = {'re': re}
tree = ast.parse((tools / 'dmsh_build.py').read_text())
exec(compile(ast.Module(body=[n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'fs_dual'], type_ignores=[]), '<fs_dual>', 'exec'), ns)

SRC = '''using namespace metal;
struct main0_out
{
    float4 m_0 [[color(0)]];
    float4 m_1 [[color(1)]];
};
[[early_fragment_tests]]
fragment main0_out main0()
{
    main0_out out = {};
    out.m_0 = float4(.125);
    out.m_1 = float4(.5);
    return out;
}
'''

class DualSourceTests(unittest.TestCase):
    def test_outputs_and_body(self):
        variant = ns['fs_dual'](SRC)
        self.assertIn('float4 m_1 [[color(0), index(1)]];', variant)
        self.assertIn('[[early_fragment_tests]]\nfragment main0_out_d main0_d()', variant)
        self.assertIn('out.m_1 = float4(.5);', variant)
        self.assertIn('main0_out_d out = {};', variant)

    def test_preserves_depth(self):
        variant = ns['fs_dual'](SRC.replace('};', '    float z [[depth(any)]];\n};', 1))
        self.assertIn('float z [[depth(any)]];', variant)

    def test_ineligible_outputs(self):
        for src in (SRC.replace('color(1)', 'color(2)'), SRC.replace('float4 m_1', 'uint4 m_1'), SRC.replace('color(1)', 'color(0), index(1)')):
            self.assertIsNone(ns['fs_dual'](src))

    def test_fetch_does_not_clone_dual_body(self):
        variant, meta = dmsh_fetch.variant(SRC + ns['fs_dual'](SRC), [], om_only_ok=True)
        self.assertIsNotNone(variant, meta)
        self.assertNotIn('main0_d', variant)
        self.assertNotIn('index(1)', variant)

if __name__ == '__main__': unittest.main()
