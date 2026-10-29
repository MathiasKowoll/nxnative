# FC 27 bring-up status

This file records FC 27-specific work in the source tree. It contains no NSP,
RomFS image or extracted game files.

## Current rebuild validation: incomplete

The next shader candidate, chain `a18770be6fc6`, builds all 1,205 mapped shaders
with zero undecoded bindings, zero unfillable driver-bank reads and no
unimplemented-instruction notes. It fixes absolute c2 texture-table indices
(173 entries, including separate slots 0..127), implements PRMT, and removes
unused sampler declarations while densely numbering the remaining argument IDs.
PRMT was previously omitted in `050a1c9b91308a2c` (compute) and
`0332490f5224b266` (vertex).

Validation completed for this candidate:

- PRMT: 248 exact integer GPU results across all four operand forms and all
  seven modes.
- Driver arrays: 26 GPU checks, including a negative control for the former
  32-entry clamp.
- Unused samplers: 12 reflection tests, including direct GPU resource-ID writes
  through a compacted Metal argument buffer. Removing fields without compacting
  IDs was rejected: Metal's encoded length can be smaller than `(maxAid+1)*8`.
- Production shader loader: all 1,205 libraries and their declared variants
  load with Metal API validation enabled, zero failures
  (`verify-q0/shader-library-loader.log`).
- The preceding `67b72e28c5af` candidate reached Manchester United vs Liverpool
  with spectators on the default Metal 4 path (`shaders-prmt-60`), then exited
  cleanly at 9,039 frames / 153.771 seconds. Its 60–100 second sample averages
  60.0 FPS, but other samples contain stalls up to 89 ms. This is not a stable
  full-match result.

The installed app now embeds chain `a18770be6fc6` and both shader tables. The
five-game static regression is recorded in `verify-q0/shaders-final-regress`;
all mapped shaders across the five profiles were rebuilt without a build
failure. The headless prewarm run reached 136,500 frames, with interval
p50 averaging 16.659 ms (16.370–16.920 ms) and a maximum logged frame of
178.44 ms. The harness session ended without a graceful-exit line, so this is
not a clean-shutdown result.

Startup A/B on 2026-10-28 separates prewarm from the remaining crash family.
One installed launch crashed at frame 52 in `main+0x96f01c4`, where the guest
dereferenced `[NULL-4]`; its pipeline prepare had completed with 390 shaders,
406 render pipelines and 71 compute pipelines, with no key outside the shader
map. Seven direct launches with the same partial archive, window and audio
configuration passed. Without prewarm, one of seven launches hit the known
Scratch-allocator alignment trap at `main+0x17f62b8`. Prewarm therefore changes
timing but is not the root cause: both modes expose an existing intermittent
guest allocation/initialization failure.

The launcher now sets `DM_QOS_MAP=1` so worker priorities remain below the
real-time main thread. A 60-second visible run survived 3,300 frames with p50
16.56–16.66 ms, p95 19.38–20.22 ms and maximum 21.38 ms. This is a promising
mitigation, not proof that the rare startup crash is fixed.

On 2026-10-28 the user completed Manchester United vs Liverpool at Old Trafford
in the `verify-q0/blend-descriptor` run. Stadium, pitch, players and pause menu
rendered; the crowd was missing. The run reached 26,400 frames with frame p50
near 16.7 ms. This used `DM_PSO_MTL4=0` and `DM_NVN_PREDICT=0`: invalid pipelines
returned an error instead of aborting in Metal 4. This historical run predates the crowd fix below. Default-path stability
validation remains open.

The subsequent crowd investigation adds an offline dual-source fragment entry
selected by blend state and supports indexed c2 textures with a fixed separate
sampler. The GPU blend test passes 59 checks; reflection conversion passes 28
checks (two unavailable historical sample files are skipped). Runtime captures
add 28 hash-verified shaders, including three compute programs whose local sizes
come from their control sections. The map now has 1,205 keys. Evidence is under
`verify-q0/crowd-*`; crowd visibility is now confirmed by `crowd-mapfix`.

- Audio-only black screen: fixed by rebuilding the full shader cache for host
  chain `8d74aac40e09`, using a hash-verified package with all 1,177 mapped keys.
  The full-build input stamp is `2c6d064230e3`.
- The old hand-written result-copy cave used `STP D0,D1` for a `Q0` value. That
  mixes unrelated SIMD registers. It now stores the entire `Q0`; five Unicorn
  execution tests cover the copy and the null-result/cleanup paths. The old
  cave fails the copy regression. This fixes one corruption source but has
  not removed all crashes.
- The earlier attribution of `main+0x804e358` to EA online services is not
  established: the adjacent routine at `0x804e3a0` checks the `VP80` FourCC,
  width and height, suggesting a video-result path. Further guards are not a
  substitute for identifying the original missing result.
- Current CPU failures include `main+0x9698144` with repeated floating-point
  bits in allocator links, `0x9696a4c`, and `0x9695a74`. The frame-52 startup
  failure is now characterized more precisely: `main+0x96f01c4` is reached
  through the descriptor loop at `main+0x96efef0`; its `x1` source record was
  all zero, so the routine loaded a null string/data pointer and immediately
  read `[NULL-4]`. This confirms the immediate cause as an uninitialized
  metadata record reaching the hash/conversion callback. The writer or race
  that leaves that record zero is still unidentified. Waiting for GPU
  completion instead of early fence wake did not eliminate the failure.
- A diagnostic `DM_PROBE_WATCH_REG=x21` capture on the descriptor page observed
  repeated writes from `main+0x9697bbc` / `main+0x9697cec` and `main+0x9707ec8`.
  The disassembly identifies the first two as allocator free-list/link updates;
  the capture changed timing and did not reproduce the frame-52 callback crash,
  so these are candidates for correlation, not yet the writer of the zero
  metadata record. The feature remains diagnostic-only and is not enabled by
  the launcher.
- The historical Metal compiler abort in `buildBlendFactor` led to the
  dual-source entry fix above. It has not recurred in the subsequent legacy
  pipeline runs. After the crowd fix, `crowd-mapfix-default2` also reaches
  the match on the default Metal 4 path without this compiler abort.
- `crowd-mapfix-default2` repeats the actual menu → teams → kits → preview
  → match flow at the launcher's 60 FPS target with default Metal 4 and shader
  prediction enabled. Spectators render in the introduction and match/pause
  cameras. This is a short runtime validation, not a completed full match.
- The first post-crowd-fix default-path attempt (`crowd-mapfix-default`) stops
  at `main+0x17f62b8` during boot. This is an intentional assertion trap, not
  an unguarded result dereference: `VirtualAlloc_Posix.cpp(389)` reports an
  unmap address not aligned to the 4 KB page size, for the `Scratch` allocator.
  The captured address is `0x7127376ff0`; the caller is `main+0x1814f8c`.
  The origin of that invalid scratch allocation remains open. Do not bypass
  the alignment check or round the address without identifying its owner.
- The installed `a18770be6fc6` cache resolves shader
  `cc26086f56a50927`'s absolute c2 table within its 173-entry bounds. The
  former sampler-4096 and dynamic-c2 diagnostics do not recur in the current
  loader or gameplay runs.
- `crowd-thirty` reached an actual match at 30 FPS, all shaders enabled, without
  the allocator crash seen in several 60 FPS diagnostic runs. Empty stands
  persist. This is a diagnostic timing change, not a crash fix or launcher default.
- The crowd pose buffer was entirely zero, despite populated crowd indices,
  state and world-position buffers. `crowd-replay` captures the exact draw
  inputs; `crowd-buffertrace` and the NVN NRO upload routine identify the
  [incorrect CPU mapping of GPU-only pools](../../../docs/reference/nvn-objects.md#cpu-inaccessible-pools-must-not-return-a-cpu-mapping).
  Both map APIs now honor `CPU_NO_ACCESS`. `t_nvn` passes 179 checks, including
  cached/uncached/no-access mappings and preserved GPU offsets. The full
  graphics suite passes (`verify-q0/crowd-map-suite.log`). `crowd-mapfix` confirms
  visible spectators in the introduction, gameplay and pause camera. The GPU
  pose buffer dump has 1,537,286 nonzero bytes out of 8,827,392; before the fix,
  the corresponding buffer was entirely zero. This 30 FPS legacy-path run
  exited cleanly on request, without a crash. It is not a full-match stress test.

Evidence: `FC27_base_work/verify-q0/visible-trace/01.png` is the match preview;
`first-crash.log`, `fence-completion/run.log`, `no-predict/run.log`,
`allocator-list/run.log`, and `blend-test.log` preserve the distinct outcomes.
The binary backup is `patched-v262144/backup-before-q0-fix`; the corrected
image SHA256 is `b7c6e01db1d90df86ea574da08365b0aee0b8da75f3936de9b33189c35ee3d17`.

## Historical menu run (run-942)

- App title: `0100C49025D3E000`, update `1.8c.cab1`.
- Main module build: `fb81983aa1cc3a2e97402497e2ca6528`.
- Audio: `DM_AUDIO=1` opens CoreAudio; the user confirmed sound works.
- 60 fps: the internal Frostbite target is held at 60 and presentation follows
  the display interval.
- **FC Hub menu:** real-time 3D background, stadium, grass, player, ball,
  lighting and HUD are visible.
- **Menu navigation:** FC News, Ultimate Team, Manager Career, Player Career,
  Kick Off, Learn to Play, Seasons and Tournaments load their live scenes.
- **Menu transition:** FC News to Ultimate Team was sampled frame by frame.
  The player animation advances, the selection scene changes, and the process
  remains stable.
- The validated process reached frame 11,100 at 60 fps without a crash.
- Runtime cache: 1,177 Mac libraries, profile map with 1,178 entries and 1,548
  variation pairs.

## Fixes required for the working menu

- `patches.py`: guard an empty result copy observed after the offline notice
  (`main+0x804E358`); the subsystem attribution remains unconfirmed.
- `shader_facts_manual.tsv`: supply the runtime compute local sizes for
  `09211021c12cb409`, `b297f7dbdac50353` and `c3cab88f31d3cfeb`.
- Launcher: keep prewarm and the pipeline archive enabled, but map guest
  priorities with `DM_QOS_MAP=1`. Partial and complete archives pass repeated
  startup trials; the remaining failure is the intermittent Scratch/null
  initialization bug above.
- `nvn_mtl.m`: name the failed compute key when threadgroup reflection is
  missing, so a future gap is actionable.

## Historical limits of run-942

- At the time of run-942 the match world was outside that milestone: HUD,
  radar, cards and pause UI rendered, while the 3D world camera was black in
  the earlier profile. The current profile renders the match world.
- Sampler ID `4096` came from unused sampler declarations in that historical
  cache and is removed by the current shader chain.
- `c1_full.tsv` and `cb_extent.tsv` were not stamped for that historical full
  rebuild. They now match chain `a18770be6fc6` and input stamp `9dd03cf0d278`.
- Pipeline archive and manifest prewarm were not safe at that milestone. They
  have since passed the partial-archive and complete-archive startup trials
  recorded above.

## Rebuild

From `/Users/mathias/Development/nxnative`:

```sh
./script/build_and_run.sh --verify
```

The profile tables in this directory are the source of truth. The large Metal
cache and runtime shader dumps stay under `FC27_base_work`.

## Evidence

- `/Volumes/CrucialX8/Emulation/Switch/_nxnative/FC27_base_work/run-942`
- Cache: `FC27_base_work/shader-cache-fc27/b-a18770be6fc6`
- Startup A/B: `FC27_base_work/verify-q0/stress-*` and `qos-long-60`
- Pacing: `FC27_base_work/verify-q0/shaders-prewarm-headless`
- Runtime profile: `FC27_base_work/profile`

## Next work

1. Identify the writer/race that leaves the frame-52 metadata record zero and
   corrupts Scratch/allocator state; QOS mapping is a mitigation, not a root fix.
2. Validate the current c2/PRMT candidate through complete matches and the
   remaining match-time shader `3e9a7bcf756123f0`.
3. Resume native weather and the other basic quality improvements after full
   match stability is established.
