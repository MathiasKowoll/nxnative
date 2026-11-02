"""Conservative uniform/storage extent extraction from translated Metal shaders."""
import sys
from pathlib import Path
import unittest

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'dm/gfx/tools'))
import cb_extent   # noqa: E402
import dmsh_abi as abi   # noqa: E402


class UnknownBindingSlot(unittest.TestCase):
    def test_null_slots_are_ignored_without_losing_known_uniforms(self):
        source = """
constant uint4* known [[id(0)]];
constant uint4* unknown [[id(1)]];
uint4 a = (*spvDescriptorSet0.known)._m0[1];
uint4 b = (*spvDescriptorSet0.unknown)._m0[2];
"""
        bindings = [
            {'kind': abi.KIND_CBUF, 'reg': 3, 'msl_name': 'known'},
            {'kind': abi.KIND_CBUF, 'reg': None, 'msl_name': 'unknown'},
        ]
        self.assertEqual(cb_extent.extents(source, bindings), {3: 32})

    def test_null_storage_slot_is_not_reported_read_only(self):
        source = """
uint a = (*spvDescriptorSet0.known)._m0[0];
uint b = (*spvDescriptorSet0.unknown)._m0[0];
"""
        bindings = [
            {'kind': abi.KIND_SBUF, 'reg': 4, 'msl_name': 'known'},
            {'kind': abi.KIND_SBUF, 'reg': None, 'msl_name': 'unknown'},
        ]
        self.assertEqual(cb_extent.unwritten(source, bindings), [4])


if __name__ == '__main__': unittest.main()
