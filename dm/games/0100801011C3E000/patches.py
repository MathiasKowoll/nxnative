# Persona 5 Strikers (0100801011C3E000): the rewriter's patches of this game's own builds.
# CUTS, OBS and FRAME_STEP are keyed by NSO build ID as dm/tools/patch_nso.py applies them.
CUTS = {
    # 1.0.0 main. FPSLocker's master write for build C4DF04F647BDC727 blocks eight
    # instructions that otherwise restore the Switch's 30 fps configuration after boot.
    # The profile's fps_target 60 supplies the frame-rate pair, frame-time float and
    # interval flag (hle_fpslock.c); these cuts stop the game from overwriting them.
    'c4df04f647bdc727926348bd9a9918c8': [
        (0x4F3D68, '09c12c39', '1f2003d5', "60 fps: block the game's frame-rate update"),
        (0x4F3D7C, '09f904b9', '1f2003d5', "60 fps: block the game's frame-rate update"),
        (0x4F3D8C, '4bfd04b9', '1f2003d5', "60 fps: block the game's frame-rate update"),
        (0x4F3D94, '09a10fb9', '1f2003d5', "60 fps: block the game's frame-rate update"),
        (0x4D8748, '09c12c39', '1f2003d5', "60 fps: block the game's frame-rate update"),
        (0x4D8754, '09fd04b9', '1f2003d5', "60 fps: block the game's frame-rate update"),
        (0x4D8760, '09f904b9', '1f2003d5', "60 fps: block the game's frame-rate update"),
        (0x4D876C, '09a10fb9', '1f2003d5', "60 fps: block the game's frame-rate update"),
    ],
}
