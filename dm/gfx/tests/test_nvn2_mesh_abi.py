"""Tests for the neutral NVN2 task/mesh ISBE ABI plan."""

from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import nvn2_isbe
import nvn2_mesh_abi


def instruction(opcode: int, **fields: int) -> nvn2_isbe.IsbeInstruction:
    raw = opcode
    for name, (offset, count) in {
        "predicate": (12, 4),
        "destination": (16, 8),
        "offset_register": (24, 8),
        "data_register": (32, 8),
        "immediate_offset": (40, 16),
        "memory_type": (74, 2),
        "access_type": (76, 2),
        "skew": (78, 1),
        "output": (79, 1),
    }.items():
        raw |= fields.get(name, 0) << offset
    decoded = nvn2_isbe.decode_instruction(raw.to_bytes(16, "little"))
    assert decoded is not None
    return decoded


class MeshAbiTests(unittest.TestCase):
    def test_classifies_supported_pipeline(self):
        task = [
            instruction(
                nvn2_isbe.ISBERD,
                predicate=7,
                destination=4,
                offset_register=255,
                memory_type=2,
                access_type=3,
            ),
            instruction(
                nvn2_isbe.ISBEWR,
                offset_register=5,
                data_register=4,
                immediate_offset=0x10,
                memory_type=2,
                access_type=3,
                output=1,
            ),
            instruction(
                nvn2_isbe.ISBEWR,
                predicate=7,
                offset_register=255,
                data_register=2,
                immediate_offset=16,
                memory_type=2,
                access_type=3,
                output=1,
            ),
        ]
        mesh = [
            instruction(
                nvn2_isbe.ISBERD,
                predicate=7,
                destination=0,
                offset_register=255,
                memory_type=2,
                access_type=3,
            ),
            instruction(
                nvn2_isbe.ISBEWR,
                predicate=7,
                offset_register=21,
                data_register=40,
                memory_type=2,
                access_type=3,
                skew=1,
                output=1,
            ),
            instruction(
                nvn2_isbe.ISBEWR,
                predicate=7,
                offset_register=10,
                data_register=15,
                immediate_offset=4,
                output=1,
            ),
            instruction(
                nvn2_isbe.ISBEWR,
                predicate=7,
                offset_register=255,
                data_register=0,
                immediate_offset=3,
                memory_type=2,
                output=1,
            ),
        ]
        plan = nvn2_mesh_abi.build_plan(task, mesh)
        self.assertEqual(plan.version, 3)
        self.assertEqual([operation.space for operation in plan.task], ["task_group_index", "task_payload", "mesh_dispatch_count"])
        self.assertEqual(
            [operation.space for operation in plan.mesh],
            ["mesh_group_index", "mesh_attribute", "mesh_index", "mesh_primitive_count"],
        )
        self.assertTrue(plan.mesh[1].skew)
        self.assertEqual(plan.mesh[2].byte_width, 1)

    def test_only_reserved_rz_zero_read_is_mesh_group_index(self):
        group_index = instruction(
            nvn2_isbe.ISBERD,
            offset_register=255,
            memory_type=2,
            access_type=3,
        )
        payload = instruction(
            nvn2_isbe.ISBERD,
            offset_register=7,
            immediate_offset=16,
            memory_type=2,
            access_type=3,
        )
        self.assertEqual(nvn2_mesh_abi._operation("mesh", group_index).space, "mesh_group_index")
        self.assertEqual(nvn2_mesh_abi._operation("task", group_index).space, "task_group_index")
        self.assertEqual(nvn2_mesh_abi._operation("mesh", payload).space, "task_payload")
        with self.assertRaisesRegex(ValueError, "reserved workgroup index"):
            nvn2_mesh_abi._operation("task", payload)

    def test_rejects_unknown_task_domain(self):
        task = [
            instruction(
                nvn2_isbe.ISBEWR,
                offset_register=255,
                data_register=2,
                immediate_offset=5,
                memory_type=2,
                output=1,
            )
        ]
        with self.assertRaisesRegex(ValueError, "unsupported domain"):
            nvn2_mesh_abi.build_plan(task, [])

    def test_requires_raster_output_contract(self):
        task = [
            instruction(
                nvn2_isbe.ISBEWR,
                offset_register=255,
                data_register=2,
                immediate_offset=4,
                memory_type=2,
                access_type=3,
                output=1,
            )
        ]
        with self.assertRaisesRegex(ValueError, "primitive count"):
            nvn2_mesh_abi.build_plan(task, [])


if __name__ == "__main__":
    unittest.main()
