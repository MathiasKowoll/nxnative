"""Refuse an FC27 app build whose shader cache cannot render its profile."""
import csv
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(ROOT / 'dm/gfx/tools'))
import dmsh_chain


def check(work):
    game = dmsh_chain.load_game()
    chain = dmsh_chain.version()
    library = work / 'shader-cache-fc27' / ('b-' + chain)
    expected = dmsh_chain.inputs(game)
    stamp = dmsh_chain.read_stamp(library)
    errors = []
    if stamp.get('game') != game.id or stamp.get('inputs') != expected:
        errors.append(f'full shader build missing or stale: {library}')
    rows = csv.DictReader((s for s in game.table('shader_map.tsv').read_text().splitlines()
                           if not s.startswith('#')), delimiter='\t')
    keys = {r['dm_ctl_sha16'] for r in rows}
    for key in sorted(keys):
        lib = library / (key + '_b.metallib')
        reflection = library / (key + '_b.json')
        if not lib.is_file() or not lib.stat().st_size or not reflection.is_file():
            errors.append(f'missing shader {key}')
            continue
        try:
            if json.loads(reflection.read_text()).get('chain') != chain:
                errors.append(f'stale reflection {key}')
        except (ValueError, OSError):
            errors.append(f'invalid reflection {key}')
    for name in ('c1_full.tsv', 'cb_extent.tsv'):
        path = game.table(name)
        if not path.is_file() or not path.read_text().startswith(f'# chain b-{chain} inputs {expected}'):
            errors.append(f'stale profile table {name}')
    if errors:
        print('\n'.join(errors[:8]), file=sys.stderr)
        print(f'{len(errors)} cache validation errors', file=sys.stderr)
        return 1
    print(f'FC27 shaders verified: {len(keys)} libraries, chain {chain}, inputs {expected}')
    return 0


if __name__ == '__main__':
    sys.exit(check(Path(sys.argv[1])))
