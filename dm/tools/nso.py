import sys
from pathlib import Path
from nso_segments import load

src, dst = Path(sys.argv[1]), Path(sys.argv[2])
img, flags, segs, bss, _ = load(src)
dst.write_bytes(img)
print([[hex(x) for x in s] for s in segs], hex(bss), 'moduleid', src.read_bytes()[0x40:0x60].hex())
