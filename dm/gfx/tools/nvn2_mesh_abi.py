#!/usr/bin/env python3
"""Build a neutral ISBE ABI plan for one NVN2 task/mesh shader pair.

The plan is intentionally independent of Metal and of the external Ampere
lowerer.  A later code-generation step can map every operation to object/mesh
payload access or to a compute scratch buffer without guessing its domain.
"""

from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
import json
from pathlib import Path
from typing import Final, Iterable

from nvn2_isbe import IsbeInstruction, scan_code


ABI_VERSION: Final = 3
WIDTHS: Final = {"u8": 1, "u16": 2, "b32": 4}


@dataclass(frozen=True)
class AbiOperation:
    shader: str
    space: str
    access: str
    instruction_offset: int
    offset_register: int
    immediate_offset: int
    data_register: int
    byte_width: int
    skew: bool
    predicate: int


@dataclass(frozen=True)
class MeshAbiPlan:
    version: int
    task: tuple[AbiOperation, ...]
    mesh: tuple[AbiOperation, ...]


def _operation(shader: str, instruction: IsbeInstruction) -> AbiOperation:
    try:
        width = WIDTHS[instruction.memory_type]
    except KeyError as error:
        raise ValueError(
            f"{shader} {instruction.opcode} at {instruction.offset:#x} uses "
            f"unsupported memory type {instruction.memory_type}"
        ) from error

    if shader == "task":
        if instruction.opcode == "ISBERD":
            if (
                not instruction.output
                and instruction.access_type == "attribute"
                and instruction.memory_type == "b32"
                and instruction.offset_register == 255
                and instruction.immediate_offset == 0
            ):
                space = "task_group_index"
            else:
                raise ValueError(
                    f"task ISBE read at {instruction.offset:#x} is not the reserved workgroup index"
                )
        elif instruction.opcode != "ISBEWR" or not instruction.output:
            raise ValueError(
                f"task ISBE at {instruction.offset:#x} is not an output write"
            )
        # Ampere encodes EmitMeshTasks through the output-attribute path too.
        # The reserved RZ + 4/8/12 words are dispatch dimensions; other
        # attribute writes are payload data.
        elif (
            instruction.access_type == "attribute"
            and instruction.memory_type == "b32"
            and instruction.offset_register == 255
            and instruction.immediate_offset in (4, 8, 12, 16)
        ):
            space = "mesh_dispatch_count"
        elif instruction.access_type == "attribute":
            space = "task_payload"
        else:
            raise ValueError(
                f"task ISBE write at {instruction.offset:#x} has unsupported domain "
                f"{instruction.access_type}.{instruction.memory_type}"
            )
    elif shader == "mesh":
        if instruction.opcode == "ISBERD":
            if instruction.output or instruction.access_type != "attribute":
                raise ValueError(
                    f"mesh ISBE read at {instruction.offset:#x} is not a payload read"
                )
            if (
                instruction.memory_type == "b32"
                and instruction.offset_register == 255
                and instruction.immediate_offset == 0
            ):
                space = "mesh_group_index"
            else:
                space = "task_payload"
        elif instruction.opcode == "ISBEWR" and instruction.output:
            if instruction.access_type == "attribute":
                space = "mesh_attribute"
            elif instruction.access_type == "map" and instruction.memory_type == "b32" and instruction.immediate_offset == 3:
                space = "mesh_primitive_count"
            elif instruction.access_type == "map" and instruction.memory_type == "u8" and instruction.immediate_offset >= 4:
                space = "mesh_index"
            else:
                raise ValueError(
                    f"mesh ISBE write at {instruction.offset:#x} has unsupported domain "
                    f"{instruction.access_type}.{instruction.memory_type}"
                )
        else:
            raise ValueError(
                f"mesh ISBE at {instruction.offset:#x} has unsupported direction"
            )
    else:
        raise ValueError(f"unknown shader role {shader}")

    data_register = (
        instruction.data_register
        if instruction.opcode == "ISBEWR"
        else instruction.destination_register
    )
    assert data_register is not None
    return AbiOperation(
        shader=shader,
        space=space,
        access="write" if instruction.opcode == "ISBEWR" else "read",
        instruction_offset=instruction.offset,
        offset_register=instruction.offset_register,
        immediate_offset=instruction.immediate_offset,
        data_register=data_register,
        byte_width=width,
        # The shader has already calculated the packed SKEW address.  SKEW
        # selects that ISBE layout; it is not another lane-id stride.
        skew=instruction.skew,
        predicate=instruction.predicate,
    )


def build_plan(
    task_instructions: Iterable[IsbeInstruction],
    mesh_instructions: Iterable[IsbeInstruction],
) -> MeshAbiPlan:
    task = tuple(_operation("task", instruction) for instruction in task_instructions)
    mesh = tuple(_operation("mesh", instruction) for instruction in mesh_instructions)
    if not any(operation.space == "mesh_dispatch_count" for operation in task):
        raise ValueError("task shader does not emit a mesh dispatch count")
    if not any(operation.space == "mesh_primitive_count" for operation in mesh):
        raise ValueError("mesh shader does not emit a primitive count")
    if not any(operation.space == "mesh_index" for operation in mesh):
        raise ValueError("mesh shader does not emit primitive indices")
    return MeshAbiPlan(version=ABI_VERSION, task=task, mesh=mesh)


def _summary(plan: MeshAbiPlan) -> dict[str, object]:
    operations = (*plan.task, *plan.mesh)
    counts: dict[str, int] = {}
    for operation in operations:
        counts[operation.space] = counts.get(operation.space, 0) + 1
    return {
        "version": plan.version,
        "counts": counts,
        "task": [asdict(operation) for operation in plan.task],
        "mesh": [asdict(operation) for operation in plan.mesh],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("task", type=Path, help="captured task shader .code file")
    parser.add_argument("mesh", type=Path, help="captured mesh shader .code file")
    parser.add_argument("--header-size", type=lambda value: int(value, 0), default=0x80)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    plan = build_plan(
        scan_code(args.task.read_bytes(), args.header_size),
        scan_code(args.mesh.read_bytes(), args.header_size),
    )
    summary = _summary(plan)
    if args.json:
        print(json.dumps(summary, indent=2))
    else:
        print(f"NVN2 mesh ABI v{plan.version}")
        for space, count in summary["counts"].items():
            print(f"  {space}: {count}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
