"""Compact NVN2 controls must not be read at legacy +0x704 offsets."""
from pathlib import Path
import subprocess
import tempfile
import unittest

NVN = Path(__file__).resolve().parents[2] / 'gfx/nvn'


class ShaderControl(unittest.TestCase):
    def test_bounds_and_legacy(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'control.c'
            source.write_text('''#include "nvn_shader_control.h"
#include <assert.h>
#include <stdlib.h>
static void put(void *p, unsigned off, uint32_t v) { memcpy((char *)p + off, &v, 4); }
int main(void) {
    uint32_t ctl, code;
    void *p = calloc(1, 0xd8);
    put(p,0,0x98761234); put(p,4,201); put(p,8,7);
    put(p,0x30,0xd8); put(p,0x40,0x1500);
    assert(nvn_shader_control_layout(p,&ctl,&code) && ctl==0xd8 && code==0x1500);
    assert(nvn_shader_control_stage(p)==0);
    put(p,0x54,1u<<16); assert(nvn_shader_control_stage(p)==1);
    put(p,0x54,6u<<16); assert(nvn_shader_control_stage(p)==6);
    put(p,0x54,7u<<16); assert(nvn_shader_control_stage(p)==7);
    put(p,0x54,8u<<16); assert(nvn_shader_control_stage(p)==-1);
    put(p,0x54,0); put(p,8,11);
    assert(nvn_shader_control_layout(p,&ctl,&code) && ctl==0xd8 && code==0x1500);
    put(p,0xc4,0xd8); put(p,0x30,0); assert(nvn_shader_control_layout(p,&ctl,&code) && ctl==0xd8);
    put(p,0xc4,0); assert(!nvn_shader_control_layout(p,&ctl,&code));
    put(p,0x30,0xd8); put(p,8,7); put(p,0x40,0x1501); assert(!nvn_shader_control_layout(p,&ctl,&code));
    put(p,0x40,0x1500); put(p,0x30,0x40); assert(!nvn_shader_control_layout(p,&ctl,&code));
    put(p,0x30,0xd8); put(p,8,8); assert(!nvn_shader_control_layout(p,&ctl,&code));
    free(p);
    p=calloc(1,0x880); put(p,0,0x98761234); put(p,4,29); put(p,0x20,0x850); put(p,0x704,0x1230);
    assert(nvn_shader_control_layout(p,&ctl,&code) && ctl==0x850 && code==0x1230);
    assert(nvn_shader_control_stage(p)==-1);
    put(p,0x20,0x900); assert(nvn_shader_control_layout(p,&ctl,&code) && ctl==0x880);
    free(p); assert(!nvn_shader_control_layout(NULL,&ctl,&code));
    return 0;
}
''')
            binary = root / 'control'
            subprocess.run(['clang', '-Wall', '-Werror', '-fsanitize=address,undefined',
                            '-I', str(NVN), str(source), '-o', str(binary)],
                           check=True, capture_output=True)
            subprocess.run([str(binary)], check=True, timeout=10)


if __name__ == '__main__': unittest.main()
