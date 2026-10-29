# EA SPORTS FC 27

Profile for the Switch **1.8c.cab1** update on the Switch base title
`0100C49025D3E000`. The game reaches nnMain, initializes Frostbite, loads the
NVN renderer, opens the window and renders the FC Hub as a real-time 3D scene.

## Current status

**2026-10-28: a playable match is confirmed; the missing crowd is restored.**
The user completed Manchester United vs Liverpool at Old Trafford with empty
stands. The subsequent crowd fix makes CPU-inaccessible pools return NULL from
CPU mapping queries, preserving the GPU destinations of the engine's uploads.
`verify-q0/crowd-mapfix` confirms spectators in the stadium introduction,
gameplay and pause cameras. Its pose buffer now contains data instead of zeros.
The diagnostic 30 FPS legacy-path run and a subsequent 60 FPS default Metal 4
run (`crowd-mapfix-default2`) both reached the match with visible spectators.
One default-path boot still hit the scratch-memory alignment assertion; this
is not a claim of crash-free full matches. See `STATUS.md` for remaining issues.

- **The menu renderer is working.** FC News, Ultimate Team, Manager Career,
  Player Career, Kick Off, Learn to Play, Seasons and Tournaments each load a
  live scene with stadium, grass, player, ball, lighting and HUD.
- Selection changes render the 3D player transition. The validated run reached
  more than 11,100 presented frames at 60 fps without a game or system crash.
- The offline EA Servers notice can be dismissed. An async result-copy guard
  in `patches.py` avoids a NULL dereference; its earlier attribution to EA
  online services is unconfirmed (adjacent code checks VP8 video metadata).
- Three runtime menu compute programs had no threadgroup reflection. Their
  local sizes and shared-memory values are recovered from the NVN control
  section and recorded in `shader_facts_manual.tsv`. Without these values the
  dispatches were skipped and the transition remained incomplete.
- The launcher prepares seed and learned pipelines before the first frame
  (`DM_PSO_PREBUILD=1`, `DM_PSO_PREPARE=1`) and maps the game's thread
  priorities (`DM_QOS_MAP=1`). Seven partial-archive launches passed after one
  installed launch hit the pre-existing intermittent startup failure; one of
  seven launches without prewarm hit the same failure family, so prewarm is not
  its root cause. A 60-second QoS run held p50 at 16.56–16.66 ms through 3,300
  frames.

## Validated menu run

The final profile was exercised in one process through:

```text
attract -> EA Servers notice -> FC Hub -> FC News -> Ultimate Team
-> Manager Career -> Player Career -> Kick Off -> Learn to Play
-> Seasons -> Tournaments
```

Evidence is in
`/Volumes/CrucialX8/Emulation/Switch/_nxnative/FC27_base_work/run-942`.
The menu transition was sampled around 3 fps: consecutive frames changed while
the player animation ran, then settled on the scene pose. No shader load,
pipeline creation or compute-dispatch error was emitted after the fix.

## Rebuild consistency

The audio-only black screen after the host rebuild was caused by the host
requesting a new `b-<chain>` directory while only the previous chain was present.
`script/build_and_run.sh` now checks every mapped library, its reflection chain,
the full-build input stamp and the two generated profile tables before packaging.
If necessary it builds the matching shaders first.

The runtime shader map also contained indices from different capture packages.
Its 1,177 unique keys were retained and reindexed into the external
`FC27_base_work/pkg-fc27-verified` package; every record's control/code hash was
checked against its map key. The original map is backed up beside that package.

Found on this game: [geometry capture accepts flat vertex outputs](../../../docs/reference/shaders.md#geometry-capture-accepts-flat-vertex-outputs).

Found on this game: [dual-source blending from output location 1](../../../docs/reference/rendering.md#dual-source-blending-from-output-location-1),
[indexed driver textures with a fixed separate sampler](../../../docs/reference/shaders.md#indexed-driver-textures-with-a-fixed-separate-sampler).

Found on this game: [CPU-inaccessible pools must not return a CPU mapping](../../../docs/reference/nvn-objects.md#cpu-inaccessible-pools-must-not-return-a-cpu-mapping).

Found on this game: [byte permutation instructions must produce a result](../../../docs/reference/shaders.md#byte-permutation-instructions-must-produce-a-result).

Found on this game: [texel reads must not bind an unused sampler](../../../docs/reference/shaders.md#texel-reads-must-not-bind-an-unused-sampler).

## 60 fps

- Frostbite's internal frame-rate object is a pointer at `main+0xDA19E38`; the
  double target is at pointer `+8`. `hle_fpslock.c` keeps it at 60 for main build
  `fb81983aa1cc3a2e97402497e2ca6528`.
- `present_interval display` ignores the interval 2 requested by the game.
- The validated menu run held p50 near 16.6 ms with MetalFX enabled.

## Shaders

- Profile map: 1,205 unique keys, including 28 verified match-time captures;
  1,548 variation pairs.
- Metal cache: 1,205 compiled Mac libraries under
  `FC27_base_work/shader-cache-fc27/b-a18770be6fc6` (full-build input stamp
  `9dd03cf0d278`, with matching `c1_full.tsv` and `cb_extent.tsv`).
- The three runtime compute facts are:
  - `09211021c12cb409`: local `[8,8,1]`, shared `0`.
  - `b297f7dbdac50353`: local `[4,1,1]`, shared `0`.
  - `c3cab88f31d3cfeb`: local `[16,16,1]`, shared `1024`.

The installed cache now uses candidate `a18770be6fc6`. It builds and loads all
1,205 libraries with Metal API validation enabled, and fixes:

- Sampler ID `4096` diagnostics from unused sampler declarations on integer
  texel-read shaders. These fields are removed offline; remaining argument IDs
  are compacted to match the host's direct resource-ID writes. Referenced
  samplers still receive normal validation.
- Shader `cc26086f56a50927`'s absolute c2 indices: the table contains 173
  entries, covering separate texture slots 0..127. GPU tests verify the bounds
  and fixed sampler broadcast.
- PRMT byte permutation, previously omitted in two captured shaders.

See [current validation](STATUS.md#current-rebuild-validation-incomplete) for
runtime coverage and the remaining stability limits.

## App launcher

`script/build_and_run.sh` verifies the shader chain, copies the menu profile into
`FC27_base_work/profile`, and packs a self-contained app through
`dm/mac/pack_app.py`. The app contains the RomFS, rewritten modules, Metal
shaders, PSO archive, `dmhost`, and the FC27-specific settings launcher; it no
longer stores `FC27WorkFolder` or requires the external work folder at runtime.

Output (`pack` builds without opening it; the default `run` opens it):

- `/Volumes/CrucialX8/Emulation/Switch/_nxnative/FC27_Full_60fps_Texturas.app`
- alias: `/Volumes/CrucialX8/Emulation/Switch/_nxnative/EA Sports FC 27.app`

Test:

```sh
python3 -m unittest dm/games/0100C49025D3E000/tests/test_launcher.py
FC27_WORK=/path/to/FC27_base_work FC27_APP=/path/to/FC27.app script/build_and_run.sh pack
```

## Instalador con el juego del usuario

El instalador no distribuye FC27, actualizaciones, DLC ni claves. La persona
debe seleccionar su propia carpeta con el NSP/NSZ/XCI base y sus actualizaciones,
y su propio `prod.keys`; el pipeline extrae, reescribe, prepara los shaders y
genera una app Mac autocontenida con `--platform mac-app`.

Desde una copia de nxnative:

```sh
script/build_fc27_from_own_game.sh \
  "/ruta/a/EA Sports FC 27" \
  "/ruta/a/prod.keys" \
  "/ruta/de/salida"
```

También puede ejecutarse sin argumentos para seleccionar las tres rutas con
diálogos de macOS. Los intermedios quedan junto a la carpeta del juego, bajo
`0100C49025D3E000_build/`; `prod.keys` no se copia ni se imprime. La app final
incluye el RomFS, módulos reescritos, shaders y runtime necesarios para abrirla
sin depender de `FC27_base_work` en una ruta fija.

## Remaining work

The [FC26-to-FC27 quality research record](QUALITY_RESEARCH.md) tracks texture,
squad, player-animation and goal-net investigations that may inform this title.
These are research leads, not validated FC27 features.

- Validate additional match shader coverage; world and crowd rendering are
  confirmed, while `3e9a7bcf756123f0` remains a runtime-only pixel shader.
- Identify the intermittent Scratch/null-pointer startup failure. `DM_QOS_MAP=1`
  is the current mitigation, not a proven root fix.
- Validate the dual-source and 60 FPS candidate over complete matches before
  claiming stable transitions.
