"""Host SDK parsing stays bounded for both legacy and Generic-target markers."""
from pathlib import Path
import subprocess
import tempfile
import unittest

HOST = Path(__file__).resolve().parents[2] / 'host'


class HostSdkVersion(unittest.TestCase):
    def test_version_and_truncation(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); source = root / 'sdk.c'; binary = root / 'sdk'
            source.write_text('''#include "sdk_version.h"
#include <assert.h>
int main(void) {
    const char legacy[] = "16_2_1-Release";
    const char generic[] = "Generic_19_3_3-Release";
    assert(dm_sdk_version_major(legacy, sizeof legacy) == 16);
    assert(dm_sdk_version_major(generic, sizeof generic) == 19);
    for (size_t n = 0; n <= 10; n++) assert(dm_sdk_version_major(generic, n) == 0);
    assert(dm_sdk_version_major("Generic_", 8) == 0);
    assert(dm_sdk_version_major("1234_0", 6) == 0);
    assert(dm_sdk_version_major("19-3", 4) == 0);
    assert(dm_sdk_version_major("0_0", 3) == 0);
    return 0;
}
''')
            subprocess.run(['clang', '-Wall', '-Werror', '-I', str(HOST), str(source), '-o', str(binary)], check=True, capture_output=True)
            subprocess.run([str(binary)], check=True, timeout=5)


if __name__ == '__main__': unittest.main()
