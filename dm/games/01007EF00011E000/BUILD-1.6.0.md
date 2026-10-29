# Breath of the Wild 1.6.0 (v786432)

Date: 2026-10-28

## Identity

The update file named `The Legend of Zelda Breath of the Wild v1.9.0.nsp` identifies as display version 1.6.0.
Its module builds are:

- `main`: `8e9978d50bdd20b4c8395a106c27ffde`
- `subsdk0`: `93ff8252d975adf07230cb86c83301c5`
- `sdk`: `fcf93a41b08c5193a1410d262602dc62`

These are now registered in `game.tsv`; they do not match the 1.9.0 profile build
(`main` `cd57b23fa4bbad65803d9788c01821ee`).

## Frame step

The 1.6.0 VFR update is `main+0x1c01180` (not the 1.9.0 function). Its entry
stub takes the host's one- or two-vsync step, or the game's VFR override, and
publishes the ratio used by the other 1.6.0 readers:

| Step | VFR ratio | Delta time |
|---:|---:|---:|
| 1 | 0.5 | 16.67 ms |
| 2 | 1.0 | 33.33 ms |

The stub also publishes a 1/30 s tick for the held-button loop
(`main+0x126e3b0`) and the pause-menu countdown (`main+0x1214474`). The host
writes its present number at state `+0x38`; `VFR::update` is reached from two
call sites in some scenes, so the stub updates the tick and the logged stepped
vsyncs only when that number changes. This keeps game time at 1.000 rather than
counting the two callers twice.

The fade at `main+0x1821548`, the UI animation at `main+0x18522e0`, the
sound-link timer rate at `main+0x1c59fac`–`+0x1c5a014`, and the physics call at
`main+0x1618480` use the published ratio or preserve the six shipped substeps.

## Exclusive loads and the crash from issue #251

The reproducible crash is:

`SIGSEGV in h_nvnBufferGetAddress from main+0x14ef6f8`

The sead spin locks use a plain `ldxr`/`stxr` and a release barrier before the
unlock. On Apple's cores, loads inside the protected section can be satisfied
before the plain exclusive load observes the lock free. Two workers then read
the same job index and run the same job. The rewriter's
`ACQUIRE_EXCLUSIVES` option changes the 18,312 real `ldxr/stxr` windows in this
build to `ldaxr/stxr` (one bit, the same registers and size). The local runs no
longer reach the `h_nvnBufferGetAddress` crash; this is a crash-fix validation,
not a proof that every sead atomic in every game needs the same change.

## Shader tables

The profile's shader tables were regenerated from the 1.6.0 RomFS and `main`:

- 19,420 shaders
- 19,423 `shader_map.tsv` lines including its three header lines
- 91 `shader_facts.tsv` rows
- 12,750 shader pairs
- 2,883 `pso_pairs.tsv` rows

The 1.6.0 profile uses 1,493 prewarm rows. The 1.9.0 list had 178 shader keys
that do not occur in this build; those rows are filtered out, so the prewarm
now reports `shader keys not in the shader map 0`.

## Mac validation

The official `tools/dmhost`, patched `v786432`, Mac GPU `applegpu_g16s`, docked, 60 fps
target, copied save:

- title through save and into gameplay; no game crash in a 130 s run (the test timeout ended it with `SIGALRM`)
- frame time p50 16.66–16.71 ms in the early and middle windows
- `frame step: game time` at 1,800 / 3,600 / 5,400 presents: 1.000–1.001 of real time;
  the first 1,800 frames were held at one vsync
- the late gameplay windows still show 80–100 ms CPU hitches and occasional
  50 ms present pacing; `DM_HITCH_DUMP=80:60` puts the main thread and two
  `Worker` threads in the job queue's `main+0x12c0e4c` / `+0x12c0e58` spin
  gate, with `PlacementMgr` yielding over its batch

## Still open

- the 80–100 ms job-queue/PlacementMgr hitches above
- the 1.6.0 dynamic-resolution render-scale site; `DM_RENDER_SCALE` remains
  1.9.0-only for now
- an iPhone run of this profile (the Mac run above is the bring-up test)
