"""Execute the bridge on synthetic scalar/vector TEX programs, without a GPU.

NVN2_BRIDGE_SOURCE selects the external Eglantine source. NVN2_BRIDGE_TEST_TMP
selects scratch on the game drive. The overlay-only checks need neither.
"""
import os
import hashlib
import json
from pathlib import Path
import struct
import shutil
import subprocess
import sys
import tempfile
import unittest

TOOLS = Path(__file__).resolve().parents[1] / "tools"
sys.path.insert(0, str(TOOLS))
from build_nvn2_ampere_bridge import texture_overlay


def tex(*, scalar=True, dimension=2, ra=6, rb=11, rd=0, rd2=2,
        mask=7, lod=0, predicate=7, handle=12, offset=False, depth=False):
    fields = [(12, predicate), (16, rd), (24, ra), (32, rb), (40, handle),
              (54, 2), (60, int(scalar)), (61, dimension), (64, rd2),
              (72, mask), (76, int(offset)), (78, int(depth)), (81, 7), (87, lod)]
    word = 0xb60
    for shift, value in fields:
        word |= value << shift
    return word.to_bytes(16, "little")


class OverlayTests(unittest.TestCase):
    def test_only_layout_decision_changes(self):
        for original in ("count <= 4 ? (count + 1) / 2 : 4", "coordinates"):
            source = "unrelated prefix\nconst auto general_tex = [&]() -> bool {\n" + \
                     f"const u32 in_a = {original};\nconst auto value = untouched;\nunrelated suffix"
            result = texture_overlay(source)
            self.assertTrue(result.startswith("unrelated prefix\n"))
            self.assertTrue(result.endswith("const auto value = untouched;\nunrelated suffix"))
            self.assertIn("Nvn2TexSourceACount(insn.Bits(60, 1) != 0, coordinates, count)", result)

    def test_unknown_dependency_fails_closed(self):
        with self.assertRaises(ValueError):
            texture_overlay("const auto general_tex = [&]() -> bool { const u32 in_a = 42; const auto value =")


@unittest.skipUnless(os.environ.get("NVN2_BRIDGE_SOURCE"), "set NVN2_BRIDGE_SOURCE for executable decoder tests")
class DecoderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(dir=os.environ.get("NVN2_BRIDGE_TEST_TMP"))
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.scratch = Path(cls.temporary.name)
        cls.binary = cls.scratch / "bridge output with spaces"
        compiler = cls.scratch / "compiler with spaces" / "clang++"
        compiler.parent.mkdir()
        compiler.symlink_to(shutil.which("clang++"))
        run = subprocess.run([str(TOOLS / "build_nvn2_ampere_bridge.sh"),
                              os.environ["NVN2_BRIDGE_SOURCE"], str(cls.binary)],
                             capture_output=True, text=True,
                             env={**os.environ, "CXX": str(compiler)})
        if run.returncode:
            raise RuntimeError(f"bridge build exited {run.returncode}:\n{run.stdout}\n{run.stderr}")

    def test_provenance_and_depfile_with_spaces(self):
        manifest = json.loads(self.binary.with_name(self.binary.name + ".build.json").read_text())
        self.assertEqual(manifest["binary_sha256"], hashlib.sha256(self.binary.read_bytes()).hexdigest())
        self.assertIn("compiler with spaces", manifest["command"][0])
        self.assertGreaterEqual(len(manifest["inputs_sha256"]), 7)
        for name, sha in manifest["inputs_sha256"].items():
            self.assertEqual(hashlib.sha256(Path(name).read_bytes()).hexdigest(), sha, name)

    def lower(self, instruction, success=True):
        source, output = self.scratch / "input.code", self.scratch / "output.bin"
        # An unconditional entry EXIT terminates the bounded synthetic program.
        exit_word = 0x94d | (7 << 12) | (7 << 87)
        source.write_bytes(instruction + exit_word.to_bytes(16, "little"))
        run = subprocess.run([str(self.binary), "compute", str(source), str(output)],
                             capture_output=True, text=True)
        self.assertEqual(run.returncode == 0, success, run.stderr)
        if not success:
            self.assertIn("native texture mode", run.stderr)
            return []
        return [word[0] for i, word in enumerate(struct.iter_unpack("<Q", output.read_bytes())) if i % 4]

    def check_sample(self, instruction, coordinates, *, meta=None, destinations=(0, 1, 2), predicate=7):
        # Track register identity through emitted MOVs; snapshot all texture
        # sources before injecting results to catch overlapping input/output GPRs.
        regs = {r: r for r in range(256)}
        samples = 0
        for word in self.lower(instruction):
            if word >> 52 == 0x5c9:
                self.assertEqual((word >> 16) & 15, predicate)
                regs[word & 255] = regs[(word >> 20) & 255]
            elif word >> 59 == 0x18:  # general Maxwell TEX
                self.assertEqual((word >> 16) & 15, predicate)
                ra, rb = (word >> 8) & 255, (word >> 20) & 255
                self.assertEqual([regs[ra + i] for i in range(len(coordinates))], coordinates)
                if meta is not None:
                    self.assertEqual([regs[rb + i] for i in range(len(meta))], meta)
                rd = word & 255
                for i in range(len(destinations)):
                    regs[rd + i] = 1000 + i
                samples += 1
            elif word >> 60 == 0xd:  # scalar Maxwell TEXS, 2D fast path
                self.assertEqual((word >> 16) & 15, predicate)
                self.assertEqual([regs[(word >> 8) & 255], regs[(word >> 20) & 255]], coordinates)
                d0, d1 = word & 255, (word >> 28) & 255
                for i in range(len(destinations)):
                    regs[d0 + i if i < 2 else d1 + i - 2] = 1000 + i
                samples += 1
        self.assertEqual(samples, 1)
        self.assertEqual([regs[r] for r in destinations], list(range(1000, 1000 + len(destinations))))

    def test_scalar_3d_uses_split_third_coordinate(self):
        self.check_sample(tex(), [6, 7, 11])

    def test_vector_3d_keeps_contiguous_coordinates(self):
        self.check_sample(tex(scalar=False), [6, 7, 8])

    def test_scalar_two_sources_and_three_split_results(self):
        self.check_sample(tex(dimension=1, ra=4, rb=5, rd=4, rd2=11), [4, 5], destinations=(4, 5, 11))

    def test_scalar_four_results_preserve_overlapping_sources(self):
        self.check_sample(tex(dimension=1, ra=6, rb=7, mask=15), [6, 7], destinations=(0, 1, 2, 3))

    def test_scalar_single_result(self):
        self.check_sample(tex(dimension=1, ra=6, rb=7, rd=8, rd2=255, mask=1), [6, 7], destinations=(8,))

    def test_predicate_and_split_odd_result_destination(self):
        self.check_sample(tex(rd=8, rd2=13, predicate=0), [6, 7, 11], destinations=(8, 9, 13), predicate=0)

    def test_scalar_lod_four_operands_split_two_two(self):
        self.check_sample(tex(lod=3), [6, 7, 11], meta=[12])

    def test_vector_lod_does_not_consume_rb_as_coordinate(self):
        self.check_sample(tex(scalar=False, lod=3), [6, 7, 8], meta=[11])

    def test_array_scalar_and_vector(self):
        self.check_sample(tex(dimension=5, lod=3), [6, 7, 11], meta=[12])
        self.check_sample(tex(dimension=5, lod=3, scalar=False), [6, 7, 8], meta=[11])

    def test_zero_register_coordinate(self):
        self.check_sample(tex(rb=255), [6, 7, 255])

    def test_scalar_more_than_four_operands_rejected(self):
        self.lower(tex(lod=3, offset=True), success=False)


if __name__ == "__main__":
    unittest.main()
