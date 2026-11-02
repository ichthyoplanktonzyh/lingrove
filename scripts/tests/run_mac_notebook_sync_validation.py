#!/usr/bin/env python3
"""Serialize one Mac D validation command and retain complete local evidence.

The lock covers Apple subprocesses until their log/result receipt is durable. Invoke once around
preparation/build/test; subprocesses must not acquire this same lock again.
"""
import argparse
import fcntl
import json
import pathlib
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('--log', required=True, type=pathlib.Path)
parser.add_argument('command', nargs=argparse.REMAINDER)
args = parser.parse_args()
command = args.command[1:] if args.command[:1] == ['--'] else args.command
if not command:
    parser.error('a command is required')
args.log.parent.mkdir(parents=True, exist_ok=True)
print('Waiting for the shared Apple validation lock.', flush=True)
with open('/tmp/lingrove-mobile-validation.lock', 'a') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    print('Acquired the shared Apple validation lock.', flush=True)
    started = time.time()
    with args.log.open('w') as output:
        result = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT)
        output.flush()
    args.log.with_suffix('.receipt.json').write_text(json.dumps({
        'exitCode': result.returncode, 'elapsedSeconds': round(time.time() - started, 3),
        'log': str(args.log.resolve()), 'sharedAppleLock': True,
    }, indent=2) + '\n')
    print(f'Validation finished: exit {result.returncode}; evidence {args.log}', flush=True)
raise SystemExit(result.returncode)
