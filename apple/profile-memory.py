#!/usr/bin/env python3
"""Opt-in isolated native-window probe with an external resident-memory watchdog."""
import argparse
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source', type=Path, help='optional database to copy read-only; original is never migrated')
parser.add_argument('--limit-mb', type=int, default=512)
args = parser.parse_args()
if args.limit_mb < 128:
    parser.error('limit must be at least 128 MB')
root = Path(__file__).resolve().parents[1]
folder = Path(tempfile.mkdtemp(prefix='workbench-memory-report-'))
logfile = folder / 'probe.log'
env = dict(os.environ, WORKBENCH_MEMORY_PROBE='1', WORKBENCH_MEMORY_ALL='1', WORKBENCH_QA='1', NSUnbufferedIO='YES')
if args.source:
    env['WORKBENCH_MEMORY_SOURCE'] = str(args.source.resolve(strict=True))
helper = None
peak = 0
stopped = False
with logfile.open('w') as log:
    process = subprocess.Popen(['swift', 'test', '--package-path', str(root / 'apple/Packages/WorkBenchKit'),
                                '--filter', 'nativeWindowMemoryProbe'], env=env, stdout=log,
                               stderr=subprocess.STDOUT, start_new_session=True)
    started = time.monotonic()
    try:
        while process.poll() is None:
            time.sleep(1)
            text = logfile.read_text(errors='replace')
            match = re.search(r'MEMORY_PROBE_PID (\d+)', text)
            if match:
                helper = int(match.group(1))
                status = subprocess.run(['ps', '-p', str(helper), '-o', 'rss=,comm='], capture_output=True, text=True)
                if status.returncode == 0 and 'swiftpm-testing-helper' in status.stdout:
                    rss = int(status.stdout.split()[0])
                    peak = max(peak, rss)
                    if rss > args.limit_mb * 1024:
                        subprocess.run(['sample', str(helper), '2', '-file', str(folder / 'sample.txt')],
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                        stopped = True
                        break
            if time.monotonic() - started > 180:
                stopped = True
                break
    finally:
        if process.poll() is None:
            if helper is not None:
                try:
                    os.kill(helper, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            os.killpg(process.pid, signal.SIGKILL)
        code = process.wait()
print(f'report: {folder}; observed helper peak RSS: {peak / 1024:.1f} MB')
if stopped:
    raise SystemExit('watchdog stopped the probe; inspect the report before retrying')
raise SystemExit(code)
