"""Decode ZBIC-compressed Switch NSO segments.

Firmware 22 and later can mark an NSO with flag bit 7 and compress its three
segments with ZBIC, a Zstandard variant whose frame starts with ``ZBIC`` and
uses Binary Interpolative Coding for normalization headers. Python's normal
Zstandard implementation rejects that frame, so this module builds the
ZBIC-enabled Zstandard amalgamation in ``dm/third_party/zstd-zbic`` once and
calls it through ctypes. Build products go to ``NXNATIVE_CACHE`` (the NSP build
script points it at the game drive), or to the system temporary directory when
a tool is run by hand.
"""
import ctypes
import fcntl
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

_ROOT = Path(__file__).resolve().parents[1] / 'third_party' / 'zstd-zbic'
_SOURCE = _ROOT / 'source/core/zstd.c'
_WRAPPER = _ROOT / 'zbic_decode.c'
_LIB = None


def library_path():
    explicit = os.environ.get('NXNATIVE_ZBIC_LIBRARY')
    if explicit:
        path = Path(explicit)
        if not path.is_file(): raise FileNotFoundError(path)
        return path
    cache = Path(os.environ.get('NXNATIVE_CACHE') or tempfile.gettempdir())
    cache.mkdir(parents=True, exist_ok=True)
    out = cache / 'libzbic.dylib'
    newest = max(p.stat().st_mtime_ns for p in (_SOURCE, _WRAPPER, _ROOT / 'include/core/zstd.h'))
    if out.is_file() and out.stat().st_mtime_ns >= newest: return out
    clang = shutil.which('clang')
    if not clang: raise RuntimeError('clang not found: ZBIC needs the Xcode Command Line Tools')
    lock_path = cache / 'libzbic.lock'
    with lock_path.open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if out.is_file() and out.stat().st_mtime_ns >= newest: return out
        partial = cache / 'libzbic.partial.dylib'
        cmd = [clang, '-O0', '-DNDEBUG', '-DZSTD_ZBIC_SUPPORT=1', '-pthread', '-dynamiclib',
               str(_SOURCE), str(_WRAPPER), f'-I{_ROOT / "include"}', '-o', str(partial)]
        subprocess.run(cmd, check=True)
        partial.replace(out)
    return out


def _function():
    global _LIB
    if _LIB is None:
        _LIB = ctypes.CDLL(str(library_path()))
        _LIB.nxnative_zbic_decompress.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t]
        _LIB.nxnative_zbic_decompress.restype = ctypes.c_size_t
    return _LIB.nxnative_zbic_decompress


def decompress(data, size):
    """The exact ``size`` bytes a ZBIC frame holds, or ValueError."""
    if len(data) > size: raise ValueError(f'ZBIC input is larger than its {size:#x}-byte segment')
    src = ctypes.create_string_buffer(data)
    dst = ctypes.create_string_buffer(size)
    got = _function()(dst, size, src, len(data))
    if got != size:
        raise ValueError(f'ZBIC decode returned {got:#x} bytes, expected {size:#x}')
    return dst.raw[:size]
