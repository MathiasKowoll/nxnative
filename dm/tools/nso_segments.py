"""Shared NSO header parsing and segment decompression (LZ4 or ZBIC)."""
import struct
from pathlib import Path


def load(source, bss=True):
    """(image, flags, segments, bss size, compressed sizes) from an NSO.

    ``source`` is a path or the module's bytes. The image contains the three
    decompressed segments and, when ``bss`` is true, the zero-filled BSS tail.
    """
    data = Path(source).read_bytes() if isinstance(source, (str, Path)) else source
    if data[:4] != b'NSO0': raise ValueError('not an NSO module')
    flags = struct.unpack_from('<I', data, 0xc)[0]
    segments = [struct.unpack_from('<III', data, 0x10 + i * 0x10) for i in range(3)]
    bss_size = struct.unpack_from('<I', data, 0x3c)[0]
    compressed = struct.unpack_from('<III', data, 0x60)
    image = bytearray(segments[2][1] + segments[2][2] + (bss_size if bss else 0))
    for i, (file_offset, memory_offset, size) in enumerate(segments):
        raw = data[file_offset:file_offset + compressed[i]]
        if flags >> i & 1:
            if flags & 0x80:
                import zbic
                raw = zbic.decompress(raw, size)
            else:
                import lz4.block
                raw = lz4.block.decompress(raw, uncompressed_size=size)
        if len(raw) != size:
            raise ValueError(f'NSO segment {i} decoded to {len(raw):#x} bytes, expected {size:#x}')
        image[memory_offset:memory_offset + size] = raw
    return image, flags, segments, bss_size, compressed
