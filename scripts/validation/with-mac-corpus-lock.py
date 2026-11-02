#!/usr/bin/env python3
"""Run one native corpus checkpoint with the shared Apple validation lock.

Each invocation keeps its command and evidence in this checkout's build tree. Preparation
copies only pinned dependency source from the read-only development cache, then invokes the
normal workspace preparation; no user app, account, permissions or Simulator is accessed.
"""
import argparse
import fcntl
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT / "build/mac-w2-c"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--label", required=True)
    parser.add_argument("--prepare", action="store_true")
    parser.add_argument("--local-team", action="store_true")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if args.local_team:
        match = re.search(r"^DEVELOPMENT_TEAM\s*=\s*(\S+)", (ROOT / "Config/Signing.local.xcconfig").read_text(), re.MULTILINE)
        if match is None:
            raise SystemExit("Local development team is not configured")
        command.append("DEVELOPMENT_TEAM=" + match.group(1))
    BASE.mkdir(parents=True, exist_ok=True)
    started = time.time()
    with open("/tmp/lingrove-mobile-validation.lock", "a") as lock:
        print("Waiting for the shared Apple validation lock.", flush=True)
        fcntl.flock(lock, fcntl.LOCK_EX)
        print("Acquired validation lock for " + args.label, flush=True)
        with (BASE / (args.label + ".log")).open("w") as output:
            env = os.environ.copy()
            if args.prepare:
                copies = [
                    (Path("/Users/shadow/lingrove/build/lingrove-dependencies/CotabbyInference"), ROOT / "build/lingrove-dependencies/CotabbyInference"),
                    (Path("/Users/shadow/lingrove/build/tts-native/llama.cpp"), ROOT / "build/tts-native/llama.cpp"),
                ]
                for source, destination in copies:
                    if not destination.exists():
                        shutil.copytree(source, destination, symlinks=True)
                env["CMAKE_OSX_ARCHITECTURES"] = "arm64"
                code = subprocess.run(["scripts/prepare_lingrove_workspace.sh"], cwd=ROOT, env=env, stdout=output, stderr=subprocess.STDOUT).returncode
                if code == 0:
                    code = subprocess.run(["xcodegen", "generate"], cwd=ROOT, env=env, stdout=output, stderr=subprocess.STDOUT).returncode
            else:
                if not command:
                    raise SystemExit("A command is required")
                code = subprocess.run(command, cwd=ROOT, env=env, stdout=output, stderr=subprocess.STDOUT).returncode
        (BASE / (args.label + ".json")).write_text(json.dumps({"label": args.label, "exitCode": code,
            "elapsedSeconds": round(time.time() - started, 2), "command": ["DEVELOPMENT_TEAM=<local>" if item.startswith("DEVELOPMENT_TEAM=") else item for item in command], "prepare": args.prepare,
            "sharedLock": "/tmp/lingrove-mobile-validation.lock"}, indent=2) + "\n")
        print(args.label + " finished with exit " + str(code), flush=True)
        return code


if __name__ == "__main__":
    raise SystemExit(main())
