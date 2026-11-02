"""Identify a loose ExeFS/RomFS dump without keys, copying it, or running guest code."""
from dataclasses import dataclass
from pathlib import Path
import struct


@dataclass(frozen=True)
class ExtractedSource:
    root: Path
    exefs: Path
    romfs: Path
    program_id: int
    system_resource: int
    flags: int

    @property
    def title_id(self):
        return f'{self.program_id:016X}'

    @property
    def switch2(self):
        # Generation is source metadata, not a claim of support by the runtime.
        return self.program_id >> 56 == 4


def _child(directory, name):
    matches = [p for p in directory.iterdir() if p.name.casefold() == name.casefold()]
    if len(matches) > 1:
        raise ValueError(f'ambiguous {name} directories in {directory}')
    return matches[0] if matches else directory / name


def inspect(folder):
    folder = Path(folder).expanduser().resolve()
    if folder.is_file() and folder.name == 'main':
        folder = folder.parent
    if not folder.is_dir():
        raise ValueError(f'not a source folder: {folder}')
    if folder.name.casefold() == 'exefs':
        folder = folder.parent
    choices = [folder]
    base = _child(folder, 'base')
    if base.is_dir():
        choices.append(base)
    candidates = []
    for root in choices:
        exefs, romfs = _child(root, 'exefs'), _child(root, 'romfs')
        if exefs.is_dir() and romfs.is_dir():
            candidates.append((root, exefs, romfs))
    if len(candidates) != 1:
        raise ValueError('expected exactly one ExeFS/RomFS pair, directly or under base/')
    root, exefs, romfs = candidates[0]
    npdm = exefs / 'main.npdm'
    if not npdm.is_file() or not 0x80 <= npdm.stat().st_size <= 1024 * 1024:
        raise ValueError('missing or invalid main.npdm; cannot identify the extracted program')
    data = npdm.read_bytes()
    if data[:4] != b'META':
        raise ValueError('main.npdm has no META header')
    offset, size = struct.unpack_from('<II', data, 0x70)
    if size < 0x20 or offset < 0x80 or offset > len(data) - size or data[offset:offset + 4] != b'ACI0':
        raise ValueError('main.npdm ACI0 range is invalid')
    program_id, = struct.unpack_from('<Q', data, offset + 0x10)
    if not program_id:
        raise ValueError('main.npdm has no program ID')
    if not data[0xc] & 1:
        raise ValueError('32-bit ARM programs cannot execute natively on Apple silicon')
    for name in ('main', 'sdk'):
        path = exefs / name
        if not path.is_file():
            raise ValueError(f'ExeFS is missing {name}')
        with path.open('rb') as stream:
            if stream.read(4) != b'NSO0':
                raise ValueError(f'ExeFS {name} is not an NSO module')
    return ExtractedSource(root, exefs, romfs, program_id, struct.unpack_from('<I', data, 0x14)[0], data[0xc])
