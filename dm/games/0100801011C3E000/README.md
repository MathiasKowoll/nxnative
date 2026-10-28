# Persona 5 Strikers

Persona 5 Strikers (Switch, base game 1.0.0). Runs on the Mac at 60 fps after a small host fix for this game's older SDK 8 play-statistics overload and build-gated cuts that keep the game from restoring its Switch 30 fps configuration.

## What works

- Boot, save creation, audio, video, movies, and controller input.
- The game reaches and stays in its opening sequence; no crash after the first save.
- 60 fps in a 95-second Mac test: the final 2,700 measured frames averaged 59.9 fps, with frame-time p50 16.75 ms and GPU time p50 about 1 ms.
- Shaders and pipelines load from the profile.
- The host uses `DM_GAMES_DIR` if you build with a provisional profile, and this profile can be used directly from `dm/games`.

## What was fixed

The game calls the older `nn::pdm::QueryApplicationPlayStatistics` overload without a user ID. The host only hooked the newer overload with a user ID, so the older one reached an unimplemented service path and crashed after the first save. `dm/host/hle_offline.c` now hooks both overloads.

## 60 fps

The 1.0.0 main build restores the Switch configuration in two paths: eight stores set the interval flag, the 30 fps frame-rate pair and the 30.0 fps float frame rate. `patches.py` turns those eight instructions into NOPs, gated by main build ID `c4df04f647bdc727926348bd9a9918c8`, and `hle_fpslock.c` writes the frame-rate pair, float frame rate and interval flag from `fps_target` when they differ. With `fps_target 60`, display-mode presentation holds one 60 Hz tick per frame. The measured run stayed at 59.9 fps through the opening movie after startup; the earlier data-only host writes held 60 fps only for the first scene and then fell back to about 27.5 fps when the game restored its own timing.

## Profile notes

- Base game only, version 1.0.0.
- Modules: `main`, `subsdk0`, `sdk`.
- SDK: 8.3.2.
- Shader map and pipeline pairs are generated from the base game.
