#!/usr/bin/env python3
"""Build the optional GPL bridge with a guarded, non-mutating dependency overlay.

Eglantine f6d03bc's general TEX lowerer always splits Ra/Rb. A later diagnostic
binary instead always used contiguous coordinates. Neither handles both forms.
Keep the rest of the supplied dependency intact and replace only that decision.
The output's .build.json records the compiler, inputs and binary hashes.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile


LOWER = Path("shader_recompiler/frontend/ampere/lower_to_maxwell.h")


def texture_overlay(source: str) -> str:
    """Fail closed if the expected upstream TEX block has changed."""
    start = source.index("const auto general_tex = [&]() -> bool {")
    end = source.index("const auto value =", start)
    block = source[start:end]
    pattern = r"const u32 in_a = (?:count <= 4 \? \(count \+ 1\) / 2 : 4|coordinates);"
    replacement = (
        "const int decoded_in_a = ::Nvn2TexSourceACount(insn.Bits(60, 1) != 0, coordinates, count);\n"
        "                if (decoded_in_a < 0) return false;\n"
        "                const u32 in_a = static_cast<u32>(decoded_in_a);"
    )
    patched, count = re.subn(pattern, lambda _: replacement, block)
    if count != 1:
        raise ValueError("unrecognized general TEX source layout; review dependency before building")
    return source[:start] + patched + source[end:]


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("eglantine_source", type=Path)
    parser.add_argument("output", nargs="?", type=Path, default=Path("nvn2_ampere_bridge"))
    args = parser.parse_args()
    root = args.eglantine_source.resolve()
    output = args.output.resolve()
    here = Path(__file__).resolve().parent
    header = root / "src" / LOWER
    try:
        overlay = texture_overlay(header.read_text())
    except (OSError, ValueError) as error:
        parser.exit(2, f"cannot prepare Eglantine TEX overlay: {error}\n")
    # Large scratch and the compiler output stay beside the requested binary.
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="bridge-build-", dir=output.parent) as temporary:
        scratch = Path(temporary)
        patched = scratch / LOWER
        patched.parent.mkdir(parents=True)
        patched.write_text(overlay)
        binary, depfile = scratch / "bridge", scratch / "dependencies.d"
        compiler = os.environ.get("CXX", "clang++")  # one executable path, including spaces
        command = [compiler, "-std=c++20", "-O2", "-I", str(scratch), "-I", str(root / "src"),
                   "-MMD", "-MF", str(depfile), str(here / "nvn2_ampere_bridge.cpp"), "-o", str(binary)]
        subprocess.run(command, check=True)
        dependencies = shlex.split(depfile.read_text().replace("\\\n", " ").split(":", 1)[1])
        inputs = {str(Path(p).resolve()): digest(Path(p)) for p in dependencies if Path(p) != patched}
        for p in (header, Path(__file__), here / "build_nvn2_ampere_bridge.sh"):
            inputs[str(p.resolve())] = digest(p)
        revision = subprocess.run(["git", "-C", str(root), "rev-parse", "HEAD"],
                                  capture_output=True, text=True)
        manifest = {
            "dependency_root": str(root),
            "dependency_revision": revision.stdout.strip() if revision.returncode == 0 else None,
            "compiler": subprocess.check_output([compiler, "--version"], text=True).strip(),
            "command": [v.replace(str(scratch), "<build-overlay>") for v in command],
            "inputs_sha256": inputs,
            "patched_lower_sha256": hashlib.sha256(overlay.encode()).hexdigest(),
            "binary_sha256": digest(binary),
            "tex_source_layout": "SCR-balanced-at-most-four; otherwise coordinates/metadata",
        }
        binary.replace(output)
        output.with_name(output.name + ".build.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"built {output}; provenance: {output.name}.build.json")


if __name__ == "__main__":
    main()
