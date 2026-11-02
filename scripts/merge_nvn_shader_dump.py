#!/usr/bin/env python3
"""Merge a bounded runtime shader dump into an existing provisional package.

The profile's explicit shader_abi keeps classic NVN and compact NVN2 captures
from ever sharing a shader map.  Generated facts are refreshed for new compact
compute/task/mesh controls, then shader_facts_manual.tsv is overlaid exactly as
the full shader splitter does.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import struct
import sys


STAGE_PACKAGE = {
    'vs': 'vs_other.bin', 'hs': 'hs_other.bin', 'ds': 'ds_other.bin',
    'gs': 'gs_other.bin', 'ps': 'ps_other.bin', 'cs': 'cs_other.bin',
    'ts': 'ts_other.bin', 'ms': 'ms_other.bin',
}


def data_lines(path):
    return [line for line in path.read_text(encoding='utf-8').splitlines()
            if line.strip() and not line.startswith('#')]


def read_facts(path):
    out = {}
    for line in data_lines(path):
        key, raw = line.split('\t', 1)
        if key in out: raise ValueError(f'duplicate fact {key} in {path}')
        out[key] = json.loads(raw)
    return out


def write_facts(path, header, facts):
    rows = [header.rstrip('\n')]
    rows += [key + '\t' + json.dumps(facts[key], sort_keys=True, separators=(',', ':'))
             for key in sorted(facts)]
    path.write_text('\n'.join(rows) + '\n', encoding='utf-8')


def fact_header(path):
    comments = [line for line in path.read_text(encoding='utf-8').splitlines()
                if line.startswith('#')]
    return '\n'.join(comments) or '# Shader translation facts.'


def parse_override(value):
    match = re.fullmatch(r'([0-9a-fA-F]{16})=(\d+)', value)
    if not match: raise argparse.ArgumentTypeError('expected 16-hex-key=bytes')
    size = int(match.group(2))
    if size <= 0 or size & 15: raise argparse.ArgumentTypeError('bytes must be positive and 16-byte aligned')
    return match.group(1).lower(), size


def record(ctl, code):
    out = bytearray(b'BTCDBTCD' + bytes(0x30))
    struct.pack_into('<2I', out, 0x28, len(ctl), len(code))
    out += code + ctl
    if out.count(b'BTCDBTCD') != 1:
        raise ValueError('record separator occurs inside a shader')
    return bytes(out)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package-root', required=True, type=Path,
                        help='existing root containing package/ and generated shader tables')
    parser.add_argument('--profile-dir', required=True, type=Path,
                        help='existing profile directory containing game.tsv')
    parser.add_argument('--dump-dir', required=True, type=Path,
                        help='runtime dump containing matching .ctl and .code files')
    parser.add_argument('--output-package-root', required=True, type=Path)
    parser.add_argument('--output-profile-dir', required=True, type=Path)
    parser.add_argument('--shared-host', action='append', default=[], type=parse_override,
                        metavar='KEY=BYTES', help='verified host-safe shared-memory override')
    args = parser.parse_args()

    roots = (args.package_root.resolve(), args.profile_dir.resolve(), args.dump_dir.resolve())
    for path in roots:
        if not path.is_dir(): parser.error(f'not a directory: {path}')
    out_pkg, out_profile = args.output_package_root.resolve(), args.output_profile_dir.resolve()
    if out_pkg.exists() or out_profile.exists(): parser.error('output paths must not already exist')

    os.environ['DM_GAME'] = str(roots[1])
    tools = Path(__file__).resolve().parents[1] / 'dm/gfx/tools'
    games = Path(__file__).resolve().parents[1] / 'dm/games'
    sys.path[:0] = [str(tools), str(games)]
    import game
    import shader_split as split

    profile = game.load(str(roots[1]))
    shader_abi = profile.get('shader_abi', '')
    if shader_abi not in ('nvn1', 'nvn2'):
        parser.error('profile must explicitly declare shader_abi nvn1 or nvn2')

    shutil.copytree(roots[0], out_pkg)
    shutil.copytree(roots[1], out_profile)
    map_path = out_pkg / 'shader_map.tsv'
    profile_map = out_profile / 'shader_map.tsv'
    if not map_path.is_file() or not (out_pkg / 'package').is_dir():
        parser.error('package root needs shader_map.tsv and package/')

    original = map_path.read_text(encoding='utf-8').rstrip('\n')
    map_rows, by_key, next_index = [], {}, {}
    for line in data_lines(map_path):
        if line.startswith('package\t'): continue
        cols = line.split('\t')
        if len(cols) != 5 or not cols[1].isdigit(): raise ValueError(f'invalid shader map row: {line}')
        package, index, stage, key, source = cols
        if key in by_key: raise ValueError(f'duplicate shader key {key}')
        by_key[key] = (package, stage, source)
        next_index[package] = max(next_index.get(package, 0), int(index) + 1)

    controls = sorted(roots[2].glob('*.ctl'))
    if not controls: parser.error('dump directory has no .ctl files')
    added = []
    generated = read_facts(out_pkg / 'shader_facts.tsv')
    for ctl_path in controls:
        code_path = ctl_path.with_suffix('.code')
        if not code_path.is_file(): raise ValueError(f'missing {code_path.name}')
        ctl, code = ctl_path.read_bytes(), code_path.read_bytes()
        key = split.skey(ctl, code)
        if ctl_path.stem.lower() != key:
            raise ValueError(f'{ctl_path.name} hashes to {key}')
        compact = split.compact_control(ctl) is not None
        if compact != (shader_abi == 'nvn2'):
            kind = 'compact NVN2' if compact else 'classic NVN'
            raise ValueError(f'{key} is {kind}, incompatible with profile shader_abi {shader_abi}')
        stage = split.glslc_stage(ctl, code)
        if not stage: raise ValueError(f'cannot determine stage of {key}')
        if key in by_key: continue
        package = STAGE_PACKAGE[stage]
        index = next_index.get(package, 0)
        package_path = out_pkg / 'package' / package
        with package_path.open('ab') as stream: stream.write(record(ctl, code))
        source = f'/nvn_dump/{roots[2].name}/{key}.ctl#NVNDUMP'
        map_rows.append(f'{package}\t{index}\t{split.STAGE_NAME[stage]}\t{key}\t{source}')
        by_key[key] = (package, split.STAGE_NAME[stage], source)
        next_index[package] = index + 1
        if stage in ('cs', 'ts', 'ms'):
            facts = split.compact_nvn2_facts(ctl, stage)
            if facts is None: raise ValueError(f'{key} has no valid compact {stage} facts')
            generated[key] = facts
        added.append((key, stage))

    manual_path = out_profile / 'shader_facts_manual.tsv'
    manual_header = fact_header(manual_path) if manual_path.exists() else '# Verified host-specific shader facts.'
    manual = read_facts(manual_path) if manual_path.exists() else {}
    for key, size in args.shared_host:
        if key not in by_key or by_key[key][1] != 'compute':
            raise ValueError(f'shared-memory override {key} is not a mapped compute shader')
        manual[key] = {**manual.get(key, {}), 'shared_host': size}
    write_facts(manual_path, manual_header, manual)
    for key, values in manual.items(): generated[key] = {**generated.get(key, {}), **values}

    merged_map = original + ('\n' + '\n'.join(map_rows) if map_rows else '') + '\n'
    map_path.write_text(merged_map, encoding='utf-8')
    profile_map.write_text(merged_map, encoding='utf-8')
    header = fact_header(out_pkg / 'shader_facts.tsv')
    write_facts(out_pkg / 'shader_facts.tsv', header, generated)
    write_facts(out_profile / 'shader_facts.tsv', header, generated)
    print(json.dumps({'shader_abi': shader_abi, 'added': len(added),
                      'keys': [key for key, _ in added], 'manual_overrides': len(args.shared_host)}, indent=2))


if __name__ == '__main__':
    try: main()
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as exc:
        raise SystemExit(f'[RED] {exc}')
