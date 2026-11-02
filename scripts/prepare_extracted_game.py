#!/usr/bin/env python3
"""Prepare a loose game dump for native bring-up, with one worker by default.

The source is never moved or rewritten. Generated profiles and rewritten modules
stay beside the game. This command does not claim Switch 2 runtime compatibility.
"""
import argparse
import json
import os
from pathlib import Path
import sys

REPO = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(REPO / 'dm/tools'), str(REPO / 'dm/games'), str(REPO / 'scripts')]
from extracted_source import inspect
from build_ipa_from_nsp import BuildError


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('--name', required=True)
    parser.add_argument('--work-dir', type=Path)
    parser.add_argument('--prepare-code', action='store_true', help='rewrite code modules and compile a diagnostic host')
    parser.add_argument('--workers', type=int, choices=(1, 2), default=1)
    parser.add_argument('--refresh-inventory', action='store_true', help='refresh cached RomFS metadata after modifying game assets')
    args = parser.parse_args()
    source = inspect(args.source)
    if any(c in args.name for c in '\t\n\r'):
        raise ValueError('game name must fit on one line without tabs')
    game_folder = source.root.parent if source.root.name.casefold() == 'base' else source.root
    work = (args.work_dir or game_folder / f'{source.title_id}_build').resolve()
    if work == source.root or work.is_relative_to(source.exefs) or work.is_relative_to(source.romfs):
        raise ValueError('work folder must be outside the source files')
    work.mkdir(parents=True, exist_ok=True)
    identity_file = work / 'source.json'
    if identity_file.exists():
        previous = json.loads(identity_file.read_text())
        if previous.get('exefs') != str(source.exefs) or previous.get('romfs') != str(source.romfs):
            raise ValueError('work directory belongs to another extracted source; choose a separate work directory')
    logs = work / 'logs'; logs.mkdir(exist_ok=True)
    import profile_guess as pg
    import build_ipa_from_nsp as builder
    import game
    builder.pg = pg
    # The existing facts reader accepts an inventory. Generate it sequentially,
    # retaining only 32 bytes per asset and never copying entire game resources.
    manifest = work / 'romfs_manifest.tsv'
    if not manifest.exists() or args.refresh_inventory:
        partial = manifest.with_suffix('.partial')
        count = 0
        with partial.open('w') as out:
            for directory, dirs, files in os.walk(source.romfs):
                dirs[:] = sorted(d for d in dirs if not d.startswith('.'))
                for name in sorted(files):
                    if name.startswith('.'): continue
                    path = Path(directory) / name
                    if any(c in str(path.relative_to(source.romfs)) for c in '\t\n\r'):
                        raise ValueError(f'unsupported inventory filename: {path}')
                    with path.open('rb') as stream: head = stream.read(32)
                    out.write(f'/{path.relative_to(source.romfs)}\t{path.stat().st_size}\t{head.hex()}\n')
                    count += 1
                    if count % 20000 == 0: print(f'inventory: {count} files', flush=True)
        partial.replace(manifest)
    facts = pg.facts_of(source.exefs, manifest)
    profile_root = work / 'profile'
    existing = profile_root / source.title_id / 'game.tsv'
    if existing.is_file():
        registered = game.Game(existing.parent).builds().get('v0', {})
        if any(registered.get(name) != data['bid'] for name, data in facts['mods'].items() if name != 'rtld'):
            raise ValueError('source modules changed; use a separate work directory for this game version')
    builder.write_profile(profile_root / source.title_id, source.program_id, {
        'F': facts, 'name': args.name, 'survey': str(work / 'source.json'),
        'version': 'v0', 'display': 'unknown',
    })
    # v0 is only a local build-slot identifier; the source's display version is unknown.
    modules = {name: {k: data[k] for k in ('bid', 'sizes', 'bss')} for name, data in facts['mods'].items()}
    report = {'title_id': source.title_id, 'source': str(source.root), 'exefs': str(source.exefs),
              'romfs': str(source.romfs), 'switch2': source.switch2, 'display_version': None,
              'sdk_versions': sorted(facts['sdkver']), 'modules': modules,
              'runtime_status': 'unvalidated', 'workers': args.workers}
    (work / 'source.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2), flush=True)
    if not args.prepare_code: return
    env = dict(os.environ, DM_GAME=source.title_id, DM_GAMES_DIR=str(profile_root),
               DM_ROOT=str(work), WORK=str(work / 'tmp'), J=str(args.workers),
               DM_REWRITE_J='1', MAKEFLAGS=f'-j{args.workers}', DOTNET_PROCESSOR_COUNT=str(args.workers))
    env['PATH'] = os.pathsep.join(builder.TOOL_PATHS + [env.get('PATH', '/usr/bin:/bin')])
    (work / 'tmp').mkdir(exist_ok=True)
    os.environ['DM_GAMES_DIR'] = str(profile_root)
    profile = game.load(source.title_id)
    # Normalize only the work layout. Preserve caller casing and original paths.
    extract = work / 'extract/v0'; extract.mkdir(parents=True, exist_ok=True)
    for name, target in (('ExeFS', source.exefs), ('RomFS', source.romfs)):
        link = extract / name
        if link.is_symlink() and link.resolve() == target.resolve(): continue
        if link.exists() or link.is_symlink(): raise ValueError(f'work path already belongs to another source: {link}')
        link.symlink_to(target, target_is_directory=True)
    builder.rewrite(sys.executable, REPO, extract / 'ExeFS', work / 'patched_v0', env, logs, profile, provisional=True)
    builder.mac_host(sys.executable, REPO, work, env, logs, profile)
    print(f'Diagnostic host prepared in {work}; native boot and rendering remain unvalidated.')


if __name__ == '__main__':
    try: main()
    except (ValueError, OSError, BuildError) as error: sys.exit(f'[RED] {error}')
