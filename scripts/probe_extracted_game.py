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
    parser.add_argument('--max-rss-mib', type=int,
                        help='optional hard process-group ceiling; by default only the system reserve is enforced')
    parser.add_argument('--min-available-mib', type=int, default=8192,
                        help='stop before conservative available system memory falls below this reserve (default: 8192)')
    parser.add_argument('--shader-dump', action='store_true', help='preserve missing shader inputs, bounded to 64 MiB per probe')
    parser.add_argument('--shader-keys', help='comma-separated 16-hex shader keys to capture even when already mapped')
    parser.add_argument('--profile-dir', type=Path,
                        help='diagnostic profile directory containing shader_map.tsv (default: WORK/profile/TITLE_ID)')
    parser.add_argument('--visible', action='store_true', help='open the game window while retaining all probe limits')
    parser.add_argument('--keys', metavar='DM_KEYS',
                        help='script controller input during a visible probe (same syntax as the host DM_KEYS setting)')
    parser.add_argument('--quiet-svc', action='store_true',
                        help='omit verbose system-call tracing for a lower-overhead play-through probe')
    parser.add_argument('--profile-performance', action='store_true',
                        help='collect dropped-frame, NVN recording, replay-phase and wait diagnostics')
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
    parser.add_argument('--split-indirect', action='store_true',
                        help='diagnostically end and submit after each indirect draw')
    parser.add_argument('--wait-indirect', action='store_true',
                        help='wait for the last committed fence before the first indirect draw')
    parser.add_argument('--indirect-abi', action='store_true',
                        help='log raw argument registers for DrawElementsIndirect calls')
    parser.add_argument('--passdump', metavar='FRAME_OR_RANGE',
                        help='log graphics operations for one frame or an inclusive frame range')
    parser.add_argument('--passdump-summary', metavar='FRAME_OR_RANGE',
                        help='log one graphics summary per pass without every repeated binding')
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
    parser.add_argument('--guest-poll-reg', metavar='XN+OFFSET+LENGTH[=VALUE]',
                        help='after the first guest-probe hit, poll a register-relative value (also sees GPU writes)')
    args = parser.parse_args()
    if args.max_rss_mib is not None and not 256 <= args.max_rss_mib <= 32768:
        parser.error('--max-rss-mib must be between 256 and 32768')
    if args.keys is not None and (not args.keys.strip() or len(args.keys) > 65536):
        parser.error('--keys must be a non-empty DM_KEYS script of at most 65536 characters')
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
    host = work / 'tools/dmhost'; patched = work / 'patched_v0'
    if not host.is_file() or not (patched / 'main.fixups.tsv').is_file():
        parser.error('run prepare_extracted_game.py --prepare-code first')
    run = work / 'run'; run.mkdir(exist_ok=True)
    for name in ('save', 'temp', 'msl'): (run / name).mkdir(exist_ok=True)
    profile = args.profile_dir.resolve() if args.profile_dir else work / 'profile' / metadata['title_id']
    if not (profile / 'shader_map.tsv').is_file():
        parser.error(f'profile has no shader_map.tsv: {profile}')
    env = {k: v for k, v in os.environ.items() if not k.startswith('DM_')}
    env.update(DM_ROOT=str(work), DM_ROMFS=metadata['romfs'], DM_SAVE=str(run / 'save'),
               DM_TEMP=str(run / 'temp'), DM_MSL_DIR=str(run / 'msl'), DM_FONT_DIR=str(work / 'font'),
               DM_NVN_SHMAP=str(profile / 'shader_map.tsv'), DM_BOOTPROF='1',
               DM_PSO_PREBUILD='0', DM_PSO_PREBUILD_THREADS='1', DM_PSO_PREPARE_THREADS='1')
    if not args.quiet_svc: env['DM_SVC'] = '1'
    if args.profile_performance:
        env.update(DM_SLOWFRAME='1', DM_NVN_PROF='1', DM_NVN_CPUPROF='1', DM_NVN_WAITS='1')
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
    if args.guest_poll_reg:
        if not args.guest_probe: parser.error('--guest-poll-reg requires --guest-probe')
        if not re.fullmatch(r'x(?:[12]?\d|30)\+[0-9a-fA-F]+\+[0-9a-fA-F]+(?:=[0-9a-fA-F]+)?', args.guest_poll_reg):
            parser.error('--guest-poll-reg requires xN+hex-offset+hex-length[=hex-value]')
        env['DM_PROBE_POLL_REG'] = args.guest_poll_reg
    if args.visible: env['DM_WINDOW'] = '1'
    if args.keys is not None: env['DM_KEYS'] = args.keys
    stamp = time.strftime('%Y%m%d-%H%M%S')
    log = work / 'logs' / f'probe-{stamp}.log'
    shaders = work / 'logs' / f'shaders-{stamp}'
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
                if now - start >= args.seconds: reason = 'time-limit'; break
                time.sleep(0.05)
        except KeyboardInterrupt:
            reason = 'cancelled'
        finally:
            stop(process)
    # A fast startup crash can fall between process-list samples. wait() also
    # supplies the OS high-water mark (bytes on macOS, KiB on Linux).
    child_peak = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
    if sys.platform != 'darwin': child_peak *= 1024
    report = {'log': str(log), 'reason': reason, 'returncode': process.returncode,
              'seconds': round(time.monotonic() - start, 2), 'peak_rss_mib': round(max(peak, child_peak) / 2**20, 2),
              'sampled_group_peak_rss_mib': round(peak / 2**20, 2),
              'os_child_peak_rss_mib': round(child_peak / 2**20, 2),
              'initial_available_mib': round(initial_available / 2**20, 2) if initial_available is not None else None,
              'minimum_available_mib': round(minimum_available / 2**20, 2) if minimum_available is not None else None,
              'reserved_available_mib': args.min_available_mib,
              'hard_group_limit_mib': args.max_rss_mib,
              'headless': not args.visible, 'playability': 'not tested'}
    if args.shader_dump: report['shader_dump'] = str(shaders)
    log.with_suffix('.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
    return 0 if process.returncode == 0 and reason == 'exit' else 1


if __name__ == '__main__': raise SystemExit(main())
