#!/usr/bin/env python3
"""Build a cloud-disabled synthetic Mac host and watch physical footprint, including compressed memory."""
import argparse
import ctypes
import json
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--seconds', type=int, default=600)
parser.add_argument('--limit-mb', type=int, default=450)
parser.add_argument('--cycles', action='store_true', help='exercise pause/resume/end/restart 60 times')
args = parser.parse_args()
if not 70 <= args.seconds <= 3600 or not 128 <= args.limit_mb <= 1024:
    parser.error('seconds must be 70–3600, limit-mb must be 128–1024')
repo = Path(__file__).resolve().parents[1]
folder = Path(tempfile.mkdtemp(prefix='workbench-focus-report-'))
data = folder / 'data'
data.mkdir()
for name in ('workbench.sqlite', 'photo.sqlite'):
    with sqlite3.connect(data / name) as db:
        db.execute('PRAGMA user_version=0')
spec = {'name': 'IsolatedFocusProbe', 'packages': {'WorkBenchKit': {'path': str(repo / 'apple/Packages/WorkBenchKit')}},
        'targets': {'Probe': {'type': 'application', 'platform': 'macOS', 'deploymentTarget': '26.0',
        'sources': [str(repo / 'apple/Diagnostics/FocusMemoryProbe.swift')], 'dependencies': [{'package': 'WorkBenchKit'}],
        'settings': {'base': {'PRODUCT_BUNDLE_IDENTIFIER': 'local.workbench.focus-diagnostic',
        'GENERATE_INFOPLIST_FILE': 'YES', 'INFOPLIST_KEY_WorkbenchCloudEnabled': 'NO',
        'CODE_SIGNING_ALLOWED': 'NO', 'SWIFT_VERSION': '6.2'}}}}}
(folder / 'project.yml').write_text(json.dumps(spec))
print('REPORT', folder, flush=True)
with (folder / 'build.log').open('w') as log:
    subprocess.run(['xcodegen', 'generate', '--spec', str(folder / 'project.yml')], check=True, stdout=log, stderr=log)
    subprocess.run(['xcodebuild', '-project', str(folder / 'IsolatedFocusProbe.xcodeproj'), '-scheme', 'Probe',
                    '-configuration', 'Release', '-destination', 'platform=macOS', '-derivedDataPath', str(folder / 'build'),
                    'CODE_SIGNING_ALLOWED=NO', 'build'], check=True, stdout=log, stderr=log)
class Usage(ctypes.Structure):
    _fields_ = [('uuid', ctypes.c_ubyte * 16)] + [(name, ctypes.c_uint64) for name in
        ('user','system','wake','interrupt','pageins','wired','rss','footprint','start','exit','childuser',
         'childsystem','childwake','childinterrupt','childpageins','childelapsed','read','write')]
lib = ctypes.CDLL('/usr/lib/libproc.dylib')
lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
env = dict(os.environ, WORKBENCH_QA='1', WORKBENCH_DB_PATH=str(data / 'workbench.sqlite'),
           PROBE_CYCLES='1' if args.cycles else '0', NSUnbufferedIO='YES')
app = folder / 'build/Build/Products/Release/Probe.app/Contents/MacOS/Probe'
policy = '(version 1)(allow default)(deny network*)(deny file-read* (subpath ' + json.dumps(str(repo / 'data')) + '))'
peak = 0
failure = None
with (folder / 'runtime.log').open('w') as log, (folder / 'memory.log').open('w') as stats:
    process = subprocess.Popen(['/usr/bin/sandbox-exec', '-p', policy, str(app)], env=env,
                               stdout=log, stderr=log, start_new_session=True)
    start = time.monotonic()
    last = 0
    try:
        while process.poll() is None and time.monotonic() - start < args.seconds:
            time.sleep(.1)
            usage = Usage()
            if lib.proc_pid_rusage(process.pid, 2, ctypes.byref(usage)) != 0:
                failure = 'Cannot measure physical footprint'
                break
            elapsed = time.monotonic() - start
            peak = max(peak, usage.footprint)
            if elapsed - last >= 1:
                line = f'{elapsed:.1f} pid={process.pid} rss_mb={usage.rss/1048576:.1f} physical_mb={usage.footprint/1048576:.1f}'
                print(line, flush=True)
                print(line, file=stats, flush=True)
                last = elapsed
            if usage.footprint > args.limit_mb * 1048576:
                failure = 'PHYSICAL_FOOTPRINT_LIMIT'
                break
            if elapsed > 15 and 'FOCUS_READY true' not in (folder / 'runtime.log').read_text():
                failure = 'Focus never started: invalid test setup'
                break
        if process.poll() is not None:
            failure = f'Process exited early: {process.returncode}'
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
        process.wait()
if args.cycles and 'FOCUS_PHASE 59' not in (folder / 'runtime.log').read_text():
    failure = failure or 'Cycle sequence did not complete'
report = {'peak_physical_mb': peak/1048576, 'seconds': time.monotonic()-start, 'failure': failure,
          'cycles': args.cycles, 'cloud_disabled': True, 'formal_data_denied': True}
(folder / 'result.json').write_text(json.dumps(report, indent=2))
print(json.dumps(report), flush=True)
raise SystemExit(1 if failure else 0)
