#!/usr/bin/env python3
"""Time a forced app rebuild and sample Linux system counters while Cargo runs."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import threading
import time

parser = argparse.ArgumentParser()
parser.add_argument('phase', choices=['test-first', 'test-second'])
args = parser.parse_args()
root = Path(os.environ['RUNNER_TEMP']) / 'linux-diagnostics'
root.mkdir(parents=True, exist_ok=True)
def utc():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()
def append(name, value):
    with (root / name).open('a') as out:
        out.write(json.dumps(value) + '\n')
source = Path('spotify_player/src/main.rs')
before = hashlib.sha256(source.read_bytes()).hexdigest()
os.utime(source, None)
assert hashlib.sha256(source.read_bytes()).hexdigest() == before
append('forced-rebuilds.jsonl', dict(phase=args.phase, utc=utc(), sourceHash=before,
    sourceMtimeNs=source.stat().st_mtime_ns, bootId=Path('/proc/sys/kernel/random/boot_id').read_text().strip(),
    uptime=Path('/proc/uptime').read_text().strip(), revision=os.environ['GITHUB_SHA'],
    launched=os.environ.get('RUNS_ON_INSTANCE_LAUNCHED_AT'), cpuCount=os.cpu_count()))
timings = Path('target/cargo-timings')
if timings.exists():
    shutil.rmtree(timings)
stop = threading.Event()
errors = []
def collect():
    try:
        with (root / f'{args.phase}-counters.jsonl').open('w') as out:
            while True:
                sample = dict(utc=utc(), cpu=Path('/proc/stat').read_text().splitlines()[0],
                    memory=Path('/proc/meminfo').read_text(), disk=Path('/proc/diskstats').read_text(),
                    vm=Path('/proc/vmstat').read_text())
                out.write(json.dumps(sample) + '\n')
                out.flush()
                if stop.wait(1):
                    break
            # Keep an explicit final sample for coverage and counter deltas.
            out.write(json.dumps(dict(utc=utc(), cpu=Path('/proc/stat').read_text().splitlines()[0],
                memory=Path('/proc/meminfo').read_text(), disk=Path('/proc/diskstats').read_text(),
                vm=Path('/proc/vmstat').read_text())) + '\n')
    except Exception as error:
        errors.append(repr(error))
thread = threading.Thread(target=collect)
thread.start()
append('phases.jsonl', dict(phase=args.phase, event='start', utc=utc()))
env = os.environ.copy()
env.update(CARGO_LOG='cargo::core::compiler::fingerprint=info', CARGO_TERM_COLOR='never', CARGO_INCREMENTAL='0')
code = 1
start = time.monotonic()
try:
    with (root / f'{args.phase}.log').open('w') as log:
        proc = subprocess.Popen(['cargo', 'test', '--locked', '--timings', '--no-default-features',
            '--features', os.environ['RUST_FEATURES']], env=env, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True)
        for line in proc.stdout:
            log.write(line)
            print(line, end='', flush=True)
        code = proc.wait()
finally:
    elapsed = time.monotonic() - start
    append('durations.jsonl', dict(phase=args.phase, seconds=elapsed, exitCode=code))
    append('phases.jsonl', dict(phase=args.phase, event='end', utc=utc()))
    stop.set()
    thread.join()
    if timings.exists():
        shutil.copytree(timings, root / f'{args.phase}-timings')
if code:
    raise SystemExit(code)
if errors:
    raise RuntimeError(f'Counter collection failed: {errors}')
report = (timings / 'cargo-timing.html').read_text()
units = json.JSONDecoder().raw_decode(report.split('const UNIT_DATA = ', 1)[1])[0]
compiled = [x for x in units if x['duration'] > 0]
assert compiled and all(x['name'] == 'spotify_player' for x in compiled), 'Expected app-only rebuild'
(root / f'{args.phase}-compiled-units.json').write_text(json.dumps(compiled, indent=2))
with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as out:
    out.write(f'{args.phase}: {elapsed:.2f}s; verified app rebuild with dependencies reused\n')
