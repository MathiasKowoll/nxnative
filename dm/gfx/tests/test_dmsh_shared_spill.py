"""Oversized NVN shared memory is preserved through device scratch on Metal."""

import ast
from pathlib import Path
import re
import unittest


TOOLS = Path(__file__).resolve().parents[1] / "tools"
SOURCE = TOOLS / "dmsh_build.py"
tree = ast.parse(SOURCE.read_text())
node = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "spill_large_shared")
scope = {"re": re}
exec(compile(ast.Module(body=[node], type_ignores=[]), str(SOURCE), "exec"), scope)
spill_large_shared = scope["spill_large_shared"]


class SharedSpillTests(unittest.TestCase):
    SOURCE = """kernel void main0(constant uint& args [[buffer(0)]], uint3 group [[threadgroup_position_in_grid]])
{
    threadgroup spvUnsafeArray<uint, 12288> shared;
    shared[group.x] = args;
    threadgroup_barrier(mem_flags::mem_threadgroup);
}
"""

    def test_preserves_48_kib_in_device_memory_per_workgroup(self):
        got, size = spill_large_shared(self.SOURCE, 49152)
        self.assertEqual(size, 49152)
        self.assertIn("uint3 dm_groups [[threadgroups_per_grid]]", got)
        self.assertIn("device uint *dm_shared [[buffer(1)]]", got)
        self.assertIn("device uint *shared = dm_shared + ulong(", got)
        self.assertIn("* 12288ul;", got)
        self.assertIn("threadgroup_barrier(mem_flags::mem_device)", got)
        self.assertNotIn("threadgroup spvUnsafeArray<uint, 12288> shared", got)

    def test_32_kib_stays_in_threadgroup_memory(self):
        got, size = spill_large_shared(self.SOURCE, 32768)
        self.assertEqual((got, size), (self.SOURCE, 0))

    def test_does_not_overwrite_an_existing_buffer_slot(self):
        with self.assertRaisesRegex(ValueError, "buffer\\(1\\) is already used"):
            spill_large_shared(self.SOURCE.replace("buffer(0)", "buffer(1)"), 49152)

    def test_runtime_reflection_and_binding_are_connected(self):
        header = (TOOLS.parent / "nvn/nvn_refl.h").read_text()
        reflection = (TOOLS.parent / "nvn/nvn_refl.m").read_text()
        runtime = (TOOLS.parent / "nvn/nvn_mtl.m").read_text()
        self.assertIn("uint32_t shared_device", header)
        self.assertIn('j[@"shared_device_bytes"]', reflection)
        self.assertIn("arena_alloc(bytes, &scratch)", runtime)
        self.assertIn("scratch.gpuAddress + off, 1", runtime)


if __name__ == "__main__":
    unittest.main()
