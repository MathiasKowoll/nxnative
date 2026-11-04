# Mario Kart World: native Switch 2 bring-up

Status: experimental and not a supported release. A packaged Mac app now reaches and
plays an interactive race with a controller; save-load, long-session and iOS validation
remain open. The provisional profile and all game-derived outputs stay beside the
user's extracted game, outside this repository.

This game's remaining work follows the repository-wide performance and graphics
quality work; it is no longer the sole priority. Memory and crash monitoring remain
active. Quality experiments run at the game's native scale so that a presentation
change cannot hide their cause. A lower-resolution or MetalFX route must be measured
separately and must not remove texture data to mask resource pressure.

## Reproducible source preparation

`scripts/prepare_extracted_game.py SOURCE --name "Mario Kart World" --prepare-code --workers 1`
accepts an ExeFS/RomFS pair, including a pair under `base/`. It validates the META/ACI0
identity and NSO inputs, inventories assets without copying them, derives a local
profile and reuses the existing rewriter and Mac host builder. It does not convert
a Switch 2 program into a Switch 1 program, nor infer a retail version from the
local `v0` work slot. A changed source needs a separate work directory.

`scripts/probe_extracted_game.py WORK --seconds 15 --min-available-mib 8192` runs
the host with a time, available-memory and log limit. An explicit `--max-rss-mib`
can additionally impose a process-group ceiling. It stops the whole process group
and keeps the log and a JSON report. These are headless diagnostic runs unless
`--visible` is supplied; neither mode implies a gameplay pass. Add `--metal-hud`
to a visible run to show Apple's Metal performance HUD; the setting is scoped
to the child host and recorded as `metal_hud_requested` in the report.

## Capture retention

Keep only a bounded set of local frame captures needed for the current visual
comparison. Record the observation, frame number and file path here before
moving an analysed temporary capture to the external volume's Trash; preserve
the text log and JSON report. Do not attach diagnostic captures to a chat or
embed their bytes in reports: cite their local path and the recorded finding
instead. The target-dump set from `20261102-180135` was analysed and moved to
the volume Trash, while the later frame-500 and menu checkpoints remain the
current visual evidence.

## Source identity

- Program ID: `0400C3F00006E000`.
- Main build: `9e244438c3d8ef1c703a6a85ef99c4f0`.
- SDK build: `90ebba182862b9ecdc21fcb87b999012`.
- SDK marker: `NintendoSDK_nnSdk-Generic_19_3_3-Release`.
- Retail display version: unknown; no control NACP was supplied.

## Confirmed bring-up findings

1. The rewriter treated a SIMD destination such as `s1` as a write to GPR `w1`
   while recovering a jump-table index. Main's dispatch at `+0xea4a8` consequently
   failed analysis. Only `wN`/`xN` writes now affect GPR index tracking; all three
   modules rewrite. See [register namespaces](../reference/rewriter.md#vector-registers-read-as-writes-of-the-jump-table-index).
2. The host and profile guesser missed the `Generic_` SDK prefix. Both now identify
   SDK 19 without reading past the marker's bounds.
3. SDK `+0x14aa08` asks GetInfo(33) for its physical mapping granule and passes that
   value straight to MapPhysicalMemory. Returning zero caused Result `0xd401`.
   The host now reports its 4 KiB guest mapping granule; the SDK initializes.
4. The ordinary Switch 1 profile did not fit this game's memory layout. Main
   `+0xcf25b4` reserves a fixed `0x1bd600000`-byte region. The external provisional
   Mac profile currently reserves 16 GiB of alias VA and 8.5 GiB of heap VA, with a
   10 GiB logical application pool and map-limit accounting. Virtual reservation
   is not resident RAM. Early probes used a 2 GiB RSS ceiling; current probes retain
   8 GiB of available system memory without that arbitrary process cap. This is not an iOS layout.
5. Main `+0xcf3b20` requires NVN API 231.16. The external profile requests that API
   for diagnosis only. Reporting it does not establish full NVN2 compatibility.
6. Secondary-queue setup calls `nvnQueueBuilderSetPrimaryQueue`. The host records
   that relationship while retaining independent replay state and serialized
   Metal execution. Cross-device and self-primary queues are rejected.
7. NVN2 uses ProgramBuilder and compact 201.7/201.11 shader control sections. Their
   control length is at `+0x30`; `+0x38` is the exact instruction length, `+0x40`
   rounds it to 0x100 and `+0x44` ends the code area after optional c1 data. The
   observed controls are usually 216 bytes. A bounded census of four shader archives checked 20
   version-201.7 and 2,230 version-201.11 descriptors against these spans, without
   mismatches. Legacy `+0x704` reads would overrun compact controls. Program initialization,
   keys and diagnostic dumps now respect the compact layout. Unsupported forced
   sample shading remains an explicit failure.
8. Generic SDK 19 queries a graphics-scale applet service and an audio-device
   auto-volume policy. The direct host services report a fixed initial graphics
   scale and disabled automatic volume adjustment; explicit output gain remains
   active. Enabling auto-volume is still reported as unsupported.
9. Command recording modes 0/1 use the host's deferred records. In the supplied
   SDK, SetRecordingMode at `+0x59f2c0` stores the mode at command buffer +0x18;
   CopyBufferToBuffer at `+0x5af4c0` uses a software copy record in mode 1, retaining
   source, destination and length. EndRecording returns an ordinary handle for
   modes 0/1. The host tests both forms with an actual copy and recorded fence.
   Compute-overlap modes
   0/1 retain the backend's ordered execution; they do not enable asynchronous
   compute. Other recording modes are refused, not silently treated as mode 0.
10. Null shading-rate images disable variable shading and retain the backend's
    per-pixel shading. Full 16-entry palettes and non-null 2D `R8UI` maps are
    validated. Metal does not consume the NVN2 rate map yet, so a valid non-null
    map deliberately runs at the full 1x1 rate. This preserves samples and image
    quality at the cost of the VRS performance win; it is not native VRS support.
11. The renderer ignored a failed `prog_key` call and formatted uninitialized
    bytes as a shader key. It now rejects the invalid key, including in prefetch.
    Runtime-built 201.11 controls with zero at +0x30 carry their exact 216-byte
    size at +0xc4; bounded captures confirmed that value in all 39 such controls.
    Their keys now use the same exact span as archive controls.
12. Compact controls identify their logical shader stage at +0x54. The first
    mesh-task program binds fragment stage 1, task/object stage 6 and mesh stage 7,
    independent of descriptor order. Runtime dumps now enter the shader inventory
    under those exact stages instead of being guessed from their SPH or list index.
13. Geometry-processing modes 0, 1 and 2 are retained. The first mode-1 command is
    `DrawMeshTasks(first=0, count=1)`, with shader keys `bf2db28e0007f27d`,
    `552bff639f0fe92b` and `1585faea431dbac0`. It remains an explicit stop because
    no task/mesh execution path exists yet.
14. Main `+0x16d722c` calls `nvnCommandBufferPushGraphicsConstants` through NVN
    import slot `0x3399160`, with root table 0, offset 0 and 16 bytes containing
    `{1/width, 1/height, width, height}`. The missing import produced the null-PC
    crash at `main+0x16d72f4`. The host now records partial updates to all eight
    256-byte NVN2 root tables and snapshots a table at each draw when reflection
    reads constant-buffer slots 24 through 31. Capture/replay retains the inline
    bytes. The bounded run after this change passes the old crash and reaches the
    explicit task/mesh stop.
15. The Metal program cache now recognizes logical stages 6 and 7 as task/object
    and mesh without widening the stable six-stage draw path. Replay retains their
    uniform, storage, texture, sampler and image bindings in separate stage slots.
    This is state preservation only: no ordinary vertex/fragment draw consumes
    those slots. A dedicated GPU test compiles a Metal object+mesh pipeline, sends
    a 16-byte payload from object to mesh and validates all 16 rendered pixels.
    This confirms the host architecture on Apple Silicon but is not a translation
    of the game's shaders.

## Shader experiment

The external probe uses Eglantine's Ampere lowering at commit
[`f6d03bc69d5bcda45bd054edda24521820c42deb`](https://github.com/MathiasKowoll/Eglantine/tree/f6d03bc69d5bcda45bd054edda24521820c42deb).
Its GPL sources remain in the external diagnostic workspace, with their license;
they are not linked into or copied into NXNative's runtime.

One `DriveRefreshUber.GridifyRoad.Nin_Ounce_NVN2.bfsha.zs` archive supplied 11 unique
graphics programs. All 11 lower, translate to SPIR-V without translator notes and
compile to Metal libraries using the production translator's default debug/SSA
option. This is compiler acceptance, not rendering equivalence or whole-game coverage.

Eight additional 201.11 graphics shaders captured from the native boot (four
vertex, four fragment) also lower, translate without notes, and compile to Metal.
Their raw libraries are isolated in the external `runtime-20111` experiment;
they have no validated runtime binding reflection and are not installed as game
shader libraries. The combined 19 samples do not constitute a complete AOT build.

The exact first task/mesh pipeline was captured separately. At the pinned
Eglantine revision its fragment shader lowers, while task opcode `0x927` (`ISBEWR`)
and mesh opcode `0x923` (`ISBERD`) are rejected. A short-lived upstream change
accepted both by translating reads and dropping writes, then was reverted. Dropping
`ISBEWR` is not valid: Mesa's NVK documentation shows that task shaders use it for
the emitted mesh-group count and payload, and mesh shaders use it for primitive
counts, indices and output attributes. A local diagnostic application of that
reverted change makes the two binaries pass instruction lowering only; it does not
provide the missing pipeline or establish correct rendering.

`dm/gfx/tools/nvn2_isbe.py` now decodes the Mesa-documented ISBE fields directly
from bounded 16-byte Ampere instructions, independently of the GPL experiment. In
the first task shader it finds two `ISBEWR.O.ATTR.B32` operations: one writes the
payload at a dynamic offset plus `0x10`, the other writes the emitted count at
offset `0x4`. In the first mesh shader it finds 42 ISBE operations: two input
attribute reads, two 32-bit output-map writes (initial and final primitive count),
32 skewed output-attribute writes and six 8-bit output-map index writes. This
concrete inventory rules out a write-dropping fallback and gives the native Metal
translator exact resource classes to model.

A bounded lowerer probe then replaced only those ISBE instructions with diagnostic
no-ops inside the external Eglantine workspace. With that single exclusion, the
task shader captures 19 Ampere instructions and lowers to 23 Maxwell instructions;
the mesh shader captures 582 Ampere instructions and lowers to 841 Maxwell
instructions. No second unsupported opcode appears in this first pair. This is not
executable output because the ISBE effects are deliberately absent, but it narrows
the translation blocker to the payload/count/attribute/index contract rather than
the rest of either program.

`dm/gfx/tools/nvn2_mesh_abi.py` converts the independent ISBE decode into a strict,
versioned neutral plan. It classifies the first pair as one task payload write, one
mesh-dispatch-count write, two mesh payload reads, two primitive-count writes, 32
skewed mesh-attribute writes and six byte-index writes. Unsupported directions,
memory widths and output domains fail instead of being dropped. The plan deliberately
does not choose Metal object/mesh versus compute scratch yet, so both implementations
must consume the same proven operation inventory.

The SKEW flag is layout selection, not an extra lane-number stride. Mesa's documented
layout packs 32 values of each active attribute into 128-byte lines, while the shader
has already calculated the packed address supplied to ISBE. The neutral plan therefore
retains `skew` as metadata and does not modify the shader-computed address.

`dm/gfx/tools/nvn2_ampere_bridge.cpp` is an optional GPL offline adapter built against
an external Eglantine checkout; neither Eglantine nor the adapter binary is linked into
or bundled with the MIT runtime. It substitutes each ISBE source operation with one
native NOP before ordinary lowering, then replaces the corresponding one-instruction
Maxwell NOP with a private read/write operation. Instruction count and relocated branch
distances stay unchanged. A leading Maxwell NOP aligns the compute scheduling phase
with the lowerer's graphics address model.

The production Ryujinx translator now recognizes those private operations and emits a
dedicated storage-buffer access. Its synthetic reflection identity is constant-buffer
slot 255, offset 65532, so it cannot be confused with one of the game's 16 storage slots.
One uint is reserved per logical ISBE byte: 8-bit primitive-index writes from adjacent
lanes cannot race through read-modify-write, while 16- and 32-bit values retain their
low bits at the same logical address. Five disjoint 64-KiB logical spaces hold task
payload, mesh dispatch values, primitive count, mesh attributes and mesh indices.

For the exact first pair, the restored unmodified Eglantine lowerer plus this adapter
produces 25 Maxwell instructions for task and 883 for mesh, retaining 2 and 42 ISBE
operations. Both programs translate to SPIR-V with no translator notes, pass
`spirv-val --target-env vulkan1.1`, convert to MSL, and compile with Xcode's Metal
compiler into separate 4.5-KiB and 17-KiB libraries. The reflected synthetic buffer is
read/write in both. This confirms compiler code generation; it is not yet a playable
pipeline because replay still needs per-workgroup scratch records, task-to-mesh group
expansion, indirect raster output and stage-6/7 resource binding.

The adapter must use scheduling slots relative to the end of the 80-byte Maxwell
header, as Ryujinx does, and relocate branches with the same layout. An earlier
absolute scheduling layout could compile while decoding the wrong instructions;
its results are superseded. Computed branches and all other archives remain unvalidated.
Turning off the default debug option additionally exposes an existing optimizer
bug: expression propagation replaces SPIR-V call arguments that must remain local
pointers (`GenerateCall`). No shared translator option was changed to hide it.

## Current Metal validation (2026-11-02)

The experimental task/mesh compute and raster adapters now execute. The current
chain is `20c79ed3433c`, with 884 captured shader libraries and profile input stamp
`99485007233a`; the default external profile includes these inputs and the measured
conditional-rendering setting. The user confirmed the corrected
loading-map picture. Neither shader coverage nor this loading picture establishes
gameplay, high-detail geometry correctness, or a finished app.

**Resolved early sparse-copy fault:** `probe-20261102-143117.log` identifies
nonresident native sparse textures in Metal copy operations immediately before the
GPU page fault around frame 117. The affected arrays are 8192 x 8192 x 68, with
Metal formats 194 and 151. Their last draw used vertex `f78677b6732eaccb` and
fragment `7ac775286e9829e5`, but that draw was not evidence of a shader-compiler bug.
Metal 4 pipelines, legacy pipelines without instrumentation, archive-disabled and
hybrid-disabled probes all reproduced the fault. A short instrumented run that
had no fault simply had not reached the same operation yet.

The shared fix uses [placement sparse resources on Metal 4 queues](../reference/rendering.md#placement-sparse-resources-on-metal-4-queues).
The isolated GPU check preserves all 65,536 bytes of a mapped tile. With the fix,
`probe-20261102-143537.log` runs 20 seconds with empty diagnostic mappings without
the early GPU error; `probe-20261102-143801.log` runs 45 seconds with real texture
data, reaches frame 145 and reports no GPU page fault or hang. It nevertheless
stops progressing there: time-limit termination is not a successful boot.

**Resolved cleanup deadlock:** the visible frame-143 and headless frame-145 stalls
were not evidence of memory exhaustion. `placement-sparse-stall.sample.txt` from
`probe-20261102-143927.log` shows a residency-set commit releasing a texture whose
heap-owner deallocator re-enters the same residency mutex. The shared fix defers
[sparse heap retirement during residency commits](../reference/rendering.md#sparse-heap-retirement-during-residency-commits).
`t_sparse_retirement` reproduces the delayed owner release and verifies that the
commit finishes and the backing heap leaves both residency tables.

**Confirmed cause of the guest CPU crash:** with both sparse fixes, `probe-20261102-144239.log` advances to
frame 166 without a reported GPU error, then exits with signal 11 at
`main+0x1ec460`, reading address `0x6240`. For main build
`9e244438c3d8ef1c703a6a85ef99c4f0`, the instruction is `ldr x9, [x9, #0x10]`:
the preceding load from `[x19+0x5830]` supplies `0x6230` where a pointer is expected.
This 11.69-second run peaks at
4,271.17 MiB RSS with at least 11,031.5 MiB available. Large sparse arrays retain
their native formats and all mip levels; full-quality data, not diagnostic empty
tiles, must be used for further visual tests.

`probe-20261102-145408.log` catches the watched pointer changing from a valid
address to `0x6230` immediately after the single dispatch of compute shader
`957a54bf6eeb6430` (frame 179); `probe-20261102-150024.log` reproduces it at
frame 180 with the API buffer bindings recorded. The CPU write watch reports no
store. The bridge confused native descriptor locations with compiler discovery
indices, and the reflection loader independently repeated that substitution.
See [native compute binding layout](../reference/shaders.md#native-compute-bindings-must-preserve-the-shaders-driver-layout)
for the shared mechanism and fix. A partial fix still failed in
`probe-20261102-150829.log`; both reflection generation and loading must preserve
the declared slots. With the complete fix, `probe-20261102-151144.log` runs
45.37 seconds, advances beyond frame 223 and retains the watched pointer, with no
reported GPU fault or the old CPU crash (peak 4,344.84 MiB, at least 10,496.17 MiB
available).

**Resolved black silhouettes and sky holes:** the next 105 captures expand the
inventory to 704 shaders. Using those same libraries, the conditional-clear A/B
in `probe-20261102-152227.log` shows six color clears skipped at frame 400 because
their counters are 0 / 0 after timestamp reports (type 16). Enabling the existing
`render_cond` profile contract restores the blue sky, removes the black corner
rectangle and reveals terrain, road and vehicles at frames 700/900. See
[conditional rendering](../reference/rendering.md#conditional-rendering-evaluated-at-replay).
This is measured evidence for the external profile key, not a copied Bananza preset.
The same-library scene still has pink/magenta materials and lighting.

**Later CPU crash, open:** `probe-20261102-152354.log` reaches frame 900 and then
faults at `main+0x3ec1d8`, reading through `x9 = 0x3f8000003f800000`. Main reads
the preceding pointer from `[x19+0x408]`, then `[x9+0x10]`. The float-like bits
suggest an overwritten pointer but do not identify the writer. This is distinct
from the resolved `main+0x1ec460` crash; the 26.09-second run peaks at 4,621.89 MiB
with at least 10,760.69 MiB available.

**Native compute translation:** seven of the 98 captured compute shaders still
had untraceable storage pointers after legacy lowering. The native frontend
retains their wide-address provenance and resolves all seven. The census now
translates all 98 after adding UBREV, MEMBAR.SC, ERRBAR and integer SURED; seven
programs additionally read native launch counts at c0+4/8/12, now mapped to the
host's canonical dispatch row. Full-library rebuild and runtime results must be
checked separately; these counts do not establish full-game shader coverage.

`probe-20261102-153521.log` uses all 704 rebuilt libraries on the native compute
route. It reaches present 2520 in 55.12 seconds with no CPU crash, GPU page fault
or hang, peaks at 5,034.70 MiB and retains at least 11,038.23 MiB available. Thus
the later crash did not recur on this route; its exact writer was not isolated.
The run captures another 180 shaders; the complete 884-library rebuild succeeds
with no unresolved resource bindings or unfillable driver reads. Colors remain
incorrect in the frame-700 screenshot. A single shader, `67a43fd738d8902b`, requests
49,152 bytes of shared memory, above this Metal device's 32,768-byte limit; its
pipeline remains unavailable. No memory truncation or lower-quality replacement
was enabled.

**Confirmed image dimension mismatch:** the instrumented headless probe
`probe-20261102-153945.log` reports 19 cases of a 2D-array texture bound to a 2D
image argument, in compute shaders `4eed355de892cbac`, `3c4418dd2645b188` and
`ec60b8d4b23eeef7`. The common image-binding path omitted the dimension adaptation
already present for sampled textures. The fix uses [compatible image views](../reference/rendering.md#compatible-views-for-a-mismatched-declared-texture-type),
preserving the selected subresource and backing. The GPU test passes 78 checks,
including writes through both 2D/array forms and readback of untouched mips/layers.
That instrumented run reached only present 120 in 56.76 seconds; it does not
validate the later scene or prove all other shader memory accesses correct.

With the compatible-view fix, `probe-20261102-154459.log` reaches present 360 in
60.63 seconds under instrumentation with no reported Metal validation error,
GPU fault or CPU crash (peak 4,620.03 MiB, at least 11,297.41 MiB available).
The uninstrumented `probe-20261102-155018.log` reaches present 2640 in 55.13 seconds,
peaks at 5,156.16 MiB and retains at least 14,281.08 MiB available. Its frame-2200
capture shows Mario and the circuit, but pink materials, lighting and terrain
holes remain. Scripted `A` at frame 1000 was delivered and released at 1004;
this does not establish menu selection or driving input.

**Confirmed sparse-copy data loss:** the resident-tile counter added to
`DM_NVN_ZBLOCK` finds millions of zero ASTC blocks on re-upload in
`probe-20261102-155616.log`. The bounded pass dump in
`probe-20261102-155812.log` shows earlier GPU copies into the same arrays:
627 level/slice copies each to textures 31570/31572 at frame 114, then streaming
copies into 31567/31569 around frames 142-160. Virtual pools were excluded from
copy mirroring, so a new mapping discarded those GPU-only updates. See
[GPU texture copies survive sparse remapping](../reference/rendering.md#gpu-texture-copies-survive-sparse-remapping).

The first corrected run, `probe-20261102-160524.log`, preserves the copied data:
at the last observed upload of texture 31567, zero blocks at levels 0/1/2 drop
from essentially all uploaded blocks to 0 of 4,194,304 / 1,048,576 / 262,144.
Smaller-level zero counts remain and require separate analysis. The 55.13-second
probe has no CPU crash or reported GPU fault, peaks at 5,649.78 MiB and retains
at least 9,755.84 MiB available. It also exposes excessive re-uploads of the
uncompressed sparse atlases 31487/31488 and reaches only present 360 by 47.50 s,
versus 14.18 s before the coherence fix. The initial absorption check compared
the global mapping generation; it now checks mappings within the texture's
range, with an unrelated-mapping regression case.

**Sparse-copy performance, measured:** `probe-20261102-161316.log` enables the
Metal HUD; the user observes about 5 FPS. Avoiding dirty stamps for identical
sparse writes, preparing each changed page once and transferring whole GOBs
reduces re-uploads. `probe-20261102-162233.log` reports 106.19 ms median frame
time through frame 300 (about 9.4 FPS), with only 12 re-uploads by present 360.
The user independently observes 9 FPS. A two-second CPU sample from
`probe-20261102-162433.log` identifies repeated pool searches and mapping-only
page walks; see [Sparse texture checks repeatedly scan every memory pool](../reference/frame-rate.md#sparse-texture-checks-repeatedly-scan-every-memory-pool).

With those lookup fixes, `probe-20261102-162845.log` measures 34.03 ms median
through frame 300, then 36.30 ms for frames 301-600 (about 27.5 FPS), with GPU
time 10.62 ms median in that second interval. Present 600 arrives at 28.50 s;
the user captures the Metal HUD at 27.27 FPS. The window becomes covered after
that interval, so later timing is not a valid foreground comparison. The
55.11-second run has no CPU crash or reported GPU fault, peak process RSS
5,146.92 MiB and at least 11,424.59 MiB available system memory. Process RSS is
not the complete GPU-inclusive footprint. Resolution, texture formats, mip
levels and shader quality settings were not reduced.

The user's screenshot still shows an almost black road and large rainbow bands,
with some vehicle color visible. Visual validation has not passed.
`probe-20261102-163035.log` captures frame 500 and its pass summary for follow-up.
The frame-500 target dump in `probe-20261102-163201.log` also has the dark road
in the 1328x748 HDR target 43921 before the final presentation; presentation or
window scaling alone cannot explain it. The dump converts HDR to clamped 8-bit
PNG, so brightness/color values in that image are not a quantitative HDR test.
The shader or input responsible for the material/lighting failure is still open.
Sparse mirroring passes 76 checks, the ordinary readback
paths pass 132/133 checks in the two completion modes, and dirty-range slot,
write-race and retirement checks pass. C compilation succeeds; the compile
database is generated, but clang-tidy is unavailable. No gameplay validation
is implied by the higher frame rate.

**Graphics comparison, analysis only:** the native frontend accepts 763 of 765
captured vertex/fragment programs; keys `646ed9812c712c0b` and `3a741d14e62cee94`
need UP2UR (0x883). These diagnostic outputs are not installed. Differences in
shadow texture declarations alone were not a missing comparison operation:
the legacy-lowered MSL still uses `spvDepthCast(...).sample_compare(...)`.

**Other confirmed validation defects:** compute shaders `45d86fa1411730f9` and
`184411d25e7fb2c0` read beyond their bound allocations, and `957a54bf6eeb6430`
writes beyond one. Several compute pipelines bind 2D textures where arrays are
expected, or the reverse. Their causes remain open. Compute pipeline labels now
carry the shader key, and `MTL_SHADER_VALIDATION_REPORT_TO_STDERR=1` preserves the
reports alongside the probe log. Enabling validation changes execution timing;
compare reached frames and operations, not elapsed seconds alone.

## Comparison with Donkey Kong Bananza and Eglantine

### Follow-up runtime inventory, 2026-11-02

`probe-20261102-193036.log` uses chain `20c79ed3433c`, profile input digest
`d85d2953abac`, and the current 886-entry shader map. With `--native-sparse`,
the visible 45.18-second probe reaches at least present 960, peaks at
5,173.73 MiB process RSS, and retains 14,971.05 MiB available system memory.
The supervisor stops it at the time limit; no CPU crash or GPU fault is
reported. Its missing-shader capture directory is empty. All 886 base
reflection files have a corresponding Metal library. This establishes only
coverage of this startup route; the user still reports incorrect environment
rendering.

The current inventory contains one base shader requesting more than 32 KiB
of threadgroup memory: `67a43fd738d8902b`, at 49,152 bytes. The runtime still
reports pipeline creation failure for that size. Its MSL has 12,288 shared
uints and data-dependent shared-memory reads; reducing its allocation is not
validated. The earlier 599-shader rebuild from `profile-stage-124908` and
chain `4283a035dfac` used an older checkout/profile and cannot establish that
this failure is fixed. The current environment/material defect remains open.

`probe-20261102-193131.log` enables Metal shader validation but spends its
30-second budget before a logged presentation. Its zero validation-error
count is not evidence about the scene's shader accesses.

**Confirmed diagnostic crash:** disabling pipeline prewarm lets shader
validation reach the scene. `probe-20261102-193325.log` exits with signal 5
inside `MTL4GPUDebugCommandBuffer applyResidencySets:` after present 120,
with 4,091.61 MiB peak RSS and 16,505.34 MiB minimum available memory.
The zombie diagnostic `probe-20261102-193442.log` identifies a message to a
deallocated `MTLGPUDebugHeap` (`enumerateBufferIndices:`), after frame 131.
Its peak RSS is 4,231.27 MiB; this is not a memory-reserve termination.
See [sparse heap retirement](../reference/rendering.md#sparse-heap-retirement-during-residency-commits)
for the fence-delayed lifetime fix and focused test. The follow-up targets
presentation 600, with memory/output limits retained instead of a fixed
wall-clock cutoff. This change does not establish correct environment rendering.

The regression harness was attempted for MKW alone because the changed path
is native sparse-heap retirement, observed here. It cannot discover this
extracted-game build as a registered Mac build. Its result is incomplete;
the focused production-code test and supervised MKW run provide the local
validation, not a five-game regression claim.

**Fence-retention follow-up, still open:** `probe-20261102-193652.log` uses
the candidate host that retains retired sparse heaps until the next submission
fence completes. The focused lifetime test passes with Metal API validation.
The live shader-validation run passes frame 167 but exits with signal 6 after
120.20 seconds: `MTLGPUDebugBuffer enumerateBufferIndices:` is an unrecognized
selector inside MetalTools' `HeapUsageTable::processHeapEntry`, called from
`present_now`. Peak process RSS is 4,224.89 MiB and minimum available memory
is 10,430.70 MiB. The candidate therefore does not resolve the complete
validation-layer lifetime failure. Presentation/queue-side references still
need investigation; do not call this a validated crash fix.

The same candidate without shader validation, `probe-20261102-193915.log`,
reaches the explicit 1,200-presentation target and exits gracefully after
50.37 seconds. Peak process RSS is 5,241.81 MiB; minimum available system
memory is 10,304.22 MiB, above the 8,192 MiB reserve. No CPU crash, GPU fault
or hang is reported. Six previously unmapped shaders are captured:
`12fd0645ddbafe6a`, `28b6b5fba6bcae14`, `a6a4dc1ac8465e9f`,
`b197aeb30126c01b`, `c675b7627e6caae1`, and `ca9b078b2be89f20`. The 48-KiB
compute-pipeline failure persists and visual correctness is not established.

The six captures were merged into `profile-stage-1940` and rebuilt into
`shaders-stage-1940`: 892 shaders, chain `20c79ed3433c`, inputs
`6653c7068a80`, with no unresolved bindings or unfillable driver reads.
`probe-20261102-194131.log` then reached 1,440 presentations and stopped
normally after 214.6 seconds, without a CPU crash or reported GPU fault/hang.
Peak process RSS was 6,174.94 MiB and minimum available system memory was
8,969.59 MiB, above the configured 8,192 MiB reserve. These RSS numbers do
not represent total unified-memory resource allocation.

Visual inspection of presentation 1,000 confirmed the title logo; presentation
1,400 confirmed the actual mode menu, with four left-side mode icons and the
three lower shortcuts after the scripted A input. Both captures show severe
rainbow bands, incorrect materials and background corruption. Reaching the
menu is confirmed; correct rendering and gameplay are not. Additional missing
shaders were captured and the 49,152-byte compute shared-memory rejection
persists. Window occlusion delayed presentation independently of logic frames.
The two screenshots were analyzed and then removed from the capture directory;
this text retains their findings without retaining large image attachments.

The 173 subsequent captures were merged into `profile-stage-menu173` and
`shader-capture-package-menu173`; `shaders-stage-menu173` built all 1,065
shaders successfully (892 cache hits, 173 rebuilt), inputs `293f25bca52d`.
No unresolved binding slots or unfillable driver reads were reported.
`probe-20261102-195100.log` reached 1,800 presentations in 102.82 seconds,
with peak process RSS 5,314.20 MiB and minimum available system memory
9,012.56 MiB. No CPU crash or GPU fault/hang was reported; validation was
not enabled. Presentation 1,400 shows the mode menu with rainbow corruption
in the live 3D background; presentation 1,750, after another A input, shows
the next menu's recognizable static Mario artwork and mode icons, but no
readable option labels. This separates intact static artwork from the broken
live scene; it does not establish correct colors in gameplay. Both screenshots
were inspected and sent to Trash after recording these findings.

The oversized compute allocation is present in the original compact control
section (`+0x58`: 64, 1, 1, 49152); original LDS/STS access shared memory.
The shader indexes 48-byte records using `64 * group.x + local.x` and reads
uniform-selected records. Existing binding traces show one workgroup, but
do not prove a smaller valid memory extent. Full per-workgroup device-memory
backing is a candidate platform adaptation, not implemented or validated.
Its barrier inside a conditional loop also needs participation analysis before
enabling that pipeline. Neither this allocation failure nor that barrier risk
has been proven to cause the scene-wide rainbow corruption.

Navigation captured another 212 shaders. `shaders-stage-menu212` builds all
1,277 successfully, inputs `94432def57e6`, but its baseline run
`probe-20261102-195637.log` reports a GPU hang at frame 668 (segment 1,
three dispatches), after the last presentation checkpoint at 600. Peak RSS
was 4,975.53 MiB, minimum available memory 9,853.19 MiB; this was not a
memory-reserve stop. A thread sample shows the guest waiting in `mtl_wait_at`.
The failed process group was stopped after Metal reported the hang. No planned
menu screenshots were reached. The four added compute shaders are
`2261bd5da118b167`, `5fe4d3ed59af451a`, `54e05f72e4a7efea`, and
`ec66ac9e7aa3e2d0`; none requests shared memory. Causality is not isolated.
The 1,065-shader library remains available for controlled comparisons.

The one-draw key dump in that run confirms `433f1007e575367e` samples two
32x32x32 volume textures at fixed slots 2/3 (serials 31498/31499), alongside
the scene, depth and bloom textures. Inspect color-pass inputs/outputs and
volume coordinates before attributing the bands to video decoding. No movie
or codec activity is logged on this route, while earlier captures show live
depth-tested geometry. Static menu artwork is not evidence of 3D correctness.

Upstream was checked through `65501fbb`. The confirmed
[pending-clear ordering fix](../reference/rendering.md#pending-clears-land-before-a-compute-dispatch)
was ported narrowly and passed its focused GPU regression; its MKW visual
effect is being tested with the prior 1,065-shader library. The upstream
primitive-ID and bindless-array fixes are not established causes here: no
base MSL in the 1,277 set uses `[[primitive_id]]`, and this color pass uses
fixed volume bindings. AV1 decoding additions do not establish a movie-path
failure in MKW. No blanket rebase or merge was performed.

The clear-order candidate run `probe-20261102-195921.log` ends with guest
`CRASH sig=11 addr=0 pc=0 lr=main+0x19e77a0`, at 58.26 seconds after the
presentation-360 checkpoint, peak RSS 4,165.05 MiB. The preceding host saved
as `tools/dmhost-before-clear-order-20261102`, with the same 1,065 libraries,
then reaches 1,800 presentations in `probe-20261102-200053.log` (81.61 seconds,
RSS 5,453 MiB, available-memory minimum 8,373.84 MiB). Its frame-1400 capture
still has severe color bands; screenshots were removed after retaining that
finding. This single A/B does not establish the crash's writer or prove the
clear-order fix unsafe, but the candidate is not validated for the game.

The five-game regression attempt selected Wonder, Breath of the Wild, Mario
Kart 8 Deluxe, Super Mario 3D World and Metroid Dread to cover shared NVN
clear/compute semantics. The harness's stored revision `5474c6f34789` fails
its Metal compiler lock (32023.921 expected, 32023.922 installed); it did not
validate this dirty working-tree candidate. See external report
`0400C3F00006E000-work/regress/reports/20261102-200001-chain/report.md`.

**Confirmed color-path translation defect:** `433f1007e575367e` has three
scalar 3D TEX instructions whose coordinates are R6/R7/R11. The external
bridge named `nvn2_ampere_bridge-fixed` lowers the third source to R8 (fog),
not R11 (processed blue), while the native frontend preserves the intended
RGB dataflow. See [scalar TEX register blocks](../reference/shaders.md#scalar-ampere-tex-operands-split-between-register-blocks).
Offline reproduction is retained under external `analysis/433f-readonly-20261102-195804`.
This establishes a real defect in the color pass, not that all visual errors
or the separate compute hang have been solved. A general corrected bridge
and a fresh complete library must be validated in the actual menu.

The corrected bridge uses a non-mutating overlay over Eglantine `f6d03bc`.
Fourteen decoder/build-provenance tests pass, none skipped, including paths
with spaces and fail-closed handling of unfamiliar source layouts. The six
TEX source lists in the color pass agree with native decoding. Reconstructing
the earlier contiguous-coordinate variant reproduces all 765 saved outputs;
the corrected bridge preserves 436 and changes 329, all lowered successfully.
Chain `23cf57c7d452` includes the overlay helper and is being rebuilt with
the 1,065-shader profile in `shaders-stage-colorfix`. No runtime success is
implied by these offline checks.

**Color-fix runtime checkpoint:** the full 1,065-shader build completes with
zero unresolved binding slots or unfillable driver reads, followed by the
matching host rebuild. `probe-20261102-200856.log` reaches 1,800 presentations
in 86.06 seconds without a CPU crash or reported GPU fault/hang. Peak process
RSS is 4,386.75 MiB; minimum available system memory is 10,306.83 MiB.
Metal shader validation was not enabled. Frame 1,400 shows recognizable
Mario/kart colors, road texture and tree trunks, with substantial improvement
over the previous scene-wide bands. Background surfaces and foliage still
have pink/cyan/rainbow corruption; menu option labels remain absent. Frame
1,750 shows the recognizable static mode-menu illustration with the same
missing labels. Both images were inspected and sent to Trash.

This candidate includes the pending-clear fix too; no single-change visual
effect size is claimed. The color-pass register defect is independently
confirmed offline. The 48-KiB rejection persists, the 212-shader expansion's
GPU hang remains unresolved, and no race/controller/save-load validation has
passed. Next work stays on remaining colors/materials and labels before HDR,
performance or RTX. No application was packaged, installed, committed or pushed
for this checkpoint.

[Bananza's game note](../../dm/games/040074A01BF12000/README.md) records Mac
gameplay on an M4 Pro, including the opening and mining tunnel; this investigation
has not rerun Bananza. Its SDK is 20.5.19, whereas this MKW dump is 19.3.3.
The useful common contracts and the differences are:

| Area | Evidence and application to MKW |
|---|---|
| Compute descriptors | Bananza's 205 compute shaders established the per-shader c0 layout used by `InstEmitAmpere.AMapC0`. The optional MKW bridge bypasses that frontend, so it now carries the same native layout through reflection and replay. This fixes a shared NVN2 contract, not a title-specific slot table. |
| Texture tiling | Bananza documented the Switch 2 GOB ordering. MKW's external profile already selects `texture_gob_layout nx2`; do not revert to the Switch 1 layout. |
| Upscaling and shader loading | Bananza exercises shared push constants, the native frontend's HMMA upscaler translation, shader prefetch and persistent pipeline lists. MKW must preserve its actual shader operations and validate its own output; Bananza's measurements do not establish MKW performance or bridge equivalence. |
| Geometry | Bananza's documented geometry pair uses the existing geometry-to-mesh path. MKW also has native task/mesh stages with ISBE payloads; that distinct execution contract still needs its own validation. |
| Memory and conditional rendering | Bananza has no system resource and explicitly needs conditional clears. MKW declares a 64 MiB system resource and uses virtual mappings. Its own pass-dump A/B now confirms the same conditional-clear contract. Do not copy Bananza's heap sizes, fixed addresses or patches. |

Eglantine's `BufferCache::BindComputeStorageBuffer` reads the descriptor from the
original compute launch's constant-buffer address plus the translator's source
offset. It therefore does not substitute an NVN API slot from compiler discovery
order. This source comparison explains why our binding bug is specific to this
adapter; it does not establish that the same MKW build reaches gameplay in either
Eglantine or an Eden fork. No side-by-side gameplay run was performed.

**Regression scope:** native placement sparse remains opt-in, so this change's
runtime validation targets MKW. `regress.py check --games 0400C3F00006E000 --jobs 1
--quick` was attempted with the external harness root and game folder; the harness
cannot discover this extracted provisional build and exits with an error. The
standalone Metal check and bounded probes are the current evidence, not a harness
pass or validation of other games.

The native-compute update also attempted the required five-local-game check
(Wonder, Luigi's Mansion 3, Breath of the Wild, Crash N. Sane Trilogy and CTR),
with one worker and no smoke launches. Report
`regress/reports/20261102-153928-chain/report.md` records five errors before
comparison: baseline `5474c6f34789` locks Metal 32023.921, whereas this Mac has
32023.922. The current chain is locked to the installed compiler; silently
relaxing the baseline's requirement would not establish the requested baseline.

## Earlier validation and remaining work

### Native compact graphics rebuild, 2026-11-03

The full shader inventory used by the validated app is derived from
[`pahorema/kartnative` at `47f2d1d5`](https://github.com/pahorema/kartnative/tree/47f2d1d5c8298a562190dd0493da8a4eb18e4626/dm/games/0400C3F00006E000):
its 11,567-entry `shader_map.tsv`, 5,176 shader pairs and 6,524-entry pipeline
manifest match the packaged tables byte for byte. The NXNative integration layer
adds `native_sparse on`, `texture_gob_layout nx2` and `shader_abi nvn2`, records
the runtime shader facts, and regenerates `c1_full.tsv` and `cb_extent.tsv` from
the resulting libraries. Keep that provenance when contributing the profile;
the external inventory and note are not independent work from this branch. The
general sparse-texture, compact-control, Ampere translation and synchronization
fixes remain changes to NXNative itself and apply beyond this profile.

The complete 11,567-shader KartNative-derived inventory exposed a bridge-only
failure before any new library stamp was written: fragment shader
`0203f1e1c31ab456` contains native opcode `0xd08`, which the optional
Ampere-to-Maxwell lowerer does not implement. The in-repo Ampere frontend accepts
that shader and compiles its base, alpha-test and logic-operation Metal libraries.
It also compiles vertex shader `6ad7fe08b687cba5`, its paired fragment shader and
the vertex-pulling variant. Their resource and attribute slots agree with the
older bridge reflections, with no unresolved binding or unfillable driver read.
Compact vertex and fragment therefore take the shared native route now; only task
and mesh retain the adapter needed for their private ISBE ABI. See
[compact NVN2 graphics](../reference/shaders.md#compact-nvn2-graphics-uses-the-native-ampere-frontend).

A fresh full build on chain `de1663f1a7c5` is required before rebuilding the host.
Its result is not recorded as complete here until all 11,567 base shaders, the
profile-input stamp and generated extent tables exist. The current reference app
still shows objects that appear and disappear. That visual defect remains open:
the native graphics rebuild must be tested first, then sequential-frame evidence
must distinguish shader output from task/mesh expansion, indirect draws,
conditional rendering and visibility/query state.

### Interactive race and decoder synchronization, 2026-11-03

The packaged Mac app reaches an interactive race through Grand Prix, Luigi,
Mushroom Cup, 50 cc and Mario Bros. Circuit. The user played it normally and
reported more than 60 fps and behaviour matching the KartNative reference. This
is a gameplay validation of that route, not a controlled benchmark, a long-session
pass or an iOS result.

Before the fix, entering the race waited indefinitely in the movie/scene handoff.
The SDK 20.5 decoder type keeps its submission-ready event at +8, while the host
used the SDK 22 host-reserved offset. More importantly, a newly registered output
buffer must enter both the acquire queue and the fill queue with a pending
generation-1 sync handle: the first submitted picture fills and signals it without
a preceding release. `CancelSyncPointEvent` signals while disarming the waiter; it
does not clear it. The shared decoder fix and its sanitizer test are documented in
[`nn::codec` video decoders taken over](../reference/movies.md#nncodec-video-decoders-taken-over).

Three performance candidates were rejected and are not defaults: the encode thread
made this route slower, reporting six Switch 2 cores did not improve it (the game
already made its workers), and disabling the present thread's time-constraint policy
did not improve the frame time. Their temporary host/profile changes were reverted.
The successful app contains the decoder correction and the existing graphics work;
it does not depend on any of those candidates.

### Resume checkpoint, 2026-11-02 20:45

`probe-20261102-204542.log` uses host chain `23cf57c7d452` and the
1,065-shader color-fix library, with native sparse textures and no scripted
controller input. It reaches logged presentation 600 before the supervisor
stops at the system-memory reserve: minimum available memory 7,956.02 MiB
against an 8,192-MiB reserve, peak process RSS 5,741.23 MiB, 46.19 seconds.
No CPU crash or reported GPU fault/hang occurs. The requested frame-1400
capture is not reached; this run establishes no new visual improvement.
Process RSS is not total unified-memory usage. An initial attempt with the
older `tools/dmhost` was terminated after its chain mismatch was detected;
that attempt is not a graphics comparison.

This startup route captures 241 shaders absent from the color-fix map;
26 already exist in the separate 212-shader expansion, leaving 215 new to
both inventories. They are merged into the isolated external
`profile-stage-resume241` and `shader-capture-package-resume241` (1,306
entries). The 49,152-byte compute-pipeline rejection remains open.

The shorter baseline, `probe-20261102-205137.log`, reaches its 600-present
target in 31.67 seconds with peak RSS 4,117.05 MiB and minimum available
memory 10,042.59 MiB, without a CPU crash or reported GPU fault/hang.
Frame 500 shows the title logo over a recognizable road and Mario/kart;
very bright yellow and pink background surfaces remain to be compared.
It is an attract/title scene, not an interactive race or the mode menu.
The screenshot was inspected and moved to Trash. The shader expansion was
compiling concurrently, so this run is not a clean performance benchmark.

The expanded library completes all 1,306 base shaders on chain
`23cf57c7d452`, inputs `02a814a20035`, with no unresolved binding slots or
unfillable driver reads; the matching host build succeeds. The new captures
comprise 69 vertex, 165 fragment and 7 compute shaders, none of the new compute
facts requesting more than 32 KiB shared memory. `probe-20261102-205711.log`
reaches 600 presentations normally, peak RSS 4,655.52 MiB and minimum available
memory 10,692.09 MiB, without a CPU crash or reported GPU fault/hang.
Frame 500 shows recognizable road, grass and kart, but bright yellow-white
trees and pink surfaces remain. The attract scene differs from the baseline,
so the images do not establish the expansion's visual effect. This image was
also inspected and moved to Trash.

`probe-20261102-205813.log` then plays `f1000:A~f3` and reaches the actual
mode menu at captured frame 1,400. It stops normally at logged presentation
1,560 (target 1,500), in 66.62 seconds; peak RSS 4,963.55 MiB, minimum
available memory 9,714.66 MiB. No CPU crash or reported GPU fault/hang occurs;
Metal shader validation is not enabled. The menu's road, kart, barriers and
buildings are recognizable, while pink/cyan background bands, bright objects
and missing option labels remain. The capture was analyzed and moved to
Trash. This is menu/probe validation only, not race, controller, save-load or
normal packaged-launch validation. The 48-KiB pipeline failure persists.

The two registered Switch 2 references are
[Bananza](../../dm/games/040074A01BF12000/README.md) and
[Splatoon Raiders](../../dm/games/0400380020056000/README.md).
Bananza's native Ampere interpolation, half-texture results and scoreboard
semantics are relevant comparison targets for missing MKW labels; similarity
of the symptom does not establish the same defect. Splatoon's
[first-invocation store](../reference/shaders.md#a-store-only-a-dispatchs-first-invocation-makes)
fix already exists in the shared builder, but none of the 1,065 baseline
reflection files contains a `first_store` entry. Do not transplant either
game's heap constants, build addresses or profile switches into MKW.

- Targeted Python and sanitizer checks cover source identity, SDK versions, jump
  analysis and compact-control bounds.
- Memory SVC tests pass with map accounting on/off and 16 KiB host pages.
- The queue/program GPU test passes 438 checks in each of the direct and deferred
  encoding runs; the capture test passes 83 checks and operating-environment tests
  pass 53 checks. The Metal object/payload/mesh test validates 16 pixels and the
  bounded ISBE decoder and neutral mesh ABI planner pass six focused unit tests. The
  first translated task/mesh pair additionally passes SPIR-V validation and Metal
  compilation as two isolated compute-stage libraries.
- Five-game `regress.py check --quick --no-smoke --jobs 1` was attempted for Wonder,
  Luigi's Mansion 3, Breath of the Wild, Crash N. Sane Trilogy and CTR. All stopped
  before comparison because Xcode 27.2's Metal 32023.922 differs from the locked
  32023.921 compiler. This is an incomplete regression run, not five passes.
- Targeted ruff and pyright checks pass for the new source/probe scripts and tests.
  The full Python lint ratchet reports nine findings in pre-existing files outside
  these changes; none names a newly added file. C lint cannot run without clang-tidy.

The earlier native boot reached resource loading, texture/program creation, audio
initialization, logged frame presentations and the first mesh-task draw. No game
picture was validated at that stage: the runtime shader libraries were incomplete.
The earlier bounded run, `probe-20261102-065618.log`, passed the former
`main+0x16d72f4` null-call crash and reached the explicit
`DrawMeshTasks(first=0, count=1)` stop with the same three shader keys. The stop now
identifies the absent translated task and mesh libraries separately. Its supervisor
observed 2,561 MiB group RSS before terminating the process at the 2,048 MiB limit;
macOS reported a 2,798 MiB child high-water mark during shutdown.
The current dump importer recognizes 28 captured shaders, including task and mesh;
recognition is not translation or rendering. The diagnostic shader-dump option
stops above 64 MiB per run.

Remaining work includes validating the task/mesh adapter's output, the outstanding
compute-memory defects and shared-memory limit, sparse-copy performance and
remaining material/geometry defects, the remaining NVN2 command surface and complete
bounded AOT shader extraction. Selection, controller and one race now pass on the
Mac; normal launcher repetition, save-load, longer races/sessions and iOS remain
required before calling the self-contained app supported. Do not add this title to
the playable gallery from the single validated route.
