import pathlib
import sys
import unittest


TOOLS = pathlib.Path(__file__).resolve().parents[1] / "tools"
sys.path.insert(0, str(TOOLS))

import cb_extent  # noqa: E402
import dmsh_abi as abi  # noqa: E402


class CompactBindingTests(unittest.TestCase):
    def test_null_register_is_conservatively_ignored(self):
        source = "constant uint* cp_c0; device uint* cp_s0;"
        bindings = [
            {"kind": abi.KIND_CBUF, "msl_name": "cp_c0", "reg": None},
            {"kind": abi.KIND_SBUF, "msl_name": "cp_s0", "reg": None},
        ]
        self.assertEqual(cb_extent.extents(source, bindings), {})
        self.assertEqual(cb_extent.unwritten(source, bindings), [])


if __name__ == "__main__":
    unittest.main()
