# Mario Kart World: native Switch 2 bring-up

Status: experimental, not a supported or playable game. No release app, gameplay,
controller, save-load or iOS validation has passed. The provisional profile and all
game-derived outputs stay beside the user's extracted game, outside this repository.

## Reproducible source preparation

`scripts/prepare_extracted_game.py SOURCE --name "Mario Kart World" --prepare-code --workers 1`
accepts an ExeFS/RomFS pair, including a pair under `base/`. It validates the META/ACI0
identity and NSO inputs, inventories assets without copying them, derives a local
profile and reuses the existing rewriter and Mac host builder. It does not convert
a Switch 2 program into a Switch 1 program, nor infer a retail version from the
local `v0` work slot. A changed source needs a separate work directory.

`scripts/probe_extracted_game.py WORK --seconds 15 --max-rss-mib 2048` runs the host
with a time, memory and log limit. It stops the whole process group and keeps the
log and a JSON report. These are headless diagnostic runs, not gameplay tests.

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
   modules rewrite. See [register namespaces](../reference/rewriter.md#simd-writes-do-not-clobber-gpr-jump-indices).
2. The host and profile guesser missed the `Generic_` SDK prefix. Both now identify
   SDK 19 without reading past the marker's bounds.
3. SDK `+0x14aa08` asks GetInfo(33) for its physical mapping granule and passes that
   value straight to MapPhysicalMemory. Returning zero caused Result `0xd401`.
   The host now reports its 4 KiB guest mapping granule; the SDK initializes.
4. The ordinary Switch 1 profile did not fit this game's memory layout. Main
   `+0xcf25b4` reserves a fixed `0x1bd600000`-byte region. The external provisional
   Mac profile currently reserves 16 GiB of alias VA and 8.5 GiB of heap VA, with a
   10 GiB logical application pool and map-limit accounting. Virtual reservation
   is not resident RAM; probes still stop above 2 GiB RSS. This is not an iOS layout.
5. Main `+0xcf3b20` requires NVN API 231.16. The external profile requests that API
   for diagnosis only. Reporting it does not establish full NVN2 compatibility.
6. Secondary-queue setup calls `nvnQueueBuilderSetPrimaryQueue`. The host records
   that relationship while retaining independent replay state and serialized
   Metal execution. Cross-device and self-primary queues are rejected.
7. NVN2 uses ProgramBuilder and compact 201.7/201.11 shader control sections. Their
   control length is at `+0x30`, padded code span at `+0x40`; the observed controls
   are usually 216 bytes. A bounded census of four shader archives checked 20
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

## Validation and remaining work

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

The native boot has reached resource loading, texture/program creation, audio
initialization, logged frame presentations and the first mesh-task draw. No game
picture is validated: the runtime shader libraries are still incomplete. The
latest bounded run, `probe-20261102-065618.log`, passed the former
`main+0x16d72f4` null-call crash and reached the explicit
`DrawMeshTasks(first=0, count=1)` stop with the same three shader keys. The stop now
identifies the absent translated task and mesh libraries separately. Its supervisor
observed 2,561 MiB group RSS before terminating the process at the 2,048 MiB limit;
macOS reported a 2,798 MiB child high-water mark during shutdown.
The current dump importer recognizes 28 captured shaders, including task and mesh;
recognition is not translation or rendering. The diagnostic shader-dump option
stops above 64 MiB per run.

Remaining
work includes a real task/mesh pipeline (Metal object+mesh functions, or a correct
compute plus indirect-draw emulation), `ISBERD`/`ISBEWR` semantics and reflection,
the remaining NVN2 command surface, complete bounded AOT shader extraction and
actual Metal rendering. Only then can a self-contained signed `.app` and normal
launcher validation be produced. Do not add this title to the playable gallery
based on these probes.
