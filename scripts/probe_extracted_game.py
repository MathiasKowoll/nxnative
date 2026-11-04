#!/usr/bin/env python3
"""Run an extracted game's diagnostic host with time, RSS and log limits.

The process group is always stopped on timeout, excess memory/logging, or Ctrl-C.
This is a headless bring-up probe, not a playability test or app installer.
"""
import argparse
import json
import os
from pathlib import Path
import resource
import re
import signal
import subprocess
import sys
import time


def process_rss(pid):
    rows = [tuple(map(int, line.split())) for line in subprocess.check_output(['ps', '-axo', 'pid=,ppid=,rss='], text=True).splitlines()]
    owned = {pid}
    while True:
        children = {p for p, parent, _ in rows if parent in owned} - owned
        if not children: break
        owned |= children
    return sum(rss for p, _, rss in rows if p in owned) * 1024


def available_memory():
    """Conservative reclaimable system memory in bytes.

    On macOS, free + inactive + speculative pages can be reused without
    swapping. Purgeable pages are deliberately omitted because they may
    overlap another VM category. Linux exposes the equivalent directly.
    """
    if sys.platform == 'darwin':
        text = subprocess.check_output(['vm_stat'], text=True)
        page = re.search(r'page size of (\d+) bytes', text)
        values = {m.group(1): int(m.group(2).replace('.', '')) for m in re.finditer(r'^([^:]+):\s+([\d.]+)\.$', text, re.M)}
        if not page: raise RuntimeError('vm_stat did not report its page size')
        return int(page.group(1)) * sum(values.get(name, 0) for name in ('Pages free', 'Pages inactive', 'Pages speculative'))
    if sys.platform.startswith('linux'):
        text = Path('/proc/meminfo').read_text()
        match = re.search(r'^MemAvailable:\s+(\d+) kB$', text, re.M)
        if match: return int(match.group(1)) * 1024
    return None


def stop(process):
    # The group may outlive its leader; always address the group we created.
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except (ProcessLookupError, PermissionError):
        process.wait()
        return
    try:
        process.wait(timeout=2)
        return
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass
    process.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('work', type=Path)
    parser.add_argument('--seconds', type=int, choices=range(1, 61), default=15)
    parser.add_argument('--until-present', type=int,
                        help='stop at this logged presentation instead of the wall-clock budget; memory and output limits remain active')
    parser.add_argument('--host', type=Path,
                        help='diagnostic host executable (default: WORK/tools/dmhost)')
    parser.add_argument('--shader-dir', type=Path,
                        help='diagnostic library root containing b-CHAIN (default: WORK/run/msl)')
    parser.add_argument('--progress-timeout', type=int, default=300,
                        help='with --until-present, stop after this many seconds without new log output (default: 300)')
    parser.add_argument('--max-rss-mib', type=int,
                        help='optional hard process-group ceiling; by default only the system reserve is enforced')
    parser.add_argument('--min-available-mib', type=int, default=8192,
                        help='stop before conservative available system memory falls below this reserve (default: 8192)')
    parser.add_argument('--shader-dump', action='store_true', help='preserve missing shader inputs, bounded to 64 MiB per probe')
    parser.add_argument('--shader-keys', help='comma-separated 16-hex shader keys to capture even when already mapped')
    parser.add_argument('--profile-dir', type=Path,
                        help='diagnostic profile directory containing shader_map.tsv (default: WORK/profile/TITLE_ID)')
    parser.add_argument('--visible', action='store_true', help='open the game window while retaining all probe limits')
    parser.add_argument('--metal-hud', action='store_true',
                        help='show the Metal performance HUD in the visible game window')
    parser.add_argument('--capture-frames', metavar='FRAMES',
                        help='save at most eight rendered-frame images for graphics diagnosis (comma-separated frame numbers)')
    parser.add_argument('--capture-targets', type=int, metavar='FRAME',
                        help='diagnostic: save the color render targets of one positive frame')
    parser.add_argument('--capture-target-snapshots', metavar='PASS_INDICES',
                        help='with --capture-targets, save attachments after comma-separated in-frame render-pass indices')
    parser.add_argument('--capture-raw-textures', metavar='SERIALS',
                        help='with --capture-targets, save raw level-0 bytes for comma-separated texture serials')
    parser.add_argument('--zero-blocks', action='store_true',
                        help='diagnostic: log zero ASTC blocks during CPU texture uploads')
    parser.add_argument('--keys', metavar='DM_KEYS',
                        help='script controller input during a visible probe (same syntax as the host DM_KEYS setting)')
    parser.add_argument('--quiet-svc', action='store_true',
                        help='omit verbose system-call tracing for a lower-overhead play-through probe')
    parser.add_argument('--profile-performance', action='store_true',
                        help='collect dropped-frame, NVN recording, replay-phase and wait diagnostics')
    parser.add_argument('--allocation-profile', action='store_true',
                        help='log large Metal allocations and their replay operation for memory diagnosis')
    parser.add_argument('--native-sparse', action='store_true',
                        help='diagnostic: enable native sparse texture backing for every supported texture')
    parser.add_argument('--native-sparse-serials', metavar='SERIALS',
                        help='diagnostic: use native sparse textures only for these comma-separated decimal texture serials')
    parser.add_argument('--native-sparse-empty', action='store_true',
                        help='diagnostic: bind native sparse textures with every tile unmapped')
    parser.add_argument('--native-sparse-empty-serials', metavar='SERIALS',
                        help='diagnostic: leave only these comma-separated sparse texture serials unmapped')
    parser.add_argument('--native-sparse-no-upload', action='store_true',
                        help='diagnostic: map native sparse tiles but do not upload texels')
    parser.add_argument('--native-sparse-zero-upload', action='store_true',
                        help='diagnostic: map native sparse tiles and upload zero-filled texels')
    parser.add_argument('--mesh-trace', action='store_true',
                        help='log bounded NVN2 task/mesh replay ranges and shader keys')
    parser.add_argument('--sparse-lifetime', choices=('log', 'keep'),
                        help='diagnostic: log sparse heap releases, or temporarily keep every heap alive')
    parser.add_argument('--no-mesh-raster', action='store_true',
                        help='diagnostic: run translated task/mesh compute but skip the native raster adapter')
    parser.add_argument('--mesh-raster-mode', type=int, choices=(1, 2),
                        help='diagnostic: rasterize only task/mesh mode 1 or direct-mesh mode 2')
    parser.add_argument('--direct-raster-keys', metavar='KEYS',
                        help='diagnostic: with mode 1 intact, rasterize only these comma-separated direct-mesh keys')
    parser.add_argument('--task-raster-keys', metavar='KEYS',
                        help='diagnostic: with mode 2 intact, rasterize only these comma-separated task shader keys')
    parser.add_argument('--safe-raster', action='store_true',
                        help='diagnostic: use a scratch-free NVN2 raster adapter')
    parser.add_argument('--no-task-mesh', action='store_true',
                        help='diagnostic: skip all NVN2 task/mesh replay')
    parser.add_argument('--watch-stall', type=int, choices=range(2, 60),
                        help='dump guest/GPU wait state and stop after this many seconds without progress')
    parser.add_argument('--watch-sample', type=Path,
                        help='write a one-second macOS thread sample when --watch-stall fires')
    parser.add_argument('--fence-trace', action='store_true',
                        help='log each Metal submission and completion for GPU-stall diagnosis')
    parser.add_argument('--no-segment', action='store_true',
                        help='disable mid-submission GPU cuts for a controlled stall comparison')
    parser.add_argument('--segment-draws', type=int, choices=range(1, 65),
                        help='cut a diagnostic Metal segment after this many draws')
    parser.add_argument('--split-draws', action='store_true',
                        help='diagnostic: submit every encoded draw separately')
    parser.add_argument('--wait-segments', action='store_true',
                        help='diagnostic: wait for each segment and stop at its first GPU failure')
    parser.add_argument('--residency-check', action='store_true',
                        help='diagnostic: report shader resources absent from the residency set')
    parser.add_argument('--legacy-pipelines', action='store_true',
                        help='diagnostic: compile pipelines through MTLDevice without Metal 4 specialization')
    parser.add_argument('--no-pipeline-archive', action='store_true',
                        help='diagnostic: compile pipeline bases without loading or writing disk archives')
    parser.add_argument('--no-pipeline-prewarm', action='store_true',
                        help='diagnostic: compile only encountered pipelines so validation can reach the scene within the probe budget')
    parser.add_argument('--no-hybrid-pipelines', action='store_true',
                        help='diagnostic: wait for the vertex-layout pipeline instead of using a pulling stand-in')
    parser.add_argument('--no-staged-t2t', action='store_true',
                        help='diagnostic: skip compressed texture copies that require block staging')
    parser.add_argument('--terrain-probe', action='store_true',
                        help='diagnostic: log Mario Kart World terrain material-buffer indices')
    parser.add_argument('--cbuf-probe', action='store_true',
                        help='diagnostic: log the dynamic uniform index of the first faulting NVN2 vertex shader')
    parser.add_argument('--no-cs-hoist', action='store_true',
                        help='diagnostic: keep compute dispatches in their original replay position')
    parser.add_argument('--no-slice-merge', action='store_true',
                        help='diagnostic: keep consecutive array-layer render passes separate')
    parser.add_argument('--no-uniform-defer', action='store_true',
                        help='diagnostic: apply inline uniform updates at their original replay position')
    parser.add_argument('--no-lazy-clear', action='store_true',
                        help='diagnostic: encode attachment clears when the target changes')
    parser.add_argument('--skip-fragment-shaders', metavar='KEYS',
                        help='diagnostic: skip draws for comma-separated 16-hex fragment shader keys')
    parser.add_argument('--hilite-fragment-shaders', metavar='KEYS',
                        help='diagnostic: replace one to six fragment shader key prefixes with solid colours')
    parser.add_argument('--depth-override-fragment-shaders', metavar='KEYS',
                        help='diagnostic: compare depth with ALWAYS for one to eight fragment shader key prefixes')
    parser.add_argument('--split-indirect', action='store_true',
                        help='diagnostically end and submit after each indirect draw')
    parser.add_argument('--wait-indirect', action='store_true',
                        help='wait for the last committed fence before the first indirect draw')
    parser.add_argument('--indirect-abi', action='store_true',
                        help='log raw argument registers for DrawElementsIndirect calls')
    parser.add_argument('--passdump', metavar='FRAME_OR_RANGE',
                        help='log graphics operations for one frame or an inclusive frame range')
    parser.add_argument('--keydump', metavar='SHADER_KEY',
                        help='dump bindings and uniforms for one draw of a fragment shader')
    parser.add_argument('--passdump-summary', metavar='FRAME_OR_RANGE',
                        help='log one graphics summary per pass without every repeated binding')
    parser.add_argument('--program-trace', metavar='KEYS',
                        help='trace ProgramSetShaders callers for comma-separated 16-hex shader keys')
    parser.add_argument('--gpu-profile', metavar='FRAME_OR_RANGE',
                        help='measure every Metal encoder in a frame/range, or every:N frames')
    parser.add_argument('--no-global-image-alias-barrier', action='store_true',
                        help='diagnostic: omit the global ResourceAlias visibility flag without changing image quality')
    parser.add_argument('--game-barriers', action='store_true',
                        help='diagnostic: order draw passes from the game barriers instead of a full barrier per pass')
    parser.add_argument('--guest-probe', metavar='MODULE:OFFSET',
                        help='install a bounded guest-code probe (DM_PROBE syntax)')
    parser.add_argument('--guest-probe-all', action='store_true',
                        help='include x9-x18 in guest-probe observations')
    parser.add_argument('--guest-probe-limit', type=int, choices=range(1, 1001),
                        help='maximum observations printed by each guest probe')
    parser.add_argument('--guest-watch-reg', metavar='XN[+OFFSET+LENGTH]',
                        help='after the first guest-probe hit, watch writes to a register-relative range')
    parser.add_argument('--gpu-watch-writes', action='store_true',
                        help='diagnostic: sample the watched word at GPU completions and stop at its first change')
    parser.add_argument('--compute-bindings', metavar='SHADER_KEY',
                        help='diagnostic: log storage and uniform slots for one compute shader')
    parser.add_argument('--guest-poll-reg', metavar='XN+OFFSET+LENGTH[=VALUE]',
                        help='after the first guest-probe hit, poll a register-relative value (also sees GPU writes)')
    args = parser.parse_args()
    if args.until_present is not None and args.until_present <= 0:
        parser.error('--until-present must be positive')
    if args.progress_timeout <= 0:
        parser.error('--progress-timeout must be positive')
    if args.metal_hud and not args.visible:
        parser.error('--metal-hud requires --visible')
    if args.capture_frames:
        if not re.fullmatch(r'[1-9]\d*(?:,[1-9]\d*){0,7}', args.capture_frames):
            parser.error('--capture-frames requires one to eight positive frame numbers')
        if not args.visible: parser.error('--capture-frames requires --visible')
    if args.max_rss_mib is not None and not 256 <= args.max_rss_mib <= 32768:
        parser.error('--max-rss-mib must be between 256 and 32768')
    if args.keys is not None and (not args.keys.strip() or len(args.keys) > 65536):
        parser.error('--keys must be a non-empty DM_KEYS script of at most 65536 characters')
    if args.native_sparse_serials and not re.fullmatch(r'\d+(?:,\d+)*', args.native_sparse_serials):
        parser.error('--native-sparse-serials requires comma-separated decimal texture serials')
    if args.native_sparse_empty_serials and not re.fullmatch(r'\d+(?:,\d+)*', args.native_sparse_empty_serials):
        parser.error('--native-sparse-empty-serials requires comma-separated decimal texture serials')
    if args.capture_raw_textures and not re.fullmatch(r'\d+(?:,\d+)*', args.capture_raw_textures):
        parser.error('--capture-raw-textures requires comma-separated decimal texture serials')
    if args.capture_raw_textures and args.capture_targets is None:
        parser.error('--capture-raw-textures requires --capture-targets')
    if args.capture_target_snapshots and not re.fullmatch(r'\d+(?:,\d+)*', args.capture_target_snapshots):
        parser.error('--capture-target-snapshots requires comma-separated non-negative render-pass indices')
    if args.capture_target_snapshots and args.capture_targets is None:
        parser.error('--capture-target-snapshots requires --capture-targets')
    if args.native_sparse and args.native_sparse_serials:
        parser.error('--native-sparse and --native-sparse-serials are mutually exclusive')
    if args.direct_raster_keys and not re.fullmatch(r'[0-9a-fA-F]{16}(?:,[0-9a-fA-F]{16})*', args.direct_raster_keys):
        parser.error('--direct-raster-keys requires comma-separated 16-hex keys')
    if args.task_raster_keys and not re.fullmatch(r'[0-9a-fA-F]{16}(?:,[0-9a-fA-F]{16})*', args.task_raster_keys):
        parser.error('--task-raster-keys requires comma-separated 16-hex keys')
    if args.skip_fragment_shaders and not re.fullmatch(r'[0-9a-fA-F]{16}(?:,[0-9a-fA-F]{16})*', args.skip_fragment_shaders):
        parser.error('--skip-fragment-shaders requires comma-separated 16-hex keys')
    if args.hilite_fragment_shaders and not re.fullmatch(r'[0-9a-fA-F]{1,16}(?:,[0-9a-fA-F]{1,16}){0,5}', args.hilite_fragment_shaders):
        parser.error('--hilite-fragment-shaders requires one to six comma-separated 1-16 hex key prefixes')
    if args.depth_override_fragment_shaders and not re.fullmatch(r'[0-9a-fA-F]{1,16}(?:,[0-9a-fA-F]{1,16}){0,7}', args.depth_override_fragment_shaders):
        parser.error('--depth-override-fragment-shaders requires one to eight comma-separated 1-16 hex key prefixes')
    if args.program_trace and not re.fullmatch(r'[0-9a-fA-F]{16}(?:,[0-9a-fA-F]{16})*', args.program_trace):
        parser.error('--program-trace requires comma-separated 16-hex keys')
    if not 2048 <= args.min_available_mib <= 32768:
        parser.error('--min-available-mib must be between 2048 and 32768')
    shader_keys = []
    if args.shader_keys:
        shader_keys = [key.strip().lower() for key in args.shader_keys.split(',') if key.strip()]
        if not shader_keys or any(not re.fullmatch(r'[0-9a-f]{16}', key) for key in shader_keys):
            parser.error('--shader-keys requires comma-separated 16-hex keys')
        if not args.shader_dump:
            parser.error('--shader-keys requires --shader-dump')
    work = args.work.resolve()
    metadata = json.loads((work / 'source.json').read_text())
    host = args.host.resolve() if args.host else work / 'tools/dmhost'
    patched = work / 'patched_v0'
    if not host.is_file() or not (patched / 'main.fixups.tsv').is_file():
        parser.error('run prepare_extracted_game.py --prepare-code first')
    run = work / 'run'; run.mkdir(exist_ok=True)
    for name in ('save', 'temp', 'msl'): (run / name).mkdir(exist_ok=True)
    profile = args.profile_dir.resolve() if args.profile_dir else work / 'profile' / metadata['title_id']
    if not (profile / 'shader_map.tsv').is_file():
        parser.error(f'profile has no shader_map.tsv: {profile}')
    env = {k: v for k, v in os.environ.items() if not k.startswith('DM_')}
    env.update(DM_ROOT=str(work), DM_ROMFS=metadata['romfs'], DM_SAVE=str(run / 'save'),
               DM_TEMP=str(run / 'temp'), DM_MSL_DIR=str(args.shader_dir.resolve() if args.shader_dir else run / 'msl'), DM_FONT_DIR=str(work / 'font'),
               DM_NVN_SHMAP=str(profile / 'shader_map.tsv'), DM_BOOTPROF='1',
               DM_PSO_PREBUILD='0', DM_PSO_PREBUILD_THREADS='1', DM_PSO_PREPARE_THREADS='1')
    if not args.quiet_svc: env['DM_SVC'] = '1'
    if args.profile_performance:
        env.update(DM_SLOWFRAME='1', DM_NVN_PROF='1', DM_NVN_CPUPROF='1', DM_NVN_WAITS='1')
    if args.allocation_profile:
        env['DM_NVN_ALLOCPROF'] = '1'
    if args.native_sparse or args.native_sparse_serials:
        env['DM_NVN_NATIVE_SPARSE'] = '1'
    if args.native_sparse_serials:
        env['DM_NVN_NATIVE_SPARSE_SERIALS'] = args.native_sparse_serials
    if args.native_sparse_empty:
        env['DM_NVN_NATIVE_SPARSE_EMPTY'] = '1'
    if args.native_sparse_empty_serials:
        env['DM_NVN_NATIVE_SPARSE_EMPTY_SERIALS'] = args.native_sparse_empty_serials
    if args.native_sparse_no_upload:
        env['DM_NVN_NATIVE_SPARSE_NO_UPLOAD'] = '1'
    if args.native_sparse_zero_upload:
        env['DM_NVN_NATIVE_SPARSE_ZERO_UPLOAD'] = '1'
    if args.mesh_trace:
        env['DM_NVN2_MESH_TRACE'] = '1'
    if args.sparse_lifetime:
        env['DM_NVN_SPARSE_LIFETIME'] = args.sparse_lifetime
    if args.no_mesh_raster:
        env['DM_NVN2_RASTER'] = '0'
    if args.mesh_raster_mode:
        env['DM_NVN2_RASTER_MODE'] = str(args.mesh_raster_mode)
    if args.direct_raster_keys:
        env['DM_NVN2_DIRECT_RASTER_KEYS'] = args.direct_raster_keys.lower()
    if args.task_raster_keys:
        env['DM_NVN2_TASK_RASTER_KEYS'] = args.task_raster_keys.lower()
    if args.safe_raster:
        env['DM_NVN2_RASTER_SAFE'] = '1'
    if args.no_task_mesh:
        env['DM_NVN2_MESH'] = '0'
    if args.watch_sample and not args.watch_stall:
        parser.error('--watch-sample requires --watch-stall')
    if args.watch_stall:
        env['DM_WATCH_STALL'] = str(args.watch_stall)
        if args.watch_sample: env['DM_WATCH_SAMPLE'] = str(args.watch_sample.resolve())
    if args.fence_trace: env['DM_NVN_FENCE_TRACE'] = '1'
    if args.no_segment and args.segment_draws:
        parser.error('--no-segment and --segment-draws are mutually exclusive')
    if args.no_segment: env['DM_NVN_CUT'] = '0'
    elif args.segment_draws: env['DM_NVN_CUT'] = str(args.segment_draws)
    if args.split_draws: env['DM_NVN_SPLIT_DRAWS'] = '1'
    if args.wait_segments: env['DM_NVN_WAIT_SEGMENTS'] = '1'
    if args.residency_check: env['DM_RES_CHECK'] = '1'
    if args.legacy_pipelines: env['DM_PSO_MTL4'] = '0'
    if args.no_pipeline_archive: env['DM_PSO_ARCHIVE'] = 'off'
    if args.no_pipeline_prewarm: env['DM_PSO_MANIFEST'] = 'off'
    if args.no_hybrid_pipelines: env['DM_PSO_HYBRID'] = '0'
    if args.no_staged_t2t: env['DM_NVN_T2T_STAGE'] = '0'
    if args.terrain_probe: env['DM_NVN_TERRAIN_PROBE'] = '1'
    if args.cbuf_probe: env['DM_NVN_CBUF_PROBE'] = '1'
    if args.no_cs_hoist: env['DM_NVN_CS_HOIST'] = '0'
    if args.no_slice_merge: env['DM_NVN_SLICE_MERGE'] = '0'
    if args.no_uniform_defer:
        env['DM_NVN_UB_DEFER'] = '0'
        env['DM_NVN_UB_LAZY'] = '0'
    if args.no_lazy_clear: env['DM_NVN_LAZY_CLEAR'] = '0'
    if args.skip_fragment_shaders: env['DM_NVN_SKIP_FS'] = args.skip_fragment_shaders.lower()
    if args.hilite_fragment_shaders: env['DM_NVN_HILITE'] = args.hilite_fragment_shaders.lower()
    if args.depth_override_fragment_shaders: env['DM_NVN_DEPTHOVR'] = args.depth_override_fragment_shaders.lower()
    if args.program_trace: env['DM_NVN_PROGTRACE'] = args.program_trace.lower()
    if args.keydump:
        if not re.fullmatch(r'[0-9a-fA-F]{16}', args.keydump):
            parser.error('--keydump requires a 16-hex shader key')
        env['DM_NVN_KEYDUMP'] = args.keydump.lower() + ':1'
    if args.split_indirect: env['DM_NVN_SPLIT_INDIRECT'] = '1'
    if args.wait_indirect: env['DM_NVN_WAIT_INDIRECT'] = '1'
    if args.indirect_abi: env['DM_NVN_INDIRECT_ABI'] = '1'
    if args.passdump and args.passdump_summary:
        parser.error('--passdump and --passdump-summary are mutually exclusive')
    if args.passdump or args.passdump_summary:
        pd_range = args.passdump or args.passdump_summary
        if not re.fullmatch(r'\d+(?:-\d+)?', pd_range):
            parser.error('--passdump requires a frame number or start-end')
        env['DM_NVN_PASSDUMP'] = pd_range
        if args.passdump: env['DM_NVN_PASSDUMP_ALL'] = '1'
    if args.gpu_profile:
        if not re.fullmatch(r'(?:\d+(?:-\d+)?|every:[1-9]\d*)', args.gpu_profile):
            parser.error('--gpu-profile requires a frame number, start-end or every:N')
        env['DM_NVN_GPUPROF'] = args.gpu_profile
    if args.no_global_image_alias_barrier:
        env['DM_NVN_IMAGE_ALIAS_BARRIER'] = '0'
    if args.game_barriers:
        env['DM_NVN_BARRIER'] = 'game'
    if args.guest_probe:
        if not re.fullmatch(r'[^,:]+:[0-9a-fA-F]+(?:[^,]*)(?:,[^,:]+:[0-9a-fA-F]+(?:[^,]*))*', args.guest_probe):
            parser.error('--guest-probe requires DM_PROBE syntax such as main:411b90@x11+10')
        env['DM_PROBE'] = args.guest_probe
    if args.guest_probe_all:
        if not args.guest_probe: parser.error('--guest-probe-all requires --guest-probe')
        env['DM_PROBE_ALL'] = '1'
    if args.guest_probe_limit:
        if not args.guest_probe: parser.error('--guest-probe-limit requires --guest-probe')
        env['DM_PROBE_LIMIT'] = str(args.guest_probe_limit)
    if args.guest_watch_reg:
        if not args.guest_probe: parser.error('--guest-watch-reg requires --guest-probe')
        if not re.fullmatch(r'x(?:[12]?\d|30)(?:\+[0-9a-fA-F]+\+[0-9a-fA-F]+)?', args.guest_watch_reg):
            parser.error('--guest-watch-reg requires xN or xN+hex-offset+hex-length')
        env['DM_PROBE_WATCH_REG'] = args.guest_watch_reg
    if args.gpu_watch_writes:
        if not args.guest_watch_reg: parser.error('--gpu-watch-writes requires --guest-watch-reg')
        env['DM_NVN_WATCH_WRITES'] = '1'
    if args.compute_bindings:
        if not re.fullmatch(r'[0-9a-fA-F]{16}', args.compute_bindings): parser.error('--compute-bindings requires a 16-hex shader key')
        env['DM_NVN_COMPUTE_BINDINGS'] = args.compute_bindings.lower()
    if args.guest_poll_reg:
        if not args.guest_probe: parser.error('--guest-poll-reg requires --guest-probe')
        if not re.fullmatch(r'x(?:[12]?\d|30)\+[0-9a-fA-F]+\+[0-9a-fA-F]+(?:=[0-9a-fA-F]+)?', args.guest_poll_reg):
            parser.error('--guest-poll-reg requires xN+hex-offset+hex-length[=hex-value]')
        env['DM_PROBE_POLL_REG'] = args.guest_poll_reg
    if args.visible: env['DM_WINDOW'] = '1'
    if args.metal_hud: env['MTL_HUD_ENABLED'] = '1'
    if args.zero_blocks: env['DM_NVN_ZBLOCK'] = '1'
    if args.keys is not None: env['DM_KEYS'] = args.keys
    stamp = time.strftime('%Y%m%d-%H%M%S')
    log = work / 'logs' / f'probe-{stamp}.log'
    shaders = work / 'logs' / f'shaders-{stamp}'
    frames = work / 'logs' / f'frames-{stamp}'
    if args.capture_targets is not None:
        if args.capture_targets < 1: parser.error('--capture-targets must be a positive frame')
        targets = work / 'logs' / f'targets-{stamp}'
        targets.mkdir()
        env['DM_NVN_TEXDUMP'] = f'{args.capture_targets}:{targets}/target-%d.png'
        if args.capture_target_snapshots: env['DM_NVN_TEXSNAP'] = args.capture_target_snapshots
        if args.capture_raw_textures: env['DM_NVN_TEXRAW'] = args.capture_raw_textures
    if args.capture_frames:
        frames.mkdir()
        env['DM_NVN_SHOT'] = f'{args.capture_frames}:{frames}/frame-%d.png'
    if args.shader_dump:
        shaders.mkdir()
        env['DM_NVN_SHDUMP'] = str(shaders)
        if shader_keys: env['DM_NVN_SHDUMP_KEYS'] = ','.join(shader_keys)
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    reason, peak = 'exit', 0
    reserve = args.min_available_mib * 1024 * 1024
    initial_available = available_memory()
    minimum_available = initial_available
    if initial_available is not None and initial_available <= reserve:
        parser.error(f'only {initial_available / 2**20:.0f} MiB is conservatively available; the requested reserve is {args.min_available_mib} MiB')
    start = time.monotonic()
    next_memory_check = start
    last_progress, log_offset, reached_present = start, 0, 0
    progress_tail = b''
    with log.open('wb') as stream:
        process = subprocess.Popen(['/usr/bin/nice', '-n', '10', str(host), str(patched)],
                                   cwd=run, env=env, stdin=subprocess.DEVNULL, stdout=stream,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            while process.poll() is None:
                rss = process_rss(process.pid); peak = max(peak, rss)
                if args.max_rss_mib and rss > args.max_rss_mib * 1024 * 1024: reason = 'memory-limit'; break
                now = time.monotonic()
                if now >= next_memory_check:
                    available = available_memory()
                    next_memory_check = now + 0.25
                    if available is not None:
                        minimum_available = available if minimum_available is None else min(minimum_available, available)
                        if available < reserve: reason = 'system-memory-reserve'; break
                if log.stat().st_size > 16 * 1024 * 1024: reason = 'log-limit'; break
                if args.shader_dump and sum(p.stat().st_size for p in shaders.iterdir()) > 64 * 1024 * 1024:
                    reason = 'shader-dump-limit'; break
                if args.until_present is not None:
                    with log.open('rb') as progress:
                        progress.seek(log_offset)
                        chunk = progress.read()
                        log_offset = progress.tell()
                    if chunk:
                        last_progress = now
                        lines = (progress_tail + chunk).split(b'\n')
                        progress_tail = lines.pop()
                        if any(b'Caused GPU Hang Error' in line or
                               b'kIOGPUCommandBufferCallbackErrorHang' in line for line in lines):
                            reason = 'gpu-hang'
                            break
                        for line in lines:
                            match = re.search(rb'\[bootprof\].*\bpresent #(\d+):', line)
                            if match: reached_present = max(reached_present, int(match[1]))
                    if reached_present >= args.until_present: reason = 'present-target'; break
                    if now - last_progress >= args.progress_timeout: reason = 'progress-timeout'; break
                elif now - start >= args.seconds: reason = 'time-limit'; break
                time.sleep(0.05)
        except KeyboardInterrupt:
            reason = 'cancelled'
        finally:
            stop(process)
    # A fast startup crash can fall between process-list samples. wait() also
    # supplies the OS high-water mark (bytes on macOS, KiB on Linux).
    child_peak = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
    if sys.platform != 'darwin': child_peak *= 1024
    log_text = log.read_text(errors='replace')
    cpu_crash = re.search(r'CRASH sig=(\d+).*', log_text)
    gpu_page_fault = bool(re.search(r'GPU Address Fault|kIOGPUCommandBufferCallbackErrorPageFault', log_text))
    gpu_hang = 'kIOGPUCommandBufferCallbackErrorHang' in log_text
    validation_errors = log_text.count('Invalid Metal usage:')
    gpu_error = gpu_page_fault or gpu_hang or bool(re.search(r'\[RED\].*command buffer (?:execution error|error details)', log_text))
    if cpu_crash: reason = 'cpu-crash'
    elif process.returncode not in (0, None) and reason == 'exit': reason = 'abnormal-exit'
    elif gpu_page_fault: reason = 'gpu-page-fault'
    elif gpu_hang: reason = 'gpu-hang'
    elif gpu_error: reason = 'gpu-command-error'
    elif validation_errors: reason = 'metal-validation-error'
    report = {'log': str(log), 'reason': reason, 'returncode': process.returncode,
              'target_present': args.until_present, 'reached_present': reached_present,
              'cpu_crash': cpu_crash.group(0) if cpu_crash else None,
              'seconds': round(time.monotonic() - start, 2), 'peak_rss_mib': round(max(peak, child_peak) / 2**20, 2),
              'sampled_group_peak_rss_mib': round(peak / 2**20, 2),
              'os_child_peak_rss_mib': round(child_peak / 2**20, 2),
              'initial_available_mib': round(initial_available / 2**20, 2) if initial_available is not None else None,
              'minimum_available_mib': round(minimum_available / 2**20, 2) if minimum_available is not None else None,
              'reserved_available_mib': args.min_available_mib,
              'hard_group_limit_mib': args.max_rss_mib, 'gpu_page_fault': gpu_page_fault,
              'gpu_hang': gpu_hang, 'gpu_error': gpu_error, 'metal_validation_errors': validation_errors,
              'headless': not args.visible, 'metal_hud_requested': args.metal_hud,
              'playability': 'not tested'}
    if args.shader_dump: report['shader_dump'] = str(shaders)
    if args.capture_frames: report['captured_frames'] = [str(p) for p in sorted(frames.glob('frame-*.png'))]
    log.with_suffix('.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
    return 0 if process.returncode == 0 and reason in ('exit', 'present-target') else 1


if __name__ == '__main__': raise SystemExit(main())
