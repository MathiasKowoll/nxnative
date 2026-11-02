# The single compile standard for Apple device shader packaging: MSL from any source (PC chain / constant patches / in future, the Switch original translated via Ryujinx) → device metallib.
# Compile parameters are defined only once, here; the chain.metal record in the reflection json is generated from the same parameters, record == actual.
import os
import subprocess
# -fmetal-math-mode=relaxed: keep fast math's reassociation / contraction, but forbid assuming there are no NaN / Inf. The translated shaders reproduce Maxwell's NaN semantics with isnan selects (8337 / 12809 use them),
# and the default fast mode lets each GPU's backend compiler treat them as always false; on the A20 Pro the opening course's odd frames had 727k NaN pixels in the main image (a few dozen with the same AIR on the M4 Pro), which became the black band / black-edged glow
# -fpreserve-invariance: [[invariant]] position outputs only agree across shaders with this flag (as dmsh_build.py's MAC_METAL: a depth pre-pass followed by a less-or-equal G-buffer)
# -O1: -O2's switch folding leaves a control-flow graph Apple's GPU backend can only lower slowly into very large code (as dmsh_build.py's MAC_METAL)
SDK = os.environ.get('DM_METAL_SDK', 'iphoneos')
MIN_VERSION = '-mtvos-version-min=26.0' if SDK == 'appletvos' else '-mios-version-min=18.0'
METAL = ['xcrun', '-sdk', SDK, 'metal', '-c', '-O1', MIN_VERSION, '-fmetal-math-mode=relaxed', '-fpreserve-invariance']
METALLIB = ['xcrun', '-sdk', SDK, 'metallib']
RECORD = ' '.join(METAL) + '; ' + ' '.join(METALLIB)                                # Written into json chain.metal

def compile(msl, air, lib):
    subprocess.run([*METAL, msl, '-o', air], check=True)
    subprocess.run([*METALLIB, air, '-o', lib], check=True)
